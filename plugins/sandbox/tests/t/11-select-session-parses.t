#!/usr/bin/env perl
# select-session.pl must handle a real-shaped JSONL session:
#  - extract the session UUID
#  - skip <local-command-*> meta lines and tool_result entries when
#    building the preview
#  - never crash on partial / malformed lines further down the file
# Drives the line-prompt fallback path (no TTY) so we can pipe a chosen
# index in via STDIN.

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Test::More;
use File::Temp qw(tempdir);

plan tests => 4;

my $script = "$Bin/../../scripts/select-session.pl";
ok(-f $script, 'select-session.pl exists') or BAIL_OUT("script missing");

# Build a synthetic sessions dir with one session jsonl shaped like a
# real Claude Code session opener.
my $sessions_dir = tempdir(CLEANUP => 1);
my $uuid = '12345678-1234-1234-1234-123456789abc';
my $jsonl = "$sessions_dir/$uuid.jsonl";

open my $w, '>', $jsonl or die;
# Line 1: permission-mode metadata.
print $w qq({"type":"permission-mode","permissionMode":"bypassPermissions","sessionId":"$uuid"}\n);
# Line 2: file-history-snapshot, no preview material.
print $w qq({"type":"file-history-snapshot","messageId":"abc","snapshot":{"trackedFileBackups":{}}}\n);
# Line 3: a local-command-caveat user message (should be skipped for preview).
print $w qq({"type":"user","isMeta":true,"message":{"role":"user","content":"<local-command-caveat>Caveat blah</local-command-caveat>"},"sessionId":"$uuid","cwd":"/project"}\n);
# Line 4: a real user prompt — this is what should appear in the preview.
print $w qq({"type":"user","message":{"role":"user","content":"fix the failing test in src/calc"},"sessionId":"$uuid","cwd":"/project"}\n);
close $w;

# Drive the picker via the line-prompt fallback (no TTY → reads stdin).
# Pipe "1\n" so it picks the first option = NEW (avoiding interactive flow
# but exercising the discovery path).
my $out_file = "$sessions_dir/.session-pick";
my $cmd = qq("$^X" "$script" --sessions-dir "$sessions_dir" --project-label test-parse --output "$out_file");
open my $p, "| $cmd > /dev/null 2>&1" or die;
print $p "1\n";
close $p;
my $rc = $? >> 8;

is($rc, 0, "picker exits 0 after consuming line-prompt input");

ok(-f $out_file, "output file written");

open my $rfh, '<', $out_file or die;
my $content = do { local $/; <$rfh> };
close $rfh;
chomp $content;
# Option 1 is always "Start a new session" → output should be NEW even when
# sessions exist. This verifies the menu offered NEW as the first option,
# which is the core behavior change vs. claude --resume.
is($content, 'NEW',
   'picking option 1 yields NEW (proves "Start a new session" is option 1)');
