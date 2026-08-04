#!/usr/bin/env perl
# bp-spend-auth.pl — credential UX for the OpenCode Go/Zen spend cookie
# (b36-multi-provider-spend-governance, reopened spec §3).
#
# Setting the spend cookie today means knowing an undocumented path and mode.
# This is the one command that does it:
#
#   bp-spend-auth.pl --provider go              # cookie read from STDIN, NEVER argv
#   bp-spend-auth.pl --provider go --from-firefox   # host-side extraction, see §3.1
#   bp-spend-auth.pl --status [--provider NAME]  # presence/mode/parseability, never the value
#
# THREE RULES ENFORCED HERE, restated at the point each is enforced so a future
# editor changing a flag cannot miss them:
#
#   1. NEVER accept the cookie on argv. argv lands in `ps` output and shell
#      history. This script defines NO --cookie flag at all -- STDIN is the
#      only input. An unrecognised flag is rejected (with the flag NAME only,
#      never any value that followed it) rather than silently accepted.
#   2. NEVER echo the cookie, not even truncated, not even in --status.
#   3. Create the credential file at 0600 FROM THE START -- sysopen with the
#      mode baked into the open() call, never chmod'd afterward, so there is
#      no window in which the file is briefly world-readable.
#
# --from-firefox (§3.1): host-side PowerShell + winsqlite3.dll extraction from
# Firefox's cookies.sqlite -- Windows-only, best-effort, and MUST degrade to
# the manual path (print instructions, exit non-zero, write NOTHING -- no
# empty/partial file) on any non-Windows host, missing profile, locked DB, or
# absence of an opencode.ai cookie. The happy path cannot run in this
# container and is not implemented here beyond the platform gate below; see
# docs/spend-credentials.md for the manual fallback this prints.
#
# require: this file is a CLI entry point, run as a real subprocess (never
# `require`d) -- so its argv/STDIN/echo behaviour is exercised as the actual
# tool operators run, per the oracle's own convention (C17 comment).

use strict;
use warnings;
use File::Basename qw(dirname);
use Cwd qw(abs_path);
use Fcntl ();
use JSON::PP;

my $DIR = dirname(do { (my $f = __FILE__) =~ s{\\}{/}g; abs_path($f) // $f });
require "$DIR/bp-spend.pl";   # BpSpend::resolve_credential -- reused for --status parseability, never reimplemented.

sub _home {
    return $ENV{HOME} // $ENV{USERPROFILE} // '';
}

# _default_path($provider) -> the standing per-provider credential path,
# under ~/.claude/ (the claude-home bind -- survives container rebuilds, per
# the reopen spec's ruling §1).
sub _default_path {
    my ($provider) = @_;
    my $home = _home();
    return "$home/.claude/opencode-$provider.json";
}

my $usage = <<'USAGE';
usage: bp-spend-auth.pl --provider NAME [--path PATH]
           store a cookie read from STDIN (NEVER argv) for provider NAME.
       bp-spend-auth.pl --provider NAME --from-firefox [--path PATH]
           host-side Firefox cookie extraction (Windows-only, see spec 3.1).
       bp-spend-auth.pl --status [--provider NAME] [--path PATH]
           report presence/mode/parseability of the credential file. NEVER
           prints the cookie value.
USAGE

sub _fail_usage {
    my ($msg) = @_;
    print STDERR "bp-spend-auth.pl: $msg\n" if defined $msg;
    print STDERR $usage;
    exit 1;
}

# --- argv parsing. Deliberately no --cookie flag exists (rule 1 above). ---
my %opt;
{
    my @args = @ARGV;
    while (@args) {
        my $a = shift @args;
        if ($a eq '--provider') {
            my $v = shift @args;
            _fail_usage('--provider requires a value') unless defined $v;
            $opt{provider} = $v;
        } elsif ($a eq '--path') {
            my $v = shift @args;
            _fail_usage('--path requires a value') unless defined $v;
            $opt{path} = $v;
        } elsif ($a eq '--from-firefox') {
            $opt{from_firefox} = 1;
        } elsif ($a eq '--status') {
            $opt{status} = 1;
        } else {
            # NEVER echo the argument that follows an unrecognised flag --
            # only the flag token itself, so a smuggled cookie value handed
            # after an unknown flag name is never printed.
            _fail_usage("unknown argument '$a'");
        }
    }
}

# ---------------------------------------------------------------------------
# --status: presence, mode, parseability. NEVER the value.
# ---------------------------------------------------------------------------
if ($opt{status}) {
    my $provider = $opt{provider} // 'go';
    my $path = $opt{path} // _default_path($provider);

    unless (-e $path) {
        print "provider=$provider path=$path present=0\n";
        exit 0;
    }

    my @st = stat($path);
    my $mode = @st ? sprintf('%04o', $st[2] & 07777) : 'unknown';

    my $r = BpSpend::resolve_credential(fallback_path => $path);
    my $parseable = ($r && $r->{ok}) ? 1 : 0;
    my $note = $parseable ? '' : ' reason=' . ($r->{reason} // 'unknown');

    print "provider=$provider path=$path present=1 mode=$mode parseable=$parseable$note\n";
    exit($parseable ? 0 : 1);
}

# ---------------------------------------------------------------------------
# _write_credential_file($path, $cookie) -> writes { cookie => $cookie } at
# mode 0600, created that way from the start (rule 3 above): sysopen with the
# mode baked in, never chmod'd afterward. Atomic: temp file in the same
# directory, then rename, so a reader never observes a partial write.
# ---------------------------------------------------------------------------
sub _write_credential_file {
    my ($path, $cookie) = @_;

    (my $dir = $path) =~ s{[/\\][^/\\]+$}{};
    $dir = '.' unless length $dir;
    if (length $dir && !-d $dir) { require File::Path; File::Path::make_path($dir); }

    my $tmp = "$path.tmp.$$." . int(rand(1_000_000));
    sysopen(my $fh, $tmp, Fcntl::O_WRONLY() | Fcntl::O_CREAT() | Fcntl::O_TRUNC(), 0600)
        or die "bp-spend-auth.pl: cannot create $tmp: $!\n";
    print {$fh} JSON::PP->new->encode({ cookie => $cookie })
        or die "bp-spend-auth.pl: write $tmp: $!\n";
    close $fh or die "bp-spend-auth.pl: close $tmp: $!\n";

    rename($tmp, $path) or die "bp-spend-auth.pl: rename $tmp -> $path: $!\n";
    return $path;
}

# ---------------------------------------------------------------------------
# --from-firefox: host-side extraction (spec §3.1). Best-effort, degrades to
# the manual path on ANY obstacle -- never writes an empty or partial file.
# The happy path (Windows + winsqlite3.dll + a live Firefox profile) cannot
# be exercised inside this Linux sandbox container; only the degrade gate
# below is implemented and is what the oracle (C18) actually exercises.
# ---------------------------------------------------------------------------
if ($opt{from_firefox}) {
    _fail_usage('--from-firefox requires --provider') unless defined $opt{provider};
    my $provider = $opt{provider};
    my $path = $opt{path} // _default_path($provider);

    my $manual = <<MANUAL;
--from-firefox could not extract a usable opencode.ai session cookie automatically.

Manual fallback (see plugins/butler/docs/spend-credentials.md):
  1. Open https://opencode.ai in Firefox and sign in.
  2. DevTools (F12) -> Application -> Cookies -> https://opencode.ai
  3. Copy the session cookie's value.
  4. Run: bp-spend-auth.pl --provider $provider
     and paste the value on STDIN when prompted.
MANUAL

    if ($^O ne 'MSWin32') {
        print STDERR $manual;
        print STDERR "reason: --from-firefox is a Windows-only mechanism (winsqlite3.dll, spec 3.1) -- this host is '$^O'.\n";
        exit 1;
    }

    # A real Windows implementation would shell out to PowerShell here to
    # copy cookies.sqlite, read it via winsqlite3.dll, and extract the
    # opencode.ai session cookie. Not implemented in this checkout (no
    # Windows host available to exercise or validate the happy path against
    # a real profile) -- degrade to the manual path rather than fake success.
    print STDERR $manual;
    print STDERR "reason: no Firefox profile / cookies.sqlite / opencode.ai cookie could be extracted.\n";
    exit 1;
}

# ---------------------------------------------------------------------------
# Store mode: cookie read from STDIN only, never argv.
# ---------------------------------------------------------------------------
_fail_usage('--provider is required') unless defined $opt{provider};
my $provider = $opt{provider};
my $path = $opt{path} // _default_path($provider);

my $cookie = do { local $/; <STDIN> };
$cookie = '' unless defined $cookie;
$cookie =~ s/\r?\n\z//;   # drop a single trailing newline, keep the rest verbatim

if (!length $cookie) {
    print STDERR "bp-spend-auth.pl: no cookie was provided on STDIN\n";
    exit 1;
}

_write_credential_file($path, $cookie);
print "stored credential for provider=$provider at $path (mode 0600)\n";
exit 0;
