#!/usr/bin/perl
# Claude Code status line -- Perl core modules only, no external deps.
#
# Row 1: marker, project name, full working directory, git, plans.
# Row 2: model, context window, plan usage.
#
# THIS FILE IS A STANDALONE INSTALLED PAYLOAD. It is bind-mounted read-only
# into the sandbox container at /root/.claude/statusline.pl and installed to
# ~/.claude/statusline.pl on the host, so it must import NOTHING from this
# repo -- core modules only, no search-path manipulation, no path require.
# Shared truth reaches it two other ways instead:
#   * colours, through the GENERATED token block below (the block records
#     its own regeneration command);
#   * glyph widths, through the inline %GLYPH_COLS table, which a drift
#     guard in the test suite compares against the canonical width table.
# Neither is a dependency: both are checked, not imported.
use strict;
use warnings;
use JSON::PP;
use Time::Piece;
use File::Basename;
use Cwd ();    # the generated payload calls Cwd::abs_path but may not import (spec 2.2)
use constant MIN_CWD_COLS     => 2;
use constant MIN_PROJECT_COLS => 2;

binmode STDOUT, ':utf8';

my $raw  = do { local $/; my $r = <STDIN>; defined($r) ? $r : '' };
# Malformed or truncated stdin must not cost the user their statusline. An
# unguarded decode dies with exit 255 and prints the exception where the two
# rows belong -- worse than a statusline with empty fields. Degrade to an
# empty payload instead; every read below already tolerates a missing key.
my $data = eval { decode_json($raw) };
$data = {} unless ref($data) eq 'HASH';

# ── Colours ──────────────────────────────────────────────────
# Every colour in this file is derived from %THEME_RGB by ROLE NAME. No
# numeric colour literal survives anywhere. %THEME_X256 and %THEME_ATTR are
# part of the byte-exact generated payload and are deliberately left unused
# -- do not "tidy" them away, the block is compared byte-for-byte.
# >>> BEGIN GENERATED FROM Theme.pm -- DO NOT EDIT BY HAND >>>
# THEME TOKENS -- generated from plugins/sandbox/scripts/Theme.pm.
# Regenerate: perl -Iplugins/sandbox/scripts -MTheme -e "print Theme::generated_block()"
my %THEME_RGB = (
  'accent' => [66,148,250],
  'gauge.crit' => [236,93,94],
  'gauge.low' => [0,144,255],
  'gauge.mid' => [18,165,148],
  'gauge.track' => [68,68,68],
  'gauge.warn' => [247,107,21],
  'overlay.warn' => [245,245,245],
  'rule' => [60,70,85],
  'state.crit' => [255,90,90],
  'state.idle' => [110,126,148],
  'state.ok' => [26,168,74],
  'state.warn' => [214,128,16],
  'text.faint' => [100,116,139],
  'text.muted' => [148,163,184],
  'text.primary' => [230,230,230],
);
my %THEME_X256 = (
  'accent' => 69,
  'gauge.crit' => 203,
  'gauge.low' => 33,
  'gauge.mid' => 36,
  'gauge.track' => 238,
  'gauge.warn' => 202,
  'overlay.warn' => 255,
  'rule' => 238,
  'state.crit' => 203,
  'state.idle' => 244,
  'state.ok' => 35,
  'state.warn' => 172,
  'text.faint' => 243,
  'text.muted' => 248,
  'text.primary' => 254,
);
my %THEME_ATTR = (
  'accent' => '1',
  'gauge.crit' => '',
  'gauge.low' => '',
  'gauge.mid' => '',
  'gauge.track' => '',
  'gauge.warn' => '',
  'overlay.warn' => '1',
  'rule' => '2',
  'state.crit' => '1',
  'state.idle' => '2',
  'state.ok' => '1',
  'state.warn' => '1',
  'text.faint' => '2',
  'text.muted' => '2',
  'text.primary' => '',
);
my %THEME_BG = (
  'overlay.warn' => [59,10,10],
);
# <<< END GENERATED FROM Theme.pm <<<

# rgb($role) -> the truecolor SGR string for a semantic role, or '' for an
# unknown role. The only place an escape is composed from channel values,
# and those values come from the generated table, never from a literal.
sub rgb {
    my ($role) = @_;
    my $t = defined($role) ? $THEME_RGB{$role} : undef;
    return '' unless ref($t) eq 'ARRAY';
    my ($r, $g, $b) = @$t;
    return "\033[38;2;$r;$g;${b}m";
}

# bgrgb($role) -> the truecolor BACKGROUND SGR for a role that declares one
# (%THEME_BG), or '' for a role without a background. rgb()'s sibling.
sub bgrgb {
    my ($role) = @_;
    my $t = defined($role) ? $THEME_BG{$role} : undef;
    return '' unless ref($t) eq 'ARRAY';
    my ($r, $g, $b) = @$t;
    return "\033[48;2;$r;$g;${b}m";
}

my $R       = "\033[0m";
my $B       = "\033[1m";
my $ACCENT  = rgb('accent');
my $RULE    = rgb('rule');
my $PRIMARY = rgb('text.primary');
my $MUTED   = rgb('text.muted');
my $FAINT   = rgb('text.faint');
my $OK      = rgb('state.ok');
my $WARN    = rgb('state.warn');
my $CRIT    = rgb('state.crit');
my $SEP     = " ${RULE}\x{FF5C}${R} ";

# Theme's 'thread.blocked' codepoint (Decision 54: U+229D CIRCLED DASH, a
# reversible stand-in for Decision 12's U+26D4, which fails the no-colour-
# emoji guards). Named once here so a future swap touches exactly the three
# places that need the literal: this constant, %GLYPH_COLS below and the
# render site in thread_row -- never a fourth hard-coded \x{229D} (review N5).
my $G_BLOCKED = "\x{229D}";

# ── Display width ────────────────────────────────────────────
# %GLYPH_COLS declares the display width of every non-single-column glyph
# this file can emit. U+FF5C (the segment separator) is FULL-WIDTH: two
# columns, not one. Anything absent from the table counts one column. A
# drift guard in the suite fails if a declared width disagrees with the
# canonical glyph table, so this stays honest without an import.
my %GLYPH_COLS = (
    0xFF5C => 2,
    0x3000 => 2,
    0x2191 => 1,
    0x2193 => 1,
    # The blueprints icon (2026-08-26). East-Asian-ambiguous, so terminals
    # disagree about it -- declared as one column, which is what a monospaced
    # terminal renders it as and what the row budget must assume.
    0x29C9 => 1,
    # The todos icon (package 01-statusline-counters, 2026-09). East-Asian
    # neutral, one column, declared explicitly to match Theme.pm.
    0x274F => 1,
    # The notes icon (package 10). East-Asian-WIDE, so two columns.
    0x2630 => 2,
    # The thread row's glyphs (package 12-statusline-threads, spec 2.4).
    # U+25B6, U+2192 and U+2502 are East-Asian-ambiguous; the rest default to
    # one column anyway, but every glyph the thread row can emit is declared
    # explicitly so the AC-S5/AC-8 drift guards stay meaningful for all of
    # them, not just the ambiguous ones.
    0x23E3 => 1,   # icon.threads, the row-1 thread counter / thread-row lead
    0x25B0 => 1,   # thread.full, a done task in the bar
    0x25B1 => 1,   # thread.empty, an open task in the bar
    0x25B6 => 1,   # cursor, the thread row's "doing" marker
    0x2192 => 1,   # arrow.right, the thread row's "next" marker
    0x2502 => 1,   # rule.v, the thread row's path separator
    0x23F8 => 1,   # thread.idle, nothing doing
    ord($G_BLOCKED) => 1,   # thread.blocked, the current task is blocked
);

# row_cost($fragment) -> the budget a rendered fragment consumes.
# SGR escapes are stripped first; the result is the LARGER of the column sum
# and the UTF-8 byte length. Both terms are kept deliberately: a terminal
# budgets in columns, but the output-hygiene oracle measures the raw byte
# stream, so honouring both means a row that fits one always fits the other.
# For this alphabet the byte term usually dominates, which makes truncation
# start marginally early -- declared conservatism, not a defect.
sub row_cost {
    my ($s) = @_;
    return 0 unless defined $s;
    $s =~ s/\033\[[^m]*m//g;
    my $cols = 0;
    $cols += ($GLYPH_COLS{ ord($_) } // 1) for split //, $s;
    my $bytes = $s;
    utf8::encode($bytes) if utf8::is_utf8($bytes);
    my $n = length($bytes);
    return $cols > $n ? $cols : $n;
}

# ── Elision, and the non-ambiguity guarantee ─────────────────
# THE ELISION MARKER IS NON-NEGOTIABLE. A shortened field that dropped its
# '>' / '<' would be presented to the reader as if it were whole -- exactly
# the ambiguity criterion 4 exists to forbid. So no path through either
# primitive below returns a bare fragment of the text:
#
#   * $max < 1              -> '' (the field does not render at all);
#   * the text fits         -> the text, verbatim, with no marker;
#   * $max < 2              -> the BARE MARKER. Nothing else can be shown in
#                              one column, and the fit ladder's bottom rungs
#                              ask for exactly this;
#   * $max >= 2 but not one
#     whole character fits
#     beside the marker     -> marker PLUS one whole character anyway.
#
# That last case is a deliberate, BOUNDED overrun of $max (at most three
# columns, the excess of one 4-byte character) and it is safe because $max is
# a FIELD budget, not the row's: the ladder re-measures the whole row after
# every rung and answers an overrun with the next rung. The alternative --
# a bare marker while the project field is still on the row -- would discard
# the very text the field exists to carry and would break §2.4.4's N1/N2,
# which require a NON-EMPTY prefix/suffix beside the marker.

# fit_head($text, $max) -> $text if it fits, else a NON-EMPTY PREFIX of it
# with an ASCII '>' appended. The head of a name is what identifies it, so
# the head is what a shortened name keeps.
sub fit_head {
    my ($text, $max) = @_;
    $text = '' unless defined $text;
    return '' unless length($text);
    return '' if $max < 1;
    return $text if row_cost($text) <= $max;
    return '>' if $max < 2;
    # AN ANSI ESCAPE IS ATOMIC AND ZERO-WIDTH HERE (g01 step-8 UI pass).
    # This used to `split //` and accumulate per character, which was correct
    # while every caller passed plain text -- but g01's WATCHED badge put colour
    # escapes into the marker field, and at <=14 columns rung 8 sliced one in
    # half and emitted a malformed CSI to the terminal (observed:
    # "\e[38;>" at cols=14, "\e>" at cols=10 -- and \e> is a real control,
    # Normal Keypad mode, so this could leave a terminal in an unintended state
    # rather than merely looking wrong). row_cost already strips SGR before
    # measuring, so an escape costs nothing and is always safe to carry whole.
    my $out = '';
    my $kept_visible = 0;
    my $ESC_TOK = qr/\e\[[0-9;:?]*[ -\/]*[\@-~]|\e[\@-_]/;
    for my $tok ($text =~ /($ESC_TOK|.)/gs) {
        if ($tok =~ /\A\e/) { $out .= $tok; next; }
        last if row_cost($out . $tok) > $max - 1;
        $out .= $tok;
        $kept_visible++;
    }
    unless ($kept_visible) {
        # Keep any leading escapes with the first visible character, so the
        # fallback cannot split one either.
        ($out) = $text =~ /\A((?:$ESC_TOK)*.)/s;
        $out = '' unless defined $out;
    }
    # Close any colour we opened but did not close, so a truncated field cannot
    # bleed into the rest of the row.
    $out .= "\033[0m" if $out =~ /\e\[/ && $out !~ /\e\[0m\z/;
    return $out . '>';
}

# fit_tail($text, $max) -> $text if it fits, else an ASCII '<' followed by a
# NON-EMPTY SUFFIX of it. The tail of a path is what says where you are; the
# head is the part a reader can infer.
sub fit_tail {
    my ($text, $max) = @_;
    $text = '' unless defined $text;
    return '' unless length($text);
    return '' if $max < 1;
    return $text if row_cost($text) <= $max;
    return '<' if $max < 2;
    my @ch  = split //, $text;
    my $out = '';
    while (@ch) {
        my $c = pop @ch;
        last if row_cost($c . $out) > $max - 1;
        $out = $c . $out;
    }
    $out = substr($text, -1) unless length($out);
    return '<' . $out;
}

# ── Spawning, without a shell ────────────────────────────────
# $workspace arrives from stdin JSON and is a DIRECTORY NAME: on POSIX it may
# legally contain '"', ';', a backtick or '$( )', and this script runs inside
# the Linux container. Interpolating it into a backtick or system() string
# therefore hands an attacker-controlled string to /bin/sh AS CODE -- a
# current_dir of `/tmp"; echo pwned 1>&2; git #` really did execute. Every
# spawn below is LIST-FORM: perl execs the binary directly, so no argument of
# ours can ever be reparsed as a command.
#
# The shell was also what supplied `2>/dev/null`, so stderr is silenced
# explicitly instead. ('nul' is perl's null device on Win32; this is an
# open() call, not a shell redirect, so the usual NUL-file hazard does not
# apply.)
my $DEVNULL = ($^O eq 'MSWin32') ? 'nul' : '/dev/null';

# quiet_stderr() -> a coderef that puts STDERR back. Between the two, the
# process's stderr goes to the null device, so a spawned child's diagnostics
# (`fatal: not a git repository`) never reach the terminal.
sub quiet_stderr {
    my $saved;
    return sub { } unless open($saved, '>&', \*STDERR);
    open(STDERR, '>', $DEVNULL);
    return sub { open(STDERR, '>&', $saved); close($saved); };
}

# cmd_out(@argv) -> the command's stdout, or '' if it could not be run.
sub cmd_out {
    my (@argv) = @_;
    my $restore = quiet_stderr();
    my $out;
    if (open(my $fh, '-|', @argv)) {
        $out = do { local $/; <$fh> };
        close($fh);
    }
    $restore->();
    return defined($out) ? $out : '';
}

# spawn_detached(@argv) -> fire-and-forget, never waited on. The trailing '&'
# that used to background these needed a shell, which is precisely what the
# list form removes; fork + exec is the shell-free equivalent. A platform
# without fork simply skips the spawn -- both callers are opportunistic
# refreshes whose absence costs nothing this render.
sub spawn_detached {
    my (@argv) = @_;
    my $pid = fork();
    return unless defined $pid;
    return if $pid;
    open(STDIN,  '<', $DEVNULL);
    open(STDOUT, '>', $DEVNULL);
    open(STDERR, '>', $DEVNULL);
    { no warnings 'exec'; exec { $argv[0] } @argv; }
    CORE::exit(127);
}

# ── Almanac counters (generated) ─────────────────────────────
# The counting code for todos, notes, the thread and the operator's inbox. It
# cannot be imported (this file loads nothing from the repo) and must not
# spawn (a subprocess per render costs ~292 ms on the Windows host), so it is
# GENERATED next to the almanac modules and carried here byte for byte. A
# test regenerates it and compares; edit the generator, never this block.
# >>> BEGIN GENERATED FROM gen-statusline-counters.pl -- DO NOT EDIT BY HAND >>>
# ALMANAC COUNTERS -- generated from plugins/almanac/scripts/gen-statusline-counters.pl.
# Regenerate: perl plugins/almanac/scripts/gen-statusline-counters.pl
#
# The one shared accessor for almanac counts, restated from Almanac::Store,
# Almanac::GlobalCounts, Almanac::PackageLink and Almanac::Thread because
# this file may import nothing. Every public sub wraps its body in eval and
# degrades to the "unavailable" value (undef); nothing here ever dies to its
# caller, spawns, or writes. Paths are byte strings throughout.
#
#   almanac_counts(cwd => $dir, sandbox => 0|1) -> {
#       project => { todo, note, thread, inbox } | undef,
#       global  => { todo, note, thread } | undef }
#   almanac_thread(cwd => $dir, session => $sid) -> undef | {
#       name, done, total, doing => [ \%label, ... ],
#       current => \%label | undef, next => \%label | undef }
#     %label = ( class => 'doing'|'blocked'|'pending',
#                kind => 'text', title => $text, waits_on => $text|undef )
#            | ( class => ..., kind => 'link', blueprint => $bp,
#                number => $nn, step => $word )
#   blueprint where-things-go, package 12-statusline-threads (spec section
#   2). almanac_focus and the flat-tasklist "task" count are RETIRED
#   (Decision 3): the row-1 counter and the directory row now read threads.
my $ALMANAC_SNAPSHOT_NAME = 'almanac-global-counts.json';
my $ALMANAC_LEGACY_INBOX_DIR = 'decision';
my $ALM_PKG_STATUS_OK = { map { ($_ => 1) } qw(pending running converging reviewing done blocked parked dropped) };
# Frontmatter already read this render, keyed by the record dir's identity
# (device and inode where the platform has them, else its path) plus the
# entry name. An attached thread's own record and its task records are each
# read once, not twice, even though almanac_counts and almanac_thread both
# scan thread/ -- a file open is the dominant cost of a render.
my $ALMANAC_FM_SEEN = {};
my $ALMANAC_DIR_KEY = {};
# Per-render memo of _alm_link_resolve, keyed by "$root\0$link" -- spec 5
# requires each ledger be read at most once per render; without this, K tasks
# linking the same package re-read and re-scan the ledger K times.
my $ALMANAC_LINK_SEEN = {};
# _alm_bytes($s) -> $s as UTF-8 bytes. A JSON-decoded path is a character
# string; the filesystem wants the bytes.
sub _alm_bytes {
    my ($s) = @_;
    return '' unless defined $s && !ref($s);
    $s = "$s";
    utf8::encode($s) if utf8::is_utf8($s);
    return $s;
}
sub _alm_is_abs {
    my ($p) = @_;
    return 0 unless defined $p && length $p;
    return 1 if substr($p, 0, 1) eq '/';
    return ($p =~ m{\A[A-Za-z]:(?:/|\z)}) ? 1 : 0;
}
# _alm_is_id($id) -> 1 when $id is a record id (Almanac::Store's grammar).
sub _alm_is_id {
    my ($id) = @_;
    return 0 unless defined $id && !ref($id);
    return 0 unless length($id) <= 128 && $id =~ /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/;
    return 0 if index($id, '..') >= 0;
    return 0 if $id =~ /\A(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])\z/i;
    return 1;
}
# _alm_sw_* / $ALMANAC_SW_IS_WIN / _alm_bounded_walk -- a PRIVATE mirror of
# plugins/butler/scripts/BpDataRoot.pm's bounded walk-up (R1-R4), restated
# here because this file may import nothing (AC-S3/AC-9). The marker kept is
# this file's own: .ccpraxis-local-data OR .git, matching
# Almanac::Store::_bounded_walk (unlike BpDataRoot.pm, which never looks at
# .git). A parity test (statusline-bounded-walkup.t AC-3) asserts the 11
# stop-rule subs below are source-identical to BpDataRoot.pm, modulo naming.
my $ALMANAC_SW_IS_WIN = ($^O =~ /^(MSWin32|msys|cygwin)$/) ? 1 : 0;
sub _alm_sw_fold_ascii {
    my ($s) = @_;
    return $s unless defined $s;
    (my $t = $s) =~ tr/A-Z/a-z/;
    return $t;
}
sub _alm_sw_is_abs_ish {
    my ($p) = @_;
    return 0 unless defined $p && length $p;
    return 1 if $p =~ m{^/};
    return 1 if $p =~ m{^[A-Za-z]:[\\/]};
    return 1 if $ALMANAC_SW_IS_WIN && $p =~ m{^\\};
    return 0;
}
sub _alm_sw_lex_canon {
    my ($p) = @_;
    return '' unless defined $p;
    (my $s = $p) =~ s{\\}{/}g;
    my $drive_prefix = '';
    if ($ALMANAC_SW_IS_WIN) {
        if ($s =~ m{^/([A-Za-z])(/.*)?$}) {
            my $rest = defined $2 ? $2 : '/';
            $s = lc($1) . ':' . $rest;
        }
        elsif ($s =~ m{^([A-Za-z]):(/.*)?$}) {
            my $rest = defined $2 ? $2 : '/';
            $s = lc($1) . ':' . $rest;
        }
        if ($s =~ m{^([a-z]:)(/.*)?$}) {
            $drive_prefix = $1;
            $s = defined $2 ? $2 : '/';
        }
    }
    my $is_abs = ($s =~ m{^/});
    my @parts = split m{/+}, $s;
    shift @parts if @parts && $parts[0] eq '';
    my @out;
    for my $seg (@parts) {
        next if $seg eq '' || $seg eq '.';
        if ($seg eq '..') { pop @out if @out; next }
        push @out, $seg;
    }
    my $canon = $is_abs ? ('/' . join('/', @out)) : join('/', @out);
    $canon = $drive_prefix . $canon if length $drive_prefix;
    unless ($canon =~ m{^(?:[a-z]:)?/\z}) {
        $canon =~ s{/\z}{};
    }
    return $canon;
}
sub _alm_sw_seg_eq {
    my ($x, $y, $allow_83) = @_;
    $allow_83 = 1 unless defined $allow_83;
    return $x eq $y unless $ALMANAC_SW_IS_WIN;
    return 1 if _alm_sw_fold_ascii($x) eq _alm_sw_fold_ascii($y);
    return 0 unless $allow_83;
    for my $pair ([$x, $y], [$y, $x]) {
        my ($short, $long) = @$pair;
        next unless defined $short && $short =~ /^([^~\/]{1,6})~[0-9]+(?:\.[^.\/]{0,3})?$/;
        my $stem = _alm_sw_fold_ascii($1);
        $stem =~ s/[^a-z0-9]//g;
        next unless length $stem;
        my $longfold = _alm_sw_fold_ascii($long);
        $longfold =~ s/[^a-z0-9]//g;
        $longfold = substr($longfold, 0, 6);
        return 1 if $stem eq $longfold;
    }
    return 0;
}
sub _alm_sw_same_path {
    my ($p, $q, $allow_83) = @_;
    $allow_83 = 1 unless defined $allow_83;
    return 0 unless defined $p && defined $q;
    my $ca = _alm_sw_lex_canon($p);
    my $cb = _alm_sw_lex_canon($q);
    my @sa = grep { length } split m{/}, $ca, -1;
    my @sb = grep { length } split m{/}, $cb, -1;
    return 0 unless scalar(@sa) == scalar(@sb);
    for my $i (0 .. $#sa) {
        return 0 unless _alm_sw_seg_eq($sa[$i], $sb[$i], $allow_83);
    }
    return 1;
}
sub _alm_sw_real_path {
    my ($p) = @_;
    return $p unless defined $p && length $p;
    return $p unless -e $p;
    my $r = eval { Cwd::abs_path($p) };
    return (defined $r && length $r) ? $r : $p;
}
sub _alm_sw_same_path_any_form {
    my ($d, $s, $allow_83) = @_;
    $allow_83 = 1 unless defined $allow_83;
    return 1 if _alm_sw_same_path($d, $s, $allow_83);
    my $rd = _alm_sw_real_path($d);
    my $rs = _alm_sw_real_path($s);
    return 1 if _alm_sw_same_path($rd, $rs, $allow_83);
    if ($^O =~ /^(msys|cygwin)$/ && defined &Cygwin::posix_to_win_path) {
        my $wd = eval { Cygwin::posix_to_win_path($rd) };
        my $ws = eval { Cygwin::posix_to_win_path($rs) };
        $wd = $rd unless defined $wd;
        $ws = $rs unless defined $ws;
        return 1 if _alm_sw_same_path($wd, $ws, $allow_83);
    }
    return 0;
}
sub _alm_sw_compute_stops {
    my @candidates;
    push @candidates, eval { File::Spec->tmpdir };
    push @candidates, $ENV{TMP}, $ENV{TEMP}, $ENV{TMPDIR};
    push @candidates, $ENV{HOME}, $ENV{USERPROFILE};
    my @stops;
    for my $v (@candidates) {
        next unless defined $v && length $v;
        next unless _alm_sw_is_abs_ish($v);
        my $canon = _alm_sw_lex_canon($v);
        next if $canon =~ m{^(?:[a-z]:)?/\z};
        push @stops, $v;
    }
    return \@stops;
}
sub _alm_sw_is_stop {
    my ($d, $stops, $allow_83) = @_;
    $allow_83 = 1 unless defined $allow_83;
    for my $s (@$stops) {
        return 1 if _alm_sw_same_path_any_form($d, $s, $allow_83);
    }
    return 0;
}
sub _alm_sw_collapse_dotdot {
    my ($p) = @_;
    return $p unless defined $p && length $p;
    return $p unless $p =~ m{(?:^|/)\.\.?(?:/|\z)};
    my $drive_prefix = '';
    my $s = $p;
    if ($ALMANAC_SW_IS_WIN && $s =~ m{^([A-Za-z]:)(/.*)?\z}) {
        $drive_prefix = $1;
        $s = defined $2 ? $2 : '/';
    }
    my $is_abs = ($s =~ m{^/});
    my @parts = split m{/+}, $s;
    shift @parts if @parts && $parts[0] eq '';
    my @out;
    for my $seg (@parts) {
        next if $seg eq '' || $seg eq '.';
        if ($seg eq '..') { pop @out if @out; next }
        push @out, $seg;
    }
    my $canon = $is_abs ? ('/' . join('/', @out)) : join('/', @out);
    $canon = $drive_prefix . $canon if length $drive_prefix;
    unless ($canon =~ m{^(?:[A-Za-z]:)?/\z}) {
        $canon =~ s{/\z}{};
    }
    return $canon;
}
sub _alm_sw_home_usable {
    for my $v ($ENV{HOME}, $ENV{USERPROFILE}) {
        return 1 if defined $v && length $v && _alm_sw_is_abs_ish($v);
    }
    return 0;
}
sub _alm_sw_parent_of {
    my ($d) = @_;
    return undef unless defined $d && length $d;
    return undef if $d =~ m{\A[A-Za-z]:/?\z};
    return undef if $d eq '/';
    my $idx = rindex($d, '/');
    return undef if $idx < 0;
    my $parent = substr($d, 0, $idx);
    return '/' if $parent eq '';
    return "$parent/" if $parent =~ m{\A[A-Za-z]:\z};
    return $parent;
}
sub _alm_bounded_walk {
    my ($start) = @_;
    return undef unless defined $start && length $start;
    (my $s = $start) =~ s{\\}{/}g;
    $s = _alm_sw_collapse_dotdot($s) if length $s;
    my $home_ok = _alm_sw_home_usable();
    my $stops = _alm_sw_compute_stops();
    # stat-based identity (device+inode) check, supplementing _alm_sw_is_stop's
    # text-only match: this file loads no Cwd (AC-S3/AC-9), so the _alm_sw_*
    # subs' realpath step is silently inert and a junction/symlink/alternate-
    # codepoint alias of a stop directory evades text comparison. stat is a
    # core builtin -- no use/require needed -- and two paths naming the same
    # filesystem entry share a (dev, ino) pair even when their text differs.
    my @stop_dev_ino;
    for my $stop (@$stops) {
        my @st = stat($stop);
        push @stop_dev_ino, [$st[0], $st[1]] if @st && defined $st[0];
    }
    my $d = $s;
    my %seen;
    while (1) {
        return undef if $seen{$d}++;
        my $is_stop_here = _alm_sw_is_stop($d, $stops);
        if (!$is_stop_here && @stop_dev_ino) {
            my @dst = stat($d);
            if (@dst && defined $dst[0]) {
                for my $sdi (@stop_dev_ino) {
                    if ($dst[0] == $sdi->[0] && $dst[1] == $sdi->[1]) {
                        $is_stop_here = 1;
                        last;
                    }
                }
            }
        }
        return undef if $is_stop_here && !_alm_sw_same_path_any_form($d, $s);
        return $d if -d "$d/.ccpraxis-local-data" || -e "$d/.git";
        return undef if $is_stop_here;
        return undef unless $home_ok;
        my $parent = _alm_sw_parent_of($d);
        return undef unless defined $parent && length $parent && $parent ne $d;
        $d = $parent;
    }
}
# _alm_project_root($cwd) -> the project root, or undef. The nearest ancestor
# holding .ccpraxis-local-data or .git, found by the bounded walk
# _alm_bounded_walk above; that walk mirrors Almanac::Store::_bounded_walk
# and plugins/butler/scripts/BpDataRoot.pm's R1-R4, restated inline because
# this file may import nothing. After the walk comes CLAUDE_PROJECT_DIR, then
# the start. A relative start is never walked, so the process cwd is never
# consulted; a relative result is no project.
sub _alm_project_root {
    my ($cwd) = @_;
    my $start = _alm_bytes($cwd);
    $start =~ tr{\\}{/};
    my $project;
    if (_alm_is_abs($start)) {
        my $dir = $start;
        $dir =~ s{/+\z}{} unless $dir =~ m{\A(?:[A-Za-z]:)?/\z};
        $project = _alm_bounded_walk($dir);
    }
    if (!defined $project) {
        my $cpd = $ENV{CLAUDE_PROJECT_DIR};
        $project = (defined $cpd && length $cpd) ? $cpd : $start;
        $project =~ tr{\\}{/};
    }
    $project =~ s{/+\z}{};
    return undef unless _alm_is_abs($project);
    return $project;
}
# _alm_home() -> ALMANAC_HOME, else HOME, else USERPROFILE; undef if none.
sub _alm_home {
    for my $h ($ENV{ALMANAC_HOME}, $ENV{HOME}, $ENV{USERPROFILE}) {
        next unless defined $h && length $h;
        my $v = $h;
        $v =~ tr{\\}{/};
        $v =~ s{/+\z}{};
        return $v;
    }
    return undef;
}
# _alm_record_names($dir) -> the entries of $dir that name a record. A
# missing or unreadable dir has none.
sub _alm_record_names {
    my ($dir) = @_;
    my @names;
    opendir(my $dh, $dir) or return @names;
    while (defined(my $e = readdir($dh))) {
        next unless $e =~ /\A(.+)\.md\z/s;
        push @names, $e if _alm_is_id($1);
    }
    closedir($dh);
    return @names;
}
sub _alm_dir_key {
    my ($dir) = @_;
    my $k = $ALMANAC_DIR_KEY->{$dir};
    return $k if defined $k;
    my @st = stat($dir);
    $k = (@st && $st[1]) ? "inode:$st[0]:$st[1]" : "path:$dir";
    $ALMANAC_DIR_KEY->{$dir} = $k;
    return $k;
}
# almanac_parse_record($bytes) -> \%fields, or undef when Almanac::Record
# would refuse the bytes (almanac-records Decision 38: this parser accepts
# exactly what Almanac::Record::check accepts). Field values are decoded
# characters, exactly as Almanac::Record::parse returns them. Refused:
# invalid UTF-8 (strict: no surrogate, noncharacter or code point past
# U+10FFFF), a first line that is not exactly "---", no closing "---", a CR
# on either delimiter or any field line, an empty front matter, a line that
# is not "key: value" (one colon, one space), a duplicate key, and a value
# carrying C0 (less TAB), DEL, C1, U+2028 or U+2029. A value is never
# trimmed, so "status: open " is not "open".
sub almanac_parse_record {
    my ($bytes) = @_;
    return undef unless defined $bytes && !ref($bytes);
    my $text = "$bytes";
    if ($text =~ /[^\x00-\x7f]/) {
        return undef if utf8::is_utf8($text);
        return undef unless utf8::decode($text);
        return undef if $text =~ /[^\x{0}-\x{10FFFF}]/;
        return undef if $text =~ /[\x{D800}-\x{DFFF}\x{FDD0}-\x{FDEF}\x{FFFE}\x{FFFF}\x{1FFFE}\x{1FFFF}\x{2FFFE}\x{2FFFF}\x{3FFFE}\x{3FFFF}\x{4FFFE}\x{4FFFF}\x{5FFFE}\x{5FFFF}\x{6FFFE}\x{6FFFF}\x{7FFFE}\x{7FFFF}\x{8FFFE}\x{8FFFF}\x{9FFFE}\x{9FFFF}\x{AFFFE}\x{AFFFF}\x{BFFFE}\x{BFFFF}\x{CFFFE}\x{CFFFF}\x{DFFFE}\x{DFFFF}\x{EFFFE}\x{EFFFF}\x{FFFFE}\x{FFFFF}\x{10FFFE}\x{10FFFF}]/;
    }
    my @l = split /\n/, $text, -1;
    return undef unless @l && $l[0] eq '---';
    my $closing;
    for my $i (1 .. $#l) {
        if ($l[$i] =~ /\A---\r?\z/) { $closing = $i; last }
    }
    return undef unless defined $closing && $closing >= 2 && $l[$closing] eq '---';
    my %fields;
    for my $i (1 .. $closing - 1) {
        return undef unless $l[$i] =~ /\A([A-Za-z0-9_]+): (.*)\z/;
        my ($k, $v) = ($1, $2);
        return undef if exists $fields{$k};
        return undef if $v =~ /[\x00-\x08\x0A-\x1F\x7F-\x9F\x{2028}\x{2029}]/;
        $fields{$k} = $v;
    }
    return \%fields;
}
# _alm_frontmatter($dir, $entry) -> almanac_parse_record's fields for that
# file, or 0 when it cannot be read, exceeds 1048576 bytes, or is refused.
sub _alm_frontmatter {
    my ($dir, $entry) = @_;
    my $path = "$dir/$entry";
    my $key = _alm_dir_key($dir) . "/$entry";
    my $seen = $ALMANAC_FM_SEEN->{$key};
    return $seen if defined $seen;
    my $fm = 0;
    if (open(my $fh, '<:raw', $path)) {
        # Read in 8 KiB steps: one read() with the whole cap as its length
        # would allocate that much for every record, and records are small.
        my $bytes = '';
        my $n = 0;
        while (1) {
            my $got = read($fh, $bytes, 8192, length $bytes);
            if (!defined $got) { $n = undef; last }
            $n += $got;
            last if $got < 8192 || $n > 1048576;
        }
        close($fh);
        if (defined $n && $n <= 1048576) {
            my $f = almanac_parse_record($bytes);
            $fm = $f if $f;
        }
    }
    $ALMANAC_FM_SEEN->{$key} = $fm;
    return $fm;
}
# _alm_count($dir, @statuses) -> the records in $dir that parse and whose
# status is one of @statuses; with no statuses, every record that parses.
sub _alm_count {
    my ($dir, @statuses) = @_;
    my %want = map { ($_ => 1) } @statuses;
    my $n = 0;
    for my $e (_alm_record_names($dir)) {
        my $fm = _alm_frontmatter($dir, $e);
        next unless $fm;
        if (@statuses) {
            next unless defined $fm->{status};
            next unless $want{ $fm->{status} };
        }
        $n++;
    }
    return $n;
}
# _alm_count_field($dir, $field, @values) -> the records in $dir that parse
# and whose $field equals one of @values. Same record-name grammar and
# frontmatter cache as _alm_count, generalised to any field (package
# 12-statusline-threads: thread records are counted by "state", not
# "status").
sub _alm_count_field {
    my ($dir, $field, @values) = @_;
    my %want = map { ($_ => 1) } @values;
    my $n = 0;
    for my $e (_alm_record_names($dir)) {
        my $fm = _alm_frontmatter($dir, $e);
        next unless $fm;
        next unless defined $fm->{$field};
        next unless $want{ $fm->{$field} };
        $n++;
    }
    return $n;
}
sub _alm_nonneg_int {
    my ($v) = @_;
    return 0 unless defined $v && !ref($v);
    return ("$v" =~ /\A\d+\z/) ? 1 : 0;
}
# _alm_snapshot($path) -> { todo, note, thread } or undef. One attempt, never
# a retry: Almanac::GlobalCounts::_read_snapshot_once's checks, in its order.
# thread is the integer thread.open when the snapshot carries a HASH "thread"
# member whose "open" is a non-negative integer and whose "projects" (if
# present) is an ARRAY of defined, non-ref, non-empty scalars; otherwise
# thread is undef -- a malformed thread member never invalidates todo/note
# (package 12-statusline-threads, spec 2.1).
sub _alm_snapshot {
    my ($path) = @_;
    return undef unless -f $path;
    my @st = stat($path);
    return undef unless @st && defined $st[7] && $st[7] >= 1 && $st[7] <= 4096;
    open(my $fh, '<:raw', $path) or return undef;
    my $bytes = '';
    my $n = read($fh, $bytes, 4097);
    close($fh);
    return undef unless defined $n && $n >= 1 && $n <= 4096;
    my $d = eval { JSON::PP->new->decode($bytes) };
    return undef unless ref($d) eq 'HASH';
    return undef unless defined $d->{schema} && !ref($d->{schema}) && "$d->{schema}" eq '1';
    my $at = $d->{generated_at};
    return undef unless defined $at && !ref($at) && $at =~ /\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/;
    my $todo = $d->{todo};
    return undef unless ref($todo) eq 'HASH';
    for my $k (qw(open done total)) {
        return undef unless _alm_nonneg_int($todo->{$k});
    }
    my $note = $d->{note};
    return undef unless ref($note) eq 'HASH' && _alm_nonneg_int($note->{total});
    my $thread;
    my $th = $d->{thread};
    if (ref($th) eq 'HASH' && _alm_nonneg_int($th->{open})) {
        my $projects_ok = 1;
        if (exists $th->{projects}) {
            if (ref($th->{projects}) eq 'ARRAY') {
                for my $p (@{ $th->{projects} }) {
                    $projects_ok = 0 if !defined($p) || ref($p) || !length("$p");
                }
            } else {
                $projects_ok = 0;
            }
        }
        $thread = 0 + $th->{open} if $projects_ok;
    }
    return { todo => 0 + $todo->{open}, note => 0 + $note->{total}, thread => $thread };
}
sub almanac_counts {
    my (%o) = @_;
    my ($project, $global);
    eval {
        my $root = _alm_project_root($o{cwd});
        if (defined $root) {
            my $ad = "$root/.ccpraxis-local-data/almanac";
            $project = {
                todo     => _alm_count("$ad/todo", 'open'),
                note     => _alm_count("$ad/note"),
                thread   => _alm_count_field("$ad/thread", 'state', 'live', 'handed-off'),
                inbox    => _alm_count(-d "$ad/inbox" ? "$ad/inbox" : "$ad/$ALMANAC_LEGACY_INBOX_DIR", 'unanswered'),
            };
        }
        1;
    } or $project = undef;
    eval {
        my $home = _alm_home();
        if (defined $home) {
            my $snap = _alm_snapshot("$home/.claude/$ALMANAC_SNAPSHOT_NAME");
            if ($o{sandbox}) {
                $global = $snap;
            } else {
                my $v = "$home/.claude/claude-code-vault/almanac";
                $global = { todo => _alm_count("$v/todo", 'open'), note => _alm_count("$v/note"),
                            thread => (ref($snap) eq 'HASH' ? $snap->{thread} : undef) };
            }
        }
        1;
    } or $global = undef;
    return { project => $project, global => $global };
}
# _alm_text($chars) -> a decoded field value with C0, DEL and Unicode format
# characters (\p{Cf}: bidi overrides/embeddings/isolates, ZWSP, the Arabic
# letter mark, etc.) removed. Format characters pass grammar-restricted
# fields untouched (those are plain ASCII) but would otherwise reach a free-
# text title or blocked_on byte for byte, letting a crafted value reverse or
# spoof the rendered row on a bidi-aware terminal (redteam L1).
sub _alm_text {
    my ($s) = @_;
    $s = '' unless defined $s;
    $s =~ s/[\x00-\x1f\x7f]//g;
    $s =~ s/\p{Cf}//g;
    return $s;
}
# _alm_thread_name_ok($name) -> 1 iff $name is a thread id (restates
# Almanac::Thread::valid_name: lowercase alnum/hyphen, <=64 chars, not a
# reserved device name). This is stricter and lower-case-only compared to
# _alm_is_id, which is the generic Almanac::Store grammar used for record
# FILE names (e.g. task ids) -- the two must not be conflated.
sub _alm_thread_name_ok {
    my ($name) = @_;
    return 0 unless defined $name && $name =~ /\A[a-z0-9][a-z0-9-]{0,63}\z/;
    return 0 if $name =~ /\A(?:con|prn|aux|nul|com[1-9]|lpt[1-9])\z/i;
    return 1;
}
# _alm_rank_id_cmp($ra, $rb, $ia, $ib) -> restates Almanac::Store's
# _rank_id_cmp: rank (if both defined) compared with cmp, tie broken by id;
# a ranked entry always sorts before an unranked one; two unranked entries
# sort by id.
sub _alm_rank_id_cmp {
    my ($ra, $rb, $ia, $ib) = @_;
    if (defined $ra && defined $rb) {
        my $c = $ra cmp $rb;
        return $c ? $c : ($ia cmp $ib);
    } elsif (defined $ra) {
        return -1;
    } elsif (defined $rb) {
        return 1;
    } else {
        return $ia cmp $ib;
    }
}
# _alm_norm_pkg_status($raw) -> restates Almanac::PackageLink::norm_status:
# lowercase, every run of non-[a-z] becomes one space, trim, and the WHOLE
# result must equal one of @Almanac::PackageLink::STATUSES (interpolated at
# generation time into $ALM_PKG_STATUS_OK, the same way $ALMANAC_SNAPSHOT_NAME
# is interpolated) or the result is ''.
sub _alm_norm_pkg_status {
    my ($s) = @_;
    return '' unless defined $s;
    my $t = lc $s;
    $t =~ s/[^a-z]+/ /g;
    $t =~ s/\A\s+|\s+\z//g;
    return $ALM_PKG_STATUS_OK->{$t} ? $t : '';
}
# _alm_read_capped($path, $cap) -> up to $cap bytes of $path, or undef if it
# cannot be opened. Read in 8 KiB steps, same discipline as _alm_frontmatter.
sub _alm_read_capped {
    my ($path, $cap) = @_;
    return undef unless open(my $fh, '<:raw', $path);
    my $bytes = '';
    my $n = 0;
    while ($n < $cap) {
        my $want = $cap - $n;
        $want = 8192 if $want > 8192;
        my $got = read($fh, $bytes, $want, $n);
        last unless defined $got && $got > 0;
        $n += $got;
    }
    close($fh);
    return $bytes;
}
# _alm_link_resolve($root, $link) -> restates Almanac::PackageLink::resolve
# plus the pipeline-step reader (spec 2.2). Never consults CCPRAXIS_DATA_DIR.
# { state => 'invalid' }
# { state => 'missing', blueprint, package }
# { state => 'ok', blueprint, package, status, step }
sub _alm_link_resolve {
    my ($root, $link) = @_;
    $link = '' unless defined $link;
    my $key = (defined($root) ? $root : '') . "\0" . $link;
    my $cached = $ALMANAC_LINK_SEEN->{$key};
    return $cached if defined $cached;
    my $result = _alm_link_resolve_uncached($root, $link);
    $ALMANAC_LINK_SEEN->{$key} = $result;
    return $result;
}
sub _alm_link_resolve_uncached {
    my ($root, $link) = @_;
    my @parts = split m{/}, $link, -1;
    return { state => 'invalid' } unless @parts == 2;
    my ($bp, $pkg) = @parts;
    for my $p ($bp, $pkg) {
        return { state => 'invalid' }
            unless defined($p) && length($p) && length($p) <= 128
                && $p =~ /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/ && index($p, '..') < 0;
    }
    $bp  = _alm_bytes($bp);
    $pkg = _alm_bytes($pkg);
    my $live     = "$root/.ccpraxis-local-data/blueprints/$bp/packages/$pkg.md";
    my $archived = "$root/.ccpraxis-local-data/blueprints/_archive/$bp/packages/$pkg.md";
    my $ledger;
    if (-f $live)          { $ledger = $live }
    elsif (-f $archived)   { $ledger = $archived }
    else                   { return { state => 'missing', blueprint => $bp, package => $pkg } }
    my $bytes = _alm_read_capped($ledger, 65536);
    $bytes = '' unless defined $bytes;
    my @lines = split /\n/, $bytes, -1;
    my $in = 0;
    my $status_raw;
    for my $ln (@lines) {
        if ($ln =~ /\A-{3}\s*\z/) { $in++; last if $in == 2; next; }
        next unless $in == 1;
        if (!defined($status_raw) && $ln =~ /\Astatus:[ \t]*(.*)/) {
            my $raw = $1;
            $raw =~ s/\s+\z//;
            $status_raw = $raw;
        }
    }
    my $norm = _alm_norm_pkg_status($status_raw);
    my $status = length($norm) ? $norm : 'pending';
    my $step = _alm_pipeline_step($bytes);
    return { state => 'ok', blueprint => $bp, package => $pkg, status => $status, step => $step };
}
# _alm_pipeline_step($blob) -> the current step word, or undef -- restates
# RunState::_parse_pipeline's rule (spec 2.2), run over ledger bytes.
sub _alm_pipeline_step {
    my ($blob) = @_;
    return undef unless defined $blob && length $blob;
    my $s = $blob;
    $s =~ s/\A\xEF\xBB\xBF//;
    my @lines = split /\n/, $s, -1;
    for my $l (@lines) { $l =~ s/\r\z//; }
    my $start;
    for my $i (0 .. $#lines) {
        if ($lines[$i] =~ /\A##[ \t]+Pipeline[ \t]*\z/i) { $start = $i; last; }
    }
    return undef unless defined $start;
    my %checked;
    my %word;
    my $in_fence = 0;
    for (my $i = $start + 1; $i <= $#lines; $i++) {
        my $line = $lines[$i];
        if ($line =~ /\A[ \t]*(?:\x60{3}|~~~)/) { $in_fence = $in_fence ? 0 : 1; next; }
        last if !$in_fence && $line =~ /\A#{1,6}[ \t]/;
        next if length($line) > 1024;
        if ($line =~ /\A[ \t]*-[ \t]*\[([ xX])\][ \t]*(\d{1,2})\.[ \t]+(\S+)/) {
            my ($mark, $num_raw, $w) = ($1, $2, $3);
            my $num = 0 + $num_raw;
            next if exists $checked{$num};
            $checked{$num} = ($mark eq 'x' || $mark eq 'X') ? 1 : 0;
            $word{$num} = $w;
        }
    }
    my @nums = sort { $a <=> $b } keys %checked;
    return undef unless @nums;
    my @pending = grep { !$checked{$_} } @nums;
    return undef unless @pending;
    my $w = lc($word{ $pending[0] });
    $w =~ s/[^a-z0-9-]//g;
    return length($w) ? $w : undef;
}
# _alm_classify_linked($status) -> 'done'|'doing'|'blocked'|'pending', per
# spec 2.1's resolved-status table.
sub _alm_classify_linked {
    my ($status) = @_;
    return 'done'    if defined($status) && ($status eq 'done' || $status eq 'dropped');
    return 'doing'   if defined($status) && ($status eq 'running' || $status eq 'converging' || $status eq 'reviewing');
    return 'blocked' if defined($status) && ($status eq 'blocked' || $status eq 'parked');
    return 'pending';
}
# _alm_classify_unlinked($status) -> 'done'|'doing'|'blocked'|'pending', per
# spec 2.1's unlinked-status table.
sub _alm_classify_unlinked {
    my ($status) = @_;
    $status = '' unless defined $status;
    return 'done'    if $status eq 'done' || $status eq 'obsoleted';
    return 'doing'   if $status eq 'doing';
    return 'blocked' if $status eq 'blocked';
    return 'pending';
}
# _alm_pkg_number($pkg) -> the leading digits of a package name (leading
# zeros kept), or the whole package part when it has none (spec 2.1 rule 7).
sub _alm_pkg_number {
    my ($pkg) = @_;
    $pkg = '' unless defined $pkg;
    return $1 if $pkg =~ /\A(\d+)/;
    return $pkg;
}
# _alm_task_label($root, \%fm, $id) -> ($class, \%label), per spec 2.1 rules
# 5-9.
sub _alm_task_label {
    my ($root, $fm, $id) = @_;
    if (defined($fm->{link})) {
        my $res = _alm_link_resolve($root, $fm->{link});
        if ($res->{state} eq 'ok') {
            my $class = _alm_classify_linked($res->{status});
            my $step  = (defined($res->{step}) && length($res->{step})) ? $res->{step} : $res->{status};
            return ($class, { class => $class, kind => 'link', blueprint => $res->{blueprint},
                               number => _alm_pkg_number($res->{package}), step => $step });
        }
        if ($res->{state} eq 'missing') {
            return ('pending', { class => 'pending', kind => 'link', blueprint => $res->{blueprint},
                                  number => _alm_pkg_number($res->{package}), step => 'missing' });
        }
        my $txt = _alm_text($fm->{link}) . ' missing';
        return ('pending', { class => 'pending', kind => 'text', title => $txt, waits_on => undef });
    }
    my $class = _alm_classify_unlinked($fm->{status});
    my $title = _alm_text($fm->{title});
    $title = $id unless length $title;
    my $wo;
    if (defined $fm->{blocked_on}) {
        my $w = _alm_text($fm->{blocked_on});
        $wo = length($w) ? $w : undef;
    }
    return ($class, { class => $class, kind => 'text', title => $title, waits_on => $wo });
}
# _alm_thread_find(cwd, session) -> the implementation behind almanac_thread
# (spec 2.1). Not eval-wrapped itself; almanac_thread wraps it.
sub _alm_thread_find {
    my (%o) = @_;
    my $sid = $o{session};
    return undef unless _alm_is_id($sid);
    my $root = _alm_project_root($o{cwd});
    return undef unless defined $root;
    my $tdir = "$root/.ccpraxis-local-data/almanac/thread";
    my @names;
    if (opendir(my $dh, $tdir)) {
        while (defined(my $e = readdir($dh))) {
            next unless $e =~ /\A(.+)\.md\z/s;
            push @names, $1 if _alm_thread_name_ok($1);
        }
        closedir($dh);
    }
    my $chosen;
    for my $name (sort @names) {
        my $fm = _alm_frontmatter($tdir, "$name.md");
        next unless $fm;
        next unless defined($fm->{state}) && $fm->{state} eq 'live';
        next unless defined($fm->{owner_kind}) && $fm->{owner_kind} eq 'session';
        next unless defined($fm->{owner_id}) && $fm->{owner_id} eq $sid;
        $chosen = $name;
        last;
    }
    return undef unless defined $chosen;
    my $tasks_dir = "$root/.ccpraxis-local-data/almanac/thread-tasks-$chosen";
    my @recs;
    for my $e (_alm_record_names($tasks_dir)) {
        my $fm = _alm_frontmatter($tasks_dir, $e);
        next unless $fm;
        (my $id = $e) =~ s/\.md\z//;
        push @recs, { id => $id, fm => $fm };
    }
    @recs = sort { _alm_rank_id_cmp($a->{fm}{rank}, $b->{fm}{rank}, $a->{id}, $b->{id}) } @recs;
    my $total = scalar @recs;
    my $done = 0;
    my @doing;
    my $current;
    my $next;
    for my $r (@recs) {
        my ($class, $label) = _alm_task_label($root, $r->{fm}, $r->{id});
        if ($class eq 'done') { $done++; next; }
        push @doing, $label if $class eq 'doing';
        $current = $label unless defined $current;
        $next = $label if !defined($next) && $class eq 'pending';
    }
    $current = undef if @doing;
    return { name => $chosen, done => $done, total => $total, doing => \@doing,
             current => $current, next => $next };
}
sub almanac_thread {
    my (%o) = @_;
    my $t;
    eval { $t = _alm_thread_find(%o); 1 } or $t = undef;
    return $t;
}
# <<< END GENERATED FROM gen-statusline-counters.pl <<<

# ── Model ────────────────────────────────────────────────────
my $display  = $data->{model}{display_name} // '';
my $model_id = $data->{model}{id} // '?';
my $short    = $display || $model_id;
$short =~ s/^Claude //;
$short =~ s/\s*\(\d+[kKmM]\s*context\)//;

# ── Project identity and location ────────────────────────────
# The project ROOT is computed once, here, and reused by the plans lookup
# below -- it used to be computed inside that lookup, after row 1 had
# already taken its project name from the working directory basename, which
# is why `cd plugins/sandbox/scripts` used to display "scripts".
# Name and location resolve INDEPENDENTLY: the name always comes from the
# git toplevel (falling back to the working directory outside a repo), the
# location is always the full current_dir verbatim, even when the two are
# unrelated.
my $workspace = $data->{workspace}{current_dir} // '';
my $toplevel  = '';
if (length $workspace) {
    my $t = cmd_out('git', '-C', $workspace, 'rev-parse', '--show-toplevel');
    chomp $t;
    # git writes UTF-8 bytes; decode once so basename and every downstream
    # comparison (which see JSON-decoded text) agree.
    utf8::decode($t) if length($t) && !utf8::is_utf8($t);
    $toplevel = $t;
}
my $root    = length($toplevel) ? $toplevel : $workspace;
my $project = length($root) ? basename($root) : '?';
my $cwd     = $workspace;

# Inside the sandbox the project is bind-mounted at /project, so the git
# toplevel IS `/project` and basename() yields the literal word "project" for
# every project on the machine. The field that exists to say WHICH project you
# are in was the one field that could never say it.
#
# The launcher writes the real name into claude-home/project-name on every
# launch. claude-home is a LIVE bind mount, so that file appears at
# /root/.claude/project-name immediately — including in containers created
# before this existed. An env var would have been the obvious choice and is the
# wrong one: `podman create` bakes env at creation, so it would fix only
# containers made after the change and silently leave every existing sandbox
# still displaying "project".
#
# Host behaviour is untouched: the file is only consulted when the mount shape
# actually indicates the sandbox.
if ($root eq '/project' || $project eq 'project') {
    my $home = $ENV{HOME} // '';
    my $name_file = length($home) ? "$home/.claude/project-name" : '';
    if (length($name_file) && -f $name_file && open my $nfh, '<:raw', $name_file) {
        my $n = do { local $/; <$nfh> };
        close $nfh;
        if (defined $n) {
            $n =~ s/\s+\z//;
            $n =~ s/\A\s+//;
            # Same provenance as any other display field read off disk: it is
            # written by the launcher from a host directory name, which may
            # legally hold control bytes.
            $n =~ s/[\x00-\x1f\x7f]//g;
            utf8::decode($n) if length($n) && !utf8::is_utf8($n);
            $project = $n if length $n;
        }
    }
}

# Both DISPLAY fields are sanitised before they can reach row 1. current_dir
# comes from stdin JSON and a POSIX directory name may legally contain any
# byte but '/' and NUL -- including a newline, which would split one row into
# three, and ESC, which would repaint the terminal from a component nobody
# audited while row_cost's SGR strip removed it from the budget, desynchro-
# nising the accounting from what is painted. Rendering the FULL path (rather
# than only its basename, as this file used to) is what opened that door, so
# it is closed here. Only the display copies are scrubbed: $root stays
# verbatim because the plans lookup uses it as a filesystem path, where a
# rewritten value would silently miscount.
$project =~ s/[\x00-\x1f\x7f]//g;
$cwd     =~ s/[\x00-\x1f\x7f]//g;

# ── Environment marker ───────────────────────────────────────
# CCPRAXIS_SANDBOX is set ONLY by container/settings.json's `env` block, so
# this script is otherwise byte-identical in behaviour on the host, where
# the var is never set (this file is also the payload installed to the
# user's ~/.claude/statusline.pl and used on the host).
#
# THE MARKER SHRINKS TO FIT (operator, 2026-08-26: "No need to reserve space on
# HOST vs SANDBOX string cell. Have it shrink to fit available space").
#
# It used to pad HOST out to SANDBOX's width so the row could never reflow
# between the two. That guarantee was worth having when the two words could
# alternate on one screen -- they cannot: a given session is one or the other
# for its whole life, so the reflow it prevented was between two runs that never
# sit side by side. Three columns of padding on every row of every host session
# to protect against a comparison nobody makes.
my $SANDBOX_ON = $ENV{CCPRAXIS_SANDBOX} ? 1 : 0;
my %MARKER = (
    sandbox => 'SANDBOX',
    host    => 'HOST',
);

# THE LEAD GLYPH NOW MEANS CONTINUITY, NOT ENVIRONMENT (operator, 2026-08-26:
# "Should instead use the `● HOST ｜` versus `○ SANDBOX` to signalize the
# continuity watcher trigger on that first icon as it is. So instead of it
# representing sandbox vs host it should represent continuity watching vs not").
#
# It is the better assignment on its own merits. Host-versus-sandbox is
# CONSTANT for a session, so a glyph spent on it never changes and therefore
# never tells you anything you did not already know -- and the word beside it
# says the same thing in full. Whether this turn can end is the fact that
# actually varies, and it is the one worth a shape you can read without
# reading.
#
# Filled means watched, hollow means not; the shape is load-bearing, so it
# survives an SGR strip, exactly as Decision 3 required of the old pair.
#
# ...AND THE ENVIRONMENT MOVES INTO THE WORD'S COLOUR. "The `HOST` string could
# have some slight color difference so we can actually call a bit of attention
# to the fact its running in the host, but without screaming too much." So HOST
# takes text.primary and SANDBOX stays text.muted: a brightness step rather
# than a hue, present when you look at it and silent when you do not. The
# sandbox is the safe default and gets the quieter treatment.
my $GLYPH_WATCHED   = "\x{25CF}";   # filled  -- a Stop gate is armed for this session
my $GLYPH_UNWATCHED = "\x{25CB}";   # hollow  -- nothing is watching
my %WORD_COLOR = ( sandbox => $MUTED, host => $PRIMARY );

my $env  = $SANDBOX_ON ? 'sandbox' : 'host';
my $word = $MARKER{$env};

# ── Continuity badge ─────────────────────────────────────────
# Per-session, keyed by the documented top-level `session_id` field of the
# stdin JSON (spec SS2.6/AC-7).
#
# Batch C (spec 16-cutover, criterion C-8, 1.3 departure #8): the three old
# per-session registries (.continuity-active, .drive-solo-active,
# .reporter-active) are gone. The badge now reads the ONE new-store arm file,
# <state>/armed/<sid>, the same file BpHook's arm-on-entry hook and
# BpContinuityLease::new_store_active both read. "Why can't this turn end" is
# answered by whether that one file exists for this session, full stop.
#
# PATH RESOLUTION duplicates BpHook::state_dir()'s rule ON PURPOSE -- this
# file stays a standalone installed payload (no require of anything under
# plugins/). BUTLER_STATE_DIR if absolute (a relative value is UNRESOLVABLE,
# never guessed at), else $HOME then $USERPROFILE, each plus
# /.claude/butler-state/continuity.
#
# NO TTL IS APPLIED HERE, deliberately and as before. Reaping a stale marker is
# the hooks' job. A read path that second-guessed the reaper would disagree
# with the gate, which is the one thing this badge must never do.
sub _bp_is_absolute_path {
    my ($v) = @_;
    return 0 unless defined $v && length $v;
    return 1 if $v =~ m{^/};
    return 0 unless $v =~ m{^[A-Za-z]:};
    # The drive-letter form may be bare ("C:"), slashed, or backslashed. The
    # backslash is matched via chr(92) rather than written into a character
    # class: this repo edits perl through shell heredocs, which collapse a
    # doubled backslash and silently produce an unterminated class.
    # F8 (red-team L6, package 16 fix-batch): a BARE drive letter ("C:", no
    # slash) is NOT absolute -- must agree with BpHook::_is_abs, which
    # requires [\\/] right after the colon. Before this fix a bare "C:"
    # BUTLER_STATE_DIR could make the badge claim armed from a resolved
    # "C:/continuity/armed/<sid>" the gate itself never reads.
    my $rest = substr($v, 2);
    return 1 if $rest =~ m{^/} || substr($rest, 0, 1) eq chr(92);
    return 0;
}

# _home_var() -- the first absolute of HOME, USERPROFILE, with no fall-
# through once one is picked. Shared by _state_dir() and the power-plan
# CLI lookup below, so both resolve under the SAME home (S1, package 06
# review): a fake HOME can never pair its own state with a real
# USERPROFILE install.
sub _home_var {
    for my $home ($ENV{HOME}, $ENV{USERPROFILE}) {
        next unless _bp_is_absolute_path($home);
        (my $v = $home) =~ s{/+$}{};
        $v =~ tr{\\}{/};
        return $v;
    }
    return undef;
}

# _state_dir() -- BpHook::state_dir()'s rule, duplicated (see header above).
sub _state_dir {
    my $bsd = $ENV{BUTLER_STATE_DIR};
    if (defined $bsd && length $bsd) {
        return undef unless _bp_is_absolute_path($bsd);
        (my $v = $bsd) =~ s{/+$}{};
        $v =~ tr{\\}{/};
        return "$v/continuity";
    }
    my $home = _home_var();
    return defined $home ? "$home/.claude/butler-state/continuity" : undef;
}

my $sid = $data->{session_id};
$sid = '' unless defined $sid && !ref($sid) && $sid =~ m{\A[^/\\\0]+\z} && $sid !~ /\.\./;

my $badge_word = '';
if (length $sid) {
    my $state = _state_dir();
    if (defined $state && -f "$state/armed/$sid") {
        $badge_word = 'watched';
    }
}

# ── Silenced / agent-disarmed badge (Decision 7) ─────────────
# The lead glyph says whether a Stop gate is armed. It cannot say WHY one is
# not, and two of those reasons are worth seeing: an agent disarmed this
# session (off/<sid> with "actor":"agent"), or it is silenced
# (silence/<sid>). Both files live under the same root as armed/<sid>, so the
# badge costs two bounded reads and no subprocess.
#
# The silence test is BpHook::take_silence's own acceptance rule (session_id,
# by, a reason of two or more words), so the badge never claims a silence the
# gate would ignore. An agent disarm outranks a silence: disarming deletes the
# silence file, so both at once is a stale leftover, and "off" is the fact.
# -- continuity-badge:begin --
# _badge_record($path) -> the decoded hash, or undef. One read of at most
# 4096 bytes, so a record that starts past that point never decodes.
sub _badge_record {
    my ($path) = @_;
    return undef unless -f $path;
    open(my $fh, '<:raw', $path) or return undef;
    my $buf = '';
    my $n = read($fh, $buf, 4096);
    close($fh);
    return undef unless defined $n && $n > 0;
    # Decoded as UTF-8, exactly as BpHook::_read_json does, so the reason's
    # words are split on the same characters the Stop gate splits on.
    my $rec = eval { JSON::PP->new->utf8->decode($buf) };
    return (ref($rec) eq 'HASH') ? $rec : undef;
}
my $badge_glyph = '';
if (length $sid) {
    my $state = _state_dir();
    if (defined $state) {
        my $off = _badge_record("$state/off/$sid");
        my $actor = $off ? $off->{actor} : undef;
        if (defined $actor && !ref($actor) && $actor eq 'agent') {
            $badge_glyph = "\x{2205}";
        } elsif (my $sil = _badge_record("$state/silence/$sid")) {
            my ($s_sid, $s_by, $s_why) = @{$sil}{qw(session_id by reason)};
            my @words = (defined $s_why && !ref($s_why)) ? grep { length } split(/\s+/, $s_why) : ();
            $badge_glyph = "\x{2016}"
                if defined $s_sid && !ref($s_sid) && $s_sid eq $sid
                && defined $s_by && !ref($s_by) && $s_by eq 'butler-continuity'
                && @words >= 2;
        }
    }
}
# -- continuity-badge:end --

# ── Power plan follows arming (Decision 14, package 06) ──────
# On this session's first draw on the Windows host, start a detached
# `bp-power-plan.pl reconcile --why statusline`, at most once per session
# (an O_EXCL marker under plan-checked/<sid> makes "at most once" true even
# when two draws race). The whole block is wrapped in eval so a failure
# never costs the draw, and the draw never waits on the child: spawn_detached
# redirects the child's stdio to null before exec, so this process's stdout
# pipe reaches EOF at once regardless of how long the child runs.
# -- power-plan:begin --
use POSIX ();
eval {
    if ($^O =~ /^(MSWin32|msys|cygwin)$/ && !$SANDBOX_ON && length($sid)
        && (($ENV{CCPRAXIS_POWER_PLAN_STATUSLINE} // '1') ne '0')
        && !length($ENV{BUTLER_STATE_DIR} // '')
        && !length($ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR} // '')) {
        my $pp_state = _state_dir();
        if (defined $pp_state && -d $pp_state) {
            my $pp_marker = "$pp_state/plan-checked/$sid";
            unless (-e $pp_marker) {
                my $pp_cli = $ENV{CCPRAXIS_POWER_PLAN_CLI};
                unless (defined $pp_cli && _bp_is_absolute_path($pp_cli) && -f $pp_cli) {
                    $pp_cli = undef;
                    my $h = _home_var();
                    if (defined $h) {
                        my $cand = "$h/.claude/ccpraxis/plugins/butler/scripts/bp-power-plan.pl";
                        $pp_cli = $cand if -f $cand;
                    }
                }
                if (defined $pp_cli) {
                    mkdir("$pp_state/plan-checked") unless -d "$pp_state/plan-checked";
                    if (sysopen(my $pp_fh, $pp_marker, POSIX::O_WRONLY() | POSIX::O_CREAT() | POSIX::O_EXCL())) {
                        close($pp_fh);
                        spawn_detached($^X, $pp_cli, 'reconcile', '--why', 'statusline');
                    }
                }
            }
        }
    }
};
# -- power-plan:end --

# ── The operator's inbox, and every other almanac count ─────────
#
# A COUNT, BECAUSE THE ALTERNATIVE WAS STOPPING. Unattended work used to halt
# the moment an agent wanted to ask something -- hours of idle for an answer
# nobody was there to give, and usually for a question the agent could have
# settled itself. Questions are filed as almanac inbox items now instead, and
# the thing that makes that acceptable rather than a way of losing them is
# that the operator can SEE there are some waiting without going to look.
#
# Package 10 routes this, and the todo/note/thread counters below, through
# the ONE generated accessor above. This is its only call site; the counters
# segment reuses the same result.
my $almanac = { project => undef, global => undef };
{
    # -- inbox:begin --
    $almanac = almanac_counts(cwd => $workspace, sandbox => $SANDBOX_ON);
    # -- inbox:end --
}
my $alm_project = ref($almanac) eq 'HASH' && ref($almanac->{project}) eq 'HASH' ? $almanac->{project} : {};
my $alm_global  = ref($almanac) eq 'HASH' && ref($almanac->{global})  eq 'HASH' ? $almanac->{global}  : {};
my $inbox_unanswered = $alm_project->{inbox} // 0;

# The inbox flag, built here rather than inside the "Plans & Todos" eval
# below: this way a failure in the blueprint scan (opendir ... or die) can
# never take the flag down with it. It leads the counters field (Decision 1)
# rather than riding in the marker.
my $inbox_str = '';
$inbox_str = bgrgb('overlay.warn') . rgb('overlay.warn') . "\x{2691} ${inbox_unanswered}${R}"
    if $inbox_unanswered > 0;

# ── ...and where it goes ─────────────────────────────────────
#
# IT IS THE LEAD GLYPH NOW (operator, 2026-08-26). It was a word: first an
# uppercase green one on a row of its own ("complete shit", their words), then a
# lowercase one riding row 2. Both spent horizontal space on a binary.
#
# A filled-versus-hollow circle says the same thing in one column, in the
# position the eye already lands on first, and it frees the environment word to
# carry the environment by colour alone. The three registries the badge reads
# are unchanged -- only its rendering moves.
#
# The named source (watched / driving / reporting) is deliberately NOT dropped:
# it goes to the WORD'S COLOUR? No -- it goes nowhere, and that is a real
# trade. A glyph can say "something is watching"; it cannot say which of three
# things. The operator asked for the glyph, and "why can't this turn end" has a
# command that answers it precisely (/butler:continuity status). What the
# statusline owes is the fact, continuously and cheaply, which the glyph does.
my $watched = length($badge_word) ? 1 : 0;
my $marker  = ($watched ? $OK : $FAINT)
            . ($watched ? $GLYPH_WATCHED : $GLYPH_UNWATCHED)
            . "${R}$WORD_COLOR{$env} ${word}${R}";

# The Decision 7 badge follows the word: why this session is NOT watched, when
# the reason is an agent's disarm or a silence. Nothing at all -- not even a
# space -- when neither applies.
$marker .= "${R} ${WARN}${badge_glyph}${R}" if length $badge_glyph;

# The inbox flag no longer rides in the marker field (Decision 1): it now
# leads the counters field via $inbox_str, built above next to
# $inbox_unanswered, so the fit ladder can drop it last rather than first.

# ── Git (with background fetch every 30 min) ────────────────
my $git_str = '';
eval {
    my $branch = cmd_out('git', '-C', $workspace, 'rev-parse', '--abbrev-ref', 'HEAD');
    chomp $branch;
    # Decoded for the same reason $toplevel is: git writes UTF-8 BYTES, and
    # the adjacent \x{2325}/\x{200A} upgrade $git_str to a character string,
    # which would Latin-1-upgrade those bytes and render `feature/Andre'` as
    # `feature/AndrA(c)`. The sibling call got this treatment; this one did not.
    utf8::decode($branch) if length($branch) && !utf8::is_utf8($branch);
    if ($branch) {
        # Fetch remote if stale (>30 min since last fetch)
        my $fetch_stamp = "$workspace/.git/FETCH_HEAD";
        my $stale = 1;
        if (-f $fetch_stamp) {
            $stale = (time() - (stat($fetch_stamp))[9]) > 1800;
        }
        if ($stale) {
            # Fire-and-forget background fetch (no blocking)
            spawn_detached('git', '-C', $workspace, 'fetch', '--quiet');
        }

        my $ahead  = cmd_out('git', '-C', $workspace, 'rev-list', '--count', '@{upstream}..HEAD'); chomp $ahead;
        my $behind = cmd_out('git', '-C', $workspace, 'rev-list', '--count', 'HEAD..@{upstream}'); chomp $behind;
        $ahead  = 0 unless $ahead  =~ /^\d+$/;
        $behind = 0 unless $behind =~ /^\d+$/;

        # The counts are VALUES, not health states -- text.primary, never a
        # green/amber state role. "A value is present" is not "healthy".
        $git_str = "${MUTED}\x{2325}\x{200A}${branch}${R}";
        $git_str .= " ${PRIMARY}\x{2191}${ahead}${R}"  if $ahead  > 0;
        $git_str .= " ${PRIMARY}\x{2193}${behind}${R}" if $behind > 0;
    }
};

# ── Plans & Todos ────────────────────────────────────────────
my $plans_str = '';
eval {
    my @parts;

    # Blueprints: non-archived <data>/blueprints/<name>/ (per-project). Count
    # blueprint dirs (those containing blueprint.md), skipping _archive/ and
    # dotfiles. Data root mirrors the plugins: $CCPRAXIS_DATA_DIR or the
    # per-project default <root>/.ccpraxis-local-data.
    my $bp_root = ($ENV{CCPRAXIS_DATA_DIR} // "$root/.ccpraxis-local-data") . "/blueprints";
    if ($root && -d $bp_root) {
        opendir(my $dh, $bp_root) or die;
        my $n = grep { $_ ne '_archive' && !/^\./ && -f "$bp_root/$_/blueprint.md" } readdir($dh);
        closedir($dh);
        # AN ICON, NOT THE WORD (operator, 2026-08-26: "Instead of saying in the
        # statusline `blueprints 1` we could instead use some icon in place of
        # the `blueprints` label? You can suggest a bunch to me, I just don't
        # want any colored emoji"). U+29C9, two joined squares -- layered
        # packages, which is what a blueprint is -- chosen from four offered.
        # It is East-Asian-ambiguous width, so it is DECLARED in %GLYPH_COLS
        # above rather than left to the fallback. One space after the glyph,
        # like the tasklist and todos counters (operator, 2026-09-27: the
        # two-space form tried in package 01 was one too many).
        push @parts, "${MUTED}\x{29C9} ${R}${PRIMARY}${n}${R}" if $n > 0;
    }

    # The almanac counters, from the one accessor call above. Each reads
    # "<glyph> P·G": the project count, then the global one after a dot.
    # A zero or unavailable side is omitted along with its dot, and a
    # counter with nothing on either side is omitted entirely. A zero
    # project side with a non-zero global side renders dimmed and without
    # the dot (Decision 1) -- there is nothing "of the project's" to
    # highlight, so nothing here is drawn in the bright colours.
    #
    # Todos are U+274F (package 01-statusline-counters; U+22EE previously),
    # with a space before the number, same as the thread counter. Notes are
    # U+2630, with NO space before the number -- the one counter that packs
    # tight against its glyph. The thread counter is U+23E3 (package
    # 12-statusline-threads: replaces the retired U+25A3 tasklist counter;
    # unlike the tasklist, threads DO have a global side, read from the
    # snapshot -- Decision 18 F4). All are declared in Theme.pm and, where
    # not one column, in %GLYPH_COLS above.
    #
    # Clamp, thread only (spec 2.3): a defined global count below the
    # project's own is shown as the project's, since the global snapshot
    # counts every project including this one and so can never truly be
    # lower -- a sandbox-created thread can leave it stale (refresh refuses
    # in a container). An absent/invalid global thread count is 0, same as
    # every other counter here, and is never clamped (behaviour 2: no
    # snapshot renders "P", not "P.P").
    for my $c (['thread', "\x{23E3}", 1, ' ', 1], ['todo', "\x{274F}", 1, ' ', 0], ['note', "\x{2630}", 1, '', 0]) {
        my ($kind, $glyph, $has_global, $gap, $clamp) = @$c;
        my $p     = $alm_project->{$kind} // 0;
        my $g_raw = $has_global ? $alm_global->{$kind} : undef;
        my $g     = defined($g_raw) ? $g_raw : 0;
        $g = $p if $clamp && defined($g_raw) && $g < $p;
        next unless $p > 0 || $g > 0;
        my $seg;
        if ($p > 0) {
            $seg = "${MUTED}${glyph}${R}${gap}${PRIMARY}${p}${R}";
            $seg .= "${FAINT}\x{00B7}${R}${MUTED}${g}${R}" if $g > 0;
        } elsif ($kind eq 'thread') {
            # statusline-thread-row.t AC6 behaviour 3: the gap space is
            # itself INSIDE the number's text.faint run, unlike the older
            # todos/notes counters below (whose gap sits between the two
            # colour runs, uncoloured) -- both are correct against their own
            # oracle; this one is new and this is what it pins.
            $seg = "${FAINT}${glyph}${R}${FAINT}${gap}${g}${R}";
        } else {
            $seg = "${FAINT}${glyph}${R}${gap}${FAINT}${g}${R}";
        }
        push @parts, $seg;
    }

    # Double space between segments groups them as distinct categories.
    $plans_str = join('  ', @parts) if @parts;
};

# ── Context window ───────────────────────────────────────────
my $cw   = $data->{context_window} // {};
my $pct  = $cw->{used_percentage}    // 0;
my $size = $cw->{context_window_size} // 0;

sub fmt {
    my $n = shift;
    my $m = $n / 1_000_000;
    return sprintf("%dM", $m) if $m == int($m);
    return sprintf("%.1fM", $m) if $n >= 1_000_000;
    return sprintf("%.0fk", $n / 1_000)     if $n >= 1_000;
    return "$n";
}

my $pct_i       = int($pct + 0.5);
my $pc          = $pct_i >= 90 ? $CRIT : $pct_i >= 67 ? $WARN : $OK;
my $used_tokens = int($size * $pct / 100 + 0.5);
my $free_tokens = $size - $used_tokens;

# ── Plan usage ──────────────────────────────────────────────
sub usage_color {
    my $p = shift;
    return $p >= 80 ? $CRIT : $p >= 50 ? $WARN : $OK;
}

sub time_until {
    my ($val, $style) = @_;
    return '' unless defined $val && length($val);
    $style //= 'short';  # 'hm' = always XhYYm, 'short' = Xd Yh or Xh
    my $result = eval {
        my $secs;
        if ($val =~ /^\d+(\.\d+)?$/) {
            # Unix epoch (from stdin rate_limits)
            $secs = int($val) - time();
        } else {
            # ISO timestamp
            $val =~ s/Z$/+00:00/;
            $val =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})/ or return '';
            my $reset = Time::Piece->strptime("$1-$2-$3 $4:$5:$6", "%Y-%m-%d %H:%M:%S");
            $secs = $reset->epoch - gmtime()->epoch;
        }
        $secs = 0 if $secs < 0;
        my $days  = int($secs / 86400);
        my $hours = int(($secs % 86400) / 3600);
        my $mins  = int(($secs % 3600) / 60);
        if ($style eq 'hm') {
            sprintf("%dh\x{200A}%02dm", $hours + $days * 24, $mins);
        } elsif ($days > 0) {
            "${days}d\x{200A}${hours}h";
        } elsif ($hours > 0) {
            "${hours}h";
        } elsif ($mins > 0) {
            "${mins}m";
        } else {
            "${secs}s";
        }
    };
    return $result // '';
}

# ── Plan usage (from stdin JSON, native since v2.1.80) ──────
my ($plan_full, $plan_short) = ('', '');
my $rl = $data->{rate_limits};
if ($rl) {
    my $h5     = $rl->{five_hour} // {};
    my $d7     = $rl->{seven_day} // {};
    my $h5_pct = int(($h5->{used_percentage} // 0) + 0.5);
    my $d7_pct = int(($d7->{used_percentage} // 0) + 0.5);

    my $h5_reset = time_until($h5->{resets_at}, 'hm');
    my $d7_reset = time_until($d7->{resets_at});
    my $h5_r     = $h5_reset ? "${FAINT} ${h5_reset}${R}" : '';
    my $d7_r     = $d7_reset ? "${FAINT} ${d7_reset}${R}" : '';

    # ORDINARY SPACES, AND ONE SEPARATOR PER WINDOW (operator, 2026-08-26:
    # "`5h 11%｜2h 44m｜　7d 26%｜5d 18h｜` -> could be simplified to
    # `5h 11% 2h 44m｜7d 26% 5d 18h`. Since we're using a monospaced font for
    # the terminal, anyways, no need nor any point to using different-width
    # spaces").
    #
    # They are right on both counts. The ideographic space bought nothing a
    # normal space does not in a monospaced cell, and it cost a %GLYPH_COLS
    # entry to measure. And the reset time was fenced on BOTH sides, so two
    # windows spent four separators to say two things -- the fence between the
    # windows is the only one carrying meaning.
    $plan_full  = "${MUTED}5h ${R}" . usage_color($h5_pct) . "${h5_pct}%${R}${h5_r}"
                . "${FAINT}\x{FF5C}${R}${MUTED}7d ${R}" . usage_color($d7_pct) . "${d7_pct}%${R}${d7_r}";
    $plan_short = "${MUTED}5h ${R}" . usage_color($h5_pct) . "${h5_pct}%${R}"
                . "${FAINT}\x{FF5C}${R}${MUTED}7d ${R}" . usage_color($d7_pct) . "${d7_pct}%${R}";
}

# ── Row 1 ────────────────────────────────────────────────────
my $cols = cmd_out('tput', 'cols');
chomp $cols if defined $cols;
$cols = 120 unless defined($cols) && $cols =~ /^\d+$/ && $cols > 0;

# row1(...) -- render the four fields in their binding order. A field with
# no text contributes neither itself nor its separator.
#
# The working directory USED to be the third field here. The operator asked for
# it on its own line, and it is the right shape for it: a full path is the one
# field with no natural width, so on row 1 it was permanently in contention with
# every other field, and the fit ladder spent four of its eight steps eliding it.
# Given its own line it is simply shown in full, and row 1 becomes four
# bounded-width fields that essentially always fit.
#
# The $d parameter is retained rather than removed so the ladder's shape and
# every call site stay recognisable against the tests; it is always passed ''.
#
# counters($dec, $plans) -- the inbox flag and the blueprints/thread/
# todos/notes list, joined by the same two-space separator that already
# groups those segments from each other. Either half may be empty; the
# result never has a leading, trailing, or tripled space.
sub counters {
    my ($dec, $plans) = @_;
    return join('  ', grep { length } $dec, $plans);
}

sub row1 {
    my ($m, $p, $d, $g, $b) = @_;
    my $row = "${MUTED}${m}${R}";
    $row .= "${SEP}${ACCENT}${B}${p}${R}" if length $p;
    $row .= "${SEP}${FAINT}${d}${R}"      if length $d;
    $row .= "${SEP}${g}"                  if length $g;
    $row .= "${SEP}${b}"                  if length $b;
    return $row;
}

# The path line. Its own row, nothing else on it, never elided from the left the
# way it had to be when it shared row 1 -- if it exceeds the terminal width the
# terminal wraps it, which shows the whole path rather than hiding its head
# behind an ellipsis. A path you cannot read all of is the failure this move is
# meant to prevent.
sub path_row {
    my ($d) = @_;
    return '' unless defined $d && length $d;
    return "${FAINT}${d}${R}";
}

# ── The thread directory row (package 12-statusline-threads, spec 2.3) ──
#
# label_text(\%label) -> the FULL, unelided display text for a task label:
# "<blueprint>/<number> <step>" for a link, else its title. A linked task's
# OWN title field is never used here (spec 2.1 rule: "A linked task's own
# title is never rendered").
sub label_text {
    my ($label) = @_;
    return '' unless ref($label) eq 'HASH';
    if (($label->{kind} // '') eq 'link') {
        my $bp   = defined($label->{blueprint}) ? $label->{blueprint} : '';
        my $nn   = defined($label->{number})    ? $label->{number}    : '';
        my $step = defined($label->{step})      ? $label->{step}      : '';
        return "$bp/$nn $step";
    }
    return defined($label->{title}) ? $label->{title} : '';
}

# label_minimal(\%label) -> the MINIMAL elided form (spec 2.3's fit_label):
# ".../<NN>" for a link, the first character plus "..." for text.
sub label_minimal {
    my ($label) = @_;
    return '' unless ref($label) eq 'HASH';
    if (($label->{kind} // '') eq 'link') {
        my $nn = defined($label->{number}) ? $label->{number} : '';
        return ".../$nn";
    }
    my $title = defined($label->{title}) ? $label->{title} : '';
    my $first = substr($title, 0, 1);
    return length($first) ? "${first}..." : '...';
}

# fit_label(\%label, $max) -> the first form (spec 2.3) whose row_cost is at
# most $max, or undef if none is. Link forms: full, "<bp>/<NN>", then
# substr(bp,0,k).".../"NN for k=length(bp)-1 down to 0. Text forms: full,
# then the first k characters (trailing whitespace trimmed) plus "..." for
# k=length(title)-1 down to 1, skipping a k whose trimmed prefix is empty.
sub fit_label {
    my ($label, $max) = @_;
    return undef unless ref($label) eq 'HASH';
    if (($label->{kind} // '') eq 'link') {
        my $bp   = defined($label->{blueprint}) ? $label->{blueprint} : '';
        my $nn   = defined($label->{number})    ? $label->{number}    : '';
        my $step = defined($label->{step})      ? $label->{step}      : '';
        my $full = "$bp/$nn $step";
        return $full if row_cost($full) <= $max;
        my $short = "$bp/$nn";
        return $short if row_cost($short) <= $max;
        for (my $k = length($bp) - 1; $k >= 0; $k--) {
            my $cand = substr($bp, 0, $k) . ".../$nn";
            return $cand if row_cost($cand) <= $max;
        }
        return undef;
    }
    my $title = defined($label->{title}) ? $label->{title} : '';
    return $title if row_cost($title) <= $max;
    # Every character costs at least 1 and "..." costs 3, so a k-character
    # prefix can never fit once k > $max - 3 -- walking from length($title)-1
    # down to there is wasted O(L) work per candidate, O(L^2) overall, on a
    # title with no length cap (review M1 / redteam H1). Starting at
    # min(length-1, $max-3) bounds the loop by $cols instead, with no change
    # to which prefix is returned: every skipped k could not have fit anyway.
    my $k0 = length($title) - 1;
    my $max_k = $max - 3;
    $k0 = $max_k if $k0 > $max_k;
    for (my $k = $k0; $k >= 1; $k--) {
        my $p = substr($title, 0, $k);
        $p =~ s/\s+\z//;
        next unless length $p;
        my $cand = "${p}...";
        return $cand if row_cost($cand) <= $max;
    }
    return undef;
}

# thread_row(\%thread, $path_text, $cols) -> the directory row, fit to $cols
# through the 8-rung ladder (spec 2.3). $thread is almanac_thread's return
# value (always a HASH here). $path_text is '' in the sandbox (no path part
# at all, per the existing CCPRAXIS_SANDBOX rule); on the host it is the
# sanitised current_dir. The thread name and n/N are never cut.
sub thread_row {
    my ($thread, $path_text, $cols) = @_;
    my $name  = defined($thread->{name})  ? $thread->{name}  : '';
    my $N     = defined($thread->{total}) ? $thread->{total} : 0;
    my $n     = defined($thread->{done})  ? $thread->{done}  : 0;
    my @doing = (ref($thread->{doing}) eq 'ARRAY') ? @{ $thread->{doing} } : ();
    my $current = (ref($thread->{current}) eq 'HASH') ? $thread->{current} : undef;
    my $next    = (ref($thread->{next})    eq 'HASH') ? $thread->{next}    : undef;

    my $LEAD = "${MUTED}\x{23E3}${R} ${PRIMARY}${name}${R}";

    # ACT state: doing (one or more doing tasks), blocked (no doing task but
    # the first not-done task is blocked-class), else idle. A blocked TEXT
    # label folds its waits_on into the title here, once, so elision (R3)
    # treats the whole "<title>: waiting on <X>" as one string (spec 2.3's
    # ladder note on R3).
    my ($state, $act_label);
    if (@doing) {
        $state     = 'doing';
        $act_label = $doing[0];
    } elsif (defined($current) && (($current->{class} // '') eq 'blocked')) {
        $state     = 'blocked';
        $act_label = $current;
        if (($act_label->{kind} // '') ne 'link' && defined($act_label->{waits_on}) && length($act_label->{waits_on})) {
            $act_label = { %$act_label, title => "$act_label->{title}: waiting on $act_label->{waits_on}" };
        }
    } else {
        $state     = 'idle';
        $act_label = undef;
    }
    my $extra = (@doing > 1) ? (scalar(@doing) - 1) : 0;

    my $bar_part = sub {
        my ($w, $f) = @_;
        return '' unless $w > 0;
        $f = 0 if $f < 0;
        $f = $w if $f > $w;
        my $filled = "${ACCENT}" . ("\x{25B0}" x $f) . "${R}";
        my $empty  = "${FAINT}"  . ("\x{25B1}" x ($w - $f)) . "${R}";
        return " $filled$empty";
    };
    my $act_part = sub {
        my ($text) = @_;
        if ($state eq 'doing') {
            my $seg = "  ${OK}\x{25B6}${R} ${PRIMARY}${text}${R}";
            $seg .= " ${MUTED}+${extra}${R}" if $extra > 0;
            return $seg;
        }
        if ($state eq 'blocked') {
            return "  ${CRIT}${G_BLOCKED}${R} ${PRIMARY}${text}${R}";
        }
        return "  ${FAINT}\x{23F8} idle${R}";
    };
    my $next_part = sub {
        my ($text) = @_;
        return " ${FAINT}\x{2192}${R} ${MUTED}${text}${R}";
    };
    my $path_part = sub {
        my ($text) = @_;
        return '' unless length $text;
        return "  ${RULE}\x{2502}${R} ${FAINT}${text}${R}";
    };
    my $count_part = " ${PRIMARY}${n}/${N}${R}";

    my $path_disp    = defined($path_text) ? $path_text : '';
    my $next_text    = defined($next) ? label_text($next) : undef;
    my $act_text     = ($state ne 'idle' && defined($act_label)) ? label_text($act_label) : undef;
    my $bar_w        = $N;
    my $bar_f        = $n;
    my $act_removed  = 0;

    my $measure = sub {
        my $r = $LEAD;
        $r .= $bar_part->($bar_w, $bar_f);
        $r .= $count_part;
        unless ($act_removed) {
            $r .= $act_part->($act_text);
            $r .= $next_part->($next_text) if defined $next_text;
        }
        $r .= $path_part->($path_disp);
        return $r;
    };

    my $row = $measure->();
    RUNG: {
        last RUNG if row_cost($row) <= $cols;

        # R1: the path shortens to "...<sep><last>".
        if (length $path_disp) {
            my $p = $path_disp;
            $p =~ s{[/\\]+\z}{};
            if ($p =~ m{\A(.*)([/\\])([^/\\]*)\z}) {
                my $last = $3;
                $path_disp = "...$2$last" if length $last;
            }
        }
        $row = $measure->();
        last RUNG if row_cost($row) <= $cols;

        # R2: the next field elides, or is removed entirely.
        if (defined $next_text) {
            my $saved = $next_text;
            $next_text = '';
            my $without = $measure->();
            my $avail = $cols - row_cost($without);
            $next_text = $saved;
            $next_text = fit_label($next, $avail);
        }
        $row = $measure->();
        last RUNG if row_cost($row) <= $cols;

        # R3: the doing/blocked label elides, down to its minimal form.
        if ($state ne 'idle' && defined $act_text) {
            my $saved = $act_text;
            $act_text = '';
            my $without = $measure->();
            my $avail = $cols - row_cost($without);
            $act_text = $saved;
            my $fitted = fit_label($act_label, $avail);
            $act_text = defined($fitted) ? $fitted : label_minimal($act_label);
        }
        $row = $measure->();
        last RUNG if row_cost($row) <= $cols;

        # R4: the bar shrinks to the largest w in [1, N-1] that fits. A bar
        # wider than $cols can never fit (each cell costs at least 1 column),
        # so starting at min(N-1, $cols) instead of N-1 bounds this at
        # O(cols) rather than O(N) per rung, O(N^2) overall for a large
        # thread (redteam M1) -- every skipped w could not have fit anyway.
        if ($N > 1) {
            my $w0 = $N - 1;
            $w0 = $cols if $w0 > $cols;
            for (my $w = $w0; $w >= 1; $w--) {
                my $f = int($n * $w / $N);
                my ($save_w, $save_f) = ($bar_w, $bar_f);
                $bar_w = $w; $bar_f = $f;
                my $r = $measure->();
                if (row_cost($r) <= $cols) { last; }
                $bar_w = $save_w; $bar_f = $save_f;
            }
        }
        $row = $measure->();
        last RUNG if row_cost($row) <= $cols;

        # R5: the bar drops.
        $bar_w = 0; $bar_f = 0;
        $row = $measure->();
        last RUNG if row_cost($row) <= $cols;

        # R6: the path drops.
        $path_disp = '';
        $row = $measure->();
        last RUNG if row_cost($row) <= $cols;

        # R7: the activity (ACT and NEXT) drops, leaving "<lead> <n>/<N>".
        # Emitted even if the row still overflows -- the thread name and
        # n/N are never cut.
        $act_removed = 1;
        $row = $measure->();
    }
    return $row;
}

# The fit ladder. The WHOLE row is budgeted, never one field of it: the old
# code truncated the project name to the full column budget and then
# appended the separator, git and plans segments on top, overflowing the row
# by whatever those segments cost.
#
# Strict priority, stopping the moment the row fits. Order is
# identity-before-location: the working directory yields all the way to its
# floor before the project name gives up a single character, because the
# name is what says WHICH project and the path only says where in it. git
# and plans are dropped whole, never elided -- they carry embedded SGR and
# cutting one mid-escape would emit garbage.
# $f_cwd is now permanently '' on row 1: the working directory has its own row.
# The ladder keeps its cwd steps rather than deleting them, because they are
# unreachable-but-correct and deleting them would make a future "put it back"
# a rewrite instead of a one-line change. Steps 4 and 7 are no-ops while
# $f_cwd is empty -- both are already guarded by `if (length $f_cwd)`.
#
# $f_inbox is carried SEPARATELY from $f_plans (Decision 3(5)): the flag
# must keep its old survival priority, riding alongside the marker even after
# the four counters below it are dropped at step 2. It is folded back onto
# the marker at step 8 -- the last rung, same as when it lived inside the
# marker outright -- so it is truncated, not silently lost, on the narrowest
# rows.
my $f_marker    = $marker;
my $f_project   = $project;
my $f_cwd       = '';
my $f_git       = $git_str;
my $f_inbox = $inbox_str;
my $f_plans     = $plans_str;
my $sep_cost    = row_cost($SEP);
my $line1;

FIT: {
    $line1 = row1($f_marker, $f_project, $f_cwd, $f_git, counters($f_inbox, $f_plans));
    last FIT if row_cost($line1) <= $cols;

    # 2. plans, and its separator. The inbox flag is unaffected -- it
    # still rides in the counters field, now alone.
    $f_plans = '';
    $line1 = row1($f_marker, $f_project, $f_cwd, $f_git, counters($f_inbox, $f_plans));
    last FIT if row_cost($line1) <= $cols;

    # 3. git, and its separator.
    $f_git = '';
    $line1 = row1($f_marker, $f_project, $f_cwd, $f_git, counters($f_inbox, $f_plans));
    last FIT if row_cost($line1) <= $cols;

    # 4. left-elide the working directory, down to its floor.
    if (length $f_cwd) {
        my $fixed = row_cost($f_marker)
                  + (length($f_project) ? $sep_cost + row_cost($f_project) : 0)
                  + $sep_cost;
        my $avail = $cols - $fixed;
        $avail = MIN_CWD_COLS if $avail < MIN_CWD_COLS;
        $f_cwd = fit_tail($cwd, $avail);
        $line1 = row1($f_marker, $f_project, $f_cwd, $f_git, counters($f_inbox, $f_plans));
        last FIT if row_cost($line1) <= $cols;
    }

    # 5. right-elide the project name, down to its floor. $fixed accounts for
    # the inbox flag too, now that it is a field of its own rather than
    # part of $f_marker -- the project's budget must still see the whole row.
    if (length $f_project) {
        my $fixed = row_cost($f_marker) + $sep_cost
                  + (length($f_cwd) ? $sep_cost + row_cost($f_cwd) : 0)
                  + (length($f_inbox) ? $sep_cost + row_cost($f_inbox) : 0);
        my $avail = $cols - $fixed;
        $avail = MIN_PROJECT_COLS if $avail < MIN_PROJECT_COLS;
        $f_project = fit_head($project, $avail);
        $line1 = row1($f_marker, $f_project, $f_cwd, $f_git, counters($f_inbox, $f_plans));
        last FIT if row_cost($line1) <= $cols;
    }

    # 6. the project, and its separator.
    $f_project = '';
    $line1 = row1($f_marker, $f_project, $f_cwd, $f_git, counters($f_inbox, $f_plans));
    last FIT if row_cost($line1) <= $cols;

    # 7. the working directory down to a bare marker, then gone entirely.
    if (length $f_cwd) {
        $f_cwd = fit_tail($cwd, 1);
        $line1 = row1($f_marker, $f_project, $f_cwd, $f_git, counters($f_inbox, $f_plans));
        last FIT if row_cost($line1) <= $cols;
        $f_cwd = '';
        $line1 = row1($f_marker, $f_project, $f_cwd, $f_git, counters($f_inbox, $f_plans));
        last FIT if row_cost($line1) <= $cols;
    }

    # 8. the marker itself -- folding the inbox flag back onto it first,
    # in exactly today's composition, so it is the first thing fit_head cuts
    # rather than something already dropped a step earlier. Below the common
    # slot the symmetry guarantee is void by declaration -- nothing can hold
    # there -- but the budget invariant still does.
    my $m8 = $f_marker;
    if (length $f_inbox) {
        $m8 = "${f_marker}${R} ${f_inbox}";
        $f_inbox = '';
    }
    (my $bare = $m8) =~ s/\s+\z//;
    $f_marker = fit_head($bare, $cols);
    $line1 = row1($f_marker, '', '', '', '');
}

# ── Row 2 (single line if it fits, wrap if not) ──────────────
# ONE GROUP, ORDINARY SPACES (operator, 2026-08-26: "`Opus 5 1M　72% ｜720k
# 280k｜` I think we can drop the separator and extra spacing between the usage
# percentage and the token counters. It could be like this: `Opus 5 1M　72% 720k
# 280k｜`").
#
# The percentage and the two counters are three readings of one thing -- how
# much context is left -- so fencing them off from each other said they were
# different subjects. The separator now appears once, at the END, where it
# genuinely divides context from the plan-usage group that follows.
my $line2 = "${MUTED}${short}${R} "
          . "${MUTED}" . fmt($size) . "${R} "
          . "${pc}${pct_i}%${R} "
          . "${ACCENT}" . fmt($used_tokens) . "${R} "
          . "${PRIMARY}" . fmt($free_tokens) . "${R}";

# ── Assemble ─────────────────────────────────────────────────
#
# ONE ROW, NOT TWO (operator, 2026-08-26: "I think we can have it all in a
# single line instead of two"). Everything above is bounded-width and, with the
# padding, separators and the beacons segment gone, the two rows now fit one.
#
# The join is unconditional and the FIT LADDER decides what survives. That is
# the same discipline row 1 already had -- budget the whole row, never a field
# of it -- extended over the wider row: git and plans drop whole (they carry
# embedded SGR and cutting one mid-escape emits garbage), then the project
# elides, then the marker. What is NOT in the ladder is the context group: it is
# the reason the statusline exists, so it is the last thing standing.
# The groups are joined by the SAME separator row 1 already uses between its
# own fields, so the merged row has one grammar rather than two. Inside a group
# the fields are spaced, between groups they are fenced -- which is what makes
# "Opus 5 1M 71% 710k 290k" read as one reading of one thing.
#
# THE ORDER IS MARKER, CONTEXT, BUDGET, THEN THE OLD ROW-1 TAIL (operator,
# 2026-08-26: "after the HOST/SANDBOX cell, the model usage cell and the budget
# cell and then the rest of the stuff in the old order").
#
# It puts the two things that MOVE nearest the left edge. Context burn and plan
# usage change continuously and are the reason to glance at this line at all;
# project, branch and the two counts are near-constant for a session and are
# there to be found when wanted, not watched. It also means the two readings
# most likely to matter survive a narrow terminal, since the fit ladder trims
# from the tail.
my @tail;
push @tail, "${ACCENT}${B}${f_project}${R}" if length $f_project;
push @tail, $f_git if length $f_git;
my $f_counters = counters($f_inbox, $f_plans);
push @tail, $f_counters if length $f_counters;

my @segments = ("${MUTED}${f_marker}${R}", $line2);
push @segments, $plan_full if length $plan_full;
push @segments, @tail;
my $single = join $SEP, @segments;

# ...but never at the cost of losing the context readout. If the joined row does
# not fit, fall back to the previous two-row shape rather than eliding the one
# group that must always be legible. A wrapped statusline is worse than a
# two-row one, and this is the only path that can produce either.
my @rows;
if (row_cost($single) <= $cols) {
    push @rows, $single;
} else {
    my $line2_full = length($plan_full) ? "${line2}${SEP}${plan_full}" : $line2;
    if (row_cost($line2_full) <= $cols) { push @rows, $line1, $line2_full }
    else                                { push @rows, $line1, $line2, $plan_full }
}

# THE PATH ROW IS HOST-ONLY (operator, 2026-08-26: "what I said about hiding the
# working directory, I want it hidden only on the sandbox. On the host it can
# and should continue appearing in its own line as it currently does").
#
# Which is the right split. In a sandbox the working directory is always
# /project -- one fixed mount, the same string every session, in a container
# that by construction holds one project. On the host it is the answer to "where
# am I", and there it can be anywhere.
#
# THE ATTACHED THREAD LEADS THE DIRECTORY ROW (Decision 12, package
# 12-statusline-threads, spec 2.3): replaces the retired focus row
# ("U+25A3 <tasklist name> . <current task>") entirely. With no attached
# thread the directory row is exactly today's unelided path_row -- the one
# new row this package adds is thread_row's, and it REPLACES the path row in
# place on the host (so the row count never changes there) while ADDING a
# row in the sandbox, which otherwise has no directory row at all.
my $thread = almanac_thread(cwd => $workspace, session => $sid);
my $thread_path_text = $SANDBOX_ON ? '' : $cwd;
if (ref($thread) eq 'HASH') {
    push @rows, thread_row($thread, $thread_path_text, $cols);
} elsif (length $thread_path_text) {
    push @rows, path_row($thread_path_text);
}
print join("\n", @rows);
