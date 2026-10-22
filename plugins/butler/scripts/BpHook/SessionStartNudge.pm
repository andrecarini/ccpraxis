# BpHook::SessionStartNudge -- the one SessionStart route (blueprint
# where-things-go, package 10-gatherer-and-digest, specs/
# 10-gatherer-and-digest-spec.md sec 2.6; originally never-halt package 12,
# specs/12-session-start-nudge-spec.md, Decision 43: N6 "compacted while
# armed, re-read your task list" and N1-now "resumed while armed, continue
# or turn continuity off"). One shim (session-start-nudge.sh) registered on
# SessionStart, matcher-less, beside denial-breaker.sh. It now fires on every
# source (startup, resume, clear, compact), armed or not: the emitted TEXT is
# always, in this fixed order (sec 2.6): the project digest
# (Almanac::Gather::digest), then the never-halt-12 armed nudges (lines($p)).
# Internally, run($p) COMPUTES lines($p) first and Almanac::Thread::reattach
# second, both before the (budgeted) digest call -- redteam M2: the nudges
# are the never-halt safety signal and must not be delayed or lost just
# because the digest (reconcile + per-blueprint sweeps) is slow, and the
# digest is wrapped in an 8s alarm so a pathological digest (e.g. a FIFO
# somewhere under a blueprint.md path) cannot hang the hook. All three
# outputs are joined through one BpHook::context call.
#
# lines($p, $now) is a pure function (one -e stat aside, via BpHook::is_armed)
# returning the context lines for this SessionStart; () means quiet, and on
# its own never writes a file. run($p) wraps reattach/digest/lines in eval
# and emits at most one additionalContext line through BpHook::context;
# run() itself DOES write, through reattach (thread ownership) and through
# digest's two project-mode refresh calls (AlmanacBug::reconcile, the
# bp-answer-escalation.pl sweep) -- see hook-architecture.md's route table.
# Never dies outward, never returns non-zero.
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
# guards as lines(), then COMPUTES (1) the never-halt-12 armed nudges
# (lines($p)), (2) Almanac::Thread::reattach, (3) Almanac::Gather::digest
# (under an 8s alarm budget) -- in that order (redteam M2: nudges first, so
# a slow/hung digest never delays or loses them) -- but EMITS them through
# one BpHook::context call in the fixed text order sec 2.6 requires: digest,
# then nudges. Runs on every source (startup, resume, clear, compact), armed
# or not -- only the nudges are gated on arming, inside lines() itself.
# Never dies outward: each step is individually eval'd, so a reattach/digest
# failure still lets the nudges (or nothing) through.
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

    # The payload is JSON-decoded, so a non-ASCII cwd comes back utf8-
    # flagged even though its bytes are identical to the real path on
    # disk. Every filesystem walk downstream (project root resolution,
    # Gather's own root check) mis-stats a flagged string unless it is
    # turned into a definite byte string first. encode-if-flagged, NOT
    # utf8::downgrade -- downgrade corrupts genuinely multi-byte UTF-8
    # content (this package's own "André" fixture) instead of normalizing
    # it; see BpHook.pm::_to_bytes / Almanac::PackageLink.pm:96 for the
    # established rule, and blueprint where-things-go, package
    # 10-gatherer-and-digest, reviewer M2 / redteam H1 for why downgrade
    # was wrong here.
    my $cwd = $p->{cwd};
    if (defined $cwd && !ref $cwd) {
        utf8::encode($cwd) if utf8::is_utf8($cwd);
    }

    # redteam M2: compute the never-halt-12 armed nudges BEFORE the digest,
    # not after. They are the never-halt safety signal for a compacted/
    # resumed armed session, and must not be lost or delayed just because
    # the digest (reattach + reconcile + per-blueprint sweeps) is slow or
    # hung.
    my @nudge = eval { lines($p) };
    @nudge = () if $@;

    eval {
        require $ALMANAC_THREAD_PM;
        Almanac::Thread::reattach(
            session    => $sid,
            transcript => $p->{transcript_path},
            source     => $src,
            cwd        => $cwd,
        );
    };

    # redteam M2: bound the digest (reconcile + sweeps, in-process filesystem
    # reads, possibly a FIFO somewhere under a blueprint.md path) with a time
    # budget well inside the registered 15s hook timeout, so a pathological
    # digest cannot hang the hook or take the nudges above down with it.
    my $digest = '';
    eval {
        local $SIG{ALRM} = sub { die "digest timed out\n" };
        my $prev = alarm(8);
        my $d = eval {
            require $ALMANAC_GATHER_PM;
            Almanac::Gather::digest(cwd => $cwd);
        };
        alarm($prev // 0);
        $digest = $d if defined $d && !$@;
    };

    my @parts = grep { length } ($digest, @nudge);
    BpHook::context(join("\n", @parts)) if @parts;
    return 0;
}

1;
