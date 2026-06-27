#!/usr/bin/env perl
# select-session.pl — TUI session picker for the claude-sandbox launcher.
#
# `claude --continue` resumes the most recent session silently; `claude
# --resume` shows a picker with no "start new" option. Neither works for the
# launcher: a fresh sandbox needs the start-new fallback, an existing one
# needs both. This script gives the user one menu that always includes "new"
# and lists every persisted session ordered most-recent-first, then prints
# the chosen action so the launcher can exec the right claude invocation.
#
# Usage:
#   select-session.pl --sessions-dir <path> --output <file> [--project-label <name>]
#
# Writes one line to --output:
#   NEW                   — start a fresh session
#   RESUME <uuid>         — resume the session with this UUID
#
# Exit codes:
#   0   chose NEW or RESUME (written to --output)
#   2   cancelled (Esc / q / Ctrl-C) — --output is removed/empty
#   1   usage error or unreadable inputs
#
# Why an output file instead of stdout: the launcher invokes this via
# system() (not backticks) so stdin/stdout/stderr stay attached to the
# user's TTY — required for cbreak input + cursor-positioned redraws.
# Writing the decision to a file is the clean way to return data without
# fighting the terminal.

use strict;
use warnings;
use File::Basename qw(basename);
use POSIX qw(strftime);

binmode STDOUT, ':raw';
binmode STDERR, ':raw';

my $WINDOWS_FAMILY = $^O =~ /^(MSWin32|cygwin|msys)$/;

# =====================================================================
# Args
# =====================================================================

my $SESSIONS_DIR  = '';
my $PROJECT_LABEL = '';
my $OUTPUT_FILE   = '';

# Parse @ARGV into the three globals above. Split out from the entry point so
# the `unless (caller)` guard at the bottom can run it only when the script is
# executed directly (not when a test `require`s it to exercise the helpers).
sub parse_args {
    my @argv = @_;
    while (@argv) {
        my $a = shift @argv;
        if ($a eq '--sessions-dir' && @argv) {
            $SESSIONS_DIR = shift @argv;
        } elsif ($a =~ /^--sessions-dir=(.*)$/) {
            $SESSIONS_DIR = $1;
        } elsif ($a eq '--project-label' && @argv) {
            $PROJECT_LABEL = shift @argv;
        } elsif ($a =~ /^--project-label=(.*)$/) {
            $PROJECT_LABEL = $1;
        } elsif ($a eq '--output' && @argv) {
            $OUTPUT_FILE = shift @argv;
        } elsif ($a =~ /^--output=(.*)$/) {
            $OUTPUT_FILE = $1;
        } else {
            print STDERR "select-session.pl: unknown arg: $a\n";
            exit 1;
        }
    }
    if (!length $SESSIONS_DIR) {
        print STDERR "select-session.pl: --sessions-dir is required\n";
        exit 1;
    }
    if (!length $OUTPUT_FILE) {
        print STDERR "select-session.pl: --output is required\n";
        exit 1;
    }
    # The project label is rendered into the TUI title and the line-prompt
    # header; strip any terminal-control bytes at this input seam so a crafted
    # label can't beep/overwrite/spoof the menu (the TUI path is also guarded
    # by clip_visible, but the line-prompt header prints it raw).
    $PROJECT_LABEL = sanitize_cell($PROJECT_LABEL);
}

sub write_action {
    my $action = shift;
    open my $fh, '>:raw', $OUTPUT_FILE or do {
        print STDERR "select-session.pl: cannot write --output $OUTPUT_FILE: $!\n";
        exit 1;
    };
    print $fh $action, "\n";
    close $fh;
}

# =====================================================================
# Scan + parse sessions
# =====================================================================
#
# Each Claude Code session is one *.jsonl file directly under the project's
# encoded-cwd directory. We extract a UUID (filename or first JSON line),
# mtime (most-recent-activity), and a short preview taken from the first
# user message that isn't isMeta:true (which would surface a caveat banner
# instead of the user's real first prompt).

sub list_sessions {
    return () unless -d $SESSIONS_DIR;
    opendir(my $dh, $SESSIONS_DIR) or return ();
    my @files = grep { /\.jsonl$/i } readdir $dh;
    closedir $dh;

    my @sessions;
    for my $f (@files) {
        my $path = "$SESSIONS_DIR/$f";
        next unless -f $path;
        my @st = stat($path);
        next unless @st;
        my $mtime = $st[9];
        my $size  = $st[7];
        my $info  = parse_session_head($path);
        my ($uuid) = $f =~ /^([0-9a-fA-F-]+)\.jsonl$/;
        $uuid = $info->{session_id} unless defined $uuid && length $uuid;
        next unless defined $uuid && length $uuid;
        push @sessions, {
            uuid    => $uuid,
            mtime   => $mtime,
            size    => $size,
            preview => $info->{preview} // '',
            # cwd isn't rendered today, but sanitize at the store seam so it's
            # never a latent injection vector if a future panel displays it.
            cwd     => sanitize_cell($info->{cwd} // ''),
        };
    }
    # Most recent first.
    @sessions = sort { $b->{mtime} <=> $a->{mtime} } @sessions;
    return @sessions;
}

sub parse_session_head {
    my $path = shift;
    my %out;
    my $fallback_preview;
    open my $fh, '<:raw', $path or return \%out;
    my $line_count = 0;
    while (defined(my $line = <$fh>)) {
        $line_count++;
        # Cap how far we scan: a corrupt or multi-MB session shouldn't make
        # the picker hang during enumeration. 500 lines is enough to find
        # the first prose prompt in any normal session opening.
        last if $line_count > 500;
        next unless length $line;
        if (!defined $out{session_id} && $line =~ /"sessionId"\s*:\s*"([0-9a-fA-F-]+)"/) {
            $out{session_id} = $1;
        }
        if (!defined $out{cwd} && $line =~ /"cwd"\s*:\s*"([^"]+)"/) {
            $out{cwd} = $1;
        }
        if (!defined $out{preview}) {
            my $is_user_msg    = $line =~ /"type"\s*:\s*"user"/;
            my $is_meta        = $line =~ /"isMeta"\s*:\s*true/;
            # tool_result user messages carry the tool's stdout as
            # "content": [...] — their first "text":"..." field is the
            # tool output, not anything the user typed. Skip them.
            my $is_tool_result = $line =~ /"type"\s*:\s*"tool_result"/;
            if ($is_user_msg && !$is_meta && !$is_tool_result) {
                my $content = extract_user_content($line);
                if (defined $content && length $content) {
                    # Skip system-injected boilerplate: <local-command-*>
                    # tags wrap a caveat (every session) or slash-command
                    # stdout — neither is the user's actual prompt.
                    next if $content =~ /^<local-command-/;
                    # Strip <command-message>/<command-args>/<command-stdout>
                    # bodies entirely — their contents duplicate what's in
                    # <command-name> and would render as noise like
                    # "manage-plans /manage-plans". Keep <command-name>
                    # bodies (just strip the tags) so slash-command sessions
                    # show as "/manage-plans".
                    $content =~ s{<command-(?:message|args|stdout)>.*?</command-(?:message|args|stdout)>}{ }gs;
                    $content =~ s{</?command-name>}{ }g;
                    $content =~ s/\s+/ /g;
                    $content =~ s/^\s+|\s+$//g;
                    next unless length $content;
                    # Hold the first non-meta message as a fallback in case
                    # we never find prose — but keep scanning for something
                    # more informative than a bare slash-command invocation.
                    $fallback_preview //= substr($content, 0, 100);
                    next if $content =~ m{^/[a-zA-Z]};
                    $out{preview} = substr($content, 0, 100);
                }
            }
        }
        last if defined $out{session_id} && defined $out{cwd} && defined $out{preview};
    }
    close $fh;
    $out{preview} //= $fallback_preview;
    return \%out;
}

# Extract the user message's text content from a JSONL line without a full
# decoder. content can be a string ("...") or an array of typed blocks. We
# match the string form (most common for user input) and fall back to
# pulling the first {"type":"text","text":"..."} block.
sub extract_user_content {
    my $line = shift;
    if ($line =~ /"content"\s*:\s*"((?:[^"\\]|\\.)*)"/) {
        return json_unescape($1);
    }
    if ($line =~ /"text"\s*:\s*"((?:[^"\\]|\\.)*)"/) {
        return json_unescape($1);
    }
    return undef;
}

sub json_unescape {
    my $s = shift;
    # Decode \uXXXX (BMP) to UTF-8 bytes first, so real text renders instead of
    # literal backslash-u noise; a JSON-encoded control character (an ESC, for
    # example) then becomes a real byte that sanitize_cell strips downstream,
    # rather than slipping through as harmless-but-ugly literal text.
    $s =~ s/\\u([0-9a-fA-F]{4})/_decode_u($1)/ge;
    $s =~ s/\\n/ /g;
    $s =~ s/\\t/ /g;
    $s =~ s/\\r//g;
    $s =~ s/\\"/"/g;
    $s =~ s/\\\\/\\/g;
    return $s;
}

# _decode_u('001b') -> the UTF-8 byte encoding of code point U+001B. BMP only;
# surrogate halves are encoded best-effort (a lone-surrogate preview is rare and
# purely cosmetic). Returns bytes so the rest of the byte-oriented pipeline is
# unaffected.
sub _decode_u {
    my $hex = shift;
    my $c = chr(hex($hex));
    utf8::encode($c);
    return $c;
}

# =====================================================================
# Time formatting (relative)
# =====================================================================

sub relative_time {
    my $t = shift;
    my $delta = time - $t;
    return 'just now'           if $delta < 60;
    return int($delta/60) . 'm ago'   if $delta < 3600;
    return int($delta/3600) . 'h ago' if $delta < 86400;
    my $d = int($delta/86400);
    return "${d}d ago"                if $d < 30;
    my $mo = int($d/30);
    return "${mo}mo ago"              if $mo < 12;
    my $y = int($d/365);
    return "${y}y ago";
}

# =====================================================================
# Render + read loop
# =====================================================================
#
# `options` is an arrayref of hashrefs:
#   { label => '...', action => 'NEW'|'RESUME' UUID|'CANCEL' }
# The first option is always "Start a new session"; the rest are the
# parsed sessions in most-recent-first order.

sub build_options {
    my @sessions = @_;
    my @opts;
    push @opts, {
        label  => "\e[1;36m+ Start a new session\e[0m",
        action => 'NEW',
    };
    for my $s (@sessions) {
        my $when  = strftime('%Y-%m-%d %H:%M', localtime($s->{mtime}));
        my $rel   = relative_time($s->{mtime});
        # The preview is attacker-influenceable (it comes from arbitrary
        # user/tool text in the session file), so strip terminal-control
        # bytes before it reaches the screen — an embedded ESC could move the
        # cursor, recolor the menu, or spoof which option looks selected.
        my $prev  = sanitize_cell($s->{preview});
        $prev = '(no preview)' unless length $prev;
        # Single line: timestamp · relative · short uuid · preview.
        my $short_uuid = substr($s->{uuid}, 0, 8);
        my $label = sprintf("%s  (%s)  %s  %s", $when, $rel, $short_uuid, $prev);
        push @opts, {
            label  => $label,
            action => "RESUME $s->{uuid}",
        };
    }
    return @opts;
}

# Non-TUI fallback path — prints a numbered list and reads a single line.
# Used when stdin/stdout aren't TTYs or Term::ReadKey can't be loaded.
sub run_line_prompt {
    my @opts = @_;
    print STDERR "\n";
    print STDERR "Sessions for $PROJECT_LABEL:\n" if length $PROJECT_LABEL;
    print STDERR "Sessions:\n" unless length $PROJECT_LABEL;
    print STDERR "\n";
    for my $i (0 .. $#opts) {
        print STDERR sprintf("  [%d] %s\n", $i + 1, strip_ansi($opts[$i]{label}));
    }
    print STDERR "\n";
    print STDERR "Enter choice [1-" . scalar(@opts) . ", default 1, q to cancel]: ";
    my $line = <STDIN>;
    $line //= '';
    chomp $line;
    if ($line =~ /^q/i) { return undef }
    my $n = $line =~ /^(\d+)$/ ? $1 : 1;
    if ($n < 1 || $n > scalar(@opts)) {
        print STDERR "Out of range; using 1.\n";
        $n = 1;
    }
    return $opts[$n - 1]{action};
}

sub strip_ansi {
    my $s = shift;
    $s =~ s/\e\[[0-9;]*[A-Za-z]//g;
    return $s;
}

# sanitize_cell($s) -> $s with terminal-control bytes removed (C0 controls +
# ESC, 0x00-0x1F, and DEL 0x7F). Session previews are attacker-influenceable
# (arbitrary user/tool text), and this picker renders them; an unsanitized
# preview could emit escape sequences that move the cursor, recolor the menu,
# or spoof which option is highlighted. Printable multi-byte UTF-8 is kept as
# raw bytes (its width is handled conservatively by clip_visible).
sub sanitize_cell {
    my ($s) = @_;
    return '' if !defined $s;
    $s =~ s/[\x00-\x1F\x7F]//g;
    return $s;
}

# clip_visible($s, $width) -> $s truncated to at most $width visible columns.
# This is also the render's display-seam control-character guard: our own SGR
# color escapes (\e[...m) are preserved (zero columns), every other escape /
# CSI sequence is dropped, and ALL C0 control bytes + DEL (0x00-0x1F, 0x7F) are
# stripped — so even an un-sanitized source (e.g. $PROJECT_LABEL) can't smuggle
# a BEL/CR/cursor-move to the terminal. A trailing \e[0m is always appended so
# color never bleeds past the row end. Visible width is counted in BYTES, so a
# multi-byte UTF-8 char counts as >1: truncation is *conservative* (may stop a
# hair early) and a row can never WRAP — the invariant the bounded-height frame
# relies on, since a wrapped logical row would occupy two physical rows and
# desync the redraw.
sub clip_visible {
    my ($s, $width) = @_;
    $s = '' if !defined $s;
    $width = 0 if !defined $width || $width < 0;
    my $out  = '';
    my $cols = 0;
    while (length $s) {
        if ($s =~ s/^(\e\[[0-9;]*m)//)        { $out .= $1; next; }  # SGR: keep, 0 width
        if ($s =~ s/^\e\[[0-9;]*[A-Za-z]//)   { next; }             # other CSI: drop
        if ($s =~ s/^[\x00-\x1F\x7F]//)       { next; }             # C0/ESC/DEL: drop, 0 width
        last if $cols >= $width;
        $out .= substr($s, 0, 1, '');
        $cols++;
    }
    return $out . "\e[0m";
}

# plan_frame($rows, $n) -> { head, foot, cap, hints } : the row budget for one
# rendered frame given a terminal of $rows rows and $n options. Pure (no I/O)
# so the "frame never exceeds the screen" invariant is unit-tested at every
# size. Guarantees head + foot + (hints ? 2 : 0) + cap <= max($rows,1) and
# cap >= 1, so the frame can never overflow and reintroduce scrolling — even on
# a tiny terminal, where decorative chrome (rule, spacers, hints) is dropped
# in priority order until the option window fits.
#   head: number of header rows (3 = title+rule+blank, 1 = title, 0 = none)
#   foot: number of footer rows (2 = blank+keys, 1 = short keys, 0 = none)
#   cap : visible option rows
#   hints: 1 if 2 rows are reserved for the (N more above/below) hints
sub plan_frame {
    my ($rows, $n) = @_;
    $rows = 1 if !defined $rows || $rows < 1;
    $n    = 0 if !defined $n    || $n < 0;
    my $decor = $rows >= 8 ? 1 : 0;     # full chrome only on a normal-size terminal
    my $head  = $decor ? 3 : 1;
    my $foot  = $decor ? 2 : 1;
    if ($head + $foot >= $rows) { $head = 0; $foot = 0; }   # no room for chrome at all
    my $body  = $rows - $head - $foot;
    $body = 1 if $body < 1;
    my $overflow = ($n > $body) ? 1 : 0;
    my $hints = ($overflow && $body >= 3) ? 1 : 0;          # reserve 2 only if it still leaves 1 option
    my $cap   = $body - ($hints ? 2 : 0);
    $cap = 1 if $cap < 1;
    return { head => $head, foot => $foot, cap => $cap, hints => $hints };
}

# scroll_window($top, $sel, $cap, $n) -> the new viewport top index such that
# the selection $sel stays inside the visible window [top, top+cap-1], scrolling
# the minimum distance and clamping to valid bounds. Pure (no I/O) so the
# scrolling behavior is unit-tested without a TTY. $cap = visible option rows,
# $n = total options.
sub scroll_window {
    my ($top, $sel, $cap, $n) = @_;
    $cap = 1 if !defined $cap || $cap < 1;
    $n   = 0 if !defined $n   || $n < 0;
    $top = 0 if !defined $top || $top < 0;
    $sel = 0 if !defined $sel || $sel < 0;
    $sel = $n - 1 if $n > 0 && $sel > $n - 1;
    $top = $sel                 if $sel < $top;                  # selection above window
    $top = $sel - $cap + 1      if $sel > $top + $cap - 1;       # selection below window
    my $max_top = $n - $cap;
    $max_top = 0 if $max_top < 0;
    $top = $max_top if $top > $max_top;                          # never scroll past the end
    $top = 0 if $top < 0;
    return $top;
}

# Full TUI: a windowed, scrolling, arrow-key picker drawn on the ALTERNATE
# screen buffer. Using the alt-screen (\e[?1049h) means nothing the picker
# draws is committed to the terminal scrollback — on exit the user's original
# screen is restored verbatim. This replaces the old in-place "\e[NA" redraw,
# which scrolled the viewport once the list outgrew the screen and dumped a
# fresh copy of the whole menu into scrollback on every keypress. Only a
# screen-sized window of options is rendered; the selection scrolls the window
# (with "(N more above/below)" hints), and every row is clipped to the terminal
# width so nothing wraps. Restores the cursor + readmode + main screen on every
# exit path.
sub run_tui {
    my @opts = @_;
    my $sel  = 0;      # pre-select option 0 = "Start a new session"
    my $top  = 0;      # index of the first option shown in the viewport
    my $page = 1;      # PageUp/Down step; recomputed from the live window size

    my $have_readkey = eval { require Term::ReadKey; 1 };
    if (!$have_readkey || !-t STDIN || !-t STDERR) {
        return run_line_prompt(@opts);
    }

    my $on_alt  = 0;
    my $cleanup = sub {
        print STDERR "\e[0m";                 # reset attrs
        print STDERR "\e[?25h";               # show cursor
        print STDERR "\e[?1049l" if $on_alt;  # leave alt-screen (restore user's screen)
        $on_alt = 0;
        eval { Term::ReadKey::ReadMode(0) };
    };
    local $SIG{INT}  = sub { $cleanup->(); exit 130 };
    local $SIG{TERM} = sub { $cleanup->(); exit 143 };

    Term::ReadKey::ReadMode(4);               # cbreak
    print STDERR "\e[?1049h";                  # enter alt-screen
    $on_alt = 1;
    print STDERR "\e[?25l";                    # hide cursor

    my $term_size = sub {
        my @s = eval { Term::ReadKey::GetTerminalSize() };
        my $cols = (@s && $s[0] && $s[0] > 0) ? $s[0] : 80;
        my $rows = (@s && $s[1] && $s[1] > 0) ? $s[1] : 24;
        return ($cols, $rows);
    };

    my $render = sub {
        my ($cols, $rows) = $term_size->();
        # plan_frame guarantees the whole frame fits in $rows at any size, and
        # degrades the chrome (rule/spacers/hints) on tiny terminals so it can
        # never overflow and reintroduce scrolling.
        my $L   = plan_frame($rows, scalar @opts);
        my $cap = $L->{cap};
        $page = $cap;
        $top  = scroll_window($top, $sel, $cap, scalar @opts);
        my $last = $top + $cap - 1;
        $last = $#opts if $last > $#opts;
        my $below = $#opts - $last;

        my $row   = sub { clip_visible($_[0], $cols) . "\e[K\n" };  # clip + clear-to-EOL
        my $title = "\e[1mResume a session"
                    . (length $PROJECT_LABEL ? " - $PROJECT_LABEL" : "")
                    . "\e[0m";

        my $out = "\e[H";   # cursor home (top-left of the alt-screen)
        $out .= $row->($title)                    if $L->{head} >= 1;
        $out .= $row->("-" x 60) . $row->("")     if $L->{head} >= 3;
        $out .= $row->(sprintf("\e[2m    (%d more above)\e[0m", $top))
            if $L->{hints} && $top > 0;
        for my $i ($top .. $last) {
            my $label = $opts[$i]{label};
            $out .= $row->($i == $sel
                ? "\e[1;36m  > \e[0m" . $label
                : "    " . $label);
        }
        $out .= $row->(sprintf("\e[2m    (%d more below)\e[0m", $below))
            if $L->{hints} && $below > 0;
        if ($L->{foot} >= 2) {
            $out .= $row->("");
            $out .= $row->("  up/down: select   pgup/pgdn/home/end: jump   enter: confirm   q/esc: cancel");
        } elsif ($L->{foot} >= 1) {
            $out .= $row->("  up/down  pgup/pgdn  enter  q/esc");
        }
        $out .= "\e[J";     # wipe any rows left over from a previous taller frame
        print STDERR $out;
    };

    my $result;
    $render->();
    while (1) {
        my $k = Term::ReadKey::ReadKey(0);
        last unless defined $k;
        if ($k eq "\e") {
            my $k2 = Term::ReadKey::ReadKey(0.05);
            if (defined $k2 && ($k2 eq '[' || $k2 eq 'O')) {
                my $k3 = Term::ReadKey::ReadKey(0.05);
                if (defined $k3) {
                    if    ($k3 eq 'A') { $sel-- if $sel > 0;      $render->(); next }
                    elsif ($k3 eq 'B') { $sel++ if $sel < $#opts; $render->(); next }
                    elsif ($k3 eq 'H') { $sel = 0;                $render->(); next }  # Home
                    elsif ($k3 eq 'F') { $sel = $#opts;           $render->(); next }  # End
                    elsif ($k3 =~ /[0-9]/) {
                        # CSI numeric sequences (e.g. PageUp = \e[5~, PageDown =
                        # \e[6~); collect the digits up to the terminating '~'.
                        my $digits = $k3;
                        while (defined(my $d = Term::ReadKey::ReadKey(0.02))) {
                            last if $d !~ /[0-9;]/;
                            $digits .= $d;
                        }
                        if    ($digits eq '5') { $sel -= $page }   # PageUp
                        elsif ($digits eq '6') { $sel += $page }   # PageDown
                        $sel = 0      if $sel < 0;
                        $sel = $#opts if $sel > $#opts;
                        $render->(); next;
                    }
                    next;   # other escape: ignore
                }
            }
            $result = 'CANCEL'; last;   # lone ESC cancels
        }
        if ($k eq "\n" || $k eq "\r") { $result = $opts[$sel]{action}; last }
        if (lc($k) eq 'q')            { $result = 'CANCEL';            last }
        if ($k eq "\x03")             { $result = 'CANCEL';            last }
        # any other key: ignore, no redraw needed
    }

    $cleanup->();
    return $result;
}

# =====================================================================
# Entry point
# =====================================================================
#
# Guarded by `unless (caller)` so a test can `require` this script to unit-test
# the pure helpers (sanitize_cell / clip_visible / scroll_window / build_options)
# without the main flow running and calling exit().

unless (caller) {
    parse_args(@ARGV);

    my @sessions = list_sessions();
    my @opts     = build_options(@sessions);

    # Zero-session fast path: nothing to pick from, just emit NEW and exit.
    # Skipping the TUI here avoids a confusing one-option menu on the very
    # first launch of a fresh sandbox.
    if (@sessions == 0) {
        write_action('NEW');
        exit 0;
    }

    my $action = run_tui(@opts);
    if (!defined $action || $action eq 'CANCEL') {
        exit 2;
    }

    write_action($action);
    exit 0;
}

1;
