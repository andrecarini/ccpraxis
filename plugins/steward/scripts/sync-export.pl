#!/usr/bin/env perl
# sync-export.pl — detect sync status between the live ~/.claude/ config and the
# export repo. Outputs a JSON array describing each file's state; merge decisions
# are left to the backup driver (scripts/backup/Export.pm).
#
# Perl port of the former sync-export.sh (internal helpers are Perl per the
# shell-script policy in references/extending-ccpraxis.md).
#
# Two checkouts, two roles (DevClone.pm):
#   --live-root DIR  the live install, what runs: skills are mirrored from it,
#                    ~/.claude/CLAUDE.md is built from its payload, and it is
#                    the directory ${CCPRAXIS_LIVE} stands for. Default
#                    <home>/.claude/ccpraxis.
#   --repo-root DIR  the dev clone, the export target: repo-owned files,
#                    global-config/settings.json, the container settings and
#                    known_marketplaces.json are compared there. Default
#                    $CLAUDE_EXPORT_DIR, else the live install's origin.
# This script only reads.
use strict;
use warnings;
use JSON::PP;
use File::Spec;
use File::Basename qw(dirname basename);
use File::Compare qw(compare);
use File::Find;
use Encode ();
use B ();
use FindBin ();
use lib $FindBin::Bin;
use DevClone ();
use GlobalClaudeMd ();

my $home       = $ENV{HOME} // $ENV{USERPROFILE};
my $claude_dir = "$home/.claude";
my $script_dir = dirname(File::Spec->rel2abs(__FILE__));

my ($live_dir, $export_dir);
while (@ARGV) {
    my $a = shift @ARGV;
    if    ($a eq '--live-root') { $live_dir   = shift @ARGV; }
    elsif ($a eq '--repo-root') { $export_dir = shift @ARGV; }
    else { print STDERR "sync-export.pl: unknown argument: $a\n"; exit 2; }
}
$live_dir //= DevClone::default_live_root($home);
unless (defined $export_dir && length $export_dir) {
    $export_dir = $ENV{CLAUDE_EXPORT_DIR};
}
unless (defined $export_dir && length $export_dir) {
    my $loc = DevClone::locate(live_root => $live_dir, override => $ENV{BACKUP_CLONE_DIR});
    unless (defined $loc->{dev_clone}) {
        print STDERR "sync-export.pl: no dev clone: $loc->{reason}; $loc->{fix}\n";
        exit 2;
    }
    $export_dir = $loc->{dev_clone};
}

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

# A skill directory in ~/.claude/skills should be a link to (Unix) or a copy
# of (Windows) the live install's skill: the skills that run.
sub check_symlink {
    my $name = shift;
    my $link   = "$claude_dir/$name";
    my $target = "$live_dir/$name";

    if (-l $link) {
        return { file => $name, repo_file => $name, status => 'linked' };
    } elsif (-e $link) {
        if (is_windows()) {
            return content_matches($link, $target)
                ? { file => $name, repo_file => $name, status => 'linked',     note => 'copy matches the live install' }
                : { file => $name, repo_file => $name, status => 'not_linked', note => 'copy differs from the live install' };
        }
        return { file => $name, repo_file => $name, status => 'not_linked', note => 'exists but should be symlink' };
    }
    return { file => $name, repo_file => $name, status => 'missing', note => 'missing from ~/.claude/' };
}

# ~/.claude/CLAUDE.md is BUILT by promote.pl from the live install's payload
# (global-config/CLAUDE.md plus this host's part), so it is compared with that
# build (GlobalClaudeMd::compare_installed, shared with check-claude-md). A
# regular file equal to the build is in sync; a link is no longer expected.
# repo_file names the shared payload file -- never the repo-root CLAUDE.md,
# which is ccpraxis's own project-instructions file (bug 20260922-211416-1b92).
sub check_claude_md {
    my $c = GlobalClaudeMd::compare_installed(installed => "$claude_dir/CLAUDE.md", live_root => $live_dir);
    my %r = (file => 'CLAUDE.md', repo_file => GlobalClaudeMd::SHARED_RELPATH, claude_md_status => $c->{status});
    my $st = $c->{status};
    if ($st eq 'in_sync' || $st eq 'linked') {
        $r{status} = 'identical';
        $r{note}   = "matches what promotion builds from the live install's payload";
    } elsif ($st eq 'missing_live') {
        $r{status} = 'missing';
        $r{note}   = 'missing from ~/.claude/';
    } elsif ($st eq 'missing_payload') {
        $r{status} = 'missing';
        $r{note}   = "the live install has no " . GlobalClaudeMd::SHARED_RELPATH;
    } else {
        $r{status}        = 'claude_md_differs';
        $r{note}          = $c->{reason} // ($st eq 'symlinked_elsewhere' ? "a link to $c->{target}" : 'differs');
        $r{host_part}     = $c->{host_part};
        $r{target}        = $c->{target} if defined $c->{target};
        $r{extra_lines}   = $c->{extra_lines};
        $r{missing_lines} = $c->{missing_lines};
        $r{resolve}       = GlobalClaudeMd::fold_hint();
    }
    return \%r;
}

sub check_repo_file {
    my $name = shift;
    return -f "$export_dir/$name"
        ? { file => $name, status => 'tracked' }
        : { file => $name, status => 'missing', note => 'missing from repo' };
}

# Discover skills dynamically, from the live install (the skills that run).
sub skill_names {
    my @names;
    for my $dir (glob("'$live_dir'/skills/*/")) {
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

# 1. Built and mirrored items: CLAUDE.md + each skill dir.
push @results, check_claude_md();
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
        status => json_diff_changed('--host-live', $live_dir, $settings_live, $settings_export) ? 'settings_changed' : 'identical',
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

# Paths (from HOME) and CLAUDE.md lines (read from disk) are raw UTF-8 bytes;
# the ->utf8 encoder below wants characters, or "André" comes out double
# encoded. Numbers keep their type. Same fallback as ccpraxis-helpers.pl's
# _decode_strings_recursive: UTF-8 first, CP1252 for a Windows byte path.
sub _chars {
    my ($x) = @_;
    if (ref $x eq 'HASH')  { return { map { $_ => _chars($x->{$_}) } keys %$x }; }
    if (ref $x eq 'ARRAY') { return [ map { _chars($_) } @$x ]; }
    return $x if ref $x || !defined $x || utf8::is_utf8($x);
    my $fl = B::svref_2object(\$x)->FLAGS;
    return $x if ($fl & (B::SVf_IOK | B::SVf_NOK)) && !($fl & B::SVf_POK);
    my $copy = $x;
    my $d = eval { Encode::decode('UTF-8', $copy, Encode::FB_CROAK) };
    return defined $d ? $d : Encode::decode('cp1252', $x, Encode::FB_DEFAULT);
}

print JSON::PP->new->utf8->canonical->pretty->encode(_chars(\@results));
