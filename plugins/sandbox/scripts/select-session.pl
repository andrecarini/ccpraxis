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
{
    my @argv = @ARGV;
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
}

if (!length $SESSIONS_DIR) {
    print STDERR "select-session.pl: --sessions-dir is required\n";
    exit 1;
}
if (!length $OUTPUT_FILE) {
    print STDERR "select-session.pl: --output is required\n";
    exit 1;
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
            cwd     => $info->{cwd}     // '',
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
    $s =~ s/\\n/ /g;
    $s =~ s/\\t/ /g;
    $s =~ s/\\r//g;
    $s =~ s/\\"/"/g;
    $s =~ s/\\\\/\\/g;
    return $s;
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
        my $prev  = length $s->{preview} ? $s->{preview} : '(no preview)';
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

# Full TUI: arrow-key navigation, redraw in place, restore cursor + readmode
# on every exit path. Mirrors the pattern in skills.pl so the visual style
# matches the rest of the launcher.
sub run_tui {
    my @opts = @_;
    my $sel  = 0;
    my $have_readkey = eval { require Term::ReadKey; 1 };
    if (!$have_readkey || !-t STDIN || !-t STDERR) {
        return run_line_prompt(@opts);
    }

    my $printed_lines = 0;
    my $cleanup = sub {
        print STDERR "\e[?25h";    # show cursor
        print STDERR "\e[0m";       # reset attrs
        eval { Term::ReadKey::ReadMode(0) };
    };
    local $SIG{INT}  = sub { $cleanup->(); exit 130 };
    local $SIG{TERM} = sub { $cleanup->(); exit 143 };

    Term::ReadKey::ReadMode(4);
    print STDERR "\e[?25l";

    my $render = sub {
        if ($printed_lines) {
            print STDERR "\e[${printed_lines}A";
            print STDERR "\e[J";
        }
        my $out = "";
        $out .= "\n";
        $out .= "\e[1mResume a session" .
                (length $PROJECT_LABEL ? " - $PROJECT_LABEL" : "") .
                "\e[0m\n";
        $out .= "-" x 60 . "\n\n";
        for my $i (0 .. $#opts) {
            my $label = $opts[$i]{label};
            if ($i == $sel) {
                $out .= "\e[1;36m  > \e[0m" . $label . "\n";
            } else {
                $out .= "    " . $label . "\n";
            }
        }
        $out .= "\n";
        $out .= "  up/down: select   enter: confirm   q/esc: cancel\n";
        $printed_lines = () = ($out =~ /\n/g);
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
                    if ($k3 eq 'A' && $sel > 0)      { $sel--; $render->(); next }
                    if ($k3 eq 'B' && $sel < $#opts) { $sel++; $render->(); next }
                    next;
                }
            }
            $result = 'CANCEL'; last;
        }
        if ($k eq "\n" || $k eq "\r") { $result = $opts[$sel]{action}; last }
        if (lc($k) eq 'q')            { $result = 'CANCEL';            last }
        if ($k eq "\x03")             { $result = 'CANCEL';            last }
    }

    $cleanup->();
    print STDERR "\n";
    return $result;
}

# =====================================================================
# Entry point
# =====================================================================

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
