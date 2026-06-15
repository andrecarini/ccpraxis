#!/usr/bin/env perl
# Pins the launcher's post-refactor mount layout: /root/.claude is a
# host bind of <project>/.claude-data, not a volume. /root/.claude.json
# is a single-file bind. statusline.pl is the only ro bind remaining
# inside /root/.claude/. No CLAUDE_DATA_VOLUME references survive.

use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;

plan tests => 8;

my $launcher = "$Bin/../../scripts/launcher.pl";
ok(-f $launcher, 'launcher.pl present') or BAIL_OUT;

open my $fh, '<', $launcher or BAIL_OUT("open: $!");
my $src = do { local $/; <$fh> };
close $fh;

# 1. /root/.claude is bound from ${PROJECT_PATH}/.claude-data.
like($src, qr{'-v',\s*"\$\{PROJECT_PATH\}/\.claude-data:/root/\.claude"}m,
     '/root/.claude is a host bind mount of .claude-data');

# 2. .launcher overlays the .claude-data bind as RO. Defense-in-depth:
# a compromised in-container process can't fake backpack-trusted-hash,
# corrupt the snapshot files, or scribble on launcher metadata.
like($src, qr{'-v',\s*"\$\{LAUNCHER_DIR\}:/root/\.claude/\.launcher:ro"}m,
     '.launcher is overlaid as RO over /root/.claude/.launcher');

# 3. credentials.json is a single-file RW bind from $SANDBOX_CREDENTIALS_FILE
# (== $LAUNCHER_DIR/credentials.json). Container DOES need to write here
# (mcpOAuth tokens) — the file bind lets those writes land on the canonical
# host path so they persist across container rebuild.
like($src, qr{'-v',\s*"\$\{SANDBOX_CREDENTIALS_FILE\}:/root/\.claude/\.credentials\.json"}m,
     'credentials.json is a single-file bind from the .launcher/ canonical');

# 4. /root/.claude.json is a single-file bind from .claude-data/.claude.json.
like($src, qr{'-v',\s*"\$\{PROJECT_PATH\}/\.claude-data/\.claude\.json:/root/\.claude\.json"}m,
     '/root/.claude.json is a single-file bind from .claude-data/.claude.json');

# 5. statusline.pl ro bind is still there.
like($src, qr{statusline\.pl:/root/\.claude/statusline\.pl:ro}m,
     'statusline.pl ro bind survives');

# 6. No CLAUDE_DATA_VOLUME variable or function references survive.
unlike($src, qr/CLAUDE_DATA_VOLUME/,
       'no CLAUDE_DATA_VOLUME references remain');

# 7. No volume-management helpers survive.
unlike($src, qr/ensure_claude_data_volume|seed_claude_data_volume|rescue_volume_to_host|sync_claude_data_volume|apply_blueprints_to_volume/,
       'volume helpers (ensure/seed/rescue/sync/apply_to_volume) are gone');
