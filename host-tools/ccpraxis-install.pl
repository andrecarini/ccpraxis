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
# The shim points at whatever perl is ALREADY running this hook (its own
# $Config{perlpath} / $^X), converted to a Windows path. We anchor on the
# running interpreter rather than searching install dirs ON PURPOSE: searching
# could cache a DIFFERENT perl than the one actually in use (a mismatch). The
# search-based resolver lives in exactly one other place — the PowerShell
# launchers' Get-PerlPath (scripts/_perl-path.ps1) — which needs it because
# PowerShell has no running-perl to anchor on. Two methods for two moments; no
# shared list to drift.
# Detection happens ONCE here at install time; the generated perl.cmd caches the
# result so `perl ...` per-invoke is a fixed exec (no re-detection cost).
#
# Before caching, we VALIDATE the resolved perl is a confirmed-working version
# (Perl 5.x, >= the floor below) and refuse to cache one that isn't — "exists" is
# not "is the perl we need".
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
use Config;   # $Config{perlpath}: the authoritative path of the running perl

# Raw byte I/O: paths are UTF-8 bytes (André); a :utf8 layer would double-encode.
binmode STDOUT, ':raw';
binmode STDERR, ':raw';

# The perl floor = the version we've EXPLICITLY CONFIRMED working: 5.42.2 (the
# Git-for-Windows perl on the validated host). The policy is deliberately
# "support only confirmed configurations" — we do NOT bless an older perl just
# because it might work. (For reference the bare technical need is lower, 5.14
# for JSON::PP per plugins/butler/docs/assumptions.json — but "might work" is not
# "confirmed".) Widen this only when another perl/platform is actually validated.
# NOTE: this whole hook is Windows-only (see the $^O guard below), so any
# GfW-flavoured guidance it prints can only ever reach a Windows user.
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

# The shim always points at the perl running THIS installer ($^X), so its version
# is simply $^V — no need to spawn anything to ask.
my $perl_win = resolve_perl();
my $perl_ver = defined $perl_win ? sprintf('%vd', $^V) : undef;
my $vclass   = !defined $perl_win ? 'unresolved' : classify_ver($perl_ver);

if ($mode eq 'plan') {
    if    ($vclass eq 'unresolved')  { print "  perl-shim: WARNING could not resolve a Windows perl path (\$^X=$^X) — would SKIP the shim\n"; }
    elsif ($vclass eq 'wrong-major') { print "  perl-shim: WARNING resolved $perl_win is perl $perl_ver — ccpraxis needs Perl 5.x — would REFUSE to shim\n"; }
    elsif ($vclass eq 'too-old')     { print "  perl-shim: WARNING resolved $perl_win is perl $perl_ver (< $MIN_PERL confirmed) — would REFUSE to shim\n"; }
    else                             { print "  perl-shim: would write $shim  (caches perl $perl_ver at \"$perl_win\")\n"; }
    # Delegate the PATH portion of the plan to the shared helper (idempotent).
    system($^X, $helper, 'plan', $bindir) if -d $bindir;
    exit 0;
}

# ── apply ─────────────────────────────────────────────────────────
# Never break the rest of the install over a perl-shim problem, and never cache
# an unresolved / unconfirmed perl. The unresolved case is a non-fatal skip
# (exit 0); a resolved-but-unconfirmed perl is a real misconfiguration worth
# flagging (exit nonzero → install.pl prints a "(hook exited N)" warning).
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
    print STDERR "  perl-shim: resolved perl $perl_ver is not a confirmed-working version — ccpraxis is validated against perl >= $MIN_PERL. REFUSING to shim ($perl_win).\n";
    print STDERR "  perl-shim: install a confirmed perl (e.g. current Git for Windows) and re-run the installer.\n";
    exit 4;
}

mkdir $bindir unless -d $bindir;
write_shim($shim, $perl_win);
print "  perl-shim: wrote $shim  (caches perl $perl_ver at \"$perl_win\")\n";

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

# Resolve the perl running THIS installer to a Windows path for the shim. We
# anchor on the running interpreter itself — its build path $Config{perlpath} and
# the invocation path $^X. $^X alone is NOT enough: when perl is found on PATH by
# name it can be the bare string "perl" (observed in some shells), which we can't
# turn into a path. $Config{perlpath} is the authoritative configured path of
# THIS perl, so it always names the running interpreter — never a guessed/other
# one, hence no search and no mismatch. Returns the Windows path, or undef.
sub resolve_perl {
    # Try $^X first (honours how perl was invoked), then the authoritative build
    # path; skip any candidate that isn't an absolute path we can convert.
    for my $px (grep { defined && length } ($^X, $Config{perlpath})) {
        # (a) already an absolute Windows path (native Win32 perl).
        if ($px =~ m{^[A-Za-z]:[\\/]}) {
            (my $w = $px) =~ s{/}{\\}g;
            return $w;
        }
        # (b) absolute POSIX path (Git-for-Windows perl): convert with cygpath -w,
        #     found next to perl itself (PowerShell's PATH won't have it).
        #     MSYS2_ARG_CONV_EXCL keeps the POSIX arg from being mangled before
        #     cygpath converts it (see global CLAUDE.md).
        next unless $px =~ m{^/} && -f $px;
        (my $dir = $px) =~ s{/[^/]*$}{};
        for my $cp ("$dir/cygpath", "$dir/cygpath.exe") {
            next unless -f $cp || -x $cp;
            local $ENV{MSYS2_ARG_CONV_EXCL} = '*';
            my $w = `"$cp" -w "$px" 2>/dev/null`;
            next unless defined $w;
            $w =~ s/\s+\z//;
            return $w if length $w && $w =~ /^[A-Za-z]:/;
        }
    }
    return undef;
}

# Classify the running perl's version against what ccpraxis needs:
#   'ok' | 'too-old' | 'wrong-major'
# We need Perl 5.x specifically: "Perl 6" became Raku (a different language) and
# a future Perl 7 changes defaults enough to warrant a conscious re-validation.
sub classify_ver {
    my $ver = shift;
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
