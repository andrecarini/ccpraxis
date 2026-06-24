#!/usr/bin/env perl
# BpHttp::parse_response — the curl-output status/body splitter (pure). The curl
# transport appends "\n%{http_code}" so the trailing line is the 3-digit status;
# this asserts that split across the cases the orchestrator/keeper rely on.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;

require "$Bin/../../scripts/bp-http.pl";

plan tests => 11;

{ my ($s,$c) = BpHttp::parse_response(qq({"ok":1}\n200));
  is($s, 200, '200 status parsed off the end');
  is($c, '{"ok":1}', 'body recovered without the status line'); }

{ my ($s,$c) = BpHttp::parse_response(qq({"error":{"type":"rate_limit_error"}}\n429));
  is($s, 429, '429 parsed');
  like($c, qr/rate_limit_error/, '429 body intact'); }

{ my ($s,$c) = BpHttp::parse_response(qq({\n  "a": 1\n}\n200));
  is($s, 200, 'multiline (pretty-JSON) body: status still parsed');
  is($c, qq({\n  "a": 1\n}), 'multiline body preserved (only the trailing code stripped)'); }

{ my ($s) = BpHttp::parse_response(qq(\n000));
  is($s, 0, 'curl 000 (connection/TLS failure) -> status 0'); }

{ my ($s) = BpHttp::parse_response('');
  is($s, 0, 'empty output -> status 0'); }

{ my ($s) = BpHttp::parse_response(undef);
  is($s, 0, 'undef output -> status 0'); }

{ my ($s,$c) = BpHttp::parse_response("body\n200\r");
  is($s, 200, 'trailing CR after the code tolerated');
  is($c, 'body', 'CR-trailed status still split cleanly'); }
