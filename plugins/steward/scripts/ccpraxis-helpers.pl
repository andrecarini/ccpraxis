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
#                           keys; keys only in repo are preserved — EXCEPT
#                           where the user's saved backup preferences, or a
#                           --skip-key flag, say to leave the repo side alone.
#                           Writes result to repo path atomically.
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
        # FB_CROAK (not FB_QUIET): on invalid UTF-8, FB_QUIET returns the
        # successfully-decoded *prefix* (silently truncating CP1252 "Andr\xE9"
        # to "Andr"), making the fallback below dead code. Croak instead, then
        # fall back to a CP1252 decode — the from_fs() pattern from skills.pl.
        my $decoded = eval { decode('UTF-8', $x, Encode::FB_CROAK) };
        return defined $decoded ? $decoded : decode('cp1252', $x, Encode::FB_DEFAULT);
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
#
# Base rule: live wins on shared keys; keys only in repo are preserved.
#
# That base rule is overridden by the user's saved backup preferences
# (.backup-preferences.json, "live_vs_repo" scope) and by per-run --skip-key
# flags. Without those overrides the merge destroys the very answers
# /steward:backup asked the user to record: a "keep different" (skip-always)
# key gets silently overwritten by live, and a "keep live-only" (left-only)
# key gets exported into the repo anyway.
#
# The key model mirrors json-diff.pl exactly, because json-diff is what
# produced the categories stored in the preferences file: keys are top-level,
# EXCEPT a key present on both sides whose values are both hashes and differ,
# which expands one level into "parent.child" dotted sub-keys (expansion
# skipped on a dotted-name collision). No preference can exist below that
# depth, so there the base rule applies unconditionally.

# Category → the only action meaningful for it. Mirrors filter-diff.pl; a
# preference whose action doesn't match its category is inert in both scripts.
my %VALID_ACTION = (
    only_left  => 'left-only',
    only_right => 'right-only',
    diverged   => 'skip-always',
);

# Value comparator for merge decisions. allow_nonref because individual setting
# values are usually plain scalars — canonical_json() above is only ever handed
# whole objects and predates this need.
my $VALUE_CMP = JSON::PP->new->canonical->allow_nonref;
sub same_value { return $VALUE_CMP->encode($_[0]) eq $VALUE_CMP->encode($_[1]); }

sub prefs_path { return File::Spec->catfile(ccpraxis_dir(), '.backup-preferences.json'); }

# Load the live_vs_repo preference scope. Returns ($scope_hashref, $error).
# A missing file is fine (no preferences recorded yet); an unparseable one is
# NOT — the whole point here is to refuse to act without knowing them.
sub load_export_prefs {
    my $path = prefs_path();
    return ({}, undef) unless -f $path;
    my ($obj, $err) = read_json_file($path);
    return (undef, $err) if $err;
    my $scope = $obj->{live_vs_repo};
    return ((ref $scope eq 'HASH' ? $scope : {}), undef);
}

# json-diff.pl skips one-level expansion when an expanded "parent.child" name
# would collide with a real top-level key. Mirrored so both scripts agree on
# what a key is.
sub dotted_collision {
    my ($key, $live_val, $repo_val, $all_keys) = @_;
    for my $sk (keys %$live_val, keys %$repo_val) {
        return 1 if exists $all_keys->{"$key.$sk"};
    }
    return 0;
}

# Below the preference depth the base rule applies — but "keys only in repo are
# preserved" still has to hold all the way down, so recurse instead of taking
# live's subtree wholesale, which would drop repo-only keys nested deeper.
sub deep_merge_live_wins_keep_repo_only {
    my ($live, $repo) = @_;
    return $live unless ref($live) eq 'HASH' && ref($repo) eq 'HASH';

    my %out = %$repo;    # start from repo, so only-in-repo keys survive
    for my $k (keys %$live) {
        $out{$k} = (ref $live->{$k} eq 'HASH' && ref $out{$k} eq 'HASH')
            ? deep_merge_live_wins_keep_repo_only($live->{$k}, $out{$k})
            : $live->{$k};
    }
    return \%out;
}

# Recursive merge. $ctx = { prefs, skip, applied, ignored, skip_used }.
# $depth is 0 for top-level keys and 1 inside an expanded hash; $prefix is the
# parent key name at depth 1, so preferences are looked up by dotted name.
sub merge_export_level {
    my ($live, $repo, $ctx, $prefix, $depth) = @_;

    my %all_keys;
    $all_keys{$_} = 1 for (keys %$live, keys %$repo);

    my %out;
    for my $k (sort keys %all_keys) {
        my $in_live = exists $live->{$k};
        my $in_repo = exists $repo->{$k};
        my $lv = $live->{$k};
        my $rv = $repo->{$k};

        my $rel = !$in_repo              ? 'only_left'
                : !$in_live              ? 'only_right'
                : same_value($lv, $rv)   ? 'identical'
                :                          'diverged';

        my $name = length($prefix) ? "$prefix.$k" : $k;

        # Expand one level, matching json-diff.pl, so dotted preferences apply.
        if ($depth == 0 && $rel eq 'diverged'
            && ref($lv) eq 'HASH' && ref($rv) eq 'HASH'
            && !dotted_collision($k, $lv, $rv, \%all_keys))
        {
            $out{$k} = merge_export_level($lv, $rv, $ctx, $k, 1);
            next;
        }

        # --skip-key: this run's "Skip" answers. Same effect as a preference —
        # leave the repo side of this key exactly as it is — but not persisted.
        if ($ctx->{skip}{$name}) {
            $ctx->{skip_used}{$name} = 1;
            push @{ $ctx->{applied} }, {
                key      => $name,
                relation => $rel,
                action   => 'skip-run',
                source   => 'skip-key',
                effect   => $in_repo ? 'kept repo value' : 'left absent from repo',
            };
            $out{$k} = $rv if $in_repo;
            next;
        }

        # An 'identical' key needs no decision and filter-diff.pl never surfaces
        # one, so a preference on it is dormant rather than stale — stay quiet.
        my $pref = $rel eq 'identical' ? undef : $ctx->{prefs}{$name};
        if (ref $pref eq 'HASH') {
            my $cat = $pref->{category} // '';
            my $act = $pref->{action}   // '';
            if ($cat eq $rel && defined $VALID_ACTION{$rel} && $act eq $VALID_ACTION{$rel}) {
                push @{ $ctx->{applied} }, {
                    key      => $name,
                    relation => $rel,
                    action   => $act,
                    source   => 'preferences',
                    effect   => $rel eq 'only_left'  ? 'kept out of repo (live-only)'
                              : $rel eq 'only_right' ? 'kept repo-only value'
                              :   'kept repo value (sides intentionally differ)',
                };
                # only_left omits the key from the repo entirely; the other two
                # categories mean "whatever the repo already has, stands".
                $out{$k} = $rv unless $rel eq 'only_left';
                next;
            }
            push @{ $ctx->{ignored} }, {
                key             => $name,
                saved_category  => $cat,
                saved_action    => $act,
                actual_relation => $rel,
                reason          => $cat ne $rel
                    ? "saved category '$cat' no longer matches actual relation '$rel'"
                    : "saved action '$act' is not the valid action for category '$cat'",
            };
        }

        # Base rule. Both-hashes here means either a dotted-name collision blocked
        # expansion, or we're already at depth 1 — either way no preference can
        # address the sub-keys, so deep-merge them rather than overwrite.
        $out{$k} = (ref $lv eq 'HASH' && ref $rv eq 'HASH')
            ? deep_merge_live_wins_keep_repo_only($lv, $rv)
            : ($in_live ? $lv : $rv);
    }
    return \%out;
}

sub cmd_settings_export_merge {
    # Per-run "Skip" answers from /steward:backup Step 1.5. Repeatable.
    my %skip;
    while (@ARGV) {
        my $arg = shift @ARGV;
        if ($arg eq '--skip-key') {
            my $key = shift @ARGV;
            die_json(3, "--skip-key requires a key name") unless defined $key && length $key;
            $skip{$key} = 1;
        } elsif ($arg =~ /^--skip-key=(.+)\z/) {
            $skip{$1} = 1;
        } else {
            die_json(3, "Unknown argument for settings-export-merge: $arg");
        }
    }

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

    my ($prefs, $prefs_err) = load_export_prefs();
    # Refuse to merge blind: proceeding without the preferences is exactly the
    # failure mode this subcommand exists to avoid.
    die_json(2, "Cannot parse backup preferences: $prefs_err") if $prefs_err;

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

    my $ctx = {
        prefs     => $prefs,
        skip      => \%skip,
        applied   => [],
        ignored   => [],
        skip_used => {},
    };
    my $merged = merge_export_level($live_obj, $repo_obj, $ctx, '', 0);

    my $err = write_json_file_atomic($repo, $merged);
    die_json(2, "Cannot write merged settings: $err") if $err;

    # Reload to verify
    my ($verify_obj, $verify_err) = read_json_file($repo);
    die_json(2, "Post-write read failed: $verify_err") if $verify_err;
    unless (canonical_json($verify_obj) eq canonical_json($merged)) {
        die_json(2, "Post-write content mismatch");
    }

    # A --skip-key naming something absent from both files is almost always a
    # typo in the caller's invocation — surface it rather than swallow it.
    my @unmatched = sort grep { !$ctx->{skip_used}{$_} } keys %skip;

    emit_json({
        status              => 'merged',
        live                => $live,
        repo                => $repo,
        merge_rule          => 'preference-aware-live-wins-preserve-repo-only',
        preferences_file    => (-f prefs_path() ? prefs_path() : undef),
        preferences_applied => $ctx->{applied},
        preferences_ignored => $ctx->{ignored},
        skip_keys_unmatched => \@unmatched,
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
                         keys; keys only in repo are preserved. Saved backup
                         preferences (.backup-preferences.json, live_vs_repo
                         scope) override that: "keep different" (skip-always)
                         and "keep repo-only" (right-only) keep the repo's
                         value; "keep live-only" (left-only) stays out of the
                         repo entirely.
                         Options:
                           --skip-key KEY  Leave the repo side of KEY alone for
                                           this run only (repeatable). Use for
                                           the user's per-run "Skip" answers.
                                           Dotted names (env.FOO) address one
                                           sub-key, matching json-diff.pl.

All output is JSON on stdout. Exit codes: 0=ok, 1=soft fail, 2=hard fail,
3=usage error.
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
