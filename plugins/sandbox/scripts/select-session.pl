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
#   0   chose NEW or RESUME (written to --output, or printed as "RESUME
#       <uuid>" on stdout in --fork mode)
#   2   cancelled (Esc / q / Ctrl-C) — --output is removed/empty
#   3   host-session fork failed: --fork mode could not produce a resumable
#       session (no such host session, or SessionFork::fork_session itself
#       failed), or the plain/TUI picker's own fork-before-resume path hit
#       the same failure after a HOST row was picked. Nothing is written to
#       --output/stdout on this exit. Callers use this dedicated code (never
#       plain 1) to decide whether returning to the picker makes sense.
#   1   usage error or unreadable inputs (any other failure)
#
# Why an output file instead of stdout: the launcher invokes this via
# system() (not backticks) so stdin/stdout/stderr stay attached to the
# user's TTY — required for cbreak input + cursor-positioned redraws.
# Writing the decision to a file is the clean way to return data without
# fighting the terminal.
#
# blueprint sandbox-session-ux, package 03-picker-cards: both this script's
# plain loop and the launcher dashboard's 'c' screen render SessionIndex
# results as CARDS through the one shared renderer in tui::LaunchScreens
# (session_card_lines / session_new_lines / card_window). See
# specs/03-picker-cards-spec.md.

use strict;
use warnings;
use File::Basename qw(basename dirname);
use Cwd ();
use POSIX qw(strftime);
use JSON::PP ();
use Encode ();

# Dedicated exit code for a failed host-session fork -- see the "Exit codes"
# block in the header comment above. Kept as a named constant rather than a
# bare 3 at each call site.
use constant FORK_FAILED_EXIT => 3;

binmode STDOUT, ':raw';
binmode STDERR, ':raw';

my $WINDOWS_FAMILY = $^O =~ /^(MSWin32|cygwin|msys)$/;

# =====================================================================
# @INC / tui::LaunchScreens
# =====================================================================
# The script's own directory (backslashes normalised) goes on @INC so
# `use tui::LaunchScreens` resolves the same way launcher.pl's does — that
# module brings in Theme and tui::Frame, which is everything the card
# renderer and the colour tokens need.
BEGIN {
    my $dir = File::Basename::dirname(do { (my $f = __FILE__) =~ s{\\}{/}g; Cwd::abs_path($f) // $f });
    unshift @INC, $dir unless grep { $_ eq $dir } @INC;
}
use tui::LaunchScreens ();

# =====================================================================
# Args
# =====================================================================

my $SESSIONS_DIR  = '';
my $PROJECT_LABEL = '';
my $OUTPUT_FILE   = '';
my $BLUEPRINTS_DIR     = '';
my $BLUEPRINTS_DIR_SET = 0;   # 1 iff --blueprints-dir was supplied (even if empty)
my $LIST_JSON          = 0;   # 08-launcher-screens: data mode, no terminal at all
my $HOST_SESSIONS_DIR     = '';
my $HOST_SESSIONS_DIR_SET = 0;   # 1 iff --host-sessions-dir was supplied -- "origin mode" (07)
my $FORK_UUID             = '';
my $FORK_UUID_SET         = 0;   # 1 iff --fork was supplied -- non-interactive fork mode (07)

# Parse @ARGV into the globals above. Split out from the entry point so
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
        } elsif ($a eq '--blueprints-dir' && @argv) {
            $BLUEPRINTS_DIR = shift @argv; $BLUEPRINTS_DIR_SET = 1;
        } elsif ($a =~ /^--blueprints-dir=(.*)$/) {
            $BLUEPRINTS_DIR = $1;         $BLUEPRINTS_DIR_SET = 1;
        } elsif ($a eq '--list-json') {
            $LIST_JSON = 1;
        } elsif ($a eq '--host-sessions-dir' && @argv) {
            $HOST_SESSIONS_DIR = shift @argv; $HOST_SESSIONS_DIR_SET = 1;
        } elsif ($a =~ /^--host-sessions-dir=(.*)$/) {
            $HOST_SESSIONS_DIR = $1;         $HOST_SESSIONS_DIR_SET = 1;
        } elsif ($a eq '--fork' && @argv) {
            $FORK_UUID = shift @argv; $FORK_UUID_SET = 1;
        } elsif ($a =~ /^--fork=(.*)$/) {
            $FORK_UUID = $1;         $FORK_UUID_SET = 1;
        } else {
            print STDERR "select-session.pl: unknown arg: $a\n";
            exit 1;
        }
    }
    if (!length $SESSIONS_DIR) {
        print STDERR "select-session.pl: --sessions-dir is required\n";
        exit 1;
    }
    # --fork is a non-interactive mode: requires --sessions-dir and
    # --host-sessions-dir, never --output, and cannot be combined with
    # --list-json (usage error).
    if ($FORK_UUID_SET) {
        if ($LIST_JSON) {
            print STDERR "select-session.pl: --fork cannot be combined with --list-json\n";
            exit 1;
        }
        if (!$HOST_SESSIONS_DIR_SET || !length $HOST_SESSIONS_DIR) {
            print STDERR "select-session.pl: --fork requires --host-sessions-dir\n";
            exit 1;
        }
    }
    # --list-json is a DATA mode: it prints the session list and touches no
    # terminal and no --output file, so that flag is not required for it.
    if (!length $OUTPUT_FILE && !$LIST_JSON && !$FORK_UUID_SET) {
        print STDERR "select-session.pl: --output is required\n";
        exit 1;
    }
    # The project label is rendered into the TUI title and the line-prompt
    # header; strip any terminal-control bytes at this input seam so a crafted
    # label can't beep/overwrite/spoof the menu.
    $PROJECT_LABEL = sanitize_cell($PROJECT_LABEL);

    # --blueprints-dir is OPTIONAL (the s14-session-filter test/override seam,
    # Decision #3): when not supplied, derive it from --sessions-dir so
    # launcher.pl (outside this package's write set) needs no new flag.
    # Supplying it (even as '') disables derivation entirely.
    $BLUEPRINTS_DIR = derive_blueprints_dir($SESSIONS_DIR) unless $BLUEPRINTS_DIR_SET;
}

# derive_blueprints_dir($sessions_dir) -> $path_or_empty
#
# The real invocation passes
# <project>/.ccpraxis-local-data/claude-home/projects/-project, which yields
# <project>/.ccpraxis-local-data/blueprints — the exact tree launcher.pl and
# bp-lib.sh scan. Accepts / or \ as the separator (the launcher runs
# host-side, where $PROJECT_PATH may be a Windows path). Requires the
# .ccpraxis-local-data component to be a strict ancestor (a trailing
# separator must follow it). Any other shape -> ''. Never dies.
sub derive_blueprints_dir {
    my ($sd) = @_;
    return '' unless defined $sd && length $sd;
    return '' unless $sd =~ m{^(.*\.ccpraxis-local-data)[/\\]};   # greedy: last occurrence
    return "$1/blueprints";
}

# =====================================================================
# SessionFilter / SessionIndex integration
# =====================================================================

my $HAVE_SESSION_FORK;   # undef = not tried yet

# load_session_fork() -- lazy require, same idiom as load_session_index()/
# load_session_filter() below: a test that `require`s this script to unit-
# test its pure helpers never runs main() (the `unless (caller)` guard), so
# an eager `use SessionFork ()` at compile time would double-load the module
# under a second %INC key whenever the test also required SessionFork.pm
# directly by its own absolute path (harmless, but noisy "subroutine
# redefined" warnings). Loading on demand, from the same dir tui::LaunchScreens
# and SessionIndex already resolve against, avoids that entirely.
sub load_session_fork {
    return $HAVE_SESSION_FORK if defined $HAVE_SESSION_FORK;
    my $dir = File::Basename::dirname(do { (my $f = __FILE__) =~ s{\\}{/}g; Cwd::abs_path($f) // $f });
    $HAVE_SESSION_FORK = eval { require "$dir/SessionFork.pm"; 1 } ? 1 : 0;
    return $HAVE_SESSION_FORK;
}

my $HAVE_SESSION_FILTER;   # undef = not tried yet

sub load_session_filter {
    return $HAVE_SESSION_FILTER if defined $HAVE_SESSION_FILTER;
    my $dir = File::Basename::dirname(do { (my $f = __FILE__) =~ s{\\}{/}g; Cwd::abs_path($f) // $f });
    $HAVE_SESSION_FILTER = eval { require "$dir/SessionFilter.pm"; 1 } ? 1 : 0;
    return $HAVE_SESSION_FILTER;
}

# butler_sids() -> \%sids ({} when the module or the root is unavailable).
sub butler_sids {
    return {} unless length $BLUEPRINTS_DIR;
    return {} unless load_session_filter();
    my $s = eval { SessionFilter::collect_butler_sids($BLUEPRINTS_DIR) };
    return (ref $s eq 'HASH') ? $s : {};
}

my $HAVE_SESSION_INDEX;   # undef = not tried yet
my $SESSION_INDEX_ERR = '';

sub load_session_index {
    return $HAVE_SESSION_INDEX if defined $HAVE_SESSION_INDEX;
    my $dir = File::Basename::dirname(do { (my $f = __FILE__) =~ s{\\}{/}g; Cwd::abs_path($f) // $f });
    $HAVE_SESSION_INDEX = eval { require "$dir/SessionIndex.pm"; 1 } ? 1 : 0;
    $SESSION_INDEX_ERR = $@ unless $HAVE_SESSION_INDEX;
    return $HAVE_SESSION_INDEX;
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
# Scan sessions (SessionIndex-backed — package 02)
# =====================================================================

# list_sessions($dir) -> @sessions. Each element:
#   { uuid, mtime, kind, started_at, last_active_at, first_typed, last_typed,
#     same_message }
#
# Listing goes straight through SessionIndex::index_dir() -- package 02's
# one index -- rather than a second directory scan here. Entries the index
# marks `empty` (Decision 4: no typed message at all) are dropped by this
# consumer and never reach any view; index_dir() itself still returns them
# (its own contract leaves that filtering to callers). Order otherwise
# matches index_dir()'s own (last_active_at desc, id asc) unchanged.
sub list_sessions {
    my ($dir) = @_;
    $dir = $SESSIONS_DIR unless defined $dir;
    return () unless load_session_index();
    my $entries = eval { SessionIndex::index_dir($dir) };
    return () unless ref $entries eq 'ARRAY';

    my @out;
    for my $e (@$entries) {
        next unless ref $e eq 'HASH';
        next if $e->{empty};
        next unless defined $e->{id};
        push @out, {
            uuid           => $e->{id},
            path           => $e->{path},
            mtime          => $e->{mtime},
            kind           => $e->{kind},
            started_at     => $e->{started_at},
            last_active_at => $e->{last_active_at},
            first_typed    => $e->{first_typed},
            last_typed     => $e->{last_typed},
            same_message   => $e->{same_message},
        };
    }
    return @out;
}

# origin_sessions($dir, $forced_origin) -> @sessions -- list_sessions($dir),
# each row tagged with an `origin`. When $forced_origin is given (host
# rows), every row gets that origin. Otherwise (sandbox rows) a row is
# `fork` (+ `source_session_id`) when SessionFork::read_provenance finds a
# sidecar, else `sandbox`.
#
# red-team S1 (MUST-FIX, promoted by Decision 34): a listed row's `id` is
# SessionIndex's filename stem ONLY when the stem is uuid-shaped -- when it
# is not, index_file() falls back to the first record's `sessionId`, which
# for a file the CONTAINER wrote (any file under the sandbox sessions dir)
# is content the container controls. A crafted `"sessionId":"host:<real
# host uuid>"` would otherwise be listed as an id identical in shape to a
# genuine host row's item id, and picking it forks the named HOST session.
# Closed two ways, both applied here:
#   - every row whose id is not uuid_shaped is dropped outright (closes the
#     sandbox-row spoof: "host:<uuid>" is never uuid-shaped);
#   - a HOST row's id must equal ITS OWN file's stem -- never a
#     content-derived id -- so host-ness/identity for a host row never
#     comes from anything the container wrote.
sub origin_sessions {
    my ($dir, $forced_origin) = @_;
    my @candidates = list_sessions($dir);
    my $is_host = defined($forced_origin) && $forced_origin eq 'host';
    my @out;
    for my $s (@candidates) {
        next unless load_session_fork() && SessionFork::is_uuid_shaped($s->{uuid});
        if ($is_host) {
            my $stem = defined($s->{path}) ? $s->{path} : '';
            $stem =~ s{.*[/\\]}{};
            $stem =~ s/\.jsonl\z//i;
            next unless length($stem) && lc($stem) eq lc($s->{uuid});
        }
        push @out, $s;
    }
    for my $s (@out) {
        if (defined $forced_origin) {
            $s->{origin} = $forced_origin;
            next;
        }
        my $prov = eval { SessionFork::read_provenance($dir, $s->{uuid}) };
        if (ref $prov eq 'HASH') {
            $s->{origin}            = 'fork';
            $s->{source_session_id} = $prov->{source_session_id};
        } else {
            $s->{origin} = 'sandbox';
        }
    }
    return @out;
}

# merged_sessions() -> @sessions -- sandbox rows (list_sessions($SESSIONS_DIR),
# origin-tagged sandbox/fork) plus, in origin mode, host rows from
# $HOST_SESSIONS_DIR (origin host). Sort: last_active_at desc, then uuid
# asc, then origin (sandbox < fork < host) as the final tie-break.
sub merged_sessions {
    my @sessions = origin_sessions($SESSIONS_DIR);
    if ($HOST_SESSIONS_DIR_SET && length $HOST_SESSIONS_DIR) {
        push @sessions, origin_sessions($HOST_SESSIONS_DIR, 'host');
    }
    my %rank = (sandbox => 0, fork => 1, host => 2);
    @sessions = sort {
        (defined($b->{last_active_at}) ? $b->{last_active_at} : -1)
            <=> (defined($a->{last_active_at}) ? $a->{last_active_at} : -1)
            or $a->{uuid} cmp $b->{uuid}
            or ($rank{$a->{origin} // ''} // 9) <=> ($rank{$b->{origin} // ''} // 9)
    } @sessions;
    return @sessions;
}

# =====================================================================
# Time formatting
# =====================================================================

sub relative_time {
    my ($t, $now) = @_;
    $now = time unless defined $now;
    my $delta = $now - $t;
    return 'just now'           if $delta < 60;
    return int($delta/60) . 'm ago'   if $delta < 3600;
    return int($delta/3600) . 'h ago' if $delta < 86400;
    my $d = int($delta/86400);
    return "${d}d ago"                if $d < 30;
    my $mo = int($d/30);
    return "${mo}mo ago"              if $mo < 12;
    my $y = int($d/365) || 1;
    return "${y}y ago";
}

sub _fmt_when {
    my ($t) = @_;
    return '-' unless defined $t && !ref $t && $t =~ /^-?\d+(?:\.\d+)?$/;
    return strftime('%Y-%m-%d %H:%M', localtime($t));
}

# card_fields(\%session, $now) -> \%card — the tui::LaunchScreens card
# contract (S2.1). Missing/malformed input never dies.
sub card_fields {
    my ($s, $now) = @_;
    $s = {} unless ref $s eq 'HASH';
    $now = time unless defined $now;

    my $started_src = defined($s->{started_at}) ? $s->{started_at} : $s->{mtime};
    my $active_src  = defined($s->{last_active_at}) ? $s->{last_active_at} : $s->{mtime};

    my $ago = '-';
    if (defined($active_src) && !ref($active_src) && $active_src =~ /^-?\d+(?:\.\d+)?$/) {
        $ago = relative_time($active_src, $now);
    }

    my $kind_label;
    if ($s->{is_butler}) {
        my $kind = defined($s->{kind}) ? $s->{kind} : 'human';
        $kind_label = $kind eq 'coordinator' ? 'coordinator'
                    : $kind eq 'headless'    ? 'headless'
                    : $kind eq 'sidechain'   ? 'subagent'
                    : $kind eq 'human'       ? 'butler'
                    :                          $kind;
    }

    return {
        started    => _fmt_when($started_src),
        active     => _fmt_when($active_src),
        ago        => $ago,
        first      => (defined($s->{first_typed}) ? $s->{first_typed} : $s->{last_typed}),
        last       => ($s->{same_message} ? undef : $s->{last_typed}),
        kind_label => $kind_label,
        badges     => origin_badges($s),
    };
}

# origin_badges(\%session) -> \@badges
#
# package 07-host-session-fork: an origin badge per S2.2's table, but ONLY
# in "origin mode" (--host-sessions-dir was supplied) -- otherwise every
# card.badges stays [] and today's output is byte-for-byte unchanged (D14,
# AC-21).
sub origin_badges {
    my ($s) = @_;
    return [] unless $HOST_SESSIONS_DIR_SET;
    return [] unless ref $s eq 'HASH';
    my $origin = $s->{origin};
    return [] unless defined $origin && !ref $origin;
    if ($origin eq 'host') {
        return [ { text => 'host', role => 'accent' } ];
    }
    if ($origin eq 'sandbox') {
        return [ { text => 'sandbox', role => 'text.muted' } ];
    }
    if ($origin eq 'fork') {
        my $sid = $s->{source_session_id};
        return [] unless defined $sid && length $sid;
        return [ { text => 'duplicated from host ' . SessionFork::short_id($sid), role => 'state.ok' } ];
    }
    return [];
}

# =====================================================================
# Options (label + card, per session)
# =====================================================================
#
# `options` is an arrayref of hashrefs:
#   { label => '...', action => 'NEW'|'RESUME' UUID, is_butler => 0|1, card => \%card }
# Option 0 is always "Start a new session" (no is_butler/card key); the rest
# are list_sessions()'s entries in order.

# _normalize_for_label($s) -> collapsed/trimmed text, control bytes removed.
# N5: delegates to tui::LaunchScreens' own message normaliser (S2.1) rather
# than duplicating its rule, so the plain line-prompt's label reads the same
# way the card's message block would and a future rule change is made once.
sub _normalize_for_label {
    my ($s) = @_;
    return '' unless defined $s && !ref $s;
    my $t = tui::LaunchScreens::_normalize_msg("$s");
    return defined($t) ? $t : '';
}

sub build_options {
    my @sessions = @_;
    my @opts;
    push @opts, {
        label  => '+ Start a new session',
        action => 'NEW',
    };
    for my $s (@sessions) {
        my $card = card_fields($s, time);
        my $msg = _normalize_for_label(
            (defined($s->{first_typed}) && length($s->{first_typed})) ? $s->{first_typed}
            : (defined($s->{last_typed}) && length($s->{last_typed})) ? $s->{last_typed}
            : undef);
        $msg = sanitize_cell($msg);
        if (length($msg) > 100) { $msg = substr($msg, 0, 100) . '...'; }
        $msg = '(no message)' unless length $msg;
        my $label_txt = sprintf('%s  (%s)  %s', $card->{active}, $card->{ago}, $msg);
        if ($HOST_SESSIONS_DIR_SET && ref($card->{badges}) eq 'ARRAY' && @{ $card->{badges} }) {
            $label_txt .= ' [' . $card->{badges}[0]{text} . ']';
        }
        my $label = eval { Encode::encode('UTF-8', $label_txt) };
        $label = $label_txt unless defined $label;
        my $action = (defined($s->{origin}) && $s->{origin} eq 'host')
            ? "HOST $s->{uuid}" : "RESUME $s->{uuid}";
        push @opts, {
            label     => $label,
            action    => $action,
            is_butler => ($s->{is_butler} ? 1 : 0),
            card      => $card,
        };
    }
    return @opts;
}

# filter_options($opts_aref, $view) -> @filtered
#
# Pure. Option 0 ("Start a new session") is always kept, in every view,
# unfiltered. $view of undef/''/anything-else is treated as 'user'.
# Returns the SAME hashrefs (no copies, no mutation of the input array
# or elements).
sub filter_options {
    my ($opts, $view) = @_;
    return () unless ref $opts eq 'ARRAY' && @$opts;
    $view = 'user' unless defined $view && $view eq 'butler';
    my @out = ($opts->[0]);                          # "Start a new session", always
    for my $i (1 .. $#$opts) {
        my $b = $opts->[$i]{is_butler} ? 1 : 0;
        push @out, $opts->[$i] if ($view eq 'butler') ? $b : !$b;
    }
    return @out;
}

# footer_text($view, $short) -> $string
sub footer_text {
    my ($view, $short) = @_;
    my $label = (defined $view && $view eq 'butler') ? 'butler' : 'user';
    my $other = $label eq 'butler' ? 'user' : 'butler';
    return "  view: $label   [t] $other   up/down  pgup/pgdn  enter  q/esc" if $short;
    return "  view: $label   [t] show $other sessions   "
         . "up/down: select   pgup/pgdn/home/end: jump   enter: confirm   q/esc: cancel";
}

# empty_view_note($view) -> $string
sub empty_view_note {
    my ($view) = @_;
    return (defined $view && $view eq 'butler')
        ? '(no butler sessions)' : '(no user sessions)';
}

# show_empty_note($n_view, $shown, $cap) -> 0|1
sub show_empty_note {
    my ($n_view, $shown, $cap) = @_;
    return 0 if !defined $n_view || !defined $shown || !defined $cap;
    return ($n_view <= 1 && $shown < $cap) ? 1 : 0;
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
# ESC, 0x00-0x1F, and DEL 0x7F). Session text is attacker-influenceable
# (arbitrary user/tool content), and this picker renders it; an unsanitized
# value could emit escape sequences that move the cursor, recolor the menu,
# or spoof which option is highlighted.
sub sanitize_cell {
    my ($s) = @_;
    return '' if !defined $s;
    $s =~ s/[\x00-\x1F\x7F]//g;
    return $s;
}

# plan_frame($rows, $n) -> { head, foot, cap, hints } : the row budget for one
# rendered frame given a terminal of $rows rows and $n options. Pure (no I/O)
# so the "frame never exceeds the screen" invariant is unit-tested at every
# size. Guarantees head + foot + (hints ? 2 : 0) + cap <= max($rows,1) and
# cap >= 1, so the frame can never overflow and reintroduce scrolling.
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

# =====================================================================
# The interactive loop — cards, colour tokens, idle resize polling.
# =====================================================================
#
# run_picker_loop(\@opts, %seams) -> $action|'CANCEL'|undef
#
# Seams: read_key($timeout) (raw char or undef on timeout), term_size()
# (($cols,$rows)), out($bytes), cap (default Theme::capability()), poll
# (default 0.2, always 0 < poll <= 0.25). Pure aside from those seams: never
# touches a real terminal, a clock beyond what term_size/read_key report, or
# the filesystem.
sub run_picker_loop {
    my ($opts, %seams) = @_;
    my @opts = (ref $opts eq 'ARRAY') ? @$opts : ();

    my $read_key  = (ref $seams{read_key}  eq 'CODE') ? $seams{read_key}  : sub { undef };
    my $term_size = (ref $seams{term_size} eq 'CODE') ? $seams{term_size} : sub { (80, 24) };
    my $out       = (ref $seams{out}       eq 'CODE') ? $seams{out}       : sub { };
    my $cap       = exists $seams{cap} ? $seams{cap} : Theme::capability();
    my $poll      = (defined($seams{poll}) && $seams{poll} > 0 && $seams{poll} <= 0.25) ? $seams{poll} : 0.2;

    my $view = 'user';
    my @view_opts = filter_options(\@opts, $view);
    my $sel  = 0;
    my $top  = 0;
    my $page = 1;

    my ($last_cols, $last_rows);
    my $settle = 0;
    my $idle = 0;
    my $idle_limit = tui::LaunchScreens::IDLE_POLL_LIMIT();

    my $row = sub {
        my ($line, $cols) = @_;
        my $cell = tui::Frame::make_cell($line, undef, $cols);
        return tui::Frame::paint_row($cell, $cap) . "\e[K";
    };

    my $render_frame = sub {
        my ($full) = @_;
        my ($cols, $rows) = $term_size->();
        $cols = 80 if !$cols || $cols < 1;
        $rows = 24 if !$rows || $rows < 1;
        $last_cols = $cols;
        $last_rows = $rows;

        my @heights;
        for my $o (@view_opts) {
            if (($o->{action} // '') eq 'NEW') {
                push @heights, 2;
            } else {
                my $h = tui::LaunchScreens::session_card_height($o->{card}, $cols);
                push @heights, (defined $h && $h >= 1) ? $h : 3;
            }
        }
        my $total_h = 0;
        $total_h += $_ for @heights;
        my $L = plan_frame($rows, $total_h);
        my $cap_rows = $L->{cap};

        $sel = 0 if $sel < 0;
        $sel = $#view_opts if @view_opts && $sel > $#view_opts;
        my $win = tui::LaunchScreens::card_window(\@heights, $sel, ($cap_rows > 0 ? $cap_rows : 1), $top);
        $top = $win->{first};
        $page = $win->{last} - $win->{first} + 1;
        $page = 1 if $page < 1;

        my @lines;
        if (@view_opts && $win->{last} >= $win->{first}) {
            for my $i ($win->{first} .. $win->{last}) {
                my $o = $view_opts[$i];
                my $is_sel = ($i == $sel) ? 1 : 0;
                my $ln = (($o->{action} // '') eq 'NEW')
                    ? tui::LaunchScreens::session_new_lines($cols, $is_sel)
                    : tui::LaunchScreens::session_card_lines_cached($o->{card}, $cols, $is_sel);
                push @lines, @$ln if ref $ln eq 'ARRAY';
            }
        }
        @lines = @lines[0 .. $cap_rows - 1] if $cap_rows > 0 && @lines > $cap_rows;

        my $title_txt = 'Resume a session' . (length($PROJECT_LABEL) ? " - $PROJECT_LABEL" : '');
        my @rows;
        push @rows, $row->([ { text => $title_txt, role => 'accent' } ], $cols) if $L->{head} >= 1;
        if ($L->{head} >= 3) {
            push @rows, $row->([ { text => ('-' x 60), role => 'rule' } ], $cols);
            push @rows, $row->([], $cols);
        }
        push @rows, $row->([ { text => "    ($win->{above} more above)", role => 'text.faint' } ], $cols)
            if $L->{hints} && $win->{above};
        for my $ln (@lines) { push @rows, $row->($ln, $cols); }
        my $shown = scalar @lines;
        if (show_empty_note(scalar @view_opts, $shown, $cap_rows)) {
            push @rows, $row->([ { text => '    ' . empty_view_note($view), role => 'text.muted' } ], $cols);
        }
        push @rows, $row->([ { text => "    ($win->{below} more below)", role => 'text.faint' } ], $cols)
            if $L->{hints} && $win->{below};
        if ($L->{foot} >= 2) {
            push @rows, $row->([], $cols);
            push @rows, $row->([ { text => footer_text($view, 0), role => 'text.faint' } ], $cols);
        } elsif ($L->{foot} >= 1) {
            push @rows, $row->([ { text => footer_text($view, 1), role => 'text.faint' } ], $cols);
        }
        my $bytes = $full ? "\e[H\e[2J" : "\e[H";
        $bytes .= join("\r\n", @rows);
        $bytes .= "\e[J";
        $out->($bytes);
    };

    $render_frame->(1);

    while (1) {
        my $k = $read_key->($poll);
        if (!defined $k) {
            my ($cols, $rows) = $term_size->();
            $cols = 80 if !$cols || $cols < 1;
            $rows = 24 if !$rows || $rows < 1;
            if (defined($last_cols) && ($cols != $last_cols || $rows != $last_rows)) {
                $settle = tui::LaunchScreens::RESIZE_SETTLE_POLLS();
                $render_frame->(1);
            } elsif ($settle > 0) {
                $settle--;
                $render_frame->(1);
            }
            # Bounded so a read_key that cannot block (EOF on stdin) cannot
            # spin here forever; any real key resets the run (M3, list_run's
            # IDLE_POLL_LIMIT precedent).
            return 'CANCEL' if ++$idle >= $idle_limit;
            next;
        }
        $idle = 0;

        if ($k eq "\e") {
            my $k2 = $read_key->(0.05);
            if (defined $k2 && ($k2 eq '[' || $k2 eq 'O')) {
                my $k3 = $read_key->(0.05);
                if (defined $k3) {
                    if    ($k3 eq 'A') { $sel-- if $sel > 0;                 $render_frame->(0); next }
                    elsif ($k3 eq 'B') { $sel++ if $sel < $#view_opts;       $render_frame->(0); next }
                    elsif ($k3 eq 'H') { $sel = 0;                          $render_frame->(0); next }
                    elsif ($k3 eq 'F') { $sel = $#view_opts;                $render_frame->(0); next }
                    elsif ($k3 =~ /[0-9]/) {
                        my $digits = $k3;
                        while (defined(my $d = $read_key->(0.02))) {
                            last if $d !~ /[0-9;]/;
                            $digits .= $d;
                        }
                        if    ($digits eq '5') { $sel -= $page }
                        elsif ($digits eq '6') { $sel += $page }
                        $sel = 0          if $sel < 0;
                        $sel = $#view_opts if $sel > $#view_opts;
                        $render_frame->(0); next;
                    }
                }
                next;
            }
            return 'CANCEL';
        }
        if ($k eq "\n" || $k eq "\r") {
            return @view_opts ? $view_opts[$sel]{action} : 'CANCEL';
        }
        if (lc($k) eq 't') {
            $view = ($view eq 'user') ? 'butler' : 'user';
            @view_opts = filter_options(\@opts, $view);
            $sel = 0;
            $top = 0;
            $render_frame->(0);
            next;
        }
        if (lc($k) eq 'q') { return 'CANCEL' }
        if ($k eq "\x03")  { return 'CANCEL' }
        # any other key: ignore, no redraw needed
    }
}

# Full TUI: a windowed, scrolling, arrow-key picker drawn on the ALTERNATE
# screen buffer (\e[?1049h). run_picker_loop above holds the loop/keys/cards;
# this wraps it with the real terminal (Term::ReadKey seams, alt-screen
# enter/leave, signal cleanup) or falls back to the non-TTY line prompt.
sub run_tui {
    my @opts = @_;
    my $view = 'user';
    my @view = filter_options(\@opts, $view);

    my $have_readkey = eval { require Term::ReadKey; 1 };
    if (!$have_readkey || !-t STDIN || !-t STDERR) {
        return run_line_prompt(@view);               # D8: default-filtered, no toggle
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

    my $action = run_picker_loop(\@opts,
        read_key  => sub {
            my ($timeout) = @_;
            return eval { Term::ReadKey::ReadKey(defined $timeout ? $timeout : 0.2) };
        },
        term_size => sub {
            my @s = eval { Term::ReadKey::GetTerminalSize() };
            my $cols = (@s && $s[0] && $s[0] > 0) ? $s[0] : 80;
            my $rows = (@s && $s[1] && $s[1] > 0) ? $s[1] : 24;
            return ($cols, $rows);
        },
        out => sub { print STDERR $_[0]; },
    );

    $cleanup->();
    return $action;
}

# =====================================================================
# Entry point
# =====================================================================
#
# Guarded by `unless (caller)` so a test can `require` this script to unit-test
# the pure helpers without the main flow running and calling exit().

unless (caller) {
    parse_args(@ARGV);

    unless (load_session_index()) {
        print STDERR "select-session.pl: cannot load SessionIndex.pm: $SESSION_INDEX_ERR\n";
        exit 1;
    }
    unless (load_session_fork()) {
        print STDERR "select-session.pl: cannot load SessionFork.pm\n";
        exit 1;
    }

    # --fork <host uuid>: non-interactive mode (package 07-host-session-fork).
    # Usage errors (malformed uuid also blocks path traversal, e.g. "../x")
    # and "combined with --list-json" were already exited 1 in parse_args.
    # Never touches a terminal, never writes --output. Decision 32/33: a
    # fork failure here is reported to the caller (non-empty stderr,
    # FORK_FAILED_EXIT, empty stdout) -- it is the caller's job to decide
    # whether to return to the picker rather than silently starting a new
    # session.
    if ($FORK_UUID_SET) {
        unless (load_session_fork() && SessionFork::is_uuid_shaped($FORK_UUID)) {
            print STDERR "select-session.pl: --fork requires a well-formed uuid\n";
            exit 1;
        }
        my $host_file = "$HOST_SESSIONS_DIR/$FORK_UUID.jsonl";
        unless (-f $host_file) {
            print STDERR "select-session.pl: --fork: no such host session: $FORK_UUID\n";
            exit FORK_FAILED_EXIT;
        }
        my ($new, $err) = SessionFork::fork_session($host_file, $SESSIONS_DIR);
        unless (defined $new) {
            my $msg = sanitize_cell(defined($err) && length($err) ? $err : 'unknown error');
            print STDERR "select-session.pl: fork failed: $msg\n";
            exit FORK_FAILED_EXIT;
        }
        print "RESUME $new\n";
        exit 0;
    }

    my @sessions = merged_sessions();
    my $sids     = butler_sids();                      # {} on any failure (D4)
    SessionFilter::mark_sessions(\@sessions, $sids) if load_session_filter();
    for my $s (@sessions) {
        my $kind_hidden = defined($s->{kind}) && $s->{kind} ne 'human';
        $s->{is_butler} = ($s->{is_butler} || $kind_hidden) ? 1 : 0;
        # A fork inherits is_butler from its host source through provenance
        # (Decision 12's "same human-only filter", extended -- AC-26): its
        # OWN uuid is fresh and never matches $sids on its own.
        if (!$s->{is_butler} && defined($s->{origin}) && $s->{origin} eq 'fork'
                && defined($s->{source_session_id}) && load_session_filter()) {
            $s->{is_butler} = 1 if SessionFilter::is_butler_session($s->{source_session_id}, $sids);
        }
    }

    # 08-launcher-screens: the DATA mode. One JSON object on stdout, exit 0.
    # N3: skip build_options (and so a redundant card_fields pass) here --
    # this mode calls card_fields itself, per row, below.
    if ($LIST_JSON) {
        my $error;
        if (length $SESSIONS_DIR) {
            # Decode before interpolating into a ->utf8 JSON encoder: that
            # encoder expects Perl-internal (decoded) text and re-encodes it
            # to UTF-8 bytes. $SESSIONS_DIR is the raw argv byte string, so
            # encoding it as-is double-encodes any non-ASCII path (N2).
            my $dir_disp = eval { Encode::decode('UTF-8', $SESSIONS_DIR, Encode::FB_DEFAULT) };
            $dir_disp = $SESSIONS_DIR unless defined $dir_disp;
            if (!-d $SESSIONS_DIR) {
                # package 07 S2.2: a fresh sandbox with no sessions yet is
                # not an error -- it's exactly when forking a host session
                # matters (a nonexistent dir is created on the first fork).
                $error = undef;
            }
            elsif (opendir(my $probe, $SESSIONS_DIR)) {
                closedir $probe;
            }
            else {
                $error = "sessions directory could not be read: $dir_disp: $!";
            }
        }
        my @rows;
        for my $s (@sessions) {
            push @rows, {
                uuid      => $s->{uuid},
                mtime     => $s->{mtime},
                is_butler => ($s->{is_butler} ? 1 : 0),
                origin    => $s->{origin},
                card      => card_fields($s, time),
            };
        }
        print JSON::PP->new->utf8->canonical(1)->encode(
            { sessions => \@rows, error => $error });
        exit 0;
    }

    # Zero-session fast path: nothing to pick from, just emit NEW and exit.
    if (@sessions == 0) {
        write_action('NEW');
        exit 0;
    }

    my @opts = build_options(@sessions);
    my $action = run_tui(@opts);
    if (!defined $action || $action eq 'CANCEL') {
        exit 2;
    }

    # Picking a host row (Decision 14): fork before resuming. On failure,
    # report the error and exit FORK_FAILED_EXIT without writing --output
    # (Decision 32/33) -- the launcher's caller decides whether to return to
    # the picker rather than silently starting a new session.
    if ($action =~ /\AHOST\s+(\S+)\s*\z/) {
        my $host_uuid = $1;
        # red-team S2 (SHOULD-FIX): the plain picker's HOST id came straight
        # from the option list -- validate it the same way --fork already
        # does (is_uuid_shaped) BEFORE it is used to build a path. Without
        # this, a content-derived host-row id (S1) that slipped past
        # origin_sessions could still contain "/" or ".." and target a file
        # outside $HOST_SESSIONS_DIR.
        unless (load_session_fork() && SessionFork::is_uuid_shaped($host_uuid)) {
            print STDERR "select-session.pl: fork failed: malformed host session id\n";
            exit FORK_FAILED_EXIT;
        }
        my $host_file = "$HOST_SESSIONS_DIR/$host_uuid.jsonl";
        my ($new, $err) = SessionFork::fork_session($host_file, $SESSIONS_DIR);
        unless (defined $new) {
            my $msg = sanitize_cell(defined($err) && length($err) ? $err : 'unknown error');
            print STDERR "select-session.pl: fork failed: $msg\n";
            exit FORK_FAILED_EXIT;
        }
        $action = "RESUME $new";
    }

    write_action($action);
    exit 0;
}

1;
