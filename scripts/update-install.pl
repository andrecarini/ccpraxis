#!/usr/bin/env perl
# update-install.pl — Direct-binary Claude Code install pipeline
# Used by /update skill (windows-native installs).
#
# Subcommands:
#   detect                                Detect installed version + install method
#   manifest --version <V> [--platform P] Fetch + parse manifest, emit checksum/size/url
#   install --version <V> [--platform P]  Download binary, verify SHA256, run installer
#   verify --expected <V>                 Confirm `claude --version` matches expected

use strict;
use warnings;
use HTTP::Tiny;
use JSON::PP;
use Digest::SHA qw();
use File::Path qw(make_path);
use POSIX qw(strftime);

my $home = $ENV{HOME} // $ENV{USERPROFILE};
die "Cannot determine home directory\n" unless $home;
$home =~ s/\\/\//g;

my $DOWNLOAD_DIR     = "$home/.claude/downloads";
my $TMP_DIR          = "$home/.claude/cache/update-tmp";
my $BASE_URL         = "https://downloads.claude.ai/claude-code-releases";
my $DEFAULT_PLATFORM = "win32-x64";

my $cmd = shift @ARGV // "help";

if    ($cmd eq "detect")   { cmd_detect()   }
elsif ($cmd eq "manifest") { cmd_manifest() }
elsif ($cmd eq "install")  { cmd_install()  }
elsif ($cmd eq "verify")   { cmd_verify()   }
else                       { cmd_help()     }

exit 0;

# ── Subcommands ──────────────────────────────────────────────────────

sub cmd_detect {
    my $version_out = qx(claude --version 2>&1);
    my $rc = $? >> 8;
    if ($rc != 0) {
        emit_error("claude --version failed (exit $rc): " . trim($version_out));
    }
    my ($version) = $version_out =~ /^(\d+\.\d+\.\d+)/;
    unless ($version) {
        emit_error("Could not parse version from: " . trim($version_out));
    }

    my $binary_path = find_binary_path();

    my $method = "unsupported";
    if ($binary_path) {
        my $bp_norm = $binary_path;
        $bp_norm =~ s/\\/\//g;
        if ($bp_norm =~ m{(?:^|/)\.local/bin/claude(?:\.exe)?$}i) {
            $method = "windows-native";
        }
    }

    emit("STATUS",          "ok");
    emit("CURRENT_VERSION", $version);
    emit("BINARY_PATH",     $binary_path // "");
    emit("INSTALL_METHOD",  $method);
}

sub cmd_manifest {
    my %args = parse_args(qw(--version --platform));
    my $version  = $args{"--version"}  or emit_error("Usage: manifest --version <V> [--platform <P>]");
    my $platform = $args{"--platform"} // $DEFAULT_PLATFORM;

    my $url = "$BASE_URL/$version/manifest.json";
    my ($status, $body) = http_get($url);
    if ($status != 200) {
        emit_error("Manifest fetch failed: HTTP $status from $url");
    }
    my $manifest = eval { decode_json($body) };
    if ($@ || !$manifest) {
        emit_error("Manifest JSON parse failed: $@");
    }
    my $pinfo = $manifest->{platforms}{$platform};
    unless ($pinfo) {
        emit_error("Platform $platform not present in manifest");
    }

    my $binary_name = $pinfo->{binary} // "claude.exe";
    my $binary_url  = "$BASE_URL/$version/$platform/$binary_name";

    emit("STATUS",     "ok");
    emit("CHECKSUM",   lc($pinfo->{checksum}));
    emit("SIZE",       $pinfo->{size});
    emit("BINARY_URL", $binary_url);
}

sub cmd_install {
    my %args = parse_args(qw(--version --platform));
    my $version  = $args{"--version"}  or emit_error("Usage: install --version <V> [--platform <P>]");
    my $platform = $args{"--platform"} // $DEFAULT_PLATFORM;

    # Fetch manifest
    my $manifest_url = "$BASE_URL/$version/manifest.json";
    my ($mstatus, $mbody) = http_get($manifest_url);
    if ($mstatus != 200) {
        emit_categorized("download_failed", "Manifest fetch failed: HTTP $mstatus from $manifest_url");
    }
    my $manifest = eval { decode_json($mbody) };
    if ($@) {
        emit_categorized("download_failed", "Manifest JSON parse failed: $@");
    }
    my $pinfo = $manifest->{platforms}{$platform};
    unless ($pinfo) {
        emit_categorized("download_failed", "Platform $platform not present in manifest");
    }
    my $expected_checksum = lc($pinfo->{checksum});
    my $binary_name       = $pinfo->{binary} // "claude.exe";
    my $binary_url        = "$BASE_URL/$version/$platform/$binary_name";

    # Prepare download path
    make_path($DOWNLOAD_DIR) unless -d $DOWNLOAD_DIR;
    my $ext = ($binary_name =~ /\.exe$/i) ? ".exe" : "";
    my $local_path = "$DOWNLOAD_DIR/claude-$version-$platform$ext";

    # Download
    my $dl_status = http_download($binary_url, $local_path);
    if ($dl_status != 200) {
        unlink $local_path if -e $local_path;
        emit_categorized("download_failed", "Binary download failed: HTTP $dl_status from $binary_url");
    }

    # Verify SHA256
    my $actual_checksum = sha256_file($local_path);
    if ($actual_checksum ne $expected_checksum) {
        unlink $local_path;
        emit_categorized(
            "checksum_mismatch",
            "Expected $expected_checksum, got $actual_checksum"
        );
    }

    # Capture installer stdout/stderr to log files
    make_path($TMP_DIR) unless -d $TMP_DIR;
    my $ts = strftime("%Y%m%dT%H%M%SZ", gmtime);
    my $stdout_path = "$TMP_DIR/install-$ts-stdout.log";
    my $stderr_path = "$TMP_DIR/install-$ts-stderr.log";

    my $cmd_str = sprintf(
        "%s install %s 1>%s 2>%s",
        shell_escape($local_path),
        shell_escape($version),
        shell_escape($stdout_path),
        shell_escape($stderr_path)
    );
    my $rc = system($cmd_str);
    my $exit_code = $rc >> 8;

    if ($exit_code != 0) {
        # Leave the downloaded binary in place for the user to inspect/retry.
        emit("STATUS",                "error");
        emit("ERROR",                 "installer_failed");
        emit("ERROR_DETAIL",          "Installer exited with code $exit_code");
        emit("BINARY_PATH",           $local_path);
        emit("SHA256",                $actual_checksum);
        emit("INSTALLER_EXIT",        $exit_code);
        emit("INSTALLER_STDOUT_PATH", $stdout_path);
        emit("INSTALLER_STDERR_PATH", $stderr_path);
        exit 1;
    }

    # Success: remove temp installer binary, keep logs
    unlink $local_path;

    emit("STATUS",                "ok");
    emit("BINARY_PATH",           $local_path);
    emit("SHA256",                $actual_checksum);
    emit("INSTALLER_EXIT",        $exit_code);
    emit("INSTALLER_STDOUT_PATH", $stdout_path);
    emit("INSTALLER_STDERR_PATH", $stderr_path);
}

sub cmd_verify {
    my %args = parse_args(qw(--expected));
    my $expected = $args{"--expected"} or emit_error("Usage: verify --expected <V>");

    my $out = qx(claude --version 2>&1);
    my $rc = $? >> 8;
    if ($rc != 0) {
        emit("STATUS",           "error");
        emit("EXPECTED_VERSION", $expected);
        emit("ERROR",            "claude --version failed (exit $rc): " . trim($out));
        exit 1;
    }
    my ($actual) = $out =~ /^(\d+\.\d+\.\d+)/;
    unless ($actual) {
        emit("STATUS",           "error");
        emit("EXPECTED_VERSION", $expected);
        emit("ERROR",            "Could not parse version from: " . trim($out));
        exit 1;
    }

    if ($actual eq $expected) {
        emit("STATUS",           "ok");
        emit("ACTUAL_VERSION",   $actual);
        emit("EXPECTED_VERSION", $expected);
    } else {
        emit("STATUS",           "mismatch");
        emit("ACTUAL_VERSION",   $actual);
        emit("EXPECTED_VERSION", $expected);
    }
}

sub cmd_help {
    print "Usage: update-install.pl <command> [args]\n\n";
    print "Commands:\n";
    print "  detect                                   Report installed version + method\n";
    print "  manifest --version <V> [--platform P]    Fetch manifest, emit checksum/size/url\n";
    print "  install --version <V> [--platform P]     Download binary, verify SHA256, run installer\n";
    print "  verify --expected <V>                    Confirm `claude --version` matches expected\n";
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

# install-specific error: includes a category and exits.
sub emit_categorized {
    my ($category, $detail) = @_;
    emit("STATUS",       "error");
    emit("ERROR",        $category);
    emit("ERROR_DETAIL", $detail);
    exit 1;
}

sub parse_args {
    my %valid = map { $_ => 1 } @_;
    my %got;
    my @rest;
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

sub find_binary_path {
    # Try `where claude` first (Windows command, available via cygwin).
    my $where_out = qx(where.exe claude 2>/dev/null);
    if (($? >> 8) == 0) {
        for my $line (split /\r?\n/, $where_out) {
            $line =~ s/^\s+|\s+$//g;
            next unless length $line;
            return $line if $line =~ /\.exe$/i;
        }
    }
    # Fall back to `which`
    my $which_out = qx(which claude 2>/dev/null);
    if (($? >> 8) == 0) {
        $which_out =~ s/[\r\n]+$//;
        return $which_out if length $which_out;
    }
    return "";
}

sub http_get {
    my $url = shift;
    my $ua  = HTTP::Tiny->new(timeout => 30);
    my $res = $ua->get($url);
    return ($res->{status}, $res->{content} // "");
}

sub http_download {
    my ($url, $path) = @_;
    my $ua = HTTP::Tiny->new(timeout => 600);
    open my $fh, ">", $path or return 500;
    binmode $fh;
    my $res = $ua->get(
        $url,
        {
            data_callback => sub {
                my ($chunk, $info) = @_;
                print $fh $chunk;
            }
        }
    );
    close $fh;
    return $res->{status};
}

sub sha256_file {
    my $path = shift;
    my $sha  = Digest::SHA->new(256);
    $sha->addfile($path);
    return lc($sha->hexdigest);
}

sub shell_escape {
    my $s = shift;
    $s =~ s/'/'\\''/g;
    return "'$s'";
}

sub trim {
    my $s = shift // "";
    $s =~ s/^\s+|\s+$//g;
    return $s;
}
