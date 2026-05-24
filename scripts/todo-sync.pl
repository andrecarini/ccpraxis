#!/usr/bin/env perl
# todo-sync.pl — Git sync, listing, and creation for custom todos
# Used by /create-todo, /manage-todos, /resume-todo skills
#
# Subcommands:
#   init <repo-url>                          Clone the todo repo from the given URL
#   status                                  Check repo health
#   sync [message]                          Fetch, pull --rebase, commit, push
#   list                                    List all todos with metadata
#   create <name> [--title T] [--tags t,t]  Create a new todo (reads content from stdin)
#   done <name>                             Mark done, move to archive/

use strict;
use warnings;
use POSIX qw(strftime);
use Cwd qw(getcwd);
use File::Basename qw(basename);

my $home = $ENV{HOME} // $ENV{USERPROFILE};
die "Cannot determine home directory\n" unless $home;
$home =~ s/\\/\//g;

my $VAULT_DIR = "$home/.claude/claude-code-vault";
my $TODO_DIR  = "$VAULT_DIR/todos";
my $BRANCH    = "main";

my $cmd = shift @ARGV // "help";

if    ($cmd eq "init")   { cmd_init()   }
elsif ($cmd eq "status") { cmd_status() }
elsif ($cmd eq "sync")   { cmd_sync()   }
elsif ($cmd eq "list")   { cmd_list()   }
elsif ($cmd eq "create") { cmd_create() }
elsif ($cmd eq "done")   { cmd_done()   }
else                     { cmd_help()   }

exit 0;

# ── Subcommands ──────────────────────────────────────────────────────

sub cmd_init {
    # Already initialized? Report and exit.
    if (-d "$VAULT_DIR/.git") {
        my $remote = git_output("-C", $VAULT_DIR, "remote", "get-url", "origin");
        if ($remote) {
            emit("STATUS", "exists");
            emit("PATH",   $TODO_DIR);
            emit("REMOTE", $remote);
            emit("AUTH",   auth_type($remote));
            return;
        }
    }

    my $url = shift @ARGV;
    unless ($url) {
        emit("STATUS", "error");
        emit("ERROR",  "Usage: todo-sync.pl init <repo-url>");
        exit 1;
    }

    # v1.1 consolidation: delegate vault scaffolding to vault-sync.pl so there's
    # exactly ONE canonical vault scaffolder (was: both scripts could initialize,
    # with subtle differences — gitignore entries, .gitattributes presence).
    my $vault_sync = "$home/.claude/ccpraxis/scripts/vault-sync.pl";
    unless (-f $vault_sync) {
        emit("STATUS", "error");
        emit("ERROR",  "vault-sync.pl not found at $vault_sync — cannot init vault. Ensure ccpraxis is installed.");
        exit 1;
    }

    my $rc = system('perl', $vault_sync, 'init', '--url', $url);
    if ($rc != 0) {
        emit("STATUS", "error");
        emit("ERROR",  "vault-sync.pl init failed (exit " . ($rc >> 8) . "). Re-run for full diagnostics.");
        exit 1;
    }

    # Ensure todos/ subdir exists (vault-sync.pl creates it via the scaffold,
    # but if the user cloned a non-empty vault that lacks todos/, create it now).
    mkdir $TODO_DIR unless -d $TODO_DIR;

    emit("STATUS", "cloned");
    emit("PATH",   $TODO_DIR);
    emit("REMOTE", $url);
    emit("AUTH",   auth_type($url));
}

sub cmd_status {
    unless (-d "$VAULT_DIR/.git") {
        emit("STATUS", "missing");
        emit("PATH",   $TODO_DIR);
        return;
    }

    my $remote = git_output("-C", $VAULT_DIR, "remote", "get-url", "origin");
    unless ($remote) {
        emit("STATUS", "no_remote");
        emit("PATH",   $TODO_DIR);
        return;
    }

    my $can_fetch = git_ok("-C", $VAULT_DIR, "fetch", "origin") ? "yes" : "no";
    my $clean     = is_clean() ? "yes" : "no";
    my ($ahead, $behind) = ahead_behind();

    emit("STATUS",    "ok");
    emit("PATH",      $TODO_DIR);
    emit("REMOTE",    $remote);
    emit("AUTH",      auth_type($remote));
    emit("CAN_FETCH", $can_fetch);
    emit("CLEAN",     $clean);
    emit("AHEAD",     $ahead);
    emit("BEHIND",    $behind);
}

sub cmd_sync {
    my $message = join(" ", @ARGV) || "Update todos";

    unless (-d "$VAULT_DIR/.git") {
        emit("STATUS", "error");
        emit("ERROR",  "Repo not initialized. Run: todo-sync.pl init");
        exit 1;
    }

    unless (git_ok("-C", $VAULT_DIR, "fetch", "origin")) {
        emit("STATUS", "error");
        emit("ERROR",  "Cannot fetch from remote. Check connectivity.");
        exit 1;
    }

    my ($ahead, $behind) = ahead_behind();
    my $dirty = !is_clean();
    my ($pulled, $committed, $pushed) = ("no", "no", "no");

    # Pull if behind
    if ($behind > 0) {
        if ($dirty) {
            git_ok("-C", $VAULT_DIR, "stash", "-u");
        }
        unless (git_ok("-C", $VAULT_DIR, "pull", "--rebase", "origin", $BRANCH)) {
            emit("STATUS", "conflict");
            emit("ERROR",  "Rebase conflict during pull. Resolve in $TODO_DIR");
            exit 1;
        }
        if ($dirty) {
            unless (git_ok("-C", $VAULT_DIR, "stash", "pop")) {
                emit("STATUS", "conflict");
                emit("ERROR",  "Local changes conflict with remote after pull. Resolve in $TODO_DIR");
                exit 1;
            }
        }
        $pulled = "yes";
    }

    # Commit local changes
    unless (is_clean()) {
        # Scope to todos/ so we don't accidentally commit projects/ or other vault changes.
        git_ok("-C", $VAULT_DIR, "add", "todos/");
        if (git_ok("-C", $VAULT_DIR, "commit", "-m", $message)) {
            $committed = "yes";
        }
    }

    # Push if ahead
    ($ahead, $behind) = ahead_behind();
    if ($ahead > 0) {
        if (git_ok("-C", $VAULT_DIR, "push", "origin", $BRANCH)) {
            $pushed = "yes";
        } else {
            emit("STATUS", "error");
            emit("ERROR",  "Push failed.");
            exit 1;
        }
    }

    emit("STATUS",    "ok");
    emit("PULLED",    $pulled);
    emit("COMMITTED", $committed);
    emit("PUSHED",    $pushed);
}

sub cmd_list {
    unless (-d $TODO_DIR) {
        emit("STATUS", "empty");
        emit("TOTAL",  "0");
        return;
    }

    opendir my $dh, $TODO_DIR or die "Cannot open $TODO_DIR: $!\n";
    my @files = sort grep { /\.md$/ && $_ ne "README.md" } readdir $dh;
    closedir $dh;

    my ($n_open, $n_done, $n_cancelled) = (0, 0, 0);

    for my $file (@files) {
        (my $name = $file) =~ s/\.md$//;

        open my $fh, "<", "$TODO_DIR/$file" or next;
        my $raw = do { local $/; <$fh> };
        close $fh;

        my ($status, $created, $tags, $title, $cwd) = parse_todo($raw, $name);
        my $cwd_short = $cwd ? basename($cwd) : "";

        $n_open++      if $status eq "open";
        $n_done++      if $status eq "done";
        $n_cancelled++ if $status eq "cancelled";

        print "TODO: $name | status:$status | created:$created | tags:$tags | cwd:$cwd_short | $title\n";
    }

    my $total = scalar @files;

    # Count archived todos
    my $n_archived = 0;
    if (-d "$TODO_DIR/archive") {
        opendir my $adh, "$TODO_DIR/archive" or die "Cannot open archive: $!\n";
        $n_archived = scalar grep { /\.md$/ } readdir $adh;
        closedir $adh;
    }

    my $summary = "TOTAL: $total ($n_open open, $n_done done, $n_cancelled cancelled)";
    $summary .= " + $n_archived archived" if $n_archived > 0;
    print "$summary\n";
}

sub cmd_create {
    my $name = shift @ARGV;
    unless ($name) {
        emit("STATUS", "error");
        emit("ERROR",  "Usage: todo-sync.pl create <name> [--title T] [--tags t1,t2]");
        exit 1;
    }

    # Parse optional flags
    my ($title, $tags) = ("", "");
    while (my $arg = shift @ARGV) {
        if    ($arg eq "--title" && @ARGV) { $title = shift @ARGV }
        elsif ($arg eq "--tags"  && @ARGV) { $tags  = shift @ARGV }
    }

    # Read content from stdin if piped
    my $content = "";
    unless (-t STDIN) {
        local $/;
        $content = <STDIN> // "";
        chomp $content;
    }

    $title ||= name_to_title($name);
    my $tag_yaml = $tags ? "[$tags]" : "[]";
    my $today    = strftime("%Y-%m-%d", localtime);
    my $cwd      = getcwd();

    unless (-d $TODO_DIR) {
        emit("STATUS", "error");
        emit("ERROR",  "Todo directory does not exist. Run: todo-sync.pl init");
        exit 1;
    }

    my $file = "$TODO_DIR/$name.md";
    if (-f $file) {
        emit("STATUS", "exists");
        emit("PATH",   $file);
        emit("NAME",   $name);
        return;
    }

    my $body = join("",
        "---\n",
        "created: $today\n",
        "status: open\n",
        "tags: $tag_yaml\n",
        "cwd: $cwd\n",
        "---\n\n",
        "# $title\n",
        ($content ne "" ? "\n$content\n" : ""),
    );

    write_file($file, $body);

    emit("STATUS", "created");
    emit("PATH",   $file);
    emit("NAME",   $name);
}

sub cmd_done {
    my $name = shift @ARGV;
    unless ($name) {
        emit("STATUS", "error");
        emit("ERROR",  "Usage: todo-sync.pl done <name>");
        exit 1;
    }

    my $file = "$TODO_DIR/$name.md";
    unless (-f $file) {
        emit("STATUS", "error");
        emit("ERROR",  "Todo not found: $name");
        exit 1;
    }

    # Read and update status in frontmatter
    open my $fh, "<", $file or die "Cannot read $file: $!\n";
    my $raw = do { local $/; <$fh> };
    close $fh;

    $raw =~ s/^(status:\s*).*$/${1}done/m;

    # Create archive directory and move the file
    my $archive_dir = "$TODO_DIR/archive";
    mkdir $archive_dir unless -d $archive_dir;

    my $dest = "$archive_dir/$name.md";
    write_file($dest, $raw);
    unlink $file;

    emit("STATUS",   "archived");
    emit("NAME",     $name);
    emit("ARCHIVED", $dest);
}

sub cmd_help {
    print "Usage: todo-sync.pl <command> [args]\n\n";
    print "Commands:\n";
    print "  init <repo-url>                          Clone the todo repo from the given URL\n";
    print "  status                                  Check repo health\n";
    print "  sync [message]                          Fetch, pull, commit, push\n";
    print "  list                                    List all todos\n";
    print "  create <name> [--title T] [--tags t,t]  Create a new todo (reads content from stdin)\n";
    print "  done <name>                             Mark done, move to archive/\n";
}

# ── Helpers ──────────────────────────────────────────────────────────

sub emit {
    my ($key, $val) = @_;
    print "$key: $val\n";
}

sub parse_todo {
    my ($raw, $fallback_name) = @_;
    my ($status, $created, $tags, $title, $cwd) = ("open", "", "", $fallback_name, "");

    if ($raw =~ /\A---\s*\n(.*?)\n---/s) {
        my $fm = $1;
        $status  = $1 if $fm =~ /^status:\s*(.+)$/m;
        $created = $1 if $fm =~ /^created:\s*(.+)$/m;
        $tags    = $1 if $fm =~ /^tags:\s*\[([^\]]*)\]/m;
        $cwd     = $1 if $fm =~ /^cwd:\s*(.+)$/m;
    }

    $title = $1 if $raw =~ /^#\s+(.+)$/m;

    return ($status, $created, $tags, $title, $cwd);
}

sub name_to_title {
    my $name = shift;
    $name =~ s/-/ /g;
    return ucfirst($name);
}

sub auth_type {
    my $url = shift;
    return ($url =~ /^git@/) ? "ssh" : "https";
}

sub is_clean {
    return git_output("-C", $VAULT_DIR, "status", "--porcelain", "--", "todos/") eq "";
}

sub ahead_behind {
    my $ab = git_output("-C", $VAULT_DIR, "rev-list", "--left-right", "--count",
                        "HEAD...origin/$BRANCH");
    return ($ab =~ /^(\d+)\s+(\d+)$/) ? ($1, $2) : (0, 0);
}

# Run a git command, capture stdout, suppress stderr. Returns chomped output.
sub git_output {
    my @args = @_;
    my $cmd = "git " . join(" ", map { shell_escape($_) } @args) . " 2>/dev/null";
    my $out = `$cmd`;
    chomp $out if defined $out;
    return $out // "";
}

# Run a git command silently. Returns true on success.
sub git_ok {
    my @args = @_;
    my $cmd = "git " . join(" ", map { shell_escape($_) } @args) . " >/dev/null 2>&1";
    system($cmd);
    return ($? == 0);
}

sub shell_escape {
    my $s = shift;
    $s =~ s/'/'\\''/g;
    return "'$s'";
}

sub write_file {
    my ($path, $content) = @_;
    open my $fh, ">", $path or die "Cannot write $path: $!\n";
    print $fh $content;
    close $fh;
}
