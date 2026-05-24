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

# ── Plans & Todos ────────────────────────────────────────────
my $plans_str = '';
eval {
    # Plans: non-archived .claude-plans/*.md (per-project)
    my $root = `git -C "$workspace" rev-parse --show-toplevel 2>/dev/null`;
    chomp $root;
    $root = $workspace unless $root;
    my @parts;
    if ($root && -d "$root/.claude-plans") {
        opendir(my $dh, "$root/.claude-plans") or die;
        my $n = grep { /\.md$/ && -f "$root/.claude-plans/$_" } readdir($dh);
        closedir($dh);
        push @parts, "${DIM}\x{25C7}\x{200A}${R}${n}" if $n > 0;
    }

    # Todos: non-archived ~/.claude/claude-code-vault/todos/*.md (global)
    my $todo_dir = "$ENV{HOME}/.claude/claude-code-vault/todos";
    if (-d $todo_dir) {
        opendir(my $dh, $todo_dir) or die;
        my $n = grep { /\.md$/ && !/^README\.md$/ && -f "$todo_dir/$_" } readdir($dh);
        closedir($dh);
        push @parts, "${DIM}\x{25A2}\x{200A}${R}${n}" if $n > 0;
    }

    $plans_str = join(' ', @parts) if @parts;
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
