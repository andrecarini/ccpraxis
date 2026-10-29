#!/usr/bin/env perl
# bp-contract.pl — Anthropic-side + creds CONTRACT validators (Decision #29/#31).
#
# Pure, dependency-light functions that validate a *parsed* response/shape against
# the contract A0 pinned in plugins/butler/docs/assumptions.json. The orchestrator
# (A3) calls these on every usage poll / refresh / creds read; on drift it must
# alarm + graceful-pause + queue a escalations decision — NEVER proceed on data it
# doesn't recognize, NEVER fail silently.
#
# Dual use:
#   require:  require "<path>/bp-contract.pl"; my ($ok,$probs)=BpContract::validate_usage($parsed);
#   CLI:      perl bp-contract.pl <usage|refresh|creds> <file.json>   (exit 0 ok, 1 drift, 2 usage error)
#
# Returns ($ok, \@problems): $ok is 1/0; @problems names each violated field
# precisely (so the alarm/log says exactly WHAT drifted).

package BpContract;
use strict;
use warnings;

sub _is_iso8601 { my $s = shift; defined $s && $s =~ /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/ }
sub _is_num     { my $n = shift; defined $n && !ref $n && $n =~ /^-?\d+(?:\.\d+)?$/ }
sub _is_int     { my $n = shift; defined $n && !ref $n && $n =~ /^\d+$/ }
sub _is_str     { my $s = shift; defined $s && !ref $s && length $s }

# A WINDOW WHOSE RESET IS IN THE PAST IS NOT A STALE READING. IT IS A WRONG ONE.
#
# Measured over ~40 minutes on one session, no config change in between:
#
#   22:32Z  5h 18%  resets 2026-09-12T02:00Z   7d 79%   plausible
#   23:00Z  5h 35%  resets 2026-09-10T03:49Z   7d 40%   IMPOSSIBLE
#   23:25Z  5h 24%  resets 2026-09-12T02:00Z   7d 80%   plausible again
#
# The middle reading is self-inconsistent on its own terms: a window that resets
# every five hours cannot have a reset time 36 hours in the past, and its 7-day
# figure halved and recovered with no boundary crossed. The record is its own
# evidence of being bad -- and nothing was checking (almanac 20260911-224528-e213).
#
# This matters because butler GATES on it. A reading wrong by 40 percentage
# points either halts work that should proceed or lets work continue past a
# ceiling, and a caller currently has no way to tell a good read from a bad one.
#
# FAILING HERE IS CHEAP, WHICH IS WHY THE CHECK BELONGS HERE. bp-usage-gate.pl
# routes a validate_usage failure to action=unavailable/reason=telemetry -- "no
# reading", not "pause". So a false positive costs one skipped poll, while a
# false negative is a gate acting on a number that cannot be true.
#
# The bounds stay LOOSE on purpose. b28 is the cautionary case in this very
# function: an over-strict usage contract false-positived a drift and paused
# whole unattended fleets. $CLOCK_GRACE absorbs host/server skew in both
# directions, and only a stamp that no correct server could emit is refused.
# ONLY THE PAST BOUND. An earlier draft also refused a stamp further ahead than
# one window allows, which is true of a correct server and false of this repo's
# own fixtures: '2099-01-01T00:00:00Z' is the established idiom for "definitely
# not expired" and appears throughout usage-governor.t. Refusing it turned every
# time-pinned reading in the suite into action=unavailable.
#
# The measured defect was a stamp in the PAST, the report asked for exactly that
# check, and b28 -- in this same function -- is the standing warning about
# tightening a usage contract further than the evidence supports. So the upper
# bound is deliberately absent rather than merely unimplemented.
my %WINDOW_SPAN = (five_hour => 5 * 3600, seven_day => 7 * 86400);
my $CLOCK_GRACE = 300;

# _iso_epoch($iso) -> epoch | undef. Total; never dies on hostile input.
sub _iso_epoch {
    my ($iso) = @_;
    return undef unless defined $iso && !ref $iso
        && $iso =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})/;
    require Time::Local;
    my $e = eval { Time::Local::timegm($6, $5, $4, $3, $2 - 1, $1) };
    return (defined $e && !$@) ? $e : undef;
}

# _reset_stamp_impossible($window, $iso, $now) -> reason | undef
sub _reset_stamp_impossible {
    my ($w, $iso, $now) = @_;
    my $span = $WINDOW_SPAN{$w} or return undef;      # unknown window: not ours to judge
    my $e = _iso_epoch($iso);
    return undef unless defined $e;                   # unparseable is _is_iso8601's business
    return "resets_at is in the past ($iso); a $w window cannot have already reset"
        if $e < $now - $CLOCK_GRACE;
    return undef;
}

# usage: GET /api/oauth/usage  →  five_hour/seven_day.{utilization:int%, resets_at:ISO}
# THE RESET-STAMP RULE IS OPT-IN, AND THAT IS A DELIBERATE LIMITATION.
#
# $now enables it. A one-argument call gets the pure SHAPE check this function
# has always been, unchanged.
#
# The alternative -- defaulting to time() -- was tried and measured: it reaches
# three separate call paths (bp-usage-gate.pl's poll, BpOrch::usage_decision,
# and the validators' own suite), each carrying fixtures pinned to a real
# captured moment, and it failed roughly twenty assertions across five files for
# being OLD rather than for being wrong. Rewriting those fixtures would have
# thrown away what makes them evidence.
#
# So the protection covers the caller that passes a clock. Today that is
# bp-usage-gate.pl -- which is the path the report is about ("butler gates on
# it": --gate decides whether a package may run). BpOrch::usage_decision does
# NOT get it, and saying so here is better than implying a guarantee this does
# not give.
sub validate_usage {
    my ($d, $now) = @_;
    undef $now unless defined $now && !ref $now && $now =~ /^\d+$/;
    return (0, ['usage: response is not a JSON object']) unless ref $d eq 'HASH';
    my @p;
    for my $w (qw(five_hour seven_day)) {
        my $o = $d->{$w};
        unless (ref $o eq 'HASH') { push @p, "usage: '$w' window missing or not an object"; next; }
        if (!_is_num($o->{utilization})) {
            push @p, "usage: $w.utilization missing or non-numeric";
        } elsif ($o->{utilization} < 0 || $o->{utilization} > 100) {
            push @p, "usage: $w.utilization out of 0..100 (got $o->{utilization})";
        }
        # An idle window (utilization 0) legitimately has no resets_at — requiring it
        # here false-positived a contract-drift and paused whole unattended fleets (b28).
        if (_is_num($o->{utilization}) && $o->{utilization} > 0) {
            if (!_is_iso8601($o->{resets_at})) {
                push @p, "usage: $w.resets_at missing or not ISO-8601";
            } elsif (defined $now and my $why = _reset_stamp_impossible($w, $o->{resets_at}, $now)) {
                push @p, "usage: $w.$why";
            }
        }
    }
    return (@p ? 0 : 1, \@p);
}

# refresh: POST platform.claude.com/v1/oauth/token  →  {access_token, expires_in[, refresh_token]}
sub validate_refresh {
    my ($d) = @_;
    return (0, ['refresh: response is not a JSON object']) unless ref $d eq 'HASH';
    my @p;
    push @p, 'refresh: access_token missing or empty'         unless _is_str($d->{access_token});
    push @p, 'refresh: expires_in missing or non-positive'    unless _is_num($d->{expires_in}) && $d->{expires_in} > 0;
    # refresh_token is optional (server may omit → keep the old one); validate type if present.
    push @p, 'refresh: refresh_token present but empty'        if exists $d->{refresh_token} && !_is_str($d->{refresh_token});
    return (@p ? 0 : 1, \@p);
}

# creds: ~/.claude/.credentials.json  →  claudeAiOauth.{accessToken,refreshToken,expiresAt(ms),scopes[]}
sub validate_creds {
    my ($d) = @_;
    return (0, ['creds: file is not a JSON object']) unless ref $d eq 'HASH';
    my $o = $d->{claudeAiOauth};
    return (0, ['creds: claudeAiOauth object missing']) unless ref $o eq 'HASH';
    my @p;
    push @p, 'creds: accessToken missing or empty'  unless _is_str($o->{accessToken});
    push @p, 'creds: refreshToken missing or empty' unless _is_str($o->{refreshToken});
    push @p, 'creds: expiresAt missing or not epoch-ms (>1e12)'
        unless _is_int($o->{expiresAt}) && $o->{expiresAt} > 1_000_000_000_000;
    push @p, 'creds: scopes missing or not an array' unless ref $o->{scopes} eq 'ARRAY';
    return (@p ? 0 : 1, \@p);
}

our %DISPATCH = (
    usage   => \&validate_usage,
    refresh => \&validate_refresh,
    creds   => \&validate_creds,
);

# ---- CLI (only when run directly) ----------------------------------------
package main;
use strict;
use warnings;
unless (caller) {
    require JSON::PP;
    my ($kind, $file) = @ARGV;
    unless (defined $kind && defined $file && $BpContract::DISPATCH{$kind}) {
        print STDERR "usage: bp-contract.pl <usage|refresh|creds> <file.json>\n";
        exit 2;
    }
    open my $fh, '<:raw', $file or do { print STDERR "open $file: $!\n"; exit 2 };
    local $/; my $raw = <$fh>; close $fh;
    my $data = eval { JSON::PP->new->decode($raw) };
    unless (defined $data) { print STDERR "contract DRIFT [$kind]: response is not valid JSON\n"; exit 1 }
    my ($ok, $probs) = $BpContract::DISPATCH{$kind}->($data);
    if ($ok) { print "contract OK [$kind]\n"; exit 0 }
    print STDERR "contract DRIFT [$kind] — Anthropic-side shape changed, NOT proceeding:\n";
    print STDERR "  - $_\n" for @$probs;
    exit 1;
}
1;
