# BpHook::SessionStartNudge -- SessionStart nudge for never-halt package 12
# (specs/12-session-start-nudge-spec.md, Decision 43: N6 "compacted while
# armed, re-read your task list" and N1-now "resumed while armed, continue
# or turn continuity off"). One shim (session-start-nudge.sh) registered on
# SessionStart, matcher-less, beside denial-breaker.sh.
#
# lines($p, $now) is a pure function (one -e stat aside, via BpHook::is_armed)
# returning the context lines for this SessionStart; () means quiet. run($p)
# wraps it in eval and emits at most one additionalContext line through
# BpHook::context. Never writes a file, never dies outward, never returns 2.
package BpHook::SessionStartNudge;
use strict;
use warnings;
use File::Basename qw(dirname);
use Cwd ();

my $SELF_DIR;
{
    my $f = __FILE__;
    $f = Cwd::abs_path($f) // $f;
    $SELF_DIR = dirname($f);
}
require "$SELF_DIR/../BpHook.pm"
    unless grep { m{(?:^|/)BpHook\.pm$} } keys %INC;

# ---------------------------------------------------------------------------
# sec 2.2 -- pinned text, byte-exact.
# ---------------------------------------------------------------------------
our $COMPACT_TEXT  = 'Compacted while continuity is armed: re-read your task list, and the ledger of any package you are driving, before the next step.';
our $RESUME_FORMAT = "Resumed at %s while continuity is armed: continue the held work, or turn continuity off with a reason: butler-continuity off --reason '<why>'";

sub _is_plain_string {
    my ($v) = @_;
    return defined($v) && !ref($v);
}

# lines($p, $now) -> list of context strings for this SessionStart; () = quiet.
# $now: optional integer epoch, default time(). Never prints, never writes,
# never dies outward (callers still wrap it).
sub lines {
    my ($p, $now) = @_;

    return () unless ref $p eq 'HASH';

    my $ledger = $ENV{BP_LEDGER};
    return () if defined $ledger && length $ledger;

    return () unless _is_plain_string($p->{hook_event_name})
        && $p->{hook_event_name} eq 'SessionStart';

    return () if defined BpHook::agent_id($p);

    my $sid = BpHook::session_id($p);
    return () unless defined $sid;

    my $src = $p->{source};
    return () unless _is_plain_string($src) && ($src eq 'compact' || $src eq 'resume');

    return () unless BpHook::is_armed($sid);

    return ($COMPACT_TEXT) if $src eq 'compact';
    my $hhmm = BpHook::local_utc_hhmm(int(defined $now ? $now : time()));
    return () unless defined $hhmm;
    return (sprintf($RESUME_FORMAT, $hhmm));
}

# run($p, @ignored) -> 0, always.
sub run {
    my ($p) = @_;
    my @l = lines($p);
    BpHook::context(join("\n", @l)) if @l;
    return 0;
}

1;
