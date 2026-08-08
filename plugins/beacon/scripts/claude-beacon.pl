#!/usr/bin/env perl
# claude-beacon.pl -- TUI launcher for resuming beaconed Claude Code sessions.
# Lives in the `beacon` plugin alongside beacon.pl. The plugin's bin/ wrappers
# (claude-beacon.{sh,ps1}) just exec into this script.
#
# Flow:
#   1. Run `beacon.pl sync-vault` synchronously so the vault reflects any
#      sandbox beacons before we list (skippable with --no-sync for tests).
#   2. Read every vault record via `beacon.pl list --format json --scope host`
#      (already sorted last_active_at desc).
#   3. Render a single-select TUI; on Enter, exec into the right resume cmd:
#        host    -> claude --resume <uuid>
#        sandbox -> claude-sandbox --resume-session <uuid> <host_project_path>
#   4. Inline 'u' key removes a beacon via `beacon.pl unbeacon` with [y/N]
#      confirm on the bottom row; 'r' re-syncs and reloads; 'q'/Esc quits.
#
# Non-TTY fallback (stdin or stdout not a tty): print a numbered list and
# read a line from stdin.
#
# Flags:
#   --no-sync   Skip the sync-vault step (debug/test only).
#
# RENDERING (blueprint unified-tui-design-system, package 09):
# every colour, attribute and glyph comes from the shared design system --
# Theme.pm plus tui::{Layout,Frame,Screen} -- which live in the SANDBOX
# plugin. This file therefore contains no raw SGR escape, no hex colour, no
# colour parameter, and no non-ASCII byte or escape of its own: the only
# escapes it may write are cursor/erase control sequences, and the only
# producer of a non-ASCII character is glyph_text().
#
# THIS FILE IS PURE ASCII, ON PURPOSE. A source scan in
# tests/t/02-beacon-render-tokens.t fails the build on a raw SGR escape, a
# six-digit hex colour, an SGR colour parameter, any `\x{...}` escape at or
# above 0x80, and any byte at or above 0x80 outside a whole-line comment.

use strict;
use warnings;
use POSIX qw(strftime);
use Cwd qw(getcwd);
use JSON::PP;
use Encode qw(decode encode FB_CROAK);
use MIME::Base64 qw(encode_base64);
use Time::Piece;
use IPC::Open3 qw(open3);
use Symbol qw(gensym);

binmode STDOUT, ':utf8';
binmode STDERR, ':utf8';

# --- The cross-plugin load of the shared render library ------------------
# Runtime, eval-guarded, degrade-not-die. `claude-beacon` is a PATH-wired
# launcher the operator runs directly, so a missing or moved sandbox plugin
# must fall back to a plain ASCII frame rather than abort.
#
# Two deliberate deviations from bp-statusline.pl's precedent, both forced:
#   * __FILE__, not FindBin. FindBin derives from $0, which is the TEST FILE
#     when the oracle requires this script in-process -- the rich path could
#     then never be exercised. launcher.pl already uses the __FILE__ form.
#   * unshift @INC + bareword require, not require "<full path>". tui/Frame.pm
#     and tui/Screen.pm carry compile-time `use tui::Layout;` / `use Theme;`
#     of their own; a full-path require populates %INC under the full-path key
#     so those transitive barewords would still miss, and requiring the same
#     file under both keys would load it twice.
# A failure at any step leaves $TUI_LIB_OK false and MUST NOT warn, print or
# die -- a warn on a TUI's stderr paints over the frame. Degradation is made
# observable instead, by the [plain render] marker on the frame's last line.
our $TUI_LIB_OK = 0;
my  $SANDBOX_SCRIPTS;
{
    (my $here = __FILE__) =~ s{\\}{/}g;
    $here =~ s{/[^/]+$}{};
    $here = '.' if !length $here;
    $SANDBOX_SCRIPTS = "$here/../../sandbox/scripts";
    if (-d $SANDBOX_SCRIPTS) {
        unshift @INC, $SANDBOX_SCRIPTS;
        $TUI_LIB_OK = eval {
            require Theme;
            require tui::Layout;
            require tui::Frame;
            require tui::Screen;
            1;
        } ? 1 : 0;
    }
}

my $home = $ENV{HOME} // $ENV{USERPROFILE};
# The refusal itself is an ACTING statement, so it lives in main() (spec §2.9):
# at file scope it made a `require` of this script die at load, and an oracle
# that dies at load reports no named assertion at all -- it just stops. The
# decode block below stays exactly where it is (§2.6 rule 9), so $home is
# defaulted to '' rather than left undef, which would make the block operate on
# undef. main() refuses before anything derived from $home is used.
my $home_ok = $home ? 1 : 0;
$home = '' if !defined $home;
# Env-var bytes from cygwin/Git Bash are UTF-8; decoding sets the
# SVf_UTF8 flag so :utf8 STDOUT encodes correctly instead of double-
# encoding the raw bytes (which would produce mojibake).
unless (utf8::is_utf8($home)) {
    my $decoded = eval { decode('UTF-8', $home, FB_CROAK) };
    $home = $decoded if defined $decoded && !$@;
}
$home =~ s/\\/\//g;

my $PLUGIN_ROOT      = "$home/.claude/ccpraxis/plugins/beacon";
my $BEACON_PL        = "$PLUGIN_ROOT/scripts/beacon.pl";
my $VAULT_DIR        = "$home/.claude/claude-code-vault";
my $VAULT_BEACON_DIR = "$VAULT_DIR/beacons";
my $REGISTRY_LOCAL   = "$VAULT_DIR/.registry-local.json";

# Assigned inside main(); file-scoped so the 'r' key still sees it.
my $no_sync = 0;

# --- Frame constants -----------------------------------------------------
# The responsive breakpoint is never written here as a literal. This screen is
# single-column at every width, so it now makes no comparison against the
# breakpoint at all -- the one place that used to (footer_text) asks whether the
# legend fits instead, which is the question it actually meant to ask.
use constant MAX_FRAME_COLS => 120;   # the existing readability cap
use constant RESERVED_ROWS  => 1;     # bottom row left for inline_confirm
use constant ROW_GAP        => 2;     # spaces between a row's text and its metadata

# --- TUI plumbing --------------------------------------------------------
# Mirrors plugins/sandbox/scripts/skills.pl: cbreak via Term::ReadKey, cursor
# and erase escapes only, restored on every exit path (END + signal traps).

my $TUI_ACTIVE = 0;
sub tui_enter {
    require Term::ReadKey;
    Term::ReadKey::ReadMode(4);  # cbreak: char-at-a-time, no echo
    print "\e[?25l";             # hide cursor
    $TUI_ACTIVE = 1;
}
sub tui_exit {
    return unless $TUI_ACTIVE;
    print "\e[?25h";             # show cursor
    print sgr_reset();           # reset attrs (from Theme, never a literal)
    eval { Term::ReadKey::ReadMode(0) };
    $TUI_ACTIVE = 0;
}
END { tui_exit() }
$SIG{INT}  = sub { tui_exit(); exit 130 };
$SIG{TERM} = sub { tui_exit(); exit 143 };

sub tui_read_key {
    my $k = Term::ReadKey::ReadKey(0);
    return undef unless defined $k;
    if ($k eq "\e") {
        my $k2 = Term::ReadKey::ReadKey(0.05);
        return 'ESC' unless defined $k2;
        if ($k2 eq '[' || $k2 eq 'O') {
            my $k3 = Term::ReadKey::ReadKey(0.05);
            return 'ESC' unless defined $k3;
            return 'UP'    if $k3 eq 'A';
            return 'DOWN'  if $k3 eq 'B';
            return 'RIGHT' if $k3 eq 'C';
            return 'LEFT'  if $k3 eq 'D';
            return 'HOME'  if $k3 eq 'H';
            return 'END'   if $k3 eq 'F';
            # Drain numeric escape sequences (e.g. PageUp)
            while (defined(my $extra = Term::ReadKey::ReadKey(0.02))) {
                last if $extra =~ /[~A-DHF]/;
            }
            return 'OTHER';
        }
        return 'ESC';
    }
    return 'ENTER' if $k eq "\n" || $k eq "\r";
    return 'SPACE' if $k eq ' ';
    return $k;
}

# Read a y/N answer with cbreak still on. Returns the lowercased single char
# or '' on EOF.
sub tui_read_yn {
    my $k = Term::ReadKey::ReadKey(0);
    return '' unless defined $k;
    return lc $k;
}

sub term_size {
    my ($w, $h) = (80, 24);
    eval {
        require Term::ReadKey;
        ($w, $h) = Term::ReadKey::GetTerminalSize();
    };
    $w = 80 if !$w || $w < 40;
    $h = 24 if !$h || $h < 10;
    return ($w, $h);
}

# --- Library-facing helpers ----------------------------------------------

# tui_lib_ok() -> 0|1. A sub rather than a bare read of the variable so a
# test can localise the flag and every caller observes the change.
sub tui_lib_ok { return $TUI_LIB_OK ? 1 : 0 }

# terminal_capability() -> 'truecolor'|'256'|'none'. The single place the
# capability is obtained; read once when the TUI loop starts and passed down
# explicitly, so tui::Frame::paint_row always gets an explicit capability.
sub terminal_capability {
    return 'none' if !tui_lib_ok();
    my $cap = eval { Theme::capability() };
    return (defined $cap && length $cap) ? $cap : 'none';
}

# sgr_reset() -> Theme's reset sequence, or '' when the library is absent.
sub sgr_reset {
    return '' if !tui_lib_ok();
    my $r = eval { Theme::reset() };
    return defined $r ? $r : '';
}

# glyph_text($name, $ascii_fallback) -> a DECODED character string. THE ONLY
# function in this file that may produce a non-ASCII character: every glyph
# comes from Theme's shared table, decoded from its UTF-8 bytes. An unknown
# name, an empty glyph, or an absent library all yield the ASCII fallback.
sub glyph_text {
    my ($name, $fallback) = @_;
    $fallback = '' if !defined $fallback || ref($fallback);
    return $fallback if !tui_lib_ok();
    return $fallback if !defined $name || ref($name);
    my $bytes = eval { Theme::glyph($name) };
    return $fallback if !defined $bytes || !length $bytes;
    my $chars = eval { decode('UTF-8', $bytes) };
    return $fallback if !defined $chars || !length $chars;
    return $chars;
}

# as_bytes($str) -> UTF-8 bytes. tui/ follows the "callers pass UTF-8 bytes"
# contract, so every string handed to a tui:: primitive goes through this.
# Encoding is conditional on the UTF8 flag for the reason documented at the
# $home block above: a value out of decode_json carries the flag when it has
# non-ASCII content and does not when it is pure ASCII (where encoding is a
# no-op). Encoding unconditionally would double-encode every flagged string.
sub as_bytes {
    my ($s) = @_;
    return '' if !defined $s;
    $s = "$s" if ref $s;
    return $s if !utf8::is_utf8($s);
    my $b = eval { encode('UTF-8', $s) };
    return defined $b ? $b : $s;
}

# text_cols($str) -> display columns. RICH PATH ONLY -- every caller sits below
# frame_lines' short-circuit to plain_lines, which measures in characters with
# Perl's own length (C-10). It carried a `return length($s) if !tui_lib_ok()`
# arm that no production path and no test could ever reach; the eval guard below
# remains, because that one covers a library that IS loaded and still throws.
sub text_cols {
    my ($s) = @_;
    return 0 if !defined $s;
    my $w = eval { tui::Layout::display_width(as_bytes($s)) };
    return defined $w ? $w : length($s);
}

# --- Sanitization & formatting -------------------------------------------
# Labels/summaries/slugs can contain anything per beacon.pl's accepted
# risks. Strip ANSI/control chars before rendering so a malicious label
# can't clear the screen or repaint. tui::Frame::safe sanitises a second
# time on the rich path; this one also guards the degraded path.
sub sanitize_display {
    my $s = shift;
    return '' unless defined $s;
    if (!utf8::is_utf8($s)) {
        my $decoded = eval { decode('UTF-8', $s, FB_CROAK) };
        $s = $decoded if defined $decoded && !$@;
    }
    $s =~ s/\e\[[0-9;?]*[A-Za-z]//g;   # CSI sequences
    $s =~ s/\e\][^\a\e]*(?:\a|\e\\)//g; # OSC sequences
    $s =~ s/\e[^\[\]]//g;              # other ESC + 1
    $s =~ s/[\x00-\x1F\x7F]//g;        # C0 controls (incl \r \n \t) + DEL
    return $s;
}

# truncate_str($s, $max) -> a plain CHARACTER-count cut. Used only by the
# degraded render, which measures in characters; on the rich path
# truncation is tui::Frame::fit_spans's job and happens at a glyph boundary.
sub truncate_str {
    my ($s, $max) = @_;
    return '' unless defined $s;
    $max = 0 if !defined $max || ref($max) || $max !~ /^-?\d+$/;
    $max = int($max);
    return '' if $max <= 0;
    return $s if length($s) <= $max;
    return substr($s, 0, $max);
}

sub relative_time {
    my $iso = shift;
    return '' unless defined $iso && length $iso;
    my $epoch;
    eval {
        $iso =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})/ or die "bad iso\n";
        $epoch = Time::Piece->strptime("$1-$2-$3 $4:$5:$6", "%Y-%m-%d %H:%M:%S")->epoch;
    };
    return '' if $@ || !$epoch;
    my $secs = time() - $epoch;
    $secs = 0 if $secs < 0;
    return 'just now'     if $secs < 30;
    return "${secs}s ago" if $secs < 60;
    my $mins = int($secs / 60);
    return "${mins}m ago" if $mins < 60;
    my $hours = int($mins / 60);
    return "${hours}h ago" if $hours < 24;
    my $days = int($hours / 24);
    return "${days}d ago" if $days < 30;
    my $months = int($days / 30);
    return "${months}mo ago" if $months < 12;
    my $years = int($months / 12);
    return "${years}y ago";
}

# --- Pure render vocabulary ----------------------------------------------
# Every function below is total: any input (undef, refs, blessed objects,
# negative widths) yields a value, never a die and never a warn.

# frame_cols($cols) -> the frame's width: the terminal's, capped for
# readability, floored at 1.
sub frame_cols {
    my ($cols) = @_;
    $cols = 0 if !defined $cols || ref($cols) || $cols !~ /^-?\d+(?:\.\d+)?$/;
    $cols = int($cols);
    $cols = MAX_FRAME_COLS() if $cols > MAX_FRAME_COLS();
    $cols = 1 if $cols < 1;
    return $cols;
}

# frame_height($rows) -> composed rows: the terminal's, minus the reserved
# bottom row that inline_confirm writes on.
sub frame_height {
    my ($rows) = @_;
    $rows = 0 if !defined $rows || ref($rows) || $rows !~ /^-?\d+(?:\.\d+)?$/;
    return int($rows) - RESERVED_ROWS();
}

# list_height($frame_rows, $cols, $n_banners) -> visible list rows, floored
# at 1. The two extra rows are the panel title line and the summary line.
sub list_height {
    my ($rows, $cols, $n_banners) = @_;
    $rows = 0 if !defined $rows || ref($rows) || $rows !~ /^-?\d+(?:\.\d+)?$/;
    $n_banners = 0
        if !defined $n_banners || ref($n_banners) || $n_banners !~ /^-?\d+(?:\.\d+)?$/;
    my $h = int($rows) - 2 - int($n_banners) - 2;
    return $h < 1 ? 1 : $h;
}

# row_fields(\%beacon) -> { slug, desc, scope, ago }, DECODED strings.
#
# Reads `project_slug`, and ONLY that: it is the key beacon.pl actually writes
# (beacon.pl:132) and the one every other reader here already used --
# run_non_tty and the dispatch path both read it bare. This briefly also
# accepted a short `slug` key as a fallback, added to satisfy oracle fixtures
# that had been written with the short form. The fixtures were corrected to the
# real key instead: a fallback that exists only because a test invented a
# record shape is dead in production, and it quietly tells the next reader that
# two key spellings are in circulation when only one ever is.
sub row_fields {
    my ($b) = @_;
    $b = {} if ref($b) ne 'HASH';
    my $slug     = sanitize_display($b->{project_slug});
    my $label    = sanitize_display($b->{label});
    my $summary  = sanitize_display($b->{summary});
    my $desc     = length($label)   ? $label
                 : length($summary) ? $summary
                 : '(unlabeled)';
    my $scope    = (defined $b->{scope} && !ref($b->{scope}) && $b->{scope} eq 'sandbox')
                 ? 'sandbox' : 'host';
    my $ago      = relative_time($b->{last_active_at});
    return { slug => $slug, desc => $desc, scope => $scope, ago => $ago };
}

# right_text(\%fields) -> "<scope> <dot> <ago>".
sub right_text {
    my ($f) = @_;
    $f = {} if ref($f) ne 'HASH';
    my $scope = defined $f->{scope} && !ref($f->{scope}) ? $f->{scope} : '';
    my $ago   = defined $f->{ago}   && !ref($f->{ago})   ? $f->{ago}   : '';
    return $scope . ' ' . glyph_text('sep.dot') . ' ' . $ago;
}

# right_text, left_spans, row_spans and summary_text are RICH PATH ONLY (see
# beacon_screen), so their glyph_text calls pass no ASCII fallback: the degraded
# render is plain_row's and plain_summary's job, and those spell their `-`, `>`,
# `^` and `v` out themselves. The fallback ARGUMENT is dropped, never
# glyph_text's fallback MECHANISM -- run_non_tty is a live degrade path and
# keeps its `glyph_text('sep.dot', '-')`.

# left_spans(\%fields, $selected) -> the slug/separator/description spans.
sub left_spans {
    my ($f, $selected) = @_;
    $f = {} if ref($f) ne 'HASH';
    my $slug = defined $f->{slug} && !ref($f->{slug}) ? $f->{slug} : '';
    my $desc = defined $f->{desc} && !ref($f->{desc}) ? $f->{desc} : '';
    my @spans;
    if (length $slug) {
        push @spans, { text => as_bytes($slug), role => 'text.muted' };
        push @spans, { text => as_bytes(' ' . glyph_text('sep.dot') . ' '),
                       role => 'text.faint' };
    }
    push @spans, { text => as_bytes($desc),
                   role => $selected ? 'accent' : 'text.primary' };
    return \@spans;
}

# row_spans(\%beacon, $selected, $inner_w) -> spans exactly $inner_w wide.
# Selection is carried by the cursor GLYPH plus the accent role, never by
# reverse video: at capability 'none' the colour is gone but the glyph is not.
# When the metadata group cannot fit, it is dropped whole and the description
# absorbs the width.
sub row_spans {
    my ($b, $selected, $inner_w) = @_;
    $inner_w = 0 if !defined $inner_w || ref($inner_w) || $inner_w !~ /^-?\d+(?:\.\d+)?$/;
    $inner_w = int($inner_w);

    my $f     = row_fields($b);
    my $mark  = $selected ? glyph_text('cursor') : ' ';
    my @spans = (
        { text => as_bytes($mark), role => $selected ? 'accent' : 'text.faint' },
        { text => ' ',             role => 'text.faint' },
    );

    my $left  = left_spans($f, $selected);
    my $right = right_text($f);
    my $avail = $inner_w - 2 - text_cols($right) - ROW_GAP();

    if ($avail >= 1) {
        push @spans, @{ tui::Frame::fit_spans($left, $avail, 'text.faint') };
        push @spans, { text => ' ' x ROW_GAP(), role => 'text.faint' };
        push @spans, { text => as_bytes($right), role => 'text.faint' };
    }
    else {
        my $only = $inner_w - 2;
        $only = 0 if $only < 0;
        push @spans, @{ tui::Frame::fit_spans($left, $only, 'text.faint') };
    }
    return \@spans;
}

# summary_text(\%vp, $total) -> "<first>-<last> of <total>" plus the scroll
# marks for whatever is hidden above and below.
sub summary_text {
    my ($vp, $total) = @_;
    $vp = {} if ref($vp) ne 'HASH';
    $total = 0 if !defined $total || ref($total) || $total !~ /^-?\d+(?:\.\d+)?$/;
    $total = int($total);
    my $first = $vp->{first};
    my $last  = $vp->{last};
    $first = 0  if !defined $first || ref($first) || $first !~ /^-?\d+$/;
    $last  = -1 if !defined $last  || ref($last)  || $last  !~ /^-?\d+$/;
    return 'no sessions' if $total < 1 || $last < $first;

    my $s = sprintf('%d-%d of %d', $first + 1, $last + 1, $total);
    my $above = $vp->{above};
    my $below = $vp->{below};
    $above = 0 if !defined $above || ref($above) || $above !~ /^-?\d+$/;
    $below = 0 if !defined $below || ref($below) || $below !~ /^-?\d+$/;
    $s .= ' ' . glyph_text('scroll.up')   if $above > 0;
    $s .= ' ' . glyph_text('scroll.down') if $below > 0;
    return $s;
}

# footer_text($cols) -> the key legend. The full form whenever it FITS the
# frame's width budget, the compact form otherwise.
#
# The choice is deliberately NOT keyed to tui::Layout::arrangement (nor to any
# literal width). The compact form's whole reason for existing is that at narrow
# widths the quit key must not be what truncation removes -- an appeal to fit.
# Keying it to the two-column breakpoint made that reason misfire: the full
# legend is ~62 columns, but the breakpoint is 90, so at 80 columns -- the most
# common terminal width, and term_size()'s own floor -- the legend collapsed to
# `enter . u . r . q` with 18 columns of room going spare. Asking "does it fit"
# answers the actual question, and keeps answering it if the legend text changes.
#
# Both legends are pure ASCII literals declared right here, so `length` is their
# display width; text_cols() is deliberately not used, since it belongs to the
# rich path and this function is also called by plain_lines.
sub footer_text {
    my ($cols) = @_;
    $cols = 0 if !defined $cols || ref($cols) || $cols !~ /^-?\d+(?:\.\d+)?$/;
    $cols = int($cols);

    my $limit = $cols > MAX_FRAME_COLS() ? MAX_FRAME_COLS() : $cols;
    $limit = 0 if $limit < 0;

    my $full    = 'up/down select . enter resume . u unbeacon . r refresh . q quit';
    my $compact = 'enter . u . r . q';
    my $legend  = length($full) <= $limit ? $full : $compact;

    return length($legend) > $limit ? substr($legend, 0, $limit) : $legend;
}

# _state_cursor(\%state, $total) -> a clamped integer cursor. PRIVATE.
sub _state_cursor {
    my ($state, $total) = @_;
    $state = {} if ref($state) ne 'HASH';
    my $cursor = $state->{cursor};
    $cursor = 0 if !defined $cursor || ref($cursor) || $cursor !~ /^-?\d+(?:\.\d+)?$/;
    $cursor = int($cursor);
    $cursor = 0 if $cursor < 0;
    $cursor = $total - 1 if $cursor > $total - 1;
    $cursor = 0 if $cursor < 0;
    return $cursor;
}

# _state_status(\%state) -> ($text_or_undef, $role). PRIVATE.
sub _state_status {
    my ($state) = @_;
    $state = {} if ref($state) ne 'HASH';
    my $msg = $state->{status};
    $msg = undef if defined($msg) && (ref($msg) || !length "$msg");
    $msg = sanitize_display($msg) if defined $msg;
    $msg = undef if defined($msg) && !length $msg;
    my $role = $state->{status_role};
    $role = 'text.muted'
        if !defined $role || ref($role) || !length $role;
    return ($msg, $role);
}

# _viewport($total, $height, $cursor) -> the same scrolling arithmetic
# tui::Screen::viewport performs, carried here for the DEGRADED path only:
# the plain render must not depend on the library whose absence produced it.
# The rich path calls tui::Screen::viewport itself. PRIVATE.
sub _viewport {
    my ($total, $height, $cursor) = @_;
    return { first => 0, last => -1, above => 0, below => 0, count => 0 }
        if $total < 1 || $height < 1;
    $cursor = 0 if $cursor < 0;
    $cursor = $total - 1 if $cursor > $total - 1;
    return { first => 0, last => $total - 1, above => 0, below => 0, count => $total }
        if $total <= $height;
    my $first = $cursor - int(($height - 1) / 2);
    $first = 0 if $first < 0;
    $first = $total - $height if $first > $total - $height;
    my $last = $first + $height - 1;
    return { first => $first, last => $last,
             above => $first, below => $total - 1 - $last, count => $height };
}

# _banner_lines($msg, $w, $role) -> \@lines, each an arrayref of spans. PRIVATE,
# rich path only.
#
# The status banner is the one place a message of unbounded length reaches the
# frame: `Unbeacon failed: $err` carries beacon.pl's own captured stdout. Handed
# to tui::Screen::compose as a single string it goes through make_cell, which
# fits it to exactly $cols -- so a diagnostic longer than the frame is cut with
# no ellipsis and no indication that anything was lost. Losing text on a FAILURE
# path is the worst place to lose it, so the message is word-wrapped across as
# many banner rows as it needs instead. compose() still caps the banner block at
# body_height - 1 rows, so a pathological message cannot swallow the list.
#
# A word too wide to wrap (an unbroken path, say) would be left intact by
# tui::Layout::wrap and then cut by make_cell just the same, so such words are
# split on a display-column boundary first: split text is recoverable, cut text
# is not.
sub _banner_lines {
    my ($msg, $w, $role) = @_;
    $msg = '' if !defined $msg || ref($msg);
    $w = 1 if !defined $w || ref($w) || $w !~ /^-?\d+$/ || $w < 1;

    my @words;
    for my $word (split /\s+/, $msg) {
        next if !length $word;
        while (text_cols($word) > $w) {
            my ($head, $used) = ('', 0);
            while (length $word) {
                my $ch = substr($word, 0, 1);
                my $cw = text_cols($ch);
                last if $used + $cw > $w;
                $head .= $ch;
                $used += $cw;
                $word  = substr($word, 1);
            }
            last if !length $head;   # a single char wider than $w: no progress
            push @words, $head;
        }
        push @words, $word if length $word;
    }
    return [] if !@words;

    my $lines = eval {
        tui::Layout::wrap([ map { { text => as_bytes($_), role => $role } } @words ],
                          $w, $role);
    };
    return ref($lines) eq 'ARRAY' && @$lines ? $lines : [ [ { text => as_bytes($msg),
                                                              role => $role } ] ];
}

# beacon_screen(\@beacons, \%state, $rows, $cols) -> a tui::Screen descriptor.
# $rows is the TERMINAL height; the reserved bottom row is subtracted here.
# RICH PATH ONLY: frame_lines short-circuits to plain_lines before reaching
# this, so it may call the library unguarded. The same is true of everything it
# calls -- _banner_lines, row_spans, summary_text.
sub beacon_screen {
    my ($beacons, $state, $rows, $cols) = @_;
    $beacons = [] if ref($beacons) ne 'ARRAY';
    my $c  = frame_cols($cols);
    my $fr = frame_height($rows);
    my $total = scalar @$beacons;

    my $cursor = _state_cursor($state, $total);
    my ($msg, $role) = _state_status($state);
    my @banners = defined $msg ? @{ _banner_lines($msg, $c, $role) } : ();

    my $lh = list_height($fr, $c, scalar @banners);
    my $vp = tui::Screen::viewport($total, $lh, $cursor);

    my @lines;
    if (($vp->{count} || 0) > 0) {
        for my $i ($vp->{first} .. $vp->{last}) {
            push @lines, { role  => 'text.primary',
                           spans => row_spans($beacons->[$i], ($i == $cursor), $c - 2) };
        }
    }
    else {
        push @lines, [ { text => '(no beacons)', role => 'text.muted' } ];
    }
    push @lines, [ { text => as_bytes(summary_text($vp, $total)), role => 'text.faint' } ];

    return {
        title       => [ { text => as_bytes(sprintf('beacons (%d)', $total)),
                           role => 'accent' } ],
        title_role  => 'accent',
        banners     => \@banners,
        banner_role => $role,
        panels      => [ { title => 'sessions', lines => \@lines } ],
        footer      => footer_text($c),
        footer_role => 'text.faint',
    };
}

# frame_lines(\@beacons, \%state, $rows, $cols, $cap) -> DECODED strings,
# ready to print to the :utf8 handle. Printing paint_row's BYTES straight to
# that handle would double-encode every glyph, so the decode is mandatory.
sub frame_lines {
    my ($beacons, $state, $rows, $cols, $cap) = @_;
    return plain_lines($beacons, $state, $rows, $cols) if !tui_lib_ok();

    $beacons = [] if ref($beacons) ne 'ARRAY';
    my $c  = frame_cols($cols);
    my $fr = frame_height($rows);
    return [] if $fr < 1;

    my $screen = beacon_screen($beacons, $state, $rows, $cols);
    my $cells  = tui::Screen::compose($screen, $fr, $c);
    return [ map { decode('UTF-8', tui::Frame::paint_row($_, $cap)) } @$cells ];
}

# _plain_banner_lines($msg, $w) -> \@lines of CHARACTERS. The degraded twin of
# _banner_lines, for the same reason: a `Unbeacon failed: ...` message carries
# beacon.pl's own stdout, and truncate_str would cut it to $cols with nothing to
# say so. Measured in characters, not display columns -- the degraded path has
# no library to ask (C-10). PRIVATE.
sub _plain_banner_lines {
    my ($msg, $w) = @_;
    return [] if !defined $msg || ref($msg) || !length $msg;
    $w = 1 if !defined $w || ref($w) || $w !~ /^-?\d+$/ || $w < 1;

    my (@lines, $cur);
    $cur = '';
    for my $word (split /\s+/, $msg) {
        next if !length $word;
        while (length($word) > $w) {
            push @lines, $cur if length $cur;
            $cur = '';
            push @lines, substr($word, 0, $w);
            $word = substr($word, $w);
        }
        if (!length $cur)                                  { $cur = $word }
        elsif (length($cur) + 1 + length($word) <= $w)     { $cur .= ' ' . $word }
        else { push @lines, $cur; $cur = $word }
    }
    push @lines, $cur if length $cur;
    return \@lines;
}

# plain_lines(\@beacons, \%state, $rows, $cols) -> the degraded render:
# printable ASCII decorations only, no escape of any kind, each line cut to
# at most $cols CHARACTERS, and a last line carrying the [plain render]
# marker. That marker is how a degraded launch is observable without a warn
# painting over the frame.
sub plain_lines {
    my ($beacons, $state, $rows, $cols) = @_;
    $beacons = [] if ref($beacons) ne 'ARRAY';
    my $c  = frame_cols($cols);
    my $fr = frame_height($rows);
    return [] if $fr < 1;

    my $total  = scalar @$beacons;
    my $cursor = _state_cursor($state, $total);
    my ($msg, undef) = _state_status($state);
    my @banners = @{ _plain_banner_lines($msg, $c) };

    my $lh = list_height($fr, $c, scalar @banners);
    my $vp = _viewport($total, $lh, $cursor);

    my @body;
    push @body, truncate_str(sprintf('beacons (%d)', $total), $c);
    push @body, truncate_str($_, $c) for @banners;

    my $head = '-- sessions ';
    my $fill = $c - length($head);
    push @body, truncate_str($head . ('-' x ($fill > 0 ? $fill : 0)), $c);

    if ($vp->{count} > 0) {
        for my $i ($vp->{first} .. $vp->{last}) {
            push @body, plain_row($beacons->[$i], ($i == $cursor), $c);
        }
    }
    else {
        push @body, truncate_str('(no beacons)', $c);
    }
    push @body, truncate_str(plain_summary($vp, $total), $c);

    my $keep = $fr - 1;
    $keep = 0 if $keep < 0;
    @body = () if $keep == 0;
    @body = @body[ 0 .. $keep - 1 ] if $keep > 0 && @body > $keep;
    push @body, '' while @body < $keep;

    my $marker = ' [plain render]';
    my $room   = $c - length($marker);
    my $last   = $room >= 1
               ? truncate_str(footer_text($c), $room) . $marker
               : substr($marker, 0, $c);
    push @body, $last;
    return \@body;
}

# plain_row(\%beacon, $selected, $w) -> one degraded row, ASCII decorations
# only. Record text passes through as it stands -- an accented label reads
# the same here as it does in the rich frame.
sub plain_row {
    my ($b, $selected, $w) = @_;
    my $f     = row_fields($b);
    my $mark  = $selected ? '>' : ' ';
    my $left  = length($f->{slug}) ? $f->{slug} . ' - ' . $f->{desc} : $f->{desc};
    my $right = $f->{scope} . ' - ' . $f->{ago};
    my $avail = $w - 2 - length($right) - ROW_GAP();

    my $line;
    if ($avail >= 1) {
        $left = truncate_str($left, $avail);
        $line = $mark . ' ' . $left . (' ' x ($avail - length($left)))
              . (' ' x ROW_GAP()) . $right;
    }
    else {
        my $only = $w - 2;
        $only = 0 if $only < 0;
        $line = $mark . ' ' . truncate_str($left, $only);
    }
    return truncate_str($line, $w);
}

# plain_summary(\%vp, $total) -> the degraded summary line: the same text as
# summary_text, with ASCII scroll marks.
sub plain_summary {
    my ($vp, $total) = @_;
    return 'no sessions' if $total < 1 || $vp->{last} < $vp->{first};
    my $s = sprintf('%d-%d of %d', $vp->{first} + 1, $vp->{last} + 1, $total);
    $s .= ' ^' if $vp->{above} > 0;
    $s .= ' v' if $vp->{below} > 0;
    return $s;
}

# --- Windows-aware executable resolver -----------------------------------
# Perl's `exec LIST` on Windows calls CreateProcess directly and does NOT
# enumerate PATHEXT -- so `exec 'claude', ...` won't find `claude.cmd` (the
# npm-global form) and `exec 'claude-sandbox', ...` won't find our `.ps1`
# wrapper. On POSIX, exec + PATH resolution works normally for symlinks
# and scripts with shebangs.
#
# Returns an argv list (arrayref) ready to pass to exec. For `.ps1`
# targets we wrap with `powershell.exe -NoProfile -ExecutionPolicy Bypass
# -File <path>` because CreateProcess can't run PowerShell scripts
# directly. For `.cmd`/`.bat`/`.exe`/`.com` we exec the resolved path.
sub find_executable {
    my $name = shift;
    return [$name] if $^O ne 'MSWin32';

    my @pathext = grep { length } split /;/, ($ENV{PATHEXT} // '.COM;.EXE;.BAT;.CMD');
    @pathext = map { /^\./ ? $_ : ".$_" } @pathext;
    # Always try .PS1 -- our wrapper lives there even when PATHEXT omits it.
    push @pathext, '.PS1' unless grep { lc($_) eq '.ps1' } @pathext;

    for my $dir (split /;/, ($ENV{PATH} // '')) {
        next unless length $dir;
        $dir =~ s/[\\\/]+$//;
        for my $ext (@pathext) {
            my $p = "$dir\\$name$ext";
            next unless -f $p;
            if (lc($ext) eq '.ps1') {
                return ['powershell.exe', '-NoProfile',
                        '-ExecutionPolicy', 'Bypass', '-File', $p];
            }
            return [$p];
        }
    }
    return [$name];  # not found; exec will fail with a clear error
}

# --- Subprocess helper (no shell) ----------------------------------------
# Returns (stdout, exit_code). Drains stderr to avoid pipe deadlock, and
# captures BOTH pipes so a spawned beacon.pl can never write over the frame.
sub run_capture {
    my @cmd = @_;
    my $in  = gensym();
    my $out = gensym();
    my $err = gensym();
    my $pid = eval { open3($in, $out, $err, @cmd) };
    return ('', -1) if !$pid || $@;
    close $in;
    my $out_buf = do { local $/; <$out> } // '';
    do { local $/; <$err> };
    close $out;
    close $err;
    waitpid($pid, 0);
    return ($out_buf, $? >> 8);
}

# --- chdir helper (handles Win32 ANSI-API + Unicode paths) ---------------
# Perl's chdir on Windows passes bytes to the Win32 ANSI API. A Unicode
# string coming out of decode_json often fails with ENOENT even when the
# directory exists -- the raw Perl string is internally UTF-8 bytes, but the
# ANSI API expects the active codepage. We try the string as-is first (POSIX
# + Strawberry Perl wide-char builds work that way), then fall back to
# explicit encodings: system codepage (cp1252 on Western Windows) and UTF-8.
# Returns (ok_bool, error_message).
sub try_chdir {
    my $path = shift;
    return (0, 'no path') unless defined $path;
    return (0, 'empty path') unless length $path;

    # 1. As-is (Unicode string).
    return (1, '') if chdir $path;
    my $first_err = "$!";

    # 2. Encoded fallbacks -- only on Windows.
    if ($^O =~ /^(MSWin32|cygwin|msys)$/) {
        for my $enc (qw(cp1252 UTF-8)) {
            my $bytes = eval {
                Encode::encode($enc, $path,
                               Encode::FB_CROAK | Encode::LEAVE_SRC)
            };
            next if !defined $bytes || $@;
            next if $bytes eq $path;  # no-op encoding; skip the retry
            return (1, '') if chdir $bytes;
        }
    }
    return (0, "chdir failed: $first_err");
}

# --- Vault gathering -----------------------------------------------------

# Set by gather() when a non-zero sync-vault happened while the TUI was up, and
# consumed by the 'r' handler. See the routing note inside gather().
my $SYNC_NOTE;

sub gather {
    my $skip_sync = shift;
    $SYNC_NOTE = undef;
    unless ($skip_sync) {
        # Idempotent and LOCK_NB-deduped against the statusline's bg fire.
        # We don't care about the output; even a failure is non-fatal -- the
        # subsequent list call works against the current vault state.
        my (undef, $rc) = run_capture($^X, $BEACON_PL, 'sync-vault');
        if ($rc != 0 && $rc != -1) {
            my $note = "Note: sync-vault exited $rc; using current vault as-is.";
            # The SAME argument the load block at the top of this file makes:
            # a warn on a TUI's stderr paints over the frame. It is worse here
            # than there, and permanently so -- gather() is reachable from the
            # 'r' key, the cursor is parked on the reserved bottom row, and the
            # paint loop only rewrites rows 1..$frame_rows, so the text lands on
            # a row nothing ever repaints and survives the rest of the session
            # (scrolling the terminal on its way in). Routed to the status
            # banner instead, which the frame owns and clears. Outside the TUI
            # the warn is unchanged -- §2.6 rule 3 pins it.
            if ($TUI_ACTIVE) { $SYNC_NOTE = $note }
            else             { warn "$note\n" }
        }
    }

    my ($json, $rc) = run_capture(
        $^X, $BEACON_PL, 'list', '--format', 'json', '--scope', 'host'
    );
    if ($rc != 0) {
        print STDERR "claude-beacon: beacon.pl list failed (exit $rc)\n";
        print STDERR $json if length $json;
        exit 1;
    }
    my $records = eval { decode_json($json) };
    if ($@ || ref($records) ne 'ARRAY') {
        print STDERR "claude-beacon: cannot parse beacon list JSON: $@\n";
        exit 1;
    }
    return $records;
}

# Inline confirm rendered on the reserved bottom row. Stays in cbreak.
sub inline_confirm {
    my $prompt = shift;
    # Move to start of current line, clear it, write the prompt with no
    # newline so the next ReadKey shows the cursor where the user expects.
    print "\r\e[2K";
    print "\e[?25h$prompt";   # temporarily show cursor for the answer
    my $ch = tui_read_yn();
    print "\e[?25l";          # hide again
    print "\r\e[2K";
    return $ch;
}

# --- Resolve host project path for sandbox dispatch ----------------------
# Used for legacy sandbox records without host_project_path. Walks the
# registered sandbox project dirs and returns the first whose
# .ccpraxis-local-data/claude-home/beacons/<uuid>.json matches.
sub resolve_host_path_via_walk {
    my $uuid = shift;
    return undef unless -f $REGISTRY_LOCAL;
    my $reg;
    eval {
        open my $fh, '<:raw', $REGISTRY_LOCAL or die;
        my $raw = do { local $/; <$fh> };
        close $fh;
        $reg = decode_json($raw);
    };
    return undef if $@ || !$reg || ref($reg->{projects}) ne 'HASH';
    for my $slug (keys %{$reg->{projects}}) {
        my $p = $reg->{projects}{$slug}{path} // next;
        $p =~ s/\\/\//g;
        $p =~ s{^/([a-zA-Z])/}{$1:/};
        return $p if -f "$p/.ccpraxis-local-data/claude-home/beacons/$uuid.json";
    }
    return undef;
}

# --- Dispatch (exec into resume cmd) -------------------------------------

# valid_session_id($sid) -> 1 for a canonical UUID, 0 otherwise. beacon.pl
# writes only valid UUIDs into the vault, but this value is about to be
# passed to another process and we want a hard guarantee, not a transitive
# trust. Anchored with \z, never $, so a trailing newline is rejected.
sub valid_session_id {
    my ($sid) = @_;
    return 0 if !defined $sid || ref($sid);
    return $sid =~ /\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/
        ? 1 : 0;
}

# ps_encoded_command($cwd, $sid) -> the base64 payload for PowerShell's
# -EncodedCommand. PURE: no I/O, never dies, never warns.
#
# PowerShell -EncodedCommand takes UTF-16LE base64 and decodes it natively,
# bypassing the Win32 argv codepage interpretation that otherwise mangles
# non-ASCII paths (passing them as cp1252 mojibake on the shell's command
# line). The base64 wire format is pure ASCII so it survives the
# perl-to-CreateProcess hop.
sub ps_encoded_command {
    my ($cwd, $sid) = @_;
    my $psq = defined $cwd ? "$cwd" : '';
    $psq =~ s/'/''/g;
    my $id = defined $sid ? "$sid" : '';
    my $ps_cmd = "Set-Location -LiteralPath '$psq'; & claude --resume $id";
    my $utf16le = eval { encode('UTF-16LE', $ps_cmd) };
    return '' if !defined $utf16le;
    my $b64 = eval { encode_base64($utf16le, '') };
    return defined $b64 ? $b64 : '';
}

sub dispatch {
    my $b = shift;
    my $sid = $b->{session_id};

    unless (valid_session_id($sid)) {
        tui_exit();
        print STDERR "claude-beacon: refusing to dispatch -- invalid UUID in record: "
            . (defined $sid ? $sid : '<undef>') . "\n";
        exit 1;
    }

    my $scope = $b->{scope} // 'host';

    if ($scope eq 'host') {
        my $cwd = $b->{cwd};
        # Normalize git-bash /c/... back to C:/... for display + downstream.
        if (defined $cwd) {
            $cwd =~ s{^/([a-zA-Z])/}{$1:/};
            # Belt-and-suspenders: ensure $cwd is Unicode-flagged before it
            # flows into encode('UTF-16LE', ...). decode_json normally sets
            # SVf_UTF8 on non-ASCII values, but if a future caller bypasses
            # the JSON path or uses a JSON variant that returns raw bytes,
            # the UTF-16LE encoder would treat the bytes as Latin-1 and
            # double-encode -- exactly the bug the $home fix prevents
            # elsewhere. The is_utf8 guard makes this a no-op when already
            # decoded.
            unless (utf8::is_utf8($cwd)) {
                my $d = eval { decode('UTF-8', $cwd, FB_CROAK) };
                $cwd = $d if defined $d && !$@;
            }
        }
        tui_exit();
        print "\n";

        # Windows: delegate cwd + launch to PowerShell. perl's chdir on
        # Win32/cygwin is flaky for non-ASCII paths when perl is invoked from
        # PowerShell (the MSYS2 path-translation runtime isn't initialized,
        # so non-ASCII codepoints reach Win32 ANSI APIs as raw UTF-8 bytes
        # that don't resolve). PowerShell uses wide-char Win32 APIs natively
        # and handles such paths reliably.
        if ($^O =~ /^(MSWin32|cygwin|msys)$/) {
            if (defined $cwd && length $cwd) {
                my $b64 = ps_encoded_command($cwd, $sid);
                print "[resume] cd '$cwd' && claude --resume $sid  (via PowerShell -EncodedCommand)\n";
                { exec 'powershell.exe', '-NoProfile', '-EncodedCommand', $b64 }
            } else {
                print "[resume] claude --resume $sid  (no cwd in record)\n";
                my $argv = find_executable('claude');
                { exec @$argv, '--resume', $sid }
            }
            die "exec failed: $!\n";
        }

        # POSIX (Linux/macOS): chdir + exec is reliable.
        my ($chdir_ok, $chdir_err) = try_chdir($cwd);
        if ($chdir_ok) {
            print "[resume] cd $cwd && claude --resume $sid\n";
        } else {
            print "[resume] claude --resume $sid  (original cwd unavailable: $chdir_err)\n";
        }
        my $argv = find_executable('claude');
        { exec @$argv, '--resume', $sid }
        die "exec claude failed (tried: @$argv): $!\n";
    }
    elsif ($scope eq 'sandbox') {
        my $proj = $b->{host_project_path};
        if (defined $proj) {
            $proj =~ s{^/([a-zA-Z])/}{$1:/};
        }
        if (!defined $proj || !-d $proj) {
            # Legacy record without host_project_path, or the project
            # moved since ingestion. Try the registry walk.
            my $alt = resolve_host_path_via_walk($sid);
            $proj = $alt if defined $alt && -d $alt;
        }
        unless (defined $proj && -d $proj) {
            tui_exit();
            print STDERR "claude-beacon: cannot resolve host project path for sandbox beacon $sid\n";
            print STDERR "  (record's host_project_path: " . ($b->{host_project_path} // '<none>') . ")\n";
            exit 1;
        }
        tui_exit();
        print "\n";
        print "[resume] claude-sandbox --resume-session $sid $proj\n";
        # find_executable wraps a .ps1 wrapper with `powershell.exe -File`
        # on Windows since CreateProcess can't run PowerShell scripts.
        my $argv = find_executable('claude-sandbox');
        { exec @$argv, '--resume-session', $sid, $proj }
        die "exec claude-sandbox failed (tried: @$argv): $!\n";
    }
    else {
        tui_exit();
        print STDERR "claude-beacon: unknown beacon scope '$scope' on record $sid\n";
        exit 1;
    }
}

# --- Unbeacon from inside the TUI ----------------------------------------
sub remove_beacon {
    my $sid = shift;
    my ($out, $rc) = run_capture($^X, $BEACON_PL, 'unbeacon', '--session-id', $sid);
    # 0 = removed; 2 = not_found (already gone); other = error.
    if ($rc != 0 && $rc != 2) {
        return (0, $out || "unbeacon exited $rc");
    }
    return (1, '');
}

# --- Non-TTY fallback ----------------------------------------------------
sub run_non_tty {
    my $beacons = shift;
    if (!@$beacons) {
        print "No beacons found.\n";
        exit 0;
    }
    my $dot = glyph_text('sep.dot', '-');
    print "Beacons (" . scalar(@$beacons) . "):\n";
    for my $i (0 .. $#$beacons) {
        my $b = $beacons->[$i];
        my $slug    = sanitize_display($b->{project_slug});
        my $label   = sanitize_display($b->{label});
        my $summary = sanitize_display($b->{summary});
        my $desc    = length($label)   ? $label
                    : length($summary) ? $summary
                    : '(unlabeled)';
        my $scope   = ($b->{scope} // 'host') eq 'sandbox' ? 'sandbox' : 'host';
        my $ago     = relative_time($b->{last_active_at});
        printf "  %2d) [%s] %s%s%s   (%s)\n",
            $i + 1, $scope,
            (length($slug) ? "$slug " : ''),
            (length($slug) ? "$dot " : ''),
            $desc, $ago;
    }
    print "Select [1-" . scalar(@$beacons) . "] or q to quit: ";
    my $line = <STDIN>;
    return 0 unless defined $line;
    chomp $line;
    return 0 if $line =~ /^q$/i || $line eq '';
    unless ($line =~ /^\d+$/ && $line >= 1 && $line <= scalar(@$beacons)) {
        print STDERR "Invalid selection.\n";
        exit 1;
    }
    dispatch($beacons->[$line - 1]);
}

# --- TUI main loop -------------------------------------------------------
# The frame is painted row-positioned rather than as a stream of newline-
# terminated lines: writing a full-width row followed by a newline is what
# makes a terminal scroll. The full clear only happens on the first paint and
# on a resize.
sub run_tui {
    my $beacons = shift;
    my %state = (cursor => 0, status => undef, status_role => undef);
    my $cap = terminal_capability();

    tui_enter();
    my ($prev_cols, $prev_rows) = (0, 0);

    while (1) {
        if (!@$beacons) {
            tui_exit();
            print "No beacons found.\n";
            return 0;
        }
        $state{cursor} = 0          if $state{cursor} < 0;
        $state{cursor} = $#$beacons if $state{cursor} > $#$beacons;

        my ($cols, $rows) = term_size();
        if ($cols != $prev_cols || $rows != $prev_rows) {
            print "\e[H\e[J";   # cursor home + clear (cursor/erase, not SGR)
            ($prev_cols, $prev_rows) = ($cols, $rows);
        }

        my $lines = frame_lines($beacons, \%state, $rows, $cols, $cap);
        for my $i (0 .. $#$lines) {
            print "\e[" . ($i + 1) . ";1H";
            print $lines->[$i];
            print "\e[K";
        }
        print "\e[" . $rows . ";1H";   # park on the reserved row

        $state{status}      = undef;
        $state{status_role} = undef;

        my $key = tui_read_key();
        last unless defined $key;  # EOF -> exit cleanly

        if ($key eq 'UP')                     { $state{cursor}-- if $state{cursor} > 0 }
        elsif ($key eq 'DOWN')                { $state{cursor}++ if $state{cursor} < $#$beacons }
        elsif ($key eq 'HOME' || $key eq 'g') { $state{cursor} = 0 }
        elsif ($key eq 'END'  || $key eq 'G') { $state{cursor} = $#$beacons }
        elsif ($key eq 'ENTER')               {
            dispatch($beacons->[ $state{cursor} ]);
            return 0;  # unreachable; dispatch execs
        }
        elsif ($key eq 'q' || $key eq 'ESC')  { last }
        elsif ($key eq 'r') {
            $beacons = gather($no_sync);
            $state{cursor} = 0 if $state{cursor} > $#$beacons;
            if (defined $SYNC_NOTE) {
                $state{status}      = $SYNC_NOTE;
                $state{status_role} = 'state.warn';
            } else {
                $state{status}      = 'Refreshed.';
                $state{status_role} = 'text.muted';
            }
        }
        elsif ($key eq 'u') {
            my $b   = $beacons->[ $state{cursor} ];
            my $sid = $b->{session_id};
            # The same hard guarantee `dispatch` already takes, one call away.
            # A vault record missing session_id would otherwise reach
            # substr(undef, 0, 8) and an undef argv element, and the resulting
            # uninitialized-value warnings print INTO the frame -- the exact
            # debris the sync note above was just routed away from. There is no
            # false-success risk downstream (beacon.pl's require_sid exits 1 and
            # remove_beacon treats only 0 and 2 as success), so this buys a
            # clear refusal rather than a correctness fix.
            if (!valid_session_id($sid)) {
                $state{status}      = 'Cannot unbeacon: record carries no valid session id.';
                $state{status_role} = 'state.crit';
            }
            else {
                my $slug  = sanitize_display($b->{project_slug}) || 'beacon';
                my $short = substr($sid, 0, 8);
                my $ans   = inline_confirm("Unbeacon $slug ($short...)? [y/N] ");
                if ($ans eq 'y') {
                    my ($ok, $err) = remove_beacon($sid);
                    if ($ok) {
                        splice(@$beacons, $state{cursor}, 1);
                        $state{cursor} = $#$beacons if $state{cursor} > $#$beacons;
                        $state{status} = 'Removed.';
                        $state{status_role} = 'text.muted';
                    } else {
                        $state{status} = "Unbeacon failed: $err";
                        $state{status_role} = 'state.crit';
                    }
                } else {
                    $state{status} = 'Kept.';
                    $state{status_role} = 'text.muted';
                }
            }
        }
        # ignore everything else
    }

    tui_exit();
    print "\n";
    return 0;
}

# --- Main ----------------------------------------------------------------
# Every statement that ACTS lives in here, so the file can be required
# in-process by its oracle without parsing argv, spawning beacon.pl against
# the operator's real vault, or exiting out from under the harness.
sub main {
    die "Cannot determine home directory\n" unless $home_ok;

    for (my $i = 0; $i < @ARGV; $i++) {
        my $a = $ARGV[$i];
        if ($a eq '--no-sync') { $no_sync = 1; next }
        if ($a eq '-h' || $a eq '--help') {
            print <<'EOH';
Usage: claude-beacon [--no-sync]

Pick a beaconed Claude Code session from the vault and resume it.
With no flags, runs an interactive TUI selector; on a non-TTY it falls back
to a numbered prompt.

Keys (TTY mode):
  up/down, g/G, home/end   navigate
  enter                    resume (cd + claude --resume, or claude-sandbox)
  u                        unbeacon the highlighted row (asks y/N)
  r                        refresh (re-runs sync-vault, reloads list)
  q or esc                 quit
EOH
            exit 0;
        }
        print STDERR "claude-beacon: unknown argument: $a\n";
        print STDERR "Try `claude-beacon --help`.\n";
        exit 1;
    }

    # Sanity-check beacon.pl exists; the plugin tree may be incomplete on a
    # half-installed setup. Surface a friendly error instead of letting open3
    # fail with cryptic errno.
    unless (-f $BEACON_PL) {
        print STDERR "claude-beacon: cannot find beacon.pl at $BEACON_PL\n";
        print STDERR "Is the `beacon` plugin installed? Check ~/.claude/settings.json enabledPlugins.\n";
        exit 1;
    }

    my $beacons = gather($no_sync);

    if (! -t STDIN || ! -t STDOUT) {
        run_non_tty($beacons);
        exit 0;
    }

    if (!@$beacons) {
        print "No beacons found.\n";
        exit 0;
    }

    run_tui($beacons);
    exit 0;
}

main() unless caller;
1;
