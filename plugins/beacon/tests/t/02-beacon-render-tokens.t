#!/usr/bin/env perl
# =============================================================================
# t/02-beacon-render-tokens.t -- oracle File A for package 09-beacon-adopts-tokens
# (blueprint unified-tui-design-system).
#
# Groups: AC-S (source scans), AC-G (helpers), AC-R (the rich frame),
#         AC-D (the degraded render), AC-E (encoding).
#
# In-process only. No subprocess, no TTY, no exec. The spec's entry-point guard
# (`main() unless caller`) is what makes `require`ing the operator's own launcher
# safe -- so this file CHECKS FOR THAT GUARD IN THE SOURCE BEFORE requiring, and
# refuses to require without it. Requiring an unguarded claude-beacon.pl would
# run gather(), spawn beacon.pl against the operator's REAL vault, and could
# exit() out from under the harness.
#
# Written from the spec, against an implementation that does not exist yet.
# =============================================================================

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Spec ();
use Encode ();
use POSIX qw(strftime);

my $SCRIPT = File::Spec->catfile($Bin, '..', '..', 'scripts', 'claude-beacon.pl');

# ---------------------------------------------------------------------------
# Raw source, and the comment-blanked scan target.
#
# C-8(i): whole-line `#` comments are BLANKED (not deleted) before any scan, so
# the file may document its own reasoning -- including the escapes and hex it is
# forbidden to emit -- without the scan punishing it. Blanking rather than
# deleting keeps line numbers aligned so an offender can be located.
# ---------------------------------------------------------------------------
my $RAW = do {
    open my $fh, '<:raw', $SCRIPT or BAIL_OUT("cannot read $SCRIPT: $!");
    local $/;
    <$fh>;
};

sub t_blank_comments {
    my ($text) = @_;
    return join "\n", map { /^\s*#/ ? '' : $_ } split /\n/, $text, -1;
}

my $SRC = t_blank_comments($RAW);

# ---------------------------------------------------------------------------
# Detectors (spec AC-S). Built once, exercised against the real file AND against
# the two counter-fixtures of AC-S6 -- C-7: a detector that never fires is not
# evidence of anything.
#
# C-8(iii): \Q...\E does NOT interpolate escapes, so an ESC BYTE is found with
# index($s, chr(27)), never with qr/\Q\e...\E/. The regexes below deliberately
# match how an ESC is WRITTEN IN PERL SOURCE (backslash-e etc.), which is a
# different thing entirely.
# ---------------------------------------------------------------------------
my $ESC_SRC  = qr/(?:\\e|\\033|\\x\{?0*1[bB]\}?)/;
my $SGR_RE   = qr/$ESC_SRC\[[0-9;:?]*m/;
my $HEX_RE   = qr/\#[0-9A-Fa-f]{6}\b/;
my $PARAM_RE = qr/\b38;[25];\d/;
my $WIDE_RE  = qr/\\x\{([0-9A-Fa-f]{2,6})\}/;

# Block-based emoji predicate, mirrored from package 02 spec §2.6.1 (the same
# list t/64-theme-tokens.t uses). Deliberately an over-approximation.
sub t_is_emoji {
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

# t_detect($text) -> \%hit -- runs every detector over ALREADY-COMMENT-BLANKED
# text and reports which fired.
sub t_detect {
    my ($text) = @_;
    my @cps = map { hex $_ } ($text =~ /$WIDE_RE/g);
    return {
        sgr   => ($text =~ $SGR_RE)   ? 1 : 0,
        hex   => ($text =~ $HEX_RE)   ? 1 : 0,
        param => ($text =~ $PARAM_RE) ? 1 : 0,
        wide  => (grep { $_ >= 0x80 } @cps) ? 1 : 0,
        emoji => (grep { t_is_emoji($_) } @cps) ? 1 : 0,
    };
}

# t_locate($text, $re) -> "line N: <line>" for the first match, for diags.
sub t_locate {
    my ($text, $re) = @_;
    my @lines = split /\n/, $text, -1;
    for my $i (0 .. $#lines) {
        if ($lines[$i] =~ $re) {
            return sprintf('line %d: %s', $i + 1, $lines[$i]);
        }
    }
    return '(not located)';
}

# t_src_absent / t_src_present -- ok()-shaped source assertions. Deliberately
# NOT like()/unlike(): those dump the ENTIRE 600+-line source into the TAP diag
# on failure, which buries the finding. These report the offending line instead.
sub t_src_absent {
    my ($text, $re, $name) = @_;
    my $hit = ($text =~ $re) ? 1 : 0;
    ok(!$hit, $name . ($hit ? ' -- found at ' . t_locate($text, $re) : ''));
}

sub t_src_present {
    my ($text, $re, $name) = @_;
    ok(scalar($text =~ $re), $name);
}

# =============================================================================
# AC-S -- source scans (done criterion 1: a test fails on a raw SGR escape or
# hardcoded hex; done criterion 4: no emoji, glyphs from the shared table).
# Cheapest group; loads nothing.
# =============================================================================

subtest 'AC-S: source scans of claude-beacon.pl' => sub {
    # --- AC-S1: no raw SGR ---------------------------------------------------
    t_src_absent($SRC, $SGR_RE,
        'AC-S1: no raw SGR escape written in claude-beacon.pl source');
    is(index($RAW, chr(27)), -1,
        'AC-S1: no literal ESC byte (chr 27) anywhere in claude-beacon.pl');

    # --- AC-S2: no hardcoded colour -----------------------------------------
    t_src_absent($SRC, $HEX_RE,
        'AC-S2: no six-digit hex colour literal in claude-beacon.pl');
    t_src_absent($SRC, $PARAM_RE,
        'AC-S2: no SGR colour parameter (38;2;/38;5;) in claude-beacon.pl');

    # --- AC-S3: glyphs come from the shared table ---------------------------
    {
        my @lines = split /\n/, $SRC, -1;
        my ($bad_cp, $bad_line);
        LINE: for my $i (0 .. $#lines) {
            while ($lines[$i] =~ /$WIDE_RE/g) {
                my $cp = hex $1;
                if ($cp >= 0x80) { ($bad_cp, $bad_line) = ($cp, $i + 1); last LINE; }
            }
        }
        ok(!defined $bad_cp,
            'AC-S3: every \x{...} escape in claude-beacon.pl has a codepoint < 0x80'
            . (defined $bad_cp
               ? sprintf(' -- first offender U+%04X at line %d', $bad_cp, $bad_line)
               : ''));

        my ($byte_line, $byte_col);
        for my $i (0 .. $#lines) {
            if ($lines[$i] =~ /([^\x00-\x7F])/) {
                ($byte_line, $byte_col) = ($i + 1, ord($1));
                last;
            }
        }
        ok(!defined $byte_line,
            'AC-S3: claude-beacon.pl contains no byte >= 0x80'
            . (defined $byte_line
               ? sprintf(' -- first offender byte 0x%02X at line %d', $byte_col, $byte_line)
               : ''));
    }
    t_src_present($SRC, qr/Theme::glyph\(/,
        'AC-S3: claude-beacon.pl calls Theme::glyph( -- glyphs come from the shared table');

    # --- AC-S4: no emoji -----------------------------------------------------
    {
        my @cps = map { hex $_ } ($SRC =~ /$WIDE_RE/g);
        my @emoji = grep { t_is_emoji($_) } @cps;
        is(scalar(@emoji), 0,
            'AC-S4: no \x{...} codepoint in claude-beacon.pl falls in an emoji range'
            . (@emoji ? sprintf(' -- first U+%04X', $emoji[0]) : ''));
    }

    # --- AC-S5: no compile-time dependency on the sandbox plugin -------------
    t_src_absent($SRC, qr/^\s*use\s+(?:Theme|tui::)/m,
        'AC-S5: no compile-time `use Theme` / `use tui::...` -- the cross-plugin '
        . 'load is runtime and eval-guarded');

    # --- AC-R4 (source half): the breakpoint is never a literal (C-5) --------
    # Lives here rather than in AC-R because it is a source scan and shares the
    # comment-blanked $SRC. Decision 14: every width comparison against the
    # responsive breakpoint goes through tui::Layout, never through a bare 90.
    t_src_absent($SRC, qr/(?<![\w.\-])90(?![\w.])/,
        'AC-R4/C-5: no bare `90` token in claude-beacon.pl (Decision 14: the '
        . 'breakpoint comes from tui::Layout::BREAKPOINT_TWO_COL())');

    # --- AC-S6: every detector fires, and none over-fires (C-7) -------------
    my $tmp = tempdir(CLEANUP => 1);

    my $must_fire_path = File::Spec->catfile($tmp, 'must-fire.pl');
    {
        # Single-quoted heredoc so the backslashes survive into the fixture as
        # SOURCE TEXT -- these are how a violation is WRITTEN, not ESC bytes.
        my $fixture = <<'FIXTURE';
my $a = "\e[1m";
my $b = "\e[38;2;226;232;240m";
my $c = '#1E1E1E';
my $d = "\x{1F534}";
FIXTURE
        open my $fh, '>:raw', $must_fire_path or die "cannot write fixture: $!";
        print $fh $fixture;
        close $fh;
    }
    my $must_fire = do {
        open my $fh, '<:raw', $must_fire_path or die $!;
        local $/;
        t_blank_comments(<$fh>);
    };
    my $fire = t_detect($must_fire);
    ok($fire->{sgr},   'AC-S6: must-fire fixture -- the SGR detector fires');
    ok($fire->{hex},   'AC-S6: must-fire fixture -- the hex-colour detector fires');
    ok($fire->{param}, 'AC-S6: must-fire fixture -- the SGR-parameter detector fires');
    ok($fire->{wide},  'AC-S6: must-fire fixture -- the >= 0x80 escape scan flags \x{1F534}');
    ok($fire->{emoji}, 'AC-S6: must-fire fixture -- the emoji scan flags \x{1F534}');

    my $must_not_path = File::Spec->catfile($tmp, 'must-not-fire.pl');
    {
        my $fixture = <<'FIXTURE';
# palette note: #1E1E1E is the reference background
print "\e[?25l"; print "\e[H\e[J"; print "\e[K"; print "\e[2K";
my $s = Theme::sgr('accent');
FIXTURE
        open my $fh, '>:raw', $must_not_path or die "cannot write fixture: $!";
        print $fh $fixture;
        close $fh;
    }
    my $must_not = do {
        open my $fh, '<:raw', $must_not_path or die $!;
        local $/;
        t_blank_comments(<$fh>);
    };
    my $quiet = t_detect($must_not);
    ok(!$quiet->{sgr},
        'AC-S6: must-not-fire fixture -- cursor/erase escapes are NOT read as SGR');
    ok(!$quiet->{hex},
        'AC-S6: must-not-fire fixture -- a hex literal inside a whole-line comment is not flagged');
    ok(!$quiet->{param},
        'AC-S6: must-not-fire fixture -- no SGR-parameter false positive');
    ok(!$quiet->{wide},
        'AC-S6: must-not-fire fixture -- no >= 0x80 escape false positive');
    ok(!$quiet->{emoji},
        'AC-S6: must-not-fire fixture -- no emoji false positive');
};

# =============================================================================
# Loading claude-beacon.pl in-process -- and the safety interlock.
#
# Spec §2.9: every top-level statement that ACTS moves into `sub main`, and the
# file ends `main() unless caller; 1;`. That guard is the ONLY thing that makes
# `require`ing the operator's own launcher safe from a test: without it, the
# require would parse argv, stat beacon.pl, run gather() -- spawning beacon.pl
# against the operator's REAL vault -- and then exit() out from under the
# harness. So the guard is checked IN THE SOURCE first, and the require is
# skipped (with a failure, never a skip) if it is absent.
# =============================================================================

my $GUARD_RE  = qr/^\s*main\s*\(\s*\)\s+unless\s+caller\s*;/m;
my $HAS_GUARD = ($SRC =~ $GUARD_RE) ? 1 : 0;
my $LOADED    = 0;
my $LOAD_ERR  = '';

if ($HAS_GUARD) {
    my $abs = File::Spec->rel2abs($SCRIPT);
    $abs =~ s{\\}{/}g;
    $LOADED = eval { require $abs; 1 } ? 1 : 0;
    $LOAD_ERR = $@ if !$LOADED;
}

# The test's OWN access to the shared library. Established AFTER the require
# above, deliberately: pre-populating %INC with Theme/tui::* would make the
# script's own eval-guarded load succeed no matter where its __FILE__-derived
# path pointed, and AC-G1 would become vacuous.
my $SANDBOX_SCRIPTS = File::Spec->catdir($Bin, '..', '..', '..', 'sandbox', 'scripts');
my $LIB_OK = 0;
{
    if (-d $SANDBOX_SCRIPTS) {
        unshift @INC, $SANDBOX_SCRIPTS;
        $LIB_OK = eval {
            require Theme;
            require tui::Layout;
            require tui::Frame;
            require tui::Screen;
            1;
        } ? 1 : 0;
    }
}
BAIL_OUT("the test's own load of Theme/tui:: failed from $SANDBOX_SCRIPTS: $@")
    if !$LIB_OK;

# t_unavailable($label, @subs) -> 1 (having already recorded a failure) when the
# in-process assertions cannot run. Never skip(): a missing sub IS the missing
# behaviour this oracle exists to detect, so it must read as `not ok`.
sub t_unavailable {
    my ($label, @subs) = @_;
    if (!$HAS_GUARD) {
        fail("$label -- claude-beacon.pl carries no `main() unless caller` "
             . "entry-point guard (spec §2.9), so it cannot be required in-process");
        return 1;
    }
    if (!$LOADED) {
        my $e = $LOAD_ERR;
        $e =~ s/\s+\z//;
        fail("$label -- require of claude-beacon.pl failed: $e");
        return 1;
    }
    no strict 'refs';
    my @missing = grep { !defined &{"main::$_"} } @subs;
    if (@missing) {
        fail("$label -- claude-beacon.pl defines no " . join(', ', map { "$_()" } @missing));
        return 1;
    }
    return 0;
}

subtest 'AC-G: library-facing helpers' => sub {
    ok($HAS_GUARD,
        'AC-G: claude-beacon.pl ends with the `main() unless caller` entry-point '
        . 'guard (spec §2.9) -- without it nothing below can be loaded safely');

    # The spec's own precondition: BAIL_OUT if the file did not load, because
    # nothing after it can mean anything.
    my $have_frame_lines = $LOADED && do { no strict 'refs'; defined &main::frame_lines };
    ok($have_frame_lines,
        'AC-G: claude-beacon.pl loaded and defines frame_lines()');

    # --- AC-G1: the library actually loaded ---------------------------------
    if (!t_unavailable('AC-G1: tui_lib_ok() reports the shared library loaded', 'tui_lib_ok')) {
        my $ok = main::tui_lib_ok();
        is($ok, 1,
            'AC-G1: tui_lib_ok() is 1 -- the __FILE__-derived path found the shared library');
        diag("AC-G1: tui_lib_ok() is 0. The sandbox plugin IS present in this repo at "
             . "plugins/sandbox/scripts, so a 0 means claude-beacon.pl's __FILE__-derived "
             . "path is wrong -- and every rich-path assertion below would silently be "
             . "testing the DEGRADED path instead.") if !$ok;
    }

    # --- AC-G2: glyph_text sources from Theme -------------------------------
    if (!t_unavailable('AC-G2: glyph_text() sources from Theme', 'glyph_text')) {
        my $got  = main::glyph_text('sep.dot', '-');
        my $want = Encode::decode('UTF-8', Theme::glyph('sep.dot'));
        is($got, $want,
            'AC-G2: glyph_text("sep.dot","-") is Theme::glyph("sep.dot") decoded');
        is(length($got), 1,
            'AC-G2: glyph_text("sep.dot","-") is exactly one CHARACTER (decoded, not bytes)');
        is(main::glyph_text('no.such.glyph', '?'), '?',
            'AC-G2: an unknown glyph name falls back to the ASCII fallback');
    }

    # --- AC-G3: glyph_text degrades -----------------------------------------
    if (!t_unavailable('AC-G3: glyph_text() degrades to ASCII', 'glyph_text')) {
        no strict 'refs';
        local ${'main::TUI_LIB_OK'} = 0;
        my %cases = (
            'sep.dot'     => '-',
            'cursor'      => '>',
            'scroll.up'   => '^',
            'scroll.down' => 'v',
            'rule.h'      => '-',
        );
        my @bad;
        for my $name (sort keys %cases) {
            my $fb  = $cases{$name};
            my $got = main::glyph_text($name, $fb);
            push @bad, "$name -> " . (defined $got ? "'$got'" : 'undef')
                if !defined $got || $got ne $fb || $got !~ /\A[\x20-\x7E]*\z/;
        }
        is(scalar(@bad), 0,
            'AC-G3: with TUI_LIB_OK false every glyph_text() returns its pure-ASCII fallback'
            . (@bad ? ' -- offenders: ' . join('; ', @bad) : ''));
    }

    # --- AC-G4: capability ---------------------------------------------------
    if (!t_unavailable('AC-G4: terminal_capability() / sgr_reset()',
                       'terminal_capability', 'sgr_reset')) {
        is(Theme::detect_capability({ NO_COLOR => '' }), 'none',
            'AC-G4: Theme::detect_capability honours NO_COLOR (the pure form)');
        {
            local %ENV = (%ENV, NO_COLOR => '1');
            Theme::_reset_capability_memo();
            is(main::terminal_capability(), 'none',
                'AC-G4: with NO_COLOR set, terminal_capability() is "none"');
        }
        Theme::_reset_capability_memo();

        {
            no strict 'refs';
            local ${'main::TUI_LIB_OK'} = 0;
            is(main::terminal_capability(), 'none',
                'AC-G4: with TUI_LIB_OK false, terminal_capability() is "none"');
            is(main::sgr_reset(), '',
                'AC-G4: with TUI_LIB_OK false, sgr_reset() is the empty string');
        }
        is(main::sgr_reset(), Theme::reset(),
            'AC-G4: with the library loaded, sgr_reset() is Theme::reset()');
    }

    # --- AC-G5: as_bytes -----------------------------------------------------
    if (!t_unavailable('AC-G5: as_bytes()', 'as_bytes')) {
        # A genuinely decoded string -- see the F3 note on why a bare \x{00E9}
        # literal is NOT one.
        is(main::as_bytes(Encode::decode('UTF-8', "caf\xC3\xA9")), "caf\xC3\xA9",
            'AC-G5: as_bytes() encodes a DECODED string to UTF-8 bytes');
        is(main::as_bytes("caf\xC3\xA9"), "caf\xC3\xA9",
            'AC-G5: as_bytes() returns an already-byte string unchanged');
        is(main::as_bytes(undef), '',
            'AC-G5: as_bytes(undef) is the empty string');
        is(main::as_bytes(Encode::decode('UTF-8', "zh\xE4\xB8\xADwen")), "zh\xE4\xB8\xADwen",
            'AC-G5: as_bytes() encodes a decoded multi-byte character too');
    }
};

# =============================================================================
# Fixtures F1-F4 (spec §4). Built fresh by each accessor so that a render which
# mutates a record cannot leak that mutation into the next assertion -- AC-E2.3
# depends on being able to see such a mutation, not on being protected from it.
# =============================================================================

my $ESC = chr(27);

sub t_ts {
    my ($secs_ago) = @_;
    return strftime('%Y-%m-%dT%H:%M:%SZ', gmtime(time() - $secs_ago));
}

sub t_uuid { return sprintf('%08x-1111-4222-8333-%012x', $_[0] + 1, $_[0] + 1); }

# F1 -- three records: a labelled host beacon, a summary-only sandbox beacon,
# and one with every display field missing.
sub F1 {
    return [
        { session_id => t_uuid(1), project_slug => 'ccpraxis', label => 'blueprint work',
          summary => undef, scope => 'host',    cwd => 'C:/Development/ccpraxis',
          last_active_at => t_ts(2 * 3600) },
        { session_id => t_uuid(2), project_slug => 'other', label => undef,
          summary => 'no label here', scope => 'sandbox', cwd => 'C:/tmp/other',
          host_project_path => 'C:/tmp/other', last_active_at => t_ts(24 * 3600) },
        { session_id => t_uuid(3), project_slug => undef, label => undef, summary => undef,
          scope => 'host', cwd => undef, last_active_at => undef },
    ];
}

# F2 -- forty records, so the viewport must scroll at any realistic height.
sub F2 {
    return [ map {
        { session_id => t_uuid(100 + $_), project_slug => sprintf('p%02d', $_),
          label => sprintf('project %02d', $_), summary => undef, scope => 'host',
          cwd => "C:/w/p$_", last_active_at => t_ts(60 * ($_ + 1)) }
    } 0 .. 39 ];
}

# F3 -- accented Latin.
#
# The label is built through Encode::decode, NOT as a bare "caf\x{00E9}" literal,
# and the distinction is load-bearing rather than stylistic. §2.7's table says a
# record value arrives "out of decode_json" as DECODED characters, and a string
# perl actually decoded carries the UTF8 flag. A bare \x{00E9} literal in a
# non-`use utf8` source file does NOT: every codepoint fits in a byte, so perl
# stores it flag-off, and it is then indistinguishable from raw Latin-1 bytes --
# the exact ambiguity §2.7 warns about. Using the flag-off form here would test
# an input the launcher never actually receives.
my $E_ACUTE_LABEL = Encode::decode('UTF-8', "caf\xC3\xA9 andr\xC3\xA9");

sub F3 {
    return [
        { session_id => t_uuid(7), project_slug => 'cafe', label => $E_ACUTE_LABEL,
          summary => undef, scope => 'host',
          cwd => Encode::decode('UTF-8', "C:/Users/Andr\xC3\xA9/work"),
          last_active_at => t_ts(90) },
    ];
}

# F3C -- the AC-E2.5 counter-fixture: a character whose display width the layout
# library genuinely cannot claim.
sub F3C {
    return [
        { session_id => t_uuid(8), project_slug => 'cjk', label => "zh\x{4e2d}wen",
          summary => undef, scope => 'host', cwd => 'C:/w/cjk',
          last_active_at => t_ts(90) },
    ];
}

# F4 -- hostile input: an injected SGR sequence and a NUL byte.
sub F4 {
    return [
        { session_id => t_uuid(9), project_slug => "a\x00b",
          label => "evil${ESC}[31m red ${ESC}[0m", summary => undef,
          scope => 'host', cwd => 'C:/w/evil', last_active_at => t_ts(30) },
    ];
}

# t_strip_sgr -- the test's own two-line stripper, built from chr(27) rather
# than a \Q..\E pattern (C-8(iii): \Q...\E does not interpolate escapes).
sub t_strip_sgr {
    my ($s) = @_;
    return '' if !defined $s;
    $s =~ s/\Q$ESC\E\[[0-9;:?]*[A-Za-z]//g;
    return $s;
}

# t_bad_roles(\@cells, \%known) -> the roles that are NOT keys of %known.
# The AC-R6 defect detector: a legacy role name resolves through hard-coded
# escapes that honour neither NO_COLOR nor the terminal capability.
sub t_bad_roles {
    my ($cells, $known) = @_;
    my @bad;
    for my $c (@$cells) {
        next if ref($c) ne 'HASH';
        push @bad, (defined $c->{role} ? $c->{role} : '(undef)')
            if !defined $c->{role} || !$known->{ $c->{role} };
        my $spans = ref($c->{spans}) eq 'ARRAY' ? $c->{spans} : [];
        for my $sp (@$spans) {
            next if ref($sp) ne 'HASH';
            push @bad, (defined $sp->{role} ? $sp->{role} : '(undef)')
                if !defined $sp->{role} || !$known->{ $sp->{role} };
        }
    }
    return @bad;
}

# The §2.4 role vocabulary (C-4). A SUBSET check, never a key-set equality --
# Decision 15 forbids whole-shape pins.
my %ROLE_VOCAB = map { $_ => 1 } qw(
    accent text.primary text.muted text.faint
    state.ok state.warn state.crit rule state.idle
);

# =============================================================================
# AC-R -- the rich frame (done criterion 1: renders through tui/ + Theme.pm;
# done criterion 3: reflows at narrow widths without overflow).
# =============================================================================

subtest 'AC-R: the rich frame' => sub {
    my @NEED = qw(frame_lines beacon_screen footer_text glyph_text as_bytes MAX_FRAME_COLS);

    if (t_unavailable('AC-R: the rich render vocabulary', @NEED)) {
        return;
    }

    my $MAX = main::MAX_FRAME_COLS();
    is($MAX, 120, 'AC-R/§2.1: MAX_FRAME_COLS is 120 (the existing readability cap)');

    # --- AC-R1: exact width, swept 20..200 ----------------------------------
    for my $rows (6, 24, 40) {
        my $violations = 0;
        my $first;
        for my $w (20 .. 200) {
            my $want  = $w < $MAX ? $w : $MAX;
            my $lines = main::frame_lines(F2(), { cursor => 17 }, $rows, $w, 'truecolor');
            for my $i (0 .. $#$lines) {
                my $got = tui::Layout::display_width(
                    main::as_bytes(t_strip_sgr($lines->[$i])));
                next if $got == $want;
                $violations++;
                $first = sprintf('W=%d line=%d measured=%d want=%d', $w, $i, $got, $want)
                    if !defined $first;
            }
        }
        is($violations, 0,
            "AC-R1: at rows=$rows every rendered row is exactly min(W, MAX_FRAME_COLS) "
            . "display columns for every W in 20..200"
            . (defined $first ? " -- first offender: $first" : ''));
    }

    # --- AC-R2: the frame's height is the terminal's, minus the reserved row -
    for my $rows (6, 24) {
        my $lines = main::frame_lines(F1(), {}, $rows, 100, 'truecolor');
        is(scalar(@$lines), $rows - 1,
            "AC-R2: at rows=$rows the frame is $rows - RESERVED_ROWS lines, leaving the "
            . "terminal's bottom row for inline_confirm");
    }

    # --- AC-R3: content reach -----------------------------------------------
    {
        my $lines = main::frame_lines(F1(), {}, 24, 100, 'truecolor');
        my $text  = join("\n", map { t_strip_sgr($_) } @$lines);
        for my $needle ('ccpraxis', 'blueprint work', 'no label here',
                        '(unlabeled)', 'sandbox', 'host') {
            ok(index($text, $needle) >= 0,
                "AC-R3: the rendered frame carries '$needle'");
        }
        like($text, qr/\d+[smhd]\s+ago|just now/,
            'AC-R3: the rendered frame carries a relative-age token');
    }

    # --- AC-R4: the footer compacts when the full legend does not FIT --------
    #
    # RE-POINTED by the driver (see the package ledger). This block previously
    # asserted that tui::Layout::BREAKPOINT_TWO_COL() governed the legend. The
    # claim is kept in full -- the footer compacts at widths that cannot hold
    # it, and never overflows -- but its SUBJECT moves from the two-column
    # breakpoint to the actual fit.
    #
    # Why: the breakpoint is 90, so keying the legend to it collapsed the
    # footer to the compact form at 80 columns, the most common terminal width,
    # where the full legend fits with room to spare and where the pre-package
    # implementation showed it in full. The spec's stated rationale for
    # compacting is that at narrow widths the quit key should not be what gets
    # truncated away -- an appeal to fit, which at 80 columns does not apply.
    # The implementation followed the spec's letter and defeated its reason.
    #
    # The boundary is DERIVED from the legend's own rendered width rather than
    # written as a number, so this stays true if the legend text changes.
    {
        my $full  = main::footer_text(120);
        my $needs = tui::Layout::display_width(main::as_bytes($full));
        my $comp  = main::footer_text($needs - 1);
        isnt($full, $comp,
            'AC-R4: the footer legend differs across the width the full legend needs');
        is(main::footer_text($needs), $full,
            'AC-R4: at exactly the width the full legend needs, it is still shown in full');
        isnt(main::footer_text($needs - 1), $full,
            'AC-R4: one column narrower than it needs, the footer compacts');
        is(main::footer_text(80), $full,
            'AC-R4: at 80 columns -- the common terminal width, comfortably wider than '
          . 'the full legend -- the footer is NOT compacted (regression pin: keying this '
          . 'to the 90-column two-column breakpoint hid the key legend at the width most '
          . 'operators actually use)');
        for my $pair (['full', $full], ['compact', $comp]) {
            my ($what, $s) = @$pair;
            my @missing = grep { index($s, $_) < 0 } qw(enter u r q);
            is(scalar(@missing), 0,
                "AC-R4: the $what footer names enter, u, r and q"
                . (@missing ? ' -- missing: ' . join(',', @missing) : ''));
        }
        my ($over, $first) = (0, undef);
        for my $w (20 .. 200) {
            my $cap_w = $w < 120 ? $w : 120;
            $cap_w = 1 if $cap_w < 1;
            my $got = tui::Layout::display_width(main::as_bytes(main::footer_text($w)));
            next if $got <= $cap_w;
            $over++;
            $first = "W=$w measured=$got limit=$cap_w" if !defined $first;
        }
        is($over, 0,
            'AC-R4: the footer never exceeds its width budget for any W in 20..200'
            . (defined $first ? " -- first offender: $first" : ''));
    }

    # --- AC-R5: selection is visible without colour --------------------------
    {
        my $cursor_glyph = main::glyph_text('cursor', '>');
        for my $case ([1, 'other'], [0, 'ccpraxis']) {
            my ($cur, $expect) = @$case;
            my $lines = main::frame_lines(F1(), { cursor => $cur }, 24, 100, 'none');
            my @marked = grep { index(t_strip_sgr($_), $cursor_glyph) >= 0 } @$lines;
            is(scalar(@marked), 1,
                "AC-R5: at cap 'none' with cursor=$cur exactly one row carries the cursor glyph");
            ok(scalar(@marked) == 1 && index(t_strip_sgr($marked[0]), $expect) >= 0,
                "AC-R5: the cursor-marked row at cursor=$cur is the '$expect' row");
        }
    }

    # --- AC-R6: roles reach the paint, and only Theme roles do ---------------
    {
        my %known = map { $_ => 1 } keys %{ Theme::roles() };
        my $screen = main::beacon_screen(F1(), { cursor => 0 }, 24, 100);
        my $cells  = tui::Screen::compose($screen, 23, 100);
        my @bad    = t_bad_roles($cells, \%known);
        is(scalar(@bad), 0,
            'AC-R6: every composed span carries a role that is a key of Theme::roles()'
            . (@bad ? ' -- offenders: ' . join(', ', sort keys %{{ map { $_ => 1 } @bad }}) : ''));

        my @outside = t_bad_roles($cells, \%ROLE_VOCAB);
        is(scalar(@outside), 0,
            'AC-R6/C-4: every composed span role is drawn from the §2.4 vocabulary'
            . (@outside ? ' -- offenders: '
               . join(', ', sort keys %{{ map { $_ => 1 } @outside }}) : ''));

        # Counter-fixture: the walker must be able to SEE a bad role, or the two
        # assertions above are worth nothing.
        my @caught = t_bad_roles(
            [ { role => 'panel-title',
                spans => [ { text => 'x', role => 'panel-title' } ] } ],
            \%known);
        ok(scalar(@caught) > 0,
            'AC-R6 counter-fixture: the role walker flags a hand-built '
            . "'panel-title' cell (a legacy name Theme does not define)");
    }

    # --- AC-R7: NO_COLOR / capability degrades the paint ---------------------
    {
        my $none = join('', @{ main::frame_lines(F1(), {}, 24, 100, 'none') });
        unlike($none, qr/38;[25];/,
            "AC-R7: at cap 'none' no truecolor/256 colour parameter is emitted");
        unlike($none, qr/\Q$ESC\E\[(?:3[0-79]|9[0-7]|4[0-79]|10[0-7])(?:;|m)/,
            "AC-R7: at cap 'none' no basic colour SGR parameter is emitted either");

        my $rich   = join('', @{ main::frame_lines(F1(), {}, 24, 100, 'truecolor') });
        my $accent = Theme::sgr('accent', 'truecolor');
        ok(length($accent) && index($rich, $accent) >= 0,
            "AC-R7: at cap 'truecolor' the frame carries Theme::sgr('accent','truecolor')");
    }

    # --- AC-R8: scrolling ----------------------------------------------------
    {
        my $up   = main::glyph_text('scroll.up', '^');
        my $down = main::glyph_text('scroll.down', 'v');

        my $top = join("\n", map { t_strip_sgr($_) }
                       @{ main::frame_lines(F2(), { cursor => 0 }, 12, 100, 'truecolor') });
        ok(index($top, 'p00') >= 0, 'AC-R8: at cursor 0 the window contains p00');
        ok(index($top, 'p39') <  0, 'AC-R8: at cursor 0 the window does NOT reach p39');
        ok(index($top, 'of 40') >= 0,
            'AC-R8: at cursor 0 the summary line reports the total (40)');
        ok(index($top, $down) >= 0,
            'AC-R8: at cursor 0 the summary line marks that rows are hidden BELOW');

        my $bot = join("\n", map { t_strip_sgr($_) }
                       @{ main::frame_lines(F2(), { cursor => 39 }, 12, 100, 'truecolor') });
        ok(index($bot, 'p39') >= 0, 'AC-R8: at cursor 39 the window contains p39');
        ok(index($bot, 'p00') <  0, 'AC-R8: at cursor 39 the window does NOT reach p00');
        ok(index($bot, 'of 40') >= 0,
            'AC-R8: at cursor 39 the summary line reports the total (40)');
        ok(index($bot, $up) >= 0,
            'AC-R8: at cursor 39 the summary line marks that rows are hidden ABOVE');

        my ($missing, $first_missing) = (0, undef);
        for my $c (0 .. 39) {
            my $t = join("\n", map { t_strip_sgr($_) }
                         @{ main::frame_lines(F2(), { cursor => $c }, 12, 100, 'truecolor') });
            next if index($t, sprintf('p%02d', $c)) >= 0;
            $missing++;
            $first_missing = $c if !defined $first_missing;
        }
        is($missing, 0,
            'AC-R8: the cursor row is inside the rendered window for every cursor in 0..39'
            . (defined $first_missing ? " -- first absent at cursor $first_missing" : ''));
    }

    # --- AC-R9: hostile input never escapes ----------------------------------
    {
        my $lines = main::frame_lines(F4(), {}, 24, 100, 'truecolor');
        my @injected = grep { index($_, '31m') >= 0 } @$lines;
        is(scalar(@injected), 0,
            'AC-R9: the injected colour sequence survives nowhere in the rendered frame');
        my @nuls = grep { index($_, "\x00") >= 0 } @$lines;
        is(scalar(@nuls), 0, 'AC-R9: no rendered line carries a NUL byte');
        is(scalar(@$lines), 23,
            'AC-R9: the frame still composes to its full height with hostile input');
    }

    # --- AC-R10: banner surfacing --------------------------------------------
    {
        for my $case (['Unbeacon failed: boom', 'state.crit'], ['Removed.', 'text.muted']) {
            my ($msg, $role) = @$case;
            my %state = (cursor => 0, status => $msg, status_role => $role);
            my $lines = main::frame_lines(F1(), \%state, 24, 100, 'truecolor');
            my $text  = join("\n", map { t_strip_sgr($_) } @$lines);
            ok(index($text, $msg) >= 0, "AC-R10: the frame surfaces the status '$msg'");

            my $screen = main::beacon_screen(F1(), \%state, 24, 100);
            is($screen->{banner_role}, $role,
                "AC-R10: the screen's banner_role for '$msg' is $role");

            my $cells = tui::Screen::compose($screen, 23, 100);
            my @carrying = grep {
                ref($_) eq 'HASH' && defined $_->{text}
                && index(Encode::decode('UTF-8', $_->{text}), $msg) >= 0
            } @$cells;
            my @wrong_role = grep { (defined $_->{role} ? $_->{role} : '') ne $role } @carrying;
            ok(scalar(@carrying) >= 1 && !@wrong_role,
                "AC-R10: the composed banner cell carrying '$msg' has role $role");
        }
    }
};

# F3A -- F3 with every accented letter replaced by its unaccented ASCII twin.
# AC-E2.2's yardstick: the two must lay out identically.
sub F3A {
    return [
        { session_id => t_uuid(7), project_slug => 'cafe', label => 'cafe andre',
          summary => undef, scope => 'host', cwd => 'C:/Users/Andre/work',
          last_active_at => t_ts(90) },
    ];
}

# =============================================================================
# AC-D -- the degraded render (done criterion 1's degrade path: the cross-plugin
# load may not be fatal; done criterion 3).
# =============================================================================

subtest 'AC-D: the degraded (plain) render' => sub {
    my @NEED = qw(frame_lines MAX_FRAME_COLS);
    return if t_unavailable('AC-D: the degraded render', @NEED);

    my $MAX = main::MAX_FRAME_COLS();
    my $bp  = tui::Layout::BREAKPOINT_TWO_COL();
    # Widths straddling the responsive breakpoint, named through tui::Layout
    # rather than as a literal (Decision 14 / C-5).
    my @WIDTHS = (20, 40, $bp - 1, $bp, 120, 200);

    no strict 'refs';
    local ${'main::TUI_LIB_OK'} = 0;

    # --- AC-D1: no escapes at all -------------------------------------------
    # Restricted to the pure-ASCII fixtures F1/F2, per the spec's own carve-out:
    # record text may carry whatever the record carried (AC-E2.4 covers that).
    {
        my ($esc_hits, $nonascii_hits, $first) = (0, 0, undef);
        for my $fx (['F1', \&F1], ['F2', \&F2]) {
            for my $rows (6, 24) {
                for my $cols (@WIDTHS) {
                    my $lines = main::frame_lines($fx->[1]->(), { cursor => 0 },
                                                  $rows, $cols, 'truecolor');
                    for my $i (0 .. $#$lines) {
                        if (index($lines->[$i], $ESC) >= 0) {
                            $esc_hits++;
                            $first = "$fx->[0] rows=$rows cols=$cols line=$i (ESC)"
                                if !defined $first;
                        }
                        if ($lines->[$i] !~ /\A[\x20-\x7E]*\z/) {
                            $nonascii_hits++;
                            $first = "$fx->[0] rows=$rows cols=$cols line=$i (non-ASCII)"
                                if !defined $first;
                        }
                    }
                }
            }
        }
        is($esc_hits, 0,
            'AC-D1: the degraded frame contains no ESC byte at any size'
            . (defined $first ? " -- first offender: $first" : ''));
        is($nonascii_hits, 0,
            'AC-D1: every degraded line built from ASCII fixtures is pure printable ASCII'
            . (defined $first ? " -- first offender: $first" : ''));
    }

    # --- AC-D2: no overflow --------------------------------------------------
    {
        my ($over, $first) = (0, undef);
        for my $fx (['F1', \&F1], ['F2', \&F2]) {
            for my $rows (6, 24) {
                for my $cols (@WIDTHS) {
                    my $limit = $cols < $MAX ? $cols : $MAX;
                    my $lines = main::frame_lines($fx->[1]->(), { cursor => 0 },
                                                  $rows, $cols, 'truecolor');
                    for my $i (0 .. $#$lines) {
                        my $len = length($lines->[$i]);
                        next if $len <= $limit;
                        $over++;
                        $first = "$fx->[0] rows=$rows cols=$cols line=$i len=$len limit=$limit"
                            if !defined $first;
                    }
                }
            }
        }
        is($over, 0,
            'AC-D2: no degraded line exceeds min(cols, MAX_FRAME_COLS) CHARACTERS (C-10)'
            . (defined $first ? " -- first offender: $first" : ''));
    }

    # --- AC-D3: degradation is observable ------------------------------------
    {
        my $lines = main::frame_lines(F1(), { cursor => 0 }, 24, 100, 'truecolor');
        my $last  = @$lines ? $lines->[-1] : '';
        like($last, qr/\Q [plain render]\E\z/,
            'AC-D3: the degraded frame\'s last line ends with the [plain render] marker '
            . '-- degradation is observable without a warn painting over the frame');
    }

    # --- AC-D4: the list still lists -----------------------------------------
    {
        my $t1 = join("\n", @{ main::frame_lines(F1(), { cursor => 0 }, 24, 100, 'truecolor') });
        for my $needle ('ccpraxis', 'blueprint work', 'sandbox', 'host') {
            ok(index($t1, $needle) >= 0,
                "AC-D4: the degraded frame still carries '$needle'");
        }
        my $t2 = join("\n", @{ main::frame_lines(F2(), { cursor => 39 }, 24, 100, 'truecolor') });
        ok(index($t2, 'p39') >= 0,
            'AC-D4: the degraded frame still follows the cursor to p39');
    }
};

# AC-D3's other half -- asserted OUTSIDE the TUI_LIB_OK=0 block, because it is a
# claim about the RICH frame.
subtest 'AC-D3: the [plain render] marker is absent from the rich frame' => sub {
    return if t_unavailable('AC-D3 (rich half)', 'frame_lines');
    my $lines = main::frame_lines(F1(), { cursor => 0 }, 24, 100, 'truecolor');
    my @marked = grep { index($_, '[plain render]') >= 0 } @$lines;
    is(scalar(@marked), 0,
        'AC-D3: no line of the RICH frame carries the [plain render] marker');
};

# =============================================================================
# AC-E -- encoding (C-10). §2.7, as AMENDED by the driver on 2026-08-08:
# tui::Frame::safe passes U+00A0..U+024F through as of 17693a6, so accented
# Latin now renders INTACT. Asserted in the POSITIVE form deliberately: the
# failure mode of omitting the encode-on-the-way-in is a SILENT 'caf? andr?'
# with no error raised anywhere, which an absence-of-'?' assertion would miss.
# =============================================================================

subtest 'AC-E: encoding' => sub {
    return if t_unavailable('AC-E: encoding', 'frame_lines', 'sanitize_display');

    # --- AC-E1: no double encoding -------------------------------------------
    {
        my $lines  = main::frame_lines(F1(), {}, 24, 100, 'none');
        my $joined = join('', @$lines);
        my $bytes  = Encode::encode('UTF-8', $joined);

        my $rule = Theme::glyph('rule.h');
        ok(defined $rule && index($bytes, $rule) >= 0,
            'AC-E1: the frame\'s bytes contain Theme::glyph("rule.h") exactly once encoded '
            . '-- the panel rule survived the decode/print round trip');
        is(index($bytes, "\xC3\x83"), -1,
            'AC-E1: no \xC3\x83 double-encoding signature in the frame');
        is(index($bytes, "\xC3\x82"), -1,
            'AC-E1: no \xC3\x82 double-encoding signature in the frame');

        my $not_decoded = 0;
        for my $l (@$lines) {
            my $rt = eval { Encode::decode('UTF-8', Encode::encode('UTF-8', $l)) };
            $not_decoded++ if !defined $rt || $rt ne $l;
        }
        is($not_decoded, 0,
            'AC-E1: every line frame_lines returns is a DECODED character string');
    }

    # --- AC-E2.1: accented Latin survives the frame, INTACT ------------------
    {
        my $lines = main::frame_lines(F3(), { cursor => 0 }, 24, 100, 'truecolor');
        my $text  = join("\n", map { t_strip_sgr($_) } @$lines);
        ok(index($text, $E_ACUTE_LABEL) >= 0,
            'AC-E2.1: the rich frame carries "caf\x{00E9} andr\x{00E9}" INTACT '
            . '(tui::Frame::safe passes U+00A0..U+024F through as of 17693a6; a '
            . '"caf? andr?" here means the encode-on-the-way-in of §2.7 was omitted)');
    }

    # --- AC-E2.2: field width is preserved -----------------------------------
    {
        my $acc = join("\n", map { t_strip_sgr($_) }
                       @{ main::frame_lines(F3(),  { cursor => 0 }, 24, 100, 'none') });
        my $asc = join("\n", map { t_strip_sgr($_) }
                       @{ main::frame_lines(F3A(), { cursor => 0 }, 24, 100, 'none') });
        my $folded = $acc;
        $folded =~ s/\x{00E9}/e/g;
        is($folded, $asc,
            'AC-E2.2: the accented render is character-for-character the unaccented '
            . 'render once the accents are folded -- identical field widths, identical '
            . 'truncation, no substitution');
    }

    # --- AC-E2.3: rendering mutates no record --------------------------------
    {
        my $f3    = F3();
        my $label = $f3->[0]{label};
        my $sid   = $f3->[0]{session_id};
        main::frame_lines($f3, { cursor => 0 }, 24, 100, 'truecolor');
        is($f3->[0]{label}, $label,
            'AC-E2.3: rendering leaves the record\'s label unchanged');
        is($f3->[0]{session_id}, $sid,
            'AC-E2.3: rendering leaves the record\'s session_id unchanged '
            . '(§2.6 rule 8: no rendered value ever reaches a subprocess)');
    }

    # --- AC-E2.4: the degraded path agrees -----------------------------------
    {
        no strict 'refs';
        local ${'main::TUI_LIB_OK'} = 0;
        my $text = join("\n", @{ main::frame_lines(F3(), { cursor => 0 }, 24, 100, 'truecolor') });
        ok(index($text, $E_ACUTE_LABEL) >= 0,
            'AC-E2.4: the DEGRADED frame also keeps the accented characters -- both '
            . 'paths now agree, where before they deliberately differed');
    }

    # --- AC-E2.5: COUNTER-FIXTURE -- substitution is bounded, not removed ----
    {
        my $text = join("\n", map { t_strip_sgr($_) }
                        @{ main::frame_lines(F3C(), { cursor => 0 }, 24, 100, 'truecolor') });
        ok(index($text, 'zh?wen') >= 0,
            'AC-E2.5 counter-fixture: a character whose display width the library '
            . 'cannot claim (U+4E2D) still renders as "?" -- the whitelist was WIDENED, '
            . 'not removed, so AC-E2.1 is a boundary rather than a bug');
        is(index($text, "\x{4e2d}"), -1,
            'AC-E2.5 counter-fixture: U+4E2D itself does not reach the frame');
    }

    # --- AC-E3: sanitize_display still strips --------------------------------
    {
        my $hostile = "x" . $ESC . "[31m" . "y\x00z\nw";
        my $clean   = main::sanitize_display($hostile);
        is(index($clean, $ESC), -1, 'AC-E3: sanitize_display strips the ESC byte');
        is(index($clean, "\x00"), -1, 'AC-E3: sanitize_display strips the NUL');
        is(index($clean, "\n"), -1, 'AC-E3: sanitize_display strips the newline');
        my $accented = main::sanitize_display("caf\x{00E9}");
        ok(index($accented, "\x{00E9}") >= 0,
            'AC-E3: sanitize_display keeps an accented Latin character');
    }
};

done_testing();
