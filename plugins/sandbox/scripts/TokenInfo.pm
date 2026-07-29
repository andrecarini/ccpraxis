package TokenInfo;
# Turns a parsed credentials document + the file's mtime + "now" into a
# render-ready, token-material-free status struct (s08-token-panel).
#
# PURE module: no file I/O (no open/stat/-e), no time()/localtime/gmtime
# anywhere in this file -- "now" is always an argument. Never dies on any
# input (total function). Loaded by launcher.pl only; Dashboard.pm does NOT
# load it (Dashboard renders the already-computed struct via
# Dashboard::_token_lines, never talking to TokenInfo directly).
#
# See specs/s08-token-panel-spec.md S2.1 / S3 (B1-B12) for the binding
# contract this module implements.

use strict;
use warnings;
use Digest::MD5 ();     # already a sandbox-scripts dependency (BackpackApproval.pm:23)

# _num($v) -> $v if it looks like a plain (optionally signed, optionally
# fractional) number, else undef. Used to validate $now / $mtime / expiresAt
# without ever dying on non-numeric input (spec: never trust "does it just
# work in arithmetic").
sub _num {
    my ($v) = @_;
    return undef unless defined $v;
    return undef unless $v =~ /^-?\d+(?:\.\d+)?$/;
    return $v;
}

# _uint($v) -> $v if it looks like a non-negative integer (matches /^\d+$/
# per the spec's literal contract for expiresAt/mtime), else undef.
sub _uint {
    my ($v) = @_;
    return undef unless defined $v;
    return undef unless $v =~ /^\d+$/;
    return $v;
}

# TokenInfo::fingerprint($str) -> 8-char lowercase hex | undef.
# PUBLIC, pure, total. An identity marker, not a security primitive.
sub fingerprint {
    my ($str) = @_;
    return undef if ref $str;
    return undef unless defined $str && length $str;
    my $bytes = $str;
    utf8::encode($bytes) if utf8::is_utf8($bytes);   # never die on a wide string
    return substr(Digest::MD5::md5_hex($bytes), 0, 8);
}

# _not_logged_in_struct($mtime, $now) -> the canonical not-logged-in struct
# (B11), with the mtime/age keys computed the normal way (B8 still applies
# even when there's no token at all -- the file may exist with an empty/bad
# body, and its mtime is still meaningful, per S5).
sub _not_logged_in_struct {
    my ($mtime, $now) = @_;
    my ($last_refreshed_at, $last_refreshed_age) = _refreshed_fields($mtime, $now);
    return {
        logged_in            => 0,
        access_present       => 0,
        access_state         => 'absent',
        access_expires_at    => undef,
        access_seconds_left  => undef,
        refresh_present      => 0,
        refresh_fingerprint  => undef,
        refresh_expires      => 'n/a (not stored)',
        last_refreshed_at    => $last_refreshed_at,
        last_refreshed_age   => $last_refreshed_age,
    };
}

# _refreshed_fields($mtime, $now) -> ($last_refreshed_at, $last_refreshed_age)
# per B8: last_refreshed_at is $mtime verbatim (only when it matches /^\d+$/),
# last_refreshed_age is $now - $mtime clamped to a minimum of 0. Either bad
# input degrades both to undef.
sub _refreshed_fields {
    my ($mtime, $now) = @_;
    my $lra_at = _uint($mtime);
    return (undef, undef) unless defined $lra_at;
    my $n = _num($now);
    return ($lra_at, undef) unless defined $n;
    my $age = $n - $lra_at;
    $age = 0 if $age < 0;
    return ($lra_at, $age);
}

# TokenInfo::status($creds, $mtime, $now) -> \%info.
# PUBLIC, pure, total. See spec S2.1 for the full contract; S3 B1-B12 pin
# every edge case.
sub status {
    my ($creds, $mtime, $now) = @_;

    my $oauth = (ref $creds eq 'HASH') ? $creds->{claudeAiOauth} : undef;
    $oauth = undef unless ref $oauth eq 'HASH';

    my ($last_refreshed_at, $last_refreshed_age) = _refreshed_fields($mtime, $now);

    if (!defined $oauth) {
        return _not_logged_in_struct($mtime, $now);
    }

    my $access_tok = $oauth->{accessToken};
    my $access_present = (defined $access_tok && length $access_tok) ? 1 : 0;

    my $n = _num($now);

    my ($access_state, $access_expires_at, $access_seconds_left);
    if (!$access_present) {
        $access_state        = 'absent';
        $access_expires_at   = undef;
        $access_seconds_left = undef;
    } else {
        my $exp_raw = _uint($oauth->{expiresAt});
        if (!defined $exp_raw) {
            $access_state        = 'absent';
            $access_expires_at   = undef;
            $access_seconds_left = undef;
        } else {
            $access_expires_at = int($exp_raw / 1000);
            if (defined $n) {
                $access_seconds_left = $access_expires_at - $n;
                $access_state = ($access_seconds_left > 0) ? 'valid' : 'expired';
            } else {
                $access_seconds_left = undef;
                $access_state        = 'absent';
            }
        }
    }

    my $refresh_tok     = $oauth->{refreshToken};
    my $refresh_present = (defined $refresh_tok && length $refresh_tok) ? 1 : 0;
    my $refresh_fingerprint = $refresh_present ? fingerprint($refresh_tok) : undef;

    my $logged_in = ($access_present || $refresh_present) ? 1 : 0;

    my %info = (
        logged_in            => $logged_in,
        access_present       => $access_present,
        access_state         => $access_state,
        access_expires_at    => $access_expires_at,
        access_seconds_left  => $access_seconds_left,
        refresh_present      => $refresh_present,
        refresh_fingerprint  => $refresh_fingerprint,
        refresh_expires      => 'n/a (not stored)',
        last_refreshed_at    => $last_refreshed_at,
        last_refreshed_age   => $last_refreshed_age,
    );

    for my $pair ( [ subscriptionType => 'subscription_type' ], [ rateLimitTier => 'rate_limit_tier' ] ) {
        my ($src, $dst) = @$pair;
        my $v = $oauth->{$src};
        $info{$dst} = $v if defined $v && !ref $v && length $v;
    }

    return \%info;
}

1;
