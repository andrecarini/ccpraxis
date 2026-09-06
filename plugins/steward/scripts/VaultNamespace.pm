package VaultNamespace;
# Scoped commit + push for ONE top-level namespace inside the vault.
#
# WHY THIS IS SHARED RATHER THAN COPIED
#
# The vault holds several root-level namespaces owned by different scripts:
# projects/ (vault-sync.pl), todos/ (todo-sync.pl), reports/ (usage-audit.pl),
# research/ (update-research.pl). Two of those were writing files that NOTHING
# EVER COMMITTED -- `git status` in the vault on 2026-09-06 showed `reports/`
# and `bootstrap-archive/` as untracked, months of /steward:usage-audit output
# that never reached the remote. The skill said "writes a dated report into the
# vault", and it did; the report just never left the machine.
#
# That is what an owner-per-namespace layout costs when each owner is expected
# to reimplement the same eight git calls. So it lives here once.
#
# SCOPING IS THE POINT. Every git operation is restricted with `-- <relpath>`.
# A bare `git add -A` here would sweep another owner's half-finished work into
# this commit, which is exactly the failure mode a shared vault invites.

use strict;
use warnings;

our $VERSION = '1.0';

# git_path -- POSIX path to something native git.exe can actually open.
#
# Callers set MSYS2_ARG_CONV_EXCL=* so that URLs containing "https:" survive
# being passed to curl. That switches OFF the implicit MSYS translation, which
# means paths must be translated HERE. The project CLAUDE.md is explicit that
# the opt-out and the translation are one technique and splitting them is the
# bug -- a bare /tmp/... reaching native git gets resolved against the current
# drive and created at C:\tmp\, the documented drive-root stray.
#
# The `/c/ -> C:/` rule alone does not cover /tmp, so cygpath (which knows the
# real mount table) is asked first and that rule is only the fallback.
my $CYGPATH;
sub git_path {
    my ($p) = @_;
    return $p unless defined $p;
    return $p unless $^O =~ /^(MSWin32|cygwin|msys)$/;
    return $p unless $p =~ m{^/};

    unless (defined $CYGPATH) {
        my $probe = `cygpath -w / 2>/dev/null`;
        $CYGPATH = ($? == 0 && defined $probe && $probe =~ /\S/) ? 1 : 0;
    }
    if ($CYGPATH) {
        my $w = `cygpath -m -- "$p" 2>/dev/null`;
        if ($? == 0 && defined $w) {
            chomp $w;
            return $w if $w =~ /\S/;
        }
    }
    $p =~ s{^/([a-zA-Z])/}{\u$1:/};
    return $p;
}

# sync(%opt) -> hashref
#   vault   => path to the vault working tree (required)
#   path    => namespace relative to the vault root, e.g. 'reports' (required)
#   message => commit message
#   push    => 1 (default) or 0 to commit without pushing
#
# Returns { ok, synced, pushed, reason, steps[], error }. Never dies: a caller
# in the middle of a larger flow must be able to report a sync failure and
# carry on rather than lose the work it just wrote.
sub sync {
    my (%opt) = @_;
    my $vault = $opt{vault};
    my $rel   = $opt{path};
    my $msg   = defined $opt{message} && length $opt{message} ? $opt{message}
                                                              : "steward: sync $rel";
    my $do_push = exists $opt{push} ? $opt{push} : 1;

    return { ok => 0, error => 'no vault path given' }        unless defined $vault && length $vault;
    return { ok => 0, error => 'no namespace path given' }    unless defined $rel && length $rel;
    return { ok => 0, error => "not a git repo: $vault" }     unless -d "$vault/.git";
    # A namespace that does not exist yet is not an error -- it just has
    # nothing to sync. Reporting it as a failure would make every first run of
    # a new namespace look broken.
    return { ok => 1, synced => 0, reason => "nothing at $rel" } unless -e "$vault/$rel";

    my $g = git_path($vault);
    my @steps;
    my $run = sub {
        my (@a) = @_;
        my @cmd = ('git', '-C', $g, @a);
        my $out = '';
        if (open my $ph, '-|', @cmd) { local $/; $out = <$ph> // ''; close $ph }
        my $rc = $? >> 8;
        push @steps, { cmd => join(' ', @a), rc => $rc };
        return ($rc, $out);
    };

    my ($rc_add, $add_out) = $run->('add', '--', $rel);
    return { ok => 0, error => 'git add failed', detail => $add_out, steps => \@steps }
        if $rc_add != 0;

    # --quiet exits 1 when there IS something staged. Checking this before
    # committing is what keeps a no-op run from producing an empty commit on
    # every invocation, which matters now that sync runs automatically.
    my ($rc_diff) = $run->('diff', '--cached', '--quiet', '--', $rel);
    return { ok => 1, synced => 0, reason => 'no changes to commit', steps => \@steps }
        if $rc_diff == 0;

    my ($rc_c, $c_out) = $run->('commit', '-m', $msg, '--', $rel);
    return { ok => 0, error => 'git commit failed', detail => $c_out, steps => \@steps }
        if $rc_c != 0;

    unless ($do_push) {
        return { ok => 1, synced => 1, pushed => 0, reason => 'push not requested', steps => \@steps };
    }

    my ($rc_p, $p_out) = $run->('push');
    return {
        ok     => 1,
        synced => 1,
        pushed => ($rc_p == 0 ? 1 : 0),
        # A failed push is NOT a failed sync. The commit exists locally and the
        # next run pushes it; treating this as fatal would throw away work over
        # a dropped network.
        ($rc_p == 0 ? () : (push_error => $p_out)),
        steps  => \@steps,
    };
}

1;
