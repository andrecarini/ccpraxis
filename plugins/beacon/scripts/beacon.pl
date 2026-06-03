#!/usr/bin/env perl
# beacon.pl — mark Claude Code sessions as "ongoing work" for later resumption.
# Lives in the `beacon` plugin (plugins/beacon/scripts/beacon.pl). Used by the
# /beacon:on and /beacon:off skills (via ${CLAUDE_PLUGIN_ROOT}), by the
# claude-beacon launcher (in the same plugin's bin/), and by statusline.pl
# (which computes the on-disk path directly: ~/.claude/ccpraxis/plugins/beacon/
# scripts/beacon.pl on host; mounted into the sandbox by the sandbox-skills TUI
# as part of the plugin bundle).
#
# Beacon record schema (one JSON file per beacon):
#   session_id (uuid), schema_version, scope, sandbox_container, cwd,
#   git_root, project_slug, created_at, last_active_at, label, summary,
#   tags, auto_lit, host_machine.
#   host_project_path (optional, populated by scan_sandboxes_internal on
#   ingest of sandbox beacons — lets the launcher dispatch to
#   `claude-sandbox --resume-session <uuid> <host_project_path>` without
#   walking the registry; legacy records without it use the registry fallback).
#
# Subcommands:
#   light --session-id <uuid> [--label TEXT] [--scope auto|host|sandbox]
#                                          Write a beacon record
#   unbeacon --session-id <uuid>           Remove a beacon record
#   list  [--scope all|host|sandbox]
#         [--format kv|json]               List all beacons visible from here
#   get   --session-id <uuid>              Print one beacon record as JSON
#   update-activity --session-id <uuid>    Touch last_active_at on a beacon
#   count-project [--root <path>]          Count beacons for the current project
#   count-global                           Count (or read cached count of) all beacons
#   sync-vault [--no-lock]                 Ingest sandbox beacons + refresh
#                                          .global-count cache (fire-and-forget;
#                                          used by statusline.pl as a debounced bg job).
#                                          --no-lock skips the flock dance for
#                                          re-entrant callers (vault-sync.pl
#                                          sync-beacons) that already hold
#                                          beacons/.sync-vault.lock externally.
#   scan-sandboxes                         Standalone ingestion of sandbox beacons
#                                          into the vault (same logic as inside sync-vault)

use strict;
use warnings;
use utf8;
use POSIX qw(strftime);
use Cwd qw(getcwd);
use File::Basename qw(basename);
use File::Path qw(make_path);
use JSON::PP;
use Sys::Hostname qw(hostname);
use Encode qw(decode FB_CROAK);
use Fcntl qw(:flock);
use IPC::Open3 qw(open3);
use Symbol qw(gensym);
use Time::HiRes qw(usleep);

binmode STDOUT, ':utf8';

my $home = $ENV{HOME} // $ENV{USERPROFILE};
die "Cannot determine home directory\n" unless $home;
# Env-var bytes from cygwin/Git Bash are UTF-8; decoding sets the
# SVf_UTF8 flag so the :utf8 STDOUT layer encodes correctly instead of
# double-encoding the raw bytes — which is what produced the `AndrÃ©`
# mojibake observed in the PATH: lines emitted by `light`/`list`/`get`.
unless (utf8::is_utf8($home)) {
    my $decoded = eval { decode('UTF-8', $home, FB_CROAK) };
    $home = $decoded if defined $decoded && !$@;
}
$home =~ s/\\/\//g;

my $VAULT_DIR        = "$home/.claude/claude-code-vault";
my $VAULT_BEACON_DIR = "$VAULT_DIR/beacons";
my $REGISTRY_LOCAL   = "$VAULT_DIR/.registry-local.json";
my $GLOBAL_COUNT     = "$VAULT_BEACON_DIR/.global-count";

my $cmd = shift @ARGV // 'help';

if    ($cmd eq 'light')           { cmd_light()           }
elsif ($cmd eq 'unbeacon')        { cmd_unbeacon()        }
elsif ($cmd eq 'list')            { cmd_list()            }
elsif ($cmd eq 'get')             { cmd_get()             }
elsif ($cmd eq 'update-activity') { cmd_update_activity() }
elsif ($cmd eq 'count-project')   { cmd_count_project()   }
elsif ($cmd eq 'count-global')    { cmd_count_global()    }
elsif ($cmd eq 'sync-vault')      { cmd_sync_vault()      }
elsif ($cmd eq 'scan-sandboxes')  { cmd_scan_sandboxes()  }
else                              { cmd_help()            }

exit 0;

# ── Subcommands ─────────────────────────────────────────────

sub cmd_light {
    my $opts = parse_args(qw(session-id label scope));
    my $sid = require_sid($opts);

    my $scope = $opts->{scope} // 'auto';
    $scope = detect_scope() if $scope eq 'auto';
    die "ERROR: invalid --scope (host|sandbox|auto)\n" unless $scope =~ /^(host|sandbox)$/;

    my $dir = beacon_dir_for_scope($scope);
    make_path($dir) unless -d $dir;

    my $path = "$dir/$sid.json";

    my ($status_path, $status_slug) = with_lock("$path.lock", sub {
        my $now  = iso_now();
        my $auto_lit = $ENV{BEACON_AUTO_LIT} ? JSON::PP::true : JSON::PP::false;

        my $rec;
        if (-f $path) {
            $rec = eval { read_json($path) };
            if (!$rec) {
                # Corrupt — overwrite with a fresh record rather than crash.
                undef $rec;
            } else {
                $rec->{last_active_at} = $now;
                $rec->{label} = $opts->{label}
                    if defined $opts->{label} && length $opts->{label};
            }
        }
        unless ($rec) {
            my $cwd = norm_path(safe_getcwd());
            my $git_root = git_root($cwd);
            my $slug = project_slug($git_root, $cwd);

            $rec = {
                session_id        => $sid,
                schema_version    => 1,
                scope             => $scope,
                sandbox_container => $ENV{BEACON_CONTAINER} // undef,
                cwd               => $cwd,
                git_root          => $git_root,
                project_slug      => $slug,
                created_at        => $now,
                last_active_at    => $now,
                label             => (defined $opts->{label} && length $opts->{label}) ? $opts->{label} : undef,
                summary           => undef,
                tags              => [],
                auto_lit          => $auto_lit,
                host_machine      => hostname(),
            };
        }

        write_json($path, $rec);
        return ($path, $rec->{project_slug} // '');
    });

    emit('STATUS',     'lit');
    emit('PATH',       $status_path);
    emit('SESSION_ID', $sid);
    emit('SCOPE',      $scope);
    emit('SLUG',       $status_slug);
}

sub cmd_unbeacon {
    my $opts = parse_args(qw(session-id));
    my $sid = require_sid($opts);

    my $found = 0;
    for my $path (_all_locations_for($sid)) {
        next unless -f $path;
        with_lock("$path.lock", sub {
            # Re-check inside the lock — another process may have removed it.
            return unless -f $path;
            unless (unlink $path) {
                # ENOENT means somebody else removed it concurrently; treat as success.
                die "Cannot remove $path: $!\n" unless $!{ENOENT};
            }
            $found = 1;
        });
    }

    if ($found) {
        emit('STATUS',     'removed');
        emit('SESSION_ID', $sid);
    } else {
        emit('STATUS',     'not_found');
        emit('SESSION_ID', $sid);
        exit 2;
    }
}

sub cmd_list {
    my $opts = parse_args(qw(scope format));
    my $scope  = $opts->{scope}  // 'all';
    my $format = $opts->{format} // 'kv';

    my @records;
    if ($scope eq 'all' || $scope eq 'host') {
        push @records, _read_all_beacons($VAULT_BEACON_DIR);
    }
    if ($scope eq 'all' || $scope eq 'sandbox') {
        for my $proj_dir (sandbox_project_dirs()) {
            my $d = "$proj_dir/.claude-data/beacons";
            push @records, _read_all_beacons($d) if -d $d;
        }
    }

    @records = sort { ($b->{last_active_at} // '') cmp ($a->{last_active_at} // '') } @records;

    if ($format eq 'json') {
        # NB: `->utf8` is DELIBERATELY OMITTED here. `->utf8` makes encode
        # return UTF-8 bytes; printing those bytes through `binmode STDOUT,
        # ':utf8'` (set at the top of the script) treats each byte as a
        # Latin-1 codepoint and re-encodes to UTF-8 — the classic
        # double-encoding mojibake. Without `->utf8`, encode returns a
        # Unicode string that the `:utf8` STDOUT layer encodes correctly.
        print JSON::PP->new->pretty->canonical->encode(\@records);
        return;
    }

    for my $r (@records) {
        printf "BEACON: %s | scope:%s | slug:%s | last:%s | label:%s\n",
            $r->{session_id}, $r->{scope},
            ($r->{project_slug}   // ''),
            ($r->{last_active_at} // ''),
            ($r->{label}          // '');
    }
    emit('TOTAL', scalar @records);
}

sub cmd_get {
    my $opts = parse_args(qw(session-id));
    my $sid = require_sid($opts);

    for my $path (_all_locations_for($sid)) {
        next unless -f $path;
        my $rec = eval { read_json($path) };
        if ($@ || !$rec) {
            emit('STATUS', 'error');
            emit('ERROR',  "Cannot read $path: " . ($@ || 'unknown error'));
            exit 1;
        }
        # NB: `->utf8` omitted — see comment in cmd_list for rationale.
        print JSON::PP->new->pretty->canonical->encode($rec);
        return;
    }

    emit('STATUS',     'not_found');
    emit('SESSION_ID', $sid);
    exit 2;
}

sub cmd_update_activity {
    my $opts = parse_args(qw(session-id));
    my $sid = require_sid($opts);

    for my $path (_all_locations_for($sid)) {
        next unless -f $path;
        my $touched = with_lock("$path.lock", sub {
            return 0 unless -f $path;  # disappeared since the outer check
            my $rec = eval { read_json($path) };
            if ($@ || !$rec) {
                emit('STATUS', 'error');
                emit('ERROR',  "Cannot read $path: " . ($@ || 'unknown error'));
                exit 1;
            }
            $rec->{last_active_at} = iso_now();
            write_json($path, $rec);
            return 1;
        });
        if ($touched) {
            emit('STATUS',     'touched');
            emit('SESSION_ID', $sid);
            emit('PATH',       $path);
            return;
        }
    }

    emit('STATUS',     'not_found');
    emit('SESSION_ID', $sid);
    exit 2;
}

sub cmd_count_project {
    my $opts = parse_args(qw(root));
    my $cwd  = safe_getcwd();
    my $root = $opts->{root} // git_root($cwd) // norm_path($cwd);
    $root = norm_path($root);

    # Local (sandbox-style) beacons under <root>/.claude-data/beacons/
    my $local_dir = "$root/.claude-data/beacons";
    my $n_local   = -d $local_dir ? _count_json($local_dir) : 0;

    # Host-vault beacons attributed to this project (by git_root match)
    my $n_host = 0;
    if (-d $VAULT_BEACON_DIR) {
        for my $rec (_read_all_beacons($VAULT_BEACON_DIR)) {
            $n_host++ if defined $rec->{git_root} && $rec->{git_root} eq $root;
        }
    }

    emit('PROJECT_COUNT', $n_local + $n_host);
    emit('ROOT',          $root);
}

sub cmd_count_global {
    if (-f $GLOBAL_COUNT) {
        open my $fh, '<', $GLOBAL_COUNT or die "Cannot read $GLOBAL_COUNT: $!\n";
        my $n = <$fh>;
        close $fh;
        chomp $n if defined $n;
        $n = 0 unless defined $n && $n =~ /^\d+$/;
        emit('GLOBAL_COUNT', $n + 0);
        emit('SOURCE',       'cache');
        return;
    }

    my $n = -d $VAULT_BEACON_DIR ? _count_json($VAULT_BEACON_DIR) : 0;
    emit('GLOBAL_COUNT', $n);
    emit('SOURCE',       'walk');
}

sub cmd_sync_vault {
    # No args except the private --no-lock boolean flag (re-entrant callers
    # like `vault-sync.pl sync-beacons` that already hold .sync-vault.lock
    # use --no-lock to skip the flock dance; external callers don't pass it).
    # Two-step background sync intended for fire-and-forget invocation from
    # statusline.pl: (1) ingest any new/updated sandbox beacons into the
    # vault via scan_sandboxes_internal, then (2) refresh the .global-count
    # cache so statusline reads a fresh number on the next render. A non-
    # blocking flock dedupes concurrent runs (next render will retry).
    #
    # --no-lock contract: caller MUST hold beacons/.sync-vault.lock externally
    # via flock on that same file. We trust the caller; no verification here
    # because flock state isn't introspectable in portable Perl.
    my $no_lock = 0;
    @ARGV = grep { my $keep = ($_ ne '--no-lock'); $no_lock ||= !$keep; $keep } @ARGV;
    parse_args();  # consume/validate remaining argv (rejects unexpected args)

    unless (-d $VAULT_BEACON_DIR) {
        emit('STATUS', 'skipped');
        emit('REASON', 'vault beacons dir does not exist (sandbox or fresh install)');
        return;
    }

    my $lock_path = "$VAULT_BEACON_DIR/.sync-vault.lock";
    my $lock_fh;
    unless ($no_lock) {
        open $lock_fh, '>>', $lock_path or do {
            emit('STATUS', 'error');
            emit('ERROR',  "Cannot open sync lock $lock_path: $!");
            exit 1;
        };
        unless (flock($lock_fh, LOCK_EX | LOCK_NB)) {
            # Another sync is in progress — let it finish; the next statusline
            # render will see a fresh cache or fire again if still stale.
            close $lock_fh;
            emit('STATUS', 'busy');
            return;
        }
    }

    # Pass 1: ingest sandbox beacons. Errors are collected (not fatal) so a
    # single broken sandbox doesn't stop the count refresh.
    my ($copied, $skipped, $ingest_errs) = scan_sandboxes_internal();

    # Pass 2: count vault beacons and write the cache atomically. tmp+rename
    # so concurrent readers in statusline.pl never see a torn line.
    my $n = _count_json($VAULT_BEACON_DIR);
    my $tmp = "$GLOBAL_COUNT.tmp.$$";
    if (open my $fh, '>', $tmp) {
        print $fh "$n\n";
        close $fh;
        eval { atomic_rename($tmp, $GLOBAL_COUNT); };
        if ($@) {
            unlink $tmp;
            _release_sync_lock($lock_fh);
            emit('STATUS', 'error');
            emit('ERROR',  "atomic_rename failed: $@");
            exit 1;
        }
    } else {
        my $err = $!;
        _release_sync_lock($lock_fh);
        emit('STATUS', 'error');
        emit('ERROR',  "Cannot write $tmp: $err");
        exit 1;
    }

    _release_sync_lock($lock_fh);

    emit('STATUS',         'synced');
    emit('COUNT',          $n);
    emit('INGESTED',       $copied);
    emit('INGEST_SKIPPED', $skipped);
    if (@$ingest_errs) {
        emit('INGEST_ERRORS', scalar @$ingest_errs);
        emit('INGEST_ERROR',  $_) for @$ingest_errs;
    }
}

sub cmd_scan_sandboxes {
    # Standalone form of the ingestion logic. Useful for debugging and for
    # one-shot manual invocations. Doesn't refresh the count cache — use
    # sync-vault for the full pipeline.
    parse_args();

    unless (-d $VAULT_BEACON_DIR) {
        # On a host without a vault, there's nowhere to ingest to. On a
        # sandbox, this command is meaningless (no cross-sandbox visibility).
        emit('STATUS', 'skipped');
        emit('REASON', 'vault beacons dir does not exist');
        return;
    }

    my ($copied, $skipped, $errors) = scan_sandboxes_internal();
    emit('STATUS',  'scanned');
    emit('COPIED',  $copied);
    emit('SKIPPED', $skipped);
    emit('ERRORS',  scalar @$errors);
    emit('ERROR',   $_) for @$errors;
}

# Walk every registered sandbox project dir, copy any beacon JSON files into
# the vault that are missing OR newer (by last_active_at) than the vault copy.
# Per-record flock on $vault_path.lock so a concurrent /beacon light or
# /unbeacon targeting the same UUID can't lose updates. Conservative on
# malformed input: skip the record, collect the error, keep going.
#
# Release the sync-vault lock if we acquired it. When --no-lock is set we
# never opened a handle (caller holds the lock externally), so we no-op.
sub _release_sync_lock {
    my $fh = shift;
    return unless defined $fh;
    flock($fh, LOCK_UN);
    close $fh;
}

# Returns ($copied, $skipped, \@errors). NEVER dies — callers depend on this
# being safe to invoke from inside sync-vault's locked critical section.
sub scan_sandboxes_internal {
    my $copied  = 0;
    my $skipped = 0;
    my @errors;

    return ($copied, $skipped, \@errors) unless -d $VAULT_BEACON_DIR;

    for my $proj_dir (sandbox_project_dirs()) {
        my $src_dir = "$proj_dir/.claude-data/beacons";
        next unless -d $src_dir;

        my $dh;
        unless (opendir $dh, $src_dir) {
            push @errors, "Cannot read $src_dir: $!";
            next;
        }
        my @files = grep { /\.json$/ && !/^\./ } readdir $dh;
        closedir $dh;

        for my $f (@files) {
            my $src = "$src_dir/$f";
            my $dst = "$VAULT_BEACON_DIR/$f";

            my $src_rec = eval { read_json($src) };
            if ($@ || !$src_rec || ref($src_rec) ne 'HASH') {
                push @errors, "Cannot read $src: " . ($@ // 'malformed');
                next;
            }

            # Skip if vault already has a same-or-newer record. String compare
            # on ISO-8601 UTC strings is correct ordering.
            if (-f $dst) {
                my $dst_rec = eval { read_json($dst) };
                if ($dst_rec && ref($dst_rec) eq 'HASH'
                    && ($dst_rec->{last_active_at} // '') ge ($src_rec->{last_active_at} // '')) {
                    $skipped++;
                    next;
                }
            }

            # Stamp the host-side project dir on the record so the
            # claude-beacon launcher can dispatch to
            # `claude-sandbox --resume-session <uuid> <project>` without
            # walking the registry again. Schema-additive: legacy records
            # without this field still load, and the launcher has a
            # registry-walk fallback for them. The field gets populated
            # on the next ingest that bumps last_active_at.
            $src_rec->{host_project_path} = $proj_dir;

            my $ok = eval {
                with_lock("$dst.lock", sub { write_json($dst, $src_rec); });
                1;
            };
            if ($ok) {
                $copied++;
            } else {
                push @errors, "Cannot write $dst: " . ($@ // 'unknown');
            }
        }
    }

    return ($copied, $skipped, \@errors);
}

sub cmd_unimplemented {
    my $msg = shift;
    emit('STATUS', 'unimplemented');
    emit('REASON', $msg);
    exit 3;
}

sub cmd_help {
    print <<'EOH';
Usage: beacon.pl <command> [args]

Commands:
  light --session-id <uuid> [--label TEXT] [--scope auto|host|sandbox]
                                       Mark this session as ongoing work
  unbeacon --session-id <uuid>         Remove this session's beacon
  list  [--scope all|host|sandbox]
        [--format kv|json]             List all beacons visible from here
  get   --session-id <uuid>            Print one beacon record as JSON
  update-activity --session-id <uuid>  Touch last_active_at on a beacon
  count-project [--root <path>]        Count beacons for the current project
  count-global                         Count (or read cached count of) all beacons
  sync-vault [--no-lock]               Ingest sandbox beacons + refresh
                                       .global-count cache (LOCK_NB dedupe;
                                       fire-and-forget bg job for statusline).
                                       --no-lock is for re-entrant callers
                                       (vault-sync.pl sync-beacons) that
                                       already hold beacons/.sync-vault.lock.
  scan-sandboxes                       Standalone ingestion of sandbox beacons
                                       (same logic as inside sync-vault)

Env vars:
  BEACON_AUTO_LIT=1   Set when Claude self-invokes /beacon (vs user-initiated)
  BEACON_CONTAINER    Sandbox container name (set by claude-sandbox when applicable)
EOH
}

# ── Helpers ────────────────────────────────────────────────

sub emit {
    my ($key, $val) = @_;
    print "$key: $val\n";
}

sub iso_now {
    return strftime('%Y-%m-%dT%H:%M:%SZ', gmtime());
}

sub require_sid {
    my $opts = shift;
    my $sid = $opts->{'session-id'};
    unless (defined $sid && length $sid) {
        emit('STATUS', 'error');
        emit('ERROR',  '--session-id is required');
        exit 1;
    }
    unless ($sid =~ /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) {
        emit('STATUS', 'error');
        emit('ERROR',  "session ID must be a UUID (got: $sid)");
        exit 1;
    }
    return $sid;
}

sub detect_scope {
    # Vault is never mounted into a sandbox; its presence is the host signal.
    return (-d $VAULT_DIR) ? 'host' : 'sandbox';
}

sub beacon_dir_for_scope {
    my $scope = shift;
    return $VAULT_BEACON_DIR if $scope eq 'host';
    my $cwd  = safe_getcwd();
    my $root = git_root($cwd) // norm_path($cwd);
    return "$root/.claude-data/beacons";
}

sub git_root {
    my $cwd = shift;
    return undef unless defined $cwd && length $cwd;
    my ($out, $rc) = run_cmd('git', '-C', $cwd, 'rev-parse', '--show-toplevel');
    return undef if $rc != 0;
    chomp $out;
    return undef unless length $out;
    return norm_path($out);
}

# Spawn a child via IPC::Open3 (no shell) and return (stdout, exit_code).
# stderr is drained and discarded to avoid deadlocks; we don't surface it.
sub run_cmd {
    my @cmd = @_;
    my $stdin_fh  = gensym();
    my $stdout_fh = gensym();
    my $stderr_fh = gensym();
    my $pid = eval { open3($stdin_fh, $stdout_fh, $stderr_fh, @cmd) };
    return ('', -1) if !$pid || $@;
    close $stdin_fh;
    my $out = do { local $/; <$stdout_fh> } // '';
    # Drain stderr to keep the child from blocking on its pipe.
    do { local $/; <$stderr_fh> };
    close $stdout_fh;
    close $stderr_fh;
    waitpid($pid, 0);
    return ($out, $? >> 8);
}

sub safe_getcwd {
    my $cwd = getcwd();
    unless (defined $cwd && length $cwd) {
        emit('STATUS', 'error');
        emit('ERROR',  'Cannot determine current working directory (deleted?)');
        exit 1;
    }
    return $cwd;
}

sub norm_path {
    my $p = shift;
    return undef unless defined $p;
    # Paths arrive as byte strings; their encoding depends on source: git's
    # output is UTF-8, Windows getcwd() is system codepage (cp1252 here). Try
    # UTF-8 strict first; on failure, decode as cp1252 so non-ASCII paths
    # round-trip identically regardless of which API produced them.
    unless (utf8::is_utf8($p)) {
        my $decoded = eval { decode('UTF-8', $p, FB_CROAK) };
        if (defined $decoded && !$@) {
            $p = $decoded;
        } else {
            my $cp = eval { decode('cp1252', $p) };
            $p = $cp if defined $cp && !$@;
        }
    }
    $p =~ s/\\/\//g;
    return $p;
}

sub project_slug {
    my ($git_root, $cwd) = @_;
    my $needle = $git_root // $cwd;
    return undef unless defined $needle;
    $needle = norm_path($needle);

    if (-f $REGISTRY_LOCAL) {
        my $reg = eval { read_json($REGISTRY_LOCAL) };
        if ($reg && ref($reg->{projects}) eq 'HASH') {
            for my $slug (keys %{$reg->{projects}}) {
                my $p = $reg->{projects}{$slug}{path} // next;
                $p = norm_path($p);
                # Tolerate git-bash-style /c/... paths next to native C:/...
                my $alt = $p;
                $alt =~ s{^/([a-zA-Z])/}{$1:/};
                return $slug if $p eq $needle || $alt eq $needle;
            }
        }
    }
    return defined $git_root ? basename($git_root) : undef;
}

sub sandbox_project_dirs {
    return () unless -f $REGISTRY_LOCAL;
    my $reg = eval { read_json($REGISTRY_LOCAL) };
    return () unless $reg && ref($reg->{projects}) eq 'HASH';
    my @dirs;
    for my $slug (keys %{$reg->{projects}}) {
        my $p = $reg->{projects}{$slug}{path} // next;
        $p = norm_path($p);
        $p =~ s{^/([a-zA-Z])/}{$1:/};
        push @dirs, $p if -d $p;
    }
    return @dirs;
}

sub _all_locations_for {
    my $sid = shift;
    my @paths;
    push @paths, "$VAULT_BEACON_DIR/$sid.json";
    my $local = beacon_dir_for_scope('sandbox') . "/$sid.json";
    push @paths, $local unless grep { $_ eq $local } @paths;
    if (detect_scope() eq 'host') {
        for my $proj_dir (sandbox_project_dirs()) {
            push @paths, "$proj_dir/.claude-data/beacons/$sid.json";
        }
    }
    return @paths;
}

sub _read_all_beacons {
    my $dir = shift;
    return () unless -d $dir;
    opendir my $dh, $dir or return ();
    my @files = grep { /\.json$/ && !/^\./ } readdir $dh;
    closedir $dh;
    my @out;
    for my $f (@files) {
        my $rec = eval { read_json("$dir/$f") };
        push @out, $rec if $rec;
    }
    return @out;
}

sub _count_json {
    my $dir = shift;
    opendir my $dh, $dir or return 0;
    my $n = grep { /\.json$/ && !/^\./ } readdir $dh;
    closedir $dh;
    return $n;
}

sub read_json {
    my $path = shift;
    open my $fh, '<:raw', $path or die "Cannot read $path: $!\n";
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $obj = JSON::PP->new->utf8->max_depth(32)->allow_nonref(0)->decode($raw);
    die "Malformed JSON at $path: not an object/array\n" unless ref $obj;
    return $obj;
}

sub write_json {
    my ($path, $data) = @_;
    my $dir = $path; $dir =~ s{/[^/]+$}{};
    make_path($dir) unless -d $dir;
    my $tmp  = "$path.tmp.$$";
    my $json = JSON::PP->new->utf8->pretty->canonical->encode($data);
    open my $fh, '>:raw', $tmp or die "Cannot write $tmp: $!\n";
    print $fh $json;
    close $fh;
    atomic_rename($tmp, $path);
}

# POSIX rename(2) is atomic and replaces the target. Windows rename refuses
# to overwrite, so we fall back to unlink+rename — a small non-atomic window.
# True atomicity on Windows would require Win32API::File::MoveFileExW, which
# isn't core; the personal-tool threat model accepts the tiny window.
sub atomic_rename {
    my ($from, $to) = @_;
    return if rename $from, $to;
    my $err = $!;
    if ($^O eq 'MSWin32' && -f $to) {
        unlink $to or die "Cannot replace existing $to: $!\n";
        rename $from, $to or die "Cannot rename $from -> $to (after unlink): $!\n";
        return;
    }
    die "Cannot rename $from -> $to: $err\n";
}

# Per-resource exclusive lock built on flock. Lock file lives next to the
# protected target. On Windows flock is emulated but works for cooperating
# processes.
sub with_lock {
    my ($lock_path, $code) = @_;
    my $dir = $lock_path; $dir =~ s{/[^/]+$}{};
    make_path($dir) unless -d $dir;

    open my $lock_fh, '>>', $lock_path or die "Cannot open lock $lock_path: $!\n";
    my $acquired = 0;
    for (1..100) {  # ~5s @ 50ms
        if (flock($lock_fh, LOCK_EX | LOCK_NB)) {
            $acquired = 1;
            last;
        }
        usleep(50_000);
    }
    unless ($acquired) {
        close $lock_fh;
        emit('STATUS', 'error');
        emit('ERROR',  "Cannot acquire lock on $lock_path after 5s");
        exit 1;
    }

    my @result = eval { wantarray ? $code->() : scalar $code->() };
    my $err = $@;
    flock($lock_fh, LOCK_UN);
    close $lock_fh;
    die $err if $err;
    return wantarray ? @result : $result[0];
}

sub parse_args {
    my @known = @_;
    my %known = map { $_ => 1 } @known;
    my %opts;
    while (my $arg = shift @ARGV) {
        unless ($arg =~ /^--([\w-]+)$/ && $known{$1}) {
            emit('STATUS', 'error');
            emit('ERROR',  "Unknown or unexpected argument: $arg");
            exit 1;
        }
        my $key = $1;
        my $val = shift @ARGV;
        unless (defined $val) {
            emit('STATUS', 'error');
            emit('ERROR',  "Flag --$key requires a value");
            exit 1;
        }
        if ($val =~ /^--/) {
            emit('STATUS', 'error');
            emit('ERROR',  "Flag --$key requires a value (got another flag: $val)");
            exit 1;
        }
        # Decode argv as UTF-8 — on cygwin/Git Bash @ARGV arrives as raw
        # UTF-8 bytes (no SVf_UTF8). Without this, a label like `→` is
        # stored as 3 raw bytes \xE2\x86\x92 that JSON::PP later treats
        # as 3 separate Latin-1 codepoints → output mojibake.
        unless (utf8::is_utf8($val)) {
            my $d = eval { decode('UTF-8', $val, FB_CROAK) };
            $val = $d if defined $d && !$@;
        }
        $opts{$key} = $val;
    }
    return \%opts;
}
