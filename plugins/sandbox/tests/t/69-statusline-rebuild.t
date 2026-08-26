#!/usr/bin/env perl
# 69-statusline-rebuild -- the ORACLE for blueprint unified-tui-design-system,
# package 10-statusline-rebuild
# (specs/10-statusline-rebuild-spec.md).
#
# Written BLIND to scripts/statusline.pl and plugins/butler/scripts/
# bp-statusline.pl -- neither file was read while this oracle was written.
# Every expectation comes from the spec, so this file is an oracle rather than
# an echo of whatever the implementer eventually writes. Do NOT weaken an
# assertion to make a future implementation's life easier.
#
# Coverage: AC-S, AC-E, AC-O, AC-M, AC-P, AC-D, AC-B, AC-G (spec S4).
#
# HARD CONSTRAINTS honoured here (spec S4.0):
#   * NEVER spawns launcher.pl, never builds an image, never starts a
#     container. Only the two plain filter scripts are spawned, each bounded
#     by `timeout`, exactly as t/102-tui-output-hygiene.t and t/54-spend-panel.t
#     already spawn them.
#   * Fixtures live only under File::Temp tempdir()/tempfile().
#   * Never redirects to NUL; /dev/null only.
#   * No whole-shape pins (Decision 15): no rendered-row count, no field
#     inventory, no key-set comparison, no assertion of MIN_CWD_COLS /
#     MIN_PROJECT_COLS / the marker slot width. "Same slot, same width" is
#     asserted as a RELATIONSHIP between the two rendered variants.
#   * Whole-line `#` comments are blanked before every source scan, because
#     this oracle's own subject matter is the constructs being scanned for.
#   * Call forms are targeted, never bare words: \bwarn\s*\( , not \bwarn\b
#     (which would match the mandated role name state.warn).
#   * \Q...\E does not interpolate escapes, so escape-byte searches use
#     index($s, "\e[...") instead.
#   * This file deliberately does NOT carry the generated-block begin marker
#     at column 0 -- t/64's repo-wide walk fails if that line appears in any
#     .pl/.pm/.t outside the listed surface. Where the literal is needed it is
#     built by concatenation.
#
# ENCODING DISCIPLINE (spec S4.0, C-9): both scripts' stdout is read as RAW
# BYTES. Every expectation compared against it is bytes.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use File::Temp qw(tempdir tempfile);
use File::Basename qw(basename);
use JSON::PP qw(decode_json encode_json);
use Encode qw(encode decode);

use_ok('Theme') or BAIL_OUT('Theme.pm did not load -- package 02 is a dependency of this one');

my $STATUSLINE    = "$Bin/../../../../scripts/statusline.pl";
my $BP_STATUSLINE = "$Bin/../../../butler/scripts/bp-statusline.pl";
my $SANDBOX_SCRIPTS = "$Bin/../../scripts";
my $SETTINGS_JSON = "$Bin/../../container/settings.json";

# ===========================================================================
# Scaffolding
# ===========================================================================

sub slurp_raw {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return '';
    local $/;
    my $s = <$fh>;
    close $fh;
    return defined($s) ? $s : '';
}

sub spew_raw {
    my ($path, $bytes) = @_;
    open my $fh, '>:raw', $path or die "cannot write $path: $!";
    print {$fh} $bytes;
    close $fh;
    return $path;
}

# blank_comments($src) -> $src with every WHOLE-LINE comment replaced by an
# empty line (line numbering preserved). Mandatory before any source scan:
# both subject files document the very constructs scanned for.
sub blank_comments {
    my ($src) = @_;
    return '' unless defined $src;
    return join "\n", map { /^\s*#/ ? '' : $_ } split /\n/, $src, -1;
}

# --- the emoji detector (spec 02 S2.6.1/S2.6.3, restated here so this oracle
#     stands alone). Block-based and deliberately an over-approximation. The
#     U+2600-U+26FF block is load-bearing: U+26AA (one of the four glyphs
#     bp-statusline.pl must lose) is NOT in a 1F??? block.
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

# emoji_hits($bytes) -> list of { cp, how }. Arm A: escape literals in source
# text. Arm B: encoded literals, decoded leniently. Both arms run over the
# same input, so the detector serves source scans (AC-E) and rendered output
# (AC-M4, AC-G1) alike.
sub emoji_hits {
    my ($text) = @_;
    return () unless defined $text;
    my @hits;
    while ($text =~ /\\x\{([0-9A-Fa-f]{2,6})\}/g) {
        my $cp = hex($1);
        push @hits, { cp => $cp, how => 'escape' } if _is_emoji($cp);
    }
    my $decoded = decode('UTF-8', $text, Encode::FB_DEFAULT);
    for my $ch (split //, $decoded) {
        my $cp = ord($ch);
        push @hits, { cp => $cp, how => 'literal' } if _is_emoji($cp);
    }
    return @hits;
}
sub emoji_summary {
    my (@hits) = @_;
    return join(', ', map { sprintf('U+%04X(%s)', $_->{cp}, $_->{how}) } @hits);
}

my $TMPROOT = tempdir(CLEANUP => 1);
my $tmpseq  = 0;
sub temp_source {
    my ($bytes) = @_;
    my $path = "$TMPROOT/fixture-" . (++$tmpseq) . ".pl";
    return spew_raw($path, $bytes);
}

# --- width / cost -----------------------------------------------------------
# Spec S2.4.1: strip SGR; columns = sum of per-character display widths from a
# declared table (U+FF5C is TWO columns -- Theme declares it so); bytes = the
# UTF-8 byte length of the stripped string; cost = max(columns, bytes).
my $SEPBAR_CP    = 0xFF5C;
my $SEPBAR_BYTES = Theme::glyph('sep.bar');
my $SEPBAR_COLS  = Theme::glyph_width('sep.bar');
my %ORACLE_COLS  = ($SEPBAR_CP => (defined($SEPBAR_COLS) ? $SEPBAR_COLS : 2));

sub strip_sgr { my $s = shift; $s = '' unless defined $s; $s =~ s/\033\[[^m]*m//g; return $s }

sub col_cost {
    my ($bytes) = @_;
    my $s = strip_sgr($bytes);
    my $dec = decode('UTF-8', $s, Encode::FB_DEFAULT);
    my $cols = 0;
    $cols += ($ORACLE_COLS{ ord($_) } // 1) for split //, $dec;
    return $cols;
}

sub row_cost {
    my ($bytes) = @_;
    my $s  = strip_sgr($bytes);
    my $b  = length($s);
    my $c  = col_cost($bytes);
    return $c > $b ? $c : $b;
}

sub first_line { my $s = shift; $s = '' unless defined $s; my ($l) = split /\n/, $s, 2; return defined($l) ? $l : '' }

# sep_fields($line_bytes) -> the SGR-stripped row split on the rendered
# separator (space, sep.bar, space). Field 0 is the marker, 1 the project,
# 2 the working directory, then git and plans -- spec S2.1. Deliberately a
# positional accessor, never an inventory: nothing here counts the fields.
my $SEP_RENDERED = " " . $SEPBAR_BYTES . " ";
sub sep_fields {
    my ($line) = @_;
    my $s = strip_sgr($line);
    return split /\Q$SEP_RENDERED\E/, $s, -1;
}
sub field_at {
    my ($line, $idx) = @_;
    my @f = sep_fields($line);
    return $idx <= $#f ? $f[$idx] : undef;
}

# --- shims (spec S4.1: F-tput, F-git) ---------------------------------------
my $SHIM_DIR = tempdir(CLEANUP => 1);

sub make_tput {
    my ($cols) = @_;
    spew_raw("$SHIM_DIR/tput", "#!/bin/sh\necho $cols\n");
    chmod 0755, "$SHIM_DIR/tput";
}

# make_git(toplevel => $bytes|undef, branch => $str|undef)
#
# SCAFFOLDING NOTE (deviation from the spec's env-driven F-git, recorded):
# the spec drives the shim from S69_TOPLEVEL / S69_BRANCH. On this host the
# environment block is not a reliable carrier of raw UTF-8 bytes (case P-e
# uses `Andre'-projekt'), and AC-P5 separately requires the shim file to be
# written :raw with pre-encoded UTF-8. Baking the values into the shim file
# itself -- rewritten per run, exactly as make_tput rewrites tput -- satisfies
# both and removes the encoding hazard entirely. The observable contract is
# unchanged: rev-parse --show-toplevel prints the toplevel or exits 1;
# rev-parse --abbrev-ref prints the branch or exits 1; anything else exits 1.
sub make_git {
    my (%opt) = @_;
    my $top    = $opt{toplevel};
    my $branch = $opt{branch};
    my $topfile = "$SHIM_DIR/toplevel.txt";
    my $brfile  = "$SHIM_DIR/branch.txt";
    unlink $topfile, $brfile;
    spew_raw($topfile, $top)    if defined($top)    && length($top);
    spew_raw($brfile,  $branch) if defined($branch) && length($branch);
    my $sh = <<'SH';
#!/bin/sh
d=$(dirname "$0")
want=""
for a in "$@"; do
  case "$a" in
    --show-toplevel) want=toplevel ;;
    --abbrev-ref)    want=branch ;;
  esac
done
case "$want" in
  toplevel) if [ -s "$d/toplevel.txt" ]; then cat "$d/toplevel.txt"; echo; exit 0; fi; exit 1 ;;
  branch)   if [ -s "$d/branch.txt" ];   then cat "$d/branch.txt";   echo; exit 0; fi; exit 1 ;;
esac
exit 1
SH
    spew_raw("$SHIM_DIR/git", $sh);
    chmod 0755, "$SHIM_DIR/git";
}

# --- the sandbox variable, discovered exactly as t/54:140-154 discovers it ---
my $SANDBOX_VAR;
{
    my $settings = eval { decode_json(slurp_raw($SETTINGS_JSON)) };
    my $env = (ref($settings) eq 'HASH' && ref($settings->{env}) eq 'HASH') ? $settings->{env} : {};
    my @candidates = grep {
        /SANDBOX/i && defined($env->{$_}) && $env->{$_} =~ /^(1|true)$/i
    } sort keys %$env;
    $SANDBOX_VAR = @candidates ? $candidates[0] : 'CCPRAXIS_SANDBOX';
    diag("setup: sandbox var discovered as '$SANDBOX_VAR'");
}

# --- F-env / F-payload / the spawn ------------------------------------------
my $CLEAN_HOME = tempdir(CLEANUP => 1);
my $CLEAN_DATA = tempdir(CLEANUP => 1);
my $SEEDED_HOME = tempdir(CLEANUP => 1);
my $SEEDED_DATA = tempdir(CLEANUP => 1);

sub payload_for {
    my (%opt) = @_;
    return {
        model          => { display_name => 'Claude Sonnet 5', id => 'claude-sonnet-5' },
        workspace      => { current_dir  => $opt{current_dir} // '/w/proj-alpha' },
        context_window => { used_percentage => 10, context_window_size => 200_000 },
    };
}

# run_statusline(\%payload, cols => N, sandbox => 0|1, toplevel => ..,
#                branch => .., home => .., data => ..) -> ($stdout_bytes, $rc)
sub run_statusline {
    my ($payload, %opt) = @_;
    make_tput($opt{cols} // 80);
    make_git(toplevel => $opt{toplevel}, branch => $opt{branch});

    my ($infh, $inpath) = tempfile(DIR => $TMPROOT);
    binmode $infh, ':raw';
    print {$infh} encode_json($payload);
    close $infh;

    local %ENV = %ENV;
    $ENV{PATH} = "$SHIM_DIR:$ENV{PATH}";
    $ENV{HOME} = $opt{home} // $CLEAN_HOME;
    $ENV{CCPRAXIS_DATA_DIR} = $opt{data} // $CLEAN_DATA;
    if ($opt{sandbox}) { $ENV{$SANDBOX_VAR} = '1' } else { delete $ENV{$SANDBOX_VAR} }

    my $out = `timeout 20 perl "$STATUSLINE" < "$inpath" 2>/dev/null`;
    my $rc  = $? >> 8;
    return (defined($out) ? $out : '', $rc);
}
sub statusline_line1 { my ($out) = run_statusline(@_); return first_line($out) }

# The working directory moved OFF row 1 onto its own final row, at the
# operator's request: a full path is the one field with no natural width, so on
# row 1 it was permanently in contention with every other field and the fit
# ladder spent four of its eight steps eliding it. On its own row it is simply
# rendered in full, and is never elided at any width.
#
# These two helpers exist so the ACs below say WHICH ROW they mean. The old
# tests asked "is the cwd in line 1", which is now the wrong question rather
# than a failing one.
sub statusline_path_row {
    my ($out) = run_statusline(@_);
    my @rows = split /\n/, (defined $out ? $out : '');
    return @rows ? $rows[-1] : '';
}
sub statusline_rows {
    my ($out) = run_statusline(@_);
    return split /\n/, (defined $out ? $out : '');
}

ok(-f $STATUSLINE, 'setup: scripts/statusline.pl exists at the expected path')
    or BAIL_OUT("cannot find statusline.pl at $STATUSLINE");
ok(-f $BP_STATUSLINE, 'setup: plugins/butler/scripts/bp-statusline.pl exists at the expected path')
    or BAIL_OUT("cannot find bp-statusline.pl at $BP_STATUSLINE");

my $SRC_SL = blank_comments(slurp_raw($STATUSLINE));
my $SRC_BP = blank_comments(slurp_raw($BP_STATUSLINE));
ok(length($SRC_SL) > 0, 'setup: statusline.pl was read as raw source bytes');
ok(length($SRC_BP) > 0, 'setup: bp-statusline.pl was read as raw source bytes');

# ===========================================================================
# AC-O -- row 1 field order (criterion 1, spec S4 AC-O / B-1)
#
# Fixtures: F-tput at a generous 200, F-git with toplevel /w/proj-alpha and
# branch main, F-env, F-payload with current_dir /w/proj-alpha/plugins/sandbox.
# Positional relations only -- no count, no field inventory.
# ===========================================================================
{
    my $top    = '/w/proj-alpha';
    my $cwd    = '/w/proj-alpha/plugins/sandbox';
    my $branch = 'main';

    for my $mode (['sandbox', 1, 'SANDBOX'], ['host', 0, 'HOST']) {
        my ($label, $sb, $marker) = @$mode;
        my @args = (payload_for(current_dir => $cwd),
            cols => 200, sandbox => $sb, toplevel => $top, branch => $branch);
        my $line = statusline_line1(@args);
        my $vis  = strip_sgr($line);
        my $path_vis = strip_sgr(statusline_path_row(@args));

        my $i_marker  = index($vis, $marker);
        my $i_project = index($vis, 'proj-alpha');
        my $i_branch  = index($vis, $branch);

        ok($i_marker >= 0 && $i_project >= 0 && $i_branch >= 0,
            "AC-O1 setup ($label): marker, project name and branch all appear in the first line")
            or diag("  marker=$i_marker project=$i_project branch=$i_branch line=[$vis]");

        ok($i_marker >= 0 && $i_project > $i_marker,
            "AC-O1 ($label): the marker precedes the project name");
        ok($i_project >= 0 && $i_branch > $i_project,
            "AC-O1 ($label): the project name precedes the git branch");

        # The path is no longer ON row 1 -- and must NOT be, or it would still
        # be competing for that row's width.
        is(index($vis, $cwd), -1,
            "AC-O1 ($label): the working directory does NOT appear on row 1");
        is($path_vis, $cwd,
            "AC-O1 ($label): the LAST row is the working directory, complete and alone");

        # t06 AMENDMENT (blueprint Decision 8, package t06-statusline-marker,
        # 2026-08-19): blueprint Decision 3 (locked) puts a leading, non-emoji
        # glyph before the marker word -- filled U+25CF on HOST, hollow U+25CB
        # on SANDBOX -- so the marker WORD can no longer sit at byte offset 0;
        # the glyph does. AC-O2's INTENT ("the marker leads the row -- nothing
        # unexpected is rendered to its left") is preserved, not weakened: it
        # is re-expressed as two exact `is()` checks instead of one, and still
        # fails if the marker is absent (index -1), pushed further right than
        # glyph+space, or if anything OTHER than the declared Decision-3 glyph
        # followed by exactly one space occupies the lead.
        my %T06_GLYPH_CP = (sandbox => 0x25CB, host => 0x25CF);
        my $t06_prefix = encode('UTF-8', chr($T06_GLYPH_CP{$label})) . ' ';
        is(substr($vis, 0, length($t06_prefix)), $t06_prefix,
            "AC-O2 ($label): row 1 leads with the Decision-3 glyph, immediately followed by exactly one space, and nothing else");
        is($i_marker, length($t06_prefix),
            "AC-O2 ($label): the marker word begins immediately after the leading glyph+space -- nothing else is rendered to its left");

        my $badge = encode('UTF-8', chr(0x1F4E6));
        ok(index($line, $badge) < 0,
            "AC-O3 ($label): the emoji package badge (U+1F4E6) does not appear in the first line");
    }
}

# ===========================================================================
# AC-M -- the marker is textual and symmetric (criterion 2, B-2/B-3)
#
# Fixtures: F-tput at 40, 80, 120, 200; F-env; F-payload with an ordinary
# short path; each width rendered twice, once with the sandbox variable set
# and once with it deleted.
#
# AC-M3 is the "same slot, same width" property expressed RELATIONALLY -- as
# a comparison between the two rendered variants -- never as a pinned slot
# width, per Decision 15.
# ===========================================================================

# same_slot_report($a, $b) -> { cost_equal => 0|1, tail_equal => 0|1 }
# The two rows are compared for equal row_cost and for byte-identity from the
# first sep.bar onward. Exercised on synthetic input by AC-M5 so a comparison
# that cannot fail never masquerades as a passing assertion.
sub same_slot_report {
    my ($a, $b) = @_;
    my $va = strip_sgr($a);
    my $vb = strip_sgr($b);
    my $ia = index($va, $SEPBAR_BYTES);
    my $ib = index($vb, $SEPBAR_BYTES);
    my $tail_equal = ($ia >= 0 && $ib >= 0 && substr($va, $ia) eq substr($vb, $ib)) ? 1 : 0;
    return {
        cost_equal   => (row_cost($a) == row_cost($b)) ? 1 : 0,
        offset_equal => ($ia >= 0 && $ib >= 0 && $ia == $ib) ? 1 : 0,
        tail_equal   => $tail_equal,
        sep_a        => $ia,
        sep_b        => $ib,
    };
}

{
    my $dir = '/w/proj-alpha';
    for my $cols (40, 80, 120, 200) {
        my $on  = statusline_line1(payload_for(current_dir => $dir),
                    cols => $cols, sandbox => 1, toplevel => $dir);
        my $off = statusline_line1(payload_for(current_dir => $dir),
                    cols => $cols, sandbox => 0, toplevel => $dir);

        ok(index(strip_sgr($on), 'SANDBOX') >= 0,
            "AC-M1 (cols=$cols): the sandbox render carries the textual SANDBOX marker")
            or diag('  line = [' . strip_sgr($on) . ']');
        ok(index(strip_sgr($off), 'HOST') >= 0,
            "AC-M1 (cols=$cols): the host render carries the textual HOST marker -- absence cannot be mistaken for breakage")
            or diag('  line = [' . strip_sgr($off) . ']');

        unlike(strip_sgr($off), qr/sandbox/i,
            "AC-M2 (cols=$cols): the host render mentions nothing sandbox-ish");

        my $rep = same_slot_report($on, $off);
        ok($rep->{cost_equal},
            "AC-M3 (cols=$cols): both marker variants render rows of equal row_cost -- the row does not reflow between environments")
            or diag(sprintf('  cost sandbox=%d host=%d', row_cost($on), row_cost($off)));
        ok($rep->{offset_equal},
            "AC-M3 (cols=$cols): both variants place the first sep.bar at the same byte offset -- the marker slot is common")
            or diag(sprintf('  sep offset sandbox=%d host=%d', $rep->{sep_a}, $rep->{sep_b}));
        ok($rep->{tail_equal},
            "AC-M3 (cols=$cols): the two rows are byte-identical from the first sep.bar onward -- the marker occupies a common slot")
            or diag('  sandbox = [' . strip_sgr($on) . "]\n  host    = [" . strip_sgr($off) . ']');

        my @e_on  = emoji_hits($on);
        my @e_off = emoji_hits($off);
        ok(scalar(@e_on) == 0,
            "AC-M4 (cols=$cols): the sandbox render contains no emoji codepoint")
            or diag('  hits: ' . emoji_summary(@e_on));
        ok(scalar(@e_off) == 0,
            "AC-M4 (cols=$cols): the host render contains no emoji codepoint")
            or diag('  hits: ' . emoji_summary(@e_off));
    }

    # AC-M5 -- counter-fixture (C-7). The helper AC-M3 leans on must report a
    # DIFFERENCE for two synthetic rows whose marker fields have unequal
    # width, and agreement for two padded to a common slot.
    my $unequal = same_slot_report("SANDBOX$SEP_RENDERED" . 'p', "HOST$SEP_RENDERED" . 'p');
    ok(!$unequal->{cost_equal},
        'AC-M5 (counter-fixture): same_slot_report reports UNEQUAL cost for synthetic rows with unequal marker widths');
    ok(!$unequal->{offset_equal},
        'AC-M5 (counter-fixture): same_slot_report reports a SHIFTED separator offset when the marker slots differ in width');
    my $equal = same_slot_report("SANDBOX$SEP_RENDERED" . 'p', "HOST   $SEP_RENDERED" . 'p');
    ok($equal->{cost_equal} && $equal->{offset_equal} && $equal->{tail_equal},
        'AC-M5 (counter-fixture): the same helper AGREES when the two synthetic markers are padded to a common slot');
}

# ===========================================================================
# AC-P -- project name resolution (criterion 3, B-4..B-7)
#
# Fixtures: F-tput at a generous 200 (so nothing truncates and the assertion
# is about resolution, not layout), F-env, F-git driven per case, F-payload.
# The project field is read POSITIONALLY (the segment after the marker's
# separator), never by counting fields.
#
# The non-ASCII case is built from explicit bytes -- "Andr", 0xC3, 0xA9 -- so
# the UTF-8 encoding of the fixture cannot drift with this file's own
# encoding. Both the shim file and the expectation are those same bytes.
# ===========================================================================
my $ANDRE_NAME = 'Andr' . chr(0xC3) . chr(0xA9) . '-projekt';
{
    my %case = (
        'P-a' => { toplevel => '/w/proj-alpha', cwd => '/w/proj-alpha',                          want => 'proj-alpha' },
        'P-b' => { toplevel => '/w/proj-alpha', cwd => '/w/proj-alpha/plugins/sandbox/scripts',  want => 'proj-alpha' },
        'P-c' => { toplevel => undef,           cwd => '/w/loose-dir',                           want => 'loose-dir'  },
        'P-d' => { toplevel => '/w/proj-alpha', cwd => '/elsewhere/scratch-area',                want => 'proj-alpha' },
    );

    for my $id (sort keys %case) {
        my $c = $case{$id};
        my $line  = statusline_line1(payload_for(current_dir => $c->{cwd}),
                        cols => 200, sandbox => 0, toplevel => $c->{toplevel});
        my $field = field_at($line, 1);
        my $shown = defined($field) ? $field : '(no project field)';

        if ($id eq 'P-a') {
            ok(index(strip_sgr($line), 'proj-alpha') >= 0,
                'AC-P1 (P-a): a repo whose toplevel IS the current dir renders the toplevel basename');
        }
        is($shown, $c->{want},
            "AC-P" . ($id eq 'P-a' ? '1' : $id eq 'P-b' ? '2' : $id eq 'P-c' ? '3' : '4')
            . " ($id): the project field is '$c->{want}'"
            . ($id eq 'P-b' ? ' -- the git toplevel basename, NOT the working directory basename' : ''))
            or diag("  first line = [" . strip_sgr($line) . ']');

        if ($id eq 'P-b') {
            isnt($shown, 'scripts',
                'AC-P2 (P-b): the project field is NOT the deep working directory basename -- the mislabelled-project defect is gone');
        }
        if ($id eq 'P-d') {
            # The location lives on the path row now; the name lives on row 1.
            # That they resolve INDEPENDENTLY is exactly what this asserts, and
            # it is if anything more visible now that they are on separate rows.
            my $path_vis = strip_sgr(statusline_path_row(payload_for(current_dir => $c->{cwd}),
                                cols => 200, sandbox => 0, toplevel => $c->{toplevel}));
            is($path_vis, '/elsewhere/scratch-area',
                'AC-P4 (P-d): a working directory OUTSIDE the reported toplevel still renders in full -- name and location resolve independently');
        }
    }

    # P-e -- non-ASCII toplevel; bytes on both sides (C-9).
    {
        my $top  = '/w/' . $ANDRE_NAME;
        my $line = statusline_line1(payload_for(current_dir => "$top/plugins"),
                        cols => 200, sandbox => 0, toplevel => $top);
        ok(index($line, $ANDRE_NAME) >= 0,
            'AC-P5 (P-e): the first line carries the UTF-8 BYTES of a non-ASCII project name')
            or diag('  first line = [' . strip_sgr($line) . ']');
    }

    # AC-P6 -- non-vacuity: the SAME current_dir with and without a reported
    # toplevel must resolve to DIFFERENT project fields, proving the git shim
    # actually drives resolution rather than the assertions passing by luck.
    {
        my $cwd = '/w/loose-dir';
        my $with    = field_at(statusline_line1(payload_for(current_dir => $cwd),
                        cols => 200, sandbox => 0, toplevel => '/w/proj-alpha'), 1);
        my $without = field_at(statusline_line1(payload_for(current_dir => $cwd),
                        cols => 200, sandbox => 0, toplevel => undef), 1);
        ok(defined($with) && defined($without) && $with ne $without,
            'AC-P6 (non-vacuity): the same current_dir resolves to different project fields with and without a reported toplevel')
            or diag('  with = ' . (defined $with ? $with : '(undef)')
                  . ' / without = ' . (defined $without ? $without : '(undef)'));
    }
}

# ===========================================================================
# AC-D -- the full working directory, and graceful elision (criterion 4,
# B-8..B-11). Fixtures: F-tput at 200 and 40; F-env; F-git with toplevel
# /w/proj-alpha; a short payload and a long one (/w/proj-alpha/ + 200 x's).
#
# N1/N2 (spec S2.4.4) are asserted as PREFIX/SUFFIX relations against the
# true value -- never as a length equality, which would pin the floor
# constants Decision 15 forbids asserting.
# ===========================================================================
{
    my $top      = '/w/proj-alpha';
    my $short    = '/w/proj-alpha';
    my $long     = '/w/proj-alpha/' . ('x' x 200);

    # AC-D1 / AC-D2 -- the path row renders the path verbatim.
    {
        my @args = (payload_for(current_dir => $short),
                    cols => 200, sandbox => 0, toplevel => $top);
        my $line = statusline_line1(@args);
        is(strip_sgr(statusline_path_row(@args)), $short,
            'AC-D1: the COMPLETE working directory renders verbatim on its own row');

        my $proj = field_at($line, 1);
        ok(defined($proj) && index($proj, '>') < 0 && index($proj, '<') < 0,
            'AC-D2: at a generous width the project field carries no elision marker -- truncation is conditional, not universal')
            or diag('  project field = ' . (defined $proj ? "[$proj]" : '(none)'));
    }

    # AC-D3 -- REPLACES the old left-elision AC. The path used to be elided from
    # its head at a forcing width because it shared row 1; alone on its own row
    # it is never elided at all. That is the point of the move: a truncated path
    # is a path you cannot act on, and the terminal's own wrapping shows all of
    # it rather than hiding the head behind a marker.
    {
        for my $cols (40, 80, 200) {
            my @args = (payload_for(current_dir => $long),
                        cols => $cols, sandbox => 0, toplevel => $top);
            is(strip_sgr(statusline_path_row(@args)), $long,
                "AC-D3: at width $cols the path row is the COMPLETE path -- never elided, at any width");
            my $vis1 = strip_sgr(statusline_line1(@args));
            is(index($vis1, 'xxxxx'), -1,
                "AC-D3: at width $cols no part of the path leaks onto row 1");
        }
    }

    # AC-D4 -- N1: the project keeps its HEAD.
    {
        my $longname = 'proj-' . ('n' x 120);
        my $ltop     = "/w/$longname";
        my $line = statusline_line1(payload_for(current_dir => "$ltop/deep/place"),
                        cols => 40, sandbox => 0, toplevel => $ltop);
        my $proj = field_at($line, 1);
        my $ok_shape = defined($proj) && length($proj) > 1 && substr($proj, -1) eq '>';
        ok($ok_shape,
            'AC-D4 (N1): at a forcing width the project field is retained text followed by a right-elision marker')
            or diag('  project field = ' . (defined $proj ? "[$proj]" : '(none)')
                  . "\n  first line = [" . strip_sgr($line) . ']');
        my $prefix = $ok_shape ? substr($proj, 0, length($proj) - 1) : '';
        ok(length($prefix) && index($longname, $prefix) == 0,
            'AC-D4 (N1): the retained text is a non-empty PREFIX of the true project name')
            or diag("  retained = [$prefix]");
    }

    # AC-D5 -- non-ambiguity, the discriminating pairs. Paths differing only
    # in their FINAL component must still render differently; project names
    # differing only in their FIRST characters must too.
    {
        my $stem = '/w/proj-alpha/' . ('d' x 150) . '/deep';
        my $a = statusline_path_row(payload_for(current_dir => "$stem/alpha"),
                    cols => 40, sandbox => 0, toplevel => $top);
        my $b = statusline_path_row(payload_for(current_dir => "$stem/beta"),
                    cols => 40, sandbox => 0, toplevel => $top);
        isnt(strip_sgr($a), strip_sgr($b),
            'AC-D5: two long paths differing only in their FINAL component render different path rows');

        my $tail = 'z' x 120;
        my $ta = "/w/alpha-$tail";
        my $tb = "/w/beta-$tail";
        my $pa = statusline_line1(payload_for(current_dir => "$ta/here"),
                    cols => 40, sandbox => 0, toplevel => $ta);
        my $pb = statusline_line1(payload_for(current_dir => "$tb/here"),
                    cols => 40, sandbox => 0, toplevel => $tb);
        isnt(strip_sgr($pa), strip_sgr($pb),
            'AC-D5: two long project names differing only in their FIRST characters render different rows -- the retained head still discriminates');
    }

    # AC-D6 -- the cwd never degrades to a bare marker while the project is
    # still on the row.
    for my $cols (40, 60, 80, 120, 200) {
        my $line = statusline_line1(payload_for(current_dir => $long),
                        cols => $cols, sandbox => 0, toplevel => $top);
        my $proj = field_at($line, 1);
        my $cwd  = field_at($line, 2);
        my $bad  = (defined($proj) && length($proj) && defined($cwd) && $cwd eq '<') ? 1 : 0;
        is($bad, 0,
            "AC-D6 (cols=$cols): the cwd field is never a bare elision marker while the project field is still present")
            or diag('  first line = [' . strip_sgr($line) . ']');
    }
}

# ===========================================================================
# AC-S -- static source contract on the two scripts (criteria 5 and 6).
# No spawn except a bounded `perl -c`. Every scan runs over COMMENT-BLANKED
# source, and every detector is exercised on a counter-fixture so a scan that
# cannot fire never masquerades as a passing assertion.
# ===========================================================================

# --- balanced-delimiter helpers (t/54/t/59's slurped-source convention) ------
sub _balanced {
    my ($src, $from, $open, $close) = @_;
    my $idx = index($src, $open, $from);
    return undef if $idx < 0;
    my $depth = 0;
    my $len   = length($src);
    my $i     = $idx;
    for (; $i < $len; $i++) {
        my $c = substr($src, $i, 1);
        if    ($c eq $open)  { $depth++ }
        elsif ($c eq $close) { $depth--; last if $depth == 0 }
    }
    return undef if $depth != 0;
    return substr($src, $idx, $i - $idx + 1);
}

# colour_literal_hits($code) -> list of findings. A numeric-literal colour is
# either an rgb() CALL FORM with a digit argument, or a truecolor/256 SGR
# literal written out by hand. sub rgb's own interpolated body and the
# non-colour attribute literals are deliberately NOT matched.
sub colour_literal_hits {
    my ($code) = @_;
    my @hits;
    push @hits, 'rgb() call form with a numeric argument'
        if $code =~ /\brgb\s*\(\s*[-+]?\d/;
    push @hits, 'hand-written truecolor/256 SGR literal'
        if $code =~ /(?:\\033|\\e|\\x1[bB]|\\x\{1[bB]\}|\x1b)\[38;[25];\d/;
    return @hits;
}

# import_violations($code) -> list of findings. The allow-list is the spec's,
# verbatim: statusline.pl is an installed standalone payload and may reach
# only for core modules (criterion 6).
my @CORE_ALLOWED = qw(strict warnings JSON::PP Time::Piece File::Basename
                      POSIX Encode constant Carp List::Util Scalar::Util);
sub import_violations {
    my ($code) = @_;
    my %allowed = map { $_ => 1 } @CORE_ALLOWED;
    my @bad;
    while ($code =~ /\buse\s+([A-Za-z_][\w:]*)/g) {
        my $mod = $1;
        next if $mod =~ /^v?\d/;
        push @bad, "use $mod" unless $allowed{$mod};
    }
    push @bad, 'require of a path string' if $code =~ /\brequire\s+["']/;
    push @bad, 'require of a computed path' if $code =~ /\brequire\s+\$/;
    push @bad, 'FindBin' if $code =~ /\bFindBin\b/;
    while ($code =~ /\b(?:use|require)\s+(Theme|Dashboard|SpendPanel|tui::\w+|Layout::\w+)\b/g) {
        push @bad, "repo module as an import target: $1";
    }
    return @bad;
}

# parse_glyph_cols($code) -> hashref { codepoint => columns } read out of the
# inline %GLYPH_COLS declaration, or undef if there is no such table.
sub parse_glyph_cols {
    my ($code) = @_;
    return undef unless $code =~ /%GLYPH_COLS\s*=\s*/g;
    my $body = _balanced($code, pos($code), '(', ')');
    $body = _balanced($code, pos($code), '{', '}') unless defined $body;
    return undef unless defined $body;
    my %t;
    while ($body =~ /(0x[0-9A-Fa-f]+|\d+)\s*(?:=>|,)\s*(\d+)/g) {
        my ($k, $v) = ($1, $2);
        my $cp = ($k =~ /^0x/i) ? hex($k) : 0 + $k;
        $t{$cp} = 0 + $v;
    }
    return \%t;
}

# glyph_cols_disagreements(\%table) -> list of codepoints whose declared width
# differs from Theme's. This is criterion 6's reconciliation: a DRIFT GUARD,
# never an import.
my %THEME_WIDTH_BY_CP;
{
    my $g = Theme::glyphs();
    for my $name (keys %$g) {
        $THEME_WIDTH_BY_CP{ $g->{$name}{cp} } = $g->{$name}{width};
    }
}
# Codepoints statusline.pl may declare a width for even though Theme does not
# carry them, each with the reason it is not drift. An entry here is a DECLARED
# exception, not a silent one -- which is the whole difference between this and
# what the guard did before.
#
# It used to `next unless exists $THEME_WIDTH_BY_CP{$cp}`, so any entry Theme did
# not declare was skipped without comment. That is weaker than spec §5.2 claims
# ("a wide glyph is later added => AC-S5 fails until Theme and the table agree"):
# the entries most likely to drift are exactly the ones Theme has no opinion on,
# and those were the ones going unchecked. Found by the package 10 review.
my %GLYPH_COLS_NOT_IN_THEME = (
    0x3000 => 'ideographic space, used as row 2 padding; a spacing character '
            . 'rather than a Theme GLYPH, so Theme has no entry to reconcile with',
);
sub glyph_cols_disagreements {
    my ($table) = @_;
    my @bad;
    for my $cp (sort { $a <=> $b } keys %{ $table || {} }) {
        if (!exists $THEME_WIDTH_BY_CP{$cp}) {
            # Undeclared AND unexcused is now a finding rather than a skip.
            push @bad, sprintf('U+%04X: width %d declared in the table, but Theme '
                             . 'carries no entry and it is not on the documented '
                             . 'exception list', $cp, $table->{$cp})
                unless exists $GLYPH_COLS_NOT_IN_THEME{$cp};
            next;
        }
        push @bad, sprintf('U+%04X: table says %d, Theme says %d',
                           $cp, $table->{$cp}, $THEME_WIDTH_BY_CP{$cp})
            if $table->{$cp} != $THEME_WIDTH_BY_CP{$cp};
    }
    return @bad;
}

{
    # AC-S1 -- no numeric-literal colour in statusline.pl.
    my @colour = colour_literal_hits($SRC_SL);
    ok(scalar(@colour) == 0,
        'AC-S1: statusline.pl carries no numeric-literal colour -- every colour comes from the generated token block')
        or diag('  found: ' . join('; ', @colour));

    # AC-S1 counter-fixtures (C-7): the same helper must fire on a numeric
    # literal and stay silent on a role lookup.
    my $pos_src = slurp_raw(temp_source("my \$c = rgb(1,2,3);\n"));
    my $neg_src = slurp_raw(temp_source("my \$c = \$THEME_RGB{'accent'};\n"));
    ok(scalar(colour_literal_hits(blank_comments($pos_src))) > 0,
        'AC-S1 (counter-fixture): the colour-literal detector FIRES on a synthetic rgb(1,2,3) call');
    ok(scalar(colour_literal_hits(blank_comments($neg_src))) == 0,
        'AC-S1 (counter-fixture): the same detector stays silent on a synthetic $THEME_RGB{...} lookup');

    # AC-S2 -- the block's colours are actually CONSUMED, not merely embedded.
    ok($SRC_SL =~ /\$THEME_RGB\{/,
        'AC-S2: statusline.pl reads its colours out of %THEME_RGB by role name');

    # AC-S3 -- core modules only, nothing from the repo.
    my @imports = import_violations($SRC_SL);
    ok(scalar(@imports) == 0,
        'AC-S3: statusline.pl imports nothing outside the core allow-list and nothing from the repo')
        or diag('  found: ' . join('; ', @imports));

    my $bad_src  = slurp_raw(temp_source("use lib \"x\";\nuse Theme;\n"));
    my $good_src = slurp_raw(temp_source("use JSON::PP;\n"));
    ok(scalar(import_violations(blank_comments($bad_src))) > 0,
        'AC-S3 (counter-fixture): the import scan FIRES on a synthetic `use lib` + `use Theme`');
    ok(scalar(import_violations(blank_comments($good_src))) == 0,
        'AC-S3 (counter-fixture): the same scan stays silent on a synthetic core `use JSON::PP`');

    # AC-S4 -- it compiles with NO -I flag at all.
    my $cout = `timeout 20 perl -c "$STATUSLINE" 2>&1`;
    my $crc  = $? >> 8;
    is($crc, 0,
        'AC-S4: `perl -c scripts/statusline.pl` succeeds with no -I flag -- it is a standalone payload')
        or diag("  $cout");

    # AC-S5 -- the inline width table agrees with Theme, and declares sep.bar.
    my $table = parse_glyph_cols($SRC_SL);
    ok(defined($table) && exists $table->{$SEPBAR_CP},
        'AC-S5: statusline.pl declares an inline %GLYPH_COLS table that includes sep.bar (U+FF5C)')
        or diag('  parsed table: ' . (defined $table ? join(',', map { sprintf('U+%04X=>%d', $_, $table->{$_}) } sort keys %$table) : '(none)'));
    my @drift = glyph_cols_disagreements($table);
    ok(defined($table) && scalar(keys %$table) && scalar(@drift) == 0,
        'AC-S5: every codepoint the inline table declares carries the width Theme.pm declares for it')
        or diag('  drift: ' . join('; ', @drift));

    ok(scalar(glyph_cols_disagreements({ $SEPBAR_CP => 1 })) > 0,
        'AC-S5 (counter-fixture): the drift comparison FIRES on a synthetic table declaring sep.bar as one column');
    ok(scalar(glyph_cols_disagreements({ $SEPBAR_CP => $ORACLE_COLS{$SEPBAR_CP} })) == 0,
        'AC-S5 (counter-fixture): the same comparison is silent when the synthetic table agrees with Theme');

    # The guard used to `next` past any codepoint Theme did not declare, so the
    # entries most likely to drift -- the ones Theme has no opinion on -- were
    # exactly the ones going unchecked, while spec 5.2 claimed the opposite.
    # U+0BAD is not a Theme glyph and is not on the documented exception list.
    ok(scalar(glyph_cols_disagreements({ 0x0BAD => 2 })) > 0,
        'AC-S5: a codepoint the table declares that Theme does not carry, and that '
      . 'is not on the documented exception list, is REPORTED rather than skipped');
    # ...and the exception list is what makes that survivable, not a blanket pass:
    # U+3000 is excused with a stated reason, so it must stay silent.
    ok(scalar(glyph_cols_disagreements({ 0x3000 => 2 })) == 0,
        'AC-S5 (counter-fixture): a DECLARED exception is still silent, so the '
      . 'check above is a guard with a documented escape hatch, not a tripwire');

    # AC-S6 -- bp-statusline.pl keeps t/54-spend-panel.t:627-628 green.
    unlike($SRC_BP, qr/\blength\s*\(/,
        'AC-S6: bp-statusline.pl still never measures width via a raw length() call form');
    like($SRC_BP, qr/display_width|fit_spans|spans_width/,
        'AC-S6: bp-statusline.pl still uses the shared display-width core');

    # AC-S7 -- Theme is loaded by full path, inside an eval, and the failure
    # path does not die.
    my $theme_eval;
    {
        my $code = $SRC_BP;
        while ($code =~ /\beval\s*\{/g) {
            my $body = _balanced($code, pos($code) - 1, '{', '}');
            next unless defined $body;
            if ($body =~ /require\s+["'][^"']*Theme\.pm["']/) { $theme_eval = $body; last }
        }
    }
    ok(defined($theme_eval),
        'AC-S7: bp-statusline.pl requires Theme.pm by full path from inside an eval block')
        or diag('  no eval block containing a full-path require of Theme.pm was found');

    my $win = '';
    if ($SRC_BP =~ /require\s+["'][^"']*Theme\.pm["']/g) {
        $win = substr($SRC_BP, $-[0], 400);
    }
    ok(length($win) && $win !~ /\bdie\s*[("'\$]/,
        'AC-S7: the Theme load failure path does not die')
        or diag("  window = [$win]");
    ok($SRC_BP =~ /\bwarn\s*[("'\$]/,
        'AC-S7: bp-statusline.pl degrades a failed module load with a warn call');
}

# ===========================================================================
# AC-E -- no emoji, and the detector can fire (Decision 11, B-16).
#
# Scans run over COMMENT-BLANKED source, per this blueprint's standing rule.
# t/64-theme-tokens.t remains the authority over the raw files; this group's
# job is that the two owned surfaces carry no emoji in live code, and that the
# detector used for the rendered-output assertions (AC-M4, AC-G1) demonstrably
# fires.
# ===========================================================================
{
    my @sl = emoji_hits($SRC_SL);
    ok(scalar(@sl) == 0,
        'AC-E1: scripts/statusline.pl contains no emoji codepoint')
        or diag('  hits: ' . emoji_summary(@sl));

    my @bp = emoji_hits($SRC_BP);
    ok(scalar(@bp) == 0,
        'AC-E2: plugins/butler/scripts/bp-statusline.pl contains no emoji codepoint')
        or diag('  hits: ' . emoji_summary(@bp));

    for my $cp (0x1F7E2, 0x1F534, 0x1F7E1, 0x26AA) {
        my $esc   = sprintf('\\x{%X}', $cp);
        my $bytes = encode('UTF-8', chr($cp));
        ok(index($SRC_BP, $esc) < 0 && index($SRC_BP, lc $esc) < 0 && index($SRC_BP, $bytes) < 0,
            sprintf('AC-E2: bp-statusline.pl carries neither the escape nor the encoded form of U+%04X', $cp));
    }

    # AC-E3 -- counter-fixtures (C-7). The detector must fire on both arms and
    # stay silent on the non-emoji glyphs this blueprint standardises on.
    my $esc_src = slurp_raw(temp_source("my \$badge = \"\\x{1F4E6}\";\n"));
    ok(scalar(emoji_hits(blank_comments($esc_src))) > 0,
        'AC-E3 (counter-fixture): the detector FIRES on a synthetic \x{1F4E6} escape literal');

    my $enc_src = slurp_raw(temp_source("my \$dot = \"" . encode('UTF-8', chr(0x1F7E2)) . "\";\n"));
    ok(scalar(emoji_hits(blank_comments($enc_src))) > 0,
        'AC-E3 (counter-fixture): the detector FIRES on synthetic raw UTF-8 bytes for U+1F7E2');

    my $clean_src = slurp_raw(temp_source("my \@g = (\"\\x{FF5C}\", \"\\x{2500}\", \"\\x{25CF}\", \"\\x{00D7}\");\n"));
    ok(scalar(emoji_hits(blank_comments($clean_src))) == 0,
        'AC-E3 (counter-fixture): the same detector stays SILENT on U+FF5C / U+2500 / U+25CF / U+00D7');

    # AC-E4 -- reach: the replacement goes through the shared glyph vocabulary.
    ok($SRC_BP =~ /status\.(?:ok|warn|crit|idle)/,
        'AC-E4: bp-statusline.pl names at least one Theme status-glyph role rather than a new private literal');
}

# ===========================================================================
# AC-G -- bp-statusline.pl renders non-emoji state glyphs (Decision 11, B-17).
# Spawned as a plain filter script bounded by `timeout`, stdout read as raw
# bytes, exactly as t/54-spend-panel.t:640 spawns it.
# ===========================================================================
{
    my $NOW = 1785800000;
    my $spend = {
        claude      => { status => 'ok', five_hour => { utilization => 0.10 }, seven_day => { utilization => 0.05 } },
        go          => { status => 'ok',
                         five_hour => { used => 1,  limit => 12 },
                         weekly    => { used => 3,  limit => 30 },
                         monthly   => { used => 60, limit => 60 } },
        zen         => { status => 'ok', balance => 42, budget => 100 },
        zen_enabled => 1,
    };

    sub run_bp {
        my ($script, %opt) = @_;
        my ($fh, $inpath) = tempfile(DIR => $TMPROOT);
        binmode $fh, ':raw';
        print {$fh} encode_json({ spend => $spend, now => $NOW, width => $opt{width} // 100 });
        close $fh;
        local %ENV = %ENV;
        $ENV{HOME} = $CLEAN_HOME;
        # PERL5LIB, and WHY (recorded rather than silently added): the modules
        # bp-statusline.pl loads by full path themselves load tui/Layout.pm
        # through @INC. Without the sandbox scripts directory on @INC every
        # spawn degrades to an empty line, which would make AC-G2 unfalsifiable
        # for a reason that belongs to a neighbouring package rather than to
        # this one. This oracle therefore gives the child the search path its
        # dependencies need, and asserts the GLYPH VOCABULARY on top of that.
        $ENV{PERL5LIB} = $opt{lib} // $SANDBOX_SCRIPTS;
        my $out = `timeout 20 perl "$script" < "$inpath" 2>/dev/null`;
        my $rc  = $? >> 8;
        return (defined($out) ? $out : '', $rc);
    }

    my ($out, $rc) = run_bp($BP_STATUSLINE);
    is($rc, 0, 'AC-G setup: bp-statusline.pl runs to completion under timeout');

    my @emoji_out = emoji_hits($out);
    ok(scalar(@emoji_out) == 0,
        'AC-G1: the rendered statusline form contains none of the emoji codepoints')
        or diag('  hits: ' . emoji_summary(@emoji_out));
    for my $cp (0x1F7E2, 0x1F534, 0x1F7E1, 0x26AA) {
        ok(index($out, encode('UTF-8', chr($cp))) < 0,
            sprintf('AC-G1: the rendered output carries no UTF-8 bytes for U+%04X', $cp));
    }

    my $has_state_glyph = 0;
    for my $cp (0x25CF, 0x00D7, 0x25B3, 0x25CB) {
        $has_state_glyph = 1 if index($out, encode('UTF-8', chr($cp))) >= 0;
    }
    ok($has_state_glyph,
        'AC-G2: at least one non-emoji state glyph really renders -- the emoji were replaced, not merely deleted')
        or diag('  output = [' . $out . ']');

    # AC-G4 -- never ends mid-glyph (the property t/54-spend-panel.t:654-660
    # already asserts; the glyph swap must not regress it).
    {
        (my $trimmed = $out) =~ s/\s+\z//;
        my $mid = 0;
        if (length $trimmed) {
            my $last = ord(substr($trimmed, -1, 1));
            $mid = ($last >= 0x80 && $last <= 0xBF) ? 1 : ($last >= 0xC0) ? 1 : 0;
        }
        is($mid, 0, 'AC-G4: the rendered output does not end on a stranded UTF-8 byte');
    }

    # AC-G3 -- the degrade path, asserted STRUCTURALLY, and the spec's own
    # escape hatch is why.
    #
    # AC-G3 offers a functional form (run a tree copy with no Theme.pm) and a
    # structural fallback "if the chosen mechanism cannot be made deterministic
    # on this host". It cannot. Measured, not assumed: with Theme.pm removed
    # from the copied tree, the sibling module that bp-statusline.pl also loads
    # fails to compile, and its width core then spins on an uninitialised
    # pattern -- one probe emitted ~254 MB of warnings and had to be killed by
    # `timeout`. A run whose exit status is decided by a neighbouring module's
    # degenerate loop tests nothing about THIS package, and burns the suite's
    # runtime to say so. So the degrade path is asserted where it is actually
    # specified: an eval-wrapped load that cannot die (AC-S7) plus the ASCII
    # fallback table of spec S2.7 rule 3, whose values are given as literals
    # and are therefore binding.
    {
        my %fallback = ('o' => 'ok', 'x' => 'exhausted/unreadable', '!' => 'absent', '-' => 'disabled');
        for my $ch (sort keys %fallback) {
            my $q = quotemeta($ch);
            ok($SRC_BP =~ /=>\s*(['"])$q\1/,
                "AC-G3 (structural): bp-statusline.pl declares the ASCII degrade glyph '$ch' ($fallback{$ch})");
        }
        my @ascii = ('o', 'x', '!', '-');
        my %seen; $seen{$_}++ for @ascii;
        ok(scalar(keys %seen) == scalar(@ascii),
            'AC-G3 (structural, fixture): the declared ASCII degrade glyphs are pairwise distinct, one byte and one column each');
    }
}

# ===========================================================================
# AC-B -- the whole row is budgeted (criteria 1, 2 and 4 jointly; B-12/B-13).
# This is the group that covers the overflow defect behind the two red
# assertions at t/102-tui-output-hygiene.t:247 -- independently asserted here,
# never by re-pointing that immutable file.
#
# row_cost is computed in this oracle exactly as spec S2.4.1 defines it, so
# the oracle and the implementation agree by construction rather than by luck.
# ===========================================================================
{
    # A plans fixture, seeded per the spec's F-env: a HOME tempdir with one
    # todo file and a data dir with one blueprint. Whether a plans segment
    # results is DISCOVERED below rather than assumed -- see AC-B4.
    for my $d ("$SEEDED_HOME/.claude", "$SEEDED_HOME/.claude/todos",
               "$SEEDED_DATA/blueprints", "$SEEDED_DATA/blueprints/demo") {
        mkdir $d unless -d $d;
    }
    spew_raw("$SEEDED_HOME/.claude/todos/s69-fixture.md", "- [ ] one seeded todo\n");
    spew_raw("$SEEDED_HOME/.claude/todos/s69-fixture.json", "[{\"content\":\"one\",\"status\":\"pending\"}]\n");
    spew_raw("$SEEDED_DATA/blueprints/demo/blueprint.md", "# demo\n");

    my $top   = '/w/proj-alpha';
    my $long  = '/w/proj-alpha/' . ('x' x 200);
    my @WIDTHS = (40, 80, 120, 200);

    # AC-B0 -- non-vacuity gate (F-shim-effective). A shim that silently failed
    # to take effect would make every width assertion below vacuous. Hard ok(),
    # never a skip.
    {
        # The probe must force row 1 to differ across widths. It used to rely on
        # the working directory being elided there; the path has its own row now
        # and is never elided, so the payload has to make row 1 itself overflow.
        # A long PROJECT NAME does that -- it is what row 1 elides last.
        my $ltop = '/w/proj-' . ('n' x 120);
        my $narrow = statusline_line1(payload_for(current_dir => "$ltop/deep"),
                        cols => 40, sandbox => 0, toplevel => $ltop, branch => 'main');
        my $wide   = statusline_line1(payload_for(current_dir => "$ltop/deep"),
                        cols => 200, sandbox => 0, toplevel => $ltop, branch => 'main');
        ok(length($narrow) && length($wide) && $narrow ne $wide,
            'AC-B0 (non-vacuity gate): the width-40 and width-200 renders of the same payload differ -- the tput shim really drives the layout');
    }

    # AC-B7 -- counter-fixture (C-7) for the cost function itself. A cost
    # function that silently counted characters would make this whole group
    # vacuous, and U+FF5C is precisely the character that exposes it.
    {
        my $one_bar = 'ab' . $SEPBAR_BYTES . 'cd';
        my $chars   = length(decode('UTF-8', $one_bar, Encode::FB_DEFAULT));
        cmp_ok(row_cost($one_bar), '>', $chars,
            'AC-B7 (counter-fixture): row_cost of a string containing one sep.bar exceeds its character count');
        cmp_ok(col_cost($one_bar), '>', $chars,
            'AC-B7 (counter-fixture): the COLUMN term alone also exceeds it -- sep.bar is counted as a full-width glyph, not as one column');
        my $ascii = 'abcd';
        is(col_cost($ascii), length($ascii),
            'AC-B7 (counter-fixture): the same column term counts a plain ASCII string at one column per character');
    }

    # AC-B1 / AC-B2 / AC-B3 -- the budget invariant, with and without the
    # right-hand segments. The defect being fixed is precisely "the right-hand
    # segments are appended on top of an already-full row".
    for my $cols (@WIDTHS) {
        for my $case (
            ['bare',           { branch => undef,  home => $CLEAN_HOME,  data => $CLEAN_DATA  }, 'AC-B1'],
            ['git+plans seed', { branch => 'main', home => $SEEDED_HOME, data => $SEEDED_DATA }, 'AC-B2'],
        ) {
            my ($label, $opt, $ac) = @$case;
            my ($out, $rc) = run_statusline(payload_for(current_dir => $long),
                cols => $cols, sandbox => 0, toplevel => $top, %$opt);
            my $line = first_line($out);
            my $cost = row_cost($line);
            ok($cost <= $cols,
                "$ac (cols=$cols, $label): the whole first line costs $cost, within the $cols-column budget")
                or diag('  first line = [' . strip_sgr($line) . ']');
            unlike($line, qr/\n/,
                "AC-B3 (cols=$cols, $label): the first line carries no embedded newline -- the row is truncated, never wrapped");
        }
    }

    # AC-B4 / AC-B5 -- drop order. The git segment is under this oracle's
    # control (the branch comes from the shim), so "segments are dropped
    # before fields are elided" is asserted against it directly.
    my %plans_at;
    my %git_at;
    my %elided_at;
    for my $cols (@WIDTHS) {
        my $line = statusline_line1(payload_for(current_dir => $long),
            cols => $cols, sandbox => 0, toplevel => $top,
            branch => 'main', home => $SEEDED_HOME, data => $SEEDED_DATA);
        my $vis  = strip_sgr($line);
        $plans_at{$cols}  = ($vis =~ /\b(?:blueprints|todos)\b/) ? 1 : 0;
        $git_at{$cols}    = (index($vis, 'main') >= 0) ? 1 : 0;
        my $proj = field_at($line, 1);
        my $cwd  = field_at($line, 2);
        $elided_at{$cols} = ((defined($proj) && $proj =~ /[<>]/) || (defined($cwd) && $cwd =~ /[<>]/)) ? 1 : 0;

        ok(!$plans_at{$cols} || $git_at{$cols},
            "AC-B4 (cols=$cols): the plans segment never survives on a row the git segment has been dropped from")
            or diag("  first line = [$vis]");
        ok(!$elided_at{$cols} || !$plans_at{$cols},
            "AC-B5 (cols=$cols): no field is elided while the plans segment is still on the row")
            or diag("  first line = [$vis]");
        ok(!$elided_at{$cols} || !$git_at{$cols},
            "AC-B5 (cols=$cols): no field is elided while the git segment is still on the row -- segments yield first")
            or diag("  first line = [$vis]");
    }
    {
        my @desc = sort { $b <=> $a } @WIDTHS;
        my $monotone = 1;
        for my $i (1 .. $#desc) {
            $monotone = 0 if $plans_at{ $desc[$i] } && !$plans_at{ $desc[$i - 1] };
        }
        ok($monotone,
            'AC-B4: plans presence is monotone in width -- a segment dropped at a wider row never reappears at a narrower one');
        diag('  AC-B4: plans segment rendered at widths: '
            . join(',', grep { $plans_at{$_} } @WIDTHS) . ' (none listed means the seeded fixture produced no plans segment)');
    }

    # AC-B6 -- pathological width. The symmetry guarantee is explicitly NOT
    # asserted here (spec S2.4.2: below the marker slot it is void by
    # declaration); the budget invariant still is.
    {
        my ($out, $rc) = run_statusline(payload_for(current_dir => $long),
            cols => 8, sandbox => 1, toplevel => $top, branch => 'main');
        my $line = first_line($out);
        is($rc, 0, 'AC-B6 (cols=8): the process still exits normally at a pathological width');
        ok(length(strip_sgr($line)) >= 1, 'AC-B6 (cols=8): a first line is still printed');
        my $cost = row_cost($line);
        ok($cost <= 8, "AC-B6 (cols=8): the surviving row costs $cost, within the 8-column budget")
            or diag('  first line = [' . strip_sgr($line) . ']');
        my $vis = strip_sgr($line);
        # t06 AMENDMENT (blueprint Decision 8, package t06-statusline-marker,
        # 2026-08-19): with a leading Decision-3 glyph now the first character
        # of the marker field, the pre-Decision-3 pin ("first surviving
        # character is the head of the literal word SANDBOX") is superseded --
        # the first surviving character is the sandbox glyph itself. The
        # INTENT ("what survives at cols=8 belongs to the marker, not
        # something else") is preserved: this still fails if the marker
        # vanishes entirely, or if anything other than the declared
        # Decision-3 sandbox glyph (hollow circle, U+25CB) survives first.
        my $t06_sandbox_glyph = encode('UTF-8', chr(0x25CB));
        ok(length($vis) && substr($vis, 0, length($t06_sandbox_glyph)) eq $t06_sandbox_glyph,
            'AC-B6 (cols=8): whatever survives begins with the declared sandbox glyph (Decision 3), which now leads the marker field')
            or diag("  first line = [$vis]");
    }
}

# ===========================================================================
# AC-N -- the project name inside a sandbox.
#
# The project is bind-mounted at /project, so in-container `git rev-parse
# --show-toplevel` returns `/project` and basename() yields the literal word
# "project" -- for EVERY project on the machine. The field whose whole job is to
# say which project you are in was the one field that could never say it.
#
# The launcher writes the real name to claude-home/project-name, which is a live
# bind mount and therefore lands at $HOME/.claude/project-name immediately, in
# containers created before the fix as well. An env var would have been the
# obvious choice and the wrong one -- `podman create` bakes env at creation, so
# it would have fixed only containers made afterwards.
# ===========================================================================
{
    my $home = tempdir(CLEANUP => 1);
    mkdir "$home/.claude";

    # Without the name file we can only report what the mount says. Asserting
    # this pins WHY the file is needed rather than leaving it as decoration.
    {
        my $line = statusline_line1(payload_for(current_dir => '/project/plugins'),
                        cols => 200, sandbox => 1, toplevel => '/project', home => $home);
        is(field_at($line, 1), 'project',
            'AC-N0: with no name file the mount point is all there is -- the defect, reproduced');
    }

    spew_raw("$home/.claude/project-name", "gsa-superapp\n");
    {
        my $line = statusline_line1(payload_for(current_dir => '/project/plugins'),
                        cols => 200, sandbox => 1, toplevel => '/project', home => $home);
        is(field_at($line, 1), 'gsa-superapp',
            'AC-N1: the name file supplies the real project name in place of the mount point');
    }

    # Non-ASCII survives the round trip: this machine's paths carry them.
    spew_raw("$home/.claude/project-name", encode('UTF-8', "caf\x{e9}-app") . "\n");
    {
        my $line = statusline_line1(payload_for(current_dir => '/project'),
                        cols => 200, sandbox => 1, toplevel => '/project', home => $home);
        ok(index($line, encode('UTF-8', "caf\x{e9}-app")) >= 0,
            'AC-N2: a non-ASCII project name survives the file round trip unmangled')
            or diag('  first line = [' . strip_sgr($line) . ']');
    }

    # An empty or whitespace-only file must not blank the field.
    spew_raw("$home/.claude/project-name", "\n\n");
    {
        my $line = statusline_line1(payload_for(current_dir => '/project'),
                        cols => 200, sandbox => 1, toplevel => '/project', home => $home);
        is(field_at($line, 1), 'project',
            'AC-N3: an empty name file falls back rather than rendering an empty project field');
    }

    # Control bytes are scrubbed like every other display field read off disk.
    spew_raw("$home/.claude/project-name", "evil\nSECOND ROW\n");
    {
        my ($out) = run_statusline(payload_for(current_dir => '/project'),
                        cols => 200, sandbox => 1, toplevel => '/project', home => $home);
        my $line = first_line($out);
        is(field_at($line, 1), 'evilSECOND ROW',
            'AC-N4: an embedded newline is scrubbed, not honoured -- the file cannot inject an extra row');
        is(index(strip_sgr($line), "\n"), -1,
            'AC-N4: and no newline reaches the rendered row');
    }

    # The HOST must be untouched by all of this: there, the toplevel basename is
    # already right and the file does not exist.
    {
        my $line = statusline_line1(payload_for(current_dir => '/w/proj-alpha/x'),
                        cols => 200, sandbox => 0, toplevel => '/w/proj-alpha', home => $home);
        is(field_at($line, 1), 'proj-alpha',
            'AC-N5: on the host the name still comes from the git toplevel -- the fix is sandbox-shaped only');
    }
}

done_testing();
