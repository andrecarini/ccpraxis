#!/usr/bin/perl
# ccpraxis-helpers.pl — deterministic helper subcommands for /backup.
#
# Replaces several LLM-driven prose steps with scripted ones. Each
# subcommand emits a JSON report; the LLM consumes the JSON and only
# needs to drive AskUserQuestion / commit-message generation.
#
# Subcommands:
#   sync-skills           — Ensure each ccpraxis skill is mirrored to live.
#                           Symlink on Unix, copy on Windows. Emits per-skill
#                           result (linked/copied/unchanged/error).
#   check-claude-md       — Compare live CLAUDE.md with repo's
#                           global-config/CLAUDE.md. Reports linked/equal/
#                           differs/missing.
#   marketplace-diff      — Detect discrepancies between live and repo
#                           known_marketplaces.json. Emits the discrepancies
#                           the LLM needs to resolve.
#   settings-export-merge — Merge live settings.json into the repo's
#                           global-config/settings.json: live wins on shared
#                           keys; keys only in repo are preserved. Writes
#                           result to repo path atomically.
#   help
#
# All output is JSON on stdout. Exit codes:
#   0 = success / nothing to do
#   1 = soft fail (file missing where it should exist, etc.)
#   2 = hard fail (write error, integrity issue)
#   3 = usage error
#
# Self-contained: core Perl modules only.

use strict;
use warnings;
use File::Copy qw(copy);
use File::Path qw(make_path remove_tree);
use File::Spec;
use File::Basename qw(basename dirname);
use JSON::PP;
use Encode qw(decode);

# Output structures mix char strings (decode_json) with raw UTF-8 byte strings
# (paths from %ENV / catfile). Normalize byte strings up to chars before the
# ->utf8 encoder so each is encoded once (else non-ASCII paths double-encode).
sub _decode_strings_recursive {
    my $x = shift;
    if (ref $x eq 'HASH') {
        return { map { $_ => _decode_strings_recursive($x->{$_}) } keys %$x };
    } elsif (ref $x eq 'ARRAY') {
        return [ map { _decode_strings_recursive($_) } @$x ];
    } elsif (ref $x) {
        return $x;
    } elsif (defined $x && !utf8::is_utf8($x)) {
        return $x + 0 if $x =~ /^-?\d+$/;
        return $x + 0 if $x =~ /^-?\d+\.\d+$/;
        my $decoded = eval { decode('UTF-8', $x, Encode::FB_QUIET) };
        return defined $decoded ? $decoded : $x;
    }
    return $x;
}

sub home_dir {
    return $ENV{HOME} if defined $ENV{HOME} && length $ENV{HOME};
    return $ENV{USERPROFILE} if defined $ENV{USERPROFILE} && length $ENV{USERPROFILE};
    my $pw = eval { (getpwuid($<))[7] };
    return $pw if defined $pw;
    die "Cannot determine home directory\n";
}

sub is_windows { return $^O eq 'MSWin32' || $^O eq 'cygwin' || $^O eq 'msys'; }

sub claude_dir   { return File::Spec->catdir(home_dir(), '.claude'); }
sub ccpraxis_dir { return File::Spec->catdir(home_dir(), '.claude', 'ccpraxis'); }

sub emit_json {
    my ($obj) = @_;
    # Normalize mixed char/byte strings up to chars, then ->utf8 to emit UTF-8
    # bytes to byte-mode STDOUT — each string encoded exactly once. (The
    # file-write path above is different: a utf8-off encoder feeds an
    # ':encoding(UTF-8)' handle, which is already correct.)
    my $json = JSON::PP->new->utf8->canonical->pretty;
    print $json->encode(_decode_strings_recursive($obj));
}

sub die_json {
    my ($exit_code, $msg, %extra) = @_;
    emit_json({ status => 'error', error => $msg, %extra });
    exit $exit_code;
}

sub read_json_file {
    my ($path) = @_;
    open my $fh, '<', $path or return (undef, "Cannot open $path: $!");
    local $/;
    my $raw = <$fh>;
    close $fh;
    my $obj = eval { decode_json($raw) };
    return (undef, "Invalid JSON in $path: $@") if $@;
    return ($obj, undef);
}

# Atomic JSON write: write to .tmp then rename.
sub write_json_file_atomic {
    my ($path, $obj) = @_;
    my $tmp = "${path}.tmp.$$";
    open my $fh, '>', $tmp or return "Cannot open $tmp for write: $!";
    binmode $fh, ':encoding(UTF-8)';
    my $json = JSON::PP->new->canonical->pretty;
    print $fh $json->encode($obj);
    close $fh;
    unless (rename($tmp, $path)) {
        my $e = $!;
        unlink $tmp;
        return "Rename failed: $e";
    }
    return undef;
}

sub canonical_json {
    my ($obj) = @_;
    return JSON::PP->new->canonical->encode($obj);
}

# Recursive diff of two file trees. Returns 1 if identical, 0 otherwise.
sub trees_equal {
    my ($a, $b) = @_;
    return 0 unless -e $a && -e $b;
    if (-d $a && -d $b) {
        opendir my $da, $a or return 0;
        my @ea = sort grep { $_ ne '.' && $_ ne '..' } readdir $da;
        closedir $da;
        opendir my $db, $b or return 0;
        my @eb = sort grep { $_ ne '.' && $_ ne '..' } readdir $db;
        closedir $db;
        return 0 unless join("\0", @ea) eq join("\0", @eb);
        for my $name (@ea) {
            return 0 unless trees_equal(
                File::Spec->catfile($a, $name),
                File::Spec->catfile($b, $name),
            );
        }
        return 1;
    }
    if (-f $a && -f $b) {
        my @sa = stat $a;
        my @sb = stat $b;
        return 0 unless @sa && @sb;
        return 0 unless $sa[7] == $sb[7]; # size
        # Byte-compare
        open my $fa, '<', $a or return 0;
        binmode $fa;
        open my $fb, '<', $b or return 0;
        binmode $fb;
        my $bs = 65536;
        while (1) {
            my ($buf_a, $buf_b);
            my $ra = sysread $fa, $buf_a, $bs;
            my $rb = sysread $fb, $buf_b, $bs;
            return 0 unless defined $ra && defined $rb;
            return 0 unless $ra == $rb;
            last if $ra == 0;
            return 0 unless $buf_a eq $buf_b;
        }
        close $fa;
        close $fb;
        return 1;
    }
    return 0;
}

# ─── Subcommand: sync-skills ──────────────────────────────────────────────

sub cmd_sync_skills {
    my $ccpraxis = ccpraxis_dir();
    my $skills_src = File::Spec->catdir($ccpraxis, 'skills');
    my $skills_dst = File::Spec->catdir(claude_dir(), 'skills');

    die_json(1, "Source skills dir does not exist: $skills_src")
        unless -d $skills_src;

    make_path($skills_dst) unless -d $skills_dst;

    opendir my $dh, $skills_src or die_json(2, "Cannot read $skills_src: $!");
    my @names = sort grep { $_ ne '.' && $_ ne '..' } readdir $dh;
    closedir $dh;

    my @results;
    for my $name (@names) {
        my $src = File::Spec->catdir($skills_src, $name);
        next unless -d $src;
        my $dst = File::Spec->catdir($skills_dst, $name);

        my %r = (name => $name, src => $src, dst => $dst);

        if (is_windows()) {
            # Windows path: copy. If already matching, do nothing.
            if (-d $dst && trees_equal($src, $dst)) {
                $r{action} = 'unchanged';
            } else {
                # Remove anything currently at dst (file or dir or symlink-pretender)
                if (-l $dst) {
                    unlink $dst;
                } elsif (-d $dst) {
                    remove_tree($dst);
                } elsif (-e $dst) {
                    unlink $dst;
                }
                # Recursive copy
                my $err = recursive_copy_dir($src, $dst);
                if ($err) {
                    $r{action} = 'error';
                    $r{error} = $err;
                } else {
                    $r{action} = 'copied';
                }
            }
        } else {
            # Unix path: ensure symlink to src. If dst is already a symlink
            # pointing at src, leave it. Otherwise, replace.
            my $needs_replace = 1;
            if (-l $dst) {
                my $target = readlink($dst) // '';
                # Compare resolved paths
                my $target_abs = File::Spec->rel2abs($target, dirname($dst));
                if ($target_abs eq $src) {
                    $needs_replace = 0;
                    $r{action} = 'unchanged';
                }
            }
            if ($needs_replace) {
                if (-e $dst || -l $dst) {
                    if (-l $dst) { unlink $dst; }
                    elsif (-d $dst) { remove_tree($dst); }
                    else { unlink $dst; }
                }
                if (symlink($src, $dst)) {
                    $r{action} = 'linked';
                } else {
                    $r{action} = 'error';
                    $r{error} = "symlink failed: $!";
                }
            }
        }

        push @results, \%r;
    }

    my $any_error = grep { ($_->{action} // '') eq 'error' } @results;
    emit_json({
        status   => $any_error ? 'partial' : 'ok',
        platform => (is_windows() ? 'windows' : 'unix'),
        results  => \@results,
        count    => scalar(@results),
    });
    exit($any_error ? 2 : 0);
}

sub recursive_copy_dir {
    my ($src, $dst) = @_;
    return "source missing: $src" unless -d $src;
    unless (-d $dst) {
        make_path($dst) or return "cannot create $dst: $!";
    }
    opendir my $dh, $src or return "cannot read $src: $!";
    while (defined(my $e = readdir $dh)) {
        next if $e eq '.' || $e eq '..';
        my $sp = File::Spec->catfile($src, $e);
        my $dp = File::Spec->catfile($dst, $e);
        if (-d $sp) {
            my $err = recursive_copy_dir($sp, $dp);
            return $err if $err;
        } elsif (-f $sp) {
            unless (copy($sp, $dp)) {
                return "copy $sp → $dp failed: $!";
            }
        }
        # Skip other file types (devices, sockets) — not expected
    }
    closedir $dh;
    return undef;
}

# ─── Subcommand: check-claude-md ──────────────────────────────────────────

sub cmd_check_claude_md {
    my $live = File::Spec->catfile(claude_dir(), 'CLAUDE.md');
    my $repo = File::Spec->catfile(ccpraxis_dir(), 'global-config', 'CLAUDE.md');

    my %r = (live => $live, repo => $repo);

    if (!-e $repo) {
        $r{status} = 'missing_repo';
        emit_json(\%r);
        exit 1;
    }

    if (!-e $live) {
        $r{status} = 'missing_live';
        emit_json(\%r);
        exit 1;
    }

    if (-l $live) {
        my $target = readlink($live) // '';
        my $target_abs = File::Spec->rel2abs($target, dirname($live));
        if ($target_abs eq $repo) {
            $r{status} = 'linked';
        } else {
            $r{status} = 'symlinked_elsewhere';
            $r{target} = $target_abs;
        }
        emit_json(\%r);
        exit 0;
    }

    if (trees_equal($live, $repo)) {
        $r{status} = 'equal_content';
        emit_json(\%r);
        exit 0;
    }

    $r{status} = 'differs';
    $r{platform} = is_windows() ? 'windows' : 'unix';
    emit_json(\%r);
    exit 0;
}

# ─── Subcommand: marketplace-diff ─────────────────────────────────────────

sub cmd_marketplace_diff {
    my $live = File::Spec->catfile(claude_dir(), 'plugins', 'known_marketplaces.json');
    my $repo = File::Spec->catfile(ccpraxis_dir(), 'global-config', 'known_marketplaces.json');

    my ($live_obj, $live_err) = -f $live ? read_json_file($live) : (undef, "missing: $live");
    my ($repo_obj, $repo_err) = -f $repo ? read_json_file($repo) : (undef, "missing: $repo");

    if ($live_err && $repo_err) {
        die_json(1, "Both marketplace files unavailable", live_error => $live_err, repo_error => $repo_err);
    }

    $live_obj //= {};
    $repo_obj //= {};

    # The known_marketplaces.json shape is generally:
    # {
    #   "marketplaceName": { "source": {...}, "installLocation": "...", ... },
    #   ...
    # }
    # Strip installLocation from each entry before comparing (machine-specific).
    my $strip = sub {
        my $obj = shift;
        my %out;
        for my $name (keys %$obj) {
            my $entry = { %{ $obj->{$name} // {} } };
            delete $entry->{installLocation};
            $out{$name} = $entry;
        }
        return \%out;
    };

    my $live_clean = $strip->($live_obj);
    my $repo_clean = $strip->($repo_obj);

    my %all;
    $all{$_} = 1 for keys %$live_clean, keys %$repo_clean;

    my (@live_only, @repo_only, @diverged, @identical);
    for my $name (sort keys %all) {
        my $in_l = exists $live_clean->{$name};
        my $in_r = exists $repo_clean->{$name};
        if ($in_l && !$in_r) {
            push @live_only, { name => $name, entry => $live_clean->{$name} };
        } elsif (!$in_l && $in_r) {
            push @repo_only, { name => $name, entry => $repo_clean->{$name} };
        } else {
            if (canonical_json($live_clean->{$name}) eq canonical_json($repo_clean->{$name})) {
                push @identical, $name;
            } else {
                push @diverged, {
                    name  => $name,
                    live  => $live_clean->{$name},
                    repo  => $repo_clean->{$name},
                };
            }
        }
    }

    my $has_diff = scalar(@live_only) + scalar(@repo_only) + scalar(@diverged);
    emit_json({
        status      => $has_diff ? 'different' : 'identical',
        live        => $live,
        repo        => $repo,
        live_only   => \@live_only,
        repo_only   => \@repo_only,
        diverged    => \@diverged,
        identical   => \@identical,
    });
    exit 0;
}

# ─── Subcommand: settings-export-merge ────────────────────────────────────
# Merge live settings.json into repo's global-config/settings.json.
# Rule: live wins on shared keys; keys only in repo are preserved.
# This matches the /backup SKILL.md description.

sub deep_merge_live_wins_keep_repo_only {
    my ($live, $repo) = @_;
    # Both must be hashes; if not, just take live
    return $live unless ref($live) eq 'HASH' && ref($repo) eq 'HASH';

    my %out;
    # Start with repo keys (to preserve only-in-repo)
    for my $k (keys %$repo) {
        $out{$k} = $repo->{$k};
    }
    # Overlay live keys
    for my $k (keys %$live) {
        if (exists $out{$k} && ref($live->{$k}) eq 'HASH' && ref($out{$k}) eq 'HASH') {
            $out{$k} = deep_merge_live_wins_keep_repo_only($live->{$k}, $out{$k});
        } else {
            $out{$k} = $live->{$k};
        }
    }
    return \%out;
}

sub cmd_settings_export_merge {
    my $live = File::Spec->catfile(claude_dir(), 'settings.json');
    my $repo = File::Spec->catfile(ccpraxis_dir(), 'global-config', 'settings.json');

    die_json(1, "Live settings missing: $live") unless -f $live;

    my ($live_obj, $live_err) = read_json_file($live);
    die_json(2, "Cannot parse live settings: $live_err") if $live_err;

    my ($repo_obj, $repo_err) = -f $repo ? read_json_file($repo) : (undef, undef);
    if ($repo_err) {
        die_json(2, "Cannot parse repo settings: $repo_err");
    }
    $repo_obj //= {};

    # Pre-flight: backup the repo file before writing (in case caller hasn't).
    # Keep only the 2 most recent pre-merge backups; prune older ones so the
    # repo dir doesn't accumulate timestamped files forever.
    if (-f $repo) {
        my $backup = "${repo}.pre-merge." . time();
        unless (copy($repo, $backup)) {
            die_json(2, "Cannot create pre-merge backup: $!");
        }
        my $repo_dir = dirname($repo);
        my $base     = basename($repo);
        if (opendir my $rd, $repo_dir) {
            my @pre = sort { $b cmp $a }
                      grep { /^\Q$base\E\.pre-merge\.\d+$/ }
                      readdir $rd;
            closedir $rd;
            # Keep the 2 newest (which includes the one we just wrote); delete the rest.
            for my $stale (@pre[2 .. $#pre]) {
                unlink File::Spec->catfile($repo_dir, $stale);
            }
        }
    }

    my $merged = deep_merge_live_wins_keep_repo_only($live_obj, $repo_obj);
    my $err = write_json_file_atomic($repo, $merged);
    die_json(2, "Cannot write merged settings: $err") if $err;

    # Reload to verify
    my ($verify_obj, $verify_err) = read_json_file($repo);
    die_json(2, "Post-write read failed: $verify_err") if $verify_err;
    unless (canonical_json($verify_obj) eq canonical_json($merged)) {
        die_json(2, "Post-write content mismatch");
    }

    emit_json({
        status     => 'merged',
        live       => $live,
        repo       => $repo,
        merge_rule => 'live-wins-on-shared-keys-preserve-repo-only',
    });
    exit 0;
}

# ─── Help ─────────────────────────────────────────────────────────────────

sub cmd_help {
    print <<"EOF";
ccpraxis-helpers.pl

Subcommands:
  sync-skills            Mirror ccpraxis/skills/ to ~/.claude/skills/.
                         Symlinks on Unix, copies on Windows. Idempotent.

  check-claude-md        Report status of live CLAUDE.md vs the repo version.
                         Possible statuses: linked, equal_content, differs,
                         symlinked_elsewhere, missing_live, missing_repo.

  marketplace-diff       Diff live known_marketplaces.json vs repo's
                         global-config/known_marketplaces.json. Strips
                         installLocation from each entry before comparing.

  settings-export-merge  Merge live settings.json into repo's
                         global-config/settings.json. Live wins on shared
                         keys; keys only in repo are preserved.

All output is JSON on stdout. Exit codes: 0=ok, 1=soft fail, 2=hard fail.
EOF
    exit 0;
}

# ─── Dispatch ─────────────────────────────────────────────────────────────

my $sub = shift @ARGV;
$sub //= 'help';

if    ($sub eq 'sync-skills')           { cmd_sync_skills(); }
elsif ($sub eq 'check-claude-md')       { cmd_check_claude_md(); }
elsif ($sub eq 'marketplace-diff')      { cmd_marketplace_diff(); }
elsif ($sub eq 'settings-export-merge') { cmd_settings_export_merge(); }
elsif ($sub eq 'help' || $sub eq '--help' || $sub eq '-h') { cmd_help(); }
else { die_json(3, "Unknown subcommand: $sub"); }
