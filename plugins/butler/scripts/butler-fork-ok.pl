#!/usr/bin/env perl
# butler-fork-ok.pl -- the fork-override recorder (package 19 of blueprint
# hook-continuity-remake, Decision 64/91).
#
#   butler-fork-ok --reason '<why a fresh subagent will not do>'
#
# Contract: .ccpraxis-local-data/blueprints/hook-continuity-remake/specs/
# 19-fork-guard-spec.md sec 2.6. Architecture: docs/hook-architecture.md
# ("guard-fork.sh" rows, "Command binding").
#
# NO SESSION SELECTOR. This command never reads the caller's environment for
# a session identity; it learns its session only from a hook-written ticket
# (BpHook::take_ticket) for the exact argv it was given. There is no --token
# path (Decision 91 scope): stop tokens are accepted by
# butler-continuity off|silence and butler-hold only.
#
# All output is ONE line on stdout, prefixed "butler-fork-ok: "; stderr
# stays empty. Exit 0 = recorded; exit 1 = refused (never 2). Any unexpected
# die is caught by the top-level eval below.
use strict;
use warnings;
use FindBin qw($Bin);

sub out_line {
    my ($line) = @_;
    print STDOUT $line . "\n";
    return;
}

sub refuse {
    my ($msg) = @_;
    out_line("butler-fork-ok: $msg");
    exit 1;
}

sub main {
    require "$Bin/BpHook.pm"
        unless grep { m{(?:^|/)BpHook\.pm$} } keys %INC;
    require "$Bin/BpHook/Guards/GuardFork.pm"
        unless grep { m{(?:^|/)Guards/GuardFork\.pm$} } keys %INC;

    $| = 1;
    binmode(STDOUT, ':raw');
    binmode(STDERR, ':raw');
    $SIG{__WARN__} = sub { };

    my @ARGV_RAW = @ARGV;

    # step 1: shape. Exactly ('--reason') or ('--reason', X); '--reason=X' is
    # not accepted, and any other shape (including no args, extra args, or a
    # different flag) fails here -- before anything is read or written.
    my $USAGE = q{usage: butler-fork-ok --reason '<why a fresh subagent will not do>'};
    refuse($USAGE) if @ARGV_RAW == 0;
    refuse($USAGE) if $ARGV_RAW[0] ne '--reason';
    refuse($USAGE) if @ARGV_RAW > 2;

    # step 2: the reason itself.
    my $reason = (@ARGV_RAW == 2) ? $ARGV_RAW[1] : undef;
    refuse(q{--reason needs at least two words and 10 characters saying why.})
        unless defined $reason && BpHook::Guards::GuardFork::valid_reason($reason);

    # step 3: state root.
    my $root = BpHook::state_dir();
    refuse('no continuity state directory (set HOME, or an absolute BUTLER_STATE_DIR).')
        unless defined $root;

    # step 4: binding, via the core ticket API for this exact argv.
    my $ticket = BpHook::take_ticket('butler-fork-ok', \@ARGV_RAW);
    refuse('no session binding; run it as its own command with the reason in single quotes.')
        unless ref $ticket eq 'HASH';

    my $sid = $ticket->{session_id};

    # step 5: only the main session records an override.
    refuse('only the main session records a fork override.')
        if defined $ticket->{agent_id};

    # step 6: record the token. Save whatever token this call is about to
    # overwrite first, so a step-7 failure can put it back rather than just
    # unlinking -- otherwise the unwind destroys a PREVIOUS, still-valid
    # override that has nothing to do with this call (red-team m-2).
    my $prior_path = "$root/fork-ok/$sid.json";
    my $prior_bytes;
    if (defined $sid && $sid =~ /\A[A-Za-z0-9_-]{1,128}\z/ && -f $prior_path) {
        if (open(my $fh, '<:raw', $prior_path)) {
            local $/;
            $prior_bytes = <$fh>;
            close $fh;
        }
    }
    refuse('could not record the override; nothing was recorded.')
        unless BpHook::Guards::GuardFork::record_token($sid, $reason);

    # step 7: log the reason; unwind THIS call's write on failure -- restore
    # the prior token if there was one, or remove the file only when this
    # call was the one that created it.
    my $project = defined $ticket->{cwd} && length $ticket->{cwd} ? $ticket->{cwd} : '-';
    unless (BpHook::log_reason($sid, 'agent', 'fork-ok', $reason, $project)) {
        if (defined $prior_bytes) {
            if (open(my $fh, '>:raw', $prior_path)) {
                print $fh $prior_bytes;
                close $fh;
            }
        }
        else {
            unlink($prior_path);
        }
        refuse('could not record the override; nothing was recorded.');
    }

    # step 8: success.
    out_line('butler-fork-ok: recorded; the next fork dispatch in this session is allowed once.');
    exit 0;
}

my $MAIN_OK = eval { main(); 1 };
unless ($MAIN_OK) {
    print STDOUT "butler-fork-ok: internal error; nothing was recorded.\n";
    exit 1;
}
exit 0;
