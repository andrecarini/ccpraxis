#!/usr/bin/env perl
# A3/A8 run logger (bp-log.pl, Decision #30): structured JSON lines, secrets
# redacted, crash-safe append.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);

require "$Bin/../../scripts/bp-log.pl";

plan tests => 12;

my $dir = tempdir(CLEANUP => 1);
my $log = "$dir/sub/orchestrator.log";   # nested path: must be created

# ---- a basic event --------------------------------------------------------
my $line = BpLog::event($log, 'usage_poll',
    { five_hour => 58, seven_day => 7, next_cadence_s => 825 }, 1782107999);
ok(-f $log, 'log file created (incl. parent dir)');
my $rec = JSON::PP->new->decode($line);
is($rec->{type}, 'usage_poll',                 'type recorded');
is($rec->{ts}, '2026-06-22T05:59:59Z',         'ts is ISO-8601 UTC from epoch');
is($rec->{five_hour}, 58,                      'fields passed through');
is($rec->{next_cadence_s}, 825,                'numeric field preserved');

# ---- secret redaction -----------------------------------------------------
my $l2 = BpLog::event($log, 'token_refresh',
    { result => '200', access_token => 'sk-ant-SECRET-aaaaaaaaaaaaaaaaaaaaaaaa',
      refresh_token => 'sk-ant-SECRET-bbbbbbbbbbbbbbbbbbbb',
      note => 'embedded sk-ant-LEAK-cccccccccccccccccccc here', expiresAt => 1782286577985 });
my $r2 = JSON::PP->new->decode($l2);
is($r2->{access_token},  '<redacted>', 'access_token key redacted');
is($r2->{refresh_token}, '<redacted>', 'refresh_token key redacted');
like($r2->{note}, qr/<redacted>/,      'sk- token embedded in free text redacted');
unlike($l2, qr/SECRET|LEAK/,           'no secret substring survives anywhere in the line');
is($r2->{expiresAt}, 1782286577985,    'non-secret expiresAt kept');

# ---- crash-safe append ----------------------------------------------------
open my $fh, '<', $log or die; my @lines = <$fh>; close $fh;
is(scalar @lines, 2, 'appends (two events = two lines)');
ok((JSON::PP->new->decode($lines[0]) && JSON::PP->new->decode($lines[1])),
   'every line is independently valid JSON');
