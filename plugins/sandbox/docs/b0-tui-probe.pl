#!/usr/bin/env perl
# b0-tui-probe.pl — B0 TUI viability spike (Decision #18/#19, package B0).
#
# Proves (or fails, with a fallback note) that a raw-ANSI TUI works when perl is
# driven the way the dashboard will be driven: from PowerShell into Windows
# Terminal / conhost (NOT from a Git-Bash pty — that difference is the whole
# point of this spike). It exercises: alt-screen enter/leave, 24-bit color,
# non-blocking keypress (for the shutdown hotkey), and resize reaction. It also
# reports which perl + modules are present (informs B2 dashboard + B5 keepawake).
#
# HOW TO RUN — in a REAL terminal, via PowerShell (NOT Git Bash), so the console
# is a native Windows console exactly like the launcher's. NOTE: bare `perl` is
# usually NOT on the PowerShell PATH (Git-for-Windows puts perl in usr\bin, which
# isn't on PATH — only git's cmd dir is), so invoke perl by full path:
#
#     & "C:\Program Files\Git\usr\bin\perl.exe" "C:\Users\André\.claude\ccpraxis\plugins\sandbox\docs\b0-tui-probe.pl"
#
#   (if `perl` DOES resolve in your shell, `perl <that path>` is fine too)
#
# Try it BOTH in Windows Terminal AND in a plain conhost window if you can — the
# results may differ. Keys: 'q' quit · 'c' cycle the color test · any other key
# echoes. It auto-exits after 60s so it can never wedge a terminal.
#
# Throwaway spike code: defensive, self-reporting, prints a paste-back summary on
# exit. Nothing here ships in the dashboard; it only tells us what the dashboard
# may rely on.
use strict;
use warnings;

# ----------------------------------------------------------------- capabilities
my %have;
for my $m (qw(Term::ReadKey Time::HiRes Win32::Console Win32::Console::ANSI Win32::API)) {
    $have{$m} = eval "require $m; 1" ? 1 : 0;
}
my $is_wt    = defined $ENV{WT_SESSION} && length $ENV{WT_SESSION} ? 1 : 0;
my $term     = $ENV{TERM} // '(unset)';
my $hires    = $have{'Time::HiRes'};
my $readkey  = $have{'Term::ReadKey'};

# A non-fatal microsleep that works with or without Time::HiRes.
my $msleep = $hires
    ? do { Time::HiRes->import('sleep'); sub { Time::HiRes::sleep($_[0]) } }
    : sub { select undef, undef, undef, $_[0] };  # 4-arg select fractional sleep

# Terminal size: prefer Term::ReadKey GetTerminalSize; else a static guess.
sub term_size {
    if ($readkey) {
        my @s = eval { Term::ReadKey::GetTerminalSize() };
        return ($s[0], $s[1]) if @s >= 2 && $s[0] && $s[1];
    }
    return (80, 25);  # fallback guess; resize-detection won't work in this mode
}

# ----------------------------------------------------------------- pre-flight UI
binmode STDOUT, ':raw';
$| = 1;
print "B0 TUI probe — environment\n";
printf "  perl         : %vd  (%s)\n", $^V, $^X;
printf "  os (\$^O)      : %s\n", $^O;
printf "  TERM         : %s\n", $term;
printf "  Windows Term : %s\n", ($is_wt ? "yes (WT_SESSION set)" : "no — conhost or other");
print  "  modules:\n";
printf "    %-22s %s\n", $_, ($have{$_} ? "available" : "MISSING") for sort keys %have;
print "\n";
unless ($readkey) {
    print "Term::ReadKey is MISSING — cannot do non-blocking input / size queries.\n";
    print "FALLBACK for the dashboard: bound long-poll on a blocking read, or a\n";
    print "PowerShell input shim. Recording this as the B0 input finding. Exiting.\n";
    exit 3;
}
print "Press ENTER to enter the alt-screen probe (or Ctrl-C to abort)...";
<STDIN>;

# ----------------------------------------------------------------- raw mode + alt
my $entered_alt = 0;
my $raw_on      = 0;

sub leave {
    # Always restore, in any exit path.
    print "\e[0m";
    print "\e[?25h"          if $entered_alt;   # show cursor
    print "\e[?1049l"        if $entered_alt;   # leave alt-screen
    eval { Term::ReadKey::ReadMode('restore') } if $raw_on;
    $entered_alt = 0; $raw_on = 0;
}
$SIG{INT} = $SIG{TERM} = sub { leave(); print "\n[interrupted]\n"; exit 130 };
END { leave() }

# cbreak = line-editing off, signals on; ReadKey(-1) = non-blocking poll.
my $rm_ok = eval { Term::ReadKey::ReadMode('cbreak'); 1 };
$raw_on = 1 if $rm_ok;

print "\e[?1049h";   # enter alt-screen
print "\e[?25l";     # hide cursor
$entered_alt = 1;

# ----------------------------------------------------------------- the loop
my ($cols, $rows) = term_size();
my $start         = time;
my $ticks         = 0;
my $keys_seen     = 0;
my $last_key      = '(none yet)';
my $resizes       = 0;
my $nb_ok         = 0;    # did we ever get a non-blocking poll to return cleanly?
my $color_mode    = 0;    # 0 = truecolor gradient, 1 = 256-color, 2 = basic 16

sub at { my ($r, $c, $s) = @_; "\e[${r};${c}H$s" }
sub tc { my ($r, $g, $b, $s) = @_; "\e[38;2;${r};${g};${b}m$s\e[0m" }   # 24-bit fg

while (1) {
    $ticks++;
    # --- resize detection: poll size, compare ---
    my ($c2, $r2) = term_size();
    if ($c2 != $cols || $r2 != $rows) { $resizes++; ($cols, $rows) = ($c2, $r2); }

    # --- non-blocking key poll ---
    my $k = eval { Term::ReadKey::ReadKey(-1) };   # undef if no key waiting
    $nb_ok = 1 if !$@;
    if (defined $k) {
        $keys_seen++;
        $last_key = sprintf("%s (0x%02x)", ($k =~ /[[:print:]]/ ? $k : '?'), ord $k);
        last      if $k eq 'q';
        $color_mode = ($color_mode + 1) % 3 if $k eq 'c';
    }

    # --- draw ---
    my $out = "\e[2J\e[H";   # clear + home
    $out .= at(1, 1, tc(0, 220, 255, "B0 TUI probe")
                  . "   " . tc(255, 180, 0, "alt-screen + 24-bit color + non-blocking input + resize"));
    $out .= at(3, 3, sprintf("size: %dx%d   ticks: %d   elapsed: %ds", $cols, $rows, $ticks, time - $start));
    $out .= at(4, 3, sprintf("keys seen: %d   last key: %s", $keys_seen, $last_key));
    $out .= at(5, 3, sprintf("resizes detected: %d   non-blocking poll: %s",
                             $resizes, ($nb_ok ? "WORKING" : "FAILED")));

    # color test row(s)
    if ($color_mode == 0) {
        my $bar = ""; for my $i (0 .. 47) { my $v = int(255 * $i / 47); $bar .= tc($v, 80, 255 - $v, "#"); }
        $out .= at(7, 3, "truecolor gradient: $bar");
    } elsif ($color_mode == 1) {
        my $bar = ""; for my $i (16 .. 51) { $bar .= "\e[38;5;${i}m#\e[0m"; }
        $out .= at(7, 3, "256-color ramp:    $bar");
    } else {
        my $bar = ""; for my $i (31 .. 37) { $bar .= "\e[1;${i}m#\e[0m"; }
        $out .= at(7, 3, "basic 16-color:    $bar");
    }

    $out .= at(9,  3, "Try: resize this window now — 'resizes detected' should climb.");
    $out .= at(10, 3, "Keys: [q] quit   [c] cycle color test   [any] echo");
    $out .= at(12, 3, "If the screen redraws cleanly, colors render, keys register WITHOUT");
    $out .= at(13, 3, "you pressing Enter, and resize is detected -> B0 PASS on all four.");
    print $out;

    last if (time - $start) > 60;   # hard safety auto-exit
    $msleep->(0.08);
}

# ----------------------------------------------------------------- summary
leave();
print "\n=== B0 PROBE SUMMARY (paste this into B0-tui-spike-findings.md) ===\n";
printf "perl=%vd os=%s windows_terminal=%s\n", $^V, $^O, ($is_wt ? "yes" : "no");
printf "modules: %s\n", join(", ", map { "$_=" . ($have{$_} ? "yes" : "no") } sort keys %have);
printf "alt-screen entered/left : %s\n", "yes (visually confirm it restored cleanly)";
printf "raw/cbreak mode         : %s\n", ($rm_ok ? "engaged" : "FAILED (ReadMode threw)");
printf "non-blocking keypoll     : %s\n", ($nb_ok ? "working (ReadKey(-1) returned without blocking)" : "FAILED");
printf "keys registered          : %d  (last: %s)\n", $keys_seen, $last_key;
printf "resize detected          : %d time(s)  -> %s\n", $resizes,
        ($resizes > 0 ? "GetTerminalSize tracks resize" : "NOT observed (try resizing while it runs; if still 0, size-poll resize doesn't work here)");
printf "color: confirm visually  : truecolor gradient + 256 + 16 all rendered? (y/n you decide)\n";
print  "implication for B5: Win32::API ", ($have{'Win32::API'} ? "IS" : "is NOT"),
       " available in this perl -> keep-awake ", ($have{'Win32::API'} ? "may use in-process SetThreadExecutionState" : "needs a PowerShell helper holding the wake-lock, not in-process Win32::API"), ".\n";
print  "==================================================================\n";
