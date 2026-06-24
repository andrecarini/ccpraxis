#!/usr/bin/env perl
# bp-contract.pl — Anthropic-side + creds CONTRACT validators (Decision #29/#31).
#
# Pure, dependency-light functions that validate a *parsed* response/shape against
# the contract A0 pinned in plugins/butler/docs/assumptions.json. The orchestrator
# (A3) calls these on every usage poll / refresh / creds read; on drift it must
# alarm + graceful-pause + queue a needs-you decision — NEVER proceed on data it
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

# usage: GET /api/oauth/usage  →  five_hour/seven_day.{utilization:int%, resets_at:ISO}
sub validate_usage {
    my ($d) = @_;
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
        push @p, "usage: $w.resets_at missing or not ISO-8601" unless _is_iso8601($o->{resets_at});
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
