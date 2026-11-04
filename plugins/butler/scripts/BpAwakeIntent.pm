# BpAwakeIntent -- the one pure decision behind every "does this keep the
# machine awake" call (package 04 of blueprint wake-and-pause-consolidation).
# Contract: .ccpraxis-local-data/blueprints/wake-and-pause-consolidation/
# specs/04-awake-intent-spec.md.
#
# Four call sites decided this independently before this package: the
# sandboxed fleet's orchestrator (bp-orchestrator.pl, wake-lock phase and the
# busy-lease touch) and drive-solo (bp-drive-next.pl, keep-awake phase and the
# handoff gate). want_awake(\%state) reproduces every one of those decisions
# exactly, by scope -- no behaviour changed, only the decision pulled into one
# place so it is asked once instead of four times.
package BpAwakeIntent;
use strict;
use warnings;

use File::Basename ();
use Cwd ();
use JSON::PP ();
BEGIN {
    my $d = File::Basename::dirname(do { (my $f = __FILE__) =~ s{\\}{/}g; Cwd::abs_path($f) // $f });
    require "$d/BpAwakeConst.pm" unless defined &BpAwakeConst::AC_STALE;
}

# --- want_awake(\%state) -> { awake => 0|1, reason => <word>, until => epoch|undef,
#                              handoff => 0|1 }.  PURE: no I/O, no $ENV, no time/sleep,
# never mutates \%state. scope is 'fleet' (sandboxed orchestrator) or 'solo' (drive-solo);
# each has its own pause rules below because they differ today and stay different
# (manual flag vs reason; regex gate vs raw arithmetic; horizon validation).
#
# Evaluation order (both scopes): shutdown overrides everything; then running; then
# outstanding; then (no pause -> idle); then the scope's pause table.
#
#   shutdown true                    -> 0 shutdown   (overrides everything)
#   running true                     -> 1 running
#   outstanding true                 -> 1 outstanding
#   paused not a HASH ref            -> 0 idle
#   -- fleet (scope => 'fleet'; reason never read) --
#   paused->{manual} true            -> 0 pause-manual   (manual waits on a human)
#   relaunch_at undef/ref/unparseable -> 1 pause-pending  (telemetry: cleared on recovery, short)
#   relaunch_at - now <= horizon     -> 1 pause-pending   (until = relaunch_at if parseable)
#   relaunch_at - now >  horizon     -> 0 pause-beyond-horizon, handoff 1
#   -- solo (scope => 'solo'; manual never read) --
#   reason undef or ne 'usage'       -> 0 pause-manual    (does not auto-resume on a clock)
#   relaunch_at undef                -> 1 pause-pending   (old behaviour: undef holds)
#   (relaunch_at - now) > horizon is false -> 1 pause-pending (until = relaunch_at if parseable)
#   otherwise                         -> 0 pause-beyond-horizon, handoff = L
#       L = 1 iff relaunch_at =~ /\A-?\d+(?:\.\d+)?\z/ && gmtime(int relaunch_at) is true
#             && (relaunch_at - now) > horizon; else 0 (a pathological relaunch_at that
#             breaks gmtime or the regex fails safe to "not long").
sub want_awake {
    my ($state) = @_;
    die "BpAwakeIntent::want_awake: state must be a hash reference\n" unless ref($state) eq 'HASH';
    my $scope = $state->{scope};
    die "BpAwakeIntent::want_awake: scope must be 'fleet' or 'solo'\n"
        unless defined $scope && ($scope eq 'fleet' || $scope eq 'solo');

    return { awake => 0, reason => 'shutdown', until => undef, handoff => 0 } if $state->{shutdown};
    return { awake => 1, reason => 'running', until => undef, handoff => 0 } if $state->{running};
    return { awake => 1, reason => 'outstanding', until => undef, handoff => 0 } if $state->{outstanding};

    my $paused = $state->{paused};
    return { awake => 0, reason => 'idle', until => undef, handoff => 0 } unless ref($paused) eq 'HASH';

    return $scope eq 'fleet'
        ? _fleet_pause($paused, $state->{now}, $state->{horizon})
        : _solo_pause($paused, $state->{now}, $state->{horizon});
}

# --- fleet pause rules (3.2). horizon falls back to FLEET_PAUSE_HORIZON (115200) unless
# the given value is a plain non-negative integer. reason is never read (fleet releases
# on ->{manual}, never on the pause's reason).
sub _fleet_pause {
    my ($paused, $now, $horizon) = @_;
    return { awake => 0, reason => 'pause-manual', until => undef, handoff => 0 } if $paused->{manual};
    my $at = $paused->{relaunch_at};
    unless (defined $at && !ref($at) && $at =~ /^\d+(?:\.\d+)?$/) {
        return { awake => 1, reason => 'pause-pending', until => undef, handoff => 0 };
    }
    my $H = (defined $horizon && !ref($horizon) && $horizon =~ /^\d+$/) ? $horizon : BpAwakeConst::FLEET_PAUSE_HORIZON();
    if ($at - $now <= $H) {
        my $until = ($at =~ /\A\d+(?:\.\d+)?\z/) ? $at : undef;
        return { awake => 1, reason => 'pause-pending', until => $until, handoff => 0 };
    }
    return { awake => 0, reason => 'pause-beyond-horizon', until => undef, handoff => 1 };
}

# --- solo pause rules (3.3). horizon is used raw (no validation, as today), falling back
# to SOLO_PAUSE_HORIZON (43200) only when undef -- unreachable from any real call site.
# manual is never read (solo releases on reason ne 'usage', never on ->{manual}).
sub _solo_pause {
    my ($paused, $now, $horizon) = @_;
    my $reason = $paused->{reason};
    return { awake => 0, reason => 'pause-manual', until => undef, handoff => 0 }
        unless defined $reason && $reason eq 'usage';
    my $at = $paused->{relaunch_at};
    return { awake => 1, reason => 'pause-pending', until => undef, handoff => 0 } unless defined $at;
    my $H = defined $horizon ? $horizon : BpAwakeConst::SOLO_PAUSE_HORIZON();
    unless (($at - $now) > $H) {
        my $until = ($at =~ /\A\d+(?:\.\d+)?\z/) ? $at : undef;
        return { awake => 1, reason => 'pause-pending', until => $until, handoff => 0 };
    }
    my $handoff = ($at =~ /\A-?\d+(?:\.\d+)?\z/ && gmtime(int $at) && (($at - $now) > $H)) ? 1 : 0;
    return { awake => 0, reason => 'pause-beyond-horizon', until => undef, handoff => $handoff };
}

# --- lease_line(\%intent, $written_at) -> $line | undef (package
# 05-intent-in-busy-lease, blueprint wake-and-pause-consolidation).
# PURE: no I/O, no $ENV, no time/sleep --
# the caller supplies $written_at so this can be tested without a clock.
# Decision 12 (never write awake=>0) is enforced at the FORMAT level: there is
# no code path here that can produce a line whose decoded awake is not 1, so a
# caller cannot defeat the decision by mis-threading a falsy intent through.
sub lease_line {
    my ($intent, $written_at) = @_;
    return undef unless ref($intent) eq 'HASH' && $intent->{awake};
    return undef unless defined($written_at) && !ref($written_at) && $written_at =~ /\A\d+\z/;

    my $reason = $intent->{reason};
    $reason = 'unknown' unless defined $reason && !ref($reason) && length($reason);

    my $until;
    my $raw_until = $intent->{until};
    $until = 0 + $raw_until if defined($raw_until) && !ref($raw_until) && $raw_until =~ /\A\d+(?:\.\d+)?\z/;

    my $obj = {
        v          => 1,
        awake      => 1,
        reason     => $reason,
        until      => $until,
        written_at => 0 + $written_at,
    };
    return JSON::PP->new->canonical(1)->encode($obj) . "\n";
}

1;
