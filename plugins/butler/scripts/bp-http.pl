#!/usr/bin/env perl
# bp-http.pl — the orchestrator/keeper HTTPS transport, via curl.
#
# WHY curl and not HTTP::Tiny: the sandbox image's perl has neither
# IO::Socket::SSL nor Net::SSLeay, so HTTP::Tiny CANNOT do HTTPS there — an
# HTTP::Tiny GET/POST to api.anthropic.com / platform.claude.com dies at TLS
# setup inside the sandbox (verified in localhost/claude-sandbox:2.1.170). curl
# is present in both supported envs (OpenSSL on the Linux sandbox, Schannel on
# the win32 host) and trusts the system cert store with no perl SSL module — it
# is exactly the transport A0 proved for the usage GET, and the one the
# `bin.curl` assumption pins. So this is the assumption-aligned transport
# (Decisions #29/#31); using HTTP::Tiny here was a contract mismatch.
#
# request($method,$url,\%headers[,$body]) -> { status => int, content => str }.
# A curl spawn failure / connection failure / TLS failure all surface as
# status 0 (callers treat non-2xx/non-4xx as transient -> backoff / unavailable),
# never a die — the orchestrator must degrade to a graceful pause, never crash.
#
# require:  require "<path>/bp-http.pl"; my $r = BpHttp::request('GET',$url,\%h);

package BpHttp;
use strict;
use warnings;

# parse_response($raw) -> ($status, $content). PURE + unit-tested.
# We append "\n%{http_code}" to curl's output, so the trailing line is the
# 3-digit status; everything before it is the response body (which may itself
# contain newlines). curl emits "000" on a connection/TLS failure.
sub parse_response {
    my ($raw) = @_;
    $raw = '' unless defined $raw;
    my $status = 0;
    if ($raw =~ s/\n(\d{3})[ \t\r]*\z//) { $status = $1 + 0; }
    return ($status, $raw);
}

sub _capture {
    my @cmd = @_;
    my $pid = open(my $fh, '-|', @cmd);     # list form: no shell, argv is safe
    return undef unless $pid;               # curl missing / fork failed
    local $/;
    my $out = <$fh>;
    close $fh;
    return defined $out ? $out : '';
}

sub request {
    my ($method, $url, $headers, $body) = @_;
    my @cmd = ('curl', '-sS', '--max-time', ($ENV{BP_HTTP_TIMEOUT} // 30), '-X', uc($method));
    for my $k (sort keys %{ $headers || {} }) {
        push @cmd, '-H', "$k: $headers->{$k}";
    }
    push @cmd, '--data-binary', $body if defined $body;
    push @cmd, '-w', "\n%{http_code}", $url;
    my $out = _capture(@cmd);
    return { status => 0, content => 'curl transport unavailable (curl not found or failed to spawn)' }
        unless defined $out;
    my ($status, $content) = parse_response($out);
    return { status => $status, content => $content };
}

package main;
1;
