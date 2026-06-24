#!/usr/bin/env perl
# ccpraxis-install.pl — host-tools install hook: put `perl` on the user's PATH.
#
# Git-for-Windows keeps perl.exe in <git>\usr\bin, which is NOT on the Windows
# PATH (only <git>\cmd is) — so `perl ...` fails from PowerShell / cmd even
# though git works. This hook drops a single `perl` shim into a dedicated bin
# dir and adds that dir to PATH via the shared, Unicode-safe helper. Surgical:
# ONLY perl is exposed (unlike adding all of usr\bin, which would shadow the
# Windows find/sort/link with their Unix namesakes).
#
# The shim points at whatever perl is ALREADY running this hook ($^X — the perl
# the user invoked install.pl with), converted to a Windows path. We never
# hardcode an install dir: that dir may not exist on another machine. Detection
# happens ONCE here at install time; the generated perl.cmd caches the result so
# `perl ...` per-invoke is a fixed exec (no re-detection cost).
#
# Before caching, we VALIDATE the resolved perl meets the minimum version the
# ccpraxis perl scripts need (5.10 for //, //=, say, state) and refuse to cache
# a too-old one — "exists" is not "is the perl we need".
#
# Windows-only. On Linux/macOS perl is already on PATH and a .cmd shim is
# meaningless, so the hook is a friendly no-op there.
#
# Two modes — the same contract every ccpraxis install hook honors:
#   perl ccpraxis-install.pl plan       describe what would change
#   perl ccpraxis-install.pl apply      make the changes (idempotent)
use strict;
use warnings;
use FindBin qw($Bin);

# Raw byte I/O: paths are UTF-8 bytes (André); a :utf8 layer would double-encode.
binmode STDOUT, ':raw';
binmode STDERR, ':raw';

# The perl floor. The bare technical requirement is only 5.14 (JSON::PP core;
# see plugins/butler/docs/assumptions.json id "bin.perl"). We set the *policy*
# floor higher — 5.42.2, the version Git-for-Windows currently ships — because
# GfW is ccpraxis's supported host perl (global CLAUDE.md): anyone on the
# supported path already has it, and an older GfW just means "update Git for
# Windows". Lower this toward 5.14 if you ever need to support older/non-GfW perl.
my $MIN_PERL = '5.42.2';

my $mode = $ARGV[0] // 'plan';
$mode =~ /^(plan|apply)$/ or die "usage: $0 <plan|apply>\n";

# Windows only — $^O is 'cygwin'/'msys' for Git-for-Windows perl, 'MSWin32' for
# Strawberry/ActivePerl. Anywhere else, perl is already on PATH.
unless ($^O eq 'MSWin32' || $^O eq 'cygwin' || $^O eq 'msys') {
    print "  perl-shim: not needed on $^O (perl is already on PATH); skipping\n";
    exit 0;
}

my $bindir = "$Bin/bin";
my $shim   = "$bindir/perl.cmd";
my $helper = "$Bin/../scripts/_install-bin-helper.pl";
-f $helper or die "  perl-shim: shared helper not found at $helper\n";

my ($perl_win, $perl_spawn, $perl_running) = resolve_perl();
my $perl_ver = defined $perl_win
    ? ($perl_running ? sprintf('%vd', $^V) : perl_version_str($perl_spawn))
    : undef;
my $vclass = !defined $perl_win ? 'unresolved' : classify_ver($perl_ver);

if ($mode eq 'plan') {
    if    ($vclass eq 'unresolved')  { print "  perl-shim: WARNING could not resolve a Windows perl path (\$^X=$^X) — would SKIP the shim\n"; }
    elsif ($vclass eq 'unknown')     { print "  perl-shim: WARNING resolved $perl_win but could not determine its version — would warn and still shim\n"; }
    elsif ($vclass eq 'wrong-major') { print "  perl-shim: WARNING resolved $perl_win is perl $perl_ver — ccpraxis needs Perl 5.x — would REFUSE to shim\n"; }
    elsif ($vclass eq 'too-old')     { print "  perl-shim: WARNING resolved $perl_win is perl $perl_ver (< $MIN_PERL needed) — would REFUSE to shim\n"; }
    else                             { print "  perl-shim: would write $shim  (caches perl $perl_ver at \"$perl_win\")\n"; }
    # Delegate the PATH portion of the plan to the shared helper (idempotent).
    system($^X, $helper, 'plan', $bindir) if -d $bindir;
    exit 0;
}

# ── apply ─────────────────────────────────────────────────────────
# Never break the rest of the install over a perl-shim problem, and never cache
# a missing or too-old perl. These are non-fatal skips (exit 0) EXCEPT a
# resolved-but-too-old perl, which is a real misconfiguration worth flagging
# (exit nonzero → install.pl prints a "(hook exited N)" warning).
if ($vclass eq 'unresolved') {
    print STDERR "  perl-shim: could not resolve a Windows perl path (\$^X=$^X) — skipping shim, PATH untouched\n";
    exit 0;
}
if ($vclass eq 'wrong-major') {
    print STDERR "  perl-shim: resolved perl is $perl_ver but ccpraxis targets Perl 5.x — REFUSING to shim ($perl_win).\n";
    print STDERR "  perl-shim: (Perl 6 is now Raku, a different language; for Perl 7 verify ccpraxis runs under it, then bump \$MIN_PERL.)\n";
    exit 4;
}
if ($vclass eq 'too-old') {
    print STDERR "  perl-shim: resolved perl is $perl_ver but ccpraxis needs >= $MIN_PERL — REFUSING to shim a too-old perl ($perl_win).\n";
    print STDERR "  perl-shim: install a newer perl (Git for Windows bundles one) and re-run the installer.\n";
    exit 4;
}
if ($vclass eq 'unknown') {
    # Couldn't probe the version (unusual). The perl resolved and exists, so
    # proceed, but say so — don't silently claim it was validated.
    print STDERR "  perl-shim: WARNING could not determine perl version for $perl_win — shimming anyway (unvalidated)\n";
}

mkdir $bindir unless -d $bindir;
write_shim($shim, $perl_win);
print "  perl-shim: wrote $shim  (caches perl ", ($perl_ver // '?'), " at \"$perl_win\")\n";

# Add the bin dir to the user PATH via the shared (base64 round-trip, Unicode-
# safe) helper. Its exit code becomes ours.
my $rc = system($^X, $helper, 'apply', $bindir);
exit($rc == 0 ? 0 : ($rc >> 8 || 1));

# ── helpers ───────────────────────────────────────────────────────

# Write the batch shim (CRLF — it's a Windows .cmd). The resolved perl path is
# BAKED IN here at install time: this shim IS the cache of that one-time
# detection, so `perl ...` per-invoke is just a fixed exec — no cygpath, no
# re-detection cost. On a cache miss (perl later moved/uninstalled) it fails
# loudly with a re-install hint rather than silently doing nothing. %* forwards
# every argument; the batch's exit code is perl's. `goto` (no parenthesised
# blocks) keeps a path with spaces or "(x86)" from breaking cmd parsing.
sub write_shim {
    my ($path, $pl) = @_;
    open my $fh, '>', $path or die "  perl-shim: cannot write $path: $!\n";
    binmode $fh, ':raw';
    my @lines = (
        '@echo off',
        "set \"_PERL=$pl\"",
        'if not exist "%_PERL%" goto _noperl',
        '"%_PERL%" %*',
        'goto :EOF',
        ':_noperl',
        '>&2 echo perl.cmd [ccpraxis shim]: cached perl not found at "%_PERL%"',
        '>&2 echo perl.cmd [ccpraxis shim]: re-run the ccpraxis installer to refresh it:  perl install.pl --confirm',
        'exit /b 9',
    );
    print $fh join("\r\n", @lines), "\r\n";
    close $fh;
}

# Resolve the running perl ($^X) to a Windows path. Returns
#   ($win_path_for_shim, $spawnable_path, $is_running_perl)
# or an empty list if nothing resolves. $is_running_perl is true when the
# resolved perl IS this very process ($^X) — then its version is just $^V (no
# spawn needed). Anchored on $^X so we point at the perl the user actually uses,
# never a hardcoded dir.
sub resolve_perl {
    my $px = $^X;

    # (a) Native Win32 perl (Strawberry/ActivePerl): $^X is already a drive path.
    if ($px =~ m{^[A-Za-z]:[\\/]}) {
        (my $w = $px) =~ s{/}{\\}g;
        return ($w, $px, 1);
    }

    # (b) Git-for-Windows (cygwin/msys) perl: $^X is POSIX (/usr/bin/perl).
    #     Convert with cygpath -w, found next to perl itself (PowerShell's PATH
    #     won't have it). MSYS2_ARG_CONV_EXCL keeps the /usr/bin/perl argument
    #     from being mangled before cygpath can convert it (see global CLAUDE.md).
    if (-f $px) {
        (my $dir = $px) =~ s{/[^/]*$}{};
        for my $cp ("$dir/cygpath", "$dir/cygpath.exe") {
            next unless -f $cp || -x $cp;
            local $ENV{MSYS2_ARG_CONV_EXCL} = '*';
            my $w = `"$cp" -w "$px" 2>/dev/null`;
            next unless defined $w;
            $w =~ s/\s+\z//;
            return ($w, $px, 1) if length $w && $w =~ /^[A-Za-z]:/;  # probe via POSIX $px
        }
    }

    # (c) Fallback: search known install locations (mirrors claude-sandbox.ps1
    #     Get-PerlPath). Forward slashes are fine for -f and for spawning on
    #     cygwin/native perl; convert to backslashes for the shim.
    my @cands = grep { defined && length } (
        ($ENV{ProgramFiles}        ? "$ENV{ProgramFiles}/Git/usr/bin/perl.exe"        : undef),
        ($ENV{'ProgramFiles(x86)'} ? "$ENV{'ProgramFiles(x86)'}/Git/usr/bin/perl.exe" : undef),
        'C:/Program Files/Git/usr/bin/perl.exe',
        'C:/Program Files (x86)/Git/usr/bin/perl.exe',
        'C:/Strawberry/perl/bin/perl.exe',
        'C:/Perl64/bin/perl.exe',
    );
    for my $c (@cands) {
        if (-f $c) { (my $w = $c) =~ s{/}{\\}g; return ($w, $c, 0); }
    }

    return ();
}

# Probe a (non-running) perl's version string by invoking it. `-V:version`
# prints  version='5.42.2';  — quote-safe (no $ or spaces in the args). Returns
# the dotted version (e.g. "5.42.2") or undef if it couldn't be determined.
sub perl_version_str {
    my $spawn = shift;
    local $ENV{MSYS2_ARG_CONV_EXCL} = '*';
    my $out = `"$spawn" -V:version 2>/dev/null`;
    return undef unless defined $out && $out =~ /version='([^']+)'/;
    return $1;
}

# Classify a resolved perl's version against what ccpraxis needs:
#   'ok' | 'too-old' | 'wrong-major' | 'unknown'
# We need Perl 5.x specifically: "Perl 6" became Raku (a different language) and
# a future Perl 7 changes defaults enough to warrant a conscious re-validation.
sub classify_ver {
    my $ver = shift;
    return 'unknown' unless defined $ver && $ver =~ /^\d/;
    my ($maj) = split /\./, $ver;
    return 'wrong-major' if !defined $maj || $maj != 5;
    return 'too-old' unless vge($ver, $MIN_PERL);
    return 'ok';
}

# Dotted-version >= compare without the `version` module or $] float quirks.
sub vge {
    my ($a, $b) = @_;
    my @a = split /\./, $a;
    my @b = split /\./, $b;
    for my $i (0 .. 2) {
        my $x = $a[$i] // 0;
        my $y = $b[$i] // 0;
        return 1 if $x > $y;
        return 0 if $x < $y;
    }
    return 1;
}
