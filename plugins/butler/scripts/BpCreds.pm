# BpCreds.pm — where Claude Code's OAuth credentials live, on every host.
#
# One lookup, previously written out separately in bp-usage-gate.pl,
# bp-drive-next.pl's token recovery and four bp-preflight.pl checks, each as
# "$HOME/.claude/.credentials.json". That file is where Claude Code keeps the
# grant on Windows and inside the Linux sandbox. On macOS it is NOT there:
# Claude Code stores the same JSON in the login Keychain, as a generic password
# with service "Claude Code-credentials". So on a Mac every one of those copies
# reported "no credentials" and the usage gate went silently dark, which is the
# kind of failure nobody notices until the account hits a wall mid-run.
#
# THE ORDER (first hit wins):
#
#   1. an explicit path from the caller (a test seam or a CLI option)
#   2. $BP_CREDS_PATH, when set and non-empty
#   3. $HOME/.claude/.credentials.json, when it exists
#   4. the macOS Keychain, when keychain_enabled() says so
#
# Steps 1 and 2 are AUTHORITATIVE: a named file that is missing is reported as
# missing, never quietly replaced by the next step. Every test that drives
# these scripts as subprocesses points BP_CREDS_PATH at a temp file, and a
# missing fixture must stay a missing fixture rather than become a read of the
# operator's real secret.
#
# THE KEYCHAIN IS READ, NEVER WRITTEN, AND NOTHING IS WRITTEN IN ITS PLACE.
# There is no credentials file on a Mac and this module must not create one:
# a second, stale copy of a rotating refresh token is a liability. For the same
# reason token REFRESH is not done here on macOS (see bp-drive-next.pl's
# _token_recover): rotating the refresh token without writing the new one back
# would log Claude Code out. Claude Code refreshes its own Keychain token.
#
# THE SECRET NEVER REACHES A LOG. `security` is exec'd in list form (no shell,
# no quoting), its stderr is discarded, and no detail string this module
# returns ever contains the payload — only where it came from and what was
# wrong with it.
package BpCreds;
use strict;
use warnings;
no warnings 'redefine';   # may be require'd under more than one path spelling
use Cwd ();
use File::Spec ();

our $KEYCHAIN_SERVICE = 'Claude Code-credentials';

# Read the service name through this from another file: callers `require` this
# module at RUNTIME, so a fully-qualified $BpCreds::KEYCHAIN_SERVICE elsewhere
# compiles before the `our` exists and perl warns "used only once" -- onto the
# stderr of scripts whose --quiet mode promises silence.
sub keychain_service { return $KEYCHAIN_SERVICE }

# How long `security` may take. It answers in milliseconds when the item's ACL
# already trusts it; the only way it takes longer is a Keychain access dialog
# waiting for a human, and an unattended driver must not wait on that forever.
our $KEYCHAIN_TIMEOUT_SECONDS = 10;

sub _home { return $ENV{HOME} // $ENV{USERPROFILE} // '' }

sub default_path {
    my ($home) = @_;
    $home = _home() unless defined $home;
    return "$home/.claude/.credentials.json";
}

sub _canon {
    my ($p) = @_;
    return undef unless defined $p && length $p;
    my $c = Cwd::abs_path($p) // $p;
    $c =~ s{/+\z}{};
    return $c;
}

# keychain_enabled() -> 0|1
#
#   BP_CREDS_KEYCHAIN=0   never (an explicit opt-out)
#   BP_CREDS_KEYCHAIN=1   always, on any OS. The test seam: together with a
#                         fake `security` first on PATH it exercises this path
#                         anywhere without touching a real Keychain.
#   otherwise             only on macOS, and only when $HOME is the account's
#                         own home directory (the passwd entry).
#
# THE HOME RULE is what keeps a redirected process away from the operator's
# secret. The login Keychain belongs to the account, not to whatever $HOME a
# process was started with; a process whose HOME points somewhere else (the
# test runner's per-file sandbox, a throwaway config) is not that account's
# session, and reading its Keychain from there would be a test reaching the
# real grant — and possibly raising a Keychain dialog in front of the operator.
sub keychain_enabled {
    my $v = $ENV{BP_CREDS_KEYCHAIN};
    if (defined $v && length $v) {
        return 0 if $v eq '0';
        return 1 if $v eq '1';
    }
    return 0 unless $^O eq 'darwin';
    my $pw_home = (getpwuid($<))[7];
    my $a = _canon(_home());
    my $b = _canon($pw_home);
    return (defined $a && defined $b && $a eq $b) ? 1 : 0;
}

# locate(%o) -> { kind => 'file'|'keychain'|'none', path => $file_path, source => $label }
#
# %o: path (explicit, authoritative), home (defaults to $HOME/$USERPROFILE).
# `path` is always a file path, even for the Keychain and 'none' kinds — the
# default location — because callers derive sibling paths from it (the usage
# gate keeps its cache beside the credentials) and name it in messages.
sub locate {
    my (%o) = @_;
    if (defined $o{path} && length $o{path}) {
        return { kind => 'file', path => $o{path}, source => "file:$o{path}" };
    }
    my $env = $ENV{BP_CREDS_PATH};
    if (defined $env && length $env) {
        return { kind => 'file', path => $env, source => "file:$env" };
    }
    my $def = default_path($o{home});
    return { kind => 'file', path => $def, source => "file:$def" } if -f $def;
    return { kind => 'keychain', path => $def, source => "keychain:$KEYCHAIN_SERVICE" }
        if keychain_enabled();
    return { kind => 'none', path => $def, source => "file:$def" };
}

# load(%o) -> { ok, data, kind, path, source, detail }
#
# ok=1 means the credentials were READ and parse as a JSON object; it says
# nothing about their shape (that is BpContract::validate_creds's job) or
# freshness (BpGovern's). On failure, detail is a short machine-ish token:
#   cannot-open:<path>   invalid-json:<path>   invalid-json:keychain
#   keychain:<reason>    (timeout, security-exit-<rc>, empty, security-not-runnable)
sub load {
    my (%o) = @_;
    my $loc = locate(%o);
    my %r = (ok => 0, data => undef, kind => $loc->{kind}, path => $loc->{path},
             source => $loc->{source}, detail => '');
    my $raw;
    if ($loc->{kind} eq 'file') {
        my $fh;
        unless (open $fh, '<:raw', $loc->{path}) {
            $r{detail} = "cannot-open:$loc->{path}";
            return \%r;
        }
        local $/;
        $raw = <$fh>;
        close $fh;
        $raw = '' unless defined $raw;
    } elsif ($loc->{kind} eq 'keychain') {
        my ($text, $why) = read_keychain();
        unless (defined $text) {
            $r{detail} = "keychain:$why";
            return \%r;
        }
        $raw = $text;
    } else {
        # Same token as a named file that is absent: to a caller both mean "no
        # credentials file where one was looked for", and the usage gate's
        # CREDS line has always said exactly this on Windows.
        $r{detail} = "cannot-open:$loc->{path}";
        return \%r;
    }
    require JSON::PP;
    my $data = eval { JSON::PP->new->decode($raw) };
    unless (ref $data eq 'HASH') {
        $r{detail} = $loc->{kind} eq 'keychain' ? 'invalid-json:keychain' : "invalid-json:$loc->{path}";
        return \%r;
    }
    $r{ok}   = 1;
    $r{data} = $data;
    return \%r;
}

# read_keychain() -> ($json_text, undef) | (undef, $reason)
#
# `security find-generic-password -s <service> -w` prints the item's data on
# stdout. When the data holds bytes it considers unprintable it prints them as
# one hex string instead, so a hex-only answer that decodes to a JSON object is
# accepted as that object.
sub read_keychain {
    my @cmd = ('security', 'find-generic-password', '-s', $KEYCHAIN_SERVICE, '-w');

    my $saved;
    my $null = File::Spec->devnull;
    open($saved, '>&', \*STDERR) or undef $saved;
    open(STDERR, '>', $null) if $saved;
    my $pid = open(my $fh, '-|', @cmd);
    if ($saved) { open(STDERR, '>&', $saved); close $saved; }
    return (undef, 'security-not-runnable') unless $pid;

    my $out = '';
    my $timed_out = 0;
    {
        local $SIG{ALRM} = sub { die "bp-creds-timeout\n" };
        my $ok = eval {
            alarm($KEYCHAIN_TIMEOUT_SECONDS);
            local $/;
            my $t = <$fh>;
            $out = defined $t ? $t : '';
            alarm(0);
            1;
        };
        alarm(0);
        unless ($ok) {
            $timed_out = 1;
            kill('TERM', $pid);
        }
    }
    close $fh;
    my $rc = $? >> 8;
    return (undef, 'timeout') if $timed_out;
    return (undef, "security-exit-$rc") if $rc != 0;

    $out =~ s/[\r\n]+\z//;
    return (undef, 'empty') unless length $out;
    if ($out =~ /\A(?:[0-9A-Fa-f]{2})+\z/) {
        my $bytes = pack('H*', $out);
        $out = $bytes if $bytes =~ /\A\s*\{/;
    }
    return ($out, undef);
}

1;
