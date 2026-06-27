#!/usr/bin/env perl
# Pins the launcher's post-refactor mount layout: /root/.claude is a
# host bind of <project>/.ccpraxis-local-data/claude-home ($CLAUDE_DATA),
# not a volume. /root/.claude.json is a single-file bind. statusline.pl is
# the only ro bind remaining inside /root/.claude/. No CLAUDE_DATA_VOLUME
# references survive.

use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;

plan tests => 9;

my $launcher = "$Bin/../../scripts/launcher.pl";
ok(-f $launcher, 'launcher.pl present') or BAIL_OUT;

open my $fh, '<', $launcher or BAIL_OUT("open: $!");
my $src = do { local $/; <$fh> };
close $fh;

# 1. /root/.claude is bound from ${CLAUDE_DATA} (.ccpraxis-local-data/claude-home).
like($src, qr{'-v',\s*"\$\{CLAUDE_DATA\}:/root/\.claude"}m,
     '/root/.claude is a host bind mount of claude-home');

# 2. .launcher overlays the claude-home bind as RO. Defense-in-depth:
# a compromised in-container process can't fake backpack-trusted-hash,
# corrupt the snapshot files, or scribble on launcher metadata.
like($src, qr{'-v',\s*"\$\{LAUNCHER_DIR\}:/root/\.claude/\.launcher:ro"}m,
     '.launcher is overlaid as RO over /root/.claude/.launcher');

# 3. .credentials.json is NO LONGER a single-file bind (Fix 1). It lives at
# claude-home/.credentials.json and rides the ${CLAUDE_DATA} dir bind as a
# real file, so atomic temp+rename writes (how Claude Code / butler persist
# an OAuth refresh) succeed — a single-file bind rejected rename-over-mount
# (EBUSY) and the refreshed token could never be saved.
like($src, qr{\$SANDBOX_CREDENTIALS_FILE\s*=\s*"\$CLAUDE_DATA/\.credentials\.json"}m,
     'sandbox creds path is claude-home/.credentials.json (rides the RW dir bind)');
unlike($src, qr{:/root/\.claude/\.credentials\.json"}m,
       'no single-file bind onto /root/.claude/.credentials.json (rename-safe dir bind instead)');

# 4. /root/.claude.json is a single-file bind from claude-home/.claude.json.
like($src, qr{'-v',\s*"\$\{CLAUDE_DATA\}/\.claude\.json:/root/\.claude\.json"}m,
     '/root/.claude.json is a single-file bind from claude-home/.claude.json');

# 5. statusline.pl ro bind is still there.
like($src, qr{statusline\.pl:/root/\.claude/statusline\.pl:ro}m,
     'statusline.pl ro bind survives');

# 6. No CLAUDE_DATA_VOLUME variable or function references survive.
unlike($src, qr/CLAUDE_DATA_VOLUME/,
       'no CLAUDE_DATA_VOLUME references remain');

# 7. No volume-management helpers survive.
unlike($src, qr/ensure_claude_data_volume|seed_claude_data_volume|rescue_volume_to_host|sync_claude_data_volume|apply_blueprints_to_volume/,
       'volume helpers (ensure/seed/rescue/sync/apply_to_volume) are gone');
