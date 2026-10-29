# StewardTest — minimal test harness for the steward vault engine.
#
# Provides: a tiny TAP-ish assertion API (ok/is/like/unlike/diag/done_testing)
# and integration helpers that run vault-sync.pl against a HOME-overridden,
# file://-bare-remote scratch vault so tests never touch the real
# ~/.claude/claude-code-vault.
#
# HOME-isolation: vault-sync.pl reads $ENV{HOME} // $ENV{USERPROFILE} ONCE at
# file scope, so HOME/USERPROFILE must be set in the CHILD env BEFORE the script
# is spawned. run_vs() does exactly that (each call is a fresh subprocess), which
# is why every scenario step shells out instead of calling subs in-process.
package StewardTest;
use strict;
use warnings;
use Exporter 'import';
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use Cwd qw(abs_path);
use JSON::PP;

our @EXPORT_OK = qw(
    ok is like unlike diag done_testing
    vault_sync_script temproot make_machine init_remote
    run_vs write_text read_text path_exists
);

# ── vault-sync.pl location (../scripts/vault-sync.pl relative to this lib) ──
my $LIB_DIR = dirname(abs_path(__FILE__));
my $SCRIPT  = abs_path("$LIB_DIR/../../scripts/vault-sync.pl");

# ── HostCaps.pm: the sole owner of scratch_root() (blueprint test-platform-
# split, package 04-scratch-root). __FILE__-derived, never FindBin/$Bin --
# $Bin is a process-wide singleton set from the INVOKING SCRIPT's directory,
# not this module's own directory, so it would resolve differently depending
# on which plugin's .t required us. Bareword `require HostCaps;` (not a
# string-path require) so every caller lands on the identical %INC key and
# the file loads exactly once no matter which of HostCaps.pm / StewardTest.pm
# / TestSandbox.pm is required first.
#
# NOTE: computed inline here, not via the pre-existing $LIB_DIR variable
# above -- `use lib` is a compile-time (BEGIN-time) construct, so it runs
# BEFORE the runtime `my $LIB_DIR = ...` assignment above has executed;
# interpolating $LIB_DIR here would silently see it undef.
use lib dirname(abs_path(__FILE__)) . "/../../../butler/tests/lib";
require HostCaps;

sub vault_sync_script { return $SCRIPT }

# ── assertions ──────────────────────────────────────────────────────
my $TEST_NUM = 0;
my $FAILS    = 0;

# ($;$) mirrors Test::More's own ok() prototype: the FIRST argument is
# evaluated in SCALAR context at every normal call site compiled after this
# declaration is visible (i.e. after `use StewardTest qw(ok ...)`, since that
# import happens at compile time before the rest of the importing file is
# parsed). Without this, `ok((grep { ... } @list), $name)` passes the grep's
# LIST-context result: with zero matches that list collapses to just
# ($name), so $cond becomes the (truthy) name string and the assertion passes
# with $name undef -- a real false-pass measured in 16-mutation-r2.md
# (MF-A). The prototype is invisible to a direct `&ok(...)` call (the `&`
# sigil deliberately bypasses prototype checking in Perl) and to any call
# that resolves at runtime rather than compile time (e.g. through a `require`
# happening after the call site was already compiled) -- for those paths this
# module cannot rely on the prototype, so it also guards at runtime below.
sub ok ($;$) {
    die "StewardTest::ok() takes at most (cond, name) -- got " . scalar(@_)
      . " args; this call bypassed the ($;\$) prototype (e.g. via &ok(...))"
        if @_ > 2;
    my ($cond, $name) = @_;
    $TEST_NUM++;
    if ($cond) {
        print "ok $TEST_NUM - $name\n";
    } else {
        $FAILS++;
        print "not ok $TEST_NUM - $name\n";
    }
    return $cond ? 1 : 0;
}

sub is {
    my ($got, $exp, $name) = @_;
    my $cond = (defined $got && defined $exp && $got eq $exp)
            || (!defined $got && !defined $exp);
    ok($cond, $name) or diag("  got:      " . (defined $got ? "[$got]" : "undef")
                           . "\n  expected: " . (defined $exp ? "[$exp]" : "undef"));
    return $cond;
}

sub like {
    my ($got, $re, $name) = @_;
    my $cond = defined $got && $got =~ $re;
    ok($cond, $name) or diag("  got: " . (defined $got ? "[$got]" : "undef") . "\n  expected match: $re");
    return $cond;
}

sub unlike {
    my ($got, $re, $name) = @_;
    my $cond = !(defined $got && $got =~ $re);
    ok($cond, $name) or diag("  got: " . (defined $got ? "[$got]" : "undef") . "\n  expected NO match: $re");
    return $cond;
}

sub diag { my $m = shift; $m =~ s/^/# /mg; print STDERR "$m\n"; }

sub done_testing {
    print "1..$TEST_NUM\n";
    exit($FAILS ? 1 : 0);
}

# ── scratch environment helpers ─────────────────────────────────────

# A unique temp root, auto-removed at process exit. Returned in /c/-style POSIX
# form — the SAME form vault-sync.pl uses internally (norm_path) and passes to
# native git, relying on MSYS to convert /c/... -> C:\... (run_vs/_run keep that
# conversion ON; see _msys_convert_on). The first candidate is
# HostCaps::scratch_root()."/steward" (blueprint test-platform-split, package
# 04-scratch-root): a single ccpraxis-owned root, pure-ASCII, spelled
# identically across the perl/git boundary (Decision 11) — unlike the
# user-profile TEMP, which Windows reports as "C:\Users\ANDR~1\..." while
# abs_path returns the long form, and that disagreement is what breaks local
# git remotes. HostCaps::scratch_root() dying on a bad CCPRAXIS_SCRATCH_ROOT
# override propagates uncaught here, deliberately — see HostCaps.pm. (Off
# Windows scratch_root() is undef, so the existing $ENV{TEMP}/$ENV{TMP}//tmp
# candidates are used exactly as before.)
sub temproot {
    my $scratch = HostCaps::scratch_root();
    my $first   = defined $scratch ? "$scratch/steward" : undef;
    my $base;
    if (defined $first) {
        # A3 (fix-batch, package 04-scratch-root, red-team M3): this
        # candidate's role changed from cosmetic (a hardcoded convenience
        # path, C:/Users/Public) to LOAD-BEARING -- it is now the one root a
        # single Defender exclusion is supposed to cover. Silently falling
        # through to %TEMP%/tmp here would defeat this whole package's
        # purpose with no diagnostic, so unlike the pre-existing candidate
        # tail below (kept only for the non-Windows/no-override case), this
        # branch is authoritative: create it, and DIE LOUDLY, naming the
        # path and reason, if it cannot be created or is not writable.
        eval { make_path($first) unless -d $first; 1 }
            or die "StewardTest: could not create scratch subdirectory "
                 . "'$first' (HostCaps::scratch_root().'/steward'): $@\n";
        die "StewardTest: scratch subdirectory '$first' "
          . "(HostCaps::scratch_root().'/steward') exists but is not "
          . "writable by the current process; refusing to fall back to "
          . "\%TEMP\%/tmp, which would silently defeat the "
          . "Defender-exclusion consolidation this root exists for.\n"
            unless -w $first;
        $base = $first;
        $base =~ s|\\|/|g;
        $base =~ s|^([a-zA-Z]):/|"/" . lc($1) . "/"|e;
    } else {
        # Fallthrough tail, unchanged from before this package: only
        # reached when scratch_root() is undef (non-Windows, no override).
        for my $cand ($ENV{TEMP}, $ENV{TMP}, '/tmp') {
            next unless defined $cand && length $cand;
            my $p = $cand;
            $p =~ s|\\|/|g;
            $p =~ s|^([a-zA-Z]):/|"/" . lc($1) . "/"|e;
            if (-d $p && -w $p) { $base = $p; last; }
        }
        die "StewardTest: no writable temp base found\n" unless $base;
    }
    my $root = tempdir('steward-test-XXXXXX', DIR => $base, CLEANUP => 1);
    # Off Windows, hand back the PHYSICAL path. On macOS /tmp is a symlink to
    # /private/tmp (and $TMPDIR lives under /var -> /private/var), while the
    # code under test pins its cwd with Cwd::cwd()/abs_path, which resolve the
    # link. A scenario that chdir()s into "/tmp/steward-test-X/proj" then sees
    # "/private/tmp/steward-test-X/proj" come back, and every byte-identity
    # assertion on the pinned cwd compares two spellings of one directory.
    # Linux /tmp is a real directory, so this is a no-op there; Windows keeps
    # the /c/-form contract described above untouched.
    unless ($^O eq 'MSWin32' || $^O eq 'cygwin' || $^O eq 'msys') {
        $root = abs_path($root) // $root;
    }
    $root =~ s|\\|/|g;
    $root =~ s|^([a-zA-Z]):/|"/" . lc($1) . "/"|e;
    return $root;
}

# Create a fake HOME for one "machine": writes a hermetic .gitconfig (identity +
# default branch main + safe.directory) so git commits work without the real
# global config. Returns the home path.
sub make_machine {
    my ($root, $name) = @_;
    my $home = "$root/$name";
    make_path($home);
    write_text("$home/.gitconfig", <<'CFG');
[user]
	name = Steward Test
	email = steward-test@example.invalid
[init]
	defaultBranch = main
[safe]
	directory = *
[commit]
	gpgsign = false
CFG
    return $home;
}

# Create an empty bare git repo with HEAD on main; return its path as the clone
# URL. We hand back the PLAIN drive-letter path (not a file:// URL): git for
# Windows clones/fetches/pushes a local plain path correctly, whereas file://
# with a drive-letter or msys path mis-resolves (see temproot).
sub init_remote {
    my ($root) = @_;
    my $remote = "$root/remote.git";
    _run('git', 'init', '--bare', '-q', $remote);
    # Force HEAD to main so the first push from a main-default clone matches.
    _run('git', '-C', $remote, 'symbolic-ref', 'HEAD', 'refs/heads/main');
    return $remote;
}

# Force MSYS path conversion ON for the current process, even when the ambient
# shell set MSYS2_ARG_CONV_EXCL=*. Used by _run() — the harness's OWN native-git
# calls (init_remote's `git init --bare`, etc.), which pass POSIX /c/... paths
# straight through. With conversion off, native git resolves the leading `/`
# against the current drive and SILENTLY CREATES C:\c\Users\... instead of
# failing; that is the 2026-06-12 drive-root leak, guarded by
# t/09-no-drive-root-strays.t. Callers scope this with `local %ENV`.
#
# NOT used by run_vs — see the note there; vault-sync.pl defends itself by a
# different mechanism and is deliberately left exposed to the ambient value.
sub _msys_convert_on { delete $ENV{MSYS2_ARG_CONV_EXCL} }

sub run_vs {
    my ($home, @args) = @_;
    # NOTE: we deliberately do NOT scrub MSYS2_ARG_CONV_EXCL here. Leaving the
    # ambient value (which may be '*') in place is what proves vault-sync.pl's own
    # defence — so scrubbing it would hide exactly the regression we care about.
    #
    # That defence is git_path() (vault-sync.pl), which rewrites /c/... -> C:/...
    # before every git call. It does NOT un-set MSYS2_ARG_CONV_EXCL, and an earlier
    # version of this comment claiming it did was describing a superseded approach.
    # The distinction matters: git_path() makes the script correct under EITHER
    # conversion state, whereas un-setting the variable would only work when the
    # script controls the environment. `git.exe` accepts the C:/ form whether or
    # not MSYS later rewrites it, and a lone drive path is never split like a
    # `:`-separated list.
    local $ENV{HOME}              = $home;
    local $ENV{USERPROFILE}       = $home;
    local $ENV{GIT_CONFIG_GLOBAL} = "$home/.gitconfig";
    local $ENV{GIT_CONFIG_SYSTEM} = '/dev/null';
    local $ENV{GIT_TERMINAL_PROMPT} = '0';
    local $ENV{GIT_AUTHOR_NAME}     = 'Steward Test';
    local $ENV{GIT_AUTHOR_EMAIL}    = 'steward-test@example.invalid';
    local $ENV{GIT_COMMITTER_NAME}  = 'Steward Test';
    local $ENV{GIT_COMMITTER_EMAIL} = 'steward-test@example.invalid';

    open my $fh, '-|', $^X, $SCRIPT, @args or die "cannot spawn vault-sync.pl: $!";
    local $/;
    my $out = <$fh>;
    close $fh;
    my $exit = $? >> 8;
    my $json = eval { decode_json($out) };
    return { out => $out, exit => $exit, json => $json };
}

# ── file helpers ────────────────────────────────────────────────────
sub write_text {
    my ($path, $content) = @_;
    make_path(dirname($path));
    open my $fh, '>:raw', $path or die "write $path: $!";
    print $fh $content;
    close $fh;
}

sub read_text {
    my ($path) = @_;
    return undef unless -f $path;
    open my $fh, '<:raw', $path or die "read $path: $!";
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

sub path_exists { return -e $_[0] ? 1 : 0 }

sub _run {
    my @cmd = @_;
    local %ENV = %ENV;
    _msys_convert_on();
    system(@cmd) == 0 or die "command failed (@cmd): $?";
}

1;
