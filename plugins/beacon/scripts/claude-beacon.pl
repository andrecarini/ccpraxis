#!/usr/bin/env perl
# claude-beacon.pl — TUI launcher for resuming beaconed Claude Code sessions.
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

use strict;
use warnings;
use utf8;
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

my $home = $ENV{HOME} // $ENV{USERPROFILE};
die "Cannot determine home directory\n" unless $home;
# Env-var bytes from cygwin/Git Bash are UTF-8; decoding sets the
# SVf_UTF8 flag so :utf8 STDOUT encodes correctly instead of double-
# encoding the raw bytes (which would produce `AndrÃ©` mojibake).
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

# ── Argv ─────────────────────────────────────────────────────
my $no_sync = 0;
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

# ── TUI plumbing ─────────────────────────────────────────────
# Mirrors plugins/sandbox/scripts/skills.pl: cbreak via Term::ReadKey, ANSI escapes for
# cursor/clear, restored on every exit path (END + signal traps).

my $TUI_ACTIVE = 0;
sub tui_enter {
    require Term::ReadKey;
    Term::ReadKey::ReadMode(4);  # cbreak: char-at-a-time, no echo
    print "\e[?25l";              # hide cursor
    $TUI_ACTIVE = 1;
}
sub tui_exit {
    return unless $TUI_ACTIVE;
    print "\e[?25h";              # show cursor
    print "\e[0m";                # reset attrs
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
            # Drain numeric escape sequences (e.g. PageUp = ESC[5~)
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

# Read a y/N answer with cbreak still on. Echoes the key so the user can
# see what they typed. Returns the lowercased single char or '' on EOF.
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

# ── Sanitization & formatting ────────────────────────────────
# Labels/summaries/slugs can contain anything per beacon.pl's accepted
# risks (D5 notes line 167). Strip ANSI/control chars before rendering so
# a malicious label can't clear the screen or repaint.
sub sanitize_display {
    my $s = shift;
    return '' unless defined $s;
    if (!utf8::is_utf8($s)) {
        my $decoded = eval { decode('UTF-8', $s, FB_CROAK) };
        $s = $decoded if defined $decoded && !$@;
    }
    $s =~ s/\e\[[0-9;?]*[A-Za-z]//g;  # CSI sequences
    $s =~ s/\e\][^\a\e]*(?:\a|\e\\)//g; # OSC sequences
    $s =~ s/\e[^\[\]]//g;              # other ESC + 1
    $s =~ s/[\x00-\x1F\x7F]//g;        # C0 controls (incl \r \n \t) + DEL
    return $s;
}

# Truncate a Unicode-aware string to N visible chars. Doesn't account for
# wide CJK glyphs; close enough for ASCII slugs and labels.
sub truncate_str {
    my ($s, $max) = @_;
    return $s unless defined $s;
    return $s if length($s) <= $max;
    return '' if $max <= 1;
    return substr($s, 0, $max - 1) . "\x{2026}";  # ellipsis
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

# ── Windows-aware executable resolver ────────────────────────
# Perl's `exec LIST` on Windows calls CreateProcess directly and does NOT
# enumerate PATHEXT — so `exec 'claude', ...` won't find `claude.cmd` (the
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
    # Always try .PS1 — our wrapper lives there even when PATHEXT omits it.
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

# ── Subprocess helper (no shell) ─────────────────────────────
# Returns (stdout, exit_code). Drains stderr to avoid pipe deadlock.
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

# ── chdir helper (handles Win32 ANSI-API + Unicode paths) ────
# Perl's chdir on Windows passes bytes to the Win32 ANSI API. A Unicode
# string coming out of decode_json (e.g. `C:/Users/André/…` with `é` as
# U+00E9) often fails with ENOENT even when the directory exists — the
# raw Perl string is internally UTF-8 bytes, but the ANSI API expects
# the active codepage. We try the string as-is first (POSIX + Strawberry
# Perl wide-char builds work that way), then fall back to explicit
# encodings: system codepage (cp1252 on Western Win10/11) and UTF-8.
# Returns (ok_bool, error_message).
sub try_chdir {
    my $path = shift;
    return (0, 'no path') unless defined $path;
    return (0, 'empty path') unless length $path;

    # 1. As-is (Unicode string).
    return (1, '') if chdir $path;
    my $first_err = "$!";

    # 2. Encoded fallbacks — only on Windows.
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

# ── Vault gathering ──────────────────────────────────────────
sub gather {
    my $skip_sync = shift;
    unless ($skip_sync) {
        # Idempotent and LOCK_NB-deduped against the statusline's bg fire.
        # We don't care about the output; even a failure is non-fatal — the
        # subsequent list call works against the current vault state.
        my (undef, $rc) = run_capture($^X, $BEACON_PL, 'sync-vault');
        warn "Note: sync-vault exited $rc; using current vault as-is.\n"
            if $rc != 0 && $rc != -1;
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

# ── Render ───────────────────────────────────────────────────
sub render_beacons {
    my ($beacons, $cursor, $status_msg) = @_;
    my ($cols, $rows) = term_size();
    $cols = 120 if $cols > 120;  # cap for readability

    print "\e[H\e[J";  # cursor home + clear screen

    my $n = scalar @$beacons;
    my $title = sprintf(" Beacons (%d) ", $n);
    my $title_len = length $title;
    my $border_top = "\x{250C}\x{2500}" . $title
        . ("\x{2500}" x ($cols - 2 - $title_len - 1)) . "\x{2510}";
    print "\e[1m$border_top\e[0m\n";

    # Each row format:
    #   │ {arrow} {fisheye} {slug} · {label-or-summary}   {scope} · {ago} │
    # Right side is fixed-width "scope · ago" (max 18 chars: "sandbox · 99mo ago").
    # Left side absorbs whatever space is left.
    for my $i (0 .. $#$beacons) {
        my $b = $beacons->[$i];
        my $is_cursor = ($i == $cursor);

        my $slug    = sanitize_display($b->{project_slug});
        my $label   = sanitize_display($b->{label});
        my $summary = sanitize_display($b->{summary});
        my $desc    = length($label)   ? $label
                    : length($summary) ? $summary
                    : '(unlabeled)';
        my $scope   = ($b->{scope} // 'host') eq 'sandbox' ? 'sandbox' : 'host';
        my $ago     = relative_time($b->{last_active_at});

        my $left_text = length($slug) ? "$slug \x{00B7} $desc" : $desc;
        my $right_text = sprintf("%s \x{00B7} %s", $scope, $ago);
        my $right_text_len = length $right_text;

        # Compose with 4 ANSI-invisible chars on the left: arrow + space + icon + space
        # And: leading "│ " (2 chars) and trailing " │" (2 chars), plus a 3-char gap.
        my $arrow = $is_cursor ? "\x{25B6}" : ' ';   # ▶ or space
        my $icon  = "\x{25C9}";                        # ◉
        my $fixed_chars = 2 + 1 + 1 + 1 + 1 + 3 + $right_text_len + 2;  # see below
        # Breakdown: "│ " (2) + arrow (1) + " " (1) + icon (1) + " " (1) +
        # gap (3) + right (n) + " │" (2)
        my $left_avail = $cols - $fixed_chars;
        $left_avail = 1 if $left_avail < 1;
        $left_text = truncate_str($left_text, $left_avail);
        my $pad = $left_avail - length($left_text);
        $pad = 0 if $pad < 0;

        my $row_body = sprintf(
            "%s %s %s%s   %s",
            $arrow, $icon, $left_text, (' ' x $pad), $right_text
        );

        my $line = "\x{2502} $row_body \x{2502}";
        if ($is_cursor) {
            print "\e[7m$line\e[0m\n";
        } else {
            print "$line\n";
        }
    }

    my $help = " \x{2191}\x{2193} select \x{00B7} enter resume \x{00B7} u unbeacon \x{00B7} r refresh \x{00B7} q quit ";
    my $help_len = length $help;
    my $border_bot = "\x{2514}\x{2500}" . $help
        . ("\x{2500}" x ($cols - 2 - $help_len - 1)) . "\x{2518}";
    print "\e[1m$border_bot\e[0m\n";

    if (defined $status_msg && length $status_msg) {
        print "\e[2m$status_msg\e[0m\n";
    }
}

# Inline confirm rendered as the next line below the box. Stays in cbreak.
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

# ── Resolve host project path for sandbox dispatch ───────────
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

# ── Dispatch (exec into resume cmd) ──────────────────────────
sub dispatch {
    my $b = shift;
    my $sid = $b->{session_id};

    # Validate UUID before exec — beacon.pl writes only valid UUIDs into
    # the vault, but we're about to pass this to another process and we
    # want a hard guarantee, not a transitive trust.
    unless (defined $sid && $sid =~ /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) {
        tui_exit();
        print STDERR "claude-beacon: refusing to dispatch — invalid UUID in record: " . ($sid // '<undef>') . "\n";
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
            # double-encode — exactly the bug the $home fix prevents
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
        # so Unicode codepoints like `é` reach Win32 ANSI APIs as raw UTF-8
        # bytes that don't resolve). PowerShell uses wide-char Win32 APIs
        # natively and handles paths like `C:/Users/André/...` reliably.
        if ($^O =~ /^(MSWin32|cygwin|msys)$/) {
            if (defined $cwd && length $cwd) {
                (my $psq = $cwd) =~ s/'/''/g;
                my $ps_cmd = "Set-Location -LiteralPath '$psq'; "
                           . "& claude --resume $sid";
                # PowerShell -EncodedCommand takes UTF-16LE base64 and
                # decodes it natively, bypassing the Win32 argv codepage
                # interpretation that otherwise mangles non-ASCII paths
                # like `André` (passing them as cp1252-mojibake on the
                # shell's command line). The base64 wire format is pure
                # ASCII so it survives the perl-to-CreateProcess hop.
                my $utf16le = encode('UTF-16LE', $ps_cmd);
                my $b64 = encode_base64($utf16le, '');
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

# ── Unbeacon from inside the TUI ─────────────────────────────
sub remove_beacon {
    my $sid = shift;
    my ($out, $rc) = run_capture($^X, $BEACON_PL, 'unbeacon', '--session-id', $sid);
    # 0 = removed; 2 = not_found (already gone); other = error.
    if ($rc != 0 && $rc != 2) {
        return (0, $out || "unbeacon exited $rc");
    }
    return (1, '');
}

# ── Non-TTY fallback ─────────────────────────────────────────
sub run_non_tty {
    my $beacons = shift;
    if (!@$beacons) {
        print "No beacons found.\n";
        exit 0;
    }
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
            (length($slug) ? "\x{00B7} " : ''),
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

# ── TUI main loop ────────────────────────────────────────────
sub run_tui {
    my $beacons = shift;
    my $status_msg = '';

    tui_enter();
    my $cursor = 0;

    while (1) {
        $cursor = 0           if $cursor < 0;
        $cursor = $#$beacons  if $cursor > $#$beacons;
        if (!@$beacons) {
            tui_exit();
            print "No beacons found.\n";
            return 0;
        }

        render_beacons($beacons, $cursor, $status_msg);
        $status_msg = '';
        my $key = tui_read_key();
        last unless defined $key;  # EOF -> exit cleanly

        if ($key eq 'UP')                          { $cursor-- if $cursor > 0 }
        elsif ($key eq 'DOWN')                     { $cursor++ if $cursor < $#$beacons }
        elsif ($key eq 'HOME' || $key eq 'g')      { $cursor = 0 }
        elsif ($key eq 'END'  || $key eq 'G')      { $cursor = $#$beacons }
        elsif ($key eq 'ENTER')                    {
            dispatch($beacons->[$cursor]);
            return 0;  # unreachable; dispatch execs
        }
        elsif ($key eq 'q' || $key eq 'ESC')       { last }
        elsif ($key eq 'r') {
            $beacons = gather($no_sync);
            $cursor = 0 if $cursor > $#$beacons;
            $status_msg = 'Refreshed.';
        }
        elsif ($key eq 'u') {
            my $b = $beacons->[$cursor];
            my $slug = sanitize_display($b->{project_slug}) || 'beacon';
            my $short = substr($b->{session_id}, 0, 8);
            my $ans = inline_confirm("Unbeacon $slug ($short...)? [y/N] ");
            if ($ans eq 'y') {
                my ($ok, $err) = remove_beacon($b->{session_id});
                if ($ok) {
                    splice(@$beacons, $cursor, 1);
                    $cursor = $#$beacons if $cursor > $#$beacons;
                    $status_msg = 'Removed.';
                } else {
                    $status_msg = "Unbeacon failed: $err";
                }
            } else {
                $status_msg = 'Kept.';
            }
        }
        # ignore everything else
    }

    tui_exit();
    print "\n";
    return 0;
}

# ── Main ─────────────────────────────────────────────────────
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
