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
    # The todos icon (2026-08-26), same reasoning.
    0x22EE => 1,
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

# ── Continuity badge (g01-explicit-continuity-arming) ────────
# Per-session, keyed by the documented top-level `session_id` field of the
# stdin JSON (spec SS2.6/AC-7).
#
# IT TRACKED THE ARMING COMMAND, NOT CONTINUITY (operator, 2026-08-25: "it
# only appears when I manually toggle it on with the command, doesn't appear
# when other sources have also turned it on"). It read ONE registry --
# .continuity-active, written only by bp-continuity.pl's arm -- while butler
# runs THREE per-session registries, each backing a Stop gate that will refuse
# to let this session's turn end:
#
#   .continuity-active   gate-continuity.sh    explicit arm / /butler:continuity
#   .drive-solo-active   gate-drive-loop.sh    a /butler:drive-solo DRIVER session
#   .reporter-active     gate-drive-loop.sh    a registered reporter session
#
# So a session driving a blueprint was gated exactly as hard as an armed one
# and the badge said nothing. A status indicator that is silent while the
# state it reports is live does not merely omit -- it tells you the gate is
# off. All three are now read, and the badge names WHICH, because "why can't
# this turn end" is the question it exists to answer.
#
# Path resolution is duplicated from lib.sh's bp_continuity_active_dir /
# bp_drive_active_dir / bp_reporter_active_dir, ON PURPOSE -- this file stays a
# standalone installed payload (no require of anything under plugins/). They
# must resolve identically for a given environment; AC-13 pins that parity for
# the continuity one, and the other two are the same rule with a different leaf
# and a different override variable.
#
# PATH RESOLUTION (fix-batch F1) -- override, else $HOME, else $USERPROFILE,
# else UNRESOLVABLE. This file is a READ path only (it never writes a marker),
# so unlike bp-continuity.pl it must never hard-fail the statusline over this --
# "unresolvable" degrades to "badge renders unarmed", which is truthful rather
# than a fourth guess: if the directory can never be resolved here, the writer
# could never have resolved it either (same rule), so it could never have
# written a live marker for this badge to miss.
#
# NO TTL IS APPLIED HERE, deliberately and as before. Reaping a stale marker is
# the hooks' job (bp_continuity_any_active and its siblings sweep the whole
# registry on every Stop event, owner-independently). A read path that
# second-guessed the reaper would disagree with the gate, which is the one thing
# this badge must never do.
sub _registry_dir {
    my ($override, $leaf) = @_;
    my $v = $ENV{$override};
    return $v if defined $v && length $v;
    my $home = $ENV{HOME};
    $home = $ENV{USERPROFILE} unless defined $home && length $home;
    return undef unless defined $home && length $home;
    return "$home/.claude/ccpraxis/$leaf";
}

my $sid = $data->{session_id};
$sid = '' unless defined $sid && !ref($sid) && $sid =~ m{\A[^/\\\0]+\z} && $sid !~ /\.\./;

# Order is PRECEDENCE, most explicit first: an operator who armed continuity by
# hand is told that, even if this session also happens to be driving.
my @WATCHERS = (
    [ 'CCPRAXIS_CONTINUITY_ACTIVE_DIR', '.continuity-active',  'watched'   ],
    [ 'CCPRAXIS_DRIVE_ACTIVE_DIR',      '.drive-solo-active',  'driving'   ],
    [ 'CCPRAXIS_REPORTER_ACTIVE_DIR',   '.reporter-active',    'reporting' ],
);
my $badge_word = '';
if (length $sid) {
    for my $w (@WATCHERS) {
        my ($override, $leaf, $word) = @$w;
        my $dir = _registry_dir($override, $leaf);
        next unless defined $dir;
        next unless -f "$dir/$sid";
        $badge_word = $word;
        last;
    }
}

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
        # above rather than left to the fallback.
        push @parts, "${MUTED}\x{29C9} ${R}${PRIMARY}${n}${R}" if $n > 0;
    }

    # Todos: non-archived ~/.claude/claude-code-vault/todos/*.md (global)
    my $todo_dir = "$ENV{HOME}/.claude/claude-code-vault/todos";
    if (-d $todo_dir) {
        opendir(my $dh, $todo_dir) or die;
        my $n = grep { /\.md$/ && !/^README\.md$/ && -f "$todo_dir/$_" } readdir($dh);
        closedir($dh);
        # AN ICON, NOT THE WORD -- the same call the blueprints count got, and
        # the operator picked U+22EE (vertical ellipsis, "items continuing
        # down") from ten offered. Chosen partly BECAUSE it contrasts with
        # U+29C9 above: two box-shaped glyphs side by side would read as a
        # matched pair rather than two different counts. Declared in Theme.pm
        # and in %GLYPH_COLS above.
        push @parts, "${MUTED}\x{22EE} ${R}${PRIMARY}${n}${R}" if $n > 0;
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
my $f_marker  = $marker;
my $f_project = $project;
my $f_cwd     = '';
my $f_git     = $git_str;
my $f_plans   = $plans_str;
my $sep_cost  = row_cost($SEP);
my $line1;

FIT: {
    $line1 = row1($f_marker, $f_project, $f_cwd, $f_git, $f_plans);
    last FIT if row_cost($line1) <= $cols;

    # 2. plans, and its separator.
    $f_plans = '';
    $line1 = row1($f_marker, $f_project, $f_cwd, $f_git, $f_plans);
    last FIT if row_cost($line1) <= $cols;

    # 3. git, and its separator.
    $f_git = '';
    $line1 = row1($f_marker, $f_project, $f_cwd, $f_git, $f_plans);
    last FIT if row_cost($line1) <= $cols;

    # 4. left-elide the working directory, down to its floor.
    if (length $f_cwd) {
        my $fixed = row_cost($f_marker)
                  + (length($f_project) ? $sep_cost + row_cost($f_project) : 0)
                  + $sep_cost;
        my $avail = $cols - $fixed;
        $avail = MIN_CWD_COLS if $avail < MIN_CWD_COLS;
        $f_cwd = fit_tail($cwd, $avail);
        $line1 = row1($f_marker, $f_project, $f_cwd, $f_git, $f_plans);
        last FIT if row_cost($line1) <= $cols;
    }

    # 5. right-elide the project name, down to its floor.
    if (length $f_project) {
        my $fixed = row_cost($f_marker) + $sep_cost
                  + (length($f_cwd) ? $sep_cost + row_cost($f_cwd) : 0);
        my $avail = $cols - $fixed;
        $avail = MIN_PROJECT_COLS if $avail < MIN_PROJECT_COLS;
        $f_project = fit_head($project, $avail);
        $line1 = row1($f_marker, $f_project, $f_cwd, $f_git, $f_plans);
        last FIT if row_cost($line1) <= $cols;
    }

    # 6. the project, and its separator.
    $f_project = '';
    $line1 = row1($f_marker, $f_project, $f_cwd, $f_git, $f_plans);
    last FIT if row_cost($line1) <= $cols;

    # 7. the working directory down to a bare marker, then gone entirely.
    if (length $f_cwd) {
        $f_cwd = fit_tail($cwd, 1);
        $line1 = row1($f_marker, $f_project, $f_cwd, $f_git, $f_plans);
        last FIT if row_cost($line1) <= $cols;
        $f_cwd = '';
        $line1 = row1($f_marker, $f_project, $f_cwd, $f_git, $f_plans);
        last FIT if row_cost($line1) <= $cols;
    }

    # 8. the marker itself. Below the common slot the symmetry guarantee is
    # void by declaration -- nothing can hold there -- but the budget
    # invariant still does.
    (my $bare = $f_marker) =~ s/\s+\z//;
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
push @tail, $f_git   if length $f_git;
push @tail, $f_plans if length $f_plans;

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
my $path_row = $SANDBOX_ON ? '' : path_row($cwd);
push @rows, $path_row if length $path_row;
print join("\n", @rows);
