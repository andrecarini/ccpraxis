#!/usr/bin/env perl
# launcher.pl — unified `claude-sandbox` launcher (plugins/sandbox/scripts/).
#
# Replaces the duplicated logic that used to live in the launcher
# .sh and .ps1 files. Both are now thin shims that locate perl and
# exec this script.
#
# Responsibilities (mirrored from the original .sh/.ps1 line-for-line):
#   - Arg parsing (positional project-path, --resume-session UUID).
#   - Bootstrap path: if the sandbox home doesn't exist, ask the user whether
#     to set up a sandbox here; on confirm, invoke bootstrap.pl
#     (deterministic perl-driven setup — no agent in the loop); re-check
#     after; abort if still not set up.
#   - Per-project mkdir-based lock + dead-PID cleanup + signal trap.
#   - Image presence + Containerfile/launcher hash drift, with rebuild prompt.
#   - Pin discovery snapshots (skills + plugins + MCP) for the whole run.
#   - Run the TUI (perl select-interactive).
#   - Compute staleness reasons (version, age, hashes, drift) + interactive
#     [r]/[c] rebuild prompt.
#   - Materialize plugin registry + sandbox credentials.
#   - Build skill/plugin/extra-env/extra-mount lists.
#   - Writable claude.json seeding.
#   - Launch or reattach (podman exec/start/create) with the full mount
#     set; exec replaces this perl process at the end.

use strict;
use warnings;
use File::Basename qw(dirname basename);
use Cwd qw(abs_path);
# Resolve the script's own directory so MountSpec.pm next to us is
# discoverable. Three traps to avoid here:
#   (a) FindBin::$Bin proved unreliable on cygwin perl with a Windows-
#       style $0 — pointed at CWD instead of the launcher dir.
#   (b) Cwd::abs_path also fails on cygwin: doesn't recognise `C:/...`
#       as absolute, prepends CWD, yields `/cwd/C:/path/...` garbage.
#   (c) Backslashes in __FILE__ on native Win32 perl confuse dirname.
# Strategy: take __FILE__ as-is (perl sets it from $0 + the require
# chain, so for the main script it's whatever path perl was invoked
# with — always absolute when called via the .ps1 / .sh shims),
# normalise backslashes, and take the dirname. No abs_path involved.
BEGIN {
    my $here = __FILE__;
    $here =~ s|\\|/|g;
    my $dir = dirname($here);
    unshift @INC, $dir;
}
use MountSpec qw(winify_path v_to_mount convert_v_to_mount);
use CcpraxisWorkCopy qw(workcopy_route workcopy_refusal_outcome);
use ProtectedPaths qw(path_relation protected_roots target_self_codes normalize_path);
use LaunchLog ();   # B1: durable per-launch diagnostic log (next to us in scripts/)
use Dashboard ();   # B2: the raw-ANSI TUI dashboard framework
use TokenInfo ();   # s08: pure access/refresh token status struct for the dashboard
use SpendPanel ();  # b37: pure Claude/Go/Zen spend status struct for the dashboard
                    # (the LAUNCHER loads it and computes; Dashboard.pm renders the
                    # already-computed struct and must never load it — same split
                    # TokenInfo has, and t/54-spend-panel asserts both halves)
use Resources ();   # s09: pure resource-probe parsers + the injectable probe seam
use RunState ();    # s10: pure orchestrator/run-state summarizer for the dashboard
use BackpackApproval ();  # #21: per-item, machine-local backpack approval memory
use BackpackReview ();    # #21: the I/O-seam-injected interactive approval walk
use KeepAwake ();         # B5: dashboard wake-lock decision + lifecycle holder
use ConnectorHold ();     # Fix 3: hold-the-window decision when a connector loses the container
use ClaudeConfig ();      # self-heal .claude.json onboarding-bypass (0-byte / lost-keys)
use PluginSync ();  # Fix 2: copy-model plugin-store reconcile (copy/prune/reconcile)
use PortAlloc ();         # fix-multiple-running-sandboxes: per-container port-block allocation
use SandboxLock ();       # 04-build-race-lock: generalised mkdir lock + global build-race guard
use JSON::PP ();          # parse backpack.json + write the approved install-set
use File::Path qw(make_path);
use File::Spec;
use File::Temp ();        # s17: STDERR capture destination while the alt-screen is owned --
                           # a REAL file (never an in-memory scalar; Git-for-Windows landmine)
use Fcntl qw(O_WRONLY O_CREAT O_EXCL O_NOFOLLOW);  # symlink-safe corrupt-config backup (redteam C1)
use Digest::MD5 qw();
use POSIX qw(strftime);
use Time::Piece;

binmode STDOUT, ':raw';
binmode STDERR, ':raw';

# =====================================================================
# Constants + platform detection
# =====================================================================

my $WINDOWS_FAMILY = $^O =~ /^(MSWin32|cygwin|msys)$/;

# Detect which container CLI is installed: prefer docker (Docker Desktop's
# `docker.exe` is the more universally installed runtime), fall back to
# podman. Probing by spawning `<cli> --version` is the only reliable check
# on Windows — relying on file-existence in $PATH is fragile because of
# .exe vs extensionless shim hijacks (Docker Desktop historically dropped
# an extensionless `docker` shell-wrapper alongside `docker.exe` that
# Git-for-Windows perl's POSIX `PATH` search would find first and fail to
# spawn). Always name the .exe explicitly on Windows.
sub _detect_container_cli {
    for my $candidate ($WINDOWS_FAMILY ? ('docker.exe', 'podman.exe') : ('docker', 'podman')) {
        my $rc = system("$candidate --version > /dev/null 2>&1");
        return $candidate if $rc == 0;
    }
    return undef;
}
my $PODMAN = _detect_container_cli();
unless (defined $PODMAN) {
    print STDERR "ERROR: no container CLI on PATH (looked for docker, podman).\n";
    print STDERR "       Install Docker Desktop (https://docker.com) or Podman Desktop\n";
    print STDERR "       (https://podman-desktop.io/) and re-run.\n";
    exit 1;
}

# Disable MSYS2 argument-path conversion before spawning any subprocess.
# MSYS2 (Git for Windows) treats every argv element that looks like a POSIX
# path and TRANSLATES it to a Windows path before invoking native binaries.
# For podman `-v HOST:CONTAINER[:opts]` args, MSYS2 sees the colons, treats
# the whole thing as a `:`-separated PATH-like list, converts each side
# separately, and re-joins with `;`. Result: podman receives
# `C:\host\path;C:\fake\container\path` (note the `;C`), tries to mount the
# `;C`-suffixed host path, can't find it, and silently creates a directory
# at that mangled name on the host — leaving onboarding-bypass / CLAUDE.md /
# settings.json mounts pointing at empty dirs. Setting MSYS2_ARG_CONV_EXCL=*
# disables the translation entirely for this perl process and its children.
#
# BUT — podman.exe (Podman on Windows) does NOT auto-translate `/c/foo` style
# POSIX paths. With MSYS2 disabled, we must hand it Windows-style paths or
# it errors with "no such file or directory" on the build context / mount
# source. So we ALSO convert every host path that goes into a podman arg to
# `C:/foo` form upfront (see `winify_path` below). The two together give us
# full control: podman gets clean Windows paths, MSYS2 doesn't silently
# rewrite them mid-flight.
$ENV{MSYS2_ARG_CONV_EXCL} = '*' if $WINDOWS_FAMILY;

# winify_path / v_to_mount / convert_v_to_mount come from MountSpec.pm (loaded
# above) so the test suite can hold the same logic accountable.

# Reset Windows Terminal's Line Feed / New Line Mode (LNM). Without this,
# a prior `podman exec -it claude` can leave LNM off, causing subsequent
# stdout lines to staircase across the screen. CSI 20 h sets LNM on for
# the terminal window; the effect persists. No-op on Linux/macOS.
sub reset_terminal {
    return unless $WINDOWS_FAMILY;
    local $| = 1;
    print STDOUT "\e[20h";
}
reset_terminal();

# Home directory: prefer $HOME (always set under Git Bash) and fall back
# to $USERPROFILE on native Windows perl. Die loudly if neither is set —
# every subsequent path is relative to this. Always returns Windows-style
# (`C:/Users/...`) on Windows so podman.exe can resolve it directly.
sub home_dir {
    my $h = $ENV{HOME} // $ENV{USERPROFILE};
    die "ERROR: neither HOME nor USERPROFILE is set\n" unless defined $h && length $h;
    $h =~ s|\\|/|g;
    $h =~ s|/+$||;
    return winify_path($h);
}

my $HOME              = home_dir();
my $CLAUDE_HOST_CONFIG = "$HOME/.claude";
my $SANDBOX_PLUGIN    = "$CLAUDE_HOST_CONFIG/ccpraxis/plugins/sandbox";
my $CONTAINER_CONFIG  = "$SANDBOX_PLUGIN/container";
my $SANDBOX_SKILLS_PL = "$SANDBOX_PLUGIN/scripts/skills.pl";
my $SELECT_SESSION_PL = "$SANDBOX_PLUGIN/scripts/select-session.pl";
my $HOST_PLUGINS_DIR  = "$CLAUDE_HOST_CONFIG/plugins";
# B2: the canonical entry paths the dashboard spawns for a new claude session,
# and whether the raw-ANSI TUI is even possible (else the plain heartbeat loop).
my $LAUNCHER_PL       = "$SANDBOX_PLUGIN/scripts/launcher.pl";
my $SANDBOX_PS1       = "$SANDBOX_PLUGIN/bin/claude-sandbox.ps1";
my $READKEY_OK        = eval { require Term::ReadKey; 1 } ? 1 : 0;

# =====================================================================
# Arg parsing
# =====================================================================
#
# Accepts an optional positional <project-path> and an optional
# --resume-session <uuid> flag (used by claude-beacon to resume a
# specific session). Flag accepted before OR after the positional.
# `=`-joined form (--resume-session=UUID) accepted too. Missing UUID
# at end-of-argv is an explicit error.

my $RESUME_SESSION = '';
my $SESSION_MODE   = 0;   # B2: --session => internal connector entry (Decision #19),
                          # spawned by the dashboard's launch-claude hotkey in a
                          # new window. Bare `claude-sandbox` always lands on the
                          # dashboard instead.
my @POSITIONAL;
{
    my @argv = @ARGV;
    while (@argv) {
        my $a = shift @argv;
        if ($a eq '--resume-session') {
            die "ERROR: --resume-session requires a UUID argument\n" unless @argv;
            $RESUME_SESSION = shift @argv;
        } elsif ($a =~ /^--resume-session=(.*)$/) {
            $RESUME_SESSION = $1;
        } elsif ($a eq '--session') {
            $SESSION_MODE = 1;
        } elsif ($a eq '--') {
            push @POSITIONAL, @argv;
            @argv = ();
        } else {
            push @POSITIONAL, $a;
        }
    }
}

if (length $RESUME_SESSION
    && $RESUME_SESSION !~ /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) {
    die "ERROR: --resume-session value is not a UUID: $RESUME_SESSION\n";
}

# =====================================================================
# Resolve project path + derived per-project paths
# =====================================================================

my $PROJECT_PATH = @POSITIONAL ? $POSITIONAL[0] : Cwd::getcwd();
$PROJECT_PATH = abs_path($PROJECT_PATH)
    or die "ERROR: cannot resolve project path '$POSITIONAL[0]'\n";
$PROJECT_PATH =~ s|\\|/|g;
$PROJECT_PATH =~ s|/+$||;
$PROJECT_PATH = winify_path($PROJECT_PATH);

my $PROJECT_NAME = lc(basename($PROJECT_PATH));
$PROJECT_NAME =~ s/ /-/g;

# =====================================================================
# p01: ccpraxis work-copy detection — must run AFTER $PROJECT_PATH is final
# =====================================================================
# §9.1: derive the live ccpraxis root from __FILE__ (registry-independent anchor).
# launcher.pl lives at <ccpraxis>/plugins/sandbox/scripts/launcher.pl
# so scripts->sandbox->plugins->ccpraxis is three dirname() calls.
my $LIVE_CCPRAXIS_ROOT = do {
    my $h = abs_path(__FILE__);
    die "ERROR: cannot canonicalise launcher.pl's own path via abs_path(__FILE__) "
        . "-- refusing to guess the ccpraxis install anchor\n" unless defined $h;
    $h =~ s|\\|/|g;
    my $s = dirname($h);
    dirname(dirname(dirname($s)));
};

# >>> q03:protected-path-decision:BEGIN
#     Pure decision + message design for the protected-path refusal.
#     CLOSED OVER NOTHING: everything arrives as arguments. t/53 lifts the
#     text between these sentinels and evals it in its own package, so this
#     region must never reference a launcher file-scope lexical, must never
#     load another module (the caller supplies the ProtectedPaths imports),
#     and must never terminate the process, emit output, or touch the
#     filesystem directly.

my %_PP_SELF_NOUN = (
    'drive-root' => 'a filesystem root',
    'user-home'  => 'your home directory',
);

my %_PP_RELATION_PHRASE = (
    exact      => 'exact (the path you gave IS this protected root)',
    descendant => 'descendant (the path you gave is INSIDE this protected root)',
    ancestor   => 'ancestor (the path you gave CONTAINS this protected root)',
);

# Local mirror of the module's own reason-precedence order (spec S2.5 rule 3:
# ccpraxis-install < claude-home < marketplace-install < marketplace-source <
# user-configured). Needed here, not just inside protected_roots, because the
# live_install_hint candidate (CRITICAL-1a below) is merged into the root set
# by this region and must be sorted into the same tie-break order.
my %_PP_REASON_RANK = (
    'ccpraxis-install'    => 0,
    'claude-home'         => 1,
    'marketplace-install' => 2,
    'marketplace-source'  => 3,
    'user-configured'     => 4,
);

# Strip every byte that could forge an extra physical line or an ANSI/control
# sequence when this text later lands on STDERR (a hostile registry key/value
# is untrusted input by construction -- MINOR-5). Replaced with a plain
# space so the surrounding text stays readable rather than being truncated.
sub _pp_sanitize {
    my ($s) = @_;
    return '' unless defined $s;
    $s =~ s/[\x00-\x1f\x7f]/ /g;
    return $s;
}

# CRITICAL-1(b): a pure env-lookup seam. $env_hashref is the raw environment
# view the caller was handed (a copy of the process environment hash);
# $authoritative_home, when defined and non-empty, is a caller-trusted HOME
# value that must win over whatever HOME the raw hashref carries -- this is
# what closes the redirected-HOME bypass, where pointing HOME at a decoy
# directory collapsed the protected set and let the real Claude home through.
# Every other key passes through the raw hashref unchanged. Never touches the
# real environment itself: both inputs arrive as arguments, so this stays
# closed over nothing.
#
# NOTE on wording: this comment sits inside the sentinel region, whose purity
# is asserted by a regex scan over the region's TEXT (t/53 AC-11). Naming the
# environment hash with its sigil, or quoting a shell command in backticks,
# trips that scan even in prose. Keep both out of this region.
sub _pp_env_seam {
    my ($env_hashref, $authoritative_home) = @_;
    $env_hashref //= {};
    return sub {
        my ($key) = @_;
        # Item 1 (D5): USERPROFILE is home_dir()'s own fallback for HOME
        # (see home_dir() above), so a seam that hardened only HOME left a
        # live variant of the exact CRITICAL-1 bypass it exists to close:
        # setting USERPROFILE to a decoy on a host with no HOME set would
        # still collapse the protected set. Every OTHER key still falls
        # through unchanged to the raw hash below (this must never become a
        # blanket override).
        #
        # NOTE ON WORDING: t/53's AC-11 (R-I2) greps this whole region for a
        # short list of I/O verbs followed by a space or paren, and for a
        # backtick, to prove the sentinel region performs no I/O. That grep
        # cannot tell code from prose, so ordinary English in a COMMENT can
        # trip it -- it did, twice, while this package was being written.
        # Keep comments in this region free of those verbs and of backticks.
        if (defined $key && $key eq 'HOME') {
            return $authoritative_home
                if defined $authoritative_home && length $authoritative_home;
        }
        # USERPROFILE is hardened ONLY when it would actually act as
        # home_dir()'s fallback -- that is, when HOME is absent or empty in the
        # supplied hash. That is precisely the exposed case, and no other.
        #
        # Scoping it this narrowly is deliberate and reconciles two contracts
        # that a blanket rule would have put in conflict. q03's AC-54 asserts
        # USERPROFILE passes through unchanged, and q04 built its source-set
        # design on the recorded fact that this seam hardens HOME specifically.
        # Both fixtures supply HOME, so both still hold. Meanwhile the finding
        # this closes -- USERPROFILE standing in for an absent HOME and moving
        # the whole protected set -- is closed, because that case is exactly
        # when HOME is missing.
        if (defined $key && $key eq 'USERPROFILE'
            && !(defined $env_hashref->{HOME} && length $env_hashref->{HOME})) {
            return $authoritative_home
                if defined $authoritative_home && length $authoritative_home;
        }
        return $env_hashref->{$key};
    };
}

sub _pp_explanation {
    my ($reason) = @_;
    my %text = (
        'ccpraxis-install' => q{That is the ccpraxis installation Claude Code is running from. Its plugins,
skills and launcher are in use right now, so sandboxing it would edit the
tooling while it is running, and git inside the container would not work.},
        'claude-home' => q{That is Claude Code's own configuration home. It holds your credentials, your
session transcripts, your memory files and every installed plugin.
Bind-mounting it into a container would expose all of it read-write.},
        'marketplace-install' => q{That is where Claude Code installed a plugin marketplace registered in
known_marketplaces.json. Editing it from inside a container would corrupt the
installed plugin tree Claude Code is loading from.},
        'marketplace-source' => q{That is the directory-source of a plugin marketplace registered in
known_marketplaces.json. Claude Code loads plugins straight out of it, so it
is live installed code, not a checkout.},
        'user-configured' => q{That path is in your own protected-paths list at
~/.claude/ccpraxis-protected-paths.json.

The guard reads that list from your real home directory only. CLAUDE_CONFIG_DIR
does not relocate it: a list read from a directory named by one environment
variable could be pointed elsewhere, and the guard would then silently stop
reading your real list - fewer protections, not more.},
        'drive-root' => q{A filesystem root contains every file on the volume - your home directory,
Claude Code's configuration, and every other project on the machine. Putting
all of that inside a container read-write is never what a sandbox is for, and
every file operation in the container would crawl.},
        'user-home' => q{Your home directory contains every project you have, plus Claude Code's
configuration and your credentials. Putting all of that inside a container
read-write is never what a sandbox is for.},
    );
    return $text{$reason}
        // 'This path collides with something Claude Code has installed on this machine.';
}

sub _pp_advice {
    my ($reason, $root) = @_;

    if ($reason eq 'ccpraxis-install') {
        return q{Work on a separate clone instead. Pick any ordinary directory outside this
install (for example C:/Development/ccpraxis on Windows, or ~/src/ccpraxis on
macOS or Linux), then run:

  git clone --no-hardlinks } . $root . q{ <your-clone-dir>
  cd <your-clone-dir>
  claude-sandbox

The --no-hardlinks flag is required: a local clone hardlinks the object store
by default, which would silently re-couple the clone to this installation.
See plugins/sandbox/docs/working-on-ccpraxis.md.};
    }

    if ($reason eq 'marketplace-install' || $reason eq 'marketplace-source') {
        return q{Open the specific project directory you meant to work in - cd into it and run
claude-sandbox there, or pass it explicitly:

  claude-sandbox <your-project-dir>

If you meant to work on the plugin source that lives there, work from a
clone outside it. That directory is not necessarily a repository root, so
clone the repository that contains it - not the directory itself:

  git clone --no-hardlinks <repository-root> <your-clone-dir>};
    }

    if ($reason eq 'user-configured') {
        return q{Open the specific project directory you meant to work in - cd into it and run
claude-sandbox there, or pass it explicitly:

  claude-sandbox <your-project-dir>

If that entry was added by mistake, remove it from
~/.claude/ccpraxis-protected-paths.json - your real home directory, which is the
only place this list is read from (CLAUDE_CONFIG_DIR does not relocate it).};
    }

    return q{Open the specific project directory you meant to work in - cd into it and run
claude-sandbox there, or pass it explicitly:

  claude-sandbox <your-project-dir>};
}

sub _pp_message {
    my ($target, $reason, $root, $relation) = @_;

    my $explanation = _pp_explanation($reason);
    my $advice      = _pp_advice($reason, $root);
    my $no_override = q{There is no override: no flag and no environment variable will make
claude-sandbox act on this path. If this refusal is wrong, the guard itself
has to be fixed - see plugins/sandbox/docs/protected-paths.md.};

    my $header;
    my $body;
    if (exists $_PP_SELF_NOUN{$reason}) {
        $header = 'claude-sandbox will not sandbox ' . $_PP_SELF_NOUN{$reason} . ':';
        my $reason_label = '  ' . 'reason' . (' ' x 9) . ': ';
        $body = "\n  " . $target . "\n\n"
              . $reason_label . $reason . "\n";
    } else {
        $header = 'claude-sandbox will not sandbox a protected path:';
        my $root_label     = '  ' . 'protected root' . ' : ';
        my $relation_label = '  ' . 'relation' . (' ' x 7) . ': ';
        my $reason_label   = '  ' . 'reason' . (' ' x 9) . ': ';
        my $phrase = $_PP_RELATION_PHRASE{$relation} // $relation;
        $body = "\n  " . $target . "\n\n"
              . "That path collides with something Claude Code has installed on this machine:\n\n"
              . $root_label . $root . "\n"
              . $relation_label . $phrase . "\n"
              . $reason_label . $reason . "\n";
    }

    return $header . "\n" . $body . "\n"
         . $explanation . "\n\n"
         . $advice . "\n\n"
         . $no_override . "\n\n"
         . 'Aborting.';
}

# One sanitised line per broken source, capped at 10 + one overflow line.
# Does NOT append the "still enforcing" trailer -- callers must append that
# themselves, exactly once, as the LAST warning after every other warning
# (including any unnormalizable-target warning) has already been pushed, per
# the reviewer MINOR fix (AC-63): the trailer must always be last, even when
# it collides with the unnormalizable-target case.
sub _pp_source_warnings {
    my ($errors) = @_;
    my @warnings;
    my $shown = 0;
    for my $e (@$errors) {
        last if $shown >= 10;
        push @warnings, 'claude-sandbox: WARNING: protected-path source ['
            . _pp_sanitize($e->{code}) . ']: ' . _pp_sanitize($e->{detail});
        $shown++;
    }
    if (@$errors > 10) {
        my $more = scalar(@$errors) - 10;
        push @warnings, "claude-sandbox: WARNING: ... and $more more protected-path source problem(s).";
    }
    return @warnings;
}

sub _pp_enforcing_line {
    my ($root_count) = @_;
    return "claude-sandbox: the protected-path guard is still enforcing the $root_count protected root(s) it did resolve; a failed source never relaxes it.";
}

sub protected_path_outcome {
    my ($target, $opts) = @_;
    $opts //= {};

    my $pr    = protected_roots($opts);
    my @roots = @{ $pr->{roots} };

    # CRITICAL-1(a): an env-independent 'ccpraxis-install' root. The registry
    # already contributes one (ProtectedPaths.pm's own live_install_dir()
    # call), but that source vanishes whenever the registry is unreadable or
    # redirected. live_install_hint, when supplied, adds the same reason
    # code from the launcher's own abs_path(__FILE__)-derived anchor, in
    # ADDITION to whatever the registry resolved -- deduped so an identical
    # registry-derived root is never reported twice.
    if (defined $opts->{live_install_hint} && length $opts->{live_install_hint}) {
        my $hint_n = normalize_path($opts->{live_install_hint});
        if (defined $hint_n) {
            # Item 5 (D5): route the hint through the same bare-root / home
            # rejection guard every other candidate root gets at ingestion
            # (protected_roots' own resolve -> reject -> dedup -> sort
            # pipeline) before it is ever admitted -- reusing
            # target_self_codes, the very primitive the module itself uses
            # to answer "is this path a bare root, or exactly the user's
            # home", so the two checks can never diverge. Without this, a
            # hint of '/' or of the user's home was admitted with no
            # rejection at all and would refuse essentially every target.
            # (Resolution is deliberately not repeated here: $hint_n is the
            # launcher's own abs_path(__FILE__) anchor, already resolved
            # before it ever reaches this sentinel region, which must never
            # touch the filesystem directly.)
            my $hint_self_codes = target_self_codes($hint_n, $opts);
            unless (@$hint_self_codes) {
                my $dup = grep { $_->{reason} eq 'ccpraxis-install' && $_->{path} eq $hint_n } @roots;
                unless ($dup) {
                    push @roots, { path => $hint_n, reason => 'ccpraxis-install' };
                    @roots = sort {
                        ($_PP_REASON_RANK{$a->{reason}} // 99) <=> ($_PP_REASON_RANK{$b->{reason}} // 99)
                            || $a->{path} cmp $b->{path}
                    } @roots;
                }
            }
        }
    }

    my @errors   = @{ $pr->{errors} // [] };
    my @warnings = _pp_source_warnings(\@errors);

    my $result;

    my $codes = target_self_codes($target, $opts);
    if (@$codes) {
        my $reason = $codes->[0];
        $result = {
            refuse    => 1,
            reason    => $reason,
            root      => undef,
            relation  => undef,
            message   => _pp_message($target, $reason, undef, undef),
            exit_code => 1,
        };
    } elsif (!defined normalize_path($target)) {
        push @warnings,
            'claude-sandbox: WARNING: protected-path guard could not normalize the target path; it was not checked against any protected root.';
        $result = {
            refuse    => 0,
            reason    => undef,
            root      => undef,
            relation  => undef,
            message   => undef,
            exit_code => 1,
        };
    } else {
        my %CLASS = ( exact => 0, descendant => 1, ancestor => 2 );
        my ($best_class, $best_root, $best_rel);
        for my $candidate (@roots) {
            my $rel = path_relation($target, $candidate->{path}, $opts);
            next if $rel eq 'unrelated';
            my $class = $CLASS{$rel};
            if (!defined $best_class || $class < $best_class) {
                ($best_class, $best_root, $best_rel) = ($class, $candidate, $rel);
            }
        }

        if (!defined $best_root) {
            $result = {
                refuse    => 0,
                reason    => undef,
                root      => undef,
                relation  => undef,
                message   => undef,
                exit_code => 1,
            };
        } else {
            $result = {
                refuse    => 1,
                reason    => $best_root->{reason},
                root      => $best_root->{path},
                relation  => $best_rel,
                message   => _pp_message($target, $best_root->{reason}, $best_root->{path}, $best_rel),
                exit_code => 1,
            };
        }
    }

    push @warnings, _pp_enforcing_line(scalar @roots) if @errors;
    $result->{warnings} = \@warnings;
    return $result;
}
# <<< q03:protected-path-decision:END

# CRITICAL-1(b): the authoritative-home value that closes the
# `HOME=/tmp/decoy claude-sandbox ~/.claude` bypass (redteam CRITICAL-1). This
# reads the real OS-level home-directory record (getpwuid), independent of
# whatever the process environment claims HOME is. POSIX-only: getpwuid is
# unimplemented on native Windows perl, so this is a guarded no-op there and
# the seam falls back to the existing $ENV{HOME}-driven behaviour untouched.
my $CCPRAXIS_AUTH_HOME = eval {
    # Item 2 (D5, the highest-severity finding): a separate, named predicate
    # for the getpwuid capability, keyed on $^O eq 'MSWin32' ALONE -- never on
    # the broad Windows-family predicate, which also matches cygwin and msys.
    # getpwuid is unimplemented only on NATIVE Windows perl; it IS implemented
    # under cygwin and msys, and Git-for-Windows perl -- how this project
    # actually runs on Windows -- is msys. Gating on the broad family switched
    # this mitigation off precisely on the host it was written for.
    #
    # Deliberately self-contained, referencing no outer lexical, so this block
    # stays extractable and independently testable by $^O alone. t/56's C4
    # asserts structurally that the family predicate's NAME does not appear
    # here at all, so do not reintroduce it even in a comment.
    my $getpwuid_capable = $^O ne 'MSWin32';
    if (!$getpwuid_capable) {
        undef;
    } else {
        my @pw = getpwuid($<);
        (@pw && defined $pw[7] && length $pw[7]) ? $pw[7] : undef;
    }
};
$CCPRAXIS_AUTH_HOME = undef if $@;

# Item 3 (D5): re-derive $CLAUDE_HOST_CONFIG THROUGH THE SEAM here, so a
# redirected HOME or USERPROFILE cannot move the registry_path/extra_list_path
# keys built from it below -- registry_path and extra_list_path used to be
# literals built from $CLAUDE_HOST_CONFIG (itself computed from raw $HOME,
# before this seam even existed), so $CCPRAXIS_AUTH_HOME never applied to
# them and redirecting HOME still dropped every marketplace-install /
# marketplace-source root and the user's own extra list. Falls back to the
# existing $CLAUDE_HOST_CONFIG value when no authoritative home is available
# (e.g. native Windows perl, where getpwuid is a no-op) -- unchanged
# behaviour there.
$CLAUDE_HOST_CONFIG = do {
    my $h = _pp_env_seam(\%ENV, $CCPRAXIS_AUTH_HOME)->('HOME');
    defined $h && length $h ? "$h/.claude" : $CLAUDE_HOST_CONFIG;
};

# Item 4 (D5) -- RULING REVERSED 2026-08-03 after reading q04's recorded
# reasoning. q05's ledger framed this as "a documented contract the code does
# not honour": the help text promises the extra list at
# ${CLAUDE_CONFIG_DIR:-~/.claude}/ccpraxis-protected-paths.json while the code
# pins it to the authoritative home. The first fix here honoured
# CLAUDE_CONFIG_DIR. That was WRONG, and t/53 caught it (AC-57, AC-58).
#
# ProtectedPaths.pm records the opposite decision, with measurements: a
# directory named VERBATIM by a single environment variable is NOT a trusted
# source, so CLAUDE_CONFIG_DIR and USERPROFILE were deliberately dropped from
# the source set, because trusting them "re-opened the hole q03 closed by
# pinning extra_list_path" and additionally caused a C6 regression that
# refused a legitimate ccpraxis clone for an ordinary user with no attacker
# involved.
#
# The reasoning that made honouring it look safe was that the extra list is
# add-only, so it can only ever ADD refusals. That is true of the list's
# CONTENTS and false of its LOCATION: redirecting WHERE the list is read from
# means the user's real list is never read at all -- fewer protected roots,
# fewer refusals, failing OPEN. That is exactly the "silently void the user
# list" failure q03's Decision #5 pinned this path to prevent.
#
# So the code is right and the PROMISE is what was wrong. The help text and
# docs/protected-paths.md are corrected instead; the path stays pinned to the
# authoritative home, which item 3 above now derives through the seam.
#
# Kept as a LITERAL in the call block below rather than hoisted into a
# variable: t/53's AC-57 and AC-58 read the call block's own text to prove
# both keys are pinned to the same authoritative-home prefix, and a variable
# defeats that check even when the value is identical. The pin is meant to be
# visible at the call site.

{
    my $pp = protected_path_outcome($PROJECT_PATH, {
        registry_path     => "$CLAUDE_HOST_CONFIG/plugins/known_marketplaces.json",
        extra_list_path   => "$CLAUDE_HOST_CONFIG/ccpraxis-protected-paths.json",
        live_install_hint => $LIVE_CCPRAXIS_ROOT,
        env               => _pp_env_seam(\%ENV, $CCPRAXIS_AUTH_HOME),
    });
    print STDERR $_, "\n" for @{ $pp->{warnings} };
    if ($pp->{refuse}) {
        print STDERR $pp->{message}, "\n";
        exit($pp->{exit_code} || 1);
    }
    # not refused -> fall through to the workcopy_route fail-safe (R2) below
}

{
    my $route = workcopy_route($PROJECT_PATH, { registry_path => "$HOST_PLUGINS_DIR/known_marketplaces.json", live_install_hint => $LIVE_CCPRAXIS_ROOT });
    if ($route eq 'offer') {
        my $o = workcopy_refusal_outcome({
            path      => $PROJECT_PATH,
            live_root => $LIVE_CCPRAXIS_ROOT,
        });
        print STDERR $o->{message}, "\n";
        exit($o->{exit_code} || 1);
    }
    # 'passthrough' → fall through to existing launch flow unchanged
}

# The project carries a SINGLE ccpraxis data dir at its root:
# <project>/.ccpraxis-local-data/ (self-gitignored via an inner .gitignore=*).
# The sandbox's container-home projection (bind source for /root/.claude) lives
# under it at claude-home/ — historically this was <project>/.claude-data/, now
# migrated in (see the migration block below). Everything the sandbox persists
# (sessions, credentials, launcher metadata, logs, beacons) is nested under
# $CLAUDE_DATA, exactly as it was under .claude-data — only the parent changed.
my $CCPRAXIS_DATA            = "$PROJECT_PATH/.ccpraxis-local-data";
my $CLAUDE_DATA              = "$CCPRAXIS_DATA/claude-home";
my $LAUNCHER_DIR              = "$CLAUDE_DATA/.launcher";
my $SELECTION_FILE            = "$LAUNCHER_DIR/selected-skills.json";
my $MANIFEST_FILE             = "$LAUNCHER_DIR/container-manifest.json";
my $SNAPSHOT_FILE             = "$LAUNCHER_DIR/.discovery-snapshot.json";
my $PLUGINS_SNAPSHOT_FILE     = "$LAUNCHER_DIR/.plugins-snapshot.json";
my $MCP_SNAPSHOT_FILE         = "$LAUNCHER_DIR/.mcp-snapshot.json";
my $SETTINGS_LOCAL_FILE       = "$PROJECT_PATH/.claude/settings.local.json";
# installed_plugins.json lives under claude-home/plugins/ (Fix 2), NOT
# .launcher/ — so it appears at /root/.claude/plugins/installed_plugins.json as
# a REAL RW file through the parent claude-home bind, exactly like
# known_marketplaces.json below. Claude Code rewrites it (write-tmp + rename)
# when a plugin is installed INSIDE the sandbox; a single-file RO bind couldn't
# accept that. The launcher re-materializes it each launch, merge-preserving
# sandbox-added entries (see cmd_materialize_plugins).
my $MATERIALIZED_PLUGINS_FILE = "$CLAUDE_DATA/plugins/installed_plugins.json";
# .credentials.json lives at claude-home/ (the RW dir bind), NOT inside
# .launcher/ — so it appears at /root/.claude/.credentials.json as a REAL
# file through the parent claude-home bind, not as a single-file mount.
# Why it can't be a single-file bind: on Linux you cannot rename() over a
# single-file bind mountpoint (EBUSY), and BOTH Claude Code and butler's
# token-keeper persist an OAuth refresh with the atomic temp+rename pattern.
# A single-file overlay rejected that rename, so a refreshed token could
# never be saved — the on-disk token went stale and forced a relaunch. As a
# real file inside the RW dir bind, both in-place and rename writes land, so
# in-container token refresh persists with no relaunch.
my $SANDBOX_CREDENTIALS_FILE  = "$CLAUDE_DATA/.credentials.json";
# known_marketplaces.json lives under claude-home/plugins/ (NOT .launcher/)
# so it appears at /root/.claude/plugins/known_marketplaces.json as a real
# file through the parent claude-home bind — not as a single-file mount.
# Claude Code rewrites the file with write-tmp + rename on every load; a
# file-level bind would reject the rename with EROFS. The parent-bind
# approach lets the rename land naturally; the launcher regenerates the
# file on every launch so in-container mutations are ephemeral, which
# matches the desired "no marketplace state leaks across runs" posture.
my $MATERIALIZED_MARKETPLACES_FILE = "$CLAUDE_DATA/plugins/known_marketplaces.json";
# Fix 2 host-tier copy-plan manifests (live in .launcher/, RO in the container).
# skills.pl writes them: which selected-plugin code dirs + marketplace metadata
# dirs the launcher copied into claude-home this launch. The launcher reads the
# PRIOR manifest to reconcile (remove what it placed before that's gone now ->
# no zombies) and the NEW one to copy the current set; materialize reads the
# plugins manifest back as merge provenance (sandbox-installed vs deselected).
my $PLUGINS_COPY_MANIFEST      = "$LAUNCHER_DIR/.host-tier-plugins.json";
my $MARKETPLACES_COPY_MANIFEST = "$LAUNCHER_DIR/.host-tier-marketplaces.json";
# Container CLAUDE.md and settings.json: per-project copies (blueprint
# model). Container can modify these freely; changes never propagate
# back to ccpraxis. Drift from upstream is detected via stored hash;
# user picks rebuild to refresh.
my $CONTAINER_CLAUDE_MD       = "$LAUNCHER_DIR/container-CLAUDE.md";
my $CONTAINER_SETTINGS_JSON   = "$LAUNCHER_DIR/container-settings.json";
my $CLAUDE_MD_HASH_FILE       = "$LAUNCHER_DIR/.container-CLAUDE-md-hash";
my $SETTINGS_HASH_FILE        = "$LAUNCHER_DIR/.container-settings-json-hash";
my $LOCK_DIR                  = "$LAUNCHER_DIR/.launcher.lock";

# B1: per-launch diagnostic log. Opened just after the lock is acquired (below);
# declared here so the signal handlers / END block can close it. log_ev() is a
# no-op until the log is open and never throws — instrumentation must not be able
# to take down the launcher it instruments.
my $LAUNCH_LOG;
my $LAUNCH_ID = strftime("%Y%m%dT%H%M%SZ", gmtime()) . "-$$";
sub log_ev { LaunchLog::event($LAUNCH_LOG, @_) }

# s17-statusline-and-output-hygiene (spec S3): file-scope so BOTH the
# enter_dashboard raw-mode closures AND the file-scope $SIG{INT}/$SIG{TERM}/
# END handlers below can restore the process's own STDERR -- including on
# the signal/abnormal-exit path, not only the clean leave_raw path.
my $STDERR_CAPTURE_SAVED;   # dup'd original STDERR filehandle, while redirected
my $STDERR_CAPTURE_FH;      # File::Temp filehandle currently receiving STDERR
my $STDERR_CAPTURE_PATH;    # File::Temp path currently receiving STDERR

# s13-activity-history: read-side caps for aggregating recent activity across
# restarts. See LaunchLog::recent_logs / merge_sessions and _history_events
# (below) for how these compose (spec S2.4a / S2.6).
my $HISTORY_LOG_FILES      = 5;    # prior launch logs consulted
my $HISTORY_TAIL_LINES     = 200;  # lines tailed from EACH prior log (bumped from 50: a
                                    # heartbeat-noise filter removes lines before the
                                    # events/file cap applies, so more raw lines must be
                                    # read to reach 10 real events; _tail_lines' own 128 KB
                                    # cap still bounds worst-case per-file I/O)
my $HISTORY_EVENTS_PER_LOG = 10;   # parsed events kept from EACH prior log
my $ACTIVITY_EVENT_MAX     = 50;   # total events handed to state.events (unchanged ceiling)
my $HISTORY_SPAN_TEXT_MAX  = 200;  # bytes-per-span clamp applied to HISTORY rows only

# s16-fleet-event-source: read-side caps for the active blueprint run's
# orchestrator.log, mirroring the $HISTORY_* idiom immediately above.
my $ORCH_TAIL_LINES        = 200;  # lines tailed from orchestrator.log per tick
my $ORCH_EVENTS_PER_LOG    = 10;   # parsed events kept from orchestrator.log per tick

# s17-statusline-and-output-hygiene: the render loop's per-tick container
# poll (podman inspect + two execs) was the only recurring fork on the
# render path, firing every 10s. Lengthened and cached behind this named,
# greppable, tunable constant rather than a bare literal (spec S4) --
# bounded to <=120s so a container state change is still reflected within
# one poll interval; "poll never" is not a fix.
my $CONTAINER_POLL_SECONDS = 20;

# s17-statusline-and-output-hygiene (spec S5): the ONE heartbeat/tick
# predicate, called from BOTH _history_events (below) and the
# current-session gather closure inside enter_dashboard. Extracted from
# _history_events' former inline regex so the two call sites can never
# drift into independently-maintained copies.
sub _is_heartbeat_line {
    my ($line) = @_;
    return 0 unless defined $line;
    return $line =~ /"type"\s*:\s*"(?:heartbeat|tick)"/ ? 1 : 0;
}

# A non-empty backpack-install warning (set during the setup pass) that the
# dashboard renders as a red alert banner — so a failure isn't lost behind the
# alt-screen the way the pre-dashboard stdout warning is (#20). File-scope so the
# enter_dashboard gather closure (defined far below) sees the value set up here.
my $INSTALL_WARNING = '';

# Full launch transcript (#19): the raw combined stdout/stderr of the heavy
# setup-phase child processes (image build, the backpack summary, the install
# pass) — the scrolling output the structured JSON log can NOT hold. Together
# they are "everything from launch start". Interactive pickers run as their own
# child processes that write straight to the console, so they stay out of the
# transcript by nature; and we stop teeing before the dashboard, so its ANSI
# never pollutes the file.
my $TRANSCRIPT;

# _open_transcript($path) -> fh | undef. Raw bytes (so UTF-8 / André paths pass
# through untouched, like LaunchLog) + autoflushed; parent dir created. undef on
# failure so a transcript problem can never block a launch.
sub _open_transcript {
    my ($path) = @_;
    return undef unless defined $path && length $path;
    (my $dir = $path) =~ s{[\\/][^\\/]+$}{};
    if (length $dir && !-d $dir) {
        require File::Path;
        eval { File::Path::make_path($dir); 1 } or return undef;
    }
    open my $fh, '>:raw', $path or return undef;
    my $old = select($fh); $| = 1; select($old);
    return $fh;
}

# _tx(@msg) — append to the transcript only (no console). No-op without a handle.
sub _tx { return unless $TRANSCRIPT; print {$TRANSCRIPT} @_; }

# _close_transcript — flush + close, tolerant of undef / double-call.
sub _close_transcript { if ($TRANSCRIPT) { close $TRANSCRIPT; undef $TRANSCRIPT; } }

# Whether to colorize the interactive setup phase. Off when stdout isn't a TTY or
# NO_COLOR is set (https://no-color.org). Passed to BackpackReview (the #21 walk
# does its own ANSI); #21 part-A (below) reuses this flag for the launcher's own
# setup-phase status lines.
my $USE_COLOR = (-t STDOUT && !exists $ENV{NO_COLOR}) ? 1 : 0;

# #21 part-A: colorize the launcher's OWN setup-phase status lines so a long
# build/create/backpack scroll reads as navigable sections instead of a flat
# wall. Deliberately NARROW in scope:
#   - NOT the teed podman output (`_tee_system`) — those are podman's own bytes;
#     we pass them through verbatim and never inject SGR into them.
#   - NOT the dashboard — it owns its own raw-ANSI frame after this phase ends.
#   - NOT the transcript — these are plain `print`s that never reach $TRANSCRIPT,
#     so no color code ever lands in the on-disk log.
# All gated on $USE_COLOR, so a non-TTY run / NO_COLOR / a redirect emits the
# exact same bytes as before (tests run non-TTY → zero behavioral change). Codes
# match the BackpackReview palette so the whole setup phase is one visual family.
sub _c { my ($code, $s) = @_; $USE_COLOR ? "\e[${code}m$s\e[0m" : $s }
sub _c_step { _c('1;36', $_[0]) }   # bold cyan  — a build/container phase landmark
sub _c_ok   { _c('32',   $_[0]) }   # green      — a setup step succeeded
sub _c_warn { _c('33',   $_[0]) }   # yellow     — a WARNING: label
sub _c_err  { _c('1;31', $_[0]) }   # bold red   — an ERROR: label

# B5 keep-awake holder (set up in enter_dashboard). File-scope so the signal/END
# teardown can release the wake-lock — a leaked PowerShell helper would keep the
# machine awake forever. Release is idempotent + tolerant of an unset holder.
my $KEEPAWAKE;
sub _keepawake_release_global { eval { $KEEPAWAKE->release if $KEEPAWAKE }; }

# _tee_system(@cmd) — run @cmd streaming its combined stdout+stderr LIVE to the
# console AND into the transcript. system()-style return value ($? convention:
# 0 ok, child exit = rc>>8). Falls back to a plain system() when there is no
# transcript or the fork/pipe can't be opened, so capture never blocks a launch.
sub _tee_system {
    my @cmd = @_;
    return system(@cmd) unless $TRANSCRIPT;
    my $pid = open(my $ph, '-|');
    return system(@cmd) unless defined $pid;   # fork/pipe failed -> uncaptured run
    if (!$pid) {                               # child: merge stderr, exec the cmd
        open(STDERR, '>&', \*STDOUT);
        # _exit (not exit) on exec failure: skip END so we don't double-close the
        # parent's log/transcript handles inherited across the fork.
        exec { $cmd[0] } @cmd
            or do { print STDERR "exec failed: $cmd[0]: $!\n"; POSIX::_exit(127); };
    }
    local $| = 1;
    while (my $line = <$ph>) { print STDOUT $line; print {$TRANSCRIPT} $line; }
    close $ph;
    return $?;
}

# ensure_ccpraxis_data_dir — the project's single ccpraxis data root exists and
# self-gitignores (inner .gitignore = '*', matching steward/blueprint onboard).
# Idempotent; never clobbers an existing .gitignore (butler/blueprint may own it).
sub ensure_ccpraxis_data_dir {
    make_path($CCPRAXIS_DATA) unless -d $CCPRAXIS_DATA;
    my $gi = "$CCPRAXIS_DATA/.gitignore";
    unless (-f $gi) {
        if (open my $g, '>', $gi) { print $g "*\n"; close $g }
    }
}

# =====================================================================
# One-time migration: .claude-data -> .ccpraxis-local-data/claude-home
# =====================================================================
#
# The per-project sandbox home used to live at <project>/.claude-data so the
# project root carried TWO ccpraxis data dirs (.claude-data + the blueprint
# .ccpraxis-local-data). It now nests under the single .ccpraxis-local-data.
# Move the whole tree intact on first launch after the change — this preserves
# sessions, credentials, memories, plans (an in-FS rename, atomic + instant).
# Runs before any container/bootstrap decision so the rest of the launch sees
# only the new location.
{
    my $old = "$PROJECT_PATH/.claude-data";
    if (-d $old && ! -d $CLAUDE_DATA) {
        ensure_ccpraxis_data_dir();

        # A container created against the OLD .claude-data path keeps a
        # bind-mount handle on that directory. On Windows the podman machine
        # holds that handle alive until the container is REMOVED — merely
        # stopping it is not enough — so the atomic rename below fails with
        # EACCES ("Permission denied") even when nothing is "running". That
        # container is about to be invalidated anyway (its mount source is
        # moving out from under it), so reap it first. The one case we must
        # NOT touch is a *running* container: that's a live session, so we
        # bail and tell the user to close it instead of killing it.
        {
            my $name = _read_file("$old/.launcher/container-name");
            chomp $name if defined $name;
            $name = '' unless defined $name;
            unless (length $name) {
                $name = "claude-${PROJECT_NAME}-"
                      . substr(md5_of_string($PROJECT_PATH), 0, 8);
            }
            if (_container_exists($name)) {
                my $st = `$PODMAN inspect --format '{{.State.Status}}' "$name" 2>/dev/null`;
                chomp $st if defined $st;
                $st = '' unless defined $st;
                if ($st eq 'running') {
                    print STDERR "ERROR: a sandbox container ($name) is running and still bind-mounts\n";
                    print STDERR "       the old .claude-data, which blocks the one-time migration to\n";
                    print STDERR "       .ccpraxis-local-data/claude-home. Close its dashboard / session\n";
                    print STDERR "       first, then re-run.\n";
                    reset_terminal();
                    exit 1;
                }
                # Stopped / exited / created: safe to remove. Only the
                # container's ephemeral writable layer goes; the host-bound
                # data tree (the thing we're about to move) is untouched, and
                # the next launch recreates the container against the new path.
                print _c_step("Reaping stale container holding the old data dir: $name ($st)"), "\n";
                system($PODMAN, 'rm', '-f', $name);
                log_ev('migrate_reap_container', { container => $name, state => $st });
            }
        }

        if (rename($old, $CLAUDE_DATA)) {
            print _c_ok("Migrated sandbox home: $old -> $CLAUDE_DATA"), "\n";
            log_ev('migrate_claude_data', { from => $old, to => $CLAUDE_DATA });
        } else {
            print STDERR "ERROR: could not migrate $old -> $CLAUDE_DATA: $!\n";
            print STDERR "       Something holds a handle on the old .claude-data so it can't be\n";
            print STDERR "       moved. The usual culprit is another editor or Claude Code session\n";
            print STDERR "       open on THIS project folder — its recursive file-watcher keeps a\n";
            print STDERR "       handle on the directory (a running sandbox, a shell whose cwd is\n";
            print STDERR "       inside it, or a file indexer do the same). Close it, then re-run.\n";
            print STDERR "       (Or move it by hand once nothing holds it:\n";
            print STDERR "         mv '$old' '$CLAUDE_DATA')\n";
            reset_terminal();
            exit 1;
        }
    }
}

# =====================================================================
# Bootstrap path (no sandbox home yet)
# =====================================================================
#
# Ask the user whether to set up a new sandbox; on confirm, run the
# perl-driven bootstrap (no agent in the loop). After it returns,
# verify the sandbox home was created and continue into the normal
# launch flow.

if (! -d $CLAUDE_DATA) {
    print "\n";
    print "==============================================================\n";
    print "  No sandbox found in this project.\n";
    print "==============================================================\n";
    print "\n";
    print "Set up a new sandbox for this project? [Y/n]: ";
    my $ans = <STDIN>;
    chomp $ans if defined $ans;
    if (defined $ans && length $ans && lc(substr($ans, 0, 1)) eq 'n') {
        print "Aborted by user.\n";
        reset_terminal();
        exit 0;
    }
    chdir $PROJECT_PATH or die "chdir $PROJECT_PATH: $!\n";
    my $bootstrap_pl = "$SANDBOX_PLUGIN/scripts/bootstrap.pl";
    unless (-f $bootstrap_pl) {
        print STDERR "ERROR: $bootstrap_pl not found - reinstall ccpraxis.\n";
        reset_terminal();
        exit 1;
    }
    my $rc = system($^X, $bootstrap_pl, '--project-path', $PROJECT_PATH);
    if ($rc != 0) {
        print STDERR "Bootstrap failed (exit @{[$rc >> 8]}). Aborting.\n";
        reset_terminal();
        exit ($rc >> 8 || 1);
    }
    if (! -d $CLAUDE_DATA) {
        print STDERR "Bootstrap finished but $CLAUDE_DATA not found. Aborting.\n";
        reset_terminal();
        exit 1;
    }
}

# =====================================================================
# Ensure launcher metadata dir
# =====================================================================

make_path($LAUNCHER_DIR) unless -d $LAUNCHER_DIR;

# =====================================================================
# Cross-process lock (per-project)
# =====================================================================
#
# Acquire via atomic mkdir; cleanup on signals + END.
# The lock serializes setup flow. When a container is already running
# for this project, we attach directly without lock contention worth
# noting — but the lock still wraps the TUI + post-TUI work here.

sub _rmtree {
    my $path = shift;
    return unless -e $path;
    require File::Path;
    File::Path::remove_tree($path, { safe => 1, error => \my $err });
    # Best-effort; ignore residual errors.
}

# Signal handlers + END block — exec at the end skips these, so every
# exec path calls SandboxLock::release explicitly before exec.
# release_all() frees BOTH the per-project lock AND the global image-build
# lock if it happens to be held at signal time.
# s17: each of INT/TERM/END also restores STDERR (open() back onto the
# dup'd original filehandle) if enter_raw had it redirected -- the
# signal/abnormal-exit path must not leave the terminal with a redirected
# STDERR after the dashboard closes.
$SIG{INT}  = sub { open(STDERR, '>&', $STDERR_CAPTURE_SAVED) if $STDERR_CAPTURE_SAVED; log_ev('signal', { sig => 'INT' });  _keepawake_release_global(); LaunchLog::close_log($LAUNCH_LOG); _close_transcript(); SandboxLock::release_all(); reset_terminal(); exit 130 };
$SIG{TERM} = sub { open(STDERR, '>&', $STDERR_CAPTURE_SAVED) if $STDERR_CAPTURE_SAVED; log_ev('signal', { sig => 'TERM' }); _keepawake_release_global(); LaunchLog::close_log($LAUNCH_LOG); _close_transcript(); SandboxLock::release_all(); reset_terminal(); exit 143 };
END { open(STDERR, '>&', $STDERR_CAPTURE_SAVED) if $STDERR_CAPTURE_SAVED; _keepawake_release_global(); LaunchLog::close_log($LAUNCH_LOG); _close_transcript(); SandboxLock::release_all() }

SandboxLock::acquire($LOCK_DIR, windows => $WINDOWS_FAMILY) or do {
    print STDERR "ERROR: another claude-sandbox is doing setup for this project (lock held > 10s at $LOCK_DIR).\n";
    print STDERR "       If you're sure no other launcher is running, delete the lock dir and retry.\n";
    reset_terminal();
    exit 1;
};

# B1: open the per-launch log now that the lock is held. Best-effort — a failure
# leaves $LAUNCH_LOG undef and every log_ev() becomes a no-op (the launch still
# runs; it just isn't logged). Manager and connector invocations are separate
# processes, each with its own uniquely-named log file (no double-open).
$LAUNCH_LOG = LaunchLog::open_log("$CLAUDE_DATA/sandbox-logs/launch-$LAUNCH_ID.log");
log_ev('launch_start', { project => $PROJECT_PATH, project_name => $PROJECT_NAME, podman => $PODMAN, pid => $$ });

# Companion raw-output transcript (#19): the build/install console stream the JSON
# log can't hold. Best-effort, same naming as the JSON log (.transcript.log).
$TRANSCRIPT = _open_transcript("$CLAUDE_DATA/sandbox-logs/launch-$LAUNCH_ID.transcript.log");
_tx("=== claude-sandbox launch $LAUNCH_ID - $PROJECT_PATH ===\n");

# =====================================================================
# Get host Claude Code version
# =====================================================================

my $HOST_VERSION = '';
{
    my $out = `claude --version 2>/dev/null`;
    if (defined $out && length $out) {
        ($HOST_VERSION) = split /\s+/, $out;
        $HOST_VERSION //= '';
    }
}

# =====================================================================
# Hash helpers (MD5 via core Digest::MD5; no md5sum dependency)
# =====================================================================

sub md5_of_file {
    my $path = shift;
    open my $fh, '<:raw', $path or die "md5_of_file: open $path: $!\n";
    my $ctx = Digest::MD5->new;
    $ctx->addfile($fh);
    close $fh;
    return $ctx->hexdigest;
}

sub md5_of_string {
    my $s = shift;
    return Digest::MD5->new->add($s)->hexdigest;
}

sub containerfile_hash {
    # Hash the Containerfile AND every file it COPYs into the image, so editing a
    # build input (e.g. the entrypoint script heartbeat.sh) triggers a rebuild on
    # the next launch. Hashing only the Containerfile would let a changed
    # heartbeat.sh ship stale in a cached image.
    my $parts = md5_of_file("$CONTAINER_CONFIG/Containerfile");
    for my $f ('heartbeat.sh') {
        my $p = "$CONTAINER_CONFIG/$f";
        $parts .= ':' . (-f $p ? md5_of_file($p) : 'absent');
    }
    return md5_of_string($parts);
}

sub launcher_hash {
    # Hash the perl script that actually drives the launch — the .sh/.ps1
    # shims contain no behavior worth detecting drift on (changing a shim
    # error message doesn't affect what lands in the container). Existing
    # per-project hash files (which were based on the old fat .sh + .ps1)
    # will mismatch once and trigger a one-time staleness prompt; after
    # rebuild the new hash is saved and drift detection stabilizes.
    my $ctx = Digest::MD5->new;
    open my $fh, '<:raw', "$SANDBOX_PLUGIN/scripts/launcher.pl"
        or return '';
    $ctx->addfile($fh);
    close $fh;
    return $ctx->hexdigest;
}

# =====================================================================
# Mount-spec helpers
# =====================================================================
#
# MSYS2 (Git-for-Windows perl) silently mangles any argv element that
# contains `:` — it treats the value as a POSIX PATH-list, splits on `:`,
# runs each side through POSIX→Windows conversion, and re-joins with `;`.
# So `-v HOST:CONTAINER` becomes `HOST_winpath;C:\?\CONTAINER_winpath` and
# podman bind-mounts a `;C`-suffixed phantom path. The env-var disable
# (MSYS2_ARG_CONV_EXCL=*) only matches argv values literally starting with
# `*`, which is useless here.
#
# Fix: emit mount specs in podman's `--mount` syntax. Commas and `=`
# separate fields instead of `:`, and the value starts with `type=` which
# MSYS2 won't recognize as a path-like arg → no conversion attempt. All
# existing call sites continue to push `'-v', 'HOST:CONTAINER[:opts]'`
# into the args list (that's still the most readable form to author); we
# rewrite the whole list right before `system(@args)` via
# `convert_v_to_mount`. Belt-and-suspenders alongside the env-var guard
# and the runtime `;C` corruption detector.

# v_to_mount + convert_v_to_mount are imported from MountSpec.pm above.

# =====================================================================
# Image build
# =====================================================================

sub build_image {
    print _c_step("Building claude-sandbox image with Claude Code v${HOST_VERSION}..."), "\n";
    log_ev('image_build_start', { version => $HOST_VERSION });
    _tx("\n--- image build (v${HOST_VERSION}) ---\n");
    my $rc = _tee_system($PODMAN, 'build',
        '--build-arg', "CLAUDE_VERSION=${HOST_VERSION}",
        '-t', "claude-sandbox:${HOST_VERSION}",
        '-t', 'claude-sandbox:latest',
        $CONTAINER_CONFIG);
    if ($rc != 0) {
        log_ev('image_build_failed', { exit => $rc >> 8 });
        print STDERR _c_err("ERROR:"), " podman build failed (exit @{[$rc >> 8]}).\n";
        LaunchLog::close_log($LAUNCH_LOG);
        SandboxLock::release($LOCK_DIR);
        reset_terminal();
        exit 1;
    }
    log_ev('image_build_ok', { version => $HOST_VERSION });
    _write_file("$LAUNCHER_DIR/containerfile-hash", containerfile_hash());
}

sub _write_file {
    my ($path, $contents) = @_;
    make_path(dirname($path)) unless -d dirname($path);
    open my $fh, '>:raw', $path or die "write $path: $!\n";
    print $fh $contents;
    close $fh or die "close $path: $!\n";
}

sub _read_file {
    my $path = shift;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

# backpack_review($file, $pl, $approvals_path, $legacy_trust, $file_hash)
#   -> (\@approved_items, $deferred_count)
#
# Thin launcher glue over BackpackReview::review (the testable, I/O-seam-injected
# walk). Wires the launcher's STDIN/STDOUT, color flag, and transcript sink into
# the module. The per-item approval gate proper — content-hash memory, the
# approve/remove/quit-defer dispatch, and the legacy-trust migration — all live
# in BackpackReview.pm + BackpackApproval.pm, where they are unit-tested.
sub backpack_review {
    my ($file, $pl, $approvals_path, $legacy_trust, $file_hash) = @_;
    return BackpackReview::review(
        file         => $file,
        pl           => $pl,
        approvals    => $approvals_path,
        legacy_trust => $legacy_trust,
        file_hash    => $file_hash,
        in           => \*STDIN,
        out          => \*STDOUT,
        use_color    => $USE_COLOR,
        tx           => \&_tx,
    );
}

# Ensure base image exists. Capture instead of redirect — `> /dev/null`
# under cmd.exe (native Win32 perl) wouldn't resolve; backticks with
# `2>&1` discard cleanly on all shells.
# Global cross-project build lock (Decision #9): prevents two launchers from
# simultaneously building the same image. Fail-open: if acquire times out (e.g.
# a crashed previous holder), proceed anyway — a missed lock must never
# permanently block a launch. After acquiring, RE-CHECK the image (the winner
# may have already built it); only build if still missing. release() frees this
# lock; release_all() in END/signals also covers it.
{
    my $build_lock = "$CLAUDE_HOST_CONFIG/ccpraxis/.locks/image-build";
    File::Path::make_path(dirname($build_lock));
    my $got_build_lock = SandboxLock::acquire($build_lock, timeout => 600, windows => $WINDOWS_FAMILY);
    # fail-open: proceed even if !$got_build_lock
    `$PODMAN image inspect claude-sandbox:latest 2>&1`;
    if ($? != 0) {
        build_image();
    }
    SandboxLock::release($build_lock);
}

# =====================================================================
# Container name (generate + persist)
# =====================================================================

my $CONTAINER_NAME;
{
    my $name_file = "$LAUNCHER_DIR/container-name";
    if (-f $name_file) {
        $CONTAINER_NAME = _read_file($name_file);
        chomp $CONTAINER_NAME if defined $CONTAINER_NAME;
        $CONTAINER_NAME //= '';
    }
    if (!length $CONTAINER_NAME) {
        # MAJOR-2: use _container_name_for so container-name lookups and the real
        # launch always agree on the container name for the same path.
        $CONTAINER_NAME = _container_name_for($PROJECT_PATH);
        _write_file($name_file, $CONTAINER_NAME);
    }
}

# =====================================================================
# Early mode dispatch: CONNECTOR / DASHBOARD (Decision #19)
# =====================================================================
#
# `claude-sandbox` (the only user-typed form) ALWAYS lands on the
# dashboard (the live TUI / plain heartbeat loop). The dashboard is the
# manager window: it holds the container alive and exposes a hotkey that
# spawns a NEW window running the internal connector entry
# `claude-sandbox --session` — which is what reaches the CONNECTOR branch
# below. `--resume-session` (used by claude-beacon to resume a specific
# session directly) is also connector mode.
#
# CONNECTOR: skip all setup-time work (skill picker, staleness check,
# plugin materialize, backpack approval, container create/start, rebuild
# prompt) and go straight to: session picker → kill-orphan-claudes →
# exec claude. The manager (dashboard) terminal already made those setup
# choices when it built the container.
{
    my $state = '';
    if (_container_exists($CONTAINER_NAME)) {
        $state = `$PODMAN inspect --format '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null`;
        chomp $state if defined $state;
        $state //= '';
    }

    # redteam H1: re-enforce the shape check HERE, before either fast path
    # below can call ensure_claude_json_onboarded() (via the connector's
    # dashboard requirement, or directly via enter_dashboard()'s
    # bare-attach fast path) and rename() over the shared host config while
    # an old-shape container is still attached — the s01 sec 4 ghost-inode
    # hazard on the ordinary post-upgrade path. The sub re-inspects state
    # itself, so calling it again here (in addition to the :2547 call,
    # which stays for the create/attach decision below) is safe and,
    # on a compliant container, silent. It never returns for a
    # running+violating container (exit 1); it releases $LOCK_DIR itself in
    # that case, matching the connector's own error path just below.
    enforce_container_config_shape($CONTAINER_NAME);

    my $connector_mode = ($SESSION_MODE || length $RESUME_SESSION);

    if ($connector_mode) {
        # Connector requires a manager/dashboard to already be up.
        if ($state ne 'running') {
            print STDERR _c_err("ERROR:"), " no running sandbox to connect to for this project.\n";
            print STDERR "       Run `claude-sandbox` (no flags) to start the sandbox + dashboard first,\n";
            print STDERR "       then launch a claude session from the dashboard.\n";
            SandboxLock::release($LOCK_DIR);
            reset_terminal();
            exit 1;
        }
        print _c_step("Connecting to running sandbox: $CONTAINER_NAME"), "\n";
        SandboxLock::release($LOCK_DIR);
        my @SESSION_FLAGS;
        {
            my ($action, $uuid);
            if (length $RESUME_SESSION) {
                ($action, $uuid) = ('resume', $RESUME_SESSION);
            } else {
                ($action, $uuid) = pick_session_action();
            }
            if ($action eq 'cancel') {
                print "Cancelled.\n";
                reset_terminal();
                exit 0;
            }
            push @SESSION_FLAGS, '--resume', $uuid if $action eq 'resume';
        }
        # Orphan claudes (in-container processes from a prior connector
        # that died without releasing /root/.claude lockfiles) block any
        # new session indefinitely with no error message. Detect + offer
        # to kill before exec'ing the new claude.
        kill_orphan_claudes_if_user_confirms();
        my @cmd = ($PODMAN, 'exec', '-it', $CONTAINER_NAME,
                   'claude', '--dangerously-skip-permissions',
                   @SESSION_FLAGS);
        my $rc = run_claude(@cmd);
        reset_terminal();
        # Fix 3: distinguish a clean user quit from a LOST container (the podman
        # engine or the container died mid-session, dropping the exec). On a
        # loss, hold this window open with an explanation instead of letting the
        # Windows Terminal tab vanish — the conversation is safe on disk, but the
        # user otherwise loses the window with no idea why.
        if (ConnectorHold::should_hold_window($rc, container_status($CONTAINER_NAME))) {
            print ConnectorHold::lost_message($CONTAINER_NAME);
            hold_for_keypress();
        }
        exit $rc;
    }

    # Bare `claude-sandbox` with the container ALREADY running: the manager
    # that built it already did all setup — skip straight to the dashboard.
    # (Holding the setup lock here would needlessly block a real manager, so
    # release it first, exactly as a connector does.)
    if ($state eq 'running') {
        SandboxLock::release($LOCK_DIR);
        enter_dashboard();   # never returns (loops until the user exits)
    }

    # Otherwise the container is missing/stopped: we are the MANAGER. Fall
    # through to setup (image / create / start); it ends by calling
    # enter_dashboard() in place of the old scrolling heartbeat loop.
}

# =====================================================================
# Perl + sandbox-skills.pl invocation helpers
# =====================================================================

sub run_perl_or_die {
    my ($what, @args) = @_;
    my $rc = system($^X, $SANDBOX_SKILLS_PL, @args);
    if ($rc != 0) {
        print STDERR "ERROR: $what (perl exit @{[$rc >> 8]})\n";
        SandboxLock::release($LOCK_DIR);
        reset_terminal();
        exit 1;
    }
}

sub run_perl_to_file {
    my ($what, $output_path, @args) = @_;
    # Capture via backticks (works uniformly across cygwin/msys/linux/Win32).
    # Snapshot files are KB-scale, no streaming concern.
    my $captured = _capture_or_die($what, $^X, $SANDBOX_SKILLS_PL, @args);
    _write_file($output_path, $captured);
}

sub _capture_or_die {
    my ($what, @cmd) = @_;
    # Use IPC::Open3-style capture by piping. Simplest portable: backticks
    # with proper escaping. Building a safe shell command from @cmd is
    # tricky; use qx// with shell-quoted args.
    my $cmdstr = join(' ', map { _shell_quote($_) } @cmd);
    my $captured = `$cmdstr`;
    my $rc = $?;
    if ($rc != 0) {
        print STDERR "ERROR: $what (perl exit @{[$rc >> 8]})\n";
        SandboxLock::release($LOCK_DIR);
        reset_terminal();
        exit 1;
    }
    return defined $captured ? $captured : '';
}

sub _shell_quote {
    my $s = shift;
    return $s if $s =~ /\A[\w.\/:=+-]+\z/;
    # qx// invokes /bin/sh on cygwin/msys/linux/macos and cmd.exe on
    # native Win32 perl. Match the actual shell, not the platform family
    # — cygwin perl is "Windows family" but its backticks use POSIX sh.
    if ($^O eq 'MSWin32') {
        $s =~ s/"/\\"/g;
        return qq{"$s"};
    }
    $s =~ s/'/'\\''/g;
    return "'$s'";
}

# =====================================================================
# Pin discovery snapshots (skills + plugins + MCP)
# =====================================================================
#
# Every subsequent perl invocation reads these frozen views, so a
# concurrent /plugin install in another terminal can't cause inconsistent
# state across our pipeline.

run_perl_to_file('skill discovery snapshot', $SNAPSHOT_FILE,         'discover');
run_perl_to_file('plugin discovery snapshot', $PLUGINS_SNAPSHOT_FILE, 'discover-plugins', '--project-path', $PROJECT_PATH);
run_perl_to_file('MCP discovery snapshot',    $MCP_SNAPSHOT_FILE,    'discover-mcp',     '--project-path', $PROJECT_PATH);

# =====================================================================
# TUI selector (skills + plugins + MCP)
# =====================================================================
#
# Exit codes: 0 = confirmed, 2 = cancelled, other = error.
# The TUI writes selected-skills.json AND the project's
# .claude/settings.local.json. Needs a real TTY on stdin.

{
    my $rc = system($^X, $SANDBOX_SKILLS_PL, 'select-interactive',
        '--selection-file',       $SELECTION_FILE,
        '--discovery-snapshot',   $SNAPSHOT_FILE,
        '--plugins-snapshot',     $PLUGINS_SNAPSHOT_FILE,
        '--mcp-snapshot',         $MCP_SNAPSHOT_FILE,
        '--settings-local-file',  $SETTINGS_LOCAL_FILE,
        '--project-path',         $PROJECT_PATH);
    my $exit = $rc >> 8;
    if ($exit == 2) {
        print "Cancelled.\n";
        SandboxLock::release($LOCK_DIR);
        reset_terminal();
        exit 0;
    }
    if ($exit != 0) {
        print STDERR "ERROR: select-interactive failed (exit $exit)\n";
        SandboxLock::release($LOCK_DIR);
        reset_terminal();
        exit 1;
    }
}

# =====================================================================
# Staleness reasoning
# =====================================================================

my @STALE_REASONS;

# Version mismatch.
if (-f "$LAUNCHER_DIR/claude-version") {
    my $cv = _read_file("$LAUNCHER_DIR/claude-version");
    chomp $cv if defined $cv;
    $cv //= '';
    if (length $cv && $cv ne $HOST_VERSION) {
        push @STALE_REASONS, "  - Claude Code version mismatch: container has v${cv}, host has v${HOST_VERSION}";
    }
}

# Container age (> 7 days).
if (-f "$LAUNCHER_DIR/container-created") {
    my $created_str = _read_file("$LAUNCHER_DIR/container-created");
    chomp $created_str if defined $created_str;
    if (defined $created_str && length $created_str) {
        my $created_epoch = eval {
            # ISO 8601 strict parse; fall back to lenient strptime for older files.
            my $t = Time::Piece->strptime($created_str, "%Y-%m-%dT%H:%M:%S");
            $t->epoch;
        };
        if (defined $created_epoch && $created_epoch > 0) {
            my $age_days = int((time - $created_epoch) / 86400);
            if ($age_days > 7) {
                push @STALE_REASONS, "  - Container is ${age_days} days old (base OS packages may be outdated)";
            }
        }
    }
}

# Containerfile hash drift.
my $CURRENT_DF_HASH = containerfile_hash();
{
    my $saved = _read_file("$LAUNCHER_DIR/containerfile-hash");
    chomp $saved if defined $saved;
    if (!defined $saved || $saved ne $CURRENT_DF_HASH) {
        push @STALE_REASONS, "  - Containerfile has changed since last build";
    }
}

# Launcher hash drift.
my $CURRENT_LAUNCHER_HASH = launcher_hash();
{
    my $saved = _read_file("$LAUNCHER_DIR/launcher-hash");
    chomp $saved if defined $saved;
    if (!defined $saved || $saved ne $CURRENT_LAUNCHER_HASH) {
        push @STALE_REASONS, "  - Launcher scripts have changed since container was created";
    }
}

# Skill/plugin drift (only meaningful if container actually exists).
if (_container_exists($CONTAINER_NAME)) {
    my $div = _skill_divergence_msg();
    if (defined $div && length $div) {
        push @STALE_REASONS, "  - Skills changed since container was created: $div";
    }
}

# Silent podman-inspect for existence check (avoids dumping the
# JSON-formatted "container not found" error or the full inspect
# document to stdout).
sub _container_exists {
    my $name = shift;
    `$PODMAN inspect "$name" 2>&1`;
    return $? == 0;
}

# Row 22 (spec 02-implement-config-safety-spec.md B12-B18, s01 sec 4). An
# ALREADY-CREATED container bakes its `-e`/`-v` shape at `podman create` time
# and keeps it forever; if it still carries the pre-fix single-file bind onto
# /root/.claude.json, an atomic rename() on the host config (the new
# ensure_claude_json_onboarded write path) replaces the inode out from under
# it and that container silently, unrecoverably loses its config. This check
# forces such a container off the old shape before any create/attach/write
# decision is made.

# container_config_shape_violations($name) -> @violations
# Inspects an EXISTING container's baked mounts/env via `podman inspect` and
# runs them through the SAME MountSpec::parse_inspect_lines + audit_claude_home
# pipeline t/02 holds accountable (B17). Fail-open (returns ()) when the
# container doesn't exist, $PODMAN is unset/unusable, or inspect fails or
# emits unparseable output — a tool error must never block a launch (B16).
sub container_config_shape_violations {
    my ($name) = @_;
    return () unless defined $name && length $name;
    return () unless defined $PODMAN && length $PODMAN;
    return () unless _container_exists($name);

    # One MOUNT line per mount and one ENV line per env entry, matching the
    # line shape MountSpec::parse_inspect_lines expects. Podman's default
    # inspect JSON already stores Config.Env entries as "KEY=VALUE" strings,
    # so {{.}} on that range is exactly right.
    my $format = q{{{range .Mounts}}MOUNT {{.Type}} {{.Source}} {{.Destination}} {{.RW}}}
        . qq{\n}
        . q{{{end}}{{range .Config.Env}}ENV {{.}}}
        . qq{\n}
        . q{{{end}}};
    my $out = `$PODMAN inspect --format '$format' "$name" 2>/dev/null`;
    return () if $? != 0;
    return () unless defined $out && length $out;

    my @lines = split /\n/, $out;
    my $parsed = eval { MountSpec::parse_inspect_lines(\@lines) };
    return () if $@ || !$parsed;
    my @violations = eval { MountSpec::audit_claude_home($parsed) };
    return () if $@;
    return @violations;
}

# enforce_container_config_shape($name) -> void
# Non-declinable remediation (B18): NEVER routed through prompt_stale_action
# or @STALE_REASONS — that prompt defaults to "continue" and returns
# "continue" on EOF in every non-interactive launch, which would make this
# fix silently declinable. A compliant or fail-open container is completely
# silent (B15/B16): no output, no log_ev, no recreate.
sub enforce_container_config_shape {
    my ($name) = @_;
    my @violations = container_config_shape_violations($name);
    return unless @violations;

    my @codes = map { $_->{code} } @violations;
    my $st = `$PODMAN inspect --format '{{.State.Status}}' "$name" 2>/dev/null`;
    my $st_ok = ($? == 0);
    chomp $st if defined $st;
    $st = '' unless defined $st;

    # redteam H3: reap (podman rm -f) only on a POSITIVELY CONFIRMED
    # non-running state. The shape inspect above (container_config_shape_
    # violations) deliberately fails OPEN (B16: a tool-error must never
    # block a launch) — this state inspect must fail CLOSED instead,
    # because its failure mode is a non-declinable `podman rm -f`. A
    # transient inspect failure, or an engine phrasing this launcher
    # doesn't recognize (e.g. 'configured', 'paused', 'restarting'), must
    # route to refusal, not to reap.
    if (!$st_ok || $st eq 'running' || $st !~ /\A(?:exited|created|stopped|configured)\z/) {
        # B14: a live (or unconfirmed) session — never kill it. Refuse and
        # tell the user how to unblock, mirroring the migration reaper's
        # running-container refusal (see the .claude-data migration block
        # above).
        print STDERR _c_err("ERROR:"), " sandbox container ($name) still has the old\n";
        print STDERR "       claude.json mount shape (@{[join(', ', @codes)]}) and its\n";
        print STDERR "       running state could not be positively confirmed as safe to\n";
        print STDERR "       remove (status: '@{[$st_ok ? ($st eq '' ? '(empty)' : $st) : 'inspect failed']}'). Continuing risks silent config\n";
        print STDERR "       loss (an atomic rename() over the shared host config would\n";
        print STDERR "       leave a still-attached container following a stale, unlinked\n";
        print STDERR "       inode) or killing a live session. Close its dashboard /\n";
        print STDERR "       session first (or re-run once the container engine responds\n";
        print STDERR "       normally), then re-run.\n";
        log_ev('config_shape_blocked', { container => $name, violations => \@codes, state => $st, state_ok => $st_ok });
        # H1: this sub is now also called from the early-dispatch block,
        # above enter_dashboard()'s fast path, where $LOCK_DIR (the setup
        # lock) is still held. Release it before exiting so a refusal here
        # never wedges every later launch. Matches the connector error
        # path's own release just below in the caller. A no-op (idempotent)
        # when called from the pre-create call site further down, which
        # releases $LOCK_DIR itself later on the normal path.
        SandboxLock::release($LOCK_DIR);
        reset_terminal();
        exit 1;
    }

    # B13: confirmed not running — safe to reap. _container_exists is now
    # false, so the existing create path below rebuilds it with the new
    # shape. No prompt.
    print _c_step("Container config shape is stale ($name, $st): @{[join(', ', @codes)]} — recreating"), "\n";
    system($PODMAN, 'rm', '-f', $name);
    log_ev('config_shape_reap_container', { container => $name, state => $st, violations => \@codes });
    return;
}

# _enumerate_inuse_host_ports($self_name) -> @host_port_integers
#   fix-multiple-running-sandboxes / Decision #2-#3: collect every published
#   HOST port already claimed by an existing claude-sandbox container (running
#   OR stopped), so PortAlloc can floor them to occupied bases and hand this new
#   container a free block. Excludes $self_name (this project's own container,
#   which is about to be created / recreated). Robust to no-podman / empty
#   output (returns an empty list -> next_free_base yields the 9000 base).
sub _enumerate_inuse_host_ports {
    my ($self_name) = @_;
    $self_name = defined $self_name ? $self_name : '';

    # Discover sandbox containers by NAME pattern (claude-<project>-<8 hex>), NOT
    # by `ancestor=claude-sandbox:latest`: after any image rebuild the still-running
    # OLD containers descend from a superseded image id, so the ancestor filter
    # would MISS them and their block would be handed out again -> collision.
    # Name-matching catches them regardless of image; over-matching only wastes a
    # block (harmless, Decision #4), under-matching collides.
    my $names_raw = `$PODMAN ps -a --format "{{.Names}}" 2>/dev/null`;
    return () unless defined $names_raw && length $names_raw;

    my @host_ports;
    for my $name (split /\s+/, $names_raw) {
        next unless length $name;
        next unless $name =~ /^claude-.+-[0-9a-f]{8}$/;   # our sandbox naming
        next if $name eq $self_name;

        # Read the CREATE-time published host ports via `podman inspect` — this is
        # STATE-AGNOSTIC (running AND stopped/exited). `podman port <name>` was
        # WRONG here: it reads the live network namespace and returns EMPTY for a
        # stopped container (verified, podman 5.8.3), so a stopped sibling's block
        # would be invisible and handed out again -> EADDRINUSE on its restart,
        # which Decision #5 then cannot fix. .HostConfig.PortBindings is the
        # persisted -p mapping and survives stop. ($p/$c are Go-template vars —
        # backslash-escaped so Perl does not interpolate them.)
        my $ports_raw = `$PODMAN inspect --format '{{range \$p,\$c := .HostConfig.PortBindings}}{{range \$c}}{{.HostPort}} {{end}}{{end}}' "$name" 2>/dev/null`;
        next unless defined $ports_raw;
        push @host_ports, map { $_ + 0 } ($ports_raw =~ /(\d+)/g);
    }
    return @host_ports;
}

# Container-config blueprint drift (CLAUDE.md + settings.json).
my $CURRENT_CLAUDE_MD_HASH = md5_of_file("$CONTAINER_CONFIG/CLAUDE.md");
my $CURRENT_SETTINGS_HASH  = md5_of_file("$CONTAINER_CONFIG/settings.json");
if (-f $CLAUDE_MD_HASH_FILE) {
    my $saved = _read_file($CLAUDE_MD_HASH_FILE);
    chomp $saved if defined $saved;
    if (defined $saved && $saved ne $CURRENT_CLAUDE_MD_HASH) {
        push @STALE_REASONS, "  - Container CLAUDE.md upstream changed since last sandbox refresh";
    }
}
if (-f $SETTINGS_HASH_FILE) {
    my $saved = _read_file($SETTINGS_HASH_FILE);
    chomp $saved if defined $saved;
    if (defined $saved && $saved ne $CURRENT_SETTINGS_HASH) {
        push @STALE_REASONS, "  - Container settings.json upstream changed since last sandbox refresh";
    }
}

sub _skill_divergence_msg {
    return '' unless -f $SELECTION_FILE;
    my $cmd = join(' ',
        _shell_quote($^X),
        _shell_quote($SANDBOX_SKILLS_PL),
        'diff',
        '--selection-file',     _shell_quote($SELECTION_FILE),
        '--discovery-snapshot', _shell_quote($SNAPSHOT_FILE),
        '--plugins-snapshot',   _shell_quote($PLUGINS_SNAPSHOT_FILE),
        '--project-path',       _shell_quote($PROJECT_PATH),
    );
    my $json = `$cmd 2>/dev/null`;
    return '' if $? != 0;
    return '' unless defined $json && length $json;
    my $d = eval { require JSON::PP; JSON::PP::decode_json($json) };
    return '' unless ref $d eq 'HASH';
    my @parts;
    my $fmt = sub {
        my ($label, $arr) = @_;
        return unless ref $arr eq 'ARRAY' && @$arr;
        push @parts, scalar(@$arr) . " $label (" . join(',', @$arr) . ")";
    };
    $fmt->('skill added',       $d->{added});
    $fmt->('skill removed',     $d->{removed});
    $fmt->('now host-only',     $d->{host_only_changed});
    $fmt->('plugin-path drift', $d->{plugin_path_changed});
    $fmt->('plugin added',      $d->{plugins_added});
    $fmt->('plugin removed',    $d->{plugins_removed});
    $fmt->('plugin path drift', $d->{plugins_path_changed});
    return join('; ', @parts);
}

# =====================================================================
# Rebuild prompt (interactive)
# =====================================================================

if (@STALE_REASONS) {
    my $action = prompt_stale_action(\@STALE_REASONS, $HOST_VERSION);
    if ($action eq 'rebuild') {
        # Remove old container if it exists.
        system($PODMAN, 'rm', '-f', $CONTAINER_NAME);
        # Forced rebuild — acquire the global build lock but skip the re-check
        # (the user explicitly chose rebuild, so we always build regardless of
        # whether a concurrent launcher already built it). Fail-open on timeout.
        {
            my $build_lock = "$CLAUDE_HOST_CONFIG/ccpraxis/.locks/image-build";
            File::Path::make_path(dirname($build_lock));
            SandboxLock::acquire($build_lock, timeout => 600, windows => $WINDOWS_FAMILY);
            build_image();
            SandboxLock::release($build_lock);
        }
        # Refresh per-project container blueprint copies from upstream
        # (plugins/sandbox/container/). Any in-container modifications get
        # overwritten — that's the explicit opt-in semantic of Rebuild.
        _copy_file("$CONTAINER_CONFIG/CLAUDE.md",    $CONTAINER_CLAUDE_MD);
        _copy_file("$CONTAINER_CONFIG/settings.json", $CONTAINER_SETTINGS_JSON);
        _write_file($CLAUDE_MD_HASH_FILE, $CURRENT_CLAUDE_MD_HASH);
        _write_file($SETTINGS_HASH_FILE,  $CURRENT_SETTINGS_HASH);
        # Regenerate container name.
        unlink "$LAUNCHER_DIR/container-name";
        my $path_hash = substr(md5_of_string($PROJECT_PATH), 0, 8);
        $CONTAINER_NAME = "claude-${PROJECT_NAME}-${path_hash}";
        _write_file("$LAUNCHER_DIR/container-name", $CONTAINER_NAME);
    } elsif ($action eq 'cancel') {
        print "Cancelled.\n";
        SandboxLock::release($LOCK_DIR);
        reset_terminal();
        exit 0;
    }
    # else 'continue' — fall through to launch as-is
}

# Arrow-key TUI for the stale-container prompt — matches the visual style
# of the skills/plugins/MCP picker. Single-key shortcuts ('r', 'c', 'q')
# also work. Falls back to a line-read prompt if Term::ReadKey is missing
# or stdin/stdout aren't tty (so CI / non-interactive uses keep working).
sub prompt_stale_action {
    my ($reasons_ref, $host_version) = @_;
    my @reasons = @$reasons_ref;
    my @options = (
        ['rebuild',  "Rebuild — fresh container with Claude Code v$host_version"],
        ['continue', "Continue as-is"],
    );

    # Non-tty / Term::ReadKey unavailable → degrade to a single-line prompt.
    my $have_readkey = eval { require Term::ReadKey; 1 };
    if (!$have_readkey || !-t STDIN || !-t STDOUT) {
        print "\n";
        print "Sandbox may be stale:\n";
        print "$_\n" for @reasons;
        print "\n";
        print "Options:\n";
        print "  [r] $options[0][1]\n";
        print "  [c] $options[1][1]\n";
        print "\n";
        print "Choice [r/c]: ";
        my $line = <STDIN>;
        $line //= '';
        chomp $line;
        my $first = lc(substr($line, 0, 1) // '');
        return 'rebuild' if $first eq 'r';
        return 'cancel'  if $first eq 'q';
        return 'continue';
    }

    my $sel = 0;
    my $printed_lines = 0;

    my $cleanup = sub {
        print "\e[?25h";          # show cursor
        print "\e[0m";             # reset attrs
        eval { Term::ReadKey::ReadMode(0) };
    };
    local $SIG{INT}  = sub { $cleanup->(); reset_terminal(); exit 130 };
    local $SIG{TERM} = sub { $cleanup->(); reset_terminal(); exit 143 };

    Term::ReadKey::ReadMode(4);    # cbreak
    print "\e[?25l";               # hide cursor

    my $render = sub {
        # Move cursor up to redraw in place. \e[NA moves N lines up.
        if ($printed_lines) {
            print "\e[${printed_lines}A";
            print "\e[J";          # clear to end of screen
        }
        my $out = "";
        $out .= "\n";
        $out .= "Sandbox may be stale:\n";
        $out .= "$_\n" for @reasons;
        $out .= "\n";
        for my $i (0 .. $#options) {
            my $label = $options[$i][1];
            if ($i == $sel) {
                $out .= "\e[1;36m  > $label\e[0m\n";
            } else {
                $out .= "    $label\n";
            }
        }
        $out .= "\n";
        $out .= "  up/down: select   enter: confirm   r/c: shortcut   q/esc: cancel\n";
        $printed_lines = () = ($out =~ /\n/g);
        print $out;
    };

    my $result;
    $render->();
    while (1) {
        my $k = Term::ReadKey::ReadKey(0);
        last unless defined $k;
        if ($k eq "\e") {
            my $k2 = Term::ReadKey::ReadKey(0.05);
            if (defined $k2 && $k2 eq '[') {
                my $k3 = Term::ReadKey::ReadKey(0.05);
                if (defined $k3) {
                    if ($k3 eq 'A' && $sel > 0)         { $sel--; $render->(); next }
                    if ($k3 eq 'B' && $sel < $#options) { $sel++; $render->(); next }
                    next;  # other arrow keys: ignore
                }
            }
            $result = 'cancel'; last;
        }
        if ($k eq "\n" || $k eq "\r") { $result = $options[$sel][0]; last }
        if (lc($k) eq 'r') { $result = 'rebuild';  last }
        if (lc($k) eq 'c') { $result = 'continue'; last }
        if (lc($k) eq 'q') { $result = 'cancel';   last }
        if ($k eq "\x03")  { $result = 'cancel';   last }   # Ctrl+C
    }

    $cleanup->();
    print "\n";
    return $result // 'cancel';
}

# =====================================================================
# Container-name helper (shared by the launch path)
# =====================================================================

# _container_name_for($raw_path) -> container name string
# Normalises a path using the SAME sequence the main launch applies to
# $PROJECT_PATH (abs_path -> backslash->slash -> strip trailing slash ->
# winify_path -> lc(basename) -> space->dash) so any container-name lookup
# always matches the name the real podman launch uses for the same
# worktree. Idempotent on already-normalised paths.
sub _container_name_for {
    my ($raw_path) = @_;
    my $p = abs_path($raw_path) // $raw_path;
    $p =~ s|\\|/|g;
    $p =~ s|/+$||;
    $p = winify_path($p);
    my $n = lc(basename($p));
    $n =~ s/ /-/g;
    return "claude-${n}-" . substr(md5_of_string($p), 0, 8);
}

sub _copy_file {
    my ($src, $dst) = @_;
    my $bytes = _read_file($src);
    die "_copy_file: cannot read $src\n" unless defined $bytes;
    _write_file($dst, $bytes);
}

# =====================================================================
# Build skill mounts
# =====================================================================

my @SKILL_MOUNTS;
{
    my $cmd = join(' ',
        _shell_quote($^X),
        _shell_quote($SANDBOX_SKILLS_PL),
        'mounts',
        '--selection-file',     _shell_quote($SELECTION_FILE),
        '--discovery-snapshot', _shell_quote($SNAPSHOT_FILE),
    );
    my $output = `$cmd`;
    if ($? != 0) {
        print STDERR "ERROR: failed to enumerate skill mounts (perl exit @{[$? >> 8]})\n";
        SandboxLock::release($LOCK_DIR);
        reset_terminal();
        exit 1;
    }
    for my $line (split /\r?\n/, ($output // '')) {
        next unless length $line;
        my ($host_path, $skill_name) = split /\t/, $line, 2;
        next unless defined $host_path && length $host_path
                 && defined $skill_name && length $skill_name;
        push @SKILL_MOUNTS, '-v', "$host_path:/root/.claude/skills/$skill_name:ro";
    }
}

# =====================================================================
# Build plugin store (Fix 2 copy model) + directory-source marketplace binds
# =====================================================================
#
# Instead of MOUNTING the host plugin dirs into the container, the launcher
# COPIES the SELECTED host plugins (+ marketplace metadata) into
# claude-home/plugins/, which rides the RW claude-home bind. The host is never
# mounted into the container, so a compromised in-container process can't reach
# or damage host plugins and can't pull in anything the user didn't select; the
# selection + launcher control metadata stay RO in .launcher/. Each launch the
# host-tier is RECONCILED to exactly the current selection (refresh selected,
# remove what was placed before that isn't selected/present now -> no zombies),
# while plugins installed INSIDE the sandbox are PRESERVED. installed_plugins.json
# and known_marketplaces.json are real RW files in claude-home, merge-materialized
# (selection authoritative + sandbox installs preserved). ccpraxis (and any other
# directory-source marketplace) stays a LIVE read-only bind below.

make_path("$CLAUDE_DATA/plugins") unless -d "$CLAUDE_DATA/plugins";

# Plugins: read the prior copy-plan (for reconcile) BEFORE materialize overwrites
# it, then materialize (registry merge + fresh copy-plan), then reconcile+copy.
my $prior_plugins_plan = _read_copy_plan($PLUGINS_COPY_MANIFEST);
run_perl_or_die('materialize-plugins failed',
    'materialize-plugins',
    '--selection-file',   $SELECTION_FILE,
    '--plugins-snapshot', $PLUGINS_SNAPSHOT_FILE,
    '--project-path',     $PROJECT_PATH,
    '--manifest',         $PLUGINS_COPY_MANIFEST,
    '--output',           $MATERIALIZED_PLUGINS_FILE);
sync_copy_plan($prior_plugins_plan, _read_copy_plan($PLUGINS_COPY_MANIFEST),
               "$CLAUDE_DATA/plugins");

my @PLUGIN_MOUNTS;

# Marketplaces: same reconcile+copy pattern. The metadata of every host
# marketplace (the catalogs) is copied so the user can browse + install from
# them inside the sandbox; only SELECTED plugins are actually installed (above).
# Directory-source marketplaces are excluded from the copy by skills.pl — they
# get the LIVE read-only bind below instead.
if (-f "$HOST_PLUGINS_DIR/known_marketplaces.json") {
    my $prior_mkt_plan = _read_copy_plan($MARKETPLACES_COPY_MANIFEST);
    run_perl_or_die('materialize-known-marketplaces failed',
        'materialize-known-marketplaces',
        '--manifest', $MARKETPLACES_COPY_MANIFEST,
        '--output',   $MATERIALIZED_MARKETPLACES_FILE);
    sync_copy_plan($prior_mkt_plan, _read_copy_plan($MARKETPLACES_COPY_MANIFEST),
                   "$CLAUDE_DATA/plugins");
}

# Bind-mount each directory-source marketplace's source.path INTO the
# container's /root/.claude/plugins/marketplaces/<name> as a LIVE read-only
# bind (so the ccpraxis dev loop never drifts and the container can't modify it).
# These nest on top of the copied marketplaces/ dir in claude-home, so claude-code
# can resolve <marketplace>/.claude-plugin/marketplace.json and follow each
# plugin's relative `source` to the real code. ccpraxis-local is the canonical
# example: source.path is ~/.claude/ccpraxis/plugins/, which contains
# .claude-plugin/ + backpack/ + beacon/ + sandbox/ + steward/.
#
# materialize-known-marketplaces (above) rewrites these entries' source.path AND
# installLocation to /root/.claude/plugins/marketplaces/<name> — same target as
# these binds, so the JSON references match what's on the in-container filesystem.
if (-f "$HOST_PLUGINS_DIR/known_marketplaces.json") {
    my $km_data;
    {
        local $/;
        if (open my $fh, '<:raw', "$HOST_PLUGINS_DIR/known_marketplaces.json") {
            my $raw = <$fh>;
            close $fh;
            $km_data = eval { require JSON::PP; JSON::PP::decode_json($raw) };
        }
    }
    if (ref $km_data eq 'HASH') {
        for my $name (sort keys %$km_data) {
            my $entry = $km_data->{$name};
            next unless ref $entry eq 'HASH';
            my $src = $entry->{source};
            next unless ref $src eq 'HASH';
            next unless ($src->{source} // '') eq 'directory';
            my $host_path = $src->{path};
            next unless defined $host_path && length $host_path;
            $host_path =~ s|\\|/|g;
            $host_path =~ s|/+$||;
            $host_path = winify_path($host_path);
            next unless -d $host_path;
            # Ensure the nested mountpoint exists in claude-home (directory-source
            # marketplaces are excluded from the copy, so claude-home won't
            # already have this subdir) — podman mounts the live source on top.
            make_path("$CLAUDE_DATA/plugins/marketplaces/$name")
                unless -d "$CLAUDE_DATA/plugins/marketplaces/$name";
            my $container_path = "/root/.claude/plugins/marketplaces/$name";
            push @PLUGIN_MOUNTS, '-v', "${host_path}:${container_path}:ro";
        }
    }
}

# =====================================================================
# Materialize credentials
# =====================================================================

# One-time migration (Fix 1): older sandboxes kept the sandbox creds at
# $LAUNCHER_DIR/credentials.json and bind-mounted that single file at
# /root/.claude/.credentials.json. That single-file bind rejected rename()
# over the mountpoint (EBUSY), so an in-container OAuth refresh could never
# persist. The canonical location is now claude-home/.credentials.json (a
# real file inside the RW dir bind, rename-safe). If the new file is absent
# (or a stale 0-byte placeholder, treated as absent below) but the legacy one
# exists, carry it over so accumulated in-container
# mcpOAuth tokens survive the move (materialize-credentials below re-reads
# its own output to preserve mcpOAuth). Copy (not move): the legacy file is
# left in .launcher/ as a harmless RO orphan. Best-effort — a failure here
# just means the container re-auths its MCP servers (re-login of MCP plugins,
# no token loss). NOTE: materialize-credentials NO LONGER copies claudeAiOauth
# from the host (blueprint 01-independent-grant, Decision #1). It preserves the
# CONTAINER's own claudeAiOauth when the reset marker
# .launcher/oauth-independent-migrated is present, and performs a one-time
# reset (clears the stale host-copied token, then creates the marker) when it
# is absent — so a migrated/fresh sandbox with no own grant prompts /login.
# claude-home is RW from the container: a planted (dangling) symlink at the
# creds path makes -f false, and _copy_file would then write THROUGH it to a
# host-side target. Drop the link itself first (unlink removes the link, not its
# target) so any copy/seed lands on a real file in claude-home.
unlink $SANDBOX_CREDENTIALS_FILE if -l $SANDBOX_CREDENTIALS_FILE;
# A pre-Fix-1 sandbox can already hold a STALE 0-byte placeholder at this exact
# path (an older era touched claude-home/.credentials.json). An empty file is not
# "absent", so the old `!-f` guard skipped migration and left it in place — and
# materialize-credentials below then DIED reading that unparseable accumulator,
# aborting the whole launch. Treat a 0-byte file as absent: drop it so the legacy
# creds (with their accumulated in-container mcpOAuth) still migrate over.
unlink $SANDBOX_CREDENTIALS_FILE
    if -f $SANDBOX_CREDENTIALS_FILE && -z $SANDBOX_CREDENTIALS_FILE;
if (!-e $SANDBOX_CREDENTIALS_FILE) {
    my $legacy = "$LAUNCHER_DIR/credentials.json";
    if (-f $legacy && !-z $legacy) {
        make_path($CLAUDE_DATA) unless -d $CLAUDE_DATA;
        eval { _copy_file($legacy, $SANDBOX_CREDENTIALS_FILE); 1 }
            or print STDERR "WARNING: legacy credentials migration failed: $@";
        chmod 0600, $SANDBOX_CREDENTIALS_FILE if -f $SANDBOX_CREDENTIALS_FILE;
    }
}

run_perl_or_die('materialize-credentials failed',
    'materialize-credentials',
    '--output', $SANDBOX_CREDENTIALS_FILE);

# =====================================================================
# Extra env + extra mounts (deploy keys, PAT, SSH commands)
# =====================================================================

my @EXTRA_ENV;
my @EXTRA_MOUNTS;

if (-f "$CLAUDE_DATA/git-ssh-command.sh") {
    push @EXTRA_ENV, '-e', 'GIT_SSH_COMMAND=/root/.claude/git-ssh-command.sh';
} elsif (-f "$PROJECT_PATH/deploy_key") {
    push @EXTRA_ENV, '-e', 'GIT_SSH_COMMAND=ssh -i /project/deploy_key -o StrictHostKeyChecking=no';
}

if (-f "$CLAUDE_DATA/git-askpass.sh") {
    push @EXTRA_MOUNTS, '-v', "$CLAUDE_DATA/git-askpass.sh:/root/.claude/git-askpass.sh:ro";
    push @EXTRA_MOUNTS, '-v', "$CLAUDE_DATA/git-pat:/root/.claude/git-pat:ro";
    push @EXTRA_ENV,    '-e', 'GIT_ASKPASS=/root/.claude/git-askpass.sh';

    # GIT_ASKPASS alone is no longer enough. Claude Code's Bash tool scrubs
    # GIT_ASKPASS (and SSH_ASKPASS) from the subprocess environment as a
    # credential-exfiltration safeguard (v2.1.128+), so any git invocation the agent
    # runs over HTTPS never sees it and fails with "could not read Username for
    # 'https://github.com'". A git *credential helper* is read by git from a
    # config FILE, not the environment, so it survives the scrub and is the
    # reliable path. We materialize a tiny helper + an additive global git
    # config and mount the config at the XDG path (read IN ADDITION to the
    # image's ~/.gitconfig, so its autocrlf/defaultBranch settings are NOT
    # masked). The GIT_ASKPASS env above is kept as harmless belt-and-suspenders
    # for any non-scrubbed context (e.g. PID 1); the helper takes precedence.
    # Regenerated every launch so sandboxes created before this fix self-heal
    # on their next container (re)create.
    ensure_git_credential_helper();
    push @EXTRA_MOUNTS, '-v', "$CLAUDE_DATA/git-credential-pat.sh:/root/.claude/git-credential-pat.sh:ro";
    push @EXTRA_MOUNTS, '-v', "$CLAUDE_DATA/gitconfig:/root/.config/git/config:ro";
}

if (-f "$CLAUDE_DATA/git-ssh-command.sh") {
    push @EXTRA_MOUNTS, '-v', "$CLAUDE_DATA/git-ssh-command.sh:/root/.claude/git-ssh-command.sh:ro";
}

# =====================================================================
# SANDBOX_HOST_IP — workaround for Windows wslrelay IPv4 gaps
# =====================================================================
# On Windows + Podman, the host-side mirror of published container ports
# is owned by WSL2's wslrelay.exe, which sometimes registers only an
# IPv6 loopback listener — so `http://localhost:9000` from a host browser
# refuses to connect or TCP-RSTs mid-request even though `podman port`
# reports 0.0.0.0:9000 and the container is healthy. Docker doesn't hit
# this because Docker Desktop ships its own user-mode proxy. The WSL
# distro's external IPv4 is always reachable from the host, so we capture
# it here and expose it in the container as $SANDBOX_HOST_IP; the
# container's CLAUDE.md tells agents to prefer that URL when emitting
# user-facing links. Captured at create-time; goes stale only if WSL
# restarts before the user re-launches.
if ($WINDOWS_FAMILY && $PODMAN =~ /podman/i) {
    my $machine = `$PODMAN machine inspect --format "{{.Name}}" 2>/dev/null`;
    chomp $machine;
    $machine = 'podman-machine-default' unless $machine;
    my $ip = `wsl -d $machine -- sh -c "ip -4 addr | grep -oE 'inet [0-9.]+' | grep -v '127.0.0.1' | head -1 | cut -d' ' -f2" 2>/dev/null`;
    chomp $ip;
    push @EXTRA_ENV, '-e', "SANDBOX_HOST_IP=$ip" if $ip =~ /^\d+\.\d+\.\d+\.\d+$/;
}

# =====================================================================
# Backpack plugin mounts (always-on, file-existence-guarded)
# =====================================================================
#
# These two scripts are mounted at stable container-side paths regardless
# of which plugins/skills the TUI selector enables, because:
#   - backpack.pl is invoked by the install pass below, which runs BEFORE
#     the user opens claude (so plugin-driven mounts may not have
#     materialized yet at install-pass time).
#   - auto-declare.pl is referenced by the container's settings.json
#     PostToolUse hook on Bash (the `[ -f ... ] && perl ... || true` guard
#     in settings.json no-ops if this mount is missing).
# Both mounts gracefully no-op if the host source file is missing — useful
# for older ccpraxis checkouts that pre-date the backpack plugin.

my @BACKPACK_MOUNTS;
{
    my $backpack_dir = "$CLAUDE_HOST_CONFIG/ccpraxis/plugins/backpack";
    if (-f "$backpack_dir/scripts/backpack.pl") {
        push @BACKPACK_MOUNTS, '-v',
            "$backpack_dir/scripts/backpack.pl:/root/.claude/backpack.pl:ro";
    }
    if (-f "$backpack_dir/hooks/auto-declare.pl") {
        push @BACKPACK_MOUNTS, '-v',
            "$backpack_dir/hooks/auto-declare.pl:/root/.claude/auto-declare.pl:ro";
    }
}

# =====================================================================
# Ensure writable claude.json in project
# =====================================================================
#
# Note: rootless Podman maps container UID 0 (root) to the host running
# user via the user namespace, so files written from inside the container
# come out owned by the host user on the host automatically — no UID
# fix-up probe needed (the equivalent of the Docker setup's chown pass
# is structurally unnecessary here).

# Seed/heal it now so a fresh or corrupt config carries the onboarding bypass
# before we go any further. Re-run at the dashboard entry (every manager path)
# and before `podman create` so all three entry points self-heal — see
# ensure_claude_json_onboarded.
ensure_claude_json_onboarded();

# =====================================================================
# Session selector helper
# =====================================================================
#
# Runs the host-side select-session.pl TUI. Returns one of:
#   ('new',    undef)   — start a fresh session (`claude` with no flags)
#   ('resume', $uuid)   — resume specific session (`claude --resume $uuid`)
#   ('cancel', undef)   — user pressed q/esc/Ctrl-C; caller should exit
#
# We invoke via system() (not backticks) so the child's stdin/stdout/stderr
# stay attached to the user's TTY — required for cbreak input + redraws.
# The decision token comes back through a temp file under .launcher/ so
# we don't need to fight the terminal to read it.
sub pick_session_action {
    my $sessions_dir = "$CLAUDE_DATA/projects/-project";
    my $out_file     = "$LAUNCHER_DIR/.session-pick";
    unlink $out_file;
    my $rc = system($^X, $SELECT_SESSION_PL,
        '--sessions-dir',  $sessions_dir,
        '--project-label', $PROJECT_NAME,
        '--output',        $out_file);
    my $exit = $rc >> 8;
    if ($exit == 2) {
        return ('cancel', undef);
    }
    if ($exit != 0) {
        # Selector failed for some other reason. Don't block the user —
        # fall through to a fresh session, which is the safest default.
        print STDERR "WARNING: session selector exited $exit; starting a new session.\n";
        return ('new', undef);
    }
    my $token = _read_file($out_file);
    unlink $out_file;
    chomp $token if defined $token;
    if (!defined $token || !length $token || $token eq 'NEW') {
        return ('new', undef);
    }
    if ($token =~ /^RESUME\s+([0-9a-fA-F-]+)\s*$/) {
        return ('resume', $1);
    }
    print STDERR "WARNING: session selector returned unrecognized token '$token'; starting a new session.\n";
    return ('new', undef);
}

# =====================================================================
# Host data layout (claude-home) + blueprint application
# =====================================================================
#
# /root/.claude inside the container is a direct bind mount of the host's
# <project>/.ccpraxis-local-data/claude-home/ ($CLAUDE_DATA). Session jsonl,
# tasks/, lockfiles, settings.json, CLAUDE.md, .credentials.json, .launcher/ —
# all are live host files. No podman cp round-trips, no seed-on-create, no
# rescue. The host filesystem IS the state.
#
# On container create we ensure the launcher's canonical copies of CLAUDE.md
# / settings.json / .credentials.json live at claude-home/ on the host so
# they appear at /root/.claude/{CLAUDE.md,settings.json,.credentials.json}
# inside the container. Same for the global claude config: it now lives at
# /root/.claude/.claude.json — an ordinary file INSIDE the /root/.claude dir
# bind, reached via CLAUDE_CONFIG_DIR=/root/.claude (an -e literal on
# `podman create`). No single-file bind exists at /root/.claude.json.
#
# Historical: from the first sandbox version through 2026-06, /root/.claude
# was backed by a podman xfs volume to dodge two Hyper-V 9p bugs (O_APPEND
# EIO + utimensat silent-fail). The WSL2 backend's /mnt/c bind honors both
# correctly, so the volume + sync-sidecar architecture was retired.
# Reintroduce ONLY if a future backend's host-bind fails the t/01
# (O_APPEND, utimensat UTIME_NOW, utimensat explicit-timestamp) probes.

sub apply_blueprints_to_host_data {
    my $host_data = "$CLAUDE_DATA";
    make_path($host_data) unless -d $host_data;
    if (-f $CONTAINER_CLAUDE_MD) {
        _copy_file($CONTAINER_CLAUDE_MD, "$host_data/CLAUDE.md");
    }
    if (-f $CONTAINER_SETTINGS_JSON) {
        _copy_file($CONTAINER_SETTINGS_JSON, "$host_data/settings.json");
    }
    # .credentials.json is NOT copied here — materialize-credentials
    # writes it directly at claude-home/.credentials.json (a real file in
    # the RW dir bind), so writes from inside the container (an OAuth token
    # refresh, or mcpOAuth tokens during `claude mcp add` auth) land on the
    # canonical host file and persist across container rebuild with no sync
    # step. See the $SANDBOX_CREDENTIALS_FILE definition for why this is a
    # real file and not a single-file mount.
}

# Single-file bind mounts require the host path to exist before podman
# create — otherwise podman silently creates a directory at the host
# path and the in-container mount target becomes a directory too.
# These helpers ensure each single-file bind has a host file to point at.

# Seed or self-heal claude-home/.claude.json so the in-container claude never
# lands in the onboarding wizard. Idempotent: writes ONLY when the on-disk file
# is missing / 0-byte / unparseable (reseed the template) or is valid JSON but
# missing an onboarding-bypass key (merge it in, preserving every other key).
# A valid, already-onboarded config is left untouched (heal_claude_json returns
# undef). The write is a temp-file + rename() under an mtime-stale-safe mkdir
# lock (spec 02-implement-config-safety-spec.md B19-B27) BECAUSE .claude.json
# is an ordinary file inside the /root/.claude dir bind (CLAUDE_CONFIG_DIR=
# /root/.claude), where in-container writers (the CLI itself, an mcp
# add/remove, a token refresh) use the SAME atomic protocol and the SAME lock
# path — so the two writers interoperate instead of tearing each other's
# write. This can only land after enforce_container_config_shape (B12-B18,
# above) forces every already-created container off the old single-file-bind
# shape: renaming the host file while an old-shape container is still
# attached would leave that container following a ghost inode and lose its
# config silently (s01 sec 4 sequencing hazard).
#
# Called at three points so every entry path self-heals: at top-level manager
# setup (above), just before `podman create` (the pre-create host file must
# exist AND be valid so claude doesn't see a 0-byte file), and at the top of
# enter_dashboard (which every manager path — fresh create, start-of-stopped,
# and bare-attach to an already-running container — funnels through). The
# dashboard process is the single per-project manager and no connector claude
# is running yet at that point, so it is the safest moment to write the
# shared file.

# Row 5 (B21-B24). mkdir-based, mtime-stale-safe lock, local to launcher.pl
# (NOT SandboxLock.pm — that module's kill(0,$pid) staleness is meaningless
# here: the launcher runs on the HOST while the competing writer runs IN the
# container, across the PID-namespace split). %o: timeout (wall seconds,
# default 5), poll (default 0.1), stale (seconds, default 30). A lock older
# than `stale` is taken over — rmdir if it's a directory, unlink if it's a
# regular file (the CLI's lock artefact kind is not guaranteed) — then
# re-mkdir'd once; losing that race counts as "still held" (B22). Measured
# constraint: mtime granularity on this bind is WHOLE SECONDS
# (reports/s02-config-safety-implement/probe-01-bind-lock-and-cli.md) — no
# sub-second staleness logic here. Returns 1 on success, 0 on timeout.
sub _config_lock_acquire {
    my ($lockpath, %o) = @_;
    my $timeout = defined $o{timeout} ? $o{timeout} : 5;
    my $poll    = defined $o{poll}    ? $o{poll}    : 0.1;
    my $stale   = defined $o{stale}   ? $o{stale}   : 30;
    my $deadline = time() + $timeout;
    while (1) {
        return 1 if mkdir($lockpath);
        my @st = stat($lockpath);
        if (@st) {
            my $mtime = $st[9];
            if ((time() - $mtime) > $stale) {
                # redteam H2: the takeover must be ATOMIC. An unconditional
                # rmdir/unlink here breaks the mutual exclusion it exists to
                # preserve: two launchers that both see the same stale lock
                # both proceed — A removes the stale dir and re-mkdirs it
                # (A now holds the lock), then B, a moment behind, removes
                # *A's fresh lock* and mkdirs its own. Both then enter the
                # read-modify-write, and because both writers are atomic the
                # resulting lost update leaves valid JSON that no oracle can
                # see. rename() of the lock entry is atomic for a directory
                # AND for a regular file (the CLI's lock artefact kind is not
                # guaranteed), so exactly one contender can win the takeover;
                # the loser falls through and re-polls.
                #
                # rename() alone is NOT sufficient, and it is worth being
                # precise about why: it makes each individual takeover atomic,
                # but B's staleness DECISION was made before A's takeover, so
                # B would then blindly rename away A's brand-new lock and both
                # would hold it anyway. The entry is therefore re-stat'ed
                # AFTER it has been moved somewhere only this process can see:
                # if what we grabbed is not actually stale, we lost the race,
                # so we put it straight back and do NOT claim the lock.
                my $doomed = "$lockpath.stale.$$." . sprintf('%06x', int(rand(0xffffff)));
                if (rename($lockpath, $doomed)) {
                    my @dst = stat($doomed);
                    if (@dst && (time() - $dst[9]) > $stale) {
                        rmdir($doomed) or unlink($doomed);
                        return 1 if mkdir($lockpath);
                    } else {
                        # Someone else's FRESH lock — restore it and re-poll.
                        # If the restore fails, the worst case is a lock that
                        # ages out via the same staleness window; never a
                        # second holder.
                        rename($doomed, $lockpath);
                    }
                }
                # Lost the takeover race -> fall through, treated as held.
            }
        }
        return 0 if time() >= $deadline;
        select(undef, undef, undef, $poll);   # sub-second sleep, no Time::HiRes dep
    }
}

# Best-effort release (B21). rmdir is a no-op if the lock was already taken
# over by a staleness reaper elsewhere — never dies.
sub _config_lock_release {
    my ($lockpath) = @_;
    rmdir($lockpath);
    return;
}

# Row 5 (B25). Temp-file + rename() in the SAME directory as $path (so
# rename() is atomic and never EXDEV): print, close, chmod 0600, rename.
# Dies on any I/O failure (the caller wraps this in eval and downgrades to a
# WARNING, per spec sec 2.5); unlinks the temp file on any failure so a
# failed write never leaves stray litter.
sub _write_file_atomic {
    my ($path, $bytes) = @_;
    my $tmp = "$path.tmp.$$." . sprintf('%06x', int(rand(0xffffff)));
    open(my $fh, '>:raw', $tmp) or die "write $tmp: $!\n";
    print $fh $bytes;
    unless (close $fh) {
        my $err = $!;
        unlink $tmp;
        die "close $tmp: $err\n";
    }
    chmod 0600, $tmp;
    unless (rename($tmp, $path)) {
        my $err = $!;
        unlink $tmp;
        die "rename $tmp -> $path: $err\n";
    }
    return 1;
}

sub ensure_claude_json_onboarded {
    my $host_json = "$CLAUDE_DATA/.claude.json";
    make_path($CLAUDE_DATA) unless -d $CLAUDE_DATA;

    # B19 (symlink guard): a container-planted symlink must not redirect
    # this write — post-fix the in-container CLI follows symlinks at the
    # config path by design, so an unguarded link would silently divert
    # config into the ephemeral layer. Unlinked before any read/write.
    # (Unlike ensure_credentials_json_host_file's seed-only-if-missing
    # guard, this function must still self-heal an EXISTING plain file —
    # that IS the point of this module — so only the unlink-if-symlink half
    # of that shape applies here.)
    unlink $host_json if -l $host_json;

    # B20 (directory guard): podman's auto-created-directory failure mode
    # (a single-file bind whose host source didn't exist before `podman
    # create`) must be surfaced, not silently deleted.
    if (-d $host_json) {
        print STDERR "WARNING: $host_json is a directory, not a file —"
            . " skipping the .claude.json self-heal this launch.\n";
        return;
    }

    # B21/B23/B24: read-modify-write happens INSIDE the lock. Contention
    # (not stale, not acquired within timeout) skips the heal entirely —
    # safe because the heal is idempotent and runs at three call sites.
    my $lockpath = "$CLAUDE_DATA/.claude.json.lock";
    unless (_config_lock_acquire($lockpath, timeout => 5, poll => 0.1, stale => 30)) {
        print STDERR "WARNING: couldn't acquire $lockpath within 5s —"
            . " skipping the .claude.json self-heal this launch.\n";
        return;
    }

    my $ok = eval {
        my $cur = _read_file($host_json);                       # undef if open failed OR missing

        # redteam C2: an open failure against a file that DOES exist is not
        # "file absent" — probe-02 measured 13/57/74 transient open()
        # failures per run on this mount class, and an in-container process
        # can force it deterministically (`chmod 000`). Treating it as
        # absent would feed heal_claude_json(undef, $tpl), which reseeds
        # the ~1KB onboarding stub over the user's live config with no
        # backup (the backup guard below requires readable bytes). Skip
        # this launch's heal instead — it is idempotent and runs at three
        # call sites, so the next one retries.
        if (!defined $cur && -e $host_json) {
            die "couldn't read $host_json ($!) —"
                . " skipping the .claude.json self-heal this launch\n";
        }

        # redteam C2: a zero-length READ against a file whose on-disk SIZE
        # is nonzero is the same mount-coherency artefact (probe-02: ~0.1%
        # of samples), not a genuinely empty file. One short retry; if it
        # is still empty, treat it the same as unreadable above (never
        # reseed on it) rather than as a legitimately empty/absent file.
        if (defined $cur && !length $cur && -s $host_json) {
            select(undef, undef, undef, 0.25);
            $cur = _read_file($host_json);
            if (!defined $cur || !length $cur) {
                die "short/zero-length read of $host_json persisted after retry —"
                    . " skipping the .claude.json self-heal this launch\n";
            }
        }

        my $tpl = _read_file("$CONTAINER_CONFIG/claude.json");  # undef if missing

        # B27: heal_claude_json returns undef for an already-onboarded
        # config -> no write, no rename, no mtime bump (the overwhelmingly
        # common path; every needless write is a chance to clobber a
        # concurrent in-container merge).
        my $new = ClaudeConfig::heal_claude_json($cur, $tpl);

        # B26 (corrupt backup), widened per redteam C2: back up whenever
        # the file EXISTS and heal_claude_json is about to REPLACE its
        # current bytes — not only when the current bytes are
        # non-empty-and-unparseable. The old, narrower predicate missed
        # empty/whitespace-only bytes (length check) and valid-JSON-but-
        # non-object bytes like `[]`/`null`/`3` (is_parseable_json is true
        # for those), both of which reseed via heal_claude_json's `ref
        # $cur_obj ne 'HASH'` check with NO recovery artefact under the
        # old guard. A genuinely absent file (! -e) still needs no backup
        # — that is the legitimate first-run seed. A failed backup still
        # ABORTS the reseed (unchanged).
        if (defined $new && -e $host_json && (!defined $cur || $cur ne $new)) {
            # redteam C1: this backup must NOT be written with _write_file.
            # That helper is `open '>'`, which FOLLOWS SYMLINKS and truncates,
            # and the old filename was predictable to the second inside a
            # directory the container can write ($CLAUDE_DATA is bind-mounted
            # RW at /root/.claude). An in-container process could pre-plant
            # `.claude.json.corrupt-<T+k>` symlinks aimed at any host path,
            # make the config unparseable, and have the launcher write
            # attacker-chosen bytes there AS THE HOST USER (e.g. the host's
            # ~/.claude/settings.json hooks => host code execution). Two
            # independent defences: an unguessable name (pid + random), and
            # O_EXCL|O_NOFOLLOW so an existing entry or a symlink makes the
            # open FAIL rather than follow. O_NOFOLLOW is a no-op on some
            # Windows perls, which is exactly why the unguessable name is
            # kept as well rather than relied on alone. A failed backup still
            # ABORTS the reseed — losing the user's real config silently is
            # worse than skipping a heal.
            my $backup = "$CLAUDE_DATA/.claude.json.corrupt-" . time()
                . ".$$." . sprintf('%06x', int(rand(0xffffff)));
            eval {
                sysopen(my $bh, $backup, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600)
                    or die "open $backup: $!\n";
                binmode $bh, ':raw';
                print $bh (defined $cur ? $cur : '');
                close $bh or die "close $backup: $!\n";
                1;
            } or die "couldn't back up corrupt $host_json to $backup: $@";
        }

        if (defined $new) {
            _write_file_atomic($host_json, $new);
            chmod 0600, $host_json;
        }
        1;
    };
    print STDERR "WARNING: couldn't heal $host_json: $@" unless $ok;

    _config_lock_release($lockpath);
}

# Belt-and-suspenders alias kept for the pre-create call site: the host file
# must still exist and be valid BEFORE create so the in-container claude
# never reads a 0-byte config on first launch.
sub ensure_claude_json_host_file { ensure_claude_json_onboarded() }

# migrate_claude_json_relocation($old, $new, %opt) -> $outcome
#
# Decision #10 / Ruling B (2026-07-28). One-time, non-destructive, idempotent
# migration of the global config off the OLD pre-fix location onto the NEW
# CLAUDE_CONFIG_DIR-resolved one: COPY old -> new, then rename old aside to
# "<old>.pre-relocation-bak-<ts>".
#
# THE GUARD IS THE POINT. In this project's layout both paths resolve to the
# SAME host file — claude-home/.claude.json, seen through the (removed)
# single-file bind and through the dir bind (s01 probe-05: inode
# 9288674232328321, dev 43 on both). Executing the copy+backup-rename there
# would rename the ONLY config away from the exact path both the old and the
# new resolver read: the "migration" would itself be the outage. So a same-file
# check (dev+inode, NOT string comparison — the two paths are spelled
# differently) skips the whole operation and logs the skip.
#
# It is still written, rather than omitted, because Decision #10 was authored
# for EXISTING sandboxes whose layout may not match this container's. Cheap
# insurance that costs one stat() on the common path.
#
# Outcomes (all logged via log_ev unless a logger is injected):
#   'no-source'     old does not exist -> nothing to migrate
#   'same-file'     old and new are one file -> SKIP (this container's case)
#   'target-exists' new already holds a non-empty config -> SKIP, touch nothing
#   'migrated'      copied, verified, old renamed to the timestamped backup
#   'failed'        copy or verification failed -> old left EXACTLY as it was
#
# %opt: logger => sub { $event, \%fields } (tests inject; defaults to log_ev),
#       now => epoch seconds (tests pin the backup suffix).
sub migrate_claude_json_relocation {
    my ($old, $new, %opt) = @_;
    return ClaudeConfig::relocate_claude_json(
        $old, $new,
        logger => ($opt{logger} || sub { log_ev($_[0], $_[1]) }),
        %opt,
    );
}

# Safety guard only (Fix 1): the canonical sandbox creds now live at
# claude-home/.credentials.json — a REAL file inside the RW dir bind, no
# longer a single-file mount, so it need not pre-exist before `podman
# create`. materialize-credentials always writes a valid file earlier in
# the launch, so by the time we reach create this is a no-op. Kept as a
# belt-and-suspenders seed in case materialize was skipped. This ONLY ensures
# an empty `{}` placeholder exists; it is NOT a credential copy site and never
# writes claudeAiOauth/mcpOAuth — the host token is never copied into the
# sandbox (blueprint 01-independent-grant).
sub ensure_credentials_json_host_file {
    return if -f $SANDBOX_CREDENTIALS_FILE && !-l $SANDBOX_CREDENTIALS_FILE;
    # Drop a container-planted symlink so the seed write can't follow it to a
    # host-side target (claude-home is RW from the container).
    unlink $SANDBOX_CREDENTIALS_FILE if -l $SANDBOX_CREDENTIALS_FILE;
    make_path($CLAUDE_DATA) unless -d $CLAUDE_DATA;
    open(my $fh, '>', $SANDBOX_CREDENTIALS_FILE) or do {
        print STDERR "WARNING: couldn't create $SANDBOX_CREDENTIALS_FILE: $!\n";
        return;
    };
    # Empty file would fail claude's JSON parse. Seed minimal valid JSON
    # — claude-code overwrites with full structure on first auth.
    print $fh "{}\n";
    close $fh;
    chmod 0600, $SANDBOX_CREDENTIALS_FILE;
}

# Materialize the git credential helper (+ an additive global git config) used
# for HTTPS PAT auth. Claude Code's Bash tool scrubs GIT_ASKPASS from the
# environment, so the env-based askpass is dead for any git the agent runs; a
# credential helper read from a git CONFIG FILE is immune to that scrub. The
# helper emits GitHub creds from the PAT mounted at ~/.claude/git-pat. It is
# scoped to https://github.com in the config (the PAT is a GitHub fine-grained
# token — never hand it to other hosts) and no-ops when no PAT file is present.
# Both files live in claude-home (already bind-mounted to /root/.claude); the
# config is additionally mounted at the XDG path /root/.config/git/config by
# the caller. Rewritten every launch so the logic stays current and pre-fix
# sandboxes heal. The host source files exist before `podman create` so the
# single-file binds don't auto-create directories.
sub ensure_git_credential_helper {
    my $cd = "$CLAUDE_DATA";
    return unless -d $cd;

    my $helper = "$cd/git-credential-pat.sh";
    if (open(my $h, '>:raw', $helper)) {
        print $h "#!/bin/sh\n"
               . "# Auto-generated by the ccpraxis sandbox launcher. Do not edit.\n"
               . "[ \"\$1\" = get ] || exit 0\n"
               . "[ -s \"\$HOME/.claude/git-pat\" ] || exit 0\n"
               . "printf 'username=x-access-token\\npassword=%s\\n' \"\$(cat \"\$HOME/.claude/git-pat\")\"\n";
        close $h;
        chmod 0755, $helper or print STDERR "WARNING: chmod 0755 $helper: $!\n";
    } else {
        print STDERR "WARNING: couldn't write $helper: $!\n";
    }

    my $gc = "$cd/gitconfig";
    if (open(my $g, '>:raw', $gc)) {
        print $g "[credential \"https://github.com\"]\n"
               . "\thelper = !sh /root/.claude/git-credential-pat.sh\n";
        close $g;
    } else {
        print STDERR "WARNING: couldn't write $gc: $!\n";
    }
}

# Detect orphaned in-container claude processes — survivors of a prior
# session that the user Ctrl+C'd from PowerShell. Ctrl+C only kills the
# host-side podman.exe client; the disconnect doesn't always propagate
# through conmon to the in-container claude, so claude stays alive but
# decoupled from any user terminal. The orphan keeps refreshing its
# lockfiles in /root/.claude/, which then BLOCKS any new claude session
# that tries to acquire the same locks.
#
# Heuristic: a claude process that has done ZERO read activity over a 2s
# sample AND has been alive for >=30s is considered orphan. The 30s gate
# avoids killing freshly-started claudes that just haven't read anything
# yet (e.g. during their own startup wait).
#
# We never kill silently — print the list and ASK the user. (This runs
# before the session picker / podman start chain, so user-think-time is
# fine here.)
sub find_orphan_claudes {
    return () unless _container_exists($CONTAINER_NAME);
    my $state = `$PODMAN inspect --format '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null`;
    chomp $state if defined $state;
    return () unless defined $state && $state eq 'running';

    # Gather (pid, rchar, etime_seconds) for each claude in container.
    my $listing = `$PODMAN exec "$CONTAINER_NAME" bash -c '
        for pid in \$(pgrep -x claude 2>/dev/null); do
            rchar=\$(awk "/^rchar:/{print \\\$2}" /proc/\$pid/io 2>/dev/null)
            etime=\$(ps -o etimes= -p \$pid 2>/dev/null | tr -d " ")
            echo "\$pid \$rchar \$etime"
        done
    ' 2>/dev/null`;
    my @candidates;
    for my $line (split /\n/, ($listing // '')) {
        my ($pid, $rchar, $etime) = split /\s+/, $line;
        next unless defined $pid && length $pid && defined $rchar && defined $etime;
        # Skip claudes too young to know if they're orphans
        next if $etime < 30;
        push @candidates, { pid => $pid, rchar => $rchar };
    }
    return () unless @candidates;

    # Sample again after 2s to see which haven't read anything
    sleep 2;
    my @orphans;
    for my $cand (@candidates) {
        my $now = `$PODMAN exec "$CONTAINER_NAME" sh -c "awk '/^rchar:/{print \\\$2}' /proc/$cand->{pid}/io 2>/dev/null"`;
        chomp $now;
        if (defined $now && length $now && $now eq $cand->{rchar}) {
            push @orphans, $cand->{pid};
        }
    }
    return @orphans;
}

sub kill_orphan_claudes_if_user_confirms {
    my @orphans = find_orphan_claudes();
    return unless @orphans;
    print "\n";
    print "Found ", scalar(@orphans), " orphan claude process(es) in the container:\n";
    print "  PID $_\n" for @orphans;
    print "\n";
    print "These are claude processes left over from a previous session — usually because\n";
    print "you Ctrl+C'd from PowerShell, which kills the local client but doesn't always\n";
    print "propagate the kill into the container. They hold lockfiles in /root/.claude/\n";
    print "that will block any new claude session you start.\n";
    print "\n";
    print "Kill them now? [Y/n]: ";
    my $resp = <STDIN>;
    $resp //= '';
    chomp $resp;
    my $first = lc(substr($resp, 0, 1) // '');
    if ($first eq 'n') {
        print "Skipping orphan cleanup. If your new session hangs, run:\n";
        print "  podman.exe exec $CONTAINER_NAME pkill claude\n";
        return;
    }
    for my $pid (@orphans) {
        system($PODMAN, 'exec', $CONTAINER_NAME, 'kill', '-9', $pid);
    }
    print _c_ok("Killed orphan claude(s)."), "\n\n";
}

# Run claude inside the container. Returns claude's exit code.
#
# Host's claude-home IS the live state via the bind mount, so claude's
# writes land directly — no sync needed after exit.
#
# IMPORTANT: do NOT `podman stop` after claude exits. Other connector
# instances may have their own claude in the same container — stopping
# would kill them. The container's heartbeat-only keep-alive loop handles
# cleanup: the container reaps itself within HB(300s)+GRACE(10s) after
# the manager terminal's last sentinel touch, independent of whether any
# claude processes are running.
sub run_claude {
    my @cmd = @_;
    my $rc = system(@cmd);
    return $rc >> 8;
}

# Current podman/docker container state ('running','exited','stopped', or ''
# when `inspect` finds no such container — it was removed). Mirrors the inline
# `inspect --format {{.State.Status}}` idiom used elsewhere in this file.
#
# MINOR-5 (red-team step 6): the name is assembled as a QUOTED ARGUMENT LIST via
# _shell_quote (:906, the same idiom _capture_or_die uses) instead of being
# interpolated raw into the backtick. _container_name_for's sanitiser only folds
# spaces, so a project directory carrying shell metacharacters would otherwise
# reach /bin/sh from a keypress-reachable call site (the recover seams). The
# sanitiser itself is deliberately NOT tightened: changing it changes every
# derived container name and would orphan every container that already exists.
# Backticks are kept rather than a list-form pipe open because `2>/dev/null` is
# load-bearing -- this is called from inside the alt-screen TUI, and podman's
# "no such object" must never reach a live frame.
sub container_status {
    my $name = shift;
    return '' unless defined $name && length $name;
    my $cmd = join(' ', map { _shell_quote($_) }
                        ($PODMAN, 'inspect', '--format', '{{.State.Status}}', $name));
    my $s = `$cmd 2>/dev/null`;
    chomp $s if defined $s;
    return defined $s ? $s : '';
}

# Read a copy-plan manifest (skills.pl wrote it with ->utf8->encode): an arrayref
# of {src, dest_rel}. Delegates to PluginSync::read_copy_plan, whose decode is
# UTF-8-aware — CRITICAL because each `src` embeds the user's home dir, which may
# contain non-ASCII bytes (".../André/..."). A non-UTF-8 decode mangles those
# bytes so every `-d $src` in reconcile fails and NOTHING copies (the "selected
# but not installed" bug). Missing / unparseable -> [] ("placed nothing").
sub _read_copy_plan { return PluginSync::read_copy_plan($_[0]); }

# Reconcile a host-tier copy-plan into claude-home (Fix 2). Thin wrapper over
# PluginSync::reconcile_copy_plan (the pure, unit-tested core), passing
# winify_path so `/c/...` host srcs become `C:/...` for perl file ops on Windows.
sub sync_copy_plan {
    my ($prior, $new, $dest_root) = @_;
    PluginSync::reconcile_copy_plan($prior, $new, $dest_root, winify => \&winify_path);
}

# Fix 3: block until the user presses a key, so a held-open connector window
# (Windows Terminal tab) stays visible until the user reads the diagnostic and
# dismisses it. Prefer a single keypress via Term::ReadKey; degrade to a line
# read (Enter) when it's unavailable or stdin isn't a TTY.
sub hold_for_keypress {
    local $| = 1;
    # claude (the in-container TUI) died without restoring the terminal, so the
    # mouse/focus-reporting modes it enabled are still on. Turn them off first so
    # focusing or clicking the tab can't emit an escape sequence that the read
    # below would mistake for a keypress and close the window. (See
    # ConnectorHold::terminal_reset_seq.)
    print STDOUT ConnectorHold::terminal_reset_seq() if -t STDOUT;
    print "  Press Enter to close this window...";
    if ($READKEY_OK) {
        eval {
            Term::ReadKey::ReadMode('cbreak');
            # Drain anything already queued — a click/focus event that landed
            # while claude was dying, or leftover keystrokes — so a stale byte
            # can't dismiss the window before the user has read the message.
            my $drain = 0;
            while ($drain++ < 4096) {
                last unless defined Term::ReadKey::ReadKey(-1);   # non-blocking
            }
            # Block until the user presses ENTER specifically; ignore every other
            # key (and any stray focus/mouse byte that still slips through).
            while (1) {
                my $k = Term::ReadKey::ReadKey(0);   # block for one key
                last if !defined $k;                  # stdin EOF -> stop waiting
                last if ConnectorHold::is_dismiss_key($k);
            }
            1;
        };
        eval { Term::ReadKey::ReadMode('restore') };
    } else {
        my $ignore = <STDIN>;            # line read already requires Enter
    }
    print "\n";
}

# =====================================================================
# Container create / start (MANAGER mode)
# =====================================================================
#
# By construction the connector dispatch near the top of this file has
# already exited any launcher invocation that found the container in
# `running` state, so we know here we're the manager. Tracks whether
# this run created a new container (incl. via [r]ebuild). The backpack
# install pass below only fires on fresh creation — on a restart of an
# existing (stopped) container, tooling state was preserved and
# re-running the install pass would just be slow no-op (verify-then-
# skip on every item).

my $CONTAINER_WAS_CREATED = 0;

# At this point we are guaranteed to be in MANAGER mode — the early
# dispatch near the top of this file already redirected CONNECTOR-mode
# runs (running container) and rejected --resume-session in that mode.
# The container is either missing entirely OR exists in a non-running
# state (stopped/exited/created).

if (_container_exists($CONTAINER_NAME)) {
    print _c_step("Starting container: $CONTAINER_NAME"), "\n";
} else {
    print _c_step("Creating new container: $CONTAINER_NAME"), "\n";
}

# -----------------------------------------------------------------------
# Per-container port-block allocation (fix-multiple-running-sandboxes).
#
# Each sandbox owns one 20-port block (base..base+19). On CREATE we pick
# the lowest block not already published by another claude-sandbox
# container (running OR stopped) and persist that base to
# $LAUNCHER_DIR/port-base. On ATTACH we only read the persisted base for
# messaging — podman baked the -p mapping at create time and `podman
# start` takes no -p, so we never re-allocate or force-recreate an
# existing container (Decision #5).
#
# These are file-scoped so the port args survive from the CREATE block
# down to the podman-start retry loop below, where an EADDRINUSE at start
# re-runs the allocator against a fresh in-use set (Decision #3).
my $PORT_BASE;                 # the allocated block base (undef => no published ports)
my @PORT_INUSE_BASES;          # bases already occupied by sibling sandboxes
my @pub_port_args;         # -p flags fed into @podman_args
my @PORT_ENV_ARGS;             # -e flags fed into @podman_args (SANDBOX_PORT_BASE, ...)
my @podman_args;               # the assembled `podman create` command (file-scoped for retry)
my $build_create_args;         # closure: (re)assemble @podman_args for the current port block

# Rebuild the -p/-e port arg lists for a given base (undef => no ports).
# Kept as a closure so the create + the EADDRINUSE-retry recreate share
# one code path.
my $refresh_port_args = sub {
    my ($base) = @_;
    @pub_port_args = ();
    @PORT_ENV_ARGS     = ();
    return unless defined $base;
    # PortAlloc owns the exact -p / -e strings (module 01); we only splice
    # its result into the podman-create args. The published (-p) and env
    # (-e) halves come back as two arrayrefs.
    my ($pub_args, $env_args) = PortAlloc::build_port_args($base);
    push @pub_port_args, @$pub_args;
    push @PORT_ENV_ARGS,     @$env_args;
};

# B12: must run BEFORE the create-vs-attach decision below — a container
# reaped after that decision would be routed down the ATTACH path and never
# get a port block. Non-declinable; see enforce_container_config_shape above.
enforce_container_config_shape($CONTAINER_NAME);

if (! _container_exists($CONTAINER_NAME)) {
    # CREATE: enumerate sibling-occupied host ports, floor them to block
    # bases, and pick the lowest free base. Robust to no-podman / empty
    # output — an empty in-use set yields the 9000 base.
    @PORT_INUSE_BASES = PortAlloc::bases_from_published(
        [ _enumerate_inuse_host_ports($CONTAINER_NAME) ]);
    $PORT_BASE = PortAlloc::next_free_base(\@PORT_INUSE_BASES);
    if (defined $PORT_BASE) {
        print _c_ok("Allocated host port block $PORT_BASE-@{[$PORT_BASE + 19]}"), "\n";
        _write_file("$LAUNCHER_DIR/port-base", $PORT_BASE);
    } else {
        print STDERR _c_warn("WARNING:"),
            " no free host port block available — launching with NO published ports.\n";
    }
    $refresh_port_args->($PORT_BASE);
} else {
    # ATTACH: read the persisted base for messaging only. Never allocate
    # or re-publish (podman baked the mapping at create; `podman start`
    # takes no -p).
    $PORT_BASE = _read_file("$LAUNCHER_DIR/port-base");
    chomp $PORT_BASE if defined $PORT_BASE;
    $PORT_BASE = ($PORT_BASE // '') =~ /^\d+$/ ? $PORT_BASE + 0 : undef;
}

if (! _container_exists($CONTAINER_NAME)) {

    # Materialize blueprint copies on first create.
    if (! -f $CONTAINER_CLAUDE_MD) {
        _copy_file("$CONTAINER_CONFIG/CLAUDE.md", $CONTAINER_CLAUDE_MD);
        _write_file($CLAUDE_MD_HASH_FILE, md5_of_file("$CONTAINER_CONFIG/CLAUDE.md"));
    }
    if (! -f $CONTAINER_SETTINGS_JSON) {
        _copy_file("$CONTAINER_CONFIG/settings.json", $CONTAINER_SETTINGS_JSON);
        _write_file($SETTINGS_HASH_FILE, md5_of_file("$CONTAINER_CONFIG/settings.json"));
    }

    # Materialize blueprint files + single-file-bind placeholders on host
    # BEFORE the bind mounts go live, so /root/.claude/ inside the
    # container sees everything at the canonical paths from the first
    # moment.
    apply_blueprints_to_host_data();
    # Decision #10 / Ruling B: migrate the global config off the pre-fix
    # location before anything reads or heals it. In THIS layout both
    # arguments resolve to one host file, so the dev+inode guard inside makes
    # this a logged no-op — running the copy+backup-rename literally would
    # rename the only config away from the path both resolvers read. It is
    # called anyway because Decision #10 was written for existing sandboxes
    # whose layout may differ, where the guard falls through to a real,
    # verified copy. Must run BEFORE ensure_claude_json_host_file(), which
    # would otherwise heal/seed the new path and mask a pending migration.
    migrate_claude_json_relocation("$CLAUDE_DATA/.claude.json",
                                   "$CLAUDE_DATA/.claude.json");
    ensure_claude_json_host_file();
    ensure_credentials_json_host_file();

    # Assemble the full `podman create` arg list. Kept as a closure so the
    # EADDRINUSE-retry loop below (at podman-start time) can rebuild it with
    # a freshly-allocated port block and recreate the container. Reads the
    # current @pub_port_args / @PORT_ENV_ARGS, which $refresh_port_args
    # rewrites on each reallocation.
    $build_create_args = sub {
        my @args = (
            $PODMAN, 'create', '-it',
            '--name',     $CONTAINER_NAME,
            '--hostname', 'claude-sandbox',
            # Sandbox-marker env var that skill guards inside the container
            # key off (instead of fragile $HOME-path sniffing). Stable across
            # any future image-internal user/path changes.
            '-e',         'CLAUDE_SANDBOX=1',
        );
        # Published host-port block, allocated above via PortAlloc. The
        # base's two sub-ranges (base..base+9 bridged, base+10..base+19 open)
        # are published here in place of the old hardcoded 9000-9019 literals,
        # so concurrent sandboxes never collide on the same host ports. The
        # matching SANDBOX_PORT_BASE / SANDBOX_*_PORTS env vars ride alongside
        # (build_port_args returns both halves). Empty when no free block was
        # available (fallback: no published ports).
        push @args, @pub_port_args;
        push @args, @PORT_ENV_ARGS;
        push @args, @EXTRA_ENV;
        push @args,
        '-v', "${PROJECT_PATH}:/project",
        # /root/.claude is a direct bind from host's claude-home/.
        # On WSL2 (and Linux/macOS hosts), the bind honors O_APPEND and
        # utimensat correctly — claude's session jsonl appends, task
        # store, lock manager, and settings writes all work as expected
        # with no volume + sync-sidecar workaround. See the "Host data
        # layout" comment block earlier in this file for history.
        #
        # .launcher is OVERLAID as RO on top of the claude-home bind.
        # The directory is launcher-managed metadata (hashes, snapshots,
        # blueprint canonicals, container-created/-name) — a compromised
        # in-container process could otherwise fake hashes to bypass
        # backpack approval or corrupt the launcher's selection state.
        # statusline.pl + skills/plugins read its contents; nothing
        # inside the container needs to write to it.
        #
        # .credentials.json is NOT a single-file bind — it lives at
        # claude-home/.credentials.json and rides the ${CLAUDE_DATA} dir
        # bind above as a REAL file at /root/.claude/.credentials.json.
        # A single-file overlay rejected rename() over the mountpoint
        # (EBUSY), which blocked the atomic temp+rename write that both
        # Claude Code and butler's token-keeper use to persist an OAuth
        # refresh — so the in-container token went stale and forced a
        # relaunch. As a real file in the RW dir bind, both in-place and
        # rename writes land and persist, so in-container token refresh
        # works with no relaunch. mcpOAuth tokens written by `claude mcp
        # add` persist the same way (claude-home survives rebuild).
        # .claude.json is likewise NOT a single-file bind: CLAUDE_CONFIG_DIR
        # (below) moves the CLI's global config into this same dir bind, so
        # the identical EBUSY-free atomic rename applies (s01 probe-01 Case
        # A/B). ensure_claude_json_host_file() above still guarantees the
        # host file exists and is valid before create, so the in-container
        # claude never reads a 0-byte config.
        #
        # The whole claude-home block below — the CLAUDE_CONFIG_DIR -e
        # literal and the three -v pairs (dir bind, .launcher:ro,
        # statusline.pl:ro) — is emitted by MountSpec::claude_home_create_args
        # so this arg list and the t/02 structural guard share one source of
        # truth (spec 02-implement-config-safety-spec.md sec 2.1/2.2). No
        # single-file bind onto /root/.claude.json exists anymore.
        MountSpec::claude_home_create_args(
            claude_data  => $CLAUDE_DATA,
            launcher_dir => $LAUNCHER_DIR,
            statusline   => "${CLAUDE_HOST_CONFIG}/ccpraxis/scripts/statusline.pl",
        );
        push @args, @SKILL_MOUNTS;
        push @args, @PLUGIN_MOUNTS;
        push @args, @EXTRA_MOUNTS;
        push @args, @BACKPACK_MOUNTS;
        push @args, 'claude-sandbox:latest';

        # Rewrite every `-v HOST:CONTAINER[:opts]` pair into
        # `--mount type=bind,…` to defeat MSYS2's `:`-as-path-list mangling on
        # Git-for-Windows perl. The generated `-p N-M:N-M` args are NOT `-v`
        # pairs, so convert_v_to_mount leaves them untouched — the MSYS2 guard
        # at the top of the file remains their sole colon protection.
        return convert_v_to_mount(@args);
    };

    @podman_args = $build_create_args->();

    my $rc = system(@podman_args);
    log_ev('container_create', { exit => $rc >> 8, container => $CONTAINER_NAME });
    if ($rc != 0) {
        print STDERR _c_err("ERROR:"), " podman create failed (exit @{[$rc >> 8]}) — not committing baseline.\n";
        SandboxLock::release($LOCK_DIR);
        reset_terminal();
        exit ($rc >> 8);
    }

    # MSYS2 path-conversion corruption check (defense-in-depth).
    # If MSYS2's path conversion slipped past the env-var guard at the top
    # of this file and the .sh/.ps1 shim, podman would have auto-created
    # `;C`-suffixed directories on the host as bind-mount fallback targets.
    # Detect those NOW — before podman start — and bail loudly, so the
    # user discovers the bug immediately instead of an hour later when
    # onboarding screens or missing CLAUDE.md tell them something's off.
    # We scan the two paths that hold every host-side `-v` target (claude-home
    # and claude-home/.launcher); a `;C` entry in either is unambiguous evidence.
    {
        my @stray;
        for my $dir ($CLAUDE_DATA, $LAUNCHER_DIR) {
            next unless -d $dir;
            opendir(my $dh, $dir) or next;
            while (my $entry = readdir $dh) {
                next if $entry eq '.' || $entry eq '..';
                push @stray, "$dir/$entry" if $entry =~ /;C$/;
            }
            closedir $dh;
        }
        if (@stray) {
            my $n = scalar @stray;
            print STDERR "\n";
            print STDERR _c_err("ERROR:"), " MSYS2 path corruption detected after podman create.\n";
            print STDERR "       Found $n stray `;C`-suffixed bind-mount target(s):\n";
            print STDERR "         - $_\n" for @stray;
            print STDERR "\n";
            print STDERR "       Cause: the MSYS2_ARG_CONV_EXCL=* guard didn't apply when\n";
            print STDERR "       podman.exe was invoked. Likely someone edited launcher.pl\n";
            print STDERR "       or the .sh/.ps1 shim and removed the env-var setup, OR you\n";
            print STDERR "       invoked launcher.pl directly without the shim.\n";
            print STDERR "       See global-config/CLAUDE.md \"MSYS2 path-conversion\" for the\n";
            print STDERR "       full failure mode.\n";
            print STDERR "\n";
            print STDERR "       Auto-recovering: removing the stray dirs and the broken\n";
            print STDERR "       container so the next run can rebuild cleanly.\n";
            for my $path (@stray) {
                _rmtree($path);
            }
            system($PODMAN, 'rm', '-f', $CONTAINER_NAME);
            SandboxLock::release($LOCK_DIR);
            reset_terminal();
            exit 1;
        }
    }

    $CONTAINER_WAS_CREATED = 1;

    # Container created successfully — commit metadata + baseline.
    _write_file("$LAUNCHER_DIR/claude-version",   $HOST_VERSION);
    _write_file("$LAUNCHER_DIR/container-created",
        strftime("%Y-%m-%dT%H:%M:%S", gmtime(time)));
    _write_file("$LAUNCHER_DIR/launcher-hash",    launcher_hash());
    run_perl_or_die('record-mount failed', 'record-mount',
        '--selection-file',     $SELECTION_FILE,
        '--discovery-snapshot', $SNAPSHOT_FILE);
    run_perl_or_die('manifest write failed', 'manifest',
        '--selection-file',     $SELECTION_FILE,
        '--discovery-snapshot', $SNAPSHOT_FILE,
        '--output',             $MANIFEST_FILE);
}

# =====================================================================
# Backpack approval (host-side, BEFORE podman start)
# =====================================================================
#
# The container's heartbeat-only ENTRYPOINT loop exits when the
# /tmp/.launcher-alive sentinel goes stale without a touch.
#
# MINOR-2 (s12 red-team, step 6): the two numbers this comment used to
# quote -- "HB=300s" and "a 10s startup grace" -- were BOTH wrong, and
# this comment is where the error originated. container/heartbeat.sh:26-27
# sets HB=600 and STARTUP_GRACE=600: ten MINUTES each, not 300s and not
# 10s. Read the real values there rather than trusting a number quoted
# here; during s12 this one stale comment propagated, in good faith,
# through a scout report, a spec, a test name and two more code comments
# before anyone checked it against heartbeat.sh.
#
# The ordering below is kept regardless, on its own merits: doing the
# interaction first keeps the gap between `podman start` and the first
# `podman exec` sub-second, which is unconditionally correct and free.
# If we did validate / list / prompt AFTER
# `podman start`, the user's read-and-press-y time could push past that
# grace window and the subsequent `podman exec apt-get update` would
# fail with "container state improper". Run all the interaction up here
# on the host (using the host's backpack.pl — it's the same script that
# gets mounted into the container), capture the approval, and only do
# the in-container install after start. The gap between `podman start`
# and the first `podman exec` then stays sub-second.

my @BACKPACK_APPROVED_ITEMS;
my $BACKPACK_APPROVALS_FILE = "$LAUNCHER_DIR/backpack-approvals.json";
my $BACKPACK_TRUST_FILE     = "$LAUNCHER_DIR/backpack-trusted-hash";  # legacy; migrated away on first run
my $BACKPACK_HOST_FILE      = "$CLAUDE_DATA/backpack.json";
my $BACKPACK_HOST_PL        = "$CLAUDE_HOST_CONFIG/ccpraxis/plugins/backpack/scripts/backpack.pl";

if ($CONTAINER_WAS_CREATED && -f $BACKPACK_HOST_FILE) {
    if (! -f $BACKPACK_HOST_PL) {
        $INSTALL_WARNING = 'backpack present but host backpack.pl missing - install skipped';
        print STDERR _c_warn("WARNING:"), " backpack.json present but host backpack.pl missing at $BACKPACK_HOST_PL\n";
        print STDERR "         Skipping install pass; run /backpack:install in-session after fixing.\n";
    } else {
        # Validate using host's perl — same backpack.pl, host-resident file.
        my $validate_rc = _tee_system($^X, $BACKPACK_HOST_PL, 'validate', $BACKPACK_HOST_FILE);
        if ($validate_rc != 0) {
            $INSTALL_WARNING = 'backpack.json failed validation - install skipped (see launch transcript)';
            print STDERR "\n";
            print STDERR _c_warn("WARNING:"), " backpack.json failed schema validation (see errors above).\n";
            print STDERR "         Skipping install pass. Fix the file (or delete it) and re-launch.\n";
            print STDERR "\n";
        } else {
            # Per-item approval (#21): only NEW/CHANGED items are walked; the rest
            # install silently. backpack_review returns the approved subset.
            print "\n";
            my ($approved, $deferred) = backpack_review(
                $BACKPACK_HOST_FILE, $BACKPACK_HOST_PL,
                $BACKPACK_APPROVALS_FILE, $BACKPACK_TRUST_FILE,
                md5_of_file($BACKPACK_HOST_FILE));
            @BACKPACK_APPROVED_ITEMS = @$approved;
            log_ev('backpack_review',
                { approved => scalar(@BACKPACK_APPROVED_ITEMS), deferred => $deferred });
            if (!@BACKPACK_APPROVED_ITEMS) {
                print "No backpack items approved — skipping install. Run /backpack:install in-session anytime.\n";
            } elsif ($deferred) {
                print "$deferred item(s) deferred — you'll be asked again on the next launch.\n";
            }
        }
    }
}

# Release the per-project lock before podman exec — `exec` replaces this
# perl process and skips END/signal handlers, so we release explicitly.
# Releasing here (before podman start + install pass) lets a concurrent
# second-terminal launcher attach via the running-container fast path
# without waiting on us. The install pass below is safe lock-free because
# $CONTAINER_WAS_CREATED=1 can only be true for the launcher that just
# won the create branch — no other writer can be inside the same
# container's apt/dpkg.
SandboxLock::release($LOCK_DIR);

# podman binds published host ports at START (not create), so an
# "address already in use" collision surfaces here. On the CREATE path a
# racing sandbox may have grabbed our block between enumeration and start;
# recover by rm'ing the just-created container, marking this base occupied,
# re-running PortAlloc::next_free_base for a fresh block, rebuilding the
# create args, and recreating — bounded, then giving up loudly. On the
# ATTACH path we do NOT force-recreate an existing container (Decision #5):
# its port mapping is baked in, so we tell the user to rebuild ([r]) for a
# fresh block.
#
# `podman start` returns a non-zero exit on the port-bind failure but
# system() doesn't hand us its stderr. Only when the start fails do we
# re-run it under backticks to capture the message and classify whether it
# is an address-in-use collision (a fresh `podman start` on a container
# that is still stopped reproduces the same bind error deterministically).
#
# s03-container-health-detect (:3040-ish bug): a NON-port `podman start`
# failure used to satisfy neither this port-collision branch nor any other,
# fall through to log_ev, and continue straight into the podman exec chain
# against a container that never started. s03_run_launch_gate (below, the
# pure/seam-driven region t/58 pins) plus the real seams wired immediately
# after it close that gap: a launch-time health probe runs BEFORE the first
# `podman start` attempt (catching an exited container whose image is gone,
# or -- for a future running-container caller -- a degraded exec env), and
# any post-start failure that is NOT a port collision now aborts cleanly
# instead of falling through.
my %_s03_port_in_use_cache;
my $port_in_use = sub {
    my ($status) = @_;
    return 0 if $status == 0;
    return $_s03_port_in_use_cache{$status} if exists $_s03_port_in_use_cache{$status};
    my $out = `$PODMAN start "$CONTAINER_NAME" 2>&1`;
    my $r = (defined $out
        && $out =~ /EADDRINUSE|address already in use|port is already allocated|already in use/i) ? 1 : 0;
    $_s03_port_in_use_cache{$status} = $r;
    return $r;
};

# >>> s03:health-detect:BEGIN
# s03_run_launch_gate(%seams) -> \%result — the pure, seam-driven launch-time
# health gate (s03-container-health-detect spec). No direct podman-runtime
# handle, no subprocess call, no direct process-termination call in this
# region: every effect is one of the six injected seam callbacks below, so
# this sub can be extracted as source text and eval'd standalone (t/58's
# harness) with zero real podman/subprocess anywhere. The real wiring
# immediately following this region binds each seam to its production
# implementation, so the tested logic and the production logic are the SAME
# sub, not a parallel reimplementation.
#
#   probe()               -> \%state { machine_ok, container_state,
#                                       image_present, exec_probe_ok }
#   start()                -> $start_rc (integer, models the real container
#                              start call)
#   is_port_failure($rc)   -> bool (models the existing $port_in_use check)
#   recover($reason)       -> invoked for a rebuild offer; production binds
#                              this to recover_container(reason => $reason) --
#                              s12's shared seam, never reimplemented here
#   abort($rc)             -> invoked for a clean non-port-failure abort;
#                              production binds this to the existing
#                              print-then-terminate idiom used elsewhere in
#                              this file's port-collision handling
#   exec()                 -> invoked only when nothing aborted/recovered
#
# Three distinct causes, three distinct diagnoses (spec 1.3 -- they are
# different repairs): a podman machine/socket that is unreachable has
# NOTHING to rebuild (the runtime itself is down, so recover is never
# called); an exited container whose image is gone, or a running container
# with a degraded exec env, both DO warrant a rebuild offer through the
# shared recover_container seam. A non-port start failure aborts instead of
# falling through into podman exec (the bug this package fixes); a port
# collision is left untouched for the existing, unchanged handling just
# below this region (C6) to run exactly as before.
sub s03_run_launch_gate {
    my (%seams) = @_;

    my $state = $seams{probe}->();
    return { diagnosis => 'podman machine/socket unreachable' }
        unless $state->{machine_ok};

    if ($state->{container_state} eq 'exited' && !$state->{image_present}) {
        $seams{recover}->('launch-detect-broken');
        return { diagnosis => 'image missing' };
    }

    if ($state->{container_state} eq 'running' && !$state->{exec_probe_ok}) {
        $seams{recover}->('launch-detect-broken');
        return { diagnosis => 'degraded exec environment' };
    }

    my $start_rc = $seams{start}->();
    if ($start_rc != 0) {
        if ($seams{is_port_failure}->($start_rc)) {
            return { delegated_port => 1, start_rc => $start_rc };
        }
        $seams{abort}->($start_rc);
        return { aborted => 1, start_rc => $start_rc };
    }

    $seams{exec}->();
    return { exec_called => 1, start_rc => $start_rc };
}
# <<< s03:health-detect:END

# _s03_probe_state() -> \%state for s03_run_launch_gate's probe seam (the
# real, impure half): machine reachability (podman-on-non-Linux only, via
# the same _machine_state() the [l] recover seam trusts), this container's
# raw `podman inspect` status, whether its image still exists (only checked
# when 'exited' -- a stopped container whose image was pruned can never
# restart, which is the exact C1 scenario), and a live bash/curl probe (only
# checked when 'running' -- by construction the code below never reaches
# this call with a running container today, since the connector dispatch
# near the top of this file already redirected that case away, but the
# gate's contract covers it for future callers, e.g. a periodic health
# check).
my $_s03_probe_state = sub {
    my $capable = ($PODMAN =~ /podman/i && $^O ne 'linux') ? 1 : 0;
    my $mstate  = $capable ? _machine_state() : 'n/a';
    my $machine_ok = (!$capable || $mstate eq 'running' || $mstate eq 'n/a') ? 1 : 0;
    my $raw = container_status($CONTAINER_NAME);
    my $container_state = (defined $raw && length $raw) ? lc($raw) : 'unknown';
    my $image_present = 1;
    if ($container_state eq 'exited') {
        my $img = `$PODMAN inspect --format '{{.Image}}' "$CONTAINER_NAME" 2>/dev/null`;
        chomp $img if defined $img;
        $image_present = (defined $img && length $img
            && system("$PODMAN image inspect \"$img\" >/dev/null 2>&1") == 0) ? 1 : 0;
    }
    my $exec_probe_ok = 1;
    if ($container_state eq 'running') {
        my $bash_rc = system("$PODMAN exec \"$CONTAINER_NAME\" /bin/bash -c 'exit 0' >/dev/null 2>&1");
        my $curl_rc = system("$PODMAN exec \"$CONTAINER_NAME\" curl --version >/dev/null 2>&1");
        $exec_probe_ok = ($bash_rc == 0 && $curl_rc == 0) ? 1 : 0;
    }
    return { machine_ok => $machine_ok, container_state => $container_state,
             image_present => $image_present, exec_probe_ok => $exec_probe_ok };
};

# $start_rc stays undef through a pre-flight abort below (machine
# unreachable / image missing / degraded exec -- none of which ever call the
# start seam), which is exactly how the code right after the gate call tells
# a pre-flight diagnosis apart from a post-start one.
my $start_rc;
my $gate_result = s03_run_launch_gate(
    probe           => $_s03_probe_state,
    start           => sub { $start_rc = system($PODMAN, 'start', $CONTAINER_NAME); return $start_rc; },
    is_port_failure => $port_in_use,
    recover         => sub {
        my ($reason) = @_;
        # s12's shared seam (:3702), invoked -- never reimplemented (C5).
        return recover_container({
            reason => $reason,
            seams  => { emit => sub { }, log => sub { log_ev($_[0], $_[1]) } },
        });
    },
    abort           => sub {
        my ($rc) = @_;
        print STDERR _c_err("ERROR:"),
            " podman start failed (exit @{[$rc >> 8]}) for a reason other than a"
            . " port collision — aborting before podman exec.\n";
        reset_terminal();
        exit ($rc >> 8 || 1);   # never exit 0 on a failed/ signal-killed start
    },
    exec            => sub { 1 },   # the real exec/touch chain runs unconditionally below
);

if (!defined $start_rc) {
    # Pre-flight branch: the health probe aborted before `podman start` was
    # ever attempted (machine unreachable / image missing / degraded exec).
    # The two rebuild-warranting causes already invoked recover_container
    # above; the machine-unreachable cause deliberately did not (spec 1.3 --
    # nothing to rebuild when the runtime itself is down).
    print STDERR _c_err("ERROR:"), " $gate_result->{diagnosis}\n";
    reset_terminal();
    exit 1;
}

if ($start_rc != 0 && $port_in_use->($start_rc)) {

    if ($CONTAINER_WAS_CREATED) {
        my $tries = 0;
        my $max_tries = 5;
        while ($start_rc != 0 && $tries < $max_tries) {
            $tries++;
            print STDERR _c_warn("WARNING:"),
                " host port block "
                . (defined $PORT_BASE ? "$PORT_BASE-@{[$PORT_BASE + 19]}" : '(none)')
                . " is already in use — reallocating (attempt $tries/$max_tries).\n";
            # Mark the collided base occupied and pick the next free block.
            push @PORT_INUSE_BASES, $PORT_BASE if defined $PORT_BASE;
            my $next = PortAlloc::next_free_base(\@PORT_INUSE_BASES);
            if (!defined $next) {
                print STDERR _c_err("ERROR:"),
                    " no free host port block available after $tries attempt(s) — giving up.\n";
                reset_terminal();
                exit 1;
            }
            $PORT_BASE = $next;
            _write_file("$LAUNCHER_DIR/port-base", $PORT_BASE);
            $refresh_port_args->($PORT_BASE);
            # Recreate with the fresh block, then retry start.
            system($PODMAN, 'rm', '-f', $CONTAINER_NAME);
            @podman_args = $build_create_args->();
            my $recreate_rc = system(@podman_args);
            if ($recreate_rc != 0) {
                print STDERR _c_err("ERROR:"),
                    " podman recreate failed (exit @{[$recreate_rc >> 8]}) during port-collision retry.\n";
                reset_terminal();
                exit ($recreate_rc >> 8 || 1);
            }
            print _c_ok("Reallocated host port block $PORT_BASE-@{[$PORT_BASE + 19]}"), "\n";
            $start_rc = system($PODMAN, 'start', $CONTAINER_NAME);
            last if $start_rc == 0;
            last unless $port_in_use->($start_rc);
        }
        if ($start_rc != 0) {
            print STDERR _c_err("ERROR:"),
                " could not find a free host port block after $tries attempt(s) — giving up.\n";
            reset_terminal();
            exit ($start_rc >> 8 || 1);   # never exit 0 on a failed/ signal-killed start
        }
    } else {
        # Existing container: its -p mapping was baked at create and cannot
        # be re-published by `podman start`. Do NOT force-recreate.
        print STDERR "\n";
        print STDERR _c_err("ERROR:"),
            " another sandbox took this container's host ports"
            . (defined $PORT_BASE ? " (block $PORT_BASE-@{[$PORT_BASE + 19]})" : '') . ".\n";
        print STDERR "       This container's port mapping is fixed for its lifetime.\n";
        print STDERR "       Rebuild ([r] at the next prompt) to recreate it with a fresh,\n";
        print STDERR "       free port block.\n\n";
        reset_terminal();
        exit ($start_rc >> 8 || 1);   # never exit 0 on a failed/ signal-killed start
    }
}
log_ev('container_start', { exit => $start_rc >> 8, container => $CONTAINER_NAME });

# Land the first sentinel touch IMMEDIATELY after `podman start`, before
# anything else (perl/helper probes, apt-get update, backpack install)
# eats into the container's startup grace. The container's entrypoint loop
# checks for /tmp/.launcher-alive at t=STARTUP_GRACE and reaps itself if
# missing — so a slow operation here could kill the container mid-flight
# ("container state improper" on the next exec).
#
# MINOR-2 (s12 red-team, step 6): this comment used to say "10-second
# startup grace" and "HB=300s". Both were wrong — see
# container/heartbeat.sh:26-27, which sets HB=600 and STARTUP_GRACE=600
# (ten MINUTES each). Always read the live values there; do not trust a
# number quoted in a comment here. Touching the sentinel first is kept
# regardless: it is unconditionally correct and costs nothing.
system($PODMAN, 'exec', $CONTAINER_NAME, 'touch', '/tmp/.launcher-alive');

# Bind mount of claude-home → /root/.claude means host filesystem IS
# the live state. No seed, no rescue, no sync. Blueprint files were
# already materialized to claude-home/ before podman create — the bind
# now exposes them in the container at the canonical paths. Same for
# .claude.json, which now lives at /root/.claude/.claude.json (an ordinary
# file inside that same dir bind, reached via CLAUDE_CONFIG_DIR). Nothing
# to do here.

# --- Backpack install (container side) — only the approved subset (#21) ---
# All user interaction (validate, list, per-item approve/remove) happened on the
# host before `podman start`. By this point @BACKPACK_APPROVED_ITEMS is the set
# the user OK'd; we install ONLY that subset so an un-approved item can never run
# as root in the container.
#
# Large backpack installs (e.g. chromium = 289 deps / 221MB) can easily exceed
# the container's 5-min HB window, which would otherwise let the entrypoint loop
# reap the container mid-`apt-get install`. We run apt-get update + the install +
# a parallel heartbeat refresher under a single `podman exec bash`. The heartbeat
# is a background subshell tied to the bash's lifetime via `trap EXIT`, so it
# dies the moment the install completes (or this bash is signalled). Single exec
# → single lifecycle → no orphan helper to clean up.
if (@BACKPACK_APPROVED_ITEMS) {
    # Pre-flight: confirm the container has perl + backpack.pl wired in. If the
    # mount didn't land (older ccpraxis checkout, missing source), warn and skip
    # — claude still launches.
    my $has_perl = (system($PODMAN, 'exec', $CONTAINER_NAME,
        'test', '-x', '/usr/bin/perl') == 0);
    my $has_helper = $has_perl
        && (system($PODMAN, 'exec', $CONTAINER_NAME,
            'test', '-f', '/root/.claude/backpack.pl') == 0);
    if (!$has_helper) {
        $INSTALL_WARNING = 'backpack.pl not mounted in container - install skipped';
        print STDERR _c_warn("WARNING:"), " Backpack found at $BACKPACK_HOST_FILE but backpack.pl isn't mounted in the container. Update ccpraxis (the launcher needs the plugin's backpack/scripts/backpack.pl) and rebuild.\n";
    } else {
        # Write the approved subset as a backpack-shaped file into claude-home
        # (bound at /root/.claude) and point `install` at it — the full
        # backpack.json is never installed wholesale. The container path is fixed,
        # so the install script stays a non-interpolating single-quoted heredoc.
        my $set_host = "$CLAUDE_DATA/.backpack-install-set.json";
        my $wrote = eval {
            _write_file($set_host, JSON::PP->new->utf8->canonical(1)->pretty->encode(
                { version => 2, items => \@BACKPACK_APPROVED_ITEMS }));
            1;
        };
        if (!$wrote) {
            $INSTALL_WARNING = 'could not write backpack install-set - install skipped';
            print STDERR _c_warn("WARNING:"), " could not write backpack install-set ($set_host): $@\n";
        } else {
            # Inline bash script: kick off the heartbeat refresher in the
            # background, run apt-get update + backpack install in the foreground,
            # then let the EXIT trap kill the refresher on the way out. The
            # script's exit status mirrors the install's. apt-get update failures
            # are not fatal (some backpack entries don't depend on apt), so its
            # return code is intentionally ignored.
            my $install_script = <<'BASH';
HB_PID=""
cleanup() { [ -n "$HB_PID" ] && kill "$HB_PID" 2>/dev/null; }
trap cleanup EXIT INT TERM HUP
( while true; do touch /tmp/.launcher-alive; sleep 60; done ) &
HB_PID=$!
echo "Refreshing apt index..."
apt-get update -qq
echo "Installing backpack items..."
perl /root/.claude/backpack.pl install /root/.claude/.backpack-install-set.json
BASH
            _tx("\n--- backpack install (approved subset: @{[scalar @BACKPACK_APPROVED_ITEMS]} items) ---\n");
            my $install_rc = _tee_system($PODMAN, 'exec', $CONTAINER_NAME,
                'bash', '-c', $install_script);
            unlink $set_host;   # transient; don't leave the subset lying in claude-home
            if ($install_rc != 0) {
                $INSTALL_WARNING = 'backpack install: some items failed - run /backpack:install in the session to retry';
                log_ev('backpack_install_failed', { exit => $install_rc >> 8 });
                print "\n";
                print _c_warn("WARNING:"), " Some backpack items failed (see above). Handing off to claude anyway — fix in-session via /backpack:add, /backpack:remove, or by editing the backpack file directly and running /backpack:install.\n";
                print "\n";
            } else {
                log_ev('backpack_install_ok', { installed => scalar @BACKPACK_APPROVED_ITEMS });
            }
        }
    }
}

# =====================================================================
# Dashboard (manager mode) — Decision #19
# =====================================================================
#
# Container is up + backpack install (if any) is done. This launcher now
# becomes the manager window: it lands on the dashboard, which holds the
# container alive via the same /tmp/.launcher-alive heartbeat (every 2
# minutes, well within the container's 5-minute reap window) and exposes
# the launch-claude + shutdown-all hotkeys. Closing this window — or the
# dashboard's [q] — stops the heartbeat; the container reaps itself within
# ~5 minutes (Decision #17, unchanged). On a non-TTY / no-Term::ReadKey
# terminal it degrades to the plain scrolling heartbeat loop.
enter_dashboard();   # never returns (loops until the user exits)

# ---------------------------------------------------------------------
# Dashboard wiring (B2) — these file-scope subs close over $PODMAN /
# $CONTAINER_NAME / $PROJECT_* / the loggers, supplying the real podman +
# terminal seams to the generic Dashboard::run loop.
# ---------------------------------------------------------------------

# enter_dashboard — manager-ready: log it, do an immediate heartbeat so the
# reap window starts fresh, then run the dashboard (raw-ANSI TUI when the
# terminal supports it, else the plain heartbeat loop).
sub enter_dashboard {
    log_ev('manager_ready', { container => $CONTAINER_NAME });
    # Self-heal .claude.json's onboarding bypass on EVERY manager entry (fresh
    # create, start-of-stopped, or bare-attach to an already-running container).
    # This is the single chokepoint all manager paths funnel through, and no
    # connector claude is running yet — the safest point to write the shared
    # config (an ordinary file in the /root/.claude dir bind). Heals a
    # 0-byte/corrupt file or one that lost its onboarding keys, so the next
    # [c] never reopens the setup wizard.
    ensure_claude_json_onboarded();
    # Act on the first heartbeat: if the container is already gone, don't paint
    # a dashboard that would just die on its first tick — say so and exit clean.
    #
    # s12: NARROWED, not removed. The bail-out is still right for the one case
    # the TUI genuinely cannot fix -- a container that was REMOVED, on a live
    # machine, which needs a rebuild (R1: no in-TUI recreate). For everything
    # else the dashboard is now the better place to be: [l] relaunch can start a
    # merely-stopped container, or start a podman machine that is down. Exiting
    # on those would deny the user the only control that repairs them.
    if (_heartbeat_once() eq 'gone') {
        my $m = _machine_state();
        my $c = Dashboard::classify_container_state(container_status($CONTAINER_NAME), $m);
        if ($c eq 'absent' && $m ne 'stopped') {
            print STDERR "Container $CONTAINER_NAME is no longer running. Nothing to attach to.\n"
                       . "Re-run claude-sandbox to rebuild it.\n";
            reset_terminal();
            exit 0;
        }
        # Fall through into the dashboard: the dead-state banner plus [l].
        log_ev('recover_available', { state => $c, machine => $m, container => $CONTAINER_NAME });
    }

    my $is_tty = (-t STDOUT && -t STDIN) ? 1 : 0;
    my $mode   = Dashboard::decide_mode($is_tty, $READKEY_OK, $ENV{CCPRAXIS_NO_TUI});
    if ($mode eq 'plain') {
        plain_heartbeat_loop();   # never returns
        return;
    }

    require Term::ReadKey;
    my $log_path = "$CLAUDE_DATA/sandbox-logs/launch-$LAUNCH_ID.log";
    # s13: prior-session activity. Read ONCE, here, not per gather tick -- prior logs
    # are effectively immutable for this dashboard's lifetime, and an opendir + up to
    # five file reads per frame would be a real regression in the hot path. Reading it
    # once also keeps the boundary marker's position stable (no flicker).
    my @hist_groups = _history_events("$CLAUDE_DATA/sandbox-logs", "launch-$LAUNCH_ID.log");
    my $cached_status           = 'unknown';
    my $cached_machine_state    = 'unknown';   # s12: _machine_state, refreshed on the 10s inspect round
    my $cached_busy_age         = undef;   # B5: age (s) of /tmp/.butler-busy in CONTAINER time, or undef
    my $cached_busy_stamp       = 0;       # host time() when $cached_busy_age was measured
    my $cached_needs_you        = 0;       # B3: queued "needs you" decisions
    my $cached_backpack         = undef;   # B4: backpack items + per-item approval
    my $cached_oauth_expires_at = undef;   # 01-oauth: epoch-s when the OAuth token expires
    my $cached_tokens           = undef;   # s08: TokenInfo struct
    my $cached_resources        = undef;   # s09: Resources::build struct (never undef after the first round)
    my $cached_runs             = [];      # s10: RunState::summarize struct, initialised to [] so the "runs" key is never undef
    my $last_inspect            = 0;
    my $last_resources          = 0;       # s09: stamp for the throttled probe cadence
    my $bp_host_file      = "$CLAUDE_DATA/backpack.json";
    my $bp_appr_file      = "$LAUNCHER_DIR/backpack-approvals.json";

    # B5 keep-awake: hold a wake-lock only while the orchestrator's busy-lease is
    # fresh (active work / pending auto-resume). Reap any helper orphaned by a
    # previously-crashed launcher first, then build the seam-driven holder.
    # Keep-awake holds the host awake while the busy-lease was touched within this
    # window. 10 min (matching the loosened heartbeat HB) so a brief gap / slow
    # tick never releases the lock mid-run; the host only sleeps once the run has
    # been genuinely idle or parked this long. Env-overridable.
    my $BUSY_STALE   = ($ENV{BUSY_STALE_SECS} && $ENV{BUSY_STALE_SECS} =~ /^\d+$/)
                       ? $ENV{BUSY_STALE_SECS} : 600;
    my $ka_helper    = "$SANDBOX_PLUGIN/scripts/keep-awake.ps1";
    my $ka_pidfile   = "$LAUNCHER_DIR/keepawake.pid";
    _keepawake_reap_orphan($ka_pidfile);
    $KEEPAWAKE = KeepAwake->new(
        start => sub { _keepawake_start($ka_helper, $ka_pidfile) },
        stop  => sub { _keepawake_stop($_[0], $ka_pidfile) },
    );

    # red-team MINOR-1: one-shot guard shared by enter_raw/leave_raw so a
    # re-entrant leave_raw (second Ctrl-C during teardown) only pops the
    # title stack once. See leave_raw below for the full rationale.
    my $left_raw = 0;
    my $rc = Dashboard::run(
        color     => 1,
        enter_raw => sub {
            Term::ReadKey::ReadMode('cbreak');
            print STDOUT "\e[22;0t";                # XTPUSHTITLE: push icon+window title onto the stack
            print STDOUT "\e[?1049h\e[?25l";        # alt-screen + hide cursor
            print STDOUT "\e]0;" . Dashboard::window_title({ project_name => $PROJECT_NAME }) . "\a";
            # s17-statusline-and-output-hygiene (spec S3): while the alt-screen
            # owns the terminal, a runtime-emitted warn/die (e.g. perl's own
            # "Can't fork, trying again in 5 seconds") must not splatter across
            # the live frame. _heartbeat_once's `2>&1` only catches a CHILD's
            # stderr -- this is the PARENT's OWN STDERR, so redirect the real
            # filehandle for the duration the alt-screen is owned. Captured
            # STDERR text is logged (not dropped): a real File::Temp file, NEVER
            # an in-memory scalar (Git-for-Windows perl: open() onto \$scalar
            # dies "Bad file descriptor").
            eval {
                open($STDERR_CAPTURE_SAVED, '>&', \*STDERR) or die "dup STDERR: $!";
                ($STDERR_CAPTURE_FH, $STDERR_CAPTURE_PATH) =
                    File::Temp::tempfile('ccpraxis-stderr-XXXXXX', TMPDIR => 1, UNLINK => 0);
                open(STDERR, '>', $STDERR_CAPTURE_PATH) or die "redirect STDERR: $!";
                STDERR->autoflush(1);
            };
        },
        leave_raw => sub {
            # red-team MINOR-1: a second Ctrl-C during teardown can re-enter
            # this closure (Perl's deferred-signal dispatch runs the INT
            # handler again before the first call's pending `exit` completes)
            # while inside this very call. A second XTPOPTITLE would then pop
            # a stack entry that belongs to an outer application (tmux, vim,
            # an outer launcher). Guard so the neutral-clear + pop fire once;
            # the terminal-mode restore lines below still run every time --
            # they're already idempotent and existing double-teardown safety
            # relies on them re-running.
            if (!$left_raw++) {
                print STDOUT "\e]0;\a";             # neutral: clear our title
                print STDOUT "\e[23;0t";            # XTPOPTITLE: restore the pushed title
            }
            print STDOUT "\e[?25h\e[?1049l";        # show cursor + leave alt-screen
            eval { Term::ReadKey::ReadMode('restore') };
            # s17: restore the process's own STDERR before the alt-screen
            # teardown finishes, so the terminal is never left with a
            # redirected STDERR after the dashboard closes (the
            # signal/abnormal-exit half is covered separately by
            # $SIG{INT}/$SIG{TERM}/END at file scope).
            if ($STDERR_CAPTURE_SAVED) {
                eval { close(STDERR); open(STDERR, '>&', $STDERR_CAPTURE_SAVED); STDERR->autoflush(1); };
                close($STDERR_CAPTURE_SAVED) if $STDERR_CAPTURE_SAVED;
                $STDERR_CAPTURE_SAVED = undef;
            }
            # STDERR captured while the alt-screen was up is not lost: it is
            # logged via the same shared, timestamped log_ev writer, and a
            # visible-but-non-destructive indicator (a plain post-alt-screen
            # line, painted only after \e[?1049l above already restored the
            # normal screen) tells the operator something was captured/logged.
            if (defined $STDERR_CAPTURE_PATH && -s $STDERR_CAPTURE_PATH) {
                my $captured = '';
                if (open(my $rf, '<', $STDERR_CAPTURE_PATH)) {
                    local $/;
                    $captured = <$rf> // '';
                    close($rf);
                }
                if (length $captured) {
                    log_ev('stderr_captured', { text => substr($captured, 0, 4000) });
                    print STDOUT "\e[33m[output was captured while the dashboard was open -- see launch log]\e[0m\n";
                }
                unlink($STDERR_CAPTURE_PATH);
            }
            $STDERR_CAPTURE_PATH = undef;
            $STDERR_CAPTURE_FH   = undef;
            reset_terminal();
        },
        read_key  => sub {
            my $k = Term::ReadKey::ReadKey(-1);   # non-blocking poll
            return undef unless defined $k;
            if ($k eq "\e") {
                # Assemble an arrow escape sequence into a token the dashboard
                # understands: UP/DOWN scroll the Activity panel. A lone ESC (no
                # following bytes) falls through as "\e" (inert in dispatch_key).
                my $k2 = Term::ReadKey::ReadKey(0.02);
                if (defined $k2 && ($k2 eq '[' || $k2 eq 'O')) {
                    my $k3 = Term::ReadKey::ReadKey(0.02);
                    if (defined $k3) {
                        return 'UP'   if $k3 eq 'A';
                        return 'DOWN' if $k3 eq 'B';
                        if ($k3 =~ /[0-9]/) {   # drain a numeric CSI (e.g. \e[5~)
                            while (defined(my $d = Term::ReadKey::ReadKey(0.01))) {
                                last if $d !~ /[0-9;]/;
                            }
                        }
                        return undef;   # other arrows / CSI: ignore
                    }
                }
                # ESC + a non-CSI byte (e.g. Alt+key): surface that byte rather
                # than dropping it. A lone ESC (k2 undef) falls through as inert.
                return $k2 if defined $k2;
                return "\e";
            }
            return $k;
        },
        # s15-input-latency: the interruptible tail-wait seam. Built on
        # BLOCKING Term::ReadKey::ReadKey($timeout) with a VARIABLE timeout --
        # deliberately NOT Perl's 4-arg select(STDIN, ...): select is
        # socket-only on Windows and cannot watch the console handle there,
        # and this repo ships on Git for Windows (that is load-bearing, not
        # theoretical). ReadKey($timeout) blocks up to $timeout waiting for a
        # single byte, returning undef on timeout (idle tick, no busy-spin)
        # or that one byte the instant it arrives (a keypress wakes the loop
        # immediately). It intentionally does NOT try to assemble a full
        # arrow/CSI sequence itself -- if the byte it consumed to detect
        # readiness is an ESC, Dashboard::run's own pushback handling pulls
        # the remaining bytes back through the read_key seam above and
        # assembles them there (Decision #22): a lost or misassembled
        # ESC/arrow sequence is a hard failure, not cosmetic.
        wait_input => sub {
            my ($timeout) = @_;
            return Term::ReadKey::ReadKey($timeout);
        },
        term_size => sub {
            my @s = eval { Term::ReadKey::GetTerminalSize() };
            my $cols = (@s && $s[0]) ? $s[0] : 80;
            my $rows = (@s && $s[1]) ? $s[1] : 24;
            return ($cols, $rows);
        },
        heartbeat => \&_heartbeat_once,
        gather    => sub {
            # podman inspect is comparatively expensive; cache it ~$CONTAINER_POLL_SECONDS so the
            # input loop stays responsive. The cheap log tail refreshes every
            # state interval. (B3 may make the inspect fully async.)
            my $now = time;
            # MINOR-3 (red-team step 6): did THIS call actually re-probe, or is
            # the status below a <=10s-old cache reading? The recovery driver
            # must not skip container-start off a cached 'running' for a
            # container that died inside the throttle window.
            my $probed_now = 0;
            if ($now - $last_inspect >= $CONTAINER_POLL_SECONDS) {
                my $s = `$PODMAN inspect --format '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null`;
                chomp $s if defined $s;
                $cached_status = (defined $s && length $s) ? $s : 'unknown';
                # B5: busy-lease freshness (the orchestrator keeps /tmp/.butler-busy
                # fresh only while there's active work or a pending auto-resume).
                # Compute the age ENTIRELY in container time — read the lease mtime
                # AND the container clock, both via exec, and subtract here. Doing
                # `host_now - container_mtime` instead skews the age by the host-vs-
                # container clock offset (seen as a NEGATIVE busy_age in the wild),
                # which released keep-awake mid-run and let the host sleep. Read
                # mtime first, then now, so the inter-exec gap can't read negative.
                my $bm = `$PODMAN exec "$CONTAINER_NAME" stat -c %Y /tmp/.butler-busy 2>/dev/null`;
                my $cn = `$PODMAN exec "$CONTAINER_NAME" date +%s 2>/dev/null`;
                my ($lmt)  = ($bm && $bm =~ /^(\d+)/) ? ($1) : ();
                my ($cnow) = ($cn && $cn =~ /^(\d+)/) ? ($1) : ();
                if (defined $lmt && defined $cnow) {
                    my $a = $cnow - $lmt;
                    $cached_busy_age = $a < 0 ? 0 : $a;   # clamp the tiny exec-gap race
                } else {
                    $cached_busy_age = undef;
                }
                $cached_busy_stamp = $now;
                $cached_needs_you  = _count_needs_you($PROJECT_PATH);          # B3
                $cached_backpack   = _gather_backpack($bp_host_file, $bp_appr_file);  # B4
                $cached_oauth_expires_at = _gather_oauth_expiry();
                $cached_tokens = _gather_tokens();
                $cached_runs   = _gather_runs($PROJECT_PATH);   # s10
                # s12: the podman-machine reading, refreshed on THIS throttled
                # round rather than per-tick -- it shells out to `podman machine
                # list`, which is as expensive as the inspect above, so putting
                # it here keeps the frame budget exactly where it was.
                $cached_machine_state = _machine_state();
                $last_inspect  = $now;
                $probed_now    = 1;
            }
            # s09: the expensive resource probes run on their OWN, slower
            # cadence with their OWN stamp — deliberately NOT nested in the
            # 10s inspect above. What that buys: the two rounds are decoupled,
            # so a slow resources round never pushes the 10s inspect out of
            # phase (its stamp advances independently), and 23 being coprime
            # with 10 keeps the two rounds rarely landing in the same frame.
            # What it does NOT buy: the round below runs INLINE, in this same
            # callback that feeds the ~0.2s render loop, so it DOES stall a
            # frame — every 23s and on the very first frame. See
            # _resources_probes: nothing here is portably interruptible, so
            # the throttle and the elapsed budget only bound the blast radius.
            if (Resources::should_sample($last_resources, $now, Resources::interval())) {
                $cached_resources = _gather_resources();
                $last_resources   = $now;
            }
            # Advance the skew-free baseline by host-measured elapsed since the
            # last measurement (elapsed rate matches on both clocks; only the
            # absolute offset differed, and that's gone now).
            my $busy_age = defined $cached_busy_age ? $cached_busy_age + ($now - $cached_busy_stamp) : undef;
            # B5: the single keep-awake decision, shared by the seam below AND the
            # Run panel (so the view never re-derives the freshness threshold).
            my $stay = KeepAwake::should_stay_awake($busy_age, $BUSY_STALE) ? 1 : 0;
            my @lines = _tail_lines($log_path, 200);
            # s17-statusline-and-output-hygiene (spec S5): the history path's
            # heartbeat/tick filter was HISTORY-only by design -- absent here,
            # so a live session showed heartbeat/tick noise (the operator's
            # screenshot). Same shared predicate as _history_events, applied
            # BEFORE Dashboard::recent_events sees @lines.
            @lines = grep { !_is_heartbeat_line($_) } @lines;
            my $cur   = Dashboard::recent_events(\@lines, $ACTIVITY_EVENT_MAX);
            # s16-fleet-event-source: fold the active blueprint run's
            # orchestrator.log into the SAME activity panel (SYN-5 -- not a
            # second feed) via the best-effort cross-source interleave, never
            # a plain sort (spec S1). Within each source, append order is
            # untouched; only absent/empty orchestrator activity is a no-op.
            my $orch_ev = _gather_orchestrator_events($cached_runs);
            $cur = LaunchLog::merge_by_key([ $cur, $orch_ev ],
                       key => \&_row_time_key, max => $ACTIVITY_EVENT_MAX)
                if ref $orch_ev eq 'ARRAY' && @$orch_ev;
            return {
                project_name    => $PROJECT_NAME,
                container       => $CONTAINER_NAME,
                status          => $cached_status,
                # s12 MINOR-3: "the status above is a CACHE reading -- do not
                # trust it to skip work". Dashboard::run_recover_stages honours
                # this by always calling the container_start seam (which
                # re-probes authoritatively) instead of reporting the stage
                # skipped off a reading that may be up to 10s out of date.
                status_stale    => ($probed_now ? 0 : 1),
                events          => LaunchLog::merge_sessions(
                                        [ @hist_groups, $cur ],
                                        max    => $ACTIVITY_EVENT_MAX,
                                        marker => Dashboard::session_boundary_row(),
                                    ),
                install_warning => $INSTALL_WARNING,
                busy_age        => $busy_age,
                stay_awake      => $stay,
                needs_you        => $cached_needs_you,
                backpack         => $cached_backpack,
                oauth_expires_at => $cached_oauth_expires_at,
                tokens           => $cached_tokens,
                resources        => $cached_resources,
                runs             => $cached_runs,
                # b37-spend-surfaces: undef when no run has persisted a spend
                # snapshot, and Dashboard::build_panels then omits the Spend
                # panel entirely rather than rendering an empty or zeroed one.
                # See _gather_spend for why this never fetches from here.
                spend            => _gather_spend($cached_runs),
                # s11-lifecycle-stop spec 08 S2.8: one notch wider than the
                # Windows-only guard at _resources_probes (:3268-3271), so a
                # macOS podman machine is covered too; Linux-native podman has
                # no machine and must not get the stop-machine stage.
                machine_capable  => ($PODMAN =~ /podman/i && $^O ne 'linux') ? 1 : 0,
                # s12 spec 09 S2.8: the machine reading classify_container_state
                # needs to tell "container removed" apart from "machine down, so
                # the container probe means nothing".
                machine_state    => $cached_machine_state,
            };
        },
        keepawake => sub {
            my ($st) = @_;
            my $act = $KEEPAWAKE->sync($st->{stay_awake} ? 1 : 0);
            log_ev('keepawake', { want => ($st->{stay_awake} ? 1 : 0), action => $act,
                                  busy_age => $st->{busy_age} }) if $act ne 'noop';
        },
        spawn         => \&_spawn_session,
        stop_runs     => sub { my ($st, $prog) = @_; _lifecycle_run('stop-runs',     $st, $prog) },
        full_shutdown => sub { my ($st, $prog) = @_; _lifecycle_run('full-shutdown', $st, $prog) },
        # s12 spec 09 S2.8: the [l] relaunch/recover seam. An INLINE closure, not
        # a file-scope sub, purely because of the cache invalidation below.
        recover       => sub {
            my ($st, $prog) = @_;
            my $r = recover_container({
                state  => $st,
                reason => 'in-tui-relaunch',
                seams  => { emit => $prog, log => sub { log_ev($_[0], $_[1]) } },
            });
            # Problem 8 -- BOTH halves of the cache invalidation are required and
            # neither is sufficient alone. The loop's own $last_state = undef
            # (Dashboard side) forces a fresh gather CALL; these two force that
            # call to actually re-probe, instead of serving a <=10s-stale
            # $cached_status and re-deciding the wake-lock off a stale busy_age.
            # They are `my` lexicals of enter_dashboard (:2842-2843), reachable
            # only from a closure -- hence this shape.
            $last_inspect   = 0;
            $last_resources = 0;
            return $r;
        },
    );
    _keepawake_release_global();   # drop the wake-lock on clean dashboard exit
    exit($rc // 0);
}

# _run_timed($cmd, $secs) — backtick $cmd but bound it to a wall-clock
# ceiling so a wedged podman can't hang the caller forever. Best-effort:
# alarm()/SIGALRM interrupts our wait on POSIX, but (like the resource
# probes documented at :3348-3352) podman's CLI has no timeout flag of its
# own and a blocking backtick isn't portably interruptible, so on platforms
# where SIGALRM doesn't break a pending backtick (e.g. native Windows perl)
# this degrades to a no-op bound -- the same accepted gap as those probes,
# not a new one. Returns whatever the backtick produced, or undef on timeout.
sub _run_timed {
    my ($cmd, $secs) = @_;
    my $out;
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm($secs);
        $out = `$cmd`;
    };
    alarm(0);
    return $@ ? undef : $out;
}

# _machine_state() -> the podman-machine reading, as one of the six words
# Dashboard::classify_machine_state defines (s12 spec 09 S2.8). It disambiguates
# an empty container probe: with the machine up, "no such container" really means
# the container was removed; with the machine down it means we simply cannot
# tell, and a recovery must attempt the start rather than declare a rebuild
# (Dashboard::classify_container_state consumes exactly this vocabulary).
#
# NEVER dies and never blocks forever: it is called from enter_dashboard's
# pre-loop guard AND from the recover sequence's first stage, both of which run
# on the TUI's own thread of control. A wedged podman must degrade to 'unknown'
# instead of freezing the dashboard, hence the _run_timed bound.
#
# This is now only the IMPURE SHELL: run the bounded probe, hand the bytes over.
# The parse moved to Dashboard.pm because launcher.pl is not loadable by a test
# (spec S6/E2), so a parser living here can never have a behavioural oracle --
# which is exactly how four MAJOR defects survived a 651/651 green suite
# (red-team step 6). t/47 AC-31..AC-33 now cover the parse directly.
sub _machine_state {
    # DELEGATED CONTRACT (Dashboard::classify_machine_state, Dashboard.pm; the
    # parse used to be open-coded right here). That helper decodes these bytes
    # with decode_json inside its own eval; selects the DEFAULT machine -- the
    # element with a truthy `Default`, else the first hash element, which is
    # Resources::parse_machine_list's rule (Resources.pm:97-114) -- because
    # `podman machine start` takes no name and acts on the default; reads
    # `Starting` first, then a boolean-ish `Running`, then the `State` / `Status`
    # spellings other podman versions emit; and answers exactly one of
    # 'running', 'starting', 'stopped', 'absent', 'unknown' or 'n/a'. An
    # unrecognised schema, an undecodable body and an empty probe all degrade to
    # 'unknown' -- never to a confident 'stopped', which would paint a permanent
    # "podman machine is stopped" banner over a healthy sandbox.
    #
    # Same platform guard gather() uses for machine_capable (:2991): docker, and
    # Linux-native podman, have no machine at all -- that is not a failure.
    my $capable = ($PODMAN =~ /podman/i && $^O ne 'linux') ? 1 : 0;
    return 'n/a' unless $capable;
    my $probe_timeout = ($ENV{SANDBOX_RECOVER_PROBE_TIMEOUT}
                         && $ENV{SANDBOX_RECOVER_PROBE_TIMEOUT} =~ /^\d+$/)
                        ? $ENV{SANDBOX_RECOVER_PROBE_TIMEOUT} : 10;
    my $out = _run_timed(qq{$PODMAN machine list --format json 2>/dev/null}, $probe_timeout);
    my $st  = eval { Dashboard::classify_machine_state($out, $capable) };
    return 'unknown' if $@ || !defined $st || ref $st;
    return $st;
}

# _lifecycle_run($mode, \%state, $progress) — s11-lifecycle-stop spec 08 S2.8:
# the real, impure seams for Dashboard::run_stages. $mode is 'stop-runs' or
# 'full-shutdown'; $progress is the status_cb coderef the loop built (it
# repaints the frame on every stage transition). Never called from a unit
# test (see t/46 PART 9's note) -- covered only by source-text assertions
# plus review (AC-21).
sub _lifecycle_run {
    my ($mode, $state, $progress) = @_;
    my $plan = ($mode eq 'full-shutdown')
        ? Dashboard::full_shutdown_plan($state)
        : Dashboard::stop_runs_plan($state);

    my $busy_stale = ($ENV{BUSY_STALE_SECS} && $ENV{BUSY_STALE_SECS} =~ /^\d+$/)
                       ? $ENV{BUSY_STALE_SECS} : 600;

    return Dashboard::run_stages(
        plan            => $plan,
        mode            => $mode,
        self_container  => $CONTAINER_NAME,
        await_timeout   => ($ENV{SANDBOX_STOP_TIMEOUT} // 60),
        await_interval  => ($ENV{SANDBOX_STOP_INTERVAL} // 1),
        now             => sub { time },
        sleep_for       => sub { select undef, undef, undef, $_[0] },
        status_cb       => $progress,
        log_cb          => sub { log_ev($_[0], $_[1]) },
        signal_runs     => sub {
            return Dashboard::write_shutdown_signals(Dashboard::shutdown_targets($PROJECT_PATH));
        },
        quiet_probe     => sub {
            # Same busy-lease arithmetic as gather() (:2912-2918), read live
            # (not the cached copy) so a stop cycle sees the freshest lease.
            my @coords;
            eval { @coords = @{ RunState::summarize("$PROJECT_PATH/.ccpraxis-local-data/blueprints") }; };
            my $running = 0;
            for my $s (@coords) {
                next unless ref $s eq 'HASH';
                $running = 1 if ($s->{running_coordinators} || 0) > 0
                              || (defined $s->{state} && $s->{state} eq 'running');
            }
            if ($running) {
                my $n = 0;
                $n += ($_->{running_coordinators} || 0) for @coords;
                return { quiet => 0, detail => "$n coordinator(s) running" };
            }
            # Bounded (:5s each) -- a wedged podman must not hang await_quiet's
            # poll loop indefinitely and freeze the TUI (see _run_timed above).
            my $bm = _run_timed(qq{$PODMAN exec "$CONTAINER_NAME" stat -c %Y /tmp/.butler-busy 2>/dev/null}, 5);
            my $cn = _run_timed(qq{$PODMAN exec "$CONTAINER_NAME" date +%s 2>/dev/null}, 5);
            my ($lmt)  = ($bm && $bm =~ /^(\d+)/) ? ($1) : ();
            my ($cnow) = ($cn && $cn =~ /^(\d+)/) ? ($1) : ();
            my $busy_age;
            if (defined $lmt && defined $cnow) {
                my $a = $cnow - $lmt;
                $busy_age = $a < 0 ? 0 : $a;
            }
            # An unreadable lease (exec failed / container gone) counts as
            # released -- we cannot prove busy, and the container may already
            # be going away.
            if (KeepAwake::should_stay_awake($busy_age, $busy_stale)) {
                return { quiet => 0, detail => "busy lease fresh (${busy_age}s)" };
            }
            return { quiet => 1, detail => '' };
        },
        stop_container  => sub {
            return { ok => 1, detail => 'already stopped' }
                unless container_status($CONTAINER_NAME) eq 'running';
            # Edge case 12: release the wake-lock BEFORE stopping the
            # container -- a stopped container can never refresh the busy
            # lease, so the lock must drop first or it leaks.
            _keepawake_release_global();
            my $out = `$PODMAN stop "$CONTAINER_NAME" 2>&1`;
            my $rc  = $? >> 8;
            return { ok => ($rc == 0 ? 1 : 0), detail => ($rc == 0 ? '' : "exit $rc: $out") };
        },
        list_containers => sub {
            # Decision #15: RUNNING containers only, UNFILTERED -- no -a and
            # no name/image/label filter of any kind. Any other container
            # blocks the machine stop.
            my $out = `$PODMAN ps --format "{{.Names}}" 2>/dev/null`;
            my $rc  = $?;
            return undef unless defined $out;
            # Unconditional: a non-zero exit CAN still carry partial stdout
            # (truncated enumeration), and a truncated list is indistinguishable
            # from a complete one that legitimately has few/no entries. Gating
            # the exit-code check on empty output let a truncated listing that
            # dropped a sibling project's container be trusted as complete,
            # which could stop the shared podman machine out from under a
            # live sibling sandbox. Any non-zero exit -> unusable enumeration
            # -> fail closed (undef; run_stages skips the machine stop).
            return undef if $rc != 0;
            return [ split /\s+/, $out ];
        },
        stop_machine    => sub {
            my $rc = system($PODMAN, 'machine', 'stop');
            return { ok => ($rc == 0 ? 1 : 0), detail => ($rc == 0 ? '' : "exit $rc") };
        },
    );
}

# recover_container(\%args) -> \%result — s12 spec 09 S2.8. The impure half of
# the [l] relaunch/recover sequence, and the shared recovery seam the ledger
# promises s03 (which will call it at launch time with
# reason => 'launch-detect-broken'). %args: state (the gathered dashboard
# state), reason (a pinned tag, default 'in-tui-relaunch'), seams (overrides,
# plus the caller's emit/log callbacks).
#
# Why this is a fresh set of small seams rather than a re-entry into the setup
# spine: that spine's create/start code terminates the process on failure and
# drops a SandboxLock that enter_dashboard already released (:818/:861).
# Re-entering it from inside the TUI would kill the dashboard mid-frame and
# double-release an already-released lock. Nothing below ever does either -- the
# stages only ever RETURN, and Dashboard::run_recover_stages eval-wraps each one
# so even a dying seam cannot escape into the input drain.
#
# Injected seams OVERRIDE production. That is how s03 can supply a real
# container_create later without production growing one: R1 forbids an in-TUI
# recreate, so container_create is deliberately absent from %seams below and a
# genuinely removed container reports the gone-diagnosis instead.
sub recover_container {
    my ($args) = @_;
    $args = {} unless ref($args) eq 'HASH';
    my $state  = ref($args->{state}) eq 'HASH' ? $args->{state} : {};
    my $reason = (defined $args->{reason} && length $args->{reason})
                 ? $args->{reason} : 'in-tui-relaunch';
    my $inj    = ref($args->{seams}) eq 'HASH' ? $args->{seams} : {};

    my %seams = (
        machine_status => sub {
            # ok => 1 even for an 'unknown' reading: the container probe may
            # still resolve on its own, and the driver only treats ok => 0 as
            # fatal. The reading itself is what the later stages branch on.
            my $m = _machine_state();
            return { ok => 1, state => $m, detail => "machine $m" };
        },
        machine_start => sub {
            # Problem 5: `podman machine start` blocks for minutes on a cold
            # WSL2 VM, synchronously inside the TUI's input drain. _run_timed
            # bounds it where SIGALRM can break a pending backtick; on native
            # Windows perl it degrades to a no-op bound (see _run_timed's own
            # header) and the freeze is instead ANNOUNCED by the pre-stage
            # frame Dashboard::_recover_pre_detail paints before this runs.
            my $secs = ($ENV{SANDBOX_RECOVER_MACHINE_TIMEOUT}
                        && $ENV{SANDBOX_RECOVER_MACHINE_TIMEOUT} =~ /^\d+$/)
                       ? $ENV{SANDBOX_RECOVER_MACHINE_TIMEOUT} : 180;
            my $out = _run_timed(qq{$PODMAN machine start 2>&1}, $secs);
            return { ok => 0, timeout => 1,
                     detail => "podman machine start did not finish within ${secs}s" }
                unless defined $out;
            my $rc = $? >> 8;
            # MAJOR-3 (red-team step 6): `podman machine start` against a VM that
            # is already running OR already starting returns 125 with
            # "VM already running or starting". That is the state the user is
            # trying to reach, so it is a SUCCESS here, not a failure -- reporting
            # it as one used to abort the recovery at stage 2 and leave the
            # container untouched, in exactly the host-resume case [l] exists for.
            my $err = _trim_err($out);
            return { ok => 1, detail => 'machine already running or starting' }
                if $rc == 125 || $err =~ /already running or starting/i;
            return { ok => ($rc == 0 ? 1 : 0),
                     detail => ($rc == 0 ? 'machine started' : "rc $rc: $err") };
        },
        container_start => sub {
            return { ok => 1, detail => 'already running' }
                if container_status($CONTAINER_NAME) eq 'running';
            # CAPTURE (don't inherit) podman's output -- the same defence, for
            # the same reason, as _heartbeat_once (:3287-3294) and the
            # stop_container seam (:3162). This runs synchronously inside the
            # TUI's input drain, with the terminal in cbreak AND on the
            # alt-screen, and the renderer is a per-row diff against $prev.
            # `podman start <name>` echoes the container name ON SUCCESS: that
            # newline scrolls the alt-screen by one row, every later diff-render
            # then writes each row one line off, and because only rows whose
            # CONTENT changed are repainted the misalignment is never repaired
            # (only [r], which drops $prev, fixes it -- and nothing tells the
            # user that). The failure path is worse: multi-line `Error: ...`
            # text straight into the live frame. Capturing also turns the
            # stage's detail from a bare "rc 125" into podman's own sentence.
            my $out  = `$PODMAN start "$CONTAINER_NAME" 2>&1`;
            my $code = $? >> 8;
            # The sentinel refresh is the VERY NEXT podman invocation after the
            # start -- no status probe, no inspect, nothing in between -- so the
            # heartbeat is re-established promptly; the plan then runs
            # heartbeat-reattach immediately after this stage and refreshes it
            # again. MINOR-2 (red-team step 6): this used to cite a "10 s startup
            # grace". That was fiction, off by 60x -- container/heartbeat.sh:26-27
            # sets HB=600 and STARTUP_GRACE=600, i.e. TEN MINUTES. The adjacency
            # is kept because touching early is unconditionally correct and free,
            # NOT because of a ten-second cliff that never existed.
            if ($code == 0) {
                my $touch_out = `$PODMAN exec "$CONTAINER_NAME" touch /tmp/.launcher-alive 2>&1`;
            }
            my $err = _trim_err($out);
            # MINOR-4: a container removed while the machine was down classifies
            # 'unknown', so it never reaches run_recover_stages' 'absent' branch
            # and its gone-diagnosis. Re-probe here: an empty status after a
            # failed start means the container is genuinely gone, and the user
            # needs the instruction, not a number.
            my $detail;
            if ($code == 0) { $detail = 'container started'; }
            elsif (container_status($CONTAINER_NAME) eq '') {
                $detail = 'container no longer exists; in-TUI recreate is not available'
                        . ' - [q] quit, then re-run claude-sandbox to rebuild';
            }
            else { $detail = "rc $code" . (length($err) ? ": $err" : ''); }
            # The code field is spelled `rc` here on purpose. The setup path
            # (:2673) emits this SAME container_start event type with the other
            # common spelling of that field, which AC-27(c) forbids anywhere in
            # recover_container's body -- so the two emitters differ by
            # constraint, not by accident. Do not "harmonise" them from this side.
            log_ev('container_start', { rc => $code, container => $CONTAINER_NAME, reason => $err });
            return { ok => ($code == 0 ? 1 : 0), detail => $detail };
        },
        heartbeat_reattach => sub {
            my $hb = _heartbeat_once();
            return { ok => ($hb eq 'ok' ? 1 : 0), detail => "heartbeat $hb" };
        },
        %$inj,
    );

    return Dashboard::run_recover_stages(
        plan      => Dashboard::recover_plan($state),
        mode      => 'recover',
        reason    => $reason,
        state     => $state,
        status_cb => $seams{emit},
        log_cb    => $seams{log},
        map { $_ => $seams{$_} } qw(machine_status machine_start container_start
                                    container_create heartbeat_reattach),
    );
}

# _heartbeat_once — touch the container's keep-alive sentinel. Returns
# 'ok' | 'fail' | 'gone' (the dashboard ends its loop on 'gone'). Shared by
# the TUI seam and the plain loop so the container-gone detection lives once.
sub _heartbeat_once {
    # CAPTURE (don't inherit) podman's stderr. When the podman machine SSH
    # connection drops — e.g. the host enters Modern Standby and the WSL2 VM is
    # suspended — `podman exec` prints a multi-line "Cannot connect to Podman …
    # wsarecv: An existing connection was forcibly closed …" error. With the
    # dashboard on the alt-screen, an inherited STDERR would splatter that text
    # across the live frame (the corruption André saw). Backticks + 2>&1 keep it
    # off-screen (MSYS2_ARG_CONV_EXCL=* is set, so the /tmp path passes through),
    # and the captured reason is surfaced in the launch log instead.
    my $out = `$PODMAN exec "$CONTAINER_NAME" touch /tmp/.launcher-alive 2>&1`;
    my $rc  = $?;
    if ($rc != 0) {
        my $state = `$PODMAN inspect --format '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null`;
        chomp $state if defined $state;
        $state //= '';
        my $reason = _trim_err($out);
        if ($state ne 'running') {
            log_ev('container_gone', { state => $state, container => $CONTAINER_NAME, reason => $reason });
            return 'gone';
        }
        # $? is a wait status: exit code is >>8, low 7 bits are the signal. A
        # podman reaped by a signal (host waking from standby kills the WSL2 VM)
        # has exit 0 but a non-zero signal — log both so the field that exists to
        # diagnose these wakeup failures isn't misleadingly 0.
        log_ev('heartbeat_fail', { exit => ($rc >> 8), signal => (($rc & 127) || undef),
                                   state => $state, reason => $reason });
        return 'fail';
    }
    log_ev('heartbeat', {});
    return 'ok';
}

# _trim_err($s) -> $s collapsed to a single, bounded line for a log field: fold
# whitespace/newlines to single spaces, strip ends, cap length. Keeps a captured
# multi-line podman error readable as one JSON log value.
sub _trim_err {
    my ($s) = @_;
    return '' unless defined $s;
    $s =~ s/\s+/ /g;
    $s =~ s/^\s+|\s+$//g;
    $s = substr($s, 0, 300) . '...' if length($s) > 300;
    return $s;
}

# ---------------------------------------------------------------------
# B5 keep-awake helpers — the real spawn/kill seams for the KeepAwake holder.
# The host perl is Git-for-Windows (cygwin) perl with no Win32::API, so the
# wake-lock is a dedicated PowerShell child (keep-awake.ps1) whose lifetime IS
# the lock's lifetime. NOTE: the actual spawn/kill + whether the machine really
# stays awake is verified on a real desktop (attended); the decision + lifecycle
# logic is unit-tested in KeepAwake.pm / t/28.
# ---------------------------------------------------------------------

# _keepawake_start($ps1, $pidfile) -> child pid | undef. fork+exec the PowerShell
# helper detached (stdio to /dev/null so it can't touch the dashboard alt-screen).
# Returns the cygwin child pid (the holder's handle, used by _keepawake_stop).
# The helper self-reports its WINDOWS pid into $pidfile for cross-crash reaping.
sub _keepawake_start {
    my ($ps1, $pidfile) = @_;
    unless (-f $ps1) {
        log_ev('keepawake_start_failed', { reason => "helper missing: $ps1" });
        return undef;
    }
    my $win_ps1 = winify_path($ps1);
    my $win_pid = winify_path($pidfile);
    my $pid = fork();
    if (!defined $pid) {
        log_ev('keepawake_start_failed', { reason => "fork: $!" });
        return undef;
    }
    if ($pid == 0) {
        # child: detach stdio, then exec the helper. _exit (not exit) on failure
        # so the parent's END handlers don't run in the child.
        open(STDIN,  '<', '/dev/null');
        open(STDOUT, '>', '/dev/null');
        open(STDERR, '>', '/dev/null');
        local $ENV{MSYS2_ARG_CONV_EXCL} = '*';
        exec('powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass',
             '-WindowStyle', 'Hidden', '-File', $win_ps1, '-PidFile', $win_pid)
            or do { POSIX::_exit(127); };
    }
    log_ev('keepawake_started', { pid => $pid });
    return $pid;
}

# _keepawake_stop($child_pid, $pidfile) — kill our helper child (releases the
# wake-lock: process death drops ES_CONTINUOUS) and clear the pidfile. SIGKILL so
# it's immediate; waitpid reaps the zombie (it's a direct fork of ours).
sub _keepawake_stop {
    my ($pid, $pidfile) = @_;
    if (defined $pid && $pid =~ /^\d+$/ && $pid > 0) {
        kill('KILL', $pid);
        waitpid($pid, 0);
        log_ev('keepawake_stopped', { pid => $pid });
    }
    unlink $pidfile if defined $pidfile && -f $pidfile;
}

# _keepawake_reap_orphan($pidfile) — on dashboard entry, kill a helper left
# running by a previously-CRASHED launcher (its wake-lock would persist forever).
# Uses the helper's self-reported WINDOWS pid + taskkill, guarded by a cmdline
# check (KeepAwake::orphan_is_ours) that confirms the process is our keep-awake.ps1
# so a recycled pid that now belongs to something else is left alone.
sub _keepawake_reap_orphan {
    my ($pidfile) = @_;
    return unless defined $pidfile && -f $pidfile;
    my $wpid = _read_file($pidfile);
    chomp $wpid if defined $wpid;
    unlink $pidfile;
    return unless defined $wpid && $wpid =~ /^\d+$/;
    local $ENV{MSYS2_ARG_CONV_EXCL} = '*';
    my $cmdline = `powershell.exe -NoProfile -Command "(Get-CimInstance Win32_Process -Filter \\"ProcessId=$wpid\\" -ErrorAction SilentlyContinue).CommandLine" 2>/dev/null`;
    chomp $cmdline if defined $cmdline;
    if (KeepAwake::orphan_is_ours($cmdline, 'keep-awake.ps1')) {
        system('taskkill.exe', '/PID', $wpid, '/F', '/T');
        log_ev('keepawake_orphan_reaped', { pid => $wpid });
    }
}

# ---------------------------------------------------------------------
# B3/B4 dashboard gather helpers (host-side reads feeding build_panels).
# ---------------------------------------------------------------------

# _count_needs_you($project) -> count of queued "needs you" decision entries
# across every blueprint's runs/needs-you/ (Decision #27's dashboard indicator).
# opendir/readdir (not glob) so project paths with spaces / André bytes are safe.
sub _count_needs_you {
    my ($project) = @_;
    my $base = "$project/.ccpraxis-local-data/blueprints";
    return 0 unless -d $base;
    my $n = 0;
    opendir(my $bd, $base) or return 0;
    for my $bp (readdir $bd) {
        next if $bp eq '.' || $bp eq '..';
        my $nd = "$base/$bp/runs/needs-you";
        next unless -d $nd;
        opendir(my $d, $nd) or next;
        for my $f (readdir $d) {
            next if $f =~ /^\./ || $f =~ /\.tmp$/;   # skip dotfiles + atomic-write temps
            $n++ if -f "$nd/$f";
        }
        closedir $d;
    }
    closedir $bd;
    return $n;
}

# _gather_runs($project) -> ARRAYREF of RunState summaries (never undef).
# Read-only; no writes, no spawning, no logging of file contents. Cheap disk
# reads, so it rides the same 10s cadence as _count_needs_you/_gather_backpack/
# _gather_tokens above -- deliberately NOT the slower Resources::should_sample
# cadence, which exists to throttle expensive podman-exec probes (s10).
sub _gather_runs {
    my ($project) = @_;
    return RunState::summarize("$project/.ccpraxis-local-data/blueprints");
}

# _gather_backpack($bp_file, $appr_file) -> { total, approved, items=>[{key,
# approved}] } for the B4 panel, or undef when there's no backpack. Cheap (two
# small host JSON reads); reuses BackpackApproval so the panel's approval state
# matches the #21 gate exactly.
sub _gather_backpack {
    my ($bp_file, $appr_file) = @_;
    return undef unless -f $bp_file;
    my $data = eval { JSON::PP->new->decode(_read_file($bp_file) // '') };
    return { total => 0, approved => 0, items => [] }
        unless ref $data eq 'HASH' && ref $data->{items} eq 'ARRAY';
    my $appr = BackpackApproval::load($appr_file);
    my (@items, $napprove);
    $napprove = 0;
    for my $it (@{ $data->{items} }) {
        next unless ref $it eq 'HASH';
        my $ok = BackpackApproval::is_approved($it, $appr) ? 1 : 0;
        $napprove++ if $ok;
        push @items, { key => BackpackApproval::item_key($it), approved => $ok };
    }
    return { total => scalar(@items), approved => $napprove, items => \@items };
}

# _gather_oauth_expiry() -> epoch-seconds when the OAuth token expires, or undef.
# Reads $SANDBOX_CREDENTIALS_FILE (read-only; never writes/refreshes it), decodes
# JSON, and extracts claudeAiOauth.expiresAt (milliseconds -> seconds). Returns
# undef when the file is absent, unparseable, or lacks the key.
sub _gather_oauth_expiry {
    my $raw = _read_file($SANDBOX_CREDENTIALS_FILE);
    return undef unless defined $raw && length $raw;
    my $data = eval { JSON::PP->new->decode($raw) };
    return undef unless ref $data eq 'HASH';
    my $oauth = $data->{claudeAiOauth};
    return undef unless ref $oauth eq 'HASH';
    my $exp = $oauth->{expiresAt};
    return undef unless defined $exp && $exp =~ /^\d+$/;
    return int($exp / 1000);
}

# _gather_tokens() -> the TokenInfo status struct for $SANDBOX_CREDENTIALS_FILE.
# Read-only: never writes, never refreshes, never logs the file's contents.
# Always returns a hashref (decode failure/absent file just passes undef
# through to TokenInfo::status, which degrades to the not-logged-in struct).
sub _gather_tokens {
    my $raw   = _read_file($SANDBOX_CREDENTIALS_FILE);
    local $@;
    my $data  = (defined $raw && length $raw)
              ? eval { JSON::PP->new->decode($raw) } : undef;
    my $mtime = (stat($SANDBOX_CREDENTIALS_FILE))[9];
    return TokenInfo::status($data, $mtime, time);
}

# _ps_commands() -> (key => literal PowerShell command). The CLOSED set of
# commands _powershell_json is allowed to run, named once so the sink can
# enforce membership instead of merely documenting it.
#
# -OperationTimeoutSec 3 is the one REAL wall-clock cap in this package.
# -Filter uses single quotes inside the double-quoted -Command so no nested
# double-quote escaping is needed. Nothing here is interpolated — adding a
# "$var" to any of these strings is the change this design exists to stop.
sub _ps_commands {
    return (
        cim_mem  => "Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 3 | Select-Object FreePhysicalMemory,TotalVisibleMemorySize | ConvertTo-Json -Compress",
        cim_cpu  => "Get-CimInstance Win32_Processor -OperationTimeoutSec 3 | Select-Object LoadPercentage,NumberOfLogicalProcessors | ConvertTo-Json -Compress",
        cim_disk => "Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -OperationTimeoutSec 3 | Select-Object DeviceID,FreeSpace,Size | ConvertTo-Json -Compress",
    );
}

# _powershell_json($cmd) -> raw stdout BYTES (BOM included; the Resources
# parsers strip it), or undef off Windows. s09's one host-probe transport.
#
# -NoProfile: a profile load is slow and can print noise onto the alt-screen.
# -NonInteractive: a credential/confirmation prompt would otherwise hang the
# dashboard FOREVER — this is real hang prevention, not cosmetics.
# (-ExecutionPolicy is deliberately NOT passed: it governs loading script
# files, not an inline -Command, so it would relax a machine setting for
# nothing.)
# stderr goes to 2>/dev/null, never to a Windows device name (a `> N-U-L`
# redirect from bash creates a literal file Explorer cannot delete).
# MSYS2_ARG_CONV_EXCL is set locally, mirroring the precedent above.
#
# INJECTION: "$cmd" is interpolated into a backtick (an MSYS sh layer, where
# $, backtick and \ are live inside double quotes) and THEN into PowerShell's
# -Command (where ;, |, & and $(...) are operators). Two hostile grammars, one
# unquoted slot — so the slot is closed by construction: $cmd must be
# IDENTICAL to one of the _ps_commands strings or the probe returns undef and
# the panel prints n/a. A future caller that tries to fold the drive letter,
# the container name or a probe's own output into the command gets n/a, not
# host command execution from a directory name.
sub _powershell_json {
    my ($cmd) = @_;
    return undef unless $WINDOWS_FAMILY;
    return undef unless defined $cmd && !ref $cmd;
    my %allowed = _ps_commands();
    return undef unless grep { $_ eq $cmd } values %allowed;
    local $ENV{MSYS2_ARG_CONV_EXCL} = '*';
    return scalar `powershell.exe -NoProfile -NonInteractive -Command "$cmd" 2>/dev/null`;
}

# _resources_probes() -> { key => coderef }, the real I/O half of the s09
# probe round. Resources::gather invokes these under eval with an elapsed
# budget; nothing here parses anything.
#
# The machine + host probes are Windows-only: `podman machine` is meaningless
# on Linux and there is no host shell to query, so those keys are simply
# absent, gather never invokes them, and those fields degrade to n/a — which
# is exactly how the panel renders inside the Linux container itself.
#
# The machine probe additionally requires podman: `machine list` does not
# exist under docker, so spawning it there would burn a subprocess every 23s
# to produce the same n/a. Guard mirrors the precedent at the SANDBOX_HOST_IP
# capture above.
#
# The CIM commands' -OperationTimeoutSec 3 is the one REAL wall-clock cap in
# this package (it covers the three host probes only; podman's CLI offers no
# timeout flag for stats / system df / machine list, and a blocking backtick
# is not portably interruptible — the throttle and the elapsed budget bound
# the blast radius).
sub _resources_probes {
    my %p = (
        stats => sub { scalar `$PODMAN stats --no-stream --format json 2>/dev/null` },
        df    => sub { scalar `$PODMAN system df --format json 2>/dev/null` },
    );
    return \%p unless $WINDOWS_FAMILY;
    my %cmd = _ps_commands();
    $p{machine}  = sub { scalar `$PODMAN machine list --format json 2>/dev/null` }
        if $PODMAN =~ /podman/i;
    $p{cim_mem}  = sub { _powershell_json($cmd{cim_mem}) };
    $p{cim_cpu}  = sub { _powershell_json($cmd{cim_cpu}) };
    $p{cim_disk} = sub { _powershell_json($cmd{cim_disk}) };
    return \%p;
}

# _gather_resources() -> the 15-key resource struct for the dashboard panel.
# The thin wrapper that owns everything impure: the real probe coderefs, the
# container/drive selectors, and the clock (time() is called HERE, never
# inside Resources.pm). The drive is derived from the project path and
# defaults to C: — not a fabrication, because the panel prints the device it
# measured.
sub _gather_resources {
    my $dev;
    if ($WINDOWS_FAMILY) {
        $dev = ($PROJECT_PATH =~ m{^([A-Za-z]):}) ? uc($1) . ':' : 'C:';
    }
    # budget/now: the clock injected here is core time(), i.e. INTEGER seconds,
    # so `4` is an advisory floor checked at 1-second resolution before each
    # probe — the round can legitimately overrun it by the better part of a
    # second plus however long the probe already running takes. Do not read it
    # as a 4-second cap (Resources::gather's header states the same contract).
    # A sub-second clock would tighten the resolution but not the cap, and the
    # `now => sub { time }` shape is what the oracle pins.
    return Resources::gather(_resources_probes(), {
        container => $CONTAINER_NAME,
        device    => $dev,
        budget    => 4,
        now       => sub { time },
    });
}

# _tail_lines — last $n chomped lines of a file (the B1 launch log), or ().
# Seek-based + byte-capped: a long-lived dashboard re-reads this every state
# tick, and the log grows for the whole run, so reading the WHOLE file each time
# would be unbounded. Read only the last 128 KB (plenty for $n lines), dropping
# the first partial line when we start mid-file.
sub _tail_lines {
    my ($path, $n) = @_;
    open my $fh, '<', $path or return ();
    binmode $fh, ':raw';
    my $size = -s $fh;
    $size = 0 if !defined $size;
    my $cap  = 128 * 1024;
    my $from = $size > $cap ? $size - $cap : 0;
    seek $fh, $from, 0;
    local $/;
    my $blob = <$fh>;
    close $fh;
    return () if !defined $blob || !length $blob;
    $blob =~ s/^[^\n]*\n// if $from > 0;   # drop the partial leading line
    my @lines = split /\n/, $blob;
    chomp @lines;
    return @lines > $n ? @lines[-$n .. -1] : @lines;
}

# _history_events($dir, $exclude) -> @groups -- spec S2.4b (s13-activity-history).
# One span-row group per prior launch log, OLDEST session first, suitable as
# the leading groups of LaunchLog::merge_sessions. Any failure degrades to no
# history at all -- the dashboard behaves exactly as it did before this
# package.
sub _history_events {
    my ($dir, $exclude) = @_;
    my @groups;
    eval {
        my @paths = LaunchLog::recent_logs($dir, $HISTORY_LOG_FILES, $exclude);  # newest-first
        for my $p (reverse @paths) {                                # -> oldest-first
            my @lines = _tail_lines($p, $HISTORY_TAIL_LINES);
            # HISTORY-only: filter heartbeat/tick noise before the events/file cap
            # applies, so the events kept are the ones that explain the session
            # rather than N heartbeats from a long-lived run. Current-session live
            # tail (the gather callback's own @lines / $cur) is untouched.
            @lines = grep { !_is_heartbeat_line($_) } @lines;
            my $ev = Dashboard::recent_events(\@lines, $HISTORY_EVENTS_PER_LOG);
            if (ref $ev eq 'ARRAY') {
                # HISTORY-only: clamp bytes-per-span so a planted oversized field
                # in a prior log can't pin an expensive row for the dashboard's
                # entire lifetime (one-shot read, never re-read, never pruned).
                for my $row (@$ev) {
                    next unless ref $row eq 'ARRAY';
                    for my $span (@$row) {
                        next unless ref $span eq 'HASH' && defined $span->{text};
                        $span->{text} = substr($span->{text}, 0, $HISTORY_SPAN_TEXT_MAX)
                            if length($span->{text}) > $HISTORY_SPAN_TEXT_MAX;
                    }
                }
            }
            push @groups, $ev if ref $ev eq 'ARRAY' && @$ev;
        }
        1;
    } or do { @groups = () };      # any failure -> no history, dashboard behaves exactly as today
    return @groups;
}

# _gather_orchestrator_events($runs) -> ARRAYREF of span-rows -- spec S2
# (s16-fleet-event-source). Mirrors _history_events' degrade posture exactly:
# any failure (no active blueprint run, no orchestrator.log, unreadable,
# malformed JSONL) degrades to no orchestrator events at all -- the dashboard
# still renders. $runs is the already-gathered RunState::summarize() list
# (s10's $cached_runs), reused rather than re-walked here, so this stays a
# single bounded file read per tick: at most one orchestrator.log, tailed at
# most once, host-visible under the project's .ccpraxis-local-data/ tree
# (RunState's runs_dir is "<project>/.ccpraxis-local-data/blueprints/<bp>/runs").
sub _gather_orchestrator_events {
    my ($runs) = @_;
    my $ev = [];
    eval {
        # RunState's runs_dir is host-visible under the project's
        # .ccpraxis-local-data/ tree (.ccpraxis-local-data/blueprints/<bp>/runs).
        my @candidates = grep { ref($_) eq 'HASH' && defined $_->{runs_dir} } @{ $runs || [] };
        my ($active) = grep { ($_->{state} || '') eq 'running' } @candidates;
        ($active) = grep { ($_->{state} || '') eq 'paused' } @candidates if !$active;
        if ($active) {
            my $log = "$active->{runs_dir}/orchestrator.log";
            if (-f $log) {
                my @lines = _tail_lines($log, $ORCH_TAIL_LINES);
                my $rows  = Dashboard::recent_events(\@lines, $ORCH_EVENTS_PER_LOG);
                $ev = $rows if ref $rows eq 'ARRAY';
            }
        }
        1;
    } or do { $ev = [] };          # any failure -> no orchestrator events, dashboard still renders
    return $ev;
}

# _gather_spend($runs) -> \%info | undef (b37-spend-surfaces).
#
# Reads a spend snapshot the butler run has ALREADY persisted and hands it to
# SpendPanel::status for rendering. Mirrors _gather_orchestrator_events: locate
# the active run, read one host-visible file, degrade to nothing on any failure.
#
# ⚠ THIS DELIBERATELY MAKES NO NETWORK CALL, and that is the load-bearing
# decision rather than an omission. BpSpend::fetch reaches for bp-http.pl, the
# house curl wrapper — a SUBPROCESS, i.e. a fork, and this runs on the dashboard
# render tick. s17 has just spent an entire package REMOVING the one recurring
# fork from this path, on the very platform where forking is already failing
# ("Can't fork, trying again in 5 seconds"). Re-introducing a network fork here
# would undo that and could block the TUI for the length of a timeout.
#
# So the launcher is a READER only. The fleet polls on its own cadence — b36
# already owns the cadence floor and the TTL cache — and the TUI renders
# whatever it last wrote.
#
# ⚠ KNOWN GAP, ESCALATED, NOT PAPERED OVER: b36 does not currently WRITE such a
# snapshot. It emits `spend_fetch` events through BpLog (outcome and status, not
# figures) and returns its struct in-process to its caller. Until b36 persists
# one, this returns undef and the Spend panel is simply ABSENT — never wrong,
# never a fabricated zero. Deciding that artifact's location, lifecycle and
# redaction belongs to b36, whose defining constraint is that the OpenCode
# session cookie is the broadest secret in the system: a persisted spend
# snapshot must provably never carry it. That is not a call to make inside a
# rendering package. See the b37 ledger.
sub _gather_spend {
    my ($runs) = @_;
    my $info;
    eval {
        my @candidates = grep { ref($_) eq 'HASH' && defined $_->{runs_dir} } @{ $runs || [] };
        my ($active) = grep { ($_->{state} || '') eq 'running' } @candidates;
        ($active) = grep { ($_->{state} || '') eq 'paused' } @candidates if !$active;
        return unless $active;
        my $snap = "$active->{runs_dir}/spend.json";
        return unless -f $snap;
        my $raw = do { local $/; open my $fh, '<:raw', $snap or return; <$fh> };
        return unless defined $raw && length $raw;
        my $spend = JSON::PP->new->decode($raw);
        return unless ref $spend eq 'HASH';
        $info = SpendPanel::status($spend, time);
        1;
    } or do { $info = undef };     # any failure -> no panel, dashboard still renders
    return (ref $info eq 'HASH') ? $info : undef;
}

# _row_time_key($row) -> seconds-since-local-midnight | undef (private helper
# for the s16 cross-source interleave). recent_events rows don't carry a raw
# epoch, only the already-rendered "HH:MM:SS  " muted span (Dashboard.pm's
# _event_time), so that is the best-effort comparable key LaunchLog::merge_by_key
# needs. Unparseable -> undef, which merge_by_key treats as "keep this source's
# own append order" rather than as an error.
# _row_time_key($row) -> seconds-since-midnight, or undef.
#
# The caller-supplied key extractor for LaunchLog::merge_by_key (s16 spec S1.1).
# Best-effort by construction: rendered rows carry no raw epoch, only the muted
# HH:MM:SS span, so this recovers what is there.
#
# TWO KNOWN LIMITATIONS, recorded rather than left for the next reader to
# rediscover. Both are bounded by the spec's ordering ruling (S1): within a
# source, append order is authoritative and is NEVER violated -- merge_by_key is
# stable and only ever compares the two sources' HEADS, so neither limitation can
# reorder a source's own events. Only CROSS-SOURCE placement is affected, which
# the ruling already declares best-effort.
#
#   1. MIDNIGHT WRAP. This key resets to 0 at midnight, so for the rest of that
#      tick an event at 00:00:05 (key 5) sorts before one at 23:59:55 (key
#      86395). Unlike clock skew this is systematic, not occasional: any run
#      crossing midnight hits it, and this blueprint documents 13-hour fleet
#      runs. The visible symptom is a handful of fleet events appearing slightly
#      early in the panel around the boundary -- never a scrambled source.
#      Fixing it properly means carrying a raw epoch on the row, which changes a
#      structure s06 owns and that t/41's 453 assertions pin; that is a
#      deliberate escalation, not a silent widening.
#
#   2. COUPLING TO RENDERED TEXT. This parses display output to recover a sort
#      key. s17 is next on this same panel; if it changes the leading timestamp
#      span, this returns undef, the merge degrades to source-order fallback,
#      and NOTHING FAILS LOUDLY. Whoever touches that rendering must re-check
#      here.
sub _row_time_key {
    my ($row) = @_;
    return undef unless ref $row eq 'ARRAY' && @$row && ref $row->[0] eq 'HASH';
    my $t = $row->[0]{text};
    return undef unless defined $t && $t =~ /^(\d\d):(\d\d):(\d\d)/;
    return $1 * 3600 + $2 * 60 + $3;
}

# _spawn_session — the dashboard's launch-claude hotkey: open a NEW Windows
# Terminal window running the internal connector entry
# (`claude-sandbox --session <project>`). A native wt.exe can't exec the .ps1 by
# bare name, so we drive it through powershell -File.
#
# Windows Terminal is REQUIRED (user directive / Decision #19): there is NO silent
# degradation to a bare PowerShell console. If wt.exe is not installed we FAIL
# LOUDLY — suspend the TUI, print a clear, actionable error, wait for a keypress,
# and return to the dashboard. find_wt asserts availability (PATH + the canonical
# %LOCALAPPDATA%\Microsoft\WindowsApps app-execution-alias location).
sub _spawn_session {
    my @inner = ('powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass',
                 '-File', $SANDBOX_PS1, '--session', $PROJECT_PATH);

    my $wt = Dashboard::find_wt($ENV{PATH}, $ENV{LOCALAPPDATA});
    if (!$wt) {
        # Fail loudly: leave the alt-screen, say exactly what's missing + how to
        # fix it, block for a key, then restore the dashboard.
        print STDOUT "\e[?25h\e[?1049l";
        eval { Term::ReadKey::ReadMode('restore') };
        print STDERR "\n";
        print STDERR "  ", _c_err("ERROR:"), " Windows Terminal (wt.exe) was not found.\n";
        print STDERR "  [c] launch-claude opens a NEW Windows Terminal window and requires it —\n";
        print STDERR "  there is no fallback to a plain console (by design).\n";
        print STDERR "  Fix: install \"Windows Terminal\" from the Microsoft Store, or put wt.exe on\n";
        print STDERR "  PATH, then press [c] again.\n";
        print STDERR "  (Searched PATH and %LOCALAPPDATA%\\Microsoft\\WindowsApps.)\n";
        print STDERR "\n  Press any key to return to the dashboard...";
        eval { Term::ReadKey::ReadKey(0) };       # block for a key
        eval { Term::ReadKey::ReadMode('cbreak') };
        print STDOUT "\e[?1049h\e[?25l";
        log_ev('launch_session_failed', { reason => 'wt-not-found' });
        return 'redraw';
    }

    my $argv = Dashboard::spawn_argv('wt', { cmd => \@inner });   # ['wt.exe','-w','new',…]
    log_ev('launch_session', { mode => 'wt' });
    my $rc = system(@$argv);   # returns immediately (detached window)
    log_ev('launch_session_done', { mode => 'wt', exit => ($rc >> 8) });
    return;
}

# plain_heartbeat_loop — the non-TTY fallback: the original scrolling manager
# loop, preserved verbatim in behavior. Touch every 2 min; exit cleanly when
# the container goes away.
sub plain_heartbeat_loop {
    print "\n";
    print "=" x 60 . "\n";
    print "Sandbox ready: $CONTAINER_NAME\n";
    print "=" x 60 . "\n";
    print "This terminal is the manager — keep it open. Closing it stops\n";
    print "the sandbox (~5 minutes after the last heartbeat).\n";
    print "Press Ctrl+C to stop now.\n";
    print "\n";

    my $BEAT_INTERVAL = 120;  # Container's HB is 300 (5 min); 120s gives 2.5x margin.
    while (1) {
        sleep $BEAT_INTERVAL;
        my $hb = _heartbeat_once();
        if ($hb eq 'gone') {
            print STDERR "\n";
            print STDERR "Container $CONTAINER_NAME is no longer running.\n";
            print STDERR "Manager exiting.\n";
            reset_terminal();
            exit 0;
        }
        if ($hb eq 'fail') {
            printf STDERR "[%s] WARNING: heartbeat refresh failed; will retry next tick\n",
                strftime("%H:%M:%S", localtime);
            next;
        }
        printf "[%s] heartbeat\n", strftime("%H:%M:%S", localtime);
    }
}
