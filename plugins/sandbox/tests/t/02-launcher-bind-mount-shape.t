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

plan tests => 18;

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

# --- Fix 2: two-tier plugin store (COPY model — host plugins copied in, never mounted) ---

# 8. installed_plugins.json is a REAL RW file under claude-home/plugins/ (Fix 2),
# no longer a single-file RO bind — Claude Code rewrites it on in-container install.
like($src, qr{\$MATERIALIZED_PLUGINS_FILE\s*=\s*"\$CLAUDE_DATA/plugins/installed_plugins\.json"}m,
     'installed_plugins.json materializes to claude-home/plugins/ (real RW file)');
unlike($src, qr{:/root/\.claude/plugins/installed_plugins\.json:ro},
       'no single-file RO bind onto installed_plugins.json');

# 9. The host plugin dirs are COPIED in, NOT mounted: no cache/ mount and no
# blanket marketplaces/ mount (the host is never mounted into the container).
unlike($src, qr{\$HOST_PLUGINS_DIR/cache:/root/\.claude/plugins/cache}m,
       'plugins/cache is NOT mounted (copied into claude-home instead)');
unlike($src, qr{\$HOST_PLUGINS_DIR/marketplaces:/root/\.claude/plugins/marketplaces:}m,
       'no blanket plugins/marketplaces mount (copied into claude-home instead)');

# 10. No overlay (`:O`) mounts anywhere, and the overlay/volume helper is gone.
unlike($src, qr{:O,upperdir=}, 'no :O overlay mounts remain');
unlike($src, qr/ensure_plugin_overlay/, 'ensure_plugin_overlay helper is gone (no volume)');

# 11. The copy model: sync_copy_plan reconcile + the copy-plan manifests.
like($src, qr/sub sync_copy_plan/m,
     'sync_copy_plan reconcile helper present (copy model)');
like($src, qr/\$PLUGINS_COPY_MANIFEST\s*=\s*"\$LAUNCHER_DIR/m,
     'plugins copy-plan manifest lives in .launcher/ (RO in container — control protected)');

# 12. Directory-source marketplaces (ccpraxis-local) stay a LIVE read-only bind.
like($src, qr{\$\{host_path\}:\$\{container_path\}:ro}m,
     'directory-source marketplaces keep their live read-only bind');
