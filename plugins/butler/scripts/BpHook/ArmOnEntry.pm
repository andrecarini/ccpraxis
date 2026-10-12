# BpHook::ArmOnEntry -- arms a drive-solo session's id with role driver on
# its first real director "next" call (package 07 of blueprint
# hook-continuity-remake). Contract: specs/07-arm-on-entry-spec.md;
# architecture: plugins/butler/docs/hook-architecture.md ("Who arms",
# "Session roles", "Guard message budgets").
#
# Additive only (Decision 19): nothing here is registered; package 16 wires
# this into hooks.json. BpHook.pm belongs to package 03 and is read, never
# edited or reimplemented -- director_next_call() below is a thin, spec-
# literal wrapper over BpHook::invocations(), not a second parser.
package BpHook::ArmOnEntry;
use strict;
use warnings;
use B qw(svref_2object SVp_POK);

our $DENY_LINE = 'butler: a subagent may not call bp-drive-next next; only the driving session\'s main thread runs the director.';

# F2 (red-team H1, package 16 fix-batch): a session with an off/<sid>
# record must stay off until an explicit "on" (Decision 1) -- it must not
# be silently re-armed just because it calls `next` again.
our $OFF_DENY_LINE = 'butler: continuity is off for this session; run `butler-continuity on` before calling `next` again.';

# A plain (unblessed) string scalar, the same test BpHook.pm itself uses
# internally to tell "42" (a real string) apart from 42 (a bare IV that
# happens to stringify the same way) -- see spec sec 2.3 step 3.
sub _is_plain_string {
    my ($v) = @_;
    return 0 unless defined $v;
    return 0 if ref $v;
    my $flags = svref_2object(\$v)->FLAGS;
    return ($flags & SVp_POK()) ? 1 : 0;
}

# director_next_call($command) -> 1 iff some argv in
# BpHook::invocations($command, 'bp-drive-next') has a defined argv->[0]
# equal to 'next'. An undef or non-string $command -> 0.
sub director_next_call {
    my ($command) = @_;
    return 0 unless _is_plain_string($command);
    my @invs = BpHook::invocations($command, 'bp-drive-next');
    for my $argv (@invs) {
        next unless ref $argv eq 'ARRAY';
        my $first = $argv->[0];
        return 1 if defined $first && !ref($first) && $first eq 'next';
    }
    return 0;
}

# run($p, @args) -> 0 | 2. Never calls exit; prints only through
# BpHook::deny. See spec sec 2.3 for the exact, numbered decision order.
sub run {
    my ($p, @args) = @_;

    return 0 unless BpHook::payload_ok();
    return 0 unless ref $p eq 'HASH';
    return 0 unless defined $p->{tool_name} && $p->{tool_name} eq 'Bash';

    my $cmd = (ref $p->{tool_input} eq 'HASH') ? $p->{tool_input}{command} : undef;
    return 0 unless _is_plain_string($cmd);

    return 0 unless director_next_call($cmd);

    return 0 if defined $ENV{BP_LEDGER} && length $ENV{BP_LEDGER};

    my $sid = BpHook::session_id($p);
    return 0 unless defined $sid;

    if (defined BpHook::agent_id($p)) {
        if (BpHook::role($p) eq 'driver') {
            return BpHook::deny($DENY_LINE);
        }
        return 0;
    }

    # F2 (red-team H1): before this fix, an off session's `next` was silently
    # allowed with nothing armed, so the director handed out (concurrent)
    # packages to a caller with no bind-dispatch and no write-set guard.
    # Deny instead, and never arm.
    return BpHook::deny($OFF_DENY_LINE) if BpHook::latest_is_off($sid);

    if (BpHook::role($p) eq 'driver') {
        my $root = BpHook::state_dir();
        if (defined $root) {
            utime(undef, undef, "$root/armed/$sid");
        }
        _reattach_thread($p);
        return 0;
    }

    my %opts = (role => 'driver', by => 'arm-on-entry');
    my $tp = $p->{transcript_path};
    if (_is_plain_string($tp) && length $tp) {
        $opts{transcript_path} = $tp;
    }
    BpHook::arm($sid, %opts);
    _reattach_thread($p);
    return 0;
}

# _reattach_thread($p) -- blueprint where-things-go, package 03-thread-
# sessions, spec 2.10: calls Almanac::Thread::reattach on every director
# call, using the payload's own cwd (never the process cwd or
# CLAUDE_PROJECT_DIR). Never denies, never prints, never fails the hook,
# ignores the result.
sub _reattach_thread {
    my ($p) = @_;
    my $cwd = $p->{cwd};
    return unless _is_plain_string($cwd) && length $cwd && -d BpHook::_to_bytes($cwd);
    my $self_dir = __FILE__;
    $self_dir =~ s{\\}{/}g;
    $self_dir =~ s{/[^/]+\z}{};   # strip ArmOnEntry.pm -> .../BpHook
    my $alm = "$self_dir/../../../almanac/scripts";
    return unless -f "$alm/Almanac/Thread.pm";
    local $@;
    eval {
        { local @INC = ($alm, @INC); require Almanac::Thread; }
        Almanac::Thread::reattach(session => BpHook::session_id($p),
            transcript => $p->{transcript_path}, source => 'arm-on-entry', cwd => $cwd);
    };
    return;
}

1;
