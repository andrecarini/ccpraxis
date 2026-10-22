#!/usr/bin/env perl
# platform: any
# Bug 20261022-152805-0f35: Almanac::Inbox::list_items decodes frontmatter, so
# an inbox item's link reaches the orchestrator utf8-flagged even when it is
# pure ASCII. Joined onto a raw-byte runs path under a non-ASCII root
# ("Andre" with an e-acute, as on this machine), perl upgraded the path as
# Latin-1 and -f stat'ed a double-encoded name: a live escalation read as
# 'gone' and its inbox item was closed as an orphan.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

my $ORCH = "$Bin/../../scripts/bp-orchestrator.pl";
require $ORCH;

my $base = tempdir(CLEANUP => 1);
$base =~ s{\\}{/}g;
my $runs = "$base/Andr\xc3\xa9/blueprints/escbp/runs";   # raw bytes, flag off
make_path("$runs/escalations") or die "fixture: $!";
open(my $fh, '>', "$runs/escalations/esc001.json") or die "fixture: $!";
print {$fh} '{"package":"p1","category":"scoping"}';
close $fh;
ok(-f "$runs/escalations/esc001.json", 'precondition: the escalation file exists under the non-ASCII root');

# What list_items hands back: decoded, flag on, ASCII content.
my $link = 'escbp/p1/esc001';
utf8::upgrade($link);
ok(utf8::is_utf8($link), 'precondition: the link carries the utf8 flag');

my $r = BpOrch::inbox_resolve_link($runs, 'escbp', $link);
is($r->{state}, 'found', 'a flagged link resolves to the escalation under a non-ASCII root');
is($r->{id}, 'esc001', 'and names the right escalation id');

my $plain = 'escbp/p1/esc001';
is(BpOrch::inbox_resolve_link($runs, 'escbp', $plain)->{state}, 'found', 'an unflagged link still resolves');

is(BpOrch::inbox_resolve_link($runs, 'escbp', 'escbp/p1/esc404')->{state}, 'gone',
    'a link to a missing escalation is still gone');

# The archive lookup behind the orphan-close reason builds a path the same way.
make_path("$runs/resolved-escalations") or die "fixture: $!";
open(my $ah, '>', "$runs/resolved-escalations/esc002.json") or die "fixture: $!";
print {$ah} '{"original":{"package":"p1"},"resolved_by":"auto-settle","reason":"settled by test"}';
close $ah;
my $gone = 'escbp/p1/esc002';
utf8::upgrade($gone);
unlike(BpOrch::_orphan_close_reason($runs, $gone), qr/no longer exists/,
    'the orphan-close reason finds the archived record under a non-ASCII root');

done_testing();
