#!/usr/bin/perl
# ccpraxis-helpers.pl — deterministic helper subcommands for /backup.
#
# Replaces several LLM-driven prose steps with scripted ones. Each
# subcommand emits a JSON report; the LLM consumes the JSON and only
# needs to drive AskUserQuestion / commit-message generation.
#
# Two checkouts are involved (DevClone.pm has the whole model):
#   the live install  <home>/.claude/ccpraxis, what Claude Code runs. Read
#                     only: its skills are mirrored, its payload is what
#                     ~/.claude/CLAUDE.md is built from, its
#                     .backup-preferences.json holds this machine's answers.
#                     Nothing here ever writes into it.
#   the dev clone     the export target. Only settings-export-merge writes,
#                     and only into the dev clone's working tree.
#
# Every subcommand except claude-internals takes:
#   --live-root DIR   the live install (default <home>/.claude/ccpraxis, the
#                     same default promote.pl's --live has). The backup driver
#                     always passes it, so ${CCPRAXIS_LIVE} is collapsed against
#                     the same directory promote expanded it to.
#   --repo-root DIR   the dev clone (default: the live install's origin, which
#                     promote.pl points at the dev clone).
#
# Subcommands:
#   sync-skills           — Ensure each live-install skill is mirrored into
#                           ~/.claude/skills. Symlink on Unix, copy on
#                           Windows. Emits per-skill result
#                           (linked/copied/unchanged/error).
#   check-claude-md       — Compare ~/.claude/CLAUDE.md with what promote.pl
#                           builds for this host from the live install's
#                           payload (GlobalClaudeMd.pm). Reports in_sync/
#                           linked/differs/symlinked_elsewhere/missing_live/
#                           missing_payload, and for differs the lines on
#                           each side.
#   install-claude-md     — Rebuild ~/.claude/CLAUDE.md from the live
#                           install's payload, the existing file first backed
#                           up to ~/.claude/.promotion-backups/<ts>/.
#   marketplace-diff      — Detect discrepancies between live and repo
#                           known_marketplaces.json. Emits the discrepancies
#                           the LLM needs to resolve.
#   settings-export-merge — Merge live settings.json into the dev clone's
#                           global-config/settings.json: live wins on shared
#                           keys; keys only in repo are preserved — EXCEPT
#                           where the user's saved backup preferences, or a
#                           --skip-key flag, say to leave the repo side alone.
#                           Writes result to repo path atomically.
#   claude-internals       — Read-only check that the installed claude binary
#                           still contains the undocumented internals our
#                           settings rely on. Dispatches to the sibling
#                           claude-internals-check.pl and mirrors its exit code.
#   help
#
# All output is JSON on stdout. Exit codes:
#   0 = success / nothing to do
#   1 = soft fail (file missing where it should exist, etc.)
#   2 = hard fail (write error, integrity issue)
#   3 = usage error
#
# Core Perl modules only, plus the sibling modules in this directory.

use strict;
use warnings;
use File::Copy qw(copy);
use File::Path qw(make_path remove_tree);
use File::Spec;
use File::Basename qw(basename dirname);
use JSON::PP;
use Encode qw(decode);
use FindBin ();
use lib $FindBin::Bin;
use DevClone ();
use GlobalClaudeMd ();
use MachineLocalSettings ();

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

# --live-root / --repo-root, taken out of @ARGV before a subcommand parses
# the rest (take_root_opts, called by the dispatcher).
my %ROOT_OPT;
sub take_root_opts {
    my @rest;
    while (@ARGV) {
        my $a = shift @ARGV;
        if ($a eq '--live-root' || $a eq '--repo-root') {
            my $v = shift @ARGV;
            die_json(3, "$a requires a directory") unless defined $v && length $v;
            $ROOT_OPT{ $a eq '--live-root' ? 'live' : 'repo' } = $v;
        } elsif ($a =~ /^--(live|repo)-root=(.+)\z/) {
            $ROOT_OPT{$1} = $2;
        } else {
            push @rest, $a;
        }
    }
    @ARGV = @rest;
    return;
}

# The live install: read from, never written to.
sub live_root {
    return $ROOT_OPT{live} if defined $ROOT_OPT{live};
    return DevClone::default_live_root(home_dir());
}

# The dev clone, the only checkout an export writes into. Never the live
# install, whichever way it was named.
sub repo_root {
    my $repo = $ROOT_OPT{repo};
    unless (defined $repo) {
        my $loc = DevClone::locate(live_root => live_root(), override => $ENV{BACKUP_CLONE_DIR});
        die_json(1, "no dev clone to export into: $loc->{reason}", fix => $loc->{fix})
            unless defined $loc->{dev_clone};
        $repo = $loc->{dev_clone};
    }
    die_json(2, "refusing to export into the live install ($repo): the export target is the dev clone")
        if DevClone::same_dir($repo, live_root());
    return $repo;
}

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
    # The skills that run are the live install's, so those are what is mirrored.
    my $ccpraxis = live_root();
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
    my $root = live_root();
    # ~/.claude/CLAUDE.md is built by promote.pl from the live install's
    # payload (the shared file plus this host's part), so that build is what
    # it is compared with -- never a single repo file, and never the dev
    # clone, which may hold payload edits that are not live yet.
    my $c = GlobalClaudeMd::compare_installed(installed => $live, live_root => $root);

    my %r = (
        live      => $live,
        repo      => "$root/" . GlobalClaudeMd::SHARED_RELPATH,
        payload   => $root,
        status    => $c->{status},
        host_part => $c->{host_part},
    );
    $r{target} = $c->{target} if defined $c->{target};
    $r{reason} = $c->{reason} if defined $c->{reason};
    if ($c->{status} eq 'differs' || $c->{status} eq 'symlinked_elsewhere') {
        $r{extra_lines}   = $c->{extra_lines};
        $r{missing_lines} = $c->{missing_lines};
        $r{resolve}       = GlobalClaudeMd::fold_hint() if @{ $c->{extra_lines} };
    }
    emit_json(\%r);
    exit($c->{status} =~ /^missing_/ ? 1 : 0);
}

# ─── Subcommand: install-claude-md ────────────────────────────────────────
# What promote.pl does to ~/.claude/CLAUDE.md, alone: rebuild it from the live
# install's payload, after a verified backup copy of the file it replaces in
# ~/.claude/.promotion-backups/<UTC timestamp>/ (promote.pl's own backup
# directory, same naming). A link to the shared file holds no content, so it is
# replaced without a copy; a link anywhere else is refused, as promote refuses
# it, because replacing it would silently cut whatever it points at loose.

sub promotion_backup_dir {
    my $base = File::Spec->catdir(claude_dir(), '.promotion-backups');
    make_path($base) unless -d $base;
    my @t = gmtime(time());
    my $dir = File::Spec->catdir($base, sprintf('%04d%02d%02d-%02d%02d%02d',
        $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]));
    if (-e $dir) {
        my $n = 2;
        $n++ while -e "$dir-$n";
        $dir = "$dir-$n";
    }
    make_path($dir) or return (undef, "cannot create $dir: $!");
    return ($dir, undef);
}

sub write_bytes_atomic {
    my ($path, $bytes) = @_;
    my $tmp = "$path.tmp.$$";
    open my $fh, '>:raw', $tmp or return "cannot open $tmp for write: $!";
    unless (print {$fh} $bytes) { my $e = $!; close $fh; unlink $tmp; return "write $tmp failed: $e"; }
    unless (close $fh)          { my $e = $!; unlink $tmp; return "close $tmp failed: $e"; }
    unless (rename($tmp, $path)) { my $e = $!; unlink $tmp; return "rename $tmp -> $path failed: $e"; }
    return undef;
}

sub cmd_install_claude_md {
    my $dest = File::Spec->catfile(claude_dir(), 'CLAUDE.md');
    my $c = GlobalClaudeMd::compare_installed(installed => $dest, live_root => live_root());
    my $status = $c->{status};

    die_json(1, 'the live install has no ' . GlobalClaudeMd::SHARED_RELPATH . ' to build from', live => $dest)
        if $status eq 'missing_payload';
    die_json(1, "$dest is a link to $c->{target}; not replacing a link to another file", live => $dest)
        if $status eq 'symlinked_elsewhere';
    if ($status eq 'in_sync' || $status eq 'linked') {
        emit_json({ status => 'unchanged', live => $dest, previous_status => $status, backup => undef });
        exit 0;
    }

    my $backup;
    if (-l $dest) {
        unlink $dest or die_json(2, "cannot remove the link $dest: $!");
    } elsif (-f $dest) {
        my ($dir, $derr) = promotion_backup_dir();
        die_json(2, "cannot back up $dest: $derr") unless defined $dir;
        $backup = File::Spec->catfile($dir, 'CLAUDE.md');
        open my $in, '<:raw', $dest or die_json(2, "cannot read $dest: $!");
        local $/;
        my $orig = <$in> // '';
        close $in;
        my $err = write_bytes_atomic($backup, $orig);
        die_json(2, "cannot back up $dest: $err") if defined $err;
        open my $chk, '<:raw', $backup or die_json(2, "cannot verify the backup $backup: $!");
        my $again = <$chk> // '';
        close $chk;
        die_json(2, "backup verification failed for $backup") unless $again eq $orig;
    }
    my $err = write_bytes_atomic($dest, $c->{rendered});
    die_json(2, "cannot write $dest: $err") if defined $err;
    emit_json({ status => 'rendered', live => $dest, previous_status => $status, backup => $backup });
    exit 0;
}

# ─── Subcommand: marketplace-diff ─────────────────────────────────────────

sub cmd_marketplace_diff {
    # --live / --repo override the default locations. Added for testability:
    # without them this subcommand can only ever be exercised against the
    # operator's own two files, so a test writes fixtures, gets the real files
    # diffed instead, and passes on whatever they happen to contain. That is
    # not a hypothetical -- t/16's first assertion did exactly that, and only
    # its counter-check revealed the fixtures were being ignored.
    my ($live, $repo);
    {
        my @argv = @ARGV;
        while (@argv) {
            my $a = shift @argv;
            if    ($a eq '--live') { $live = shift @argv }
            elsif ($a eq '--repo') { $repo = shift @argv }
        }
    }
    $live //= File::Spec->catfile(claude_dir(), 'plugins', 'known_marketplaces.json');
    # Read-only, so the default is the payload that was promoted: the live
    # install's. The backup driver passes --repo with the dev clone's file.
    $repo //= File::Spec->catfile(live_root(), 'global-config', 'known_marketplaces.json');

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
    # Strip the fields that are NOT part of a marketplace's identity before
    # comparing. Two kinds, and both must go:
    #
    #   installLocation  machine-specific absolute path.
    #   lastUpdated      a refresh timestamp. Bumped every time Claude Code
    #                    re-fetches a marketplace, on each machine
    #                    independently, with no bearing on what the marketplace
    #                    IS.
    #
    # lastUpdated was not stripped, so `claude-plugins-official` reported as
    # "diverged" on 2026-09-06 with byte-identical `source` on both sides and
    # only the timestamp differing. The skill's diverged branch is written for
    # "the source URL changed" and offers Use live / Use repo / remember --
    # meaning a routine refresh presented as a conflict, on every backup,
    # forever. That is exactly the recurring-prompt noise the preferences
    # system was built to eliminate, arriving through a different door.
    #
    # Named explicitly rather than allow-listing `source`: a future field that
    # genuinely distinguishes two marketplaces should show up as a difference
    # and be noticed, not be silently discarded by a filter nobody revisits.
    my @VOLATILE = qw(installLocation lastUpdated);
    my $strip = sub {
        my $obj = shift;
        my %out;
        for my $name (keys %$obj) {
            my $entry = { %{ $obj->{$name} // {} } };
            delete $entry->{$_} for @VOLATILE;
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

    # SAVED PREFERENCES, the same mechanism settings.json already has.
    #
    # Without this, a marketplace that is deliberately machine-local is reported
    # as a discrepancy on EVERY backup, forever, and the only answers on offer
    # are "export it" (wrong), "remove it" (wrong) and "skip" (asked again next
    # time). ccpraxis-local is exactly that case: a directory-source entry whose
    # path is absolute on this machine, registered per-machine by install.pl, so
    # exporting it would carry one machine's filesystem into shared config.
    #
    # Operator, 2026-08-29: "Keep it live only and make the backup machinery
    # stop asking that." A recurring question with a permanent answer is a
    # defect in the question.
    #
    # Scope name and semantics mirror filter-diff.pl exactly, so there is one
    # vocabulary across the whole backup flow rather than a second dialect:
    #   only_left  + left-only   -> live-only on purpose
    #   only_right + right-only  -> repo-only on purpose
    #   diverged   + skip-always -> intentionally different
    my %valid_action = (only_left => 'left-only', only_right => 'right-only',
                        diverged  => 'skip-always');
    my $prefs = {};
    {
        my $pf = prefs_path();
        if (-f $pf) {
            my ($obj) = read_json_file($pf);
            $prefs = (ref $obj eq 'HASH' && ref $obj->{marketplaces} eq 'HASH')
                   ? $obj->{marketplaces} : {};
        }
    }
    my @auto_applied;
    my $honoured = sub {
        my ($name, $category) = @_;
        my $saved = $prefs->{$name};
        return 0 unless ref $saved eq 'HASH';
        return 0 unless ($saved->{category} // '') eq $category;
        return 0 unless ($saved->{action}   // '') eq $valid_action{$category};
        push @auto_applied, { name => $name, category => $category, action => $saved->{action} };
        return 1;
    };
    @live_only = grep { !$honoured->($_->{name}, 'only_left')  } @live_only;
    @repo_only = grep { !$honoured->($_->{name}, 'only_right') } @repo_only;
    @diverged  = grep { !$honoured->($_->{name}, 'diverged')   } @diverged;

    my $has_diff = scalar(@live_only) + scalar(@repo_only) + scalar(@diverged);
    emit_json({
        status        => $has_diff ? 'different' : 'identical',
        live          => $live,
        repo          => $repo,
        live_only     => \@live_only,
        repo_only     => \@repo_only,
        diverged      => \@diverged,
        identical     => \@identical,
        auto_applied  => \@auto_applied,
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

# Machine-local answers live in the live install, where promote.pl reads them.
sub prefs_path { return File::Spec->catfile(live_root(), '.backup-preferences.json'); }

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
    # Written into the dev clone's working tree, never the live install: the
    # live install changes only by promotion (DevClone.pm).
    my $repo = File::Spec->catfile(repo_root(), 'global-config', 'settings.json');

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

    # Machine-local values (MachineLocalSettings.pm). The payload is shared by
    # every machine, so this machine's own live-install path goes back in as
    # ${CCPRAXIS_LIVE}, never as the literal path, and the platform-only keys
    # that do not apply on this host are taken out of the merge on both sides
    # and put back exactly as the repo had them -- a Mac backup never adds,
    # changes or deletes the Windows-only PowerShell switch. The path is
    # collapsed against the LIVE install (live_root), the directory promote.pl
    # expanded the token to -- never against the dev clone being written.
    MachineLocalSettings::collapse_live_root($live_obj, live_root());
    MachineLocalSettings::strip_foreign_platform_keys($live_obj);
    my $repo_foreign = MachineLocalSettings::strip_foreign_platform_keys($repo_obj);

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
    MachineLocalSettings::restore_foreign_platform_keys($merged, $repo_foreign);

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

# ─── Subcommand: claude-internals ─────────────────────────────────────────
# Runs the sibling claude-internals-check.pl as a child process ($^X, never
# the claude binary). Everything after the subcommand is passed through
# unchanged. Exits with the child's exit code; the child's stdout/stderr pass
# through untouched. Adds no JSON of its own.
sub cmd_claude_internals {
    # Separators FIRST, then dirname -- __FILE__ can carry backslashes on
    # Windows. Same shape as BpTurnCaps::script_dir_for; asserted repo-wide by
    # turn-cap-consistency.t's C9.
    (my $self = __FILE__) =~ s{\\}{/}g;
    my $sibling = File::Spec->catfile(dirname($self), 'claude-internals-check.pl');
    my $rc = system($^X, $sibling, @ARGV);
    if ($rc == -1) {
        print STDERR "ccpraxis-helpers.pl: failed to run claude-internals-check.pl: $!\n";
        exit 2;
    }
    if ($rc & 127) {
        print STDERR "ccpraxis-helpers.pl: claude-internals-check.pl died with signal " . ($rc & 127) . "\n";
        exit 2;
    }
    exit($rc >> 8);
}

# ─── Help ─────────────────────────────────────────────────────────────────

sub cmd_help {
    print <<"EOF";
ccpraxis-helpers.pl

Subcommands:
  sync-skills            Mirror the live install's skills/ to ~/.claude/skills/. Symlinks on Unix, copies on Windows. Idempotent.

  check-claude-md        Compare ~/.claude/CLAUDE.md with what promote.pl builds for this host from the live install's payload (global-config/CLAUDE.md plus this host's part). Statuses: in_sync, linked, differs, symlinked_elsewhere, missing_live, missing_payload; differs also lists the lines only on each side.

  install-claude-md      Rebuild ~/.claude/CLAUDE.md from the live install's payload, as promote.pl does, after a verified copy of the old file to ~/.claude/.promotion-backups/<timestamp>/. Refuses a link to another file.

  marketplace-diff       Diff live known_marketplaces.json vs a payload copy (--repo FILE; default: the live install's global-config/known_marketplaces.json). Strips installLocation and lastUpdated from each entry before comparing.

  settings-export-merge  Merge live settings.json into the dev clone's global-config/settings.json. Live wins on shared keys; keys only in repo are preserved. Saved backup preferences (.backup-preferences.json, live_vs_repo scope) override that: "keep different" (skip-always) and "keep repo-only" (right-only) keep the repo's value; "keep live-only" (left-only) stays out of the repo entirely. Never writes into the live install.
                         Options:
                           --skip-key KEY  Leave the repo side of KEY alone for this run only (repeatable). Use for the user's per-run "Skip" answers. Dotted names (env.FOO) address one sub-key, matching json-diff.pl.

  claude-internals  Read-only check that the installed claude binary still contains the undocumented internals our settings rely on. Options: --binary PATH, --data PATH. Exit 0 all present, 1 changed, 2 could not check.

Every subcommand but claude-internals takes --live-root DIR (the live install; default ~/.claude/ccpraxis) and --repo-root DIR (the dev clone; default the live install's origin).

All output is JSON on stdout. Exit codes: 0=ok, 1=soft fail, 2=hard fail, 3=usage error.
EOF
    exit 0;
}

# ─── Dispatch ─────────────────────────────────────────────────────────────

my $sub = shift @ARGV;
$sub //= 'help';
# claude-internals passes its arguments through untouched; every other
# subcommand accepts --live-root / --repo-root.
take_root_opts() unless $sub eq 'claude-internals';

if    ($sub eq 'sync-skills')           { cmd_sync_skills(); }
elsif ($sub eq 'check-claude-md')       { cmd_check_claude_md(); }
elsif ($sub eq 'install-claude-md')     { cmd_install_claude_md(); }
elsif ($sub eq 'marketplace-diff')      { cmd_marketplace_diff(); }
elsif ($sub eq 'settings-export-merge') { cmd_settings_export_merge(); }
elsif ($sub eq 'claude-internals')      { cmd_claude_internals(); }
elsif ($sub eq 'help' || $sub eq '--help' || $sub eq '-h') { cmd_help(); }
else { die_json(3, "Unknown subcommand: $sub"); }
