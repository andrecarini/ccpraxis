#!/usr/bin/env perl
# update-bootstrap-monitor.pl — Versioned archive + drift check for upstream bootstrap.ps1
#
# Archive lives at ~/.claude/claude-code-vault/bootstrap-archive/, keyed by the
# Claude Code version that was upstream-latest at the time of capture. The script
# never decides whether a diff is meaningful — it produces inputs (paths, hashes,
# unified diff) for Claude to interpret.
#
# Subcommands:
#   check --current <V_current> --target <V_target> [--latest <V_latest>]
#                                         Resolve A=archive[V_current] and
#                                         B=archive[V_target] or upstream-now;
#                                         emit status + paths + diff.
#   capture --version <V>                 Fetch upstream now and archive under V.
#   list                                  List archive entries with sha256 + size.

use strict;
use warnings;
use HTTP::Tiny;
use Digest::SHA qw();
use File::Path qw(make_path);
use File::Copy qw(copy);
use POSIX qw(strftime);

my $home = $ENV{HOME} // $ENV{USERPROFILE};
$home =~ s/\\/\//g;

my $ARCHIVE_DIR  = "$home/.claude/claude-code-vault/bootstrap-archive";
my $TMP_DIR      = "$home/.claude/cache/update-bootstrap-tmp";
my $BOOTSTRAP_URL = "https://downloads.claude.ai/claude-code-releases/bootstrap.ps1";

my $cmd = shift @ARGV // "help";

if    ($cmd eq "check")   { cmd_check()   }
elsif ($cmd eq "capture") { cmd_capture() }
elsif ($cmd eq "list")    { cmd_list()    }
else                      { cmd_help()    }

exit 0;

# ── Subcommands ──────────────────────────────────────────────────────

sub cmd_check {
    my %args = parse_args(qw(--current --target --latest));
    my $v_current = $args{"--current"} or emit_error("Usage: check --current <V_current> --target <V_target> [--latest <V_latest>]");
    my $v_target  = $args{"--target"}  or emit_error("Usage: check --current <V_current> --target <V_target> [--latest <V_latest>]");
    my $v_latest  = $args{"--latest"} // "";

    # Resolve A side: archive[V_current]
    my $a_path = archive_path($v_current);
    my $a_present = (-f $a_path) ? 1 : 0;
    my $a_corrupt = 0;
    my $a_sha = "";
    if ($a_present) {
        $a_sha = eval { sha256_file($a_path) };
        if ($@ || !$a_sha) { $a_corrupt = 1; }
    }

    # Resolve B side: archive[V_target] (preferred), or upstream-now (if V_target == V_latest),
    # or upstream-now as a "superset" fallback.
    my $b_path = "";
    my $b_key  = "";
    my $b_sha  = "";
    my $b_present = 0;
    my $b_corrupt = 0;
    my $b_source  = "";

    my $v_target_is_latest = ($v_latest && $v_target eq $v_latest);
    my $archive_target     = archive_path($v_target);

    if ($v_target_is_latest) {
        # When V_target IS the latest, always fetch upstream-now for freshness.
        # archive[V_latest] (if exists) might be stale relative to current upstream.
        my $fetch = fetch_upstream_to_tmp();
        if ($fetch->{status} != 200) {
            emit("STATUS",           "error");
            emit("ERROR",            "upstream_fetch_failed");
            emit("ERROR_DETAIL",     "HTTP $fetch->{status} from $BOOTSTRAP_URL");
            emit("ARCHIVE_DIR",      $ARCHIVE_DIR);
            emit("BASELINE_PATH",    $a_path);
            emit("BASELINE_KEY",     $v_current);
            emit("BASELINE_PRESENT", $a_present ? "yes" : "no");
            emit("BASELINE_SHA256",  $a_sha);
            emit("BASELINE_CORRUPT", $a_corrupt ? "yes" : "no");
            exit 1;
        }
        $b_path    = $fetch->{path};
        $b_key     = "upstream-now (=$v_latest)";
        $b_source  = "upstream";
        $b_sha     = $fetch->{sha256};
        $b_present = 1;
    } elsif (-f $archive_target) {
        # V_target != latest, but we have its archive entry. Use it.
        $b_path   = $archive_target;
        $b_key    = $v_target;
        $b_source = "archive";
        $b_sha    = eval { sha256_file($b_path) };
        if ($@ || !$b_sha) { $b_corrupt = 1 } else { $b_present = 1 }
    } else {
        # V_target != latest AND archive[V_target] absent.
        # Fetch upstream-now as a SUPERSET reference — it's V_latest's ps1, not V_target's.
        my $fetch = fetch_upstream_to_tmp();
        if ($fetch->{status} == 200) {
            $b_path    = $fetch->{path};
            $b_key     = $v_latest ? "upstream-now (=$v_latest, SUPERSET)" : "upstream-now (SUPERSET)";
            $b_source  = "upstream-superset";
            $b_sha     = $fetch->{sha256};
            $b_present = 1;
        }
        # If upstream fetch failed too, B remains unresolved; status below handles.
    }

    # Classify status
    my ($status, $diff_path, $diff_hunks) = ("", "", 0);

    if ($a_corrupt) {
        $status = "archive_corrupt";
    } elsif (!$a_present && !$b_present) {
        $status = "both_missing";
    } elsif (!$a_present) {
        $status = "no_baseline_current";
    } elsif (!$b_present) {
        $status = "no_baseline_target";
    } else {
        # Both present. Compare.
        if ($a_sha eq $b_sha) {
            $status = "clean";
        } elsif ($b_source eq "upstream-superset") {
            $status = "superset_drift";
            ($diff_path, $diff_hunks) = make_diff($a_path, $b_path);
        } else {
            $status = "drifted";
            ($diff_path, $diff_hunks) = make_diff($a_path, $b_path);
        }
    }

    emit("STATUS",           $status);
    emit("ARCHIVE_DIR",      $ARCHIVE_DIR);
    emit("BASELINE_PATH",    $a_path);
    emit("BASELINE_KEY",     $v_current);
    emit("BASELINE_PRESENT", $a_present ? "yes" : "no");
    emit("BASELINE_SHA256",  $a_sha);
    emit("BASELINE_CORRUPT", $a_corrupt ? "yes" : "no");
    emit("TARGET_PATH",      $b_path);
    emit("TARGET_KEY",       $b_key);
    emit("TARGET_PRESENT",   $b_present ? "yes" : "no");
    emit("TARGET_SHA256",    $b_sha);
    emit("TARGET_SOURCE",    $b_source);
    emit("DIFF_PATH",        $diff_path)  if $diff_path;
    emit("DIFF_HUNK_COUNT",  $diff_hunks) if $diff_path;
}

sub cmd_capture {
    my %args = parse_args(qw(--version));
    my $version = $args{"--version"} or emit_error("Usage: capture --version <V>");

    make_path($ARCHIVE_DIR) unless -d $ARCHIVE_DIR;

    my $fetch = fetch_upstream_to_tmp();
    if ($fetch->{status} != 200) {
        emit("STATUS", "error");
        emit("ERROR",  "upstream_fetch_failed: HTTP $fetch->{status} from $BOOTSTRAP_URL");
        exit 1;
    }

    my $dest = archive_path($version);
    unless (copy($fetch->{path}, $dest)) {
        emit("STATUS", "error");
        emit("ERROR",  "copy_failed: $!");
        exit 1;
    }
    unlink $fetch->{path};

    emit("STATUS",        "ok");
    emit("ARCHIVED_PATH", $dest);
    emit("SHA256",        $fetch->{sha256});
    emit("SIZE",          -s $dest);
}

sub cmd_list {
    unless (-d $ARCHIVE_DIR) {
        emit("STATUS",      "ok");
        emit("ARCHIVE_DIR", $ARCHIVE_DIR);
        emit("ENTRIES",     "(none)");
        return;
    }

    opendir my $dh, $ARCHIVE_DIR or emit_error("Cannot read $ARCHIVE_DIR: $!");
    my @files = sort grep { /^bootstrap-\d+\.\d+\.\d+\.ps1$/ } readdir $dh;
    closedir $dh;

    emit("STATUS",      "ok");
    emit("ARCHIVE_DIR", $ARCHIVE_DIR);
    emit("ENTRIES",     scalar @files);
    for my $f (@files) {
        my $full = "$ARCHIVE_DIR/$f";
        my ($v) = $f =~ /^bootstrap-(\d+\.\d+\.\d+)\.ps1$/;
        my $size = -s $full;
        my $sha = sha256_file($full);
        print "ENTRY: $v | sha256:$sha | size:$size\n";
    }
}

sub cmd_help {
    print "Usage: update-bootstrap-monitor.pl <command> [args]\n\n";
    print "Commands:\n";
    print "  check --current <V_current> --target <V_target> [--latest <V_latest>]\n";
    print "                                Resolve A=archive[V_current], B=archive[V_target]\n";
    print "                                or upstream-now; emit status + paths + diff.\n";
    print "  capture --version <V>         Fetch upstream now, archive under V.\n";
    print "  list                          List archive entries with sha256 + size.\n";
}

# ── Helpers ──────────────────────────────────────────────────────────

sub emit {
    my ($k, $v) = @_;
    $v //= "";
    print "$k: $v\n";
}

sub emit_error {
    my $msg = shift;
    emit("STATUS", "error");
    emit("ERROR",  $msg);
    exit 1;
}

sub parse_args {
    my %valid = map { $_ => 1 } @_;
    my (%got, @rest);
    while (defined(my $arg = shift @ARGV)) {
        if ($valid{$arg}) {
            $got{$arg} = shift @ARGV;
        } else {
            push @rest, $arg;
        }
    }
    @ARGV = @rest;
    return %got;
}

sub archive_path {
    my $version = shift;
    return "$ARCHIVE_DIR/bootstrap-$version.ps1";
}

sub fetch_upstream_to_tmp {
    make_path($TMP_DIR) unless -d $TMP_DIR;
    my $ts = strftime("%Y%m%dT%H%M%SZ", gmtime);
    my $path = "$TMP_DIR/bootstrap-upstream-$ts.ps1";

    my $ua  = HTTP::Tiny->new(timeout => 60, agent => "ccpraxis-update/1.0");
    open my $fh, ">:raw", $path or return { status => 500 };
    my $res = $ua->get(
        $BOOTSTRAP_URL,
        {
            data_callback => sub {
                my ($chunk) = @_;
                print $fh $chunk;
            }
        }
    );
    close $fh;

    return { status => $res->{status} } if $res->{status} != 200;

    my $sha = sha256_file($path);
    return { status => 200, path => $path, sha256 => $sha };
}

sub sha256_file {
    my $path = shift;
    my $sha  = Digest::SHA->new(256);
    $sha->addfile($path);
    return lc($sha->hexdigest);
}

sub make_diff {
    my ($a, $b) = @_;
    make_path($TMP_DIR) unless -d $TMP_DIR;
    my $ts        = strftime("%Y%m%dT%H%M%SZ", gmtime);
    my $diff_path = "$TMP_DIR/bootstrap-diff-$ts.patch";
    my $cmd       = sprintf("diff -u %s %s > %s 2>&1", shell_escape($a), shell_escape($b), shell_escape($diff_path));
    my $rc        = system($cmd);
    my $exit      = $rc >> 8;
    # diff returns 0 if same, 1 if different, 2 if trouble.
    if ($exit > 1) {
        return ("", 0);
    }
    my $hunks = 0;
    if (open my $dfh, "<:raw", $diff_path) {
        while (my $line = <$dfh>) {
            $hunks++ if $line =~ /^@@/;
        }
        close $dfh;
    }
    return ($diff_path, $hunks);
}

sub shell_escape {
    my $s = shift;
    $s =~ s/'/'\\''/g;
    return "'$s'";
}
