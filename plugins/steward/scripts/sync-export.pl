#!/usr/bin/env perl
# sync-export.pl — detect sync status between the live ~/.claude/ config and the
# export repo. Outputs a JSON array describing each file's state; merge decisions
# are left to the AI (backup Step 2/3).
#
# Perl port of the former sync-export.sh (internal helpers are Perl per the
# shell-script policy in references/extending-ccpraxis.md). Behaviour preserved:
# same statuses, same item order, same JSON shape.
#
# Most files are symlinked by install; only repo-owned files are tracked here.
# settings.json is the one file that needs merging (permissions stay machine-local).
use strict;
use warnings;
use JSON::PP;
use File::Spec;
use File::Basename qw(dirname basename);
use File::Compare qw(compare);
use File::Find;

my $home       = $ENV{HOME} // $ENV{USERPROFILE};
my $export_dir = $ENV{CLAUDE_EXPORT_DIR} // "$home/.claude/ccpraxis";
my $claude_dir = "$home/.claude";
my $script_dir = dirname(File::Spec->rel2abs(__FILE__));

# Treat MSWin32/cygwin/msys as Windows (no real symlinks — config is copied).
sub is_windows { return $^O =~ /^(?:MSWin32|cygwin|msys)$/; }

# Run a command with stdout+stderr silenced; return its exit code (so a child's
# JSON/diff output never contaminates our own stdout).
sub run_quiet_exit {
    my @cmd = @_;
    open(my $save_out, '>&', \*STDOUT) or return -1;
    open(my $save_err, '>&', \*STDERR) or return -1;
    open(STDOUT, '>', File::Spec->devnull) or return -1;
    open(STDERR, '>', File::Spec->devnull) or return -1;
    my $rc = system(@cmd);
    open(STDOUT, '>&', $save_out);
    open(STDERR, '>&', $save_err);
    return $rc == -1 ? -1 : ($rc >> 8);
}

# True when json-diff.pl reports the two files differ (exit != 0). Extra flags
# (e.g. --deep-exclude installLocation) go before the two paths.
sub json_diff_changed {
    return run_quiet_exit('perl', "$script_dir/json-diff.pl", @_) != 0;
}

# Recursive content equality (replaces `diff -rq` / `diff -q`), no subprocess so
# nothing leaks to stdout.
sub content_matches {
    my ($a, $b) = @_;
    if (-d $a && -d $b) { return _dirs_equal($a, $b); }
    if (-f $a && -f $b) { return compare($a, $b) == 0; }
    return 0;
}

sub _rel_files {
    my $root = shift;
    my %map;
    find({ no_chdir => 1, wanted => sub {
        return unless -f $_;
        $map{ File::Spec->abs2rel($_, $root) } = $_;
    } }, $root);
    return %map;
}

sub _dirs_equal {
    my ($a, $b) = @_;
    my %fa = _rel_files($a);
    my %fb = _rel_files($b);
    return 0 unless join("\0", sort keys %fa) eq join("\0", sort keys %fb);
    for my $rel (keys %fa) {
        return 0 unless compare($fa{$rel}, $fb{$rel}) == 0;
    }
    return 1;
}

sub check_symlink {
    my $name = shift;
    my $link = "$claude_dir/$name";
    my $target = $name eq 'CLAUDE.md'
        ? "$export_dir/global-config/CLAUDE.md"
        : "$export_dir/$name";

    if (-l $link) {
        return { file => $name, status => 'linked' };
    } elsif (-e $link) {
        if (is_windows()) {
            return content_matches($link, $target)
                ? { file => $name, status => 'linked',     note => 'copy matches repo' }
                : { file => $name, status => 'not_linked', note => 'copy differs from repo' };
        }
        return { file => $name, status => 'not_linked', note => 'exists but should be symlink' };
    }
    return { file => $name, status => 'missing', note => 'missing from ~/.claude/' };
}

sub check_repo_file {
    my $name = shift;
    return -f "$export_dir/$name"
        ? { file => $name, status => 'tracked' }
        : { file => $name, status => 'missing', note => 'missing from repo' };
}

# Discover skills dynamically.
sub skill_names {
    my @names;
    for my $dir (glob("'$export_dir'/skills/*/")) {
        next unless -d $dir;
        $dir =~ s{/$}{};
        push @names, basename($dir);
    }
    return sort @names;
}

my @repo_files = qw(
    global-config/CLAUDE.md
    global-config/settings.json
);
my @script_files = qw(
    scripts/statusline.pl
    plugins/steward/scripts/json-diff.pl
    plugins/steward/scripts/filter-diff.pl
    plugins/steward/scripts/save-preference.pl
    plugins/steward/scripts/check-plugins.pl
    plugins/steward/scripts/sync-export.pl
    plugins/steward/scripts/sensitive-check.pl
    plugins/steward/scripts/vault-sync.pl
    plugins/steward/scripts/onboard.pl
    plugins/steward/scripts/ccpraxis-helpers.pl
    plugins/steward/scripts/claude-binary-backup.pl
);
my @container_files = qw(
    plugins/sandbox/container/Containerfile
    plugins/sandbox/bin/claude-sandbox.sh
    plugins/sandbox/bin/claude-sandbox.ps1
    plugins/sandbox/container/claude.json
    plugins/sandbox/container/CLAUDE.md
    plugins/sandbox/container/settings.json
);

my @skills      = skill_names();
my @skill_files = map { "skills/$_/SKILL.md" } @skills;

my @results;

# 1. Symlinked items: CLAUDE.md + each skill dir.
push @results, check_symlink('CLAUDE.md');
push @results, check_symlink("skills/$_") for @skills;

# 2. Repo-owned files exist?
push @results, check_repo_file($_)
    for (@repo_files, @script_files, @skill_files, @container_files);

# 3. settings.json — full semantic comparison.
my $settings_live   = "$claude_dir/settings.json";
my $settings_export = "$export_dir/global-config/settings.json";
if (-f $settings_live && -f $settings_export) {
    push @results, {
        file   => 'settings.json',
        status => json_diff_changed($settings_live, $settings_export) ? 'settings_changed' : 'identical',
        note   => 'full semantic comparison',
    };
} elsif (-f $settings_live) {
    push @results, { file => 'settings.json', status => 'settings_changed', note => 'missing from repo' };
} else {
    push @results, { file => 'settings.json', status => 'settings_changed', note => 'missing from live' };
}

# 4. Container settings — shared-key divergence from global-config.
my $settings_container = "$export_dir/plugins/sandbox/container/settings.json";
if (-f $settings_container && -f $settings_export) {
    push @results, {
        file   => 'plugins/sandbox/container/settings.json',
        status => json_diff_changed($settings_container, $settings_export) ? 'container_settings_diverged' : 'identical',
        note   => 'shared keys vs global-config',
    };
} elsif (-f $settings_container) {
    push @results, {
        file   => 'plugins/sandbox/container/settings.json',
        status => 'tracked',
        note   => 'no global-config to compare',
    };
}

# 5. Marketplace selection — known_marketplaces.json (ignore machine-local installLocation).
my $mp_live   = "$claude_dir/plugins/known_marketplaces.json";
my $mp_export = "$export_dir/global-config/known_marketplaces.json";
if (-f $mp_live && -f $mp_export) {
    push @results, {
        file   => 'known_marketplaces.json',
        status => json_diff_changed('--deep-exclude', 'installLocation', $mp_live, $mp_export) ? 'marketplace_changed' : 'identical',
        note   => 'marketplace selection',
    };
} elsif (-f $mp_live) {
    push @results, { file => 'known_marketplaces.json', status => 'live_only',   note => 'not yet exported to repo' };
} elsif (-f $mp_export) {
    push @results, { file => 'known_marketplaces.json', status => 'export_only', note => 'missing from live' };
} else {
    push @results, { file => 'known_marketplaces.json', status => 'missing',     note => 'no marketplace data' };
}

print JSON::PP->new->utf8->canonical->pretty->encode(\@results);
