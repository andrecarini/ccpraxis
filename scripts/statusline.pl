#!/usr/bin/perl
# Claude Code status line — Perl core modules only, no external deps.
# Shows: project | model | context usage | plan rate limits
use strict;
use warnings;
use JSON::PP;
use Time::Piece;
use File::Basename;

binmode STDOUT, ':utf8';

my $raw  = do { local $/; <STDIN> };
my $data = decode_json($raw);


# ── Colors (24-bit RGB) ─────────────────────────────────────
sub rgb { "\033[38;2;$_[0];$_[1];$_[2]m" }

my $R        = "\033[0m";
my $B        = "\033[1m";
my $D        = "\033[2m";
my $PROJECT  = rgb(59,  130, 246);  # Accent blue
my $MODEL    = rgb(148, 163, 184);  # Slate gray
my $BAR_USED = rgb(99,  102, 241);  # Indigo
my $CTX_OK   = rgb(16,  185, 129);  # Green
my $CTX_WARN = rgb(245, 158, 11);   # Amber
my $CTX_CRIT = rgb(239, 68,  68);   # Red
my $DIM      = rgb(100, 116, 139);  # Muted slate
my $VDIM     = rgb(60,  70,  85);   # Very dim
my $SEP      = " ${VDIM}\x{FF5C}${R} ";

# ── Model ────────────────────────────────────────────────────
my $display  = $data->{model}{display_name} // '';
my $model_id = $data->{model}{id} // '?';
my $short    = $display || $model_id;
$short =~ s/^Claude //;
$short =~ s/\s*\(\d+[kKmM]\s*context\)//;

# ── Project ──────────────────────────────────────────────────
my $workspace = $data->{workspace}{current_dir} // '';
my $project   = $workspace ? basename($workspace) : '?';

# ── Git (with background fetch every 30 min) ────────────────
my $git_str = '';
eval {
    my $branch = `git -C "$workspace" rev-parse --abbrev-ref HEAD 2>/dev/null`;
    chomp $branch;
    if ($branch) {
        # Fetch remote if stale (>30 min since last fetch)
        my $fetch_stamp = "$workspace/.git/FETCH_HEAD";
        my $stale = 1;
        if (-f $fetch_stamp) {
            $stale = (time() - (stat($fetch_stamp))[9]) > 1800;
        }
        if ($stale) {
            # Fire-and-forget background fetch (no blocking)
            system("git -C \"$workspace\" fetch --quiet >/dev/null 2>&1 &");
        }

        my $ahead  = `git -C "$workspace" rev-list --count \@{upstream}..HEAD 2>/dev/null`; chomp $ahead;
        my $behind = `git -C "$workspace" rev-list --count HEAD..\@{upstream} 2>/dev/null`; chomp $behind;
        $ahead  = 0 unless $ahead  =~ /^\d+$/;
        $behind = 0 unless $behind =~ /^\d+$/;

        $git_str = "${DIM}\x{2325}\x{200A}${branch}${R}";
        $git_str .= " ${CTX_OK}\x{2191}${ahead}${R}"  if $ahead  > 0;
        $git_str .= " ${CTX_WARN}\x{2193}${behind}${R}" if $behind > 0;
    }
};

# ── Plans, Todos & Beacons ───────────────────────────────────
my $plans_str = '';
eval {
    # Project root: git toplevel, falling back to workspace. Decode UTF-8
    # bytes (from git's stdout) to a Unicode string so beacon git_root
    # comparisons below (which see JSON-decoded Unicode) match correctly.
    my $root = `git -C "$workspace" rev-parse --show-toplevel 2>/dev/null`;
    chomp $root;
    $root = $workspace unless $root;
    utf8::decode($root) if defined $root && length $root && !utf8::is_utf8($root);

    my @parts;

    # Plans: non-archived .claude-plans/*.md (per-project)
    if ($root && -d "$root/.claude-plans") {
        opendir(my $dh, "$root/.claude-plans") or die;
        my $n = grep { /\.md$/ && -f "$root/.claude-plans/$_" } readdir($dh);
        closedir($dh);
        push @parts, "${DIM}plans ${R}${n}" if $n > 0;
    }

    # Todos: non-archived ~/.claude/claude-code-vault/todos/*.md (global)
    my $todo_dir = "$ENV{HOME}/.claude/claude-code-vault/todos";
    if (-d $todo_dir) {
        opendir(my $dh, $todo_dir) or die;
        my $n = grep { /\.md$/ && !/^README\.md$/ && -f "$todo_dir/$_" } readdir($dh);
        closedir($dh);
        push @parts, "${DIM}todos ${R}${n}" if $n > 0;
    }

    # Beacons: project = local .claude-data/beacons + vault beacons whose
    # git_root matches $root. Global = cached count file, falling back to
    # a vault-dir filename walk when the cache hasn't been written yet.
    # Rendered as a single segment: ◉ <project> <global-dim>.
    my $vault_bdir = "$ENV{HOME}/.claude/claude-code-vault/beacons";
    my $n_project  = 0;
    if ($root) {
        my $local_bdir = "$root/.claude-data/beacons";
        if (-d $local_bdir && opendir(my $dh, $local_bdir)) {
            $n_project += grep { /\.json$/ && !/^\./ } readdir($dh);
            closedir($dh);
        }
        if (-d $vault_bdir && opendir(my $dh, $vault_bdir)) {
            my @files = grep { /\.json$/ && !/^\./ } readdir($dh);
            closedir($dh);
            for my $f (@files) {
                open(my $fh, '<:raw', "$vault_bdir/$f") or next;
                my $json_raw = do { local $/; <$fh> };
                close $fh;
                my $rec = eval { decode_json($json_raw) };
                next unless $rec && ref($rec) eq 'HASH';
                $n_project++ if defined $rec->{git_root} && $rec->{git_root} eq $root;
            }
        }
    }

    my $n_global = 0;
    my $gcount   = "$vault_bdir/.global-count";
    my $cache_stale = 1;  # true on missing / unreadable; refined below if read OK
    if (-f $gcount && open(my $fh, '<', $gcount)) {
        my $n = <$fh>;
        close $fh;
        chomp $n if defined $n;
        $n_global = (defined $n && $n =~ /^\d+$/) ? $n + 0 : 0;
        my $age = time() - (stat($gcount))[9];
        $cache_stale = $age > 30;
    } elsif (-d $vault_bdir && opendir(my $dh, $vault_bdir)) {
        $n_global = grep { /\.json$/ && !/^\./ } readdir($dh);
        closedir($dh);
    }

    # Debounced async refresh — fire beacon.pl sync-vault in background when
    # the cache is stale or missing. Two-tier debounce: a .sync-vault.last-fired
    # sentinel limits spawn rate to ~1 every 5s regardless of render rate,
    # then LOCK_NB inside sync-vault dedupes any spawns that still overlap.
    # The sentinel matters because this runs every keystroke; without it,
    # a 30s stale window would fire ~300 shell+perl startups on Windows,
    # each of which the statusline parent waits on for a few ms.
    #
    # NB: beacon.pl lives in the `beacon` plugin since D7. statusline.pl is
    # host-only and runs outside any skill context, so we compute the on-disk
    # path directly (no ${CLAUDE_PLUGIN_ROOT} substitution available here).
    if ($cache_stale && -d $vault_bdir) {
        my $beacon_script = "$ENV{HOME}/.claude/ccpraxis/plugins/beacon/scripts/beacon.pl";
        my $fired_stamp   = "$vault_bdir/.sync-vault.last-fired";
        my $spawn_stale   = 1;
        if (-f $fired_stamp) {
            $spawn_stale = (time() - (stat($fired_stamp))[9]) > 5;
        }
        if ($spawn_stale && -f $beacon_script) {
            # Touch sentinel BEFORE spawning so concurrent renders skip.
            # Race-tolerant: a few extra spawns won't hurt (LOCK_NB catches
            # them), but the sentinel must move forward or we'd fire forever.
            if (open(my $ts, '>>', $fired_stamp)) { close $ts; }
            utime(undef, undef, $fired_stamp);
            system("perl \"$beacon_script\" sync-vault >/dev/null 2>&1 &");
        }
    }

    if ($n_project > 0 || $n_global > 0) {
        my $s = "${DIM}beacons ${R}";
        if ($n_project > 0 && $n_global > 0) {
            # `<proj> / <vdim global>` — project bright; slash and global
            # count both very-dim so they recede as one unit. Spaces give
            # visual breathing room.
            $s .= "${n_project} ${VDIM}/ ${n_global}${R}";
        } elsif ($n_project > 0) {
            $s .= "${n_project}";
        } else {
            # Only global beacons (none in this project) — render as 0 / N so
            # the asymmetry is explicit and the bare number isn't misread
            # as a project count.
            $s .= "0 ${VDIM}/ ${n_global}${R}";
        }
        push @parts, $s;
    }

    # Double space between segments groups them as distinct categories.
    $plans_str = join('  ', @parts) if @parts;
};

# ── Context window ───────────────────────────────────────────
my $cw   = $data->{context_window} // {};
my $pct  = $cw->{used_percentage}    // 0;
my $size = $cw->{context_window_size} // 0;

sub fmt {
    my $n = shift;
    my $m = $n / 1_000_000;
    return sprintf("%dM", $m) if $m == int($m);
    return sprintf("%.1fM", $m) if $n >= 1_000_000;
    return sprintf("%.0fk", $n / 1_000)     if $n >= 1_000;
    return "$n";
}

my $pct_i       = int($pct + 0.5);
my $pc          = $pct_i >= 90 ? $CTX_CRIT : $pct_i >= 67 ? $CTX_WARN : $CTX_OK;
my $used_tokens = int($size * $pct / 100 + 0.5);
my $free_tokens = $size - $used_tokens;

# ── Plan usage ──────────────────────────────────────────────
sub usage_color {
    my $p = shift;
    return $p >= 80 ? $CTX_CRIT : $p >= 50 ? $CTX_WARN : $CTX_OK;
}

sub time_until {
    my ($val, $style) = @_;
    return '' unless defined $val && length($val);
    $style //= 'short';  # 'hm' = always XhYYm, 'short' = Xd Yh or Xh
    my $result = eval {
        my $secs;
        if ($val =~ /^\d+(\.\d+)?$/) {
            # Unix epoch (from stdin rate_limits)
            $secs = int($val) - time();
        } else {
            # ISO timestamp
            $val =~ s/Z$/+00:00/;
            $val =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})/ or return '';
            my $reset = Time::Piece->strptime("$1-$2-$3 $4:$5:$6", "%Y-%m-%d %H:%M:%S");
            $secs = $reset->epoch - gmtime()->epoch;
        }
        $secs = 0 if $secs < 0;
        my $days  = int($secs / 86400);
        my $hours = int(($secs % 86400) / 3600);
        my $mins  = int(($secs % 3600) / 60);
        if ($style eq 'hm') {
            sprintf("%dh\x{200A}%02dm", $hours + $days * 24, $mins);
        } elsif ($days > 0) {
            "${days}d\x{200A}${hours}h";
        } elsif ($hours > 0) {
            "${hours}h";
        } elsif ($mins > 0) {
            "${mins}m";
        } else {
            "${secs}s";
        }
    };
    return $result // '';
}

# ── Plan usage (from stdin JSON, native since v2.1.80) ──────
my ($plan_full, $plan_short) = ('', '');
my $rl = $data->{rate_limits};
if ($rl) {
    my $h5     = $rl->{five_hour} // {};
    my $d7     = $rl->{seven_day} // {};
    my $h5_pct = int(($h5->{used_percentage} // 0) + 0.5);
    my $d7_pct = int(($d7->{used_percentage} // 0) + 0.5);

    my $h5_reset = time_until($h5->{resets_at}, 'hm');
    my $d7_reset = time_until($d7->{resets_at});
    my $h5_r     = $h5_reset ? "${VDIM}\x{FF5C}${h5_reset}\x{FF5C}${R}" : '';
    my $d7_r     = $d7_reset ? "${VDIM}\x{FF5C}${d7_reset}\x{FF5C}${R}" : '';

    $plan_full  = "${DIM}5h ${R}" . usage_color($h5_pct) . "${h5_pct}%${R}${h5_r}"
                . "\x{3000}${DIM}7d ${R}" . usage_color($d7_pct) . "${d7_pct}%${R}${d7_r}";
    $plan_short = "${DIM}5h ${R}" . usage_color($h5_pct) . "${h5_pct}%${R}"
                . "\x{3000}${DIM}7d ${R}" . usage_color($d7_pct) . "${d7_pct}%${R}";
}

# ── Output (single line if it fits, wrap if not) ─────────────
sub vlen { my $s = shift; $s =~ s/\033\[[^m]*m//g; length($s) }

my $cols = `tput cols 2>/dev/null`; chomp $cols; $cols ||= 120;

my $line1 = "${PROJECT}${B}${project}${R}";
$line1 .= "${SEP}${git_str}" if $git_str;
$line1 .= "${SEP}${plans_str}" if $plans_str;

my $line2 = "${MODEL}${short}${R} "
          . "${DIM}" . fmt($size) . "${R}\x{3000}"
          . "${pc}${pct_i}%${R} "
          . "${VDIM}\x{FF5C}${R}${BAR_USED}" . fmt($used_tokens) . "${R} "
          . "${CTX_OK}" . fmt($free_tokens) . "${R}${VDIM}\x{FF5C}${R}";

if ($plan_full) {
    my $oneline2 = "${line2} ${plan_full}";
    if (vlen($oneline2) <= $cols) {
        print "${line1}\n${oneline2}";
    } else {
        print "${line1}\n${line2}\n${plan_full}";
    }
} else {
    print "${line1}\n${line2}";
}
