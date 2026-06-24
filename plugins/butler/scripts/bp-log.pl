#!/usr/bin/env perl
# bp-log.pl — structured, line-flushed, crash-safe run logger (Decision #30).
#
# Every token-keeper / usage-poll / preflight / contract-drift / pause-resume
# action the orchestrator takes is written here as one JSON line, so an
# unattended run is auditable after the fact and the dashboard can render it
# live. Crash-safe: each event is an open(append) + print + close, so killing
# the orchestrator leaves a readable log up to the last completed event.
#
# SECURITY: never log secret values. redact() masks any value that looks like a
# token (sk-...) and any field whose key names a credential.
#
# require:  require "<path>/bp-log.pl"; BpLog::event($logpath, 'token_refresh', { result=>'200', expiresAt=>... });

package BpLog;
use strict;
use warnings;
use JSON::PP;

sub _iso_now {
    my @t = gmtime(defined $_[0] ? $_[0] : time);
    sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ", $t[5]+1900,$t[4]+1,$t[3],$t[2],$t[1],$t[0];
}

# Mask anything secret. Recurses through hashes/arrays. Returns a redacted COPY.
sub redact {
    my ($v) = @_;
    if (ref $v eq 'HASH') {
        my %out;
        for my $k (keys %$v) {
            if ($k =~ /token|secret|credential|access_?token|refresh_?token|authorization/i) {
                $out{$k} = '<redacted>';
            } else { $out{$k} = redact($v->{$k}); }
        }
        return \%out;
    }
    if (ref $v eq 'ARRAY') { return [ map { redact($_) } @$v ]; }
    if (defined $v && !ref $v && $v =~ /sk-[A-Za-z0-9_-]{20,}/) { return '<redacted>'; }
    return $v;
}

# event($path, $type, \%fields [, $epoch]) -> the JSON line written (without newline).
sub event {
    my ($path, $type, $fields, $epoch) = @_;
    $fields ||= {};
    my $rec = { ts => _iso_now($epoch), type => $type, %{ redact($fields) } };
    my $line = JSON::PP->new->canonical->encode($rec);

    # ensure parent dir exists
    (my $dir = $path) =~ s{[/\\][^/\\]+$}{};
    if (length $dir && !-d $dir) { require File::Path; File::Path::make_path($dir); }

    open my $fh, '>>', $path or die "bp-log: open $path: $!";
    print $fh $line, "\n" or die "bp-log: write: $!";
    close $fh or die "bp-log: close: $!";
    return $line;
}

package main;
1;
