# BpHook::SessionStartNudge -- the one SessionStart route (blueprint
# where-things-go, package 10-gatherer-and-digest, specs/
# 10-gatherer-and-digest-spec.md sec 2.6; originally never-halt package 12,
# specs/12-session-start-nudge-spec.md, Decision 43: N6 "compacted while
# armed, re-read your task list" and N1-now "resumed while armed, continue
# or turn continuity off"). One shim (session-start-nudge.sh) registered on
# SessionStart, matcher-less, beside denial-breaker.sh. It now fires on every
# source (startup, resume, clear, compact), armed or not: run($p) re-attaches
# the session's thread ownership first (Almanac::Thread::reattach), then
# prints the project digest (Almanac::Gather::digest), then the never-halt-12
# armed nudges below (lines($p)) -- all through one BpHook::context call, in
# that fixed order (sec 2.6).
#
# lines($p, $now) is a pure function (one -e stat aside, via BpHook::is_armed)
# returning the context lines for this SessionStart; () means quiet. run($p)
# wraps reattach/digest/lines in eval and emits at most one additionalContext
# line through BpHook::context. Never writes a file, never dies outward,
# never returns non-zero.
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

# Almanac modules, loaded relative to $SELF_DIR (sec 2.6). A load failure is
# caught -- the hook still emits the never-halt-12 nudges.
my $ALMANAC_THREAD_PM = "$SELF_DIR/../../../almanac/scripts/Almanac/Thread.pm";
my $ALMANAC_GATHER_PM = "$SELF_DIR/../../../almanac/scripts/Almanac/Gather.pm";

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

# run($p, @ignored) -> 0, always. The one SessionStart route (sec 2.6): same
# guards as lines(), then (1) Almanac::Thread::reattach, (2)
# Almanac::Gather::digest, (3) the never-halt-12 armed nudges (lines($p)),
# all through one BpHook::context call, in that fixed order. Runs on every
# source (startup, resume, clear, compact), armed or not -- only step 3 is
# gated on arming, inside lines() itself. Never dies outward: each step is
# individually eval'd, so a reattach/digest failure still lets the nudges
# (or nothing) through.
sub run {
    my ($p) = @_;

    return 0 unless ref $p eq 'HASH';

    my $ledger = $ENV{BP_LEDGER};
    return 0 if defined $ledger && length $ledger;

    return 0 unless _is_plain_string($p->{hook_event_name})
        && $p->{hook_event_name} eq 'SessionStart';

    return 0 if defined BpHook::agent_id($p);

    my $sid = BpHook::session_id($p);
    return 0 unless defined $sid;

    my $src_raw = $p->{source};
    my %src_ok = map { $_ => 1 } qw(startup resume clear compact);
    my $src = (_is_plain_string($src_raw) && $src_ok{$src_raw}) ? $src_raw : 'startup';

    eval {
        require $ALMANAC_THREAD_PM;
        Almanac::Thread::reattach(
            session    => $sid,
            transcript => $p->{transcript_path},
            source     => $src,
            cwd        => $p->{cwd},
        );
    };

    my $digest = eval {
        require $ALMANAC_GATHER_PM;
        Almanac::Gather::digest(cwd => $p->{cwd});
    };
    $digest = '' unless defined $digest;

    my @nudge = eval { lines($p) };
    @nudge = () if $@;

    my @parts = grep { length } ($digest, @nudge);
    BpHook::context(join("\n", @parts)) if @parts;
    return 0;
}

1;
