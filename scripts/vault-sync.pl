#!/usr/bin/env perl
# vault-sync.pl — Central engine for claude-code-vault project backups.
#
# Owns all logic for registering projects, walking tracked paths, bidirectional
# 3-way sync with backup-cache as merge base, locking, journaling, atomic
# staging, conflict resolution, and commit/push.
#
# Skills only orchestrate: call subcommands, parse structured output, present
# AskUserQuestion to the user. No LLM reasoning about files, hashes, or merges.
#
# Subcommands:
#   init             --url <repo-url>
#   propose-slugs    --cwd <path>
#   detect-trackable --cwd <path>
#   is-registered    --cwd <path>
#   register --fresh --cwd <path> --slug <s> --files <comma-list>
#   register --link  --cwd <path> --slug <s>
#   unregister       --slug <s>
#   list-projects
#   list-orphans
#   sync-project     --slug <s>
#   resolve-conflict --slug <s> --path <p> --action use-local|use-vault|use-merged [--merged-file <f>]
#   commit-and-push  --slug <s>
#   sync-beacons                            (vault-root beacons/ — separate from per-project content)

use strict;
use warnings;
use POSIX qw(strftime);
use Cwd qw(getcwd abs_path);
use File::Basename qw(basename dirname);
use File::Spec;
use File::Path qw(make_path remove_tree);
use File::Find;
use File::Copy qw(copy move);
use Digest::SHA qw(sha256_hex);
use JSON::PP;
use Sys::Hostname qw(hostname);
use Encode qw(decode encode);
use Fcntl qw(:flock O_CREAT O_RDWR);

# STDOUT stays in raw byte mode. JSON::PP->utf8 below emits UTF-8 bytes directly.
# All string values are decoded from UTF-8 to Perl chars at JSON emit/write boundaries
# (see _decode_strings_recursive). This avoids the classic "double-encode" trap when
# input paths arrive as UTF-8 byte strings (e.g. from --cwd on a system where filenames
# contain non-ASCII).

# ── Constants ───────────────────────────────────────────────────────

my $home = $ENV{HOME} // $ENV{USERPROFILE};
die "Cannot determine home directory\n" unless $home;
$home = norm_path($home);

my $VAULT_DIR        = "$home/.claude/claude-code-vault";
my $VAULT_BEACON_DIR = "$VAULT_DIR/beacons";
my $REGISTRY_PATH    = "$VAULT_DIR/.registry-local.json";
my $VAULT_LOCK       = "$VAULT_DIR/.lock";
my $BRANCH           = "main";
my $TMP_SUFFIX    = ".vault-sync.tmp";
my $LOCK_STALE_SEC = 30 * 60;  # 30 minutes
my $REGISTRY_VERSION = 1;

# Default-ON files (relative to project cwd). Order preserved for UX.
my @DEFAULT_TRACKABLE = qw(
    CLAUDE.md
    .claude/CLAUDE.md
    .claude/skills
    .claude/agents
    .claude/hooks
    .claude/commands
    .claude/plans
    .claude-plans
    .claude-data/memory
    .claude-data/plans
    .claude-data/backpack.json
    .ccpraxis-local-data/blueprints
);

# Hard-excludes — relative paths. Enforced at walk time AND at register-time.
# All comparisons are case-insensitive (see is_hard_excluded) — store entries lowercase.
my %HARD_EXCLUDE_EXACT = map { $_ => 1 } qw(
    .claude/settings.local.json
    deploy_key
);

# Hard-exclude prefixes — any tracked file whose relative path starts with one of these is dropped.
my @HARD_EXCLUDE_PREFIXES = (
    '.claude-data/git-pat',
    '.claude-data/git-askpass.sh',
    '.claude-data/git-ssh-command.sh',
);

# Hard-exclude regexes — matched (case-insensitively, against the lowercased rel
# path) when a fixed prefix can't express the rule. The blueprint name is a
# variable path component, so the machine-local butler execution dir
# `.ccpraxis-local-data/blueprints/<name>/runs/` (session ids, pids, jsonl stream
# logs, markers) needs a pattern: it's meaningless on another machine and the
# stream logs can be large and carry transient secrets. The authored files
# (blueprint.md, packages/, specs/, reports/) are backed up; runs/ is not.
my @HARD_EXCLUDE_REGEX = (
    qr{^\.ccpraxis-local-data/blueprints/[^/]+/runs(?:/|$)},
);

my $SCRIPT_DIR = abs_path(dirname(__FILE__));
my $SENSITIVE_CHECK = "$home/.claude/ccpraxis/skills/backup/scripts/sensitive-check.sh";

# Perl-native secret patterns — mirror sensitive-check.sh. Defined here (before the
# dispatcher) so that the `my` initializer actually runs before any subcommand calls
# scan_files_for_secrets. (File-scope `my` runs its initializer in source order.)
# v1.1.11: prefix-only patterns now require a sufficient suffix run so that
# documentation mentions of the prefix (e.g. `sk-ant-...` in a markdown line
# describing what the pattern is) don't false-flag. Real secrets always have
# 16+ chars of entropy after the prefix.
my @SECRET_PATTERNS = (
    [ 'sk-ant-',                qr/sk-ant-[a-zA-Z0-9_-]{16,}/ ],
    [ 'generic sk- key',        qr/sk-[a-zA-Z0-9]{20,}/ ],
    [ 'Google API key',         qr/AIza[a-zA-Z0-9_-]{20,}/ ],
    [ 'Bearer token',           qr/Bearer [a-zA-Z0-9_.\-]{16,}/ ],
    [ 'accessToken',            qr/accessToken/ ],
    [ 'PRIVATE KEY',            qr/PRIVATE KEY/ ],
    [ 'hardcoded password',     qr/[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]\s*[:=]/ ],
    [ 'hardcoded secret',       qr/[Ss][Ee][Cc][Rr][Ee][Tt]\s*[:=]/ ],
    [ 'Sentry DSN',             qr/dsn.*sentry/i ],
    [ 'Sentry ingest URL',      qr{https://[^"]*\@[^"]*\.ingest\.} ],
    [ 'credentials_json',       qr/credentials_json/ ],
);

# Fix M3 (red-team): suppression is a substring match (literal), so 'credentials_json.*secrets'
# would never fire because no real line contains the literal '.*'. Kept the two genuine
# template-placeholder suppressions; dropped the broken regex-shaped entry.
my @SECRET_FALSE_POSITIVE_SUBSTRINGS = (
    '{accessToken}',
    '>{accessToken}',
);

# ── Signal handlers ─────────────────────────────────────────────────

my %HELD_LOCKS;  # path => session_id (for cleanup)
my $SESSION_ID = generate_session_id();

$SIG{INT}  = sub { release_all_held_locks(); exit 130; };
$SIG{TERM} = sub { release_all_held_locks(); exit 143; };
END { release_all_held_locks(); }

# ── Dispatcher ──────────────────────────────────────────────────────

my $cmd = shift @ARGV // 'help';

if    ($cmd eq 'init')              { cmd_init() }
elsif ($cmd eq 'propose-slugs')     { cmd_propose_slugs() }
elsif ($cmd eq 'detect-trackable')  { cmd_detect_trackable() }
elsif ($cmd eq 'is-registered')     { cmd_is_registered() }
elsif ($cmd eq 'ensure-tracked')    { cmd_ensure_tracked() }
elsif ($cmd eq 'register')          { cmd_register() }
elsif ($cmd eq 'unregister')        { cmd_unregister() }
elsif ($cmd eq 'list-projects')     { cmd_list_projects() }
elsif ($cmd eq 'list-orphans')      { cmd_list_orphans() }
elsif ($cmd eq 'vault-files')       { cmd_vault_files() }
elsif ($cmd eq 'status')            { cmd_status() }
elsif ($cmd eq 'sync-project')      { cmd_sync_project() }
elsif ($cmd eq 'resolve-conflict')  { cmd_resolve_conflict() }
elsif ($cmd eq 'commit-and-push')   { cmd_commit_and_push() }
elsif ($cmd eq 'sync-beacons')      { cmd_sync_beacons() }
else                                { cmd_help() }

exit 0;

# ═══════════════════════════════════════════════════════════════════════
# Subcommands
# ═══════════════════════════════════════════════════════════════════════

sub cmd_help {
    print <<'EOF';
Usage: vault-sync.pl <subcommand> [args]

Setup:
  init             --url <repo-url>

Discovery:
  propose-slugs    --cwd <path>
  detect-trackable --cwd <path>
  is-registered    --cwd <path>
  vault-files      --slug <s>           (lists files in vault for preview)
  status                                (consolidated dashboard JSON)

Registration:
  register --fresh --cwd <path> --slug <s> --files <comma-list>
  register --link  --cwd <path> --slug <s>
  ensure-tracked   --slug <s> --path <rel>   (idempotent local add to tracked_paths)
  unregister       --slug <s>
  list-projects
  list-orphans

Sync:
  sync-project     --slug <s>
  resolve-conflict --slug <s> --path <p> --action use-local|use-vault|use-merged [--merged-file <f>]
  commit-and-push  --slug <s>

Beacons (vault-root data, separate from per-project content):
  sync-beacons                          Pre-flight beacon.pl sync-vault, scan, commit + push beacons/
EOF
}

# ── init ────────────────────────────────────────────────────────────

sub cmd_init {
    my %opts = parse_opts(\@ARGV, qw(url));
    my $url  = require_opt(\%opts, 'url');

    # Already initialized?
    if (-d "$VAULT_DIR/.git") {
        my $current_remote = vault_git_output('remote', 'get-url', 'origin');
        if ($current_remote && $current_remote eq $url) {
            emit_json({
                status     => 'already_initialized',
                vault_dir  => $VAULT_DIR,
                remote     => $current_remote,
            });
            return;
        } elsif ($current_remote) {
            emit_error("Vault already exists at $VAULT_DIR with remote '$current_remote', but --url was '$url'. Move the existing clone aside or update its remote with 'git remote set-url origin <new>'.");
        } else {
            emit_error("Vault at $VAULT_DIR has a .git dir but no origin remote. Inspect manually.");
        }
    }

    if (-e $VAULT_DIR) {
        emit_error("$VAULT_DIR exists but is not a git repo. Move it aside before running init.");
    }

    # Verify remote is reachable
    unless (git_ok_raw('ls-remote', $url)) {
        emit_error("Cannot reach remote: $url. Check the URL and credentials.");
    }

    # Clone
    unless (git_ok_raw('clone', $url, $VAULT_DIR)) {
        emit_error("Clone failed for: $url");
    }

    # If empty repo (no commits yet), scaffold the vault layout.
    unless (vault_git_ok('rev-parse', 'HEAD')) {
        write_file_text("$VAULT_DIR/README.md",
            "# claude-code-vault\n\nPersonal Claude Code backup repo — todos and project-scoped files.\nManaged by `vault-sync.pl` and `todo-sync.pl` in ccpraxis.\n");
        write_file_text("$VAULT_DIR/.gitignore",
            "# Machine-local registry — maps slug → absolute project path on THIS machine.\n" .
            "/.registry-local.json\n\n" .
            "# Lock files (vault + per-project) used to prevent concurrent syncs.\n" .
            "# .flock sentinels hold the OS-level flock mutex; .lock holds visible metadata.\n" .
            "/.lock\n" .
            "/.lock.flock\n" .
            "projects/*/.lock\n" .
            "projects/*/.lock.flock\n\n" .
            "# In-flight sync journals — cleared on successful commit; reconciled on next sync.\n" .
            "projects/*/.sync-journal.json\n\n" .
            "# Atomic staging tmps and merge tmps written by vault-sync.pl.\n" .
            "*.vault-sync.tmp\n" .
            "projects/*/.merge-*.tmp\n" .
            "projects/*/.empty-*.tmp\n");
        write_file_text("$VAULT_DIR/.gitattributes",
            "# Treat all files as binary to defeat CRLF normalization.\n" .
            "# Vault stores byte-exact copies of tracked project files; any normalization\n" .
            "# would break hash comparison during sync.\n" .
            "* -text\n");
        make_path("$VAULT_DIR/todos") unless -d "$VAULT_DIR/todos";
        write_file_text("$VAULT_DIR/todos/.gitkeep", "");

        vault_git_ok('add', 'README.md', '.gitignore', '.gitattributes', 'todos/.gitkeep')
            or emit_error("git add failed during vault scaffold");
        vault_git_ok('commit', '-m', 'Initial vault scaffold (README, .gitignore, .gitattributes, todos/)')
            or emit_error("git commit failed during vault scaffold");
        vault_git_ok('push', '-u', 'origin', $BRANCH)
            or emit_error("git push failed during vault scaffold");
    }

    emit_json({
        status     => 'initialized',
        vault_dir  => $VAULT_DIR,
        remote     => $url,
    });
}

sub git_ok_raw {
    # Like vault_git_ok but doesn't pass -C (used for clone/ls-remote where there's no repo yet).
    return _run_silent('git', @_) == 0;
}

sub write_file_text {
    my ($path, $content) = @_;
    make_path(dirname($path));
    open my $fh, '>:raw', $path or die "Cannot write $path: $!\n";
    print $fh $content;
    close $fh;
}

# ── propose-slugs ───────────────────────────────────────────────────

sub cmd_propose_slugs {
    my %opts = parse_opts(\@ARGV, qw(cwd));
    my $cwd = require_opt(\%opts, 'cwd');
    $cwd = norm_path(abs_path($cwd) // $cwd);

    my @candidates;
    my $base   = sanitize_slug(basename($cwd));
    my $parent = sanitize_slug(basename(dirname($cwd)));

    push @candidates, $base if length $base;
    push @candidates, "$parent-$base" if length $parent && length $base && $parent ne $base;
    push @candidates, "$base-" . random_suffix(4) if length $base;

    # De-dupe while preserving order, drop empties, validate
    my %seen;
    my @final = grep { length && validate_slug($_) && !$seen{$_}++ } @candidates;

    # Ensure at least one candidate
    @final = ('project-' . random_suffix(6)) unless @final;

    emit_json({
        candidates => \@final,
        cwd        => $cwd,
    });
}

# ── detect-trackable ────────────────────────────────────────────────

sub cmd_detect_trackable {
    my %opts = parse_opts(\@ARGV, qw(cwd));
    my $cwd = require_opt(\%opts, 'cwd');
    $cwd = norm_path(abs_path($cwd) // $cwd);

    my @found;
    for my $rel (@DEFAULT_TRACKABLE) {
        my $abs = "$cwd/$rel";
        next unless -e $abs;
        my $is_dir = -d $abs;
        my $size = $is_dir ? dir_size($abs) : (-s $abs // 0);
        push @found, {
            path   => $rel,
            type   => $is_dir ? 'dir' : 'file',
            size   => $size + 0,
            exists => JSON::PP::true,
        };
    }

    emit_json({
        cwd       => $cwd,
        trackable => \@found,
    });
}

# ── ensure-tracked ──────────────────────────────────────────────────
# Idempotently add a relative path to a registered project's LOCAL tracked_paths
# (.claude/backup-metadata.json), which is what sync-project walks. Local-only by
# design: no vault git writes, so it can't cause vault drift and needs no network.
# The path's files get copied into the vault on the next /backup. Use case: a new
# default-tracked path (e.g. .ccpraxis-local-data/blueprints) added after a project
# was already registered — the per-project tracked_paths is frozen at registration,
# so changing @DEFAULT_TRACKABLE alone doesn't reach existing projects.
sub cmd_ensure_tracked {
    my %opts = parse_opts(\@ARGV, qw(slug path));
    my $slug = require_opt(\%opts, 'slug');
    my $path = require_opt(\%opts, 'path');
    emit_error("--path must be a relative path inside the project") unless validate_relative_path($path);

    my $reg   = read_registry();
    my $entry = $reg->{projects}{$slug};
    emit_error("Slug '$slug' is not registered on this machine.") unless $entry;

    my $pmpath = project_metadata_path($entry->{path});
    emit_error("Project metadata missing at $pmpath") unless -f $pmpath;
    my $pmeta = read_json($pmpath);
    my @tp = @{ $pmeta->{tracked_paths} // [] };

    if (grep { $_ eq $path } @tp) {
        emit_json({ status => 'already_tracked', slug => $slug, path => $path, tracked_paths => \@tp });
        return;
    }
    push @tp, $path;
    $pmeta->{tracked_paths} = \@tp;
    write_json($pmpath, $pmeta);
    emit_json({
        status        => 'tracked_added',
        slug          => $slug,
        path          => $path,
        tracked_paths => \@tp,
        note          => "Added to this machine's project metadata; backed up on the next /backup. Vault-side metadata (cross-machine restore hints) is updated by the normal register/link flow.",
    });
}

# ── is-registered ───────────────────────────────────────────────────

sub cmd_is_registered {
    my %opts = parse_opts(\@ARGV, qw(cwd));
    my $cwd = require_opt(\%opts, 'cwd');
    $cwd = norm_path(abs_path($cwd) // $cwd);

    my $meta_path = project_metadata_path($cwd);
    if (-f $meta_path) {
        my $meta = read_json($meta_path);
        emit_json({
            registered => JSON::PP::true,
            slug       => $meta->{slug},
            cwd        => $cwd,
        });
    } else {
        emit_json({
            registered => JSON::PP::false,
            cwd        => $cwd,
        });
    }
}

# ── register (--fresh | --link) ─────────────────────────────────────

sub cmd_register {
    my %opts = parse_opts(\@ARGV, qw(fresh link cwd slug files));

    if (!$opts{fresh} && !$opts{link}) {
        emit_error("register requires --fresh or --link");
    }
    if ($opts{fresh} && $opts{link}) {
        emit_error("register: --fresh and --link are mutually exclusive");
    }

    my $cwd  = require_opt(\%opts, 'cwd');
    my $slug = require_opt(\%opts, 'slug');
    $cwd = norm_path(abs_path($cwd) // $cwd);

    unless (validate_slug($slug)) {
        emit_error("Invalid slug: '$slug'. Must match [a-z0-9-]+ (and not start/end with '-').");
    }

    # Already registered?
    if (-f project_metadata_path($cwd)) {
        emit_error("Project at $cwd is already registered (found .claude/backup-metadata.json).");
    }

    if ($opts{fresh}) {
        register_fresh($cwd, $slug, $opts{files} // '');
    } else {
        register_link($cwd, $slug);
    }
}

sub register_fresh {
    my ($cwd, $slug, $files_csv) = @_;

    # Validate slug isn't already in vault
    if (-d vault_project_dir($slug)) {
        emit_error("Slug '$slug' already exists in vault. Use --link to restore it, or pick a different slug.");
    }

    # Parse and validate file list
    my @files = split /,/, $files_csv;
    @files = grep { length } map { s/^\s+|\s+$//gr } @files;
    unless (@files) {
        emit_error("register --fresh requires --files <comma-list> (at least one tracked path).");
    }
    for my $rel (@files) {
        unless (validate_relative_path($rel)) {
            emit_error("Invalid tracked path: '$rel'. Must be relative, no '..', no absolute path.");
        }
        if (is_hard_excluded($rel)) {
            emit_error("Tracked path '$rel' is hard-excluded (credentials/machine-specific).");
        }
        my $abs = "$cwd/$rel";
        unless (-e $abs) {
            emit_error("Tracked path '$rel' does not exist at $cwd.");
        }
    }

    acquire_lock($VAULT_LOCK) or emit_error("Vault lock held by another session.");

    # Pull latest before adding our new project entry (avoid push conflict)
    vault_git_ok('fetch', 'origin');
    vault_git_ok('pull', '--rebase', 'origin', $BRANCH);

    # Create vault project dir + metadata
    my $vproj = vault_project_dir($slug);
    make_path("$vproj/files") unless -d "$vproj/files";

    my $now = iso_now();
    my $remote_url = '';
    my ($_url, $_url_exit) = _run_capture('git', '-C', $cwd, 'remote', 'get-url', 'origin');
    $remote_url = $_url if $_url_exit == 0;

    my $vmeta = {
        slug         => $slug,
        created_at   => $now,
        tracked_paths => \@files,
        source_notes => [{
            machine       => hostname(),
            basename      => basename($cwd),
            remote_url    => $remote_url || undef,
            registered_at => $now,
        }],
    };
    write_json("$vproj/metadata.json", $vmeta);

    # Project metadata + cache dir
    my $pmeta = {
        slug              => $slug,
        registered_at     => $now,
        last_synced_at    => undef,
        tracked_paths     => \@files,
        last_synced_hashes => {},
    };
    make_path(dirname(project_metadata_path($cwd)));
    write_json(project_metadata_path($cwd), $pmeta);
    make_path(cache_root($cwd));

    # Gitignore updates (project)
    ensure_gitignored($cwd, '.claude/backup-metadata.json');
    ensure_gitignored($cwd, '.claude/backup-cache/');

    # Registry
    registry_add_project($slug, $cwd, $now);

    # Commit + push the new vault entry so subsequent syncs start from clean vault state.
    # Fix H10 (red-team): on ANY failure here, roll back all the local state we
    # wrote (project metadata, cache, registry, vault dir) so the user can re-run
    # cleanly instead of being stuck in a half-registered limbo.
    my $rollback = sub {
        my $why = shift;
        unlink project_metadata_path($cwd) if -f project_metadata_path($cwd);
        remove_tree(cache_root($cwd)) if -d cache_root($cwd);
        registry_remove_project($slug);
        remove_tree($vproj) if -d $vproj;
        # Also undo any git-staged state from this attempt so the next run
        # doesn't see drift.
        vault_git_ok('reset', '--', "projects/$slug/");
        vault_git_ok('clean', '-fd', '--', "projects/$slug/");
        emit_error("$why — register rolled back; local and vault state restored. Re-run /steward:setup to try again.");
    };

    unless (vault_git_ok('add', '--', "projects/$slug/")) {
        $rollback->("git add failed for projects/$slug/");
    }
    # Fix M1 (red-team): omit hostname from commit message — it leaks internal machine
    # names into permanent git history. Machine attribution is already in
    # projects/<slug>/metadata.json → source_notes[].machine, which can be sanitized
    # separately if the user wants.
    my $msg = "Register $slug";
    unless (vault_git_ok('commit', '-m', $msg)) {
        $rollback->("git commit failed during register (vault may have unrelated dirt)");
    }
    unless (vault_git_ok('push', 'origin', $BRANCH)) {
        # Reset the local commit too so the next register attempt starts clean.
        vault_git_ok('reset', '--hard', 'HEAD~1');
        $rollback->("git push failed during register");
    }

    emit_json({
        status        => 'registered_fresh',
        slug          => $slug,
        cwd           => $cwd,
        tracked_paths => \@files,
        vault_dir     => $vproj,
    });
}

sub register_link {
    my ($cwd, $slug) = @_;

    acquire_lock($VAULT_LOCK) or emit_error("Vault lock held by another session.");

    # Pull latest before mutating vault metadata
    vault_git_ok('fetch', 'origin');
    vault_git_ok('pull', '--rebase', 'origin', $BRANCH);

    # Validate slug exists in vault
    my $vproj = vault_project_dir($slug);
    unless (-f "$vproj/metadata.json") {
        emit_error("Slug '$slug' not found in vault at $vproj. Use list-orphans to find available slugs, or --fresh to create a new one.");
    }

    my $vmeta = read_json("$vproj/metadata.json");
    my $now = iso_now();
    my $remote_url = '';
    my ($_url, $_url_exit) = _run_capture('git', '-C', $cwd, 'remote', 'get-url', 'origin');
    $remote_url = $_url if $_url_exit == 0;

    # Append source_note for this machine
    push @{$vmeta->{source_notes}}, {
        machine       => hostname(),
        basename      => basename($cwd),
        remote_url    => $remote_url || undef,
        registered_at => $now,
    };
    write_json("$vproj/metadata.json", $vmeta);

    # Project metadata + empty cache (so first sync triggers proper merge against empty base)
    my $pmeta = {
        slug               => $slug,
        registered_at      => $now,
        last_synced_at     => undef,
        tracked_paths      => $vmeta->{tracked_paths},
        last_synced_hashes => {},
    };
    make_path(dirname(project_metadata_path($cwd)));
    write_json(project_metadata_path($cwd), $pmeta);
    make_path(cache_root($cwd));

    ensure_gitignored($cwd, '.claude/backup-metadata.json');
    ensure_gitignored($cwd, '.claude/backup-cache/');

    registry_add_project($slug, $cwd, $now);

    # Commit + push the updated vault metadata (new source_note).
    # Fix H10 (red-team): rollback on failure (see register_fresh).
    my $rollback = sub {
        my $why = shift;
        unlink project_metadata_path($cwd) if -f project_metadata_path($cwd);
        remove_tree(cache_root($cwd)) if -d cache_root($cwd);
        registry_remove_project($slug);
        # Vault metadata.json was modified — restore from HEAD so the source_note we added is rolled back.
        vault_git_ok('checkout', '--', "projects/$slug/metadata.json");
        emit_error("$why — link rolled back; local state restored. Vault is untouched. Re-run /steward:setup to try again.");
    };

    vault_git_ok('add', '--', "projects/$slug/metadata.json")
        or $rollback->("git add failed for projects/$slug/metadata.json");
    # Fix M1 (red-team): omit hostname from commit message (see register_fresh).
    my $msg = "Link $slug";
    vault_git_ok('commit', '-m', $msg)
        or $rollback->("git commit failed during link");
    unless (vault_git_ok('push', 'origin', $BRANCH)) {
        vault_git_ok('reset', '--hard', 'HEAD~1');
        $rollback->("git push failed during link");
    }

    emit_json({
        status        => 'registered_link',
        slug          => $slug,
        cwd           => $cwd,
        tracked_paths => $vmeta->{tracked_paths},
        vault_dir     => $vproj,
    });
}

# ── unregister ──────────────────────────────────────────────────────

sub cmd_unregister {
    my %opts = parse_opts(\@ARGV, qw(slug));
    my $slug = require_opt(\%opts, 'slug');

    my $reg = read_registry();
    my $entry = $reg->{projects}{$slug};
    unless ($entry) {
        emit_error("Slug '$slug' not in registry on this machine.");
    }

    my $cwd = $entry->{path};

    # Remove project-side metadata + cache (keep vault contents intact)
    my $meta = project_metadata_path($cwd);
    unlink $meta if -f $meta;
    remove_tree(cache_root($cwd)) if -d cache_root($cwd);

    registry_remove_project($slug);

    emit_json({
        status => 'unregistered',
        slug   => $slug,
        cwd    => $cwd,
        note   => 'Vault contents preserved. Use list-orphans to find this slug, or rm vault/projects/<slug>/ to delete from vault.',
    });
}

# ── list-projects ───────────────────────────────────────────────────

sub cmd_list_projects {
    my $reg = read_registry();
    my @out;
    for my $slug (sort keys %{$reg->{projects}}) {
        my $entry = $reg->{projects}{$slug};
        my $pmeta_path = project_metadata_path($entry->{path});
        my $last_synced_at = undef;
        if (-f $pmeta_path) {
            my $pmeta = eval { read_json($pmeta_path) };
            $last_synced_at = $pmeta->{last_synced_at} if $pmeta;
        }
        push @out, {
            slug           => $slug,
            path           => $entry->{path},
            registered_at  => $entry->{registered_at},
            last_synced_at => $last_synced_at,
            project_exists => (-d $entry->{path}) ? JSON::PP::true : JSON::PP::false,
        };
    }
    emit_json({ projects => \@out });
}

# ── list-orphans ────────────────────────────────────────────────────

sub cmd_list_orphans {
    my $reg = read_registry();
    my %known = map { $_ => 1 } keys %{$reg->{projects}};

    my @orphans;
    my $vault_projects = "$VAULT_DIR/projects";
    if (-d $vault_projects) {
        opendir my $dh, $vault_projects or die "Cannot read $vault_projects: $!\n";
        for my $entry (sort readdir $dh) {
            next if $entry =~ /^\.\.?$/;
            next unless -d "$vault_projects/$entry";
            next if $known{$entry};
            my $mpath = "$vault_projects/$entry/metadata.json";
            next unless -f $mpath;
            my $meta = eval { read_json($mpath) };
            next unless $meta;

            my ($fcount, $tsize) = vault_files_stats("$vault_projects/$entry/files");
            push @orphans, {
                slug         => $entry,
                created_at   => $meta->{created_at},
                source_notes => $meta->{source_notes} // [],
                file_count   => $fcount,
                total_size   => $tsize,
                tracked_paths => $meta->{tracked_paths} // [],
            };
        }
        closedir $dh;
    }

    emit_json({ orphans => \@orphans });
}

# ── status ──────────────────────────────────────────────────────────

# Consolidated dashboard JSON for skill consumption. Combines vault state,
# every registered project's sync/journal/lock status, and orphan count.
sub cmd_status {
    my $reg = read_registry();
    my @projects;

    my $vault_exists = -d "$VAULT_DIR/.git";
    my %vault = (
        exists      => $vault_exists ? JSON::PP::true : JSON::PP::false,
        path        => $VAULT_DIR,
    );
    if ($vault_exists) {
        $vault{remote} = vault_git_output('remote', 'get-url', 'origin') || undef;
        $vault{clean}  = (vault_git_output('status', '--porcelain') eq '') ? JSON::PP::true : JSON::PP::false;
        my ($ahead, $behind) = vault_ahead_behind();
        $vault{ahead}  = $ahead + 0;
        $vault{behind} = $behind + 0;
    }

    for my $slug (sort keys %{$reg->{projects}}) {
        my $entry = $reg->{projects}{$slug};
        my $cwd = $entry->{path};
        my $pmeta_path = project_metadata_path($cwd);
        my $project_exists = -d $cwd;

        my $last_synced_at = undef;
        if (-f $pmeta_path) {
            my $pmeta = eval { read_json($pmeta_path) };
            $last_synced_at = $pmeta->{last_synced_at} if $pmeta;
        }

        # Journal state
        my $jpath = journal_path($slug);
        my $has_journal = (-f $jpath) ? 1 : 0;
        my ($journal_phase, $journal_age, $journal_ops) = (undef, undef, 0);
        if ($has_journal) {
            my $j = eval { journal_read($slug) } || {};
            $journal_phase = $j->{phase};
            $journal_ops = scalar(@{$j->{ops} || []});
            if ($j->{started_at} && $j->{started_at} =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})/) {
                require Time::Local;
                my $epoch = eval { Time::Local::timegm($6, $5, $4, $3, $2 - 1, $1) };
                $journal_age = (time() - $epoch) if $epoch;
            }
        }

        # Lock state
        my $lpath = "$VAULT_DIR/projects/$slug/.lock";
        my $has_lock = (-f $lpath) ? 1 : 0;
        my ($lock_age, $lock_is_ours) = (undef, undef);
        if ($has_lock) {
            my $info = read_lock_info($lpath);
            $lock_age = time() - ($info->{epoch} // 0);
            $lock_is_ours = ($info->{session_id} && $info->{session_id} eq $SESSION_ID) ? 1 : 0;
        }

        # Vault drift specific to this slug
        my $is_drift = 0;
        if ($vault_exists) {
            my $status = vault_git_output('status', '--porcelain', '--', "projects/$slug/");
            $is_drift = 1 if length $status;
        }

        push @projects, {
            slug             => $slug,
            path             => $cwd,
            project_exists   => $project_exists  ? JSON::PP::true : JSON::PP::false,
            last_synced_at   => $last_synced_at,
            has_journal      => $has_journal     ? JSON::PP::true : JSON::PP::false,
            journal_phase    => $journal_phase,
            journal_ops      => $journal_ops + 0,
            journal_age_sec  => defined $journal_age ? $journal_age + 0 : undef,
            has_lock         => $has_lock        ? JSON::PP::true : JSON::PP::false,
            lock_age_sec     => defined $lock_age ? $lock_age + 0 : undef,
            lock_is_ours     => $lock_is_ours    ? JSON::PP::true : JSON::PP::false,
            is_drift         => $is_drift        ? JSON::PP::true : JSON::PP::false,
        };
    }

    # Orphan count
    my %known = map { $_ => 1 } keys %{$reg->{projects}};
    my $orphan_count = 0;
    my $vault_projects_dir = "$VAULT_DIR/projects";
    if (-d $vault_projects_dir) {
        opendir my $dh, $vault_projects_dir or undef;
        if ($dh) {
            for my $entry (readdir $dh) {
                next if $entry =~ /^\.\.?$/;
                next unless -d "$vault_projects_dir/$entry";
                next if $known{$entry};
                next unless -f "$vault_projects_dir/$entry/metadata.json";
                $orphan_count++;
            }
            closedir $dh;
        }
    }

    emit_json({
        vault         => \%vault,
        projects      => \@projects,
        project_count => scalar @projects,
        orphan_count  => $orphan_count,
    });
}

# ── vault-files ─────────────────────────────────────────────────────

# Lists every file in vault projects/<slug>/files/ with size. Used by the
# /steward:setup (link mode) to preview what will be pulled
# before the user confirms (fix C4 from red-team).
sub cmd_vault_files {
    my %opts = parse_opts(\@ARGV, qw(slug));
    my $slug = require_opt(\%opts, 'slug');
    my $files_dir = vault_project_dir($slug) . "/files";
    my @files;
    if (-d $files_dir) {
        find({
            no_chdir => 1,
            follow   => 0,
            wanted => sub {
                return if -l $_;
                return unless -f $_;
                my $rel = abs_to_rel($files_dir, $_);
                push @files, { path => $rel, size => (-s $_) + 0 } if defined $rel;
            },
        }, $files_dir);
    }
    @files = sort { $a->{path} cmp $b->{path} } @files;
    my $total = 0; $total += $_->{size} for @files;
    emit_json({
        slug       => $slug,
        files      => \@files,
        file_count => scalar @files,
        total_size => $total,
    });
}

# ── sync-project ────────────────────────────────────────────────────

sub cmd_sync_project {
    my %opts = parse_opts(\@ARGV, qw(slug));
    my $slug = require_opt(\%opts, 'slug');

    my $reg = read_registry();
    my $entry = $reg->{projects}{$slug};
    emit_error("Slug '$slug' not in registry on this machine.") unless $entry;

    my $cwd = $entry->{path};
    my $vproj = vault_project_dir($slug);
    my $pmeta_path = project_metadata_path($cwd);
    emit_error("Project metadata missing at $pmeta_path") unless -f $pmeta_path;

    acquire_lock($VAULT_LOCK)            or emit_error("Vault lock held by another session.");
    acquire_lock("$vproj/.lock")          or emit_error("Project lock for '$slug' held by another session.");

    # Reconcile any leftover journal before starting fresh.
    my $reconcile = journal_reconcile($slug, $cwd, $vproj);
    if ($reconcile->{performed}) {
        # Continue — reconciliation cleaned up. Fall through to fresh sync.
    }

    # Vault clean check (after reconciliation)
    unless (vault_status_clean($slug)) {
        my @dirty = vault_dirty_files($slug);
        emit_json({
            status         => 'drift',
            slug           => $slug,
            dirty_files    => \@dirty,
            note           => "Vault has uncommitted changes in projects/$slug/ outside of a known journal. Inspect and clean manually before re-running sync.",
        });
        return;
    }

    # Fetch + pull
    unless (vault_git_ok('fetch', 'origin')) {
        emit_error("vault fetch failed");
    }
    unless (vault_git_ok('pull', '--rebase', 'origin', $BRANCH)) {
        emit_error("vault pull --rebase failed (manual resolution required at $VAULT_DIR)");
    }

    my $pmeta = read_json($pmeta_path);

    # Begin journal (staging phase)
    journal_begin($slug, $cwd, $vproj);

    # Walk tracked paths to enumerate file inventory (project + vault sides).
    my %inventory;   # rel_path => { local_exists, vault_exists, cache_exists, is_dir }
    my @skipped_symlinks;
    my @skipped_bad_paths;

    for my $tp (@{$pmeta->{tracked_paths}}) {
        unless (validate_relative_path($tp)) {
            push @skipped_bad_paths, $tp;
            next;
        }
        my $abs_local = "$cwd/$tp";
        my $abs_vault = vault_file_path($slug, $tp);
        my $abs_cache = cache_path($cwd, $tp);

        # Collect from local (skip symlinks at top before -d/-f which auto-follow)
        if (-l $abs_local) {
            push @skipped_symlinks, $tp;
        } elsif (-d $abs_local) {
            walk_dir_into_inventory(\%inventory, $cwd, $tp, 'local', \@skipped_symlinks, \@skipped_bad_paths);
        } elsif (-f $abs_local) {
            add_to_inventory(\%inventory, $tp, 'local') unless is_hard_excluded($tp);
        }

        # Collect from vault — H14 (red-team): check -l BEFORE -d/-f (which
        # auto-follow symlinks). Without this, a vault symlink pointing at
        # /etc/passwd would be hashed and pulled into local on next sync.
        if (-l $abs_vault) {
            push @skipped_symlinks, "vault:$tp";
        } elsif (-d $abs_vault) {
            walk_dir_into_inventory(\%inventory, $VAULT_DIR . "/projects/$slug/files", $tp, 'vault', \@skipped_symlinks, \@skipped_bad_paths);
        } elsif (-f $abs_vault) {
            add_to_inventory(\%inventory, $tp, 'vault') unless is_hard_excluded($tp);
        }

        # Cache files
        if (-l $abs_cache) {
            push @skipped_symlinks, "cache:$tp";
        } elsif (-d $abs_cache) {
            walk_dir_into_inventory(\%inventory, cache_root($cwd), $tp, 'cache', \@skipped_symlinks, \@skipped_bad_paths);
        } elsif (-f $abs_cache) {
            add_to_inventory(\%inventory, $tp, 'cache') unless is_hard_excluded($tp);
        }
    }

    # Classify each file
    my @auto_applied;
    my @conflicts;
    my @file_mod_skipped;
    my $applied = 0;

    for my $rel (sort keys %inventory) {
        next if is_hard_excluded($rel);

        my $abs_local = "$cwd/$rel";
        my $abs_vault = vault_file_path($slug, $rel);
        my $abs_cache = cache_path($cwd, $rel);

        my $base_hash  = -f $abs_cache ? hash_file($abs_cache) : '';
        my $local_hash = -f $abs_local ? hash_file($abs_local) : '';
        my $vault_hash = -f $abs_vault ? hash_file($abs_vault) : '';

        my $action = classify($base_hash, $local_hash, $vault_hash);

        if ($action eq 'skip') {
            next;
        } elsif ($action eq 'push') {
            stage_push($slug, $cwd, $rel, $local_hash);
            $applied++;
            push @auto_applied, { path => $rel, action => 'push' };
        } elsif ($action eq 'pull') {
            stage_pull($slug, $cwd, $rel, $vault_hash);
            $applied++;
            push @auto_applied, { path => $rel, action => 'pull' };
        } elsif ($action eq 'cache_only') {
            # local == vault but both != base. Just refresh cache.
            stage_cache_only($slug, $cwd, $rel, $local_hash);
            $applied++;
            push @auto_applied, { path => $rel, action => 'cache_only' };
        } elsif ($action eq 'delete_vault') {
            stage_delete_vault($slug, $cwd, $rel);
            $applied++;
            push @auto_applied, { path => $rel, action => 'delete_vault' };
        } elsif ($action eq 'delete_local') {
            stage_delete_local($slug, $cwd, $rel);
            $applied++;
            push @auto_applied, { path => $rel, action => 'delete_local' };
        } elsif ($action eq 'clear_cache') {
            stage_clear_cache($slug, $cwd, $rel);
            $applied++;
            push @auto_applied, { path => $rel, action => 'clear_cache' };
        } elsif ($action eq 'conflict') {
            my $local_is_text = (-f $abs_local) ? is_text_file($abs_local) : 1;
            my $vault_is_text = (-f $abs_vault) ? is_text_file($abs_vault) : 1;
            my $is_text = $local_is_text && $vault_is_text;

            my $merge_result = undef;
            if ($is_text) {
                $merge_result = git_merge_attempt($abs_local, $abs_cache, $abs_vault, $slug, $rel);
            }

            push @conflicts, {
                path   => $rel,
                base   => file_summary($abs_cache, $base_hash),
                local  => file_summary($abs_local, $local_hash),
                vault  => file_summary($abs_vault, $vault_hash),
                is_text => $is_text ? JSON::PP::true : JSON::PP::false,
                merge_result => $merge_result,
            };
        }
    }

    journal_set_phase($slug, 'awaiting_resolution');

    emit_json({
        status               => 'synced',
        slug                 => $slug,
        applied              => $applied,
        auto_applied         => \@auto_applied,
        conflicts            => \@conflicts,
        skipped_symlinks     => \@skipped_symlinks,
        skipped_bad_paths    => \@skipped_bad_paths,
        session_id           => $SESSION_ID,
    });
}

# ── resolve-conflict ────────────────────────────────────────────────

sub cmd_resolve_conflict {
    my %opts = parse_opts(\@ARGV, qw(slug path action merged-file session-id));
    my $slug   = require_opt(\%opts, 'slug');
    my $path   = require_opt(\%opts, 'path');
    my $action = require_opt(\%opts, 'action');

    # Fix H2 (red-team): validate session_id against the journal so a second
    # invocation can't splice ops into another session's pending journal.
    if ($opts{'session-id'}) {
        my $j = journal_read($slug);
        if ($j->{session_id} && $j->{session_id} ne $opts{'session-id'}) {
            emit_error("session_id mismatch for slug '$slug': journal owned by "
                      . $j->{session_id} . ", caller provided " . $opts{'session-id'}
                      . ". Re-run sync-project to start a new session.");
        }
    }

    unless ($action =~ /^(use-local|use-vault|use-merged)$/) {
        emit_error("Invalid --action: '$action'. Must be use-local, use-vault, or use-merged.");
    }

    my $reg = read_registry();
    my $entry = $reg->{projects}{$slug};
    emit_error("Slug '$slug' not in registry.") unless $entry;
    my $cwd = $entry->{path};
    my $vproj = vault_project_dir($slug);

    acquire_lock($VAULT_LOCK)    or emit_error("Vault lock held by another session.");
    acquire_lock("$vproj/.lock")  or emit_error("Project lock held by another session.");

    unless (validate_relative_path($path)) {
        emit_error("Invalid path: '$path'.");
    }
    if (is_hard_excluded($path)) {
        emit_error("Path '$path' is hard-excluded.");
    }

    my $abs_local = "$cwd/$path";
    my $abs_vault = vault_file_path($slug, $path);

    if ($action eq 'use-local') {
        unless (-f $abs_local) {
            emit_error("Cannot use-local: '$path' does not exist locally.");
        }
        my $h = hash_file($abs_local);
        stage_push($slug, $cwd, $path, $h);
        stage_cache_only_from_path($slug, $cwd, $path, $abs_local, $h);
    } elsif ($action eq 'use-vault') {
        unless (-f $abs_vault) {
            emit_error("Cannot use-vault: '$path' does not exist in vault.");
        }
        my $h = hash_file($abs_vault);
        stage_pull($slug, $cwd, $path, $h);
        stage_cache_only_from_path($slug, $cwd, $path, $abs_vault, $h);
    } elsif ($action eq 'use-merged') {
        my $merged = $opts{'merged-file'};
        unless ($merged && -f $merged) {
            emit_error("Cannot use-merged: --merged-file '$merged' not found.");
        }
        my $h = hash_file($merged);
        # Stage push (vault), pull (local), and cache from merged content
        stage_from_path($slug, $cwd, $path, $merged, 'push');
        stage_from_path($slug, $cwd, $path, $merged, 'pull');
        stage_cache_only_from_path($slug, $cwd, $path, $merged, $h);
    }

    emit_json({
        status => 'staged',
        slug   => $slug,
        path   => $path,
        action => $action,
    });
}

# ── commit-and-push ─────────────────────────────────────────────────

sub cmd_commit_and_push {
    my %opts = parse_opts(\@ARGV, qw(slug session-id));
    my $slug = require_opt(\%opts, 'slug');

    my $reg = read_registry();
    my $entry = $reg->{projects}{$slug};
    emit_error("Slug '$slug' not in registry.") unless $entry;
    my $cwd = $entry->{path};
    my $vproj = vault_project_dir($slug);

    acquire_lock($VAULT_LOCK)   or emit_error("Vault lock held by another session.");
    acquire_lock("$vproj/.lock") or emit_error("Project lock held by another session.");

    # Pre-rename sensitive scan: check all staged .tmp files that will become vault content
    # (push ops). On hit, clean up all tmps and abort BEFORE any vault state changes.
    # Deletion ops have no tmp/source to scan — they remove content, can't add secrets.
    my $j = journal_read($slug);
    my @push_tmps;
    for my $op (@{$j->{ops}}) {
        next unless $op->{status} eq 'staged' || $op->{status} eq 'pending';
        next unless $op->{action} eq 'push';
        push @push_tmps, $op->{tmp_path} if $op->{tmp_path};
    }
    if (@push_tmps) {
        my $findings = scan_files_for_secrets(@push_tmps);
        if (@$findings) {
            # Clean up all staged tmps so the next sync starts fresh
            for my $op (@{$j->{ops}}) {
                next unless $op->{tmp_path};
                unlink $op->{tmp_path} if -f $op->{tmp_path};
            }
            cleanup_merge_tmps($slug);
            journal_clear($slug);
            emit_json({
                status   => 'sensitive_blocked',
                slug     => $slug,
                findings => $findings,
                note     => "Sensitive patterns detected in files staged for vault push. ALL staging cleared; vault was not modified. Resolve the leaks locally and re-run sync.",
            });
            return;
        }
    }

    # Validate journal exists and is in a commit-able phase (fix H6 from red-team).
    # Without this, calling commit-and-push without a prior sync-project would
    # commit whatever happened to be dirty in the vault tree without going through
    # the pre-rename scan.
    my $journal = journal_read($slug);
    unless ($journal->{phase} && ($journal->{phase} eq 'awaiting_resolution'
                                 || $journal->{phase} eq 'renaming'
                                 || $journal->{phase} eq 'sensitive_check'
                                 || $journal->{phase} eq 'committing'
                                 || $journal->{phase} eq 'staging')) {
        emit_error("Cannot commit-and-push: no in-progress sync journal for slug '$slug'. Run sync-project first.");
    }

    # Fix H2 (red-team): validate session_id if the journal recorded one.
    # Prevents a second invocation from finalizing a journal it didn't create.
    if ($journal->{session_id} && $opts{'session-id'}
        && $journal->{session_id} ne $opts{'session-id'}) {
        emit_error("session_id mismatch: journal owned by " . $journal->{session_id}
                  . ", caller provided " . $opts{'session-id'} . ". Refusing to act.");
    }

    my $result = finalize_commit($slug, $cwd, $vproj, recovering => 0);
    # finalize_commit emits the JSON itself. Return early.
    return;
}

# Shared "finalize" flow used by commit-and-push and by journal_reconcile.
# Walks: renaming (if needed) → sensitive_check → committing → done.
# On sensitive hit: rolls back renamed files via git checkout, clears journal,
# emits sensitive_blocked_post_rename status. On success: updates last_synced_*,
# clears journal, emits committed_and_pushed status (with optional rollback notes).
sub finalize_commit {
    my ($slug, $cwd, $vproj, %opts) = @_;
    my $j = journal_read($slug);

    # Step 1 — Renaming phase (do or finish)
    my $rename_report = { renamed => [], rolled_back => [] };
    if (!$j->{phase} || $j->{phase} ne 'sensitive_check' && $j->{phase} ne 'committing') {
        journal_set_phase($slug, 'renaming');
        $rename_report = batch_rename_all($slug, $cwd);
    }
    my $mid_sync_rollbacks = $rename_report->{rolled_back};

    # Defense-in-depth: re-scan the renamed vault content. Use the Perl-native
    # scanner (extension-agnostic, content-based) instead of sensitive-check.sh
    # which has an extension allowlist (H11 from red-team).
    journal_set_phase($slug, 'sensitive_check');
    my $post_findings = scan_dir_for_secrets($vproj);
    if (@$post_findings) {
        # Fix H1 (red-team): roll back the renames so the vault returns to its pre-sync
        # state, then clear the journal. Previously we returned with the journal still
        # in 'sensitive_check' phase, which combined with C1's gap let the next sync's
        # reconcile path commit + push the secret unscanned.
        vault_git_ok('checkout', '--', "projects/$slug/");
        vault_git_ok('clean', '-fd', '--', "projects/$slug/");
        journal_clear($slug);
        emit_json({
            status   => 'sensitive_blocked_post_rename',
            slug     => $slug,
            findings => $post_findings,
            note     => 'Post-rename scan caught a leak that escaped the pre-rename scan. Vault files have been restored from git HEAD; journal cleared. Fix the source files locally and re-run sync.',
        });
        return;
    }

    journal_set_phase($slug, 'committing');

    # Stage to git only the project's files (and metadata if updated)
    unless (vault_git_ok('add', '--', "projects/$slug/")) {
        emit_error("git add failed for projects/$slug/");
    }

    # Check if there's anything to commit (might be a no-op sync)
    my $status = vault_git_output('status', '--porcelain', '--', "projects/$slug/");
    if (length $status) {
        my $msg = "Sync $slug: " . iso_now();
        unless (vault_git_ok('commit', '-m', $msg)) {
            emit_error("git commit failed");
        }
    }

    # Push (only if ahead)
    my ($ahead, $behind) = vault_ahead_behind();
    if ($ahead > 0) {
        unless (vault_git_ok('push', 'origin', $BRANCH)) {
            emit_error("git push failed");
        }
    }

    # Update project metadata last_synced_*
    my $pmeta_path = project_metadata_path($cwd);
    my $pmeta = read_json($pmeta_path);
    $pmeta->{last_synced_at} = iso_now();
    # Rebuild last_synced_hashes from the cache (it's authoritative for what was synced)
    $pmeta->{last_synced_hashes} = build_hash_map_from_cache($cwd);
    write_json($pmeta_path, $pmeta);

    journal_clear($slug);

    my $out = {
        status         => 'committed_and_pushed',
        slug           => $slug,
        last_synced_at => $pmeta->{last_synced_at},
    };
    if (@$mid_sync_rollbacks) {
        $out->{rolled_back_during_sync} = $mid_sync_rollbacks;
        $out->{note} = "Committed and pushed, BUT some files were rolled back because their source changed mid-sync. Re-run sync to pick them up.";
    }
    emit_json($out);
}

# ── sync-beacons ────────────────────────────────────────────────────
#
# Commits + pushes vault-root beacons/ as a self-contained step. Beacons are
# UUID-keyed JSON records written by /beacon:on (host) and ingested from
# sandboxes by the statusline-triggered background sync. Until D9 they sat
# orphaned from git; this subcommand bridges that gap.
#
# Lock order: VAULT_LOCK first (consistent with cmd_commit_and_push and
# cmd_resolve_conflict), then beacons/.sync-vault.lock. The beacons sync lock
# uses RAW flock to mutually exclude with statusline's beacon.pl sync-vault
# (which also uses raw flock); vault-sync.pl's acquire_lock helper uses a
# different protocol (metadata file + sibling .flock sentinel) and is NOT
# mutually visible — that's why this routine opens the lock by hand.
sub cmd_sync_beacons {
    parse_opts(\@ARGV);  # no args — call to reject any unexpected flags

    # Pre-lock guards: emit no_op without acquiring anything.
    unless (-d "$VAULT_DIR/.git") {
        emit_json({
            status => 'no_op',
            reason => 'vault not initialized on this host (no .git dir)',
        });
        return;
    }
    unless (-d $VAULT_BEACON_DIR) {
        emit_json({
            status => 'no_op',
            reason => 'beacons directory does not exist',
        });
        return;
    }

    # Lock 1: VAULT_LOCK (acquire_lock — tracked by %HELD_LOCKS, auto-released
    # on SIGINT/SIGTERM/END).
    acquire_lock($VAULT_LOCK) or emit_error("Vault lock held by another session.");

    # Lock 2: beacons/.sync-vault.lock (RAW flock to match beacon.pl). Held by
    # this process via $beacon_lock_fh until cmd_sync_beacons returns; OS
    # releases on process exit (including signal-driven exits), so explicit
    # cleanup is best-effort but not load-bearing for correctness.
    my $beacon_sync_lock = "$VAULT_BEACON_DIR/.sync-vault.lock";
    open my $beacon_lock_fh, '>>', $beacon_sync_lock
        or emit_error("Cannot open beacon sync lock $beacon_sync_lock: $!");

    my $got_beacon_lock = 0;
    for (1..100) {  # ~5s @ 50ms — matches beacon.pl's with_lock cadence
        if (flock($beacon_lock_fh, LOCK_EX | LOCK_NB)) {
            $got_beacon_lock = 1;
            last;
        }
        select(undef, undef, undef, 0.05);
    }
    unless ($got_beacon_lock) {
        close $beacon_lock_fh;
        emit_error("Beacon sync lock held by another process after 5s wait.");
    }

    # Run the work inside an eval so a die() doesn't leak the raw flock —
    # tighten the cleanup window before re-emitting through emit_error.
    # Pass $beacon_lock_fh through so the pre-flight subprocess can close it
    # in the child before exec (prevents fd inheritance into beacon.pl --no-lock).
    my $result = eval { _sync_beacons_locked($beacon_lock_fh) };
    my $err = $@;
    flock($beacon_lock_fh, LOCK_UN);
    close $beacon_lock_fh;

    if ($err) {
        chomp $err;
        emit_error($err);
    }

    emit_json($result);
}

# Body of cmd_sync_beacons that runs while BOTH locks are held. Separated so
# the lock-release path is exception-safe (cmd_sync_beacons evals this).
# Takes the beacon lock fh so the pre-flight subprocess can close it in the
# child before exec — keeps the inherited fd out of beacon.pl --no-lock.
sub _sync_beacons_locked {
    my $beacon_lock_fh = shift;

    # Pre-flight: drain pending sandbox ingestion + refresh .global-count
    # cache via beacon.pl sync-vault --no-lock (--no-lock skips beacon.pl's
    # own flock since we already hold it). Failures are non-fatal — local
    # vault records can still be committed/pushed even if ingestion broke.
    my $beacon_script = "$home/.claude/ccpraxis/plugins/beacon/scripts/beacon.pl";
    my ($ingested, $ingest_skipped) = (0, 0);
    my @ingest_errors;
    if (-f $beacon_script) {
        # Close $beacon_lock_fh in the child before exec so beacon.pl
        # --no-lock doesn't inherit a writable handle on the lock file. The
        # parent (cmd_sync_beacons) keeps its own fd, so the OFD-based flock
        # is retained throughout.
        my ($out, $exit) = _run_capture_close_fds(
            [$beacon_lock_fh],
            'perl', $beacon_script, 'sync-vault', '--no-lock',
        );
        for my $line (split /\n/, $out // '') {
            $ingested       = $1 + 0 if $line =~ /^INGESTED:\s*(\d+)/;
            $ingest_skipped = $1 + 0 if $line =~ /^INGEST_SKIPPED:\s*(\d+)/;
            push @ingest_errors, $1 if $line =~ /^INGEST_ERROR:\s*(.+)/;
        }
        if ($exit != 0) {
            push @ingest_errors,
                "beacon.pl sync-vault --no-lock exited $exit: "
                . substr($out // '', 0, 200);
        }
    } else {
        push @ingest_errors,
            "beacon.pl not found at $beacon_script — skipping pre-flight ingestion";
    }

    # Secret scan. Beacon labels/summaries are user-or-Claude-supplied free
    # text — scan_dir_for_secrets walks every file (extension-agnostic) and
    # skips binaries via null-byte detection. Runs BEFORE git add so a hit
    # leaves the vault git state untouched.
    my $findings = scan_dir_for_secrets($VAULT_BEACON_DIR);
    if (@$findings) {
        return {
            status   => 'sensitive_blocked',
            findings => $findings,
            note     => "Sensitive patterns detected in beacon JSONs. Vault was NOT modified by /backup. Each finding's `file` and `line` point to the offending record — edit it via /beacon:delete or directly, then re-run /backup.",
        };
    }

    # Stage beacons/ — -A so deletions (e.g. /beacon:delete between backups)
    # are captured. Gitignore patterns filter machine-local artifacts
    # (.global-count, .sync-vault.lock, *.json.lock, *.tmp.<pid>).
    unless (vault_git_ok('add', '-A', '--', 'beacons/')) {
        die "git add failed for beacons/\n";
    }

    my $status = vault_git_output('status', '--porcelain', '--', 'beacons/');
    my $committed = 0;
    if (length $status) {
        my $msg = "Sync beacons: " . iso_now();
        unless (vault_git_ok('commit', '-m', $msg)) {
            die "git commit failed\n";
        }
        $committed = 1;
    }

    # Push only when there's something to push. Covers two cases: a fresh
    # commit just made above, AND a previous run that committed but failed
    # to push (network/auth) — vault_ahead_behind sees the unpushed commit
    # and we retry the push now.
    my ($ahead, undef) = vault_ahead_behind();
    my $pushed = 0;
    if ($ahead > 0) {
        unless (vault_git_ok('push', 'origin', $BRANCH)) {
            die "git push failed\n";
        }
        $pushed = 1;
    }

    # Count current beacon JSONs. Read from the filesystem rather than
    # `git ls-files` so the count matches statusline's view (which is also
    # a directory walk). Hidden machine-local files are excluded by the
    # leading-dot filter (so .global-count / .sync-vault.lock never count).
    my $count = 0;
    if (opendir(my $dh, $VAULT_BEACON_DIR)) {
        $count = grep { /\.json$/ && !/^\./ } readdir($dh);
        closedir($dh);
    }

    # When nothing existed and nothing happened, downgrade to no_op so the
    # skill body can skip silently. Otherwise report synced with details.
    if ($count == 0 && !$committed && !$pushed) {
        my $out = {
            status         => 'no_op',
            reason         => 'no beacon records and nothing to push',
            ingested       => $ingested + 0,
            ingest_skipped => $ingest_skipped + 0,
        };
        $out->{ingest_errors} = \@ingest_errors if @ingest_errors;
        return $out;
    }

    my $out = {
        status         => 'synced',
        count          => $count + 0,
        committed      => $committed ? JSON::PP::true : JSON::PP::false,
        pushed         => $pushed    ? JSON::PP::true : JSON::PP::false,
        ingested       => $ingested + 0,
        ingest_skipped => $ingest_skipped + 0,
    };
    $out->{ingest_errors} = \@ingest_errors if @ingest_errors;
    return $out;
}

# ═══════════════════════════════════════════════════════════════════════
# Path / Slug helpers
# ═══════════════════════════════════════════════════════════════════════

sub norm_path {
    my $p = shift;
    return $p unless defined $p;
    $p =~ s|\\|/|g;
    # Convert native Windows form (C:/Users/...) to POSIX form (/c/Users/...) so
    # Cygwin perl filesystem ops work. Forward slashes already normalized above.
    $p =~ s|^([a-zA-Z]):/|"/" . lc($1) . "/"|e;
    $p =~ s|/+$||;
    return $p;
}

sub project_metadata_path { my $cwd = shift; "$cwd/.claude/backup-metadata.json" }
sub cache_root            { my $cwd = shift; "$cwd/.claude/backup-cache"          }
sub cache_path            { my ($cwd, $rel) = @_; cache_root($cwd) . "/$rel"     }
sub vault_project_dir     { my $slug = shift; "$VAULT_DIR/projects/$slug"        }
sub vault_file_path       { my ($slug, $rel) = @_; vault_project_dir($slug) . "/files/$rel" }

sub validate_slug {
    my $s = shift;
    return 0 unless defined $s && length $s;
    return 0 unless $s =~ /^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/;
    return 0 if $s eq '.' || $s eq '..';
    return 1;
}

sub sanitize_slug {
    my $s = shift // '';
    $s = lc $s;
    $s =~ s/[^a-z0-9-]+/-/g;
    $s =~ s/^-+|-+$//g;
    $s =~ s/-{2,}/-/g;
    return $s;
}

sub random_suffix {
    my $n = shift // 4;
    my @chars = ('a'..'z', 0..9);
    return join '', map { $chars[int rand @chars] } 1..$n;
}

sub validate_relative_path {
    my $p = shift;
    return 0 unless defined $p && length $p;
    return 0 if $p =~ m|^/|;          # absolute
    return 0 if $p =~ m|^[A-Za-z]:|;  # Windows absolute (C:)
    return 0 if $p =~ m{(^|/)\.\.(/|$)};  # path traversal
    return 0 if $p =~ m|^\./|;        # leading ./ (use without)
    return 0 if $p =~ m|\\|;          # backslash (we use forward slashes)
    return 1;
}

sub is_hard_excluded {
    my $rel = shift;
    # Fix H13 (red-team): case-insensitive comparison. Windows NTFS and macOS HFS+
    # are case-insensitive; without lowercasing, ".Claude/Settings.Local.Json" would
    # bypass all hard-exclude rules and leak the credential store.
    my $rel_lc = lc($rel);
    return 1 if $HARD_EXCLUDE_EXACT{$rel_lc};
    for my $prefix (@HARD_EXCLUDE_PREFIXES) {
        my $p_lc = lc($prefix);
        return 1 if $rel_lc eq $p_lc || index($rel_lc, "$p_lc/") == 0;
    }
    for my $re (@HARD_EXCLUDE_REGEX) {
        return 1 if $rel_lc =~ $re;
    }
    return 0;
}

sub dir_size {
    my $dir = shift;
    my $total = 0;
    find({
        no_chdir => 1,
        wanted => sub {
            return if -l $_;  # don't follow symlinks
            $total += -s _ if -f _;
        },
    }, $dir);
    return $total;
}

sub vault_files_stats {
    my $dir = shift;
    return (0, 0) unless -d $dir;
    my ($n, $sz) = (0, 0);
    find({
        no_chdir => 1,
        wanted => sub {
            return if -l $_;
            return unless -f _;
            $n++;
            $sz += -s _;
        },
    }, $dir);
    return ($n, $sz);
}

# Walk a directory and add files into the inventory hash.
# side = 'local' | 'vault' | 'cache'
sub walk_dir_into_inventory {
    my ($inv, $root, $rel_dir, $side, $skipped_symlinks, $skipped_bad) = @_;
    my $abs_dir = "$root/$rel_dir";
    return unless -d $abs_dir;
    # Fix H14 (red-team): refuse to walk INTO a symlinked root. File::Find
    # follows symlinks for the entry point by default; without this check, a
    # vault containing projects/<slug>/files/CLAUDE.md -> /etc/passwd would
    # cause sync to read and stage the target's content.
    if (-l $abs_dir) {
        push @$skipped_symlinks, $rel_dir;
        return;
    }

    find({
        no_chdir => 1,
        follow   => 0,  # Explicit: never follow symlinks at any depth.
        preprocess => sub {
            # Skip symlinks at directory level
            my @keep;
            for my $entry (@_) {
                next if $entry eq '.' || $entry eq '..';
                my $f = "$File::Find::dir/$entry";
                if (-l $f) {
                    my $r = abs_to_rel($root, $f);
                    push @$skipped_symlinks, $r if defined $r;
                    next;
                }
                push @keep, $entry;
            }
            return @keep;
        },
        wanted => sub {
            return if -l $_;
            return unless -f $_;
            my $rel = abs_to_rel($root, $_);
            unless (defined $rel && validate_relative_path($rel)) {
                push @$skipped_bad, ($rel // $_);
                return;
            }
            return if is_hard_excluded($rel);
            add_to_inventory($inv, $rel, $side);
        },
    }, $abs_dir);
}

sub abs_to_rel {
    my ($root, $abs) = @_;
    $root = norm_path($root);
    $abs  = norm_path($abs);
    return undef unless index($abs, "$root/") == 0;
    return substr($abs, length($root) + 1);
}

sub add_to_inventory {
    my ($inv, $rel, $side) = @_;
    $inv->{$rel} //= { local_exists => 0, vault_exists => 0, cache_exists => 0 };
    $inv->{$rel}{"${side}_exists"} = 1;
}

# ═══════════════════════════════════════════════════════════════════════
# Classify / Sync helpers
# ═══════════════════════════════════════════════════════════════════════

# Classify a tracked file based on three hashes (empty string = missing/absent).
sub classify {
    my ($base, $local, $vault) = @_;
    my $local_changed = $local ne $base;
    my $vault_changed = $vault ne $base;
    my $local_missing = ($local eq '');
    my $vault_missing = ($vault eq '');
    my $base_existed  = ($base ne '');

    return 'skip' unless $local_changed || $vault_changed;

    # Deletion cases (base had content; one or both sides went missing).
    # Handle these BEFORE the push/pull cases below because push/pull assume
    # both sides have readable content.
    if ($base_existed && $local_missing && $vault_missing) {
        # Both sides deleted; just clean the cache entry. No vault op needed.
        return 'clear_cache';
    }
    if ($base_existed && $local_missing) {
        # Local was deleted. If vault still matches base, propagate the deletion.
        # If vault diverged AND local is gone, it's a conflict (user has to decide
        # whether to restore local from vault or remove from vault too).
        return $vault eq $base ? 'delete_vault' : 'conflict';
    }
    if ($base_existed && $vault_missing) {
        # Vault was deleted (some other machine removed it). If local matches
        # base, accept the deletion (delete local). Otherwise conflict.
        return $local eq $base ? 'delete_local' : 'conflict';
    }

    if ($local_changed && !$vault_changed) {
        return 'push';
    }
    if (!$local_changed && $vault_changed) {
        return 'pull';
    }
    # Both changed
    if ($local eq $vault) {
        return 'cache_only';
    }
    return 'conflict';
}

sub file_summary {
    my ($abs, $hash) = @_;
    return {
        hash => $hash,
        size => (-f $abs) ? (-s $abs) + 0 : 0,
        mtime => (-f $abs) ? (stat($abs))[9] + 0 : 0,
        exists => (-f $abs) ? JSON::PP::true : JSON::PP::false,
    };
}

# ═══════════════════════════════════════════════════════════════════════
# Stage (atomic write to .tmp + journal record)
# ═══════════════════════════════════════════════════════════════════════

sub stage_push {
    my ($slug, $cwd, $rel, $hash_before) = @_;
    my $src = "$cwd/$rel";
    my $final = vault_file_path($slug, $rel);
    my $tmp = "$final$TMP_SUFFIX";
    make_path(dirname($tmp));
    copy_file($src, $tmp);
    journal_record_op($slug, {
        id          => next_op_id($slug),
        path        => $rel,
        action      => 'push',
        source      => $src,
        tmp_path    => $tmp,
        final_path  => $final,
        hash_before => $hash_before,
        status      => 'staged',
    });
    # Also cache from source
    stage_cache_only_from_path($slug, $cwd, $rel, $src, $hash_before);
}

sub stage_pull {
    my ($slug, $cwd, $rel, $hash_before) = @_;
    my $src = vault_file_path($slug, $rel);
    my $final = "$cwd/$rel";
    my $tmp = "$final$TMP_SUFFIX";
    make_path(dirname($tmp));
    copy_file($src, $tmp);
    journal_record_op($slug, {
        id          => next_op_id($slug),
        path        => $rel,
        action      => 'pull',
        source      => $src,
        tmp_path    => $tmp,
        final_path  => $final,
        hash_before => $hash_before,
        status      => 'staged',
    });
    # Also cache from vault source
    stage_cache_only_from_path($slug, $cwd, $rel, $src, $hash_before);
}

sub stage_cache_only {
    # local == vault. Cache from local (same content as vault).
    my ($slug, $cwd, $rel, $hash) = @_;
    stage_cache_only_from_path($slug, $cwd, $rel, "$cwd/$rel", $hash);
}

sub stage_cache_only_from_path {
    my ($slug, $cwd, $rel, $src, $hash) = @_;
    my $final = cache_path($cwd, $rel);
    my $tmp = "$final$TMP_SUFFIX";
    make_path(dirname($tmp));
    copy_file($src, $tmp);
    journal_record_op($slug, {
        id          => next_op_id($slug),
        path        => $rel,
        action      => 'cache',
        source      => $src,
        tmp_path    => $tmp,
        final_path  => $final,
        hash_before => $hash,
        status      => 'staged',
    });
}

sub stage_from_path {
    # Generic stage. action = 'push' or 'pull'.
    my ($slug, $cwd, $rel, $src, $action) = @_;
    my $final = ($action eq 'push') ? vault_file_path($slug, $rel) : "$cwd/$rel";
    my $tmp = "$final$TMP_SUFFIX";
    make_path(dirname($tmp));
    copy_file($src, $tmp);
    journal_record_op($slug, {
        id          => next_op_id($slug),
        path        => $rel,
        action      => $action,
        source      => $src,
        tmp_path    => $tmp,
        final_path  => $final,
        hash_before => hash_file($src),
        status      => 'staged',
    });
}

# Deletion stage helpers — no tmp file, just record the intent. The actual
# unlink happens in batch_rename_all so it stays atomic alongside renames.
sub stage_delete_vault {
    my ($slug, $cwd, $rel) = @_;
    my $vault_final = vault_file_path($slug, $rel);
    my $cache_final = cache_path($cwd, $rel);
    journal_record_op($slug, {
        path        => $rel,
        action      => 'delete_vault',
        final_path  => $vault_final,
        cache_path  => $cache_final,
        status      => 'staged',
    });
}

sub stage_delete_local {
    my ($slug, $cwd, $rel) = @_;
    my $local_final = "$cwd/$rel";
    my $cache_final = cache_path($cwd, $rel);
    journal_record_op($slug, {
        path        => $rel,
        action      => 'delete_local',
        final_path  => $local_final,
        cache_path  => $cache_final,
        status      => 'staged',
    });
}

sub stage_clear_cache {
    my ($slug, $cwd, $rel) = @_;
    my $cache_final = cache_path($cwd, $rel);
    journal_record_op($slug, {
        path        => $rel,
        action      => 'clear_cache',
        final_path  => $cache_final,
        status      => 'staged',
    });
}

sub batch_rename_all {
    my ($slug, $cwd) = @_;
    my $j = journal_read($slug);
    my @renamed;
    my @rolled_back;

    for my $op (@{$j->{ops}}) {
        next if $op->{status} eq 'complete' || $op->{status} eq 'rolled_back';

        # Deletion ops have no tmp_path; handle them first.
        if ($op->{action} eq 'delete_vault') {
            unlink $op->{final_path} if -f $op->{final_path};
            unlink $op->{cache_path} if $op->{cache_path} && -f $op->{cache_path};
            $op->{status} = 'complete';
            push @renamed, $op->{path};
            next;
        }
        if ($op->{action} eq 'delete_local') {
            unlink $op->{final_path} if -f $op->{final_path};
            unlink $op->{cache_path} if $op->{cache_path} && -f $op->{cache_path};
            $op->{status} = 'complete';
            push @renamed, $op->{path};
            next;
        }
        if ($op->{action} eq 'clear_cache') {
            unlink $op->{final_path} if -f $op->{final_path};
            $op->{status} = 'complete';
            push @renamed, $op->{path};
            next;
        }

        # File-modified-during-sync check: for push ops, re-hash source
        if ($op->{action} eq 'push' && -f $op->{source}) {
            my $now_hash = hash_file($op->{source});
            if ($op->{hash_before} && $now_hash ne $op->{hash_before}) {
                # Source was modified during sync — roll back this op
                unlink $op->{tmp_path} if -f $op->{tmp_path};
                $op->{status} = 'rolled_back';
                $op->{reason} = 'source_modified_during_sync';
                push @rolled_back, { path => $op->{path}, reason => 'source_modified_during_sync' };
                next;
            }
        }

        unless (-f $op->{tmp_path}) {
            # Tmp missing (already renamed in a previous pass?)
            if (-f $op->{final_path}) {
                $op->{status} = 'complete';
                push @renamed, $op->{path};
            } else {
                $op->{status} = 'rolled_back';
                $op->{reason} = 'tmp_missing_and_final_missing';
                push @rolled_back, { path => $op->{path}, reason => 'tmp_missing' };
            }
            next;
        }

        # Ensure parent of final exists (should from staging)
        make_path(dirname($op->{final_path}));

        # Atomic rename. On Windows, rename fails if final exists — remove first.
        unlink $op->{final_path} if -e $op->{final_path};
        unless (rename $op->{tmp_path}, $op->{final_path}) {
            # Fallback to copy+unlink
            unless (copy($op->{tmp_path}, $op->{final_path})) {
                emit_error("Rename and copy both failed for $op->{tmp_path} -> $op->{final_path}: $!");
            }
            unlink $op->{tmp_path};
        }
        $op->{status} = 'complete';
        push @renamed, $op->{path};
    }

    journal_write($slug, $j);
    return { renamed => \@renamed, rolled_back => \@rolled_back };
}

# ═══════════════════════════════════════════════════════════════════════
# Hash / file helpers
# ═══════════════════════════════════════════════════════════════════════

sub hash_file {
    my $path = shift;
    # Fix H14 (red-team): never follow a symlink when hashing. The walk
    # already filters them out, but defense-in-depth: if some other code
    # path slips a symlink in here, refuse to hash the target.
    return '' if -l $path;
    return '' unless -f $path;
    open my $fh, '<:raw', $path or return '';
    my $digest = Digest::SHA->new(256);
    $digest->addfile($fh);
    close $fh;
    return $digest->hexdigest;
}

sub copy_file {
    my ($src, $dst) = @_;
    # Fix H14 (red-team): never follow a symlink when copying. Defense-in-depth
    # against any code path that might try to copy through one.
    if (-l $src) {
        emit_error("copy_file: refusing to copy through symlink: $src");
    }
    unless (-f $src) {
        emit_error("copy_file: source missing: $src");
    }
    open my $in,  '<:raw', $src or emit_error("Cannot read $src: $!");
    open my $out, '>:raw', $dst or emit_error("Cannot write $dst: $!");
    my $buf;
    while (my $n = read $in, $buf, 65536) {
        print $out $buf;
    }
    close $in;
    close $out;
}

sub is_text_file {
    my $path = shift;
    return 0 unless -f $path;
    open my $fh, '<:raw', $path or return 0;
    my $buf = '';
    read $fh, $buf, 8192;
    close $fh;
    return 0 if $buf =~ /\0/;
    return 1;
}

sub build_hash_map_from_cache {
    my $cwd = shift;
    my $root = cache_root($cwd);
    my %map;
    return \%map unless -d $root;
    find({
        no_chdir => 1,
        wanted => sub {
            return if -l $_;
            return unless -f $_;
            return if $_ =~ /\Q$TMP_SUFFIX\E$/;
            my $rel = abs_to_rel($root, $_);
            $map{$rel} = hash_file($_) if defined $rel;
        },
    }, $root);
    return \%map;
}

# ═══════════════════════════════════════════════════════════════════════
# Merge
# ═══════════════════════════════════════════════════════════════════════

sub git_merge_attempt {
    my ($local_path, $base_path, $vault_path, $slug, $rel) = @_;

    # Stage tmps for inputs (git merge-file modifies the LOCAL argument in-place unless -p)
    # Use -p to print to stdout. Use --diff3 for clearer conflict markers.
    # Empty base if cache file is missing: pass /dev/null equivalent — a temp empty file.

    my $base_arg = (-f $base_path) ? $base_path : empty_temp_file($slug, $rel, 'base');
    my $local_arg = (-f $local_path) ? $local_path : empty_temp_file($slug, $rel, 'local');
    my $vault_arg = (-f $vault_path) ? $vault_path : empty_temp_file($slug, $rel, 'vault');

    my $merged_tmp = "$VAULT_DIR/projects/$slug/.merge-$$-" . random_suffix(6) . ".tmp";
    make_path(dirname($merged_tmp));

    # List-form exec (no shell parsing). Capture stdout, write to merged_tmp,
    # suppress stderr (merge-file emits "warning: conflicts..." which is noise).
    my ($merged_content, $exit) = _run_capture(
        'git', 'merge-file', '-p', '--diff3',
        $local_arg, $base_arg, $vault_arg
    );
    if (open my $fh, '>:raw', $merged_tmp) {
        print $fh $merged_content;
        close $fh;
    }

    return {
        tmp_path  => $merged_tmp,
        exit_code => $exit,
        clean     => ($exit == 0) ? JSON::PP::true : JSON::PP::false,
    };
}

sub empty_temp_file {
    my ($slug, $rel, $tag) = @_;
    my $path = "$VAULT_DIR/projects/$slug/.empty-$tag-$$-" . random_suffix(4) . ".tmp";
    make_path(dirname($path));
    open my $fh, '>:raw', $path or emit_error("Cannot create empty temp: $!");
    close $fh;
    return $path;
}

# ═══════════════════════════════════════════════════════════════════════
# JSON / IO helpers
# ═══════════════════════════════════════════════════════════════════════

sub read_json {
    my $path = shift;
    open my $fh, '<:raw', $path or die "Cannot read $path: $!\n";
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $data = decode_json($raw);
    # decode_json returns utf8-flagged Perl chars. Re-encode strings to raw UTF-8 bytes
    # so they concatenate cleanly with byte-string paths from $ENV (avoids the classic
    # "Latin-1 downgrade" trap that mangles non-ASCII chars in filesystem calls).
    return _encode_strings_recursive($data);
}

sub _encode_strings_recursive {
    my $x = shift;
    if (ref $x eq 'HASH') {
        return { map { $_ => _encode_strings_recursive($x->{$_}) } keys %$x };
    } elsif (ref $x eq 'ARRAY') {
        return [ map { _encode_strings_recursive($_) } @$x ];
    } elsif (ref $x) {
        return $x;
    } elsif (defined $x && utf8::is_utf8($x)) {
        return encode('UTF-8', $x);
    }
    return $x;
}

sub write_json {
    my ($path, $data) = @_;
    make_path(dirname($path));
    my $tmp = "$path$TMP_SUFFIX";
    my $decoded = _decode_strings_recursive($data);
    my $json = JSON::PP->new->utf8->pretty->canonical->encode($decoded);
    open my $fh, '>:raw', $tmp or die "Cannot write $tmp: $!\n";
    print $fh $json;
    close $fh;
    unlink $path if -e $path;
    rename $tmp, $path or die "Cannot rename $tmp -> $path: $!\n";
}

sub emit_json {
    my $data = _decode_strings_recursive(shift);
    print JSON::PP->new->utf8->pretty->canonical->encode($data);
}

sub _decode_strings_recursive {
    my $x = shift;
    if (ref $x eq 'HASH') {
        return { map { $_ => _decode_strings_recursive($x->{$_}) } keys %$x };
    } elsif (ref $x eq 'ARRAY') {
        return [ map { _decode_strings_recursive($_) } @$x ];
    } elsif (ref $x) {
        return $x;  # blessed (e.g. JSON booleans) pass through
    } elsif (defined $x && !utf8::is_utf8($x)) {
        # Numeric scalars: preserve as numbers, not strings
        return $x + 0 if $x =~ /^-?\d+$/;
        return $x + 0 if $x =~ /^-?\d+\.\d+$/;
        my $decoded = eval { decode('UTF-8', $x, Encode::FB_QUIET) };
        return defined $decoded ? $decoded : $x;
    }
    return $x;
}

sub emit_kv {
    my ($k, $v) = @_;
    print "$k: $v\n";
}

sub emit_error {
    my $msg = shift;
    emit_json({ status => 'error', error => $msg });
    exit 1;
}

# ═══════════════════════════════════════════════════════════════════════
# Registry
# ═══════════════════════════════════════════════════════════════════════

sub read_registry {
    if (-f $REGISTRY_PATH) {
        my $reg = read_json($REGISTRY_PATH);
        # Normalize stored paths in case they were written in MSYS form by an older invocation.
        for my $slug (keys %{$reg->{projects} || {}}) {
            $reg->{projects}{$slug}{path} = norm_path($reg->{projects}{$slug}{path});
        }
        return $reg;
    }
    return { version => $REGISTRY_VERSION, projects => {} };
}

sub write_registry {
    my $reg = shift;
    $reg->{version} //= $REGISTRY_VERSION;
    make_path(dirname($REGISTRY_PATH));
    write_json($REGISTRY_PATH, $reg);
}

sub registry_add_project {
    my ($slug, $cwd, $now) = @_;
    my $reg = read_registry();
    $reg->{projects}{$slug} = {
        path           => norm_path($cwd),
        registered_at  => $now,
    };
    write_registry($reg);
}

sub registry_remove_project {
    my $slug = shift;
    my $reg = read_registry();
    delete $reg->{projects}{$slug};
    write_registry($reg);
}

# ═══════════════════════════════════════════════════════════════════════
# Locking
# ═══════════════════════════════════════════════════════════════════════

sub acquire_lock {
    # Fix C2 (red-team): atomic acquire/reclaim via flock on a sibling
    # `.flock` file. Previously two processes could both read a stale
    # metadata lock simultaneously, both decide to reclaim, and both write
    # their own session_id — last writer "won" but first writer also
    # believed it held the lock. flock() makes the read-decide-write of
    # the metadata file mutually exclusive across processes.
    my $path = shift;
    return 1 if $HELD_LOCKS{$path};

    make_path(dirname($path));
    my $flock_path = "$path.flock";

    # Open (or create) the flock sentinel and try to acquire the OS-level mutex.
    # Retry briefly: the critical section is tiny (sub-millisecond), so 2.5s
    # of waiting amply covers any honest contention.
    sysopen(my $flock_fh, $flock_path, O_CREAT | O_RDWR)
        or die "Cannot open flock sentinel $flock_path: $!\n";

    my $got_flock = 0;
    for my $i (1..50) {
        if (flock($flock_fh, LOCK_EX | LOCK_NB)) { $got_flock = 1; last; }
        select(undef, undef, undef, 0.05);  # 50ms × 50 = 2.5s max wait
    }
    unless ($got_flock) {
        close $flock_fh;
        return 0;
    }

    # Mutex held — now the metadata-file read-decide-write is race-free.
    if (-f $path) {
        my $info = read_lock_info($path);
        my $age = time() - ($info->{epoch} // 0);
        if ($info->{session_id} && $info->{session_id} eq $SESSION_ID) {
            # Our own lock — refresh below
        } elsif ($age > $LOCK_STALE_SEC) {
            # Stale — reclaim below
        } else {
            flock($flock_fh, LOCK_UN);
            close $flock_fh;
            return 0;  # Another active session
        }
    }

    open my $mfh, '>:raw', $path or do {
        flock($flock_fh, LOCK_UN);
        close $flock_fh;
        die "Cannot write lock $path: $!\n";
    };
    print $mfh "$SESSION_ID\n$$\n" . iso_now() . "\n";
    close $mfh;

    # Release the OS mutex now that the metadata file durably records our
    # ownership. Other acquirers will see active metadata and back off
    # without needing flock contention.
    flock($flock_fh, LOCK_UN);
    close $flock_fh;

    $HELD_LOCKS{$path} = $SESSION_ID;
    return 1;
}

sub release_lock {
    my $path = shift;
    return unless $HELD_LOCKS{$path};
    # No flock needed for release — we only act if the metadata file still
    # names us as the owner. (A concurrent reclaimer would have rewritten
    # the file with their own session_id; we leave that alone.)
    if (-f $path) {
        my $info = read_lock_info($path);
        if ($info->{session_id} && $info->{session_id} eq $HELD_LOCKS{$path}) {
            unlink $path;
        }
    }
    delete $HELD_LOCKS{$path};
    # We intentionally leave $path.flock in place — other processes may be
    # mid-acquire on it and unlinking races with their sysopen. The sentinel
    # is gitignored via /*.flock pattern and re-used across runs.
}

sub release_all_held_locks {
    for my $path (keys %HELD_LOCKS) {
        release_lock($path);
    }
}

sub read_lock_info {
    my $path = shift;
    open my $fh, '<:raw', $path or return {};
    my @lines = <$fh>;
    close $fh;
    chomp @lines;
    my $epoch = 0;
    if ($lines[2]) {
        # Parse ISO 8601: 2026-05-24T12:34:56Z
        if ($lines[2] =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})/) {
            require Time::Local;
            $epoch = eval { Time::Local::timegm($6, $5, $4, $3, $2 - 1, $1) } // 0;
        }
    }
    return {
        session_id => $lines[0] // '',
        pid        => $lines[1] // '',
        timestamp  => $lines[2] // '',
        epoch      => $epoch,
    };
}

sub generate_session_id {
    return sprintf("vs-%d-%d-%s", time(), $$, random_suffix(8));
}

# ═══════════════════════════════════════════════════════════════════════
# Journal
# ═══════════════════════════════════════════════════════════════════════

sub journal_path {
    my $slug = shift;
    return "$VAULT_DIR/projects/$slug/.sync-journal.json";
}

sub journal_read {
    my $slug = shift;
    my $path = journal_path($slug);
    return { ops => [], phase => 'none' } unless -f $path;
    return read_json($path);
}

sub journal_write {
    my ($slug, $j) = @_;
    write_json(journal_path($slug), $j);
}

sub journal_begin {
    my ($slug, $cwd, $vproj) = @_;
    my $j = {
        started_at => iso_now(),
        slug       => $slug,
        cwd        => $cwd,
        session_id => $SESSION_ID,
        phase      => 'staging',
        ops        => [],
        next_op_id => 1,
    };
    journal_write($slug, $j);
}

sub journal_set_phase {
    my ($slug, $phase) = @_;
    my $j = journal_read($slug);
    $j->{phase} = $phase;
    journal_write($slug, $j);
}

# Fix H4 (red-team): atomic op recording. Previously next_op_id and
# journal_record_op were separate read-modify-writes; a crash between them
# would advance the id counter but lose the op. Now the id is assigned
# inside the same read-modify-write that appends the op.
sub journal_record_op {
    my ($slug, $op) = @_;
    my $j = journal_read($slug);
    unless ($op->{id}) {
        my $id = $j->{next_op_id} // (scalar(@{$j->{ops}}) + 1);
        $j->{next_op_id} = $id + 1;
        $op->{id} = "op-$id";
    }
    push @{$j->{ops}}, $op;
    journal_write($slug, $j);
}

# Compatibility shim — old callers may still reference next_op_id. Returns a
# placeholder that journal_record_op will overwrite when the op lacks an id.
# Kept as no-op for safety; remove once all callers are migrated.
sub next_op_id { return undef }

sub journal_clear {
    my $slug = shift;
    my $path = journal_path($slug);
    unlink $path if -f $path;
}

# Reconcile a leftover journal from a previous interrupted sync.
sub journal_reconcile {
    my ($slug, $cwd, $vproj) = @_;
    my $path = journal_path($slug);
    return { performed => 0 } unless -f $path;

    my $j = journal_read($slug);
    my $phase = $j->{phase} // 'unknown';

    if ($phase eq 'done' || $phase eq 'none') {
        journal_clear($slug);
        return { performed => 1, action => 'cleared_done_journal' };
    }

    if ($phase eq 'staging' || $phase eq 'awaiting_resolution') {
        # Sync was interrupted before any renames committed — just clean up tmps.
        my @cleaned;
        for my $op (@{$j->{ops}}) {
            if ($op->{tmp_path} && -f $op->{tmp_path}) {
                unlink $op->{tmp_path};
                push @cleaned, $op->{tmp_path};
            }
        }
        # Also clean any merge tmp files
        cleanup_merge_tmps($slug);
        journal_clear($slug);
        return { performed => 1, action => 'cleaned_staging_tmps', count => scalar @cleaned };
    }

    if ($phase eq 'renaming' || $phase eq 'sensitive_check' || $phase eq 'committing') {
        # Fix C1 (red-team): on recovery from any phase past staging, run the
        # secret scan BEFORE committing. The old code went straight to git
        # commit+push, completely bypassing the scan and pushing secrets to
        # remote if the original sync crashed between rename and scan.
        # Fix H5 (red-team): also update last_synced_hashes so the next sync
        # doesn't see every file as changed-from-empty-base.
        my $result = finalize_commit($slug, $cwd, $vproj, recovering => 1);
        return { performed => 1, action => "recovered_from_$phase", result => $result };
    }

    # Unknown phase — clear conservatively
    journal_clear($slug);
    return { performed => 1, action => 'cleared_unknown_phase' };
}

sub cleanup_merge_tmps {
    my $slug = shift;
    my $dir = vault_project_dir($slug);
    return unless -d $dir;
    opendir my $dh, $dir or return;
    for my $entry (readdir $dh) {
        next unless $entry =~ /^\.(merge|empty)-/;
        next unless $entry =~ /\.tmp$/;
        unlink "$dir/$entry";
    }
    closedir $dh;
}

# ═══════════════════════════════════════════════════════════════════════
# Vault git helpers
# ═══════════════════════════════════════════════════════════════════════

sub vault_git_ok {
    return _run_silent('git', '-C', $VAULT_DIR, @_) == 0;
}

sub vault_git_output {
    my ($out, $exit) = _run_capture('git', '-C', $VAULT_DIR, @_);
    return $out;
}

sub vault_status_clean {
    my $slug = shift;
    my $status = vault_git_output('status', '--porcelain', '--', "projects/$slug/");
    return length($status) == 0;
}

sub vault_dirty_files {
    my $slug = shift;
    my $status = vault_git_output('status', '--porcelain', '--', "projects/$slug/");
    return [] unless length $status;
    my @files;
    for my $line (split /\n/, $status) {
        $line =~ s/^...//;  # strip status code
        push @files, $line;
    }
    return @files;
}

sub vault_ahead_behind {
    my $ab = vault_git_output('rev-list', '--left-right', '--count', "HEAD...origin/$BRANCH");
    return ($ab =~ /^(\d+)\s+(\d+)$/) ? ($1, $2) : (0, 0);
}

# ═══════════════════════════════════════════════════════════════════════
# Sensitive check integration
# ═══════════════════════════════════════════════════════════════════════

sub run_sensitive_check {
    my $dir = shift;
    # Fix C3 (red-team): fail CLOSED when sensitive-check.sh is missing.
    unless (-f $SENSITIVE_CHECK) {
        return {
            blocked => 1,
            output  => "FAIL-CLOSED: sensitive-check.sh not found at $SENSITIVE_CHECK. " .
                       "Restore the ccpraxis install or set SENSITIVE_CHECK=/path/to/scanner. " .
                       "Refusing to push to vault without the defense-in-depth scan.",
        };
    }
    my ($out, $exit) = _run_capture_both('bash', $SENSITIVE_CHECK, $dir);
    return {
        blocked => ($exit != 0) ? 1 : 0,
        output  => $out,
    };
}

# v1.1.11: returns true if a regex match looks like a documentation reference
# rather than an actual secret. Heuristic: the match is wrapped in inline
# backticks AND the backtick span ends with a truncation marker (..., [REDACTED],
# or <placeholder>). Real secrets pasted into docs are mistakes; truncated
# patterns followed by descriptive prose are intentional.
sub _is_documentation_match {
    my ($line, $match_start, $match_end) = @_;

    my $before = substr($line, 0, $match_start);
    # Match must be after an opening backtick (odd count before)
    my $bt_before = ($before =~ tr/`//);
    return 0 unless ($bt_before % 2) == 1;

    # Find the closing backtick after the match
    my $close_bt = index($line, '`', $match_end);
    return 0 if $close_bt == -1;

    # Extract the full backtick-span content
    my $open_bt   = rindex($before, '`');
    my $span      = substr($line, $open_bt + 1, $close_bt - $open_bt - 1);

    # Truncation markers
    return 1 if $span =~ /\.\.\.\s*$/;        # `prefix-...`
    return 1 if $span =~ /\[REDACTED\]/i;     # `prefix-[REDACTED]`
    return 1 if $span =~ /<[^>]+>\s*$/;       # `prefix-<YOUR_KEY>`
    return 1 if $span =~ /XXXX/i;             # `prefix-XXXXXXXX`

    return 0;
}

sub scan_dir_for_secrets {
    # Recursively scan all files in a directory using the Perl-native scanner.
    # Walks every file regardless of extension (sensitive-check.sh only scans
    # a fixed extension allowlist — that's the H11 gap). Skips symlinks and
    # binary files (null-byte detection inside scan_files_for_secrets).
    my $dir = shift;
    return [] unless -d $dir;
    my @files;
    find({
        no_chdir => 1,
        wanted => sub {
            return if -l $_;
            return unless -f $_;
            push @files, $_;
        },
    }, $dir);
    return scan_files_for_secrets(@files);
}

sub scan_files_for_secrets {
    my @files = @_;
    my @findings;
    for my $file (@files) {
        next unless -f $file;
        open my $fh, '<:raw', $file or next;
        my $content = do { local $/; <$fh> };
        close $fh;
        # Skip binary files (sensitive-check.sh effectively only matches text)
        next if $content =~ /\0/;
        my @lines = split /\n/, $content;
        my $line_no = 0;
        for my $line (@lines) {
            $line_no++;
            for my $entry (@SECRET_PATTERNS) {
                my ($label, $pat) = @$entry;
                next unless $line =~ $pat;
                my ($match_start, $match_end) = ($-[0], $+[0]);

                # False-positive suppression: literal substring blacklist.
                my $fp = 0;
                for my $skip (@SECRET_FALSE_POSITIVE_SUBSTRINGS) {
                    if (index($line, $skip) >= 0) { $fp = 1; last; }
                }
                next if $fp;

                # v1.1.11: documentation-convention check. A match wrapped in
                # inline backticks AND followed by a truncation marker is
                # documentation, not a real secret. Skip it.
                next if _is_documentation_match($line, $match_start, $match_end);

                push @findings, {
                    file    => $file,
                    line    => $line_no,
                    pattern => $label,
                    context => substr($line, 0, 200),
                };
            }
        }
    }
    return \@findings;
}

# ═══════════════════════════════════════════════════════════════════════
# Misc helpers
# ═══════════════════════════════════════════════════════════════════════

sub parse_opts {
    my ($args, @valid) = @_;
    my %valid = map { $_ => 1 } @valid;
    my %opts;
    my @remain = @$args;
    while (defined(my $arg = shift @remain)) {
        if ($arg =~ /^--([\w-]+)$/) {
            my $key = $1;
            unless ($valid{$key}) {
                emit_error("Unknown option: --$key");
            }
            # Look ahead: if next arg starts with --, treat current as boolean flag
            if (!@remain || $remain[0] =~ /^--/) {
                $opts{$key} = 1;
            } else {
                $opts{$key} = shift @remain;
            }
        } else {
            emit_error("Unexpected positional argument: $arg");
        }
    }
    @$args = ();
    return %opts;
}

sub require_opt {
    my ($opts, $key) = @_;
    unless (defined $opts->{$key} && length $opts->{$key}) {
        emit_error("Missing required option: --$key");
    }
    return $opts->{$key};
}

sub iso_now {
    return strftime("%Y-%m-%dT%H:%M:%SZ", gmtime());
}

# ═══════════════════════════════════════════════════════════════════════
# Process execution (fork+exec, no shell)
# ═══════════════════════════════════════════════════════════════════════
#
# All external commands route through these helpers. List-form exec means
# arguments are passed to the OS as a vector — no shell interpretation, no
# quoting required, no injection vector regardless of perl flavor or path
# contents. Closes red-team H12 entirely; deprecates shq() and capture().

sub _run_silent {
    # Run command list. Suppress stdout AND stderr. Return exit code (0 = success).
    my @args = @_;
    my $pid = fork();
    return -1 unless defined $pid;
    if ($pid == 0) {
        open STDOUT, '>', File::Spec->devnull;
        open STDERR, '>', File::Spec->devnull;
        exec { $args[0] } @args;
        exit 127;
    }
    waitpid $pid, 0;
    return $? >> 8;
}

sub _run_capture {
    # Run command list. Capture stdout (chomped). Suppress stderr.
    # Returns ($output, $exit_code).
    my @args = @_;
    my ($r, $w);
    pipe $r, $w or return ('', -1);
    my $pid = fork();
    unless (defined $pid) { close $r; close $w; return ('', -1); }
    if ($pid == 0) {
        close $r;
        open STDOUT, '>&', $w;
        open STDERR, '>', File::Spec->devnull;
        exec { $args[0] } @args;
        exit 127;
    }
    close $w;
    local $/;
    my $out = <$r>;
    close $r;
    waitpid $pid, 0;
    $out //= '';
    $out =~ s/[\r\n]+\z//;  # strip ALL trailing newlines (chomp only removes one)
    return ($out, $? >> 8);
}

sub _run_capture_both {
    # Run command list. Capture combined stdout+stderr.
    # Returns ($output, $exit_code).
    my @args = @_;
    my ($r, $w);
    pipe $r, $w or return ('', -1);
    my $pid = fork();
    unless (defined $pid) { close $r; close $w; return ('', -1); }
    if ($pid == 0) {
        close $r;
        open STDOUT, '>&', $w;
        open STDERR, '>&', $w;
        exec { $args[0] } @args;
        exit 127;
    }
    close $w;
    local $/;
    my $out = <$r>;
    close $r;
    waitpid $pid, 0;
    $out //= '';
    $out =~ s/[\r\n]+\z//;  # strip ALL trailing newlines (chomp only removes one)
    return ($out, $? >> 8);
}

sub _run_capture_close_fds {
    # Like _run_capture but the child closes the given fds before exec. Use
    # when the parent holds resources (open file handles backing flocks, in
    # particular) that the child must not inherit. On Cygwin/MSYS Perl, fork
    # inherits all fds POSIX-style, so without this the child holds extra
    # references to the parent's lock files — behaviorally correct (the
    # parent retains the lock through its own fd) but unhygienic and
    # potentially confusing on Win32 Perl where flock/inheritance semantics
    # are platform-specific.
    my ($close_fds, @args) = @_;
    my ($r, $w);
    pipe $r, $w or return ('', -1);
    my $pid = fork();
    unless (defined $pid) { close $r; close $w; return ('', -1); }
    if ($pid == 0) {
        close $r;
        close $_ for @$close_fds;
        open STDOUT, '>&', $w;
        open STDERR, '>', File::Spec->devnull;
        exec { $args[0] } @args;
        exit 127;
    }
    close $w;
    local $/;
    my $out = <$r>;
    close $r;
    waitpid $pid, 0;
    $out //= '';
    $out =~ s/[\r\n]+\z//;
    return ($out, $? >> 8);
}

sub ensure_gitignored {
    my ($cwd, $pattern) = @_;
    my $gi = "$cwd/.gitignore";
    my @lines;
    if (-f $gi) {
        open my $fh, '<', $gi or return;
        @lines = <$fh>;
        close $fh;
        chomp @lines;
        for my $line (@lines) {
            return if $line eq $pattern;
        }
    }
    open my $fh, '>>', $gi or return;
    print $fh "\n" if @lines && $lines[-1] ne '';
    print $fh "$pattern\n";
    close $fh;
}
