package BackpackOps;
# BackpackOps -- the impure half of the [b] backpack screen's three
# persistence seams (07-backpack-screen spec S2.3/E-A: bp_load/bp_save/
# bp_remove), extracted OUT of launcher.pl so the real closures are
# unit-testable without spawning launcher.pl (t/67's AC-P7 forbids that).
#
# WHY THIS MODULE EXISTS (review-driver-round M1): before this extraction,
# tui::BackpackScreen was proven correct against MOCK seams in t/67, and the
# REAL closures that feed those seams in the shipped binary (launcher.pl
# :4214-4265) were never run by anything -- a vacuity the driver's review
# caught after two precedence bugs (absent-vs-broken) shipped inside them
# undetected. This module is that logic, pulled out from behind
# launcher.pl's file-scope variables so a test can call it directly: every
# path/coderef it needs arrives as a plain argument, never a closed-over
# global.
#
# NOT held to tui::BackpackScreen's purity contract (S2.0): this module DOES
# real I/O -- it reads backpack.json and the approvals store, and spawns
# `backpack.pl remove`. That is correct; it is launcher.pl's job, just
# relocated. Every I/O boundary is still a plain argument or an injectable
# coderef (`read_file`, `run`), so a test can point it at File::Temp
# fixtures and a stub subprocess runner instead of the real filesystem and a
# real child process.

use strict;
use warnings;
use JSON::PP ();
use File::Temp ();
use BackpackApproval ();

# _default_read_file($path) -> $bytes|undef -- the same shape as
# launcher.pl's own _read_file (open ':raw', slurp, close; undef on any
# open failure, including an absent path). Kept private so this module has
# no dependency on launcher.pl's helper.
sub _default_read_file {
    my ($path) = @_;
    return undef unless defined $path;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

# load(%args) -> \%bp == { items => \@, approvals => \%, error => \%err|undef }
#   host_file => path to backpack.json                              (required)
#   appr_file => path to the machine-local approvals store          (required)
#   read_file => coderef ->($path) => $bytes|undef   (default: _default_read_file)
#
# HIGH-2 / review-driver-round M1 -- the fix, stated as the precedence rule
# it now enforces (both directions were broken in the shipped binary):
#
#   1. Absence of backpack.json is decided by -f ON THE FILE ITSELF, never
#      by a decode failure. (Bug (a): _read_file returns undef for an
#      absent file, JSON::PP->decode('') DIES, and evaluating that die
#      before the -f check made the commonest case -- no backpack.json at
#      all -- report broken=>1.)
#   2. BROKEN beats ABSENT, regardless of which of the two independent
#      stores (backpack.json itself, or the approvals file) reports it.
#      (Bug (b): a genuinely corrupt backpack.json reported as merely
#      absent whenever the approvals store was ALSO missing -- the common
#      combination, since `backpack.pl validate` failing means the
#      approvals store is never created -- because the approvals store's
#      %e was checked, and won, before the corrupt-decode branch.)
#
# Both stores can be independently absent, independently broken, or fine;
# neither is allowed to mask the other's broken=>1.
sub load {
    my (%args) = @_;
    my $host_file = $args{host_file};
    my $appr_file = $args{appr_file};
    my $read_file = (ref $args{read_file} eq 'CODE') ? $args{read_file} : \&_default_read_file;

    my %e;
    my $appr = BackpackApproval::load($appr_file, \%e);

    my $raw = $read_file->($host_file);
    # HIGH-1's companion fix: decode as UTF-8, matching backpack.pl's own
    # decode_json (which treats @ARGV/file bytes as UTF-8 octets -- see
    # backpack.pl's header comment and its `use utf8`/Encode::decode calls).
    # Without ->utf8 here, JSON::PP->decode treated the raw bytes as
    # already-decoded characters (effectively Latin-1), so any non-ASCII
    # item name came out mojibake and later failed to string-eq what
    # backpack.pl itself decoded -- see remove() below, which this mismatch
    # made trivially reachable for any non-ASCII name (this machine's own
    # paths contain "Andre" with an accent -- not hypothetical).
    my $data = eval { JSON::PP->new->utf8->decode(defined $raw ? $raw : '') };
    my $decode_err = $@;

    my $host_present = defined($host_file) && -f $host_file;
    my $host_broken  = $host_present && $decode_err;
    my $appr_broken  = (%e && $e{broken});

    my $error;
    if ($host_broken) {
        my $msg = $decode_err;
        $msg =~ s/\n.*//s;
        $error = { op => 'decode', broken => 1, errno => '', path => $host_file, message => $msg };
    } elsif ($appr_broken) {
        $error = \%e;
    } elsif (!$host_present) {
        $error = { op => 'absent', broken => 0, path => (defined $host_file ? $host_file : '') };
    } elsif (%e) {
        # host file is present and decodable; the approvals store reported
        # something non-broken (i.e. simply absent -- first launch before
        # anything has ever been approved). Surface it, but it can never
        # win over a broken=>1 from either source (handled above).
        $error = \%e;
    } else {
        $error = undef;
    }

    return {
        items     => (ref($data) eq 'HASH' && ref($data->{items}) eq 'ARRAY') ? $data->{items} : [],
        approvals => $appr,
        error     => $error,
    };
}

# save(\%approvals, %args) -> ($ok, \%err)
#   appr_file => path to the approvals store   (required)
# A thin pass-through to BackpackApproval::save's out-param contract; kept
# here (rather than left inline in launcher.pl) purely so every bp_* seam's
# real logic lives in one testable place.
sub save {
    my ($approvals, %args) = @_;
    my %e;
    my $ok = BackpackApproval::save($args{appr_file}, $approvals, \%e);
    return ($ok, \%e);
}

# remove(\%item, %args) -> ($ok, \%err)
#   host_file   => path to backpack.json                            (required)
#   backpack_pl => path to backpack.pl                               (required)
#   perl        => the perl binary to invoke              (default: $^X)
#   run         => coderef ->(@cmd) => ($rc, $captured)   (default: capture_quiet)
#
# HIGH-1 -- rc==0 is NOT sufficient for success. `backpack.pl remove` exits
# 0 with `STATUS: noop` (plus a `REASON:` line) when nothing matched --
# reachable in practice via an uppercase category or (before the UTF-8 fix
# in load() above) any non-ASCII name. Treating that as success clears the
# approval record and reports "dropped" for an item that is STILL ON DISK:
# a destructive action lying about having happened. The captured output
# (stdout+stderr, already combined by capture_quiet/the injected `run`) is
# parsed for the literal STATUS token and a noop is reported as a failure,
# never a success.
sub remove {
    my ($item, %args) = @_;
    my $host_file   = $args{host_file};
    my $backpack_pl = $args{backpack_pl};
    my $perl        = defined($args{perl}) ? $args{perl} : $^X;
    my $run         = (ref $args{run} eq 'CODE') ? $args{run} : \&capture_quiet;

    my $category = (ref($item) eq 'HASH' && defined $item->{category}) ? $item->{category} : '';
    my $name     = (ref($item) eq 'HASH' && defined $item->{name})     ? $item->{name}     : '';

    my ($rc, $captured) = $run->(
        $perl, $backpack_pl, 'remove', $host_file,
        '--category', $category, '--name', $name);

    my $msg = defined($captured) ? $captured : '';
    $msg =~ s/\s+/ /g;
    $msg =~ s/^\s+|\s+$//g;

    if ($rc != 0) {
        $msg = "backpack.pl remove exited @{[ $rc >> 8 ]}" unless length $msg;
        return (0, { op => 'remove', broken => 1, errno => '', path => $host_file, message => $msg });
    }

    if (defined($captured) && $captured =~ /STATUS:\s*noop/) {
        my $detail = length($msg) ? $msg : "nothing matched category=$category name=$name";
        return (0, { op => 'remove', broken => 0, errno => '', path => $host_file, message => $detail });
    }

    return (1, {});
}

# capture_quiet(@cmd) -> ($rc, $captured) -- run @cmd with its combined
# stdout+stderr CAPTURED, with NO SHELL INVOLVED AT ALL (HIGH-3).
#
# The launcher.pl code this replaces built a shell command line with
# _shell_quote and ran it through backticks; the MSWin32 branch of
# _shell_quote uses MSVC-style `\"` escaping, which cmd.exe does not honour
# -- verified against a real cmd.exe that a `&` inside an attacker-
# controlled item category/name (both come straight from a
# container-writable backpack.json) then executes a second command.
#
# list-form `open $fh, '-|', @cmd` execs @cmd directly (execvp(3) on POSIX,
# CreateProcess on native Win32 perl) with no shell in the middle at all, so
# there is no quoting problem to get right or wrong. That form only pipes
# the child's STDOUT, so STDERR is merged in by temporarily redirecting
# THIS process's own STDERR to a File::Temp file for the duration of the
# call -- the same dup-and-restore idiom launcher.pl's own alt-screen
# boundary already uses (enter_raw/leave_raw's $STDERR_CAPTURE_* dance) --
# and appending its contents to the captured stdout afterwards.
#
# Never streams: this must CAPTURE (E-C) -- bp_remove runs while the
# terminal is in raw mode with the dashboard's frame painted, and inherited/
# streamed child output would shred it.
sub capture_quiet {
    my (@cmd) = @_;
    return (-1, 'no command given') unless @cmd;

    my ($err_fh, $err_path) = File::Temp::tempfile(
        'ccpraxis-capture-XXXXXX', TMPDIR => 1, UNLINK => 0);
    close($err_fh) if $err_fh;

    my $saved_stderr;
    my $redirected = eval {
        open($saved_stderr, '>&', \*STDERR) or die "dup STDERR: $!\n";
        open(STDERR, '>', $err_path)        or die "redirect STDERR: $!\n";
        STDERR->autoflush(1);
        1;
    };

    my $out = '';
    my $rc;
    my $ok = eval {
        open(my $fh, '-|', @cmd) or die "spawn failed: $!\n";
        local $/;
        $out = <$fh>;
        $out = '' unless defined $out;
        close($fh);
        $rc = $?;
        1;
    };
    unless ($ok) {
        my $e = $@;
        $e =~ s/\s+/ /g;
        $out = "capture_quiet: $e";
        $rc  = -1;
    }

    if ($redirected) {
        eval { close(STDERR); open(STDERR, '>&', $saved_stderr); STDERR->autoflush(1); };
        close($saved_stderr) if $saved_stderr;
    }

    my $err_text = '';
    if (open(my $rf, '<', $err_path)) {
        local $/;
        $err_text = <$rf>;
        $err_text = '' unless defined $err_text;
        close($rf);
    }
    unlink($err_path);

    return ($rc, $out . $err_text);
}

1;
