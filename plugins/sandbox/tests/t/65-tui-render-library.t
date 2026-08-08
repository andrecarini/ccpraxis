#!/usr/bin/env perl
# 65-tui-render-library.t — ORACLE for package 05-render-library (blueprint
# unified-tui-design-system), specs/05-render-library-spec.md. Written BLIND
# to any tui/*.pm implementation — none exists yet — directly from the spec's
# numbered observable behaviors (§3) and acceptance criteria (§4, AC-P/S/L/M/
# N/T/D). Do NOT weaken an assertion here to make a future implementation's
# life easier.
#
# TODAY'S EXPECTED STATE: plugins/sandbox/scripts/tui/{Frame,Layout,Meter,
# Screen}.pm do not exist. Every AC-P1 load attempt fails, and every
# source-scan section that needs a file's text degrades via SKIP (not a
# fail, not a compile error) because the file cannot be slurped. Every
# behavioral section is gated on $ALL_LOADED and SKIPs cleanly when it is
# false. The reds you should see today are exactly: the four AC-P1 load
# assertions and the four AC-P1 "is readable as text" preconditions (16
# `not ok`s from a 4-module x 4-precondition shape) plus a handful of
# AC-S1/AC-S6/AC-L1/AC-P2/AC-P4/AC-T1-3/AC-M2 "precondition: readable"
# checks that also fail because the file does not exist. Nothing should
# die or abort the run.
#
# SCAFFOLDING REUSE: _strip_sub_bodies, _balanced_braces, _is_emoji and
# _emoji_hits below are reused VERBATIM (same shape, same block ranges) from
# t/64-theme-tokens.t, per this package's mandate to reuse proven detector
# shapes rather than invent weaker ones. slurp()/_write() are the same
# fixture-I/O idiom t/64 uses.
#
# NO SHAPE PINS (Decision 15) except ONE, and it is the *keep* kind: AC-L1's
# `is(tui::Layout::BREAKPOINT_TWO_COL(), 90, ...)` is marked
# `# shape-lint: intentional — ...` because Decision 14 explicitly LOCKS the
# breakpoint at 90; a later package that changes it SHOULD go red. Every
# sweep assertion (AC-L3/L4/L5) is an aggregate `is($violations, 0, ...)`
# with a `diag` naming the first offending width/row/band — never a
# per-width shape pin. Every cell-key check (AC-D2) is a membership floor
# (`ok(exists ...)`), never `is(scalar keys ..., 3)`.
#
# HARD CONSTRAINTS: this file spawns no process, opens no network
# connection, touches no container, needs no real terminal, and writes only
# under File::Temp::tempdir(CLEANUP => 1). It runs standalone via
# `perl <file>` — there is no `prove` on this host.

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Encode qw(encode decode);

my $SCRIPTS      = "$Bin/../../scripts";
my $TUI_DIR      = "$SCRIPTS/tui";
my $DASHBOARD_PM = "$SCRIPTS/Dashboard.pm";

use lib "$Bin/../../scripts";

my @TUI_MODULES = qw(tui::Frame tui::Layout tui::Meter tui::Screen);
my %MODULE_FILE = (
    'tui::Frame'  => "$TUI_DIR/Frame.pm",
    'tui::Layout' => "$TUI_DIR/Layout.pm",
    'tui::Meter'  => "$TUI_DIR/Meter.pm",
    'tui::Screen' => "$TUI_DIR/Screen.pm",
);

# ===========================================================================
# Scaffolding
# ===========================================================================

# slurp($path) -> file contents as raw bytes, or undef.
sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $s = <$fh>;
    close $fh;
    return $s;
}

# _write($path, $content) -> writes raw bytes, dies loudly on setup failure.
sub _write {
    my ($path, $content) = @_;
    open my $fh, '>:raw', $path or die "fixture setup: cannot write $path: $!";
    print $fh $content;
    close $fh;
    return;
}

# _balanced_braces / _strip_sub_bodies -- reused verbatim (shape) from
# t/64-theme-tokens.t. Blanks every `sub NAME [(proto)] { ... }` body,
# leaving only a file's TOP-LEVEL code, for AC-P1's "no top-level %ENV /
# print / Theme:: call" scan.
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

# _is_emoji / _emoji_hits -- reused VERBATIM from t/64-theme-tokens.t:268-320
# (block-based, deliberately over-approximating). AC-T3 requires this exact
# copy, not a re-derivation.
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

# _comment_stripped($src) -> $src with whole-line `#` comments blanked (the
# t/64 B-A2 shape: "comment prose may discuss them").
sub _comment_stripped {
    my ($src) = @_;
    return join("\n", map { /^\s*#/ ? '' : $_ } split /\n/, $src, -1);
}

# ===========================================================================
# AC-P1 — load hygiene: each module loads, and its TOP-LEVEL code (sub
# bodies blanked) contains no %ENV, no print/warn/say, no Theme:: call.
# ===========================================================================
my %LOADED;
for my $mod (@TUI_MODULES) {
    (my $relpath = $mod) =~ s{::}{/}g;
    my $ok  = eval { require "$relpath.pm"; 1 };
    my $err = $@;
    $LOADED{$mod} = $ok ? 1 : 0;
    ok($LOADED{$mod},
        "AC-P1: $mod loads via the \"\$Bin/../../scripts\" \@INC entry (use lib already proven at t/25:18)")
        or diag("  require $relpath.pm failed: $err");
}

for my $mod (@TUI_MODULES) {
    my $path = $MODULE_FILE{$mod};
    my $src  = slurp($path);
    ok(defined($src), "AC-P1: $path is readable as text (precondition for the top-level scan)");
  SKIP: {
        skip("$path does not exist yet -- module not implemented", 3) unless defined $src;
        my $top = _strip_sub_bodies($src);
        unlike($top, qr/%ENV/, "AC-P1: $mod: no top-level (outside any sub) reference to \%ENV");
        unlike($top, qr/\bprint\b|\bwarn\b|\bsay\b/, "AC-P1: $mod: no top-level print/warn/say");
        unlike($top, qr/\bTheme::\w+\s*\(/, "AC-P1: $mod: no top-level call into Theme::");
    }
}

# ===========================================================================
# AC-P2 — forbidden-construct scan. One class-level regex per §2.6's table
# (minus "the cycle", covered more precisely by the dedicated AC-P4 below),
# asserted per file on comment-stripped source.
#
# ROUND-2 FIX (reviewer MUST-FIX-1): the console class's impurity is the
# diagnostic-output CALL, not the four letters w-a-r-n -- `\bwarn\b` matched
# inside the literal Theme role string 'state.warn' too (`.` is a non-word
# character, so `\b` fires on both sides of `warn` there exactly as it does
# on a bare `warn` statement: verified `"state.warn" =~ /\bwarn\b/` is
# true). 'state.warn' is one of Theme's nine canonical roles and the spec
# mandates it as `banner_role`'s literal default (§2.5) and
# `pressure_role`'s warn-tier return (§2.4) -- a detector that forbids what
# the spec requires is the same shape already corrected once this round for
# AC-N3. Retargeted at the call form (`warn(...)`), which is the actual
# impurity; a bare `'state.warn'` string literal can no longer trip it.
# ===========================================================================
my %FORBIDDEN_CLASS = (
    clock          => qr/\b(?:time|times|localtime|gmtime)\s*\(|\bTime::HiRes\b|\bTime::Local\b/,
    environment    => qr/%ENV\b|\$ENV\{|\bTheme::capability\s*\(/,
    filesystem     => qr/\bopen\s*\(|\bopen\s+my\b|\bopen\s+\$|\bopendir\s*\(|\breaddir\s*\(|\bclose\s*\(|\bunlink\s*\(|\bmkdir\s*\(|\brename\s*\(|\bstat\s*\(|\blstat\s*\(|(?<![\w\$])-[efdsrwx]\s+[\$\(]|\bFile::\w+/,
    process        => qr/`[^`]*`|\bqx\s*[\{\(\/\#\|]|\bsystem\s*\(|\bexec\s*\(|\bfork\s*\(|\breadpipe\s*\(|\bwait\s*\(|\bwaitpid\s*\(|\bkill\s*\(|IPC::Open[23]|CORE::(?:system|exec|fork)\s*\(/,
    console        => qr/\bprint\b|\bprintf\b|\bsay\b|\bwarn\s*\(|STDIN|STDOUT|STDERR|\bbinmode\s*\(|\bselect\s*\(|\bioctl\s*\(|Term::ReadKey/,
    nondeterminism => qr/\brand\s*\(|\bsrand\s*\(|\$\$(?!\w)|\$0\b/,
    blocking       => qr/\bsleep\s*\(|\bflock\s*\(/,
    fatality       => qr/\bdie\b|\bcroak\s*\(|\bconfess\s*\(/,
);
my @CLASS_ORDER = qw(clock environment filesystem process console nondeterminism blocking fatality);

# AC-P2 regression pair (reviewer MUST-FIX-1): the retargeted console
# detector must (a) still fire on a real diagnostic-output call, and (b)
# never fire on the spec-mandated role-name string alone. Both are proven
# directly against the class regex, independent of whether any tui/ file
# currently exists.
like("warn('oops');\n", $FORBIDDEN_CLASS{console},
    "AC-P2 (MUST-FIX-1 regression): the retargeted console detector still fires on a real warn(...) call");
unlike("use constant _ROLE_ATTENTION => 'state.warn';\n", $FORBIDDEN_CLASS{console},
    "AC-P2 (MUST-FIX-1 regression): the retargeted console detector does NOT fire on the literal role string 'state.warn'");

for my $mod (@TUI_MODULES) {
    my $path = $MODULE_FILE{$mod};
    my $src  = slurp($path);
  SKIP: {
        skip("$path does not exist yet", scalar(@CLASS_ORDER)) unless defined $src;
        my $scanned = _comment_stripped($src);
        for my $class (@CLASS_ORDER) {
            unlike($scanned, $FORBIDDEN_CLASS{$class},
                "AC-P2: $mod: no '$class' construct (purity, criterion 1)");
        }
    }
}

# ===========================================================================
# AC-P4 — the cycle is inert. No tui/ file names Dashboard as a use/require
# target, a Dashboard:: qualified call, or the literal Theme::display_width.
# THIS IS THE MOST IMPORTANT STRUCTURAL ASSERTION IN THIS PACKAGE: it is
# what keeps Dashboard -> tui -> Theme -> Dashboard from ever being
# traversed once 06 makes Dashboard consume tui/ and Theme.
# ===========================================================================
for my $mod (@TUI_MODULES) {
    my $path = $MODULE_FILE{$mod};
    my $src  = slurp($path);
  SKIP: {
        skip("$path does not exist yet", 3) unless defined $src;
        my $scanned = _comment_stripped($src);
        unlike($scanned, qr/\b(?:use|require)\s+Dashboard\b/,
            "AC-P4: $mod: no 'use Dashboard' / 'require Dashboard' (the cycle is inert)");
        unlike($scanned, qr/\bDashboard::\w+/,
            "AC-P4: $mod: no Dashboard:: qualified call");
        unlike($scanned, qr/\QTheme::display_width\E/,
            "AC-P4: $mod: no literal Theme::display_width (the one Theme fn that reaches back into Dashboard)");
    }
}

# ===========================================================================
# AC-P6 — detector non-vacuity: each AC-P2/AC-P4 regex is proven live
# against a File::Temp fixture containing that exact construct.
# ===========================================================================
{
    my $tmpdir = tempdir(CLEANUP => 1);
    my %FIXTURE_SNIPPET = (
        clock          => "my \$t = time();\n",
        environment    => "my \$x = \$ENV{PATH};\n",
        filesystem     => "open(my \$fh, '<', 'x.txt');\n",
        process        => "system('ls');\n",
        console        => "print 'hi';\n",
        nondeterminism => "my \$r = rand();\n",
        blocking       => "sleep(1);\n",
        fatality       => "die 'oops';\n",
    );
    for my $class (@CLASS_ORDER) {
        my $f = "$tmpdir/$class.pl";
        _write($f, $FIXTURE_SNIPPET{$class});
        like(slurp($f), $FORBIDDEN_CLASS{$class},
            "AC-P6: the '$class' detector fires on a fixture containing that exact construct (non-vacuity)");
    }

    my $f1 = "$tmpdir/use-dash.pl";
    _write($f1, "use Dashboard;\n");
    like(slurp($f1), qr/\b(?:use|require)\s+Dashboard\b/,
        "AC-P6: the cycle detector fires on a 'use Dashboard;' fixture");

    my $f2 = "$tmpdir/call-dash.pl";
    _write($f2, "my \$w = Dashboard::display_width('x');\n");
    like(slurp($f2), qr/\bDashboard::\w+/,
        "AC-P6: the cycle detector fires on a Dashboard:: qualified call fixture");

    my $f3 = "$tmpdir/theme-dw.pl";
    _write($f3, "my \$w = Theme::display_width('x');\n");
    like(slurp($f3), qr/\QTheme::display_width\E/,
        "AC-P6: the cycle detector fires on a literal Theme::display_width fixture");
}

# ===========================================================================
# AC-T1/AC-T2/AC-T3 — no raw SGR, no hex, no glyph literal, no emoji
# (criterion 6, Decision 11).
# ===========================================================================
my $ESC_LITERAL_RE = qr/\\e\b|\\x1[bB]\b|\\x\{1[bB]\}|\\033\b|\\027\b/;
my $HEX_RE          = qr/#(?:[0-9A-Fa-f]{6}|[0-9A-Fa-f]{3})\b/;
my $SGR_PARAM_RE    = qr/38;2;|38;5;|48;2;|48;5;/;
my $SGR_PATTERN_RE  = qr/\[\d+(?:;\d+)*m/;

for my $mod (@TUI_MODULES) {
    my $path = $MODULE_FILE{$mod};
    my $src  = slurp($path);
  SKIP: {
        skip("$path does not exist yet", 6) unless defined $src;
        my $scanned = _comment_stripped($src);
        unlike($scanned, $ESC_LITERAL_RE, "AC-T1: $mod: no escape-literal ESC form (\\e / \\x1b / \\x{1b} / \\033 / \\027)");
        unlike($src, qr/\x1B/, "AC-T1: $mod: no literal ESC byte (0x1B) in source");
        unlike($scanned, $HEX_RE, "AC-T1: $mod: no hex colour literal (#RGB or #RRGGBB)");
        unlike($scanned, $SGR_PARAM_RE, "AC-T1: $mod: no SGR truecolor/256 colour parameter string");
        unlike($scanned, $SGR_PATTERN_RE, "AC-T1: $mod: no raw SGR escape pattern (\\[N(;N)*m)");
        unlike($src, qr/[\x80-\xFF]/, "AC-T2: $mod: source contains no byte >= 0x80");
    }
}

for my $mod (@TUI_MODULES) {
    my $path = $MODULE_FILE{$mod};
    my $src  = slurp($path);
  SKIP: {
        skip("$path does not exist yet", 1) unless defined $src;
        my @codepoints = ($src =~ /\\x\{([0-9A-Fa-f]+)\}/g);
        my @over = grep { hex($_) >= 0x80 } @codepoints;
        is(scalar(@over), 0, "AC-T2: $mod: no \\x{...} escape with codepoint >= 0x80")
            or diag("  offending codepoints: " . join(', ', map { sprintf('U+%04X', hex($_)) } @over));
    }
}

for my $mod (@TUI_MODULES) {
    my $path = $MODULE_FILE{$mod};
    my $src  = slurp($path);
  SKIP: {
        skip("$path does not exist yet", 1) unless defined $src;
        my @hits = _emoji_hits($src);
        is(scalar(@hits), 0, "AC-T3: $mod: zero emoji hits (Decision 11, detector reused verbatim from t/64)")
            or diag(sprintf("  U+%04X at line %d (%s)", $_->{cp}, $_->{line}, $_->{how})) for @hits;
    }
}

# AC-T6 -- detector non-vacuity for T1/T2/T3, independent of tui/ existing.
{
    my $tmpdir = tempdir(CLEANUP => 1);

    my $f_esc = "$tmpdir/esc.pl";
    _write($f_esc, "my \$s = \"\\e[31m\";\n");
    like(slurp($f_esc), $SGR_PATTERN_RE, "AC-T6: the SGR-pattern detector fires on a '\\e[31m' fixture literal");

    my $f_hex = "$tmpdir/hex.pl";
    _write($f_hex, "my \$c = '#FF0000';\n");
    like(slurp($f_hex), $HEX_RE, "AC-T6: the hex-colour detector fires on a '#FF0000' fixture literal");

    my $f_emoji_escape = "$tmpdir/emoji-escape.pl";
    _write($f_emoji_escape, "my \$g = \"\\x{1F534}\";\n");
    my @over = grep { hex($_) >= 0x80 } (slurp($f_emoji_escape) =~ /\\x\{([0-9A-Fa-f]+)\}/g);
    ok(scalar(@over) > 0, "AC-T6: the codepoint>=0x80 detector fires on a '\\x{1F534}' escape fixture");
    my @hits_escape = _emoji_hits(slurp($f_emoji_escape));
    ok(scalar(@hits_escape) > 0, "AC-T6: the emoji detector fires on a '\\x{1F534}' escape fixture");

    my $f_emoji_literal = "$tmpdir/emoji-literal.pl";
    _write($f_emoji_literal, "my \$g = '" . encode('UTF-8', "\x{1F534}") . "';\n");
    my @hits_literal = _emoji_hits(slurp($f_emoji_literal));
    ok(scalar(@hits_literal) > 0, "AC-T6: the emoji detector fires on a raw UTF-8 emoji byte-sequence fixture");
}

# ===========================================================================
# AC-S1 — tui/Screen.pm's header names the three design targets and the
# five hooks H1-H5 (criterion 1a).
# ===========================================================================
{
    my $path = $MODULE_FILE{'tui::Screen'};
    my $src  = slurp($path);
    ok(defined($src), "AC-S1: $path is readable as text (precondition)");
  SKIP: {
        skip("$path does not exist yet", 8) unless defined $src;
        for my $slug ('06-dashboard-screen', '07-backpack-screen', '08-launcher-screens') {
            like($src, qr/\Q$slug\E/, "AC-S1: tui::Screen names design target '$slug'");
        }
        for my $hook (qw(H1 H2 H3 H4 H5)) {
            like($src, qr/\b\Q$hook\E\b/, "AC-S1: tui::Screen names hook '$hook'");
        }
    }
}

# ===========================================================================
# AC-S6 — THE BOUNDARY IS CLOSED. tui/Screen.pm defines none of the nine
# forbidden subs. This is what stops 07/08 widening the contract by
# accretion (criterion 1a's central enforcement mechanism).
# ===========================================================================
{
    my $path = $MODULE_FILE{'tui::Screen'};
    my $src  = slurp($path);
    my @FORBIDDEN_SUBS = qw(set_state handle_key show_confirm append_line teardown transition run select scroll);
  SKIP: {
        skip("$path does not exist yet", scalar(@FORBIDDEN_SUBS)) unless defined $src;
        for my $name (@FORBIDDEN_SUBS) {
            unlike($src, qr/\bsub\s+\Q$name\E\b/,
                "AC-S6: tui::Screen defines no sub named '$name' (boundary closed, criterion 1a)");
        }
    }
}

# ===========================================================================
# AC-L1 — the breakpoint is declared once, and is 90 (source-scan half; the
# behavioral half runs later, gated on tui::Layout loading).
# ===========================================================================
for my $mod (qw(tui::Frame tui::Meter tui::Screen)) {
    my $path = $MODULE_FILE{$mod};
    my $src  = slurp($path);
  SKIP: {
        skip("$path does not exist yet", 1) unless defined $src;
        unlike($src, qr/\b90\b/, "AC-L1: $mod: does not name the literal 90 (breakpoint declared once, in Layout only)");
    }
}
{
    my $path = $MODULE_FILE{'tui::Layout'};
    my $src  = slurp($path);
  SKIP: {
        skip("$path does not exist yet", 2) unless defined $src;
        my @lines_with_90 = grep { /\b90\b/ } split /\n/, $src;
        is(scalar(@lines_with_90), 1, "AC-L1: tui::Layout: the literal 90 appears on exactly one line")
            or diag("  lines: " . join(' | ', @lines_with_90));
        like($lines_with_90[0] // '', qr/BREAKPOINT_TWO_COL/,
            "AC-L1: tui::Layout: that one line defines BREAKPOINT_TWO_COL");
    }
}

# ===========================================================================
# AC-D1 CORRECTED for package 06 (in-scope oracle correction; driver
# escalation E-C, packages/06-dashboard-screen.md 2026-08-07T20:40:59Z): the
# original claim here was "Dashboard.pm contains no tui:: reference" --
# correct for package 05, which deliberately extracted-and-added without
# rewriting Dashboard.pm (spec §1.3). Package 06's entire mandate is the
# opposite: make Dashboard.pm CONSUME tui::, so that claim is now the exact
# negation of what 06 must do. The REAL invariant this file exists to
# police is the DEPENDENCY DIRECTION, not which side names the other: a
# tui:: library module may never name Dashboard -- that would invert the
# DAG by making the library depend on the 3,490-line legacy module it
# exists to replace. That is 06 spec's AC-P4, unaffected by anything 06
# does to Dashboard.pm, so it is what stays pinned here; the obsolete
# reverse-direction claim is dropped rather than kept alongside a
# contradiction (06 spec §1.3 also confirms t/65's scans enumerate the
# library's four modules BY NAME, so this scan does not reach the fifth
# file, tui/DashboardScreen.pm -- that one is t/66's AC-P4).
# ===========================================================================
for my $mod (@TUI_MODULES) {
    my $path = $MODULE_FILE{$mod};
    my $src  = slurp($path);
    ok(defined($src), "AC-D1 (corrected for 06): precondition -- $path is readable as text");
  SKIP: {
        skip("$path unreadable", 1) unless defined $src;
        # Comment-stripped first (blank comments before any source scan -- prose
        # is allowed to discuss Dashboard, e.g. this very file's own header and
        # tui::Layout.pm's "never Dashboard" design-intent comment; only CODE
        # references would invert the DAG).
        my $scanned = _comment_stripped($src);
        unlike($scanned, qr/\bDashboard\b/,
            "AC-D1 (corrected for 06): $mod names no 'Dashboard' identifier in code -- the tui:: library must never depend on the module it exists to replace (dependency-direction invariant; was package 05's AC-D1, re-scoped for 06's E-C)");
    }
}

# ===========================================================================
# Behavioral sections below need the modules (and Theme) actually loaded.
# ===========================================================================
my $THEME_OK = eval { require Theme; 1 };
ok($THEME_OK, 'precondition: Theme.pm loads (shipped by package 02-design-tokens, read-only here)')
    or diag("  require Theme failed: $@");

my $ALL_LOADED = $THEME_OK && !grep { !$LOADED{$_} } @TUI_MODULES;

# Fixture panel sets -- declared ONCE, reused by every sweep below (AC-L3/L4/L5/L6).
my @PANELS_1 = ( { title => 'Solo', lines => ['line one', 'line two'] } );
my @PANELS_2 = (
    { title => 'Alpha', lines => ['a1', 'a2'] },
    { title => 'Beta',  lines => ['b1'] },
);
# ROUND-2 RESTORATION (driver ruling 2026-08-07, redteam M3): the previous
# @PANELS_4 was tuned with verbose, non-authentic phrasing ('3 seconds
# ago', '01 hours 42 minutes 10 seconds', 'holding, this PC stays awake')
# specifically wide enough to make AC-L6 pass. Dashboard.pm's OWN
# formatters never produce that phrasing -- fmt_age()/fmt_hms()
# (Dashboard.pm:79-105) emit terse forms ('3s', '1h 42m 10s'), and
# fmt_oauth()/the run/token branches (Dashboard.pm:79-115,880-892,1099-1120)
# are similarly terse. Rebuilt here from those ACTUAL formatters' output
# shapes (still 'label : value' rows well past 34 display columns, per
# Dashboard.pm's Sandbox/Run/Resources/Token panels -- see e.g.
# Dashboard.pm:848-872's 'container : <name>  <glyph> [<status>]' row) --
# not re-tuned to fail, just no longer padded to pass. AC-L3/L4's geometry
# sweeps don't care about content length (place() operates on band widths
# alone), so this fixture change cannot regress those. If content_reach()
# now falls short of the right third, THAT IS THE FINDING (redteam M3):
# tui::Layout::columns() never allocates more than two bands at any width,
# so the right column starts at col 100 of 200 regardless of how many
# panels there are, and ordinary content does not reliably reach column
# 134 from there. Do not widen this fixture to make AC-L5/AC-L6 pass.
my @PANELS_4 = (
    { title => 'Sandbox',   lines => [
        'project   : unified-tui-design-system',
        'container : sandbox-web-01 [running]',
        'heartbeat : 3s ago',
        'uptime    : 1h 42m 10s',
    ] },
    { title => 'Resources', lines => [
        'ctr cpu    : 3.2%',
        'host cpu   : 12.5%',
    ] },
    { title => 'Run',       lines => [
        'busy-lease : idle (2m ago)',
        'keep-awake : released (PC may sleep)',
        'needs you  : none',
    ] },
    { title => 'Token',     lines => [
        'access      : EXPIRED',
        'refresh     : absent',
        'refreshed   : 12s ago',
    ] },
);
my %PANEL_FIXTURES = ( 1 => \@PANELS_1, 2 => \@PANELS_2, 4 => \@PANELS_4 );

# ---------------------------------------------------------------------------
# AC-P3 — determinism under an %ENV mutation.
# ---------------------------------------------------------------------------
SKIP: {
    skip('tui:: modules (and/or Theme) not all loaded', 6) unless $ALL_LOADED;
    my %ENV_BACKUP = %ENV;
    my @calls = (
        ['tui::Frame::safe',         sub { tui::Frame::safe("hello \x9B world") }],
        ['tui::Frame::make_cell',    sub { tui::Frame::make_cell('hi', 'text.primary', 10) }],
        ['tui::Frame::paint_row',    sub { tui::Frame::paint_row(tui::Frame::make_cell('hi', 'text.primary', 5), 'truecolor') }],
        ['tui::Layout::display_width', sub { tui::Layout::display_width('hello world') }],
        ['tui::Meter::row (gauged)', sub { tui::Meter::row({ label => 'cpu', used => 50, total => 100 }) }],
        ['tui::Screen::compose',     sub { tui::Screen::compose({ title => 'T', panels => [ { title => 'P', lines => ['a'] } ] }, 10, 40) }],
    );
    for my $c (@calls) {
        my ($name, $fn) = @$c;
        %ENV = ();
        Theme::_reset_capability_memo();
        my $r1 = $fn->();
        %ENV = %ENV_BACKUP;
        Theme::_reset_capability_memo();
        my $r2 = $fn->();
        is_deeply($r1, $r2, "AC-P3: $name returns byte-identical results across an \%ENV mutation (determinism)");
    }
    %ENV = %ENV_BACKUP;
    Theme::_reset_capability_memo();
}

# ---------------------------------------------------------------------------
# AC-P5 — totality: every public function survives a hostile corpus without
# dying or warning. Aggregated per module with a first-offender diag.
# ---------------------------------------------------------------------------
SKIP: {
    skip('tui:: modules (and/or Theme) not all loaded', 4) unless $ALL_LOADED;

    my @HOSTILE = (
        ['undef',                       undef],
        ['empty string',                ''],
        ['zero',                        0],
        ['arrayref',                    []],
        ['hashref',                     {}],
        ['coderef',                     sub { 1 }],
        ['blessed object',              bless({}, 'Some::Blessed::Fixture')],
        ['deeply nested arrayref',      [[[[1]]]]],
        ['invalid UTF-8 byte sequence', "\xC3\x28"],
        ['lone C1 CSI byte',            "\x9B"],
        ['10 KB string',                ('x' x 10_240)],
    );

    my %FN_BY_MODULE = (
        'tui::Frame' => {
            safe             => sub { tui::Frame::safe($_[0]) },
            safe_char        => sub { tui::Frame::safe_char($_[0]) },
            spanify          => sub { tui::Frame::spanify($_[0], 'text.primary') },
            spans_width      => sub { tui::Frame::spans_width($_[0]) },
            spans_text       => sub { tui::Frame::spans_text($_[0]) },
            fit_spans        => sub { tui::Frame::fit_spans($_[0], 10, 'text.primary') },
            make_cell        => sub { tui::Frame::make_cell($_[0], 'text.primary', 10) },
            clip_pad         => sub { tui::Frame::clip_pad($_[0], 10) },
            cell_sig         => sub { tui::Frame::cell_sig($_[0]) },
            panel_title_line => sub { tui::Frame::panel_title_line($_[0], 10) },
            paint_row        => sub { tui::Frame::paint_row($_[0], 'truecolor') },
            is_known_role    => sub { tui::Frame::is_known_role($_[0]) },
        },
        'tui::Layout' => {
            char_cols         => sub { tui::Layout::char_cols($_[0]) },
            glyph_width       => sub { tui::Layout::glyph_width($_[0]) },
            display_width     => sub { tui::Layout::display_width($_[0]) },
            wrap              => sub { tui::Layout::wrap($_[0], 10, 'text.primary') },
            arrangement       => sub { tui::Layout::arrangement($_[0]) },
            divide            => sub { tui::Layout::divide($_[0], 2) },
            columns           => sub { tui::Layout::columns($_[0]) },
            place             => sub { tui::Layout::place($_[0], 80) },
            dead_columns      => sub { tui::Layout::dead_columns($_[0], 80) },
            right_third_start => sub { tui::Layout::right_third_start($_[0]) },
            content_reach     => sub { tui::Layout::content_reach($_[0]) },
        },
        'tui::Meter' => {
            ratio                   => sub { tui::Meter::ratio($_[0], 100) },
            pressure_role           => sub { tui::Meter::pressure_role($_[0]) },
            percent_text            => sub { tui::Meter::percent_text($_[0]) },
            bar                     => sub { tui::Meter::bar($_[0], 10) },
            fmt_bytes               => sub { tui::Meter::fmt_bytes($_[0]) },
            numbers_used_free_total => sub { tui::Meter::numbers_used_free_total($_[0], 1, 1) },
            fits_numeric_column     => sub { tui::Meter::fits_numeric_column($_[0]) },
            row                     => sub { tui::Meter::row({ label => 'x', numbers => $_[0] }) },
        },
        'tui::Screen' => {
            compose  => sub { tui::Screen::compose($_[0], 5, 40) },
            viewport => sub { tui::Screen::viewport($_[0], 5, 2) },
            diff     => sub { tui::Screen::diff($_[0], []) },
        },
    );

    for my $mod (@TUI_MODULES) {
        my $violations = 0;
        my $first;
        for my $fname (sort keys %{ $FN_BY_MODULE{$mod} }) {
            my $fn = $FN_BY_MODULE{$mod}{$fname};
            for my $h (@HOSTILE) {
                my ($hdesc, $hval) = @$h;
                my @warnings;
                my $died;
                {
                    local $SIG{__WARN__} = sub { push @warnings, "@_" };
                    $died = !eval { $fn->($hval); 1 };
                }
                if ($died || @warnings) {
                    $violations++;
                    $first //= "$mod\::$fname($hdesc)" . ($died ? ' DIED' : ' WARNED');
                }
            }
        }
        is($violations, 0, "AC-P5: every public $mod function survives the hostile corpus without dying or warning (totality, INV-8)")
            or diag("  first offender: " . ($first // '<none recorded>'));
    }
}

# ---------------------------------------------------------------------------
# AC-D2 — the cell shape is preserved (membership floor, not a key-count pin).
# ---------------------------------------------------------------------------
SKIP: {
    skip('tui::Frame not loaded', 3) unless $LOADED{'tui::Frame'};
    my $cell = tui::Frame::make_cell('hello', 'text.primary', 10);
    ok(exists $cell->{text},  'AC-D2: make_cell result has a "text" key (membership floor)');
    ok(exists $cell->{role},  'AC-D2: make_cell result has a "role" key (membership floor)');
    ok(exists $cell->{spans}, 'AC-D2: make_cell result has a "spans" key (membership floor)');
}

# ---------------------------------------------------------------------------
# AC-T4 — the positive half: every role a tui::* function emits by default
# is a known Theme role.
#
# ROUND-2 ADDITION (reviewer MAJOR-2): the spec's own AC-T4 text names
# "Screen's four *_role defaults" as in-scope, but nothing here exercised
# tui::Screen's title_role/banner_role/footer_role defaults -- exactly the
# blind spot that let Screen.pm's banner_role default sit unexamined as a
# hand-assembled string concatenation (see the AC-P2 MUST-FIX-1 note
# above): a typo in that concatenation would compile, pass every other
# assertion in this file, and silently render every Screen-level banner
# unstyled. Compose a screen supplying title/banners/footer with NONE of
# the *_role overrides, at a height that keeps exactly one banner and still
# leaves >=1 body row (per §2.5 steps 2-4: row 0 is title, banners
# immediately follow, footer is the last row) -- then check the ROLE THE
# DEFAULT ACTUALLY PRODUCED against is_known_role, never a hardcoded
# expected string, so this catches a typo without pinning the current
# default value.
# ---------------------------------------------------------------------------
SKIP: {
    skip('tui:: modules (and/or Theme) not all loaded', 9) unless $ALL_LOADED;
    ok(tui::Frame::is_known_role(tui::Frame::DEFAULT_ROLE()), 'AC-T4: Frame::DEFAULT_ROLE() is a known Theme role');
    ok(tui::Frame::is_known_role(tui::Frame::PAD_ROLE()),     'AC-T4: Frame::PAD_ROLE() is a known Theme role');
    my @pressure_roles = grep { defined } map { tui::Meter::pressure_role($_) } (0.1, 0.8, 0.95);
    my $bad_pressure = grep { !tui::Frame::is_known_role($_) } @pressure_roles;
    is($bad_pressure, 0, 'AC-T4: every tui::Meter::pressure_role() return value is a known Theme role');
    my $rule_spans = tui::Frame::rule(5);
    my $rule_roles_ok = !grep { !tui::Frame::is_known_role($_->{role}) } @$rule_spans;
    ok($rule_roles_ok, 'AC-T4: every span tui::Frame::rule() emits carries a known Theme role');
    my $title_spans = tui::Frame::panel_title_line('Panel', 20);
    my $title_roles_ok = !grep { !tui::Frame::is_known_role($_->{role}) } @$title_spans;
    ok($title_roles_ok, 'AC-T4: every span tui::Frame::panel_title_line() emits carries a known Theme role');

    my $role_screen = { title => 'T', banners => ['B'], panels => [], footer => 'F' };
    my $role_cells  = tui::Screen::compose($role_screen, 4, 40);
    is(scalar(@$role_cells), 4,
        'AC-T4: precondition -- the role-default fixture composes to exactly 4 cells (title, banner, body, footer)');
    ok(tui::Frame::is_known_role($role_cells->[0]{role}),  "AC-T4: tui::Screen's title_role default (row 0) is a known Theme role");
    ok(tui::Frame::is_known_role($role_cells->[1]{role}),  "AC-T4: tui::Screen's banner_role default (row 1) is a known Theme role");
    ok(tui::Frame::is_known_role($role_cells->[-1]{role}), "AC-T4: tui::Screen's footer_role default (last row) is a known Theme role");
}

# ---------------------------------------------------------------------------
# AC-T5 — the glyphs Meter::bar and Frame::rule emit are byte-identical to
# the corresponding Theme::glyph(...).
# ---------------------------------------------------------------------------
SKIP: {
    skip('tui:: modules (and/or Theme) not all loaded', 2) unless $ALL_LOADED;
    my $full  = Theme::glyph('gauge.full');
    my $empty = Theme::glyph('gauge.empty');
    my $bar = tui::Meter::bar(0.5, 10);
    ok(defined($bar) && $bar =~ /\A(?:\Q$full\E|\Q$empty\E)+\z/,
        'AC-T5: tui::Meter::bar() is composed solely of Theme::glyph(gauge.full)/(gauge.empty) bytes');
    my $rule_spans = tui::Frame::rule(5);
    my $rule_text  = join('', map { $_->{text} } @$rule_spans);
    my $rule_glyph = Theme::glyph('rule.h');
    is($rule_text, ($rule_glyph x 5),
        'AC-T5: tui::Frame::rule(5) is composed of Theme::glyph(rule.h) bytes, repeated exactly 5 times');
}

# ---------------------------------------------------------------------------
# H4 regression (redteam) -- tui::Frame::safe() must preserve EVERY glyph
# Theme declares, not just the ones AC-T5 happens to exercise (gauge.full/
# empty, rule.h -- all above U+00FF). tui::Layout's decode heuristic ("a
# codepoint > 0xFF means the string is already decoded") mis-classifies a
# single-character BYTE STRING whose codepoint is <= 0xFF: it takes the
# "already decoded" branch, fails to decode the UTF-8 bytes, and yields
# U+FFFD -- so safe_char's ladder falls through to '?'. Two Theme glyphs sit
# exactly in that trap: sep.dot (U+00B7, the statusline separator) and
# status.crit (U+00D7, "a failed or critical state" -- the very glyph that
# means "this is broken"). Derived from Theme::glyphs() -- never a
# hardcoded list, so a 30th glyph automatically joins the floor.
# ---------------------------------------------------------------------------
SKIP: {
    skip('tui::Frame (and/or Theme) not all loaded', 1) unless $ALL_LOADED;
    my $glyphs = Theme::glyphs();
    my ($violations, $first) = (0, undef);
    for my $name (sort keys %$glyphs) {
        my $rec   = $glyphs->{$name};
        my $safed = tui::Frame::safe($rec->{bytes});
        if (!defined($safed) || $safed ne $rec->{bytes}) {
            $violations++;
            $first //= sprintf("glyph '%s' (U+%04X): safe() returned %s, expected the glyph's own bytes unchanged",
                $name, $rec->{cp}, defined($safed) ? "'$safed'" : 'undef');
        }
    }
    is($violations, 0,
        'H4: tui::Frame::safe() preserves EVERY glyph in Theme::glyphs() byte-for-byte, including codepoints <= U+00FF')
        or diag("  first offender: " . ($first // '<none recorded>'));
}

# ---------------------------------------------------------------------------
# AC-L1 (behavioral half) — BREAKPOINT_TWO_COL() is 90.
# ---------------------------------------------------------------------------
SKIP: {
    skip('tui::Layout not loaded', 1) unless $LOADED{'tui::Layout'};
    is(tui::Layout::BREAKPOINT_TWO_COL(), 90,
        'AC-L1: BREAKPOINT_TWO_COL() is 90 (Decision 14)');   # shape-lint: intentional — Decision 14 explicitly locks the responsive breakpoint at 90 columns; a package that changes it should go red
}

# ---------------------------------------------------------------------------
# AC-L2 — two arrangements, chosen from width alone.
# ---------------------------------------------------------------------------
SKIP: {
    skip('tui::Layout not loaded', 11) unless $LOADED{'tui::Layout'};
    my %CASES = ( 60 => 'single-column', 89 => 'single-column', 90 => 'two-column',
                  91 => 'two-column', 100 => 'two-column', 200 => 'two-column' );
    for my $cols (sort { $a <=> $b } keys %CASES) {
        is(tui::Layout::arrangement($cols), $CASES{$cols}, "AC-L2: arrangement($cols) is '$CASES{$cols}'");
    }
    for my $bad (undef, '', 'abc', 0, -5) {
        is(tui::Layout::arrangement($bad), 'single-column',
            'AC-L2: arrangement(' . (defined($bad) ? "'$bad'" : 'undef') . ") is 'single-column'");
    }
}

# ---------------------------------------------------------------------------
# AC-L3 — the sweep, no overflow at PLACEMENT level. W = 60..200 (141
# widths) x 3 fixtures. Aggregate is() per fixture with a first-offender diag.
# ---------------------------------------------------------------------------
SKIP: {
    skip('tui::Layout not loaded', scalar(keys %PANEL_FIXTURES)) unless $LOADED{'tui::Layout'};
    for my $n (sort { $a <=> $b } keys %PANEL_FIXTURES) {
        my $panels = $PANEL_FIXTURES{$n};
        my ($violations, $first) = (0, undef);
        for my $W (60 .. 200) {
            my $rows = tui::Layout::place($panels, $W);
            for my $ri (0 .. $#$rows) {
                my $row = $rows->[$ri];
                my ($sum, $prev_end) = (0, 0);
                for my $bi (0 .. $#$row) {
                    my $b = $row->[$bi];
                    if ($b->{x} < 0 || $b->{w} < 1 || $b->{x} + $b->{w} > $W || $b->{x} < $prev_end) {
                        $violations++;
                        $first //= "W=$W row=$ri band=$bi x=$b->{x} w=$b->{w}";
                    }
                    $sum += $b->{w};
                    $prev_end = $b->{x} + $b->{w};
                }
                if ($sum != $W) {
                    $violations++;
                    $first //= "W=$W row=$ri band widths sum to $sum, expected $W";
                }
                if (@$row && ($row->[-1]{x} + $row->[-1]{w} != $W)) {
                    $violations++;
                    $first //= "W=$W row=$ri rightmost band ends at " . ($row->[-1]{x} + $row->[-1]{w}) . ", expected $W";
                }
            }
        }
        is($violations, 0, "AC-L3: tui::Layout::place() never overflows across W=60..200 ($n-panel fixture)")
            or diag("  first violation: " . ($first // '<none recorded>'));
    }
}

# ---------------------------------------------------------------------------
# AC-L4 — the sweep, no overflow at RENDER level (Screen::compose). Same
# 141 widths, rows=24.
# ---------------------------------------------------------------------------
SKIP: {
    skip('tui:: modules not all loaded', scalar(keys %PANEL_FIXTURES)) unless $ALL_LOADED;
    for my $n (sort { $a <=> $b } keys %PANEL_FIXTURES) {
        my $panels = $PANEL_FIXTURES{$n};
        my ($violations, $first) = (0, undef);
        for my $W (60 .. 200) {
            my $cells = tui::Screen::compose({ title => 'T', panels => $panels, footer => 'F' }, 24, $W);
            for my $ci (0 .. $#$cells) {
                my $cell = $cells->[$ci];
                my $dw = tui::Layout::display_width($cell->{text});
                my $sw = tui::Frame::spans_width($cell->{spans});
                if ($dw != $W || $sw != $W || $cell->{text} =~ /\e/) {
                    $violations++;
                    $first //= "W=$W row=$ci display_width=$dw spans_width=$sw";
                }
            }
        }
        is($violations, 0, "AC-L4: every Screen::compose cell is exactly W display columns across W=60..200 ($n-panel fixture)")
            or diag("  first violation: " . ($first // '<none recorded>'));
    }
}

# ---------------------------------------------------------------------------
# AC-L5 — REPLACED, round 3 (driver ruling): round 2 swept the
# content_reach()-vs-right_third_start() property across the FULL W=60..200
# range and went red at 30 widths. That over-applies criterion 3's
# right-third clause, which the spec states verbatim only for "a
# 200-column terminal" -- overflow is what's swept 60..200; the right-third
# property is specified AT 200 (AC-L6 asserts that directly and passes:
# reach=173 >= need=134). At the narrow end the property is physically
# unachievable regardless of implementation quality: @PANELS_4's longest
# line is 37 display columns, so no layout can make content_reach() reach
# column 67 (need at W=100) or column 80 (need at W=120) -- there is no ink
# to stretch. This is measured, not assumed:
#     W=100 reach= 58 need= 67  under
#     W=120 reach= 68 need= 80  under
#     W=135 reach=102 need= 90  ok
#     W=150 reach=112 need=100  ok
#     W=200 reach=158 need=134  ok
# The property holds CONTIGUOUSLY from W=135 onward (EMPIRICAL finding for
# this fixture, not a spec value -- a different panel corpus would cross
# over at a different width). A W=90..200 sweep was considered and
# rejected: 45 of those widths fail, reproducing the same over-application
# one tier down. This block instead asserts a floor across W=150..200 --
# chosen with real margin above the measured 135 crossover so it cannot go
# red from a small content change -- while AC-L6 continues to assert the
# literal criterion-3 case (200 columns) directly. A floor over a
# contiguous wide range is NOT a whole-shape pin (Decision 15): it is a
# swept property assertion, structurally identical to AC-L3/AC-L4's sweeps,
# just over a narrower and empirically-justified range. This still
# replaces the original round-1 block of 423 assertions
# (`dead_columns($panels, $W) == 0` across all 141 widths x 3 fixtures),
# which could not fail for any implementation -- `dead_columns` is 0 BY
# CONSTRUCTION for every width because `divide()` (which `place()` always
# calls) guarantees every band row's rightmost edge lands at exactly
# `$cols`. Do not restore that range or that metric; both were vacuous.
# ---------------------------------------------------------------------------
SKIP: {
    skip('tui:: modules not all loaded', 1) unless $ALL_LOADED;
    my ($violations, $first) = (0, undef);
    for my $W (150 .. 200) {
        my $cells = tui::Screen::compose({ title => 'T', panels => \@PANELS_4, footer => 'F' }, 24, $W);
        my $reach = tui::Layout::content_reach($cells);
        my $rts   = tui::Layout::right_third_start($W);
        if ($reach < $rts) { $violations++; $first //= "W=$W content_reach=$reach right_third_start=$rts"; }
    }
    is($violations, 0, 'AC-L5 (redefined): content_reach() reaches into the right third across W=150..200 (4-panel fixture, contiguous floor above the measured ~135 crossover)')
        or diag("  first violation: " . ($first // '<none recorded>'));
}

# ---------------------------------------------------------------------------
# AC-L6 — the right third of a 200-column terminal is not empty.
# ---------------------------------------------------------------------------
SKIP: {
    skip('tui:: modules not all loaded', 2) unless $ALL_LOADED;
    my $cells = tui::Screen::compose({ title => 'T', panels => \@PANELS_4, footer => 'F' }, 24, 200);
    my $reach = tui::Layout::content_reach($cells);
    cmp_ok($reach, '>=', tui::Layout::right_third_start(200),
        'AC-L6: content_reach() reaches into the right third of a 200-column, 4-panel terminal');
    is(tui::Layout::right_third_start(200), 200 - int(200 / 3),
        'AC-L6: right_third_start(200) is a derivation (200 - int(200/3)), not a literal pin');
}

# ---------------------------------------------------------------------------
# AC-L7 — the dead-space metrics are not vacuous (control cases).
# ---------------------------------------------------------------------------
SKIP: {
    skip('tui::Frame/tui::Layout not loaded', 2) unless $ALL_LOADED;

    # content_reach: a hand-built frame at 200 cols whose only content sits
    # in columns 0..59 must NOT reach the right third (134).
    my $left_cell  = tui::Frame::make_cell('x' x 40, 'text.primary', 60);
    my $blank_cell = tui::Frame::make_cell('', 'text.primary', 140);
    my $hand_built_cell = {
        text  => $left_cell->{text} . $blank_cell->{text},
        role  => 'text.primary',
        spans => [ @{ $left_cell->{spans} }, @{ $blank_cell->{spans} } ],
    };
    cmp_ok(tui::Layout::content_reach([$hand_built_cell]), '<', tui::Layout::right_third_start(200),
        'AC-L7: content_reach() is not vacuous -- content confined to cols 0..59 does not reach the right third');

    # dead_columns is DEFINED (spec 2.3) as C - max(rightmost band end) over
    # band rows. Real place() output always fully allocates (divide()'s
    # postcondition guarantees sum(w) == C), so dead_columns(panels, cols)
    # can never observe a gap through the public API. This control case
    # applies the SAME formula directly to a hand-built band row with an
    # unallocated 40-col right margin, proving the metric itself would
    # catch a gap if one existed.
    my @hand_rows = ( [ { x => 0, w => 160 } ] );
    my $rightmost_end = $hand_rows[-1][-1]{x} + $hand_rows[-1][-1]{w};
    my $hand_dead = 200 - $rightmost_end;
    cmp_ok($hand_dead, '>', 0,
        'AC-L7: the dead_columns formula, applied directly to a hand-built band row with a 40-col unallocated margin, is > 0 (metric non-vacuity control case)');
}

# ---------------------------------------------------------------------------
# AC-L8 / AC-D3 — width machinery agrees with Dashboard where the tables
# overlap. A membership floor over the overlap, never over either whole
# table.
# ---------------------------------------------------------------------------
SKIP: {
    skip('tui:: modules not all loaded', 2) unless $ALL_LOADED;
    my $dash_ok = eval { require Dashboard; 1 };
  SKIP: {
        skip('Dashboard.pm did not load', 2) unless $dash_ok;
        my $dash_table   = Dashboard::glyph_table();
        my $theme_glyphs = Theme::glyphs();
        my @overlap_chars = grep { exists $dash_table->{$_} }
            map { $theme_glyphs->{$_}{char} } keys %$theme_glyphs;

        my @ascii_corpus = ('', 'a', 'hello world', 'The Quick Brown Fox', '1234567890', ' ' x 5);

        my ($dw_violations, $dw_first) = (0, undef);
        for my $s (@ascii_corpus) {
            my ($a, $b) = (tui::Layout::display_width($s), Dashboard::display_width($s));
            if ($a != $b) { $dw_violations++; $dw_first //= "display_width('$s'): tui=$a dashboard=$b"; }
        }
        for my $ch (@overlap_chars) {
            my ($a, $b) = (tui::Layout::display_width($ch), Dashboard::display_width($ch));
            if ($a != $b) { $dw_violations++; $dw_first //= sprintf("display_width(U+%04X): tui=%d dashboard=%d", ord($ch), $a, $b); }
        }
        is($dw_violations, 0,
            'AC-L8/AC-D3: tui::Layout::display_width agrees with Dashboard::display_width over ASCII + the Theme/Dashboard glyph overlap')
            or diag("  first mismatch: " . ($dw_first // '<none recorded>'));

        my ($cp_violations, $cp_first) = (0, undef);
        for my $s (@ascii_corpus) {
            for my $w (0, 1, 5, 20) {
                my ($a, $b) = (tui::Frame::clip_pad($s, $w), Dashboard::clip_pad($s, $w));
                if ($a ne $b) { $cp_violations++; $cp_first //= "clip_pad('$s',$w): tui='$a' dashboard='$b'"; }
            }
        }
        is($cp_violations, 0,
            'AC-L8/AC-D3: tui::Frame::clip_pad agrees with Dashboard::clip_pad over the ASCII corpus for several widths')
            or diag("  first mismatch: " . ($cp_first // '<none recorded>'));
    }
}

# ---------------------------------------------------------------------------
# AC-M1 — Decision 4's order: label, separator, numbers, bar, separator,
# percent -- the bar span precedes the percent span, identified structurally.
# ---------------------------------------------------------------------------
SKIP: {
    skip('tui::Meter/tui::Frame (and/or Theme) not all loaded', 3) unless $ALL_LOADED;
    my $spans = tui::Meter::row({ label => 'cpu', used => 40, total => 100 });
    ok(ref($spans) eq 'ARRAY' && @$spans >= 4, 'AC-M1: precondition -- a gauged row returns a non-trivial span list');
    my $full  = Theme::glyph('gauge.full');
    my $empty = Theme::glyph('gauge.empty');
    my ($bar_idx, $pct_idx);
    for my $i (0 .. $#$spans) {
        my $t = $spans->[$i]{text};
        next unless defined $t;
        $bar_idx = $i if !defined($bar_idx) && length($t) && $t =~ /\A(?:\Q$full\E|\Q$empty\E)+\z/;
        $pct_idx = $i if !defined($pct_idx) && $t =~ /\d+%/;
    }
    ok(defined($bar_idx) && defined($pct_idx), 'AC-M1: a gauge span and a percent span are both structurally identifiable in the row');
    ok((defined($bar_idx) && defined($pct_idx) && $bar_idx < $pct_idx),
        'AC-M1: Decision 4 order -- the bar span precedes the percent span');
}

# ---------------------------------------------------------------------------
# AC-M2 — the numeric column width is a NAMED constant, appearing exactly
# once in Meter.pm; min_width() is a recomputed derivation, never a literal.
# ---------------------------------------------------------------------------
SKIP: {
    skip('tui::Meter not loaded', 3) unless $LOADED{'tui::Meter'};
    my $const_val = tui::Meter::NUMERIC_COL_WIDTH();
    ok(defined($const_val) && $const_val > 0, 'AC-M2: tui::Meter::NUMERIC_COL_WIDTH() is a defined positive constant');

    my $path = $MODULE_FILE{'tui::Meter'};
    my $src  = slurp($path);
  SKIP: {
        skip('Meter.pm source unreadable', 1) unless defined $src;
        my @occurrences = ($src =~ /\b\Q$const_val\E\b/g);
        is(scalar(@occurrences), 1,
            "AC-M2: the literal $const_val appears exactly once in tui/Meter.pm (the NUMERIC_COL_WIDTH definition itself)");
    }

    my $expected_min = tui::Meter::LABEL_COL_WIDTH() + 3 + tui::Meter::NUMERIC_COL_WIDTH()
        + tui::Meter::BAR_CELLS() + 1 + tui::Meter::PERCENT_COL_WIDTH();
    is(tui::Meter::min_width(), $expected_min,
        'AC-M2: min_width() equals the sum recomputed from the six accessors (never a literal)');
}

# ---------------------------------------------------------------------------
# AC-M3 — THE Decision-4 guard: a wider figure fails the test. A corpus
# spanning fmt_bytes' units and boundaries, plus a non-vacuity floor.
#
# ROUND-2 ENRICHMENT (reviewer MAJOR-1 / redteam H3): the original seven-row
# corpus never sampled a triple where `used` AND `free` are INDEPENDENTLY
# large (every `total` was a round power of ten, which fmt_bytes always
# renders in exactly 6 columns -- the corpus could never produce three
# 8-column figures at once). Two rows below close that gap:
#   - a TB-tier, physically realistic (used+free ~= total) triple: measured
#     '500.0 TB used | 499.9 TB free | 999.9 TB total' = 46 display columns.
#   - the %.1f ROUNDING-BAND case: fmt_bytes rounds any figure in the top
#     ~0.005% of a decade UP into the next whole number before the unit is
#     chosen, so 999_999_999 (999.999999 MB) renders as '1000.0 MB' -- NINE
#     columns, not the spec's claimed maximum of eight. All three legs of
#     this triple sit in that band: measured
#     '1000.0 MB used | 1000.0 GB free | 1000.0 TB total' = 49 columns.
# NEITHER of these fits today's NUMERIC_COL_WIDTH (44), so both new rows are
# EXPECTED to turn this section red: that is the point -- criterion 4 says
# "a wider figure fails the test", and until now the corpus could not
# produce one. This is a MODULE fix (tui::Meter::NUMERIC_COL_WIDTH must
# widen to accommodate the true maximum), not a test fix.
# ---------------------------------------------------------------------------
SKIP: {
    skip('tui::Meter/tui::Layout not loaded', 2) unless $ALL_LOADED;
    my @CORPUS = (
        [500, 500, 1000],
        [999, 1, 1000],
        [1000, 500, 1500],
        [999_000, 1_000, 1_000_000],
        [500_000_000, 500_000_000, 1_000_000_000],
        [999_000_000_000, 1_000_000_000, 1_000_000_000_000],
        [undef, undef, undef],
        # TB-tier, used+free ~= total (reviewer MAJOR-1): 46 columns.
        [500_000_000_000_000, 499_900_000_000_000, 999_900_000_000_000],
        # %.1f rounding band, all three legs (redteam H3): 49 columns.
        [999_999_999, 999_999_999_999, 999_999_999_999_999],
    );
    my ($violations, $first, $max_width) = (0, undef, 0);
    for my $t (@CORPUS) {
        my $text = tui::Meter::numbers_used_free_total(@$t);
        if (!tui::Meter::fits_numeric_column($text)) {
            $violations++;
            $first //= "numbers_used_free_total(@{[ join(',', map { $_ // 'undef' } @$t) ]}) = '$text'";
        }
        my $w = tui::Layout::display_width($text);
        $max_width = $w if $w > $max_width;
    }
    is($violations, 0, 'AC-M3: every corpus triple fits the numeric column (fits_numeric_column true)')
        or diag("  first offender: " . ($first // '<none recorded>'));
    # Non-vacuity floor, derived FROM the corpus rather than pinned to a
    # literal: the widest corpus triple must render to EXACTLY
    # NUMERIC_COL_WIDTH columns. A floor of "at least one triple hits the
    # constant" is unsatisfiable against a corpus and a constant that were
    # authored independently (E-6) unless the two are reconciled to agree on
    # the same number; deriving the target from max(corpus width) makes the
    # assertion self-consistent and keeps the point of AC-M3 -- the column
    # stays tight against real data, so a widened fmt_bytes (or a
    # NUMERIC_COL_WIDTH that leaves slack) goes red.
    is($max_width, tui::Meter::NUMERIC_COL_WIDTH(),
        'AC-M3: the widest corpus triple renders to exactly NUMERIC_COL_WIDTH columns (non-vacuity floor, derived from the corpus itself)')
        or diag("  corpus max width: $max_width, NUMERIC_COL_WIDTH(): " . tui::Meter::NUMERIC_COL_WIDTH());
}

# ---------------------------------------------------------------------------
# AC-M4 — the bar column never moves, regardless of the numbers' width.
# ---------------------------------------------------------------------------
SKIP: {
    skip('tui::Meter/tui::Layout (and/or Theme) not all loaded', 1) unless $ALL_LOADED;
    my $full  = Theme::glyph('gauge.full');
    my $empty = Theme::glyph('gauge.empty');
    my @CORPUS = (
        { label => 'a', used => 1,         total => 100 },
        { label => 'b', used => 1_000_000, total => 2_000_000 },
        { label => 'c', used => 0,         total => 100 },
        { label => 'd', used => 100,       total => 100 },
    );
    my %starts;
    for my $spec (@CORPUS) {
        my $spans = tui::Meter::row($spec);
        my $col = 0;
        for my $s (@$spans) {
            my $t = $s->{text};
            if (defined($t) && length($t) && $t =~ /\A(?:\Q$full\E|\Q$empty\E)+\z/) { $starts{$col} = 1; last; }
            $col += tui::Layout::display_width($t);
        }
    }
    is(scalar(keys %starts), 1,
        'AC-M4: the bar span starts at the same display column for every gauged row regardless of the numbers width')
        or diag('  observed start columns: ' . join(', ', sort { $a <=> $b } keys %starts));
}

# ---------------------------------------------------------------------------
# AC-M5 — overflow truncates the figure, not the alignment.
# ---------------------------------------------------------------------------
SKIP: {
    skip('tui::Meter/tui::Layout (and/or Theme) not all loaded', 3) unless $ALL_LOADED;
    my $full  = Theme::glyph('gauge.full');
    my $empty = Theme::glyph('gauge.empty');
    my $overwide = 'x' x 100;
    my $spans = tui::Meter::row({ label => 'over', numbers => $overwide, used => 5, total => 10 });
    my $numbers_span = $spans->[2];   # label, sep, numbers, bar, sep, percent (Decision 4 order)
    is(tui::Layout::display_width($numbers_span->{text}), tui::Meter::NUMERIC_COL_WIDTH(),
        'AC-M5: an over-wide numbers figure is truncated to exactly NUMERIC_COL_WIDTH columns');
    ok(!tui::Meter::fits_numeric_column($overwide), 'AC-M5: fits_numeric_column on the original 100-char string is false');

    my ($col, $bar_start) = (0, undef);
    for my $s (@$spans) {
        my $t = $s->{text};
        if (defined($t) && length($t) && $t =~ /\A(?:\Q$full\E|\Q$empty\E)+\z/) { $bar_start = $col; last; }
        $col += tui::Layout::display_width($t);
    }
    my $normal_spans = tui::Meter::row({ label => 'n', used => 1, total => 2 });
    my ($col2, $bar_start2) = (0, undef);
    for my $s (@$normal_spans) {
        my $t = $s->{text};
        if (defined($t) && length($t) && $t =~ /\A(?:\Q$full\E|\Q$empty\E)+\z/) { $bar_start2 = $col2; last; }
        $col2 += tui::Layout::display_width($t);
    }
    is($bar_start, $bar_start2, "AC-M5: the over-wide row's bar starts at the same column as an ordinary gauged row");
}

# ---------------------------------------------------------------------------
# H1 regression (redteam) -- a truncated gauge bar is a false number. A bar
# clipped to N of BAR_CELLS() glyphs is byte-identical to a bar that IS
# N/BAR_CELLS full (80% pressure rendered with 2 of 10 blocks reads exactly
# like 20% pressure), so `make_cell()` fitting a gauged row into a width
# narrower than `min_width()` must never hand back a PARTIAL bar -- it is
# either every glyph or none. Swept across the exact band where this bites
# (from 15 columns short of `min_width()` up to `min_width()` itself, so the
# range is derived from the module's own constant, never a hardcoded 60..75).
# ---------------------------------------------------------------------------
SKIP: {
    skip('tui::Meter/tui::Frame (and/or Theme) not all loaded', 1) unless $ALL_LOADED;
    my $full      = Theme::glyph('gauge.full');
    my $empty     = Theme::glyph('gauge.empty');
    my $bar_cells = tui::Meter::BAR_CELLS();
    my $mw        = tui::Meter::min_width();
    my $row = tui::Meter::row({ label => 'memory', numbers => '6.4 GB used | 1.6 GB free | 8.0 GB total',
                                 used => 6.4e9, total => 8e9 });   # 80% pressure, a determinate gauge
    my ($violations, $first) = (0, undef);
    for my $w (($mw - 15) .. $mw) {
        my $cell  = tui::Frame::make_cell($row, 'text.primary', $w);
        my $count = () = $cell->{text} =~ /\Q$full\E|\Q$empty\E/g;
        if ($count != 0 && $count != $bar_cells) {
            $violations++;
            $first //= "w=$w: bar rendered with $count of $bar_cells glyphs (a partial bar is a false number)";
        }
    }
    is($violations, 0,
        "H1: a gauge bar fitted at any width from min_width()-15 to min_width() is either all $bar_cells glyphs or entirely absent, never partial")
        or diag("  first offender: " . ($first // '<none recorded>'));
}

# ---------------------------------------------------------------------------
# H2 regression (redteam) -- the numeric gate (`/^-?\d+(?:\.\d+)?$/`, reused
# by ratio/pressure_role/percent_text/bar/fmt_bytes) rejects Perl's own
# exponential stringification. `ratio()` itself produces such a string for
# a small-but-determinable ratio (e.g. 5e-06), so the very primitives that
# are supposed to consume what `ratio()` certifies then reject it -- the
# gauge, percent and colour all vanish while the numbers field stays
# padded (the inverse of criterion 5: stray padding for a fact the library
# DOES have). The same regex also rejects any `fmt_bytes` input that
# stringifies in scientific notation (>= 1e15, i.e. any figure at PB
# scale), degrading a known value to 'n/a'.
# ---------------------------------------------------------------------------
SKIP: {
    skip('tui::Meter (and/or Theme) not all loaded', 6) unless $ALL_LOADED;

    # (a)/(b)/(c) -- a tiny-but-determinable ratio: ratio() itself
    # stringifies to exponential notation (5e-06); every downstream
    # primitive must accept exactly what ratio() certified.
    my $tiny_ratio = tui::Meter::ratio(5_000_000, 1_000_000_000_000);   # 5 MB used of a 1 TB disk
    ok(defined($tiny_ratio), 'H2: ratio(5_000_000, 1_000_000_000_000) is defined (5 MB of 1 TB is a fact we have)');
  SKIP: {
        skip('ratio() itself returned undef -- cannot exercise the downstream primitives', 3) unless defined $tiny_ratio;
        ok(defined(tui::Meter::bar($tiny_ratio, 10)),
            'H2: bar() accepts the exponential-notation ratio that ratio() itself produced');
        ok(defined(tui::Meter::percent_text($tiny_ratio)),
            'H2: percent_text() accepts the exponential-notation ratio that ratio() itself produced');
        ok(defined(tui::Meter::pressure_role($tiny_ratio)),
            'H2: pressure_role() accepts the exponential-notation ratio that ratio() itself produced');
    }

    # (d) -- a PB-scale figure: fmt_bytes must format it, not degrade to
    # 'n/a' for a value we DO know. Written as a scientific literal (1e15)
    # deliberately -- that is exactly the form whose default Perl
    # stringification ('1e+15') the numeric gate rejects; an underscored
    # integer literal of the same magnitude would not reproduce the defect.
    my $pb_text = tui::Meter::fmt_bytes(1e15);
    isnt($pb_text, 'n/a', "H2: fmt_bytes(1e15) does not degrade to 'n/a' -- a 1 PB figure is a known value")
        or diag("  got: " . (defined($pb_text) ? "'$pb_text'" : 'undef'));

    # (e) -- a vanishing gauge (whichever cause) must never leave the
    # numbers field padded with no bar/percent to justify it: the mirror
    # image of criterion 5's "no trailing whitespace" rule, exercised at
    # the exact input that triggers this cliff. A gauged row (bar present)
    # is also an acceptable outcome (it means the gate no longer rejects
    # the ratio) -- either way there must be no orphaned padding.
    my $spans = tui::Meter::row({ label => 'disk', numbers => '5.0 MB used | 1.0 TB free | 1.0 TB total',
                                   used => 5_000_000, total => 1_000_000_000_000 });
    my $joined = join('', map { $_->{text} // '' } @$spans);
    unlike($joined, qr/\s\z/,
        'H2: used=5_000_000,total=1_000_000_000_000 -- whether or not the gauge renders, the row has no trailing whitespace (no orphaned padding)');
}

# ---------------------------------------------------------------------------
# AC-N1..N5 — never a phantom bar for a fact we do not have (criterion 5).
# ---------------------------------------------------------------------------
SKIP: {
    skip('tui::Meter (and/or Theme) not all loaded', 22) unless $ALL_LOADED;

    my @UNDETERMINABLE = ( [undef, 100], [5, undef], [5, 0], [5, -1], ['x', 100], [-1, 100] );
    for my $p (@UNDETERMINABLE) {
        is(tui::Meter::ratio(@$p), undef,
            "AC-N1: ratio(@{[ join(',', map { $_ // 'undef' } @$p) ]}) is undef");
    }
    is(tui::Meter::ratio(0, 100), 0, 'AC-N1: ratio(0,100) is 0, not undef -- a genuine zero is a fact we DO have');

    is(tui::Meter::bar(undef, 10), undef, 'AC-N2: bar(undef, $cells) is undef');

    my $full  = Theme::glyph('gauge.full');
    my $empty = Theme::glyph('gauge.empty');
    my $ctr_cpu = tui::Meter::row({ label => 'ctr cpu', numbers => '12.3%' });
    my $podman  = tui::Meter::row({ label => 'podman', numbers => 'images 3 | containers 1 | volumes 0' });
    for my $pair ([$ctr_cpu, 'ctr cpu'], [$podman, 'podman']) {
        my ($spans, $desc) = @$pair;
        my $has_bar = grep { defined($_->{text}) && length($_->{text}) && $_->{text} =~ /\A(?:\Q$full\E|\Q$empty\E)+\z/ } @$spans;
        ok(!$has_bar, "AC-N3: gauge-less row ($desc) emits no bar span");
        # Percent-span detector: identify STRUCTURALLY, never by a text regex.
        # Decision 4's fixed order/count is the spec's own guarantee (§2.4
        # rule 2/3, behaviors 16-17): a gauge-less row is EXACTLY 3 spans
        # (label, LABEL_SEP, numbers) -- rule 2 says "then STOP" -- while a
        # gauged row is EXACTLY 6 (label, sep, numbers, bar, sep, percent).
        # So the percent span, when the meter synthesizes one, is always the
        # 6th (index 5) and only exists when the span count is 6. A regex
        # over span text (e.g. /\d+%\z/) cannot distinguish that synthesized
        # span from a caller-supplied `numbers` value that itself happens to
        # end in '%' -- exactly this fixture's 'ctr cpu' => '12.3%', which
        # the spec requires to pass through verbatim (§2.4 rule 2).
        my $has_pct = scalar(@$spans) == 6 && defined($spans->[5]{text}) && length($spans->[5]{text});
        ok(!$has_pct, "AC-N3: gauge-less row ($desc) emits no percent span");
        my $joined = join('', map { $_->{text} // '' } @$spans);
        unlike($joined, qr/\s\z/, "AC-N3: gauge-less row ($desc) concatenated text has no trailing whitespace");
    }

    for my $p (@UNDETERMINABLE) {
        my ($used, $total) = @$p;
        my $spans = tui::Meter::row({ label => 'x', numbers => 'n/a', used => $used, total => $total });
        my $has_zero_pct    = grep { defined($_->{text}) && $_->{text} eq '0%' } @$spans;
        my $has_empty_glyph = grep { defined($_->{text}) && index($_->{text}, $empty) >= 0 } @$spans;
        ok(!$has_zero_pct && !$has_empty_glyph,
            "AC-N4: undeterminable ratio (@{[ join(',', map { $_ // 'undef' } @$p) ]}) never renders a 0% span or a gauge.empty glyph");
    }

    my $zero_spans = tui::Meter::row({ label => 'zero', numbers => '0 used | 100 free | 100 total', used => 0, total => 100 });
    my $has_bar0 = grep { defined($_->{text}) && length($_->{text}) && $_->{text} =~ /\A(?:\Q$full\E|\Q$empty\E)+\z/ } @$zero_spans;
    ok($has_bar0, 'AC-N5: used=>0,total=>100 DOES emit a bar span (a genuine zero is not a missing fact)');
    my $has_pct0 = grep { defined($_->{text}) && $_->{text} eq '0%' } @$zero_spans;
    ok($has_pct0, 'AC-N5: used=>0,total=>100 DOES emit a 0% percent span');
}

# ---------------------------------------------------------------------------
# AC-S2 — compose() shape and degradation ladder.
# ---------------------------------------------------------------------------
SKIP: {
    skip('tui::Screen not loaded', 9) unless $LOADED{'tui::Screen'};
    my $screen = { title => 'Title', panels => [ { title => 'P', lines => ['a'] } ], footer => 'Footer' };

    my $c1 = tui::Screen::compose($screen, 1, 40);
    is(scalar(@$c1), 1, 'AC-S2: rows==1 -> exactly 1 cell (title only)');

    my $c2 = tui::Screen::compose($screen, 2, 40);
    is(scalar(@$c2), 2, 'AC-S2: rows==2 -> exactly 2 cells (title + footer)');

    my $c0 = tui::Screen::compose($screen, 0, 40);
    is_deeply($c0, [], 'AC-S2: rows<1 -> []');

    for my $rows (1, 5, 24, 60) {
        for my $cols (60, 200) {
            my $cells = tui::Screen::compose($screen, $rows, $cols);
            is(scalar(@$cells), $rows, "AC-S2: rows=$rows cols=$cols -> exactly \$rows cells");
        }
    }

    my $many_banners_screen = {
        title   => 'T',
        banners => [ 'first (kept)', 'second (dropped)', 'third (dropped)' ],
        panels  => [ { title => 'P', lines => ['body line'] } ],
        footer  => 'F',
    };
    my $tight  = tui::Screen::compose($many_banners_screen, 4, 40);
    my $joined = join("\n", map { $_->{text} } @$tight);
    like($joined, qr/first \(kept\)/, 'AC-S2: banners -- the most-important-first banner survives when space is tight');
    unlike($joined, qr/third \(dropped\)/, 'AC-S2: banners -- a surplus banner is dropped from the END of the list first');
}

# ---------------------------------------------------------------------------
# AC-S3 — viewport() arithmetic, table-driven.
# ---------------------------------------------------------------------------
SKIP: {
    skip('tui::Screen not loaded', 12) unless $LOADED{'tui::Screen'};
    my @CASES = (
        [0,   10,  5,     { first=>0,  last=>-1, above=>0,  below=>0,  count=>0  }],
        [10,  0,   5,     { first=>0,  last=>-1, above=>0,  below=>0,  count=>0  }],
        [5,   10,  2,     { first=>0,  last=>4,  above=>0,  below=>0,  count=>5  }],
        [50,  10,  0,     { first=>0,  last=>9,  above=>0,  below=>40, count=>10 }],
        [50,  10,  49,    { first=>40, last=>49, above=>40, below=>0,  count=>10 }],
        [50,  10,  undef, { first=>40, last=>49, above=>40, below=>0,  count=>10 }],
        [50,  1,   25,    { first=>25, last=>25, above=>25, below=>24, count=>1  }],
        [50,  10,  -5,    { first=>0,  last=>9,  above=>0,  below=>40, count=>10 }],
        [50,  10,  999,   { first=>40, last=>49, above=>40, below=>0,  count=>10 }],
        ['abc', 10, 5,    { first=>0,  last=>-1, above=>0,  below=>0,  count=>0  }],
        [50,  'xyz', 5,   { first=>0,  last=>-1, above=>0,  below=>0,  count=>0  }],
        [50,  10,  'abc', { first=>40, last=>49, above=>40, below=>0,  count=>10 }],
    );
    for my $c (@CASES) {
        my ($total, $height, $cursor, $exp) = @$c;
        my $got = tui::Screen::viewport($total, $height, $cursor);
        is_deeply($got, $exp,
            sprintf("AC-S3: viewport(%s, %s, %s)", $total // 'undef', $height // 'undef', $cursor // 'undef'));
    }
}

# ---------------------------------------------------------------------------
# Escape-leak regression (redteam, dispatch question 2) -- through the
# SANCTIONED path (make_cell -> spanify -> safe -> fit_spans) five payload
# classes are proven clean elsewhere in this file (AC-P2's source scan) and
# by the redteam's own byte-for-byte measurement. But `tui::Layout::wrap`
# returns UNSANITISED spans (it copies each word's text through untouched)
# and `tui::Frame::paint_row` performs no sanitisation of its own -- it
# just wraps whatever text a span carries in `Theme::sgr`/`Theme::reset`.
# A caller who paints a `wrap()` result directly (a natural thing to write:
# 08-launcher-screens wraps subprocess stderr, text it does not control)
# can leak a raw escape into the terminal stream through this public-but-
# not-sanctioned path, even though every span passed through `make_cell`
# stays clean. `\e[31m` (red foreground) does not collide with any of
# Theme's own SGR codes (verified: none of Theme's role 'none'-capability
# attrs is literally '31'), so its presence in painted output is
# unambiguously the caller's leaked payload, not a legitimate Theme escape.
# ---------------------------------------------------------------------------
SKIP: {
    skip('tui::Layout/tui::Frame not loaded', 1) unless $ALL_LOADED;
    my $wrapped = tui::Layout::wrap(['safe', "bad\e[31m"], 40, 'text.primary');
    my $painted = tui::Frame::paint_row({ spans => $wrapped->[0] }, 'none');
    unlike($painted, qr/\e\[31m/,
        'escape-leak: paint_row({ spans => wrap(...)->[0] }, $cap) never emits a raw caller-supplied \e[31m (public-but-not-sanctioned path)');
}

# ---------------------------------------------------------------------------
# AC-S4 — diff() behaviour: full redraw on first render/length change,
# exactly the changed indices otherwise, including a colour-only change.
# ---------------------------------------------------------------------------
SKIP: {
    skip('tui::Screen/tui::Frame not loaded', 5) unless $ALL_LOADED;
    my $c1 = tui::Frame::make_cell('one',   'text.primary', 10);
    my $c2 = tui::Frame::make_cell('two',   'text.primary', 10);
    my $c3 = tui::Frame::make_cell('three', 'text.primary', 10);

    is_deeply(tui::Screen::diff(undef, [$c1, $c2, $c3]), [0, 1, 2], 'AC-S4: @old undef -> full redraw');
    is_deeply(tui::Screen::diff([], [$c1, $c2, $c3]), [0, 1, 2], 'AC-S4: @old empty -> full redraw');
    is_deeply(tui::Screen::diff([$c1, $c2], [$c1, $c2, $c3]), [0, 1, 2], 'AC-S4: length mismatch -> full redraw');
    is_deeply(tui::Screen::diff([$c1, $c2, $c3], []), [], 'AC-S4: @new empty -> []');

    my $c2_colour = tui::Frame::make_cell('two', 'accent', 10);   # same text, different role
    my $changed = tui::Screen::diff([$c1, $c2, $c3], [$c1, $c2_colour, $c3]);
    is_deeply($changed, [1], 'AC-S4: a colour-only change (same text, different span role) is reported');
}

# ---------------------------------------------------------------------------
# AC-S5 — each named consumer's shape is met by the contract as written.
# ---------------------------------------------------------------------------
SKIP: {
    skip('tui:: modules not all loaded', 2) unless $ALL_LOADED;
    my @panels06 = (
        { title => 'Sandbox', lines => ['container : demo'] },
        { title => 'Run',     lines => ['status : running'] },
    );
    my $wide = tui::Screen::compose({ title => 'T', panels => \@panels06, footer => 'F' }, 24, 120);
    my $both_wide = grep { $_->{text} =~ /-- Sandbox / && $_->{text} =~ /-- Run / } @$wide;
    is($both_wide, 1, 'AC-S5(06): two panels at 120 cols -- exactly one band row carries both panel titles');

    my $narrow = tui::Screen::compose({ title => 'T', panels => \@panels06, footer => 'F' }, 24, 80);
    my $both_narrow = grep { $_->{text} =~ /-- Sandbox / && $_->{text} =~ /-- Run / } @$narrow;
    is($both_narrow, 0, 'AC-S5(06): the same two panels at 80 cols -- no row carries both panel titles');
}

SKIP: {
    skip('tui:: modules not all loaded', 3) unless $ALL_LOADED;
    my @items = map { "item $_" } (1 .. 50);
    my $vp = tui::Screen::viewport(50, 10, 30);
    my $cursor_glyph = Theme::glyph('cursor');
    my @lines;
    for my $i ($vp->{first} .. $vp->{last}) {
        if ($i == 30) {
            push @lines, [ { text => $cursor_glyph . ' ', role => 'accent' }, { text => $items[$i], role => 'accent' } ];
        } else {
            push @lines, $items[$i];
        }
    }
    my $screen07 = {
        title   => 'Backpack',
        banners => ['Confirm: drop item? [y/n]'],
        panels  => [ { title => 'Items', lines => \@lines } ],
        footer  => 'F',
    };
    my $rows07 = 2 + 1 + $vp->{count};   # title + footer + 1 banner + body
    my $cells07 = tui::Screen::compose($screen07, $rows07, 60);
    is(scalar(@$cells07), $rows07, 'AC-S5(07): composes to exactly $rows valid cells');
    like($cells07->[1]{text}, qr/Confirm: drop item/, 'AC-S5(07): the confirm banner is on row 1');
    my $cursor_count = grep { index($_->{text}, $cursor_glyph) >= 0 } @$cells07;
    is($cursor_count, 1, 'AC-S5(07): the cursor glyph is present exactly once');
}

SKIP: {
    skip('tui:: modules not all loaded', 3) unless $ALL_LOADED;
    my @progress = map { "progress line $_" } (1 .. 200);
    my $vp8  = tui::Screen::viewport(200, 8, undef);   # tail-follow
    my @tail = @progress[$vp8->{first} .. $vp8->{last}];
    my $wrapped = tui::Layout::wrap([ 'E' x 600 ], 60, 'state.crit');
    my $screen08 = {
        title  => 'Launcher',
        panels => [
            { title => 'Progress', lines => \@tail },
            { title => 'Failure',  lines => $wrapped },
        ],
        footer => 'F',
    };
    my $rows8 = 24;
    my $cells8 = tui::Screen::compose($screen08, $rows8, 70);
    is(scalar(@$cells8), $rows8, 'AC-S5(08): composes to exactly $rows valid cells');
    my $joined8 = join("\n", map { $_->{text} } @$cells8);
    like($joined8, qr/\Qprogress line 200\E/, 'AC-S5(08): the LAST progress line (tail-followed) is present');
    my $overflow = grep { tui::Frame::spans_width($_->{spans}) > 70 } @$cells8;
    is($overflow, 0, 'AC-S5(08): no cell is wider than the band width (70 cols)');
}

# ---------------------------------------------------------------------------
# L. Accented Latin survives the sanitiser.
#
#    safe() used to fall through to '?' for every non-ASCII character that was
#    not a declared Theme glyph. Latin-1 was collateral: this machine's home
#    directory carries an accented letter, so every project path on it lost
#    that letter in every frame the library draws — dashboard, backpack screen,
#    and each launcher screen built on them. It had already been written into a
#    package spec as an accepted limitation before anyone checked whether the
#    width was actually unknown. It was not: char_cols() returns 1 for these,
#    correctly, so the substitution was discarding information the layout
#    arithmetic already had.
#
#    Input is UTF-8 BYTES throughout, which is safe()'s documented contract
#    (its own header: "safe($str) -> a UTF-8 BYTE string"). A decoded string
#    whose codepoints all sit at or below 0xFF is genuinely indistinguishable
#    from raw bytes, which is why the contract is bytes and why these fixtures
#    honour it rather than papering over the ambiguity.
# ---------------------------------------------------------------------------
{
    my $accented = decode('UTF-8', tui::Frame::safe(encode('UTF-8', "Andr\x{e9}")));
    is($accented, "Andr\x{e9}",
       'L1: safe() preserves an accented Latin letter — the project rule is that '
     . 'nothing may assume ASCII paths, and the home directory this repo runs '
     . 'from is itself non-ASCII');

    my $mixed = decode('UTF-8', tui::Frame::safe(encode('UTF-8', "caf\x{e9} na\x{ef}ve \x{142}\x{f3}d\x{17a}")));
    is($mixed, "caf\x{e9} na\x{ef}ve \x{142}\x{f3}d\x{17a}",
       'L2: and across the whole narrow-Latin range, not just Latin-1 '
     . '(U+0142/U+017A are Latin Extended-A)');

    # Width is the thing being claimed, so assert the claim rather than trusting
    # that it renders: an accented name must occupy the same columns as its
    # unaccented twin, or every frame built on it is silently one column out.
    is(tui::Layout::display_width(encode('UTF-8', "caf\x{e9}")),
       tui::Layout::display_width('cafe'),
       'L3: an accented name measures the same width as its ASCII twin — the '
     . 'column arithmetic was always right, which is why the substitution was '
     . 'pure loss');

    # THE COUNTER-FIXTURES. Widening the allowed set is only safe because it
    # stopped short of characters whose width this library cannot claim. If
    # these pass through too, L1..L3 are not evidence of a careful boundary —
    # they are evidence the sanitiser stopped sanitising.
    my $wide = decode('UTF-8', tui::Frame::safe(encode('UTF-8', "\x{4e2d}\x{6587}")));
    is($wide, '??',
       'L4: counter-fixture — a character whose column width this library does '
     . 'NOT know is still replaced; the fix widened the whitelist, it did not '
     . 'remove it');

    my $ctrl = decode('UTF-8', tui::Frame::safe("a\x{9b}b"));
    unlike($ctrl, qr/\x{9b}/,
       'L5: counter-fixture — a C1 control byte is still not passed through; '
     . 'the escape-injection guard is untouched by the Latin widening');

    my $zero = decode('UTF-8', tui::Frame::safe(encode('UTF-8', "x\x{300}")));
    is($zero, 'x',
       'L6: counter-fixture — a zero-width combining mark is still deleted '
     . 'rather than admitted as a narrow character');
}

done_testing();
