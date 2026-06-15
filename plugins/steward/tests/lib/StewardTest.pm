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

sub vault_sync_script { return $SCRIPT }

# ── assertions ──────────────────────────────────────────────────────
my $TEST_NUM = 0;
my $FAILS    = 0;

sub ok {
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
# conversion ON; see _msys_convert_on). We deliberately prefer C:/Users/Public:
# it is pure-ASCII and free of 8.3 short names, so msys-perl and native git agree
# byte-for-byte on every path. The user-profile TEMP is "C:\Users\ANDR~1\..." —
# its short name resolves inconsistently across the perl/git boundary, breaking
# local git remotes. (Off Windows these substitutions are no-ops; /tmp is used.)
sub temproot {
    my $base;
    for my $cand ('/c/Users/Public', $ENV{TEMP}, $ENV{TMP}, '/tmp') {
        next unless defined $cand && length $cand;
        my $p = $cand;
        $p =~ s|\\|/|g;
        $p =~ s|^([a-zA-Z]):/|"/" . lc($1) . "/"|e;
        if (-d $p && -w $p) { $base = $p; last; }
    }
    die "StewardTest: no writable temp base found\n" unless $base;
    my $root = tempdir('steward-test-XXXXXX', DIR => $base, CLEANUP => 1);
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

# Run vault-sync.pl as a subprocess under the given fake HOME. Returns a hashref
# { out => raw_stdout, exit => code, json => decoded_or_undef }.
# Ensure MSYS path conversion is ON for native-git argv, even if the ambient
# shell set MSYS2_ARG_CONV_EXCL=* (the CLAUDE.md belt-and-suspenders). vault-sync.pl
# passes git /c/... paths and relies on the /c/->C:\ rewrite; with conversion
# disabled, native git cannot resolve /c/ at all. We scope the un-set to the child.
sub _msys_convert_on { delete $ENV{MSYS2_ARG_CONV_EXCL} }

sub run_vs {
    my ($home, @args) = @_;
    # NOTE: we deliberately do NOT scrub MSYS2_ARG_CONV_EXCL here — vault-sync.pl
    # un-sets it itself now (it must, since it passes git POSIX paths). Leaving the
    # ambient value (which may be '*') in place is what proves the script's own fix.
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
