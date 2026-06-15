#!/usr/bin/perl
# plugins/sandbox/scripts/skills.pl - discovery, state, and selection management
# for the claude-sandbox launcher. All DRY logic lives here.
#
# Subcommands (see `help` for details):
#   discover                List available custom skills as JSON.
#   discover-plugins        List plugins for this project as JSON (with project/suggestion partition).
#   discover-mcp            List MCP servers for this project as JSON (with project/suggestion partition).
#   load-selection          Print current state file (with v1->v2->v3 migration).
#   prune                   Drop dead entries from selected/known; write state.
#   diff                    Compare current discovery to mounted baseline.
#   select-interactive      TUI selector (arrow keys + space) for skills, plugins, and MCP.
#   mounts                  Emit tab-separated host_path<TAB>skill_name for launcher.
#   record-mount            Set mounted_at_create + mounted_plugins_at_create; write state.
#   manifest                Emit JSON manifest of mounted skills + plugins for container.
#   materialize-plugins              Emit a container-shaped installed_plugins.json (paths rewritten).
#   materialize-credentials          Emit sandbox-isolated .credentials.json.
#   materialize-known-marketplaces   Emit container-shaped known_marketplaces.json (paths rewritten).
#   write-mcp-state         Overwrite enabledMcp/disabledMcp lists in settings.local.json.
#   clone-to-project        Promote a Suggestion to Project (plugin or MCP); idempotent.
#   help                    Show usage.

use strict;
use warnings;
use JSON::PP;
use Encode qw(decode);
use Fcntl qw(:flock);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use POSIX qw(strftime);

our $SCHEMA_VERSION = 3;

# Where the host stores its plugin tree. Container mount target uses the same
# layout under /root/.claude/plugins/ via materialize-plugins.
our $CONTAINER_PLUGINS_ROOT = '/root/.claude/plugins';
our $CONTAINER_PROJECT_PATH = '/project';

# Strings from $ENV{HOME}, readdir(), etc. arrive as raw UTF-8 bytes on Git Bash.
# decode_json() returns Unicode-decoded strings. We need them in the SAME perl
# internal form, otherwise concatenating them produces double-encoded output.
# Strategy: decode filesystem-sourced strings on input; set UTF-8 encoding on
# stdio so output re-encodes consistently.
binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';
binmode STDIN,  ':encoding(UTF-8)';

# Decode a byte string from the filesystem / env / argv.
# Returns the input unchanged if it is already a Unicode (decoded) string.
#
# Tries UTF-8 first (Git Bash / Linux / macOS), then falls back to CP1252
# (Windows-1252) — necessary because cygwin perl launched directly from
# PowerShell receives env vars and argv with CP1252-encoded high bytes
# (e.g. `é` arrives as the single byte 0xE9, not the UTF-8 two-byte
# sequence 0xC3 0xA9). Without the fallback, FB_DEFAULT replaces invalid
# UTF-8 bytes with U+FFFD and every path with a non-ASCII char in the
# Windows username silently breaks.
sub from_fs {
    my $s = shift;
    return undef unless defined $s;
    return $s if utf8::is_utf8($s);
    my $decoded = eval { decode('UTF-8', $s, Encode::FB_CROAK) };
    return $decoded if defined $decoded;
    return decode('cp1252', $s, Encode::FB_DEFAULT);
}

# =====================================================================
# Helpers
# =====================================================================

sub home {
    return from_fs($ENV{HOME} // die "HOME not set\n");
}

# Normalize Windows paths to Git Bash form: backslashes → slashes, C: → /c
# Fails fast on WSL and Cygwin mount conventions because we don't yet handle
# them — silently passing them through used to produce mismatches deep in
# discover/clone logic that surfaced as "no install found" or duplicate
# project-scope entries on re-run. Explicit failure here is loud and points
# the user at the right fix (run from Git Bash or PowerShell).
sub normalize_path {
    my $p = shift;
    return undef unless defined $p;
    if ($p =~ m{^/mnt/[a-zA-Z](?:/|$)}) {
        die "WSL mount path detected ($p): plugins/sandbox/scripts/skills.pl is not implemented for WSL - please run from Git Bash or PowerShell on Windows.\n";
    }
    if ($p =~ m{^/cygdrive/[a-zA-Z](?:/|$)}) {
        die "Cygwin mount path detected ($p): plugins/sandbox/scripts/skills.pl is not implemented for Cygwin - please run from Git Bash or PowerShell on Windows.\n";
    }
    $p =~ s|\\|/|g;
    $p =~ s|^([A-Za-z]):|"/" . lc($1)|e;
    return $p;
}

# Convert Git Bash form back to Windows form for storage in files that
# Claude Code writes (installed_plugins.json uses "C:\\..." entries).
# Idempotent: passes through paths that are already Windows-style or plain
# Unix paths on Linux hosts. WSL/Cygwin paths can never reach this function
# because normalize_path dies on them first.
sub denormalize_to_windows {
    my $p = shift;
    return undef unless defined $p;
    if ($p =~ s|^/([a-zA-Z])/|uc($1) . ":/"|e) {
        $p =~ s|/|\\|g;
    }
    return $p;
}

sub read_json {
    my $file = shift;
    open my $fh, '<:raw', $file or return undef;
    local $/;
    my $content = <$fh>;
    close $fh;
    # decode_json expects UTF-8 bytes and returns Unicode strings.
    my $data = eval { decode_json($content) };
    return $@ ? undef : $data;
}

# Variant for files that a concurrent process may be rewriting atomically
# (write-tmp + rename). The window for a torn read is brief but real on
# Windows hosts where ~/.claude/.credentials.json rotates while the
# launcher reads it. Retry 3 times with 100ms between attempts; die loudly
# if the file is consistently unreadable, since a silent `{}` fallback
# strips fields callers depend on.
sub read_json_with_retry {
    my $file = shift;
    for my $attempt (1..3) {
        my $data = read_json($file);
        return $data if defined $data;
        select(undef, undef, undef, 0.1) if $attempt < 3;
    }
    die "read_json_with_retry: '$file' exists but could not be parsed after 3 attempts (host may be mid-rewrite or file is corrupt)\n";
}

sub write_json_atomic {
    my ($file, $data) = @_;
    my $dir = dirname($file);
    make_path($dir) unless -d $dir;
    my $tmp = "$file.tmp.$$";
    open my $fh, '>:raw', $tmp or die "write $tmp: $!\n";
    print $fh JSON::PP->new->canonical(1)->pretty->utf8->encode($data);
    close $fh or die "close $tmp: $!\n";
    rename $tmp, $file or do {
        unlink $tmp;
        die "rename $tmp -> $file: $!\n";
    };
}

# Returns 'visible', 'host-only', or 'missing'.
# Scans only the YAML frontmatter region (between the first two `^---$` lines)
# so a code block or quoted prose in the body containing "host-only: true"
# can't false-positive.
sub skill_host_only_status {
    my $skill_md = shift;
    return 'missing' unless -f $skill_md;
    open my $fh, '<:encoding(UTF-8)', $skill_md or return 'missing';
    my $in_frontmatter = 0;
    my $saw_opening = 0;
    while (my $line = <$fh>) {
        if ($line =~ /^---\s*$/) {
            if (!$saw_opening) {
                $saw_opening = 1;
                $in_frontmatter = 1;
                next;
            } else {
                last;  # closing fence — host-only must be in frontmatter
            }
        }
        next unless $in_frontmatter;
        if ($line =~ /^host-only:\s*true\b/i) {
            close $fh;
            return 'host-only';
        }
    }
    close $fh;
    return 'visible';
}

sub now_iso {
    return strftime('%Y-%m-%dT%H:%M:%SZ', gmtime);
}

# =====================================================================
# Discovery
# =====================================================================

sub discover_skills {
    my %opts = @_;

    # Discovery-snapshot pinning. If the launcher passed --discovery-snapshot,
    # every subcommand in this run uses the same frozen view of available skills.
    # This makes the launcher immune to plugin install/uninstall happening mid-run
    # (a concurrent `/plugin install` in another terminal would otherwise change
    # what discover_skills returns between subcommand invocations).
    if (my $snap = $opts{discovery_snapshot}) {
        if (-f $snap) {
            my $data = read_json($snap);
            if (ref $data eq 'ARRAY') {
                return $data;
            }
            warn "Warning: discovery snapshot $snap is malformed; falling back to live discovery.\n";
        }
        # Snapshot path provided but file missing — fall through to live discovery
        # (the launcher will have generated it; missing means a race, just rediscover).
    }

    my @skills;

    # Custom skills only. Plugin-shipped skills are now exposed by plugin
    # selection (see `discover_plugins`), not as individual skill mounts.
    my $custom_dir = home() . "/.claude/ccpraxis/skills";
    if (-d $custom_dir) {
        if (opendir my $dh, $custom_dir) {
            for my $entry (sort grep { $_ !~ /^\.\.?$/ } map { from_fs($_) } readdir $dh) {
                my $skill_dir = "$custom_dir/$entry";
                next unless -d $skill_dir;
                my $status = skill_host_only_status("$skill_dir/SKILL.md");
                next if $status eq 'missing' || $status eq 'host-only';
                push @skills, {
                    name => $entry,
                    source => 'custom',
                    path => $skill_dir,
                };
            }
            closedir $dh;
        }
    }

    return \@skills;
}

# =====================================================================
# Plugin discovery
# =====================================================================
#
# Reads installed_plugins.json and the project's .claude/settings.json,
# then returns one entry per plugin key whose best install is relevant to
# the current project.
#
# "Best install" priority per key:
#   1. scope=project AND projectPath matches this project
#   2. scope=local   AND projectPath matches this project
#   3. scope=user
# Within a tier, later installs in the array win (Claude Code's "latest
# install wins" tiebreaker).
#
# Partition assignment per entry:
#   "project"    => best install is project-scope-for-this-project AND key
#                   APPEARS (any value) in <project>/.claude/settings.json
#                   enabledPlugins. An explicit `false` still counts as
#                   "project" — the user has made a decision about this
#                   install, even if that decision is to keep it off.
#   "suggestion" => everything else (user-scope, matching-project local-scope,
#                   or matching-project project-scope with no entry in
#                   settings.json yet)
#
# The `enabled` field is the truthiness of enabledPlugins[K] (missing/false/
# null → false; truthy → true). The TUI uses this to set the initial
# checkbox state for Project rows.
#
# Returns: [{ key, label, install_path, scope, project_path, version,
#             partition, enabled }]
sub discover_plugins {
    my %opts = @_;

    if (my $snap = $opts{plugins_snapshot}) {
        if (-f $snap) {
            my $data = read_json($snap);
            if (ref $data eq 'ARRAY') {
                return $data;
            }
            warn "Warning: plugins snapshot $snap is malformed; falling back to live discovery.\n";
        }
    }

    my $plugins_file = $opts{plugins_file} // home() . "/.claude/plugins/installed_plugins.json";
    # Normalize whatever shape the launcher passes (Windows form from PS,
    # Git Bash form from sh) so the lc() comparison below works either way.
    # Unlike discover_mcp, we do NOT early-return when --project-path is
    # omitted: user-scope plugins are global (no project context required)
    # and a caller running without a project still wants to see them as
    # suggestions. MCP servers, by contrast, are defined in <project>/.mcp.json
    # — without a project they're meaningless.
    my $project_path = normalize_path($opts{project_path});

    my @plugins;
    return \@plugins unless -f $plugins_file;

    my $data = read_json($plugins_file);
    if (!defined $data) {
        warn "Warning: $plugins_file is malformed or unreadable; skipping plugins.\n";
        return \@plugins;
    }
    if (ref($data) ne 'HASH' || ref($data->{plugins}) ne 'HASH') {
        warn "Warning: $plugins_file has unexpected shape (no 'plugins' object); skipping.\n";
        return \@plugins;
    }

    # Read enabledPlugins from <project>/.claude/settings.json. Missing file
    # or missing key => empty set (everything will partition as suggestion).
    # settings.local.json is intentionally NOT consulted — settings.json is
    # the project's source of truth, regardless of whether the project
    # commits it to git or treats it as a personal file.
    #
    # We track presence (any value) separately from truthiness because the
    # partition rule uses presence (so a key set to `false` still partitions
    # as "project" — it's a deliberate user decision) while the `enabled`
    # field uses truthiness (so the TUI's initial checkbox state matches the
    # current effective state).
    my %settings_plugins;  # key => raw value (true/false/null/missing)
    if (defined $project_path && length $project_path) {
        my $settings_file = "$project_path/.claude/settings.json";
        if (-f $settings_file) {
            my $s = read_json($settings_file);
            if (ref $s eq 'HASH' && ref $s->{enabledPlugins} eq 'HASH') {
                for my $key (keys %{$s->{enabledPlugins}}) {
                    $settings_plugins{$key} = $s->{enabledPlugins}{$key};
                }
            }
        }
    }

    for my $key (sort keys %{$data->{plugins}}) {
        my $installs = $data->{plugins}{$key};
        next unless ref $installs eq 'ARRAY' && @$installs;

        my ($best, $best_rank);
        for my $inst (@$installs) {
            next unless ref $inst eq 'HASH';
            my $install_path = $inst->{installPath};
            next unless defined $install_path && length $install_path;

            my $scope = $inst->{scope} // 'local';
            my $inst_project = normalize_path($inst->{projectPath} // '');
            my $matches_project = defined $project_path && length $project_path
                && length $inst_project
                && lc($inst_project) eq lc($project_path);

            my $rank;
            if    ($scope eq 'project' && $matches_project) { $rank = 1 }
            elsif ($scope eq 'local'   && $matches_project) { $rank = 2 }
            elsif ($scope eq 'user')                        { $rank = 3 }
            # Unknown scope: behave like 'local' (requires project match) so
            # we never blindly surface installs targeted at other projects.
            elsif ($matches_project)                        { $rank = 2 }
            else { next }

            # Lower rank wins. Equal rank => later install wins (overwrite).
            if (!defined $best_rank || $rank <= $best_rank) {
                $best      = $inst;
                $best_rank = $rank;
            }
        }
        next unless defined $best;

        my $scope         = $best->{scope} // 'local';
        my $install_path  = normalize_path($best->{installPath});
        my $entry_project = normalize_path($best->{projectPath} // '');

        my $partition = ($scope eq 'project'
                         && length $entry_project
                         && defined $project_path
                         && lc($entry_project) eq lc($project_path)
                         && exists $settings_plugins{$key})
            ? 'project'
            : 'suggestion';

        # `enabled` is the truthiness of the settings.json value (missing or
        # null or false → false; truthy → true). JSON::PP::Boolean handles
        # JSON true/false via boolean overload; bare undef and missing keys
        # both yield false through Perl's normal boolean context.
        my $enabled = (exists $settings_plugins{$key} && $settings_plugins{$key})
            ? JSON::PP::true
            : JSON::PP::false;

        my ($label) = $key =~ /^([^@]+)/;
        $label //= $key;

        push @plugins, {
            key          => $key,
            label        => $label,
            install_path => $install_path,
            scope        => $scope,
            project_path => $entry_project,
            version      => $best->{version},
            partition    => $partition,
            enabled      => $enabled,
        };
    }

    return \@plugins;
}

# =====================================================================
# State (selected-skills.json) management
# =====================================================================

sub load_state {
    my $file = shift;
    my $file_existed = -f $file;
    my $data;
    if ($file_existed) {
        $data = read_json($file);
        if (!$data || ref $data ne 'HASH') {
            warn "Warning: $file is malformed, treating as empty.\n";
            $data = {};
            $file_existed = 0;
        }
    } else {
        $data = {};
    }

    my $existing_version = $data->{schema_version} // 0;  # missing => v1
    my $needs_v1_migration = $file_existed && $existing_version < 1;
    my $needs_v3_migration = $file_existed && $existing_version < 3;

    # Skill-side defaults
    $data->{selected} //= [];
    $data->{known} //= [];
    $data->{mounted_at_create} //= [];

    # Plugin-side defaults (introduced in v3)
    $data->{selected_plugins} //= [];
    $data->{known_plugins} //= [];
    $data->{mounted_plugins_at_create} //= [];

    # v1 -> v2 migration. v1 had no `mounted_at_create`. We approximate the
    # baseline by assuming the user's currently-selected skills were what the
    # existing container actually has mounted. That's correct for users who
    # haven't toggled selection without rebuilding; for users who have, the
    # first `diff` will under-report drift on those specific skills, but the
    # next container-create cycle calls `record-mount` which restores accuracy.
    # Entries are stored as bare strings (no path/source) since v1 didn't
    # record them; `diff` handles both string and object shapes.
    if ($needs_v1_migration && !@{$data->{mounted_at_create}}) {
        $data->{mounted_at_create} = [ map { "$_" } @{$data->{selected}} ];
    }

    # v2 -> v3 migration. Plugin arrays are introduced empty; they'll be
    # populated by `select-interactive` and `record-mount`. Pre-v3 `selected`
    # may contain plugin-shipped skill names (e.g. "a11y-debugging") which
    # were never actually functional in the container - the next prune cycle
    # drops them naturally since skill discovery is now custom-only.
    # (no explicit work required here beyond the defaults above)

    $data->{schema_version} = $SCHEMA_VERSION;

    # Coerce string arrays for type sanity (defensive against hand-edited files).
    $data->{selected}         = [ map { "$_" } @{$data->{selected}} ];
    $data->{known}            = [ map { "$_" } @{$data->{known}} ];
    $data->{selected_plugins} = [ map { "$_" } @{$data->{selected_plugins}} ];
    $data->{known_plugins}    = [ map { "$_" } @{$data->{known_plugins}} ];

    return $data;
}

sub save_state {
    my ($file, $data) = @_;
    write_json_atomic($file, $data);
}

# =====================================================================
# Subcommand: discover
# =====================================================================

sub cmd_discover {
    my %opts = @_;
    my $skills = discover_skills(%opts);
    print JSON::PP->new->canonical(1)->pretty->encode($skills);
    return 0;
}

# =====================================================================
# Subcommand: discover-plugins
# =====================================================================

sub cmd_discover_plugins {
    my %opts = @_;
    my $plugins = discover_plugins(%opts);
    print JSON::PP->new->canonical(1)->pretty->encode($plugins);
    return 0;
}

# =====================================================================
# Subcommand: load-selection
# =====================================================================

sub cmd_load_selection {
    my %opts = @_;
    my $file = $opts{selection_file} or die "--selection-file required\n";
    my $state = load_state($file);
    print JSON::PP->new->canonical(1)->pretty->encode($state);
    return 0;
}

# =====================================================================
# Subcommand: prune
# =====================================================================

sub cmd_prune {
    my %opts = @_;
    my $file = $opts{selection_file} or die "--selection-file required\n";
    my $state = load_state($file);
    my $skills = discover_skills(%opts);
    my $plugins = discover_plugins(%opts);
    my %avail_skills = map { $_->{name} => 1 } @$skills;
    my %avail_plugins = map { $_->{key}  => 1 } @$plugins;

    my (@pruned, @still_selected, @still_known);
    my (@pruned_plugins, @still_selected_plugins, @still_known_plugins);

    for my $name (@{$state->{selected}}) {
        if ($avail_skills{$name}) { push @still_selected, $name }
        else                      { push @pruned,         $name }
    }
    for my $name (@{$state->{known}}) {
        push @still_known, $name if $avail_skills{$name};
    }

    for my $key (@{$state->{selected_plugins}}) {
        if ($avail_plugins{$key}) { push @still_selected_plugins, $key }
        else                      { push @pruned_plugins,         $key }
    }
    for my $key (@{$state->{known_plugins}}) {
        push @still_known_plugins, $key if $avail_plugins{$key};
    }

    $state->{selected}         = \@still_selected;
    $state->{known}            = \@still_known;
    $state->{selected_plugins} = \@still_selected_plugins;
    $state->{known_plugins}    = \@still_known_plugins;
    # mounted_at_create and mounted_plugins_at_create are NOT pruned -
    # they're the baseline for diff/drift detection.

    save_state($file, $state);

    print JSON::PP->new->canonical(1)->pretty->encode({
        pruned                  => \@pruned,
        still_selected          => \@still_selected,
        still_known             => \@still_known,
        pruned_plugins          => \@pruned_plugins,
        still_selected_plugins  => \@still_selected_plugins,
        still_known_plugins     => \@still_known_plugins,
    });
    return 0;
}

# =====================================================================
# Subcommand: diff (compares current discovery to mounted_at_create)
# =====================================================================

sub cmd_diff {
    my %opts = @_;
    my $file = $opts{selection_file} or die "--selection-file required\n";
    my $state = load_state($file);
    my $skills = discover_skills(%opts);

    my %avail = map { $_->{name} => $_ } @$skills;
    my %selected = map { $_ => 1 } @{$state->{selected}};

    # Normalize mounted_at_create entries to objects (handles v1-migrated string entries).
    my %was_mounted;
    my $mounted = $state->{mounted_at_create};
    for my $m (@$mounted) {
        if (ref $m eq 'HASH') {
            $was_mounted{$m->{name}} = $m;
        } else {
            $was_mounted{$m} = { name => $m, path => undef, source => undef };
        }
    }

    my (@added, @removed, @host_only_changed, @plugin_path_changed);

    for my $name (sort keys %was_mounted) {
        my $prev = $was_mounted{$name};
        my $cur  = $avail{$name};

        if (!$cur) {
            # Skill is no longer in the (visible) discovery set.
            # Try to distinguish "deleted" from "host-only-now".
            my $prev_path = $prev->{path};
            if (defined $prev_path && -d $prev_path
                && skill_host_only_status("$prev_path/SKILL.md") eq 'host-only') {
                push @host_only_changed, $name;
            } else {
                push @removed, $name;
            }
        } else {
            # Skill still visible. User toggled it off since container create?
            if (!$selected{$name}) {
                push @removed, $name;
            } else {
                # Still selected. Path drift?
                my $prev_path = $prev->{path};
                if (defined $prev_path && $prev_path ne $cur->{path}) {
                    push @plugin_path_changed, $name;
                }
            }
        }
    }

    for my $name (sort keys %selected) {
        push @added, $name unless exists $was_mounted{$name};
    }

    # ------------------------------------------------------------------
    # Plugin drift: same idea as skill drift, scoped to mounted_plugins_at_create
    # ------------------------------------------------------------------
    my $plugins = discover_plugins(%opts);
    my %avail_p = map { $_->{key} => $_ } @$plugins;
    my %selected_p = map { $_ => 1 } @{$state->{selected_plugins}};

    my %was_mounted_p;
    for my $m (@{$state->{mounted_plugins_at_create}}) {
        next unless ref $m eq 'HASH' && defined $m->{key};
        $was_mounted_p{$m->{key}} = $m;
    }

    my (@plugins_added, @plugins_removed, @plugins_path_changed);
    for my $key (sort keys %was_mounted_p) {
        my $prev = $was_mounted_p{$key};
        my $cur  = $avail_p{$key};
        if (!$cur) {
            push @plugins_removed, $key;
        } elsif (!$selected_p{$key}) {
            push @plugins_removed, $key;
        } else {
            my $prev_path = $prev->{install_path};
            if (defined $prev_path && $prev_path ne $cur->{install_path}) {
                push @plugins_path_changed, $key;
            }
        }
    }
    for my $key (sort keys %selected_p) {
        push @plugins_added, $key unless exists $was_mounted_p{$key};
    }

    print JSON::PP->new->canonical(1)->pretty->encode({
        added                  => [sort @added],
        removed                => [sort @removed],
        host_only_changed      => [sort @host_only_changed],
        plugin_path_changed    => [sort @plugin_path_changed],
        plugins_added          => [sort @plugins_added],
        plugins_removed        => [sort @plugins_removed],
        plugins_path_changed   => [sort @plugins_path_changed],
    });
    return 0;
}

# =====================================================================
# Subcommand: select-interactive (TTY)
# =====================================================================

# --- TUI plumbing ---------------------------------------------------
# Term::ReadKey gives us cbreak mode (single-keypress reads) and ANSI escapes
# do the rest. We hide the cursor during the TUI, restore it on every exit
# path (END block + signal traps) so the user's terminal isn't left wedged.

my $TUI_ACTIVE = 0;
sub tui_enter {
    require Term::ReadKey;
    Term::ReadKey::ReadMode(4);  # cbreak: char-at-a-time, no echo
    print "\e[?25l";              # hide cursor
    $TUI_ACTIVE = 1;
}
sub tui_exit {
    return unless $TUI_ACTIVE;
    print "\e[?25h";              # show cursor
    print "\e[0m";                # reset attrs
    eval { Term::ReadKey::ReadMode(0) };  # restore terminal mode
    $TUI_ACTIVE = 0;
}
END { tui_exit() }
$SIG{INT}  = sub { tui_exit(); exit 130 };
$SIG{TERM} = sub { tui_exit(); exit 143 };

# Read one logical key. Returns one of:
#   'UP' 'DOWN' 'LEFT' 'RIGHT'  (arrow keys)
#   'ENTER'                      (CR or LF)
#   'ESC'                        (bare escape, or unknown escape sequence)
#   'SPACE'                      (space bar)
#   single char (a-z, A-Z, digits, etc.)
#   undef on EOF
sub tui_read_key {
    my $k = Term::ReadKey::ReadKey(0);
    return undef unless defined $k;
    if ($k eq "\e") {
        my $k2 = Term::ReadKey::ReadKey(0.05);
        if (!defined $k2) { return 'ESC' }
        if ($k2 eq '[' || $k2 eq 'O') {
            my $k3 = Term::ReadKey::ReadKey(0.05);
            if (!defined $k3) { return 'ESC' }
            return 'UP'    if $k3 eq 'A';
            return 'DOWN'  if $k3 eq 'B';
            return 'RIGHT' if $k3 eq 'C';
            return 'LEFT'  if $k3 eq 'D';
            return 'HOME'  if $k3 eq 'H';
            return 'END'   if $k3 eq 'F';
            # Drain numeric escape sequences (e.g. PageUp = ESC[5~)
            while (defined(my $extra = Term::ReadKey::ReadKey(0.02))) {
                last if $extra =~ /[~A-DHF]/;
            }
            return 'OTHER';
        }
        return 'ESC';
    }
    return 'ENTER' if $k eq "\n" || $k eq "\r";
    return 'SPACE' if $k eq ' ';
    return $k;
}

# Resolve which selection hash a row uses. With subsections, the hash key
# is "<section>_<partition>" (e.g. 'plugins_project', 'mcp_suggestion',
# 'mcp_stale'); rows without a partition (currently: skills) just use
# '<section>'.
sub _sel_key_for_row {
    my $it = shift;
    my $sect = $it->{section};
    my $part = $it->{partition};
    return $part ? "${sect}_${part}" : $sect;
}

# Render the selector. `items` is an array of:
#   { kind => 'header',    section => 'skills'|'plugins'|'mcp', label => '...' }
#   { kind => 'subheader', section => 'plugins'|'mcp',
#     partition => 'project'|'suggestion'|'stale', label => '...',
#     counter_verb => 'enabled'|'to clone' (Stale uses a fixed format) }
#   { kind => 'row',       section => 'skills'|'plugins'|'mcp',
#     partition => 'project'|'suggestion'|'stale' (omitted for skills),
#     id => ..., display => ..., is_new => bool, is_stale => bool }
sub tui_render {
    my ($items, $cursor, $sel_by_section, $project_label) = @_;
    print "\e[H\e[J";  # cursor home + clear from cursor to end

    print "\e[1mSandbox configuration", ($project_label ? " - $project_label" : ""), "\e[0m\n";
    print "-" x 60, "\n\n";

    # Aggregate counters at three levels:
    # - %section_totals / %section_selected: rolled-up across subsections so
    #   the SECTION header still gives a useful aggregate.
    # - %sub_totals / %sub_selected: per-subheader, used to render
    #   "(N of M enabled)" / "(N of M to clone)" / "(N to drop)" suffixes.
    my %section_totals;
    my %section_selected;
    my %sub_totals;
    my %sub_selected;
    for my $it (@$items) {
        next if $it->{kind} ne 'row';
        next if $it->{disabled};
        $section_totals{$it->{section}}++;
        my $sub_key = _sel_key_for_row($it);
        $sub_totals{$sub_key}++;
        my $sel = $sel_by_section->{$sub_key};
        if ($sel && $sel->{$it->{id}}) {
            $section_selected{$it->{section}}++;
            $sub_selected{$sub_key}++;
        }
    }

    for my $i (0 .. $#$items) {
        my $it = $items->[$i];
        if ($it->{kind} eq 'header') {
            my $sect = $it->{section};
            my $sel  = $section_selected{$sect} // 0;
            my $tot  = $section_totals{$sect}  // 0;
            print "\n" if $i > 0;
            printf "\e[1m\e[36m%s (%d of %d selected):\e[0m\n",
                uc($it->{label}), $sel, $tot;
            next;
        }
        if ($it->{kind} eq 'subheader') {
            my $sub_key = ($it->{partition})
                ? "$it->{section}_$it->{partition}"
                : $it->{section};
            my $sel = $sub_selected{$sub_key} // 0;
            my $tot = $sub_totals{$sub_key}  // 0;
            if (($it->{partition} // '') eq 'stale') {
                # Stale: "selected" semantically means "kept", so the
                # actionable counter is "to drop" = total - kept.
                my $drop = $tot - $sel;
                printf "  \e[2m---- %s (%d to drop) ----\e[0m\n",
                    $it->{label}, $drop;
            } else {
                printf "  \e[2m---- %s (%d of %d %s) ----\e[0m\n",
                    $it->{label}, $sel, $tot, $it->{counter_verb} // 'selected';
            }
            next;
        }
        # Disabled rows are placeholders (e.g. "(no .mcp.json in this
        # project)") — render as a dimmed info line, no checkbox, no
        # cursor, never selectable. tui_advance_cursor + tui_first_row +
        # tui_last_row skip them so the cursor never lands here.
        if ($it->{disabled}) {
            printf "  \e[2m%s\e[0m\n", $it->{display};
            next;
        }
        my $is_cursor = ($i == $cursor);
        my $sub_key = _sel_key_for_row($it);
        my $sel = $sel_by_section->{$sub_key};
        my $checked = ($sel && $sel->{$it->{id}}) ? 'x' : ' ';
        my $arrow   = $is_cursor ? '>' : ' ';
        my $tag = '';
        $tag .= "  \e[33m[+ new]\e[0m"  if $it->{is_new};
        $tag .= "  \e[31m[stale]\e[0m"  if $it->{is_stale};
        # All rows use the same 2-space indent regardless of whether
        # their section has subsection headers (Skills has none; Plugins
        # / MCP do). Subheaders sit at the same column with a different
        # visual treatment (`---- label ----`) — the relationship reads
        # clearly without extra item indent that would offset rows from
        # the Skills column.
        my $indent = '  ';
        if ($is_cursor) {
            printf "\e[7m%s%s [%s] %s%s\e[0m\n", $indent, $arrow, $checked, $it->{display}, $tag;
        } else {
            printf "%s%s [%s] %s%s\n", $indent, $arrow, $checked, $it->{display}, $tag;
        }
    }

    print "\n", "-" x 60, "\n";
    print "\e[2m";
    print "  up/down: navigate    space: toggle    a: all in section    n: none in section\n";
    print "  g/G: top/bottom      enter: confirm   q or esc: cancel\n";
    print "\e[0m";
}

# Move cursor to the nearest selectable row in direction `dir` (-1 up, +1 down).
# Skips headers, subheaders, AND disabled rows (placeholder info lines like
# "(no .mcp.json in this project)" — never navigable). Clamps to the
# first/last selectable row.
sub tui_advance_cursor {
    my ($items, $cur, $dir) = @_;
    my $n = scalar @$items;
    my $i = $cur + $dir;
    while ($i >= 0 && $i < $n) {
        return $i if $items->[$i]{kind} eq 'row' && !$items->[$i]{disabled};
        $i += $dir;
    }
    return $cur;  # no movement possible
}

# Find first/last selectable row.
sub tui_first_row {
    my $items = shift;
    for my $i (0 .. $#$items) {
        return $i if $items->[$i]{kind} eq 'row' && !$items->[$i]{disabled};
    }
    return 0;
}
sub tui_last_row {
    my $items = shift;
    for (my $i = $#$items; $i >= 0; $i--) {
        return $i if $items->[$i]{kind} eq 'row' && !$items->[$i]{disabled};
    }
    return $#$items;
}

# Determine which section the cursor is currently in by scanning backwards
# for the nearest header.
sub tui_current_section {
    my ($items, $cur) = @_;
    for (my $i = $cur; $i >= 0; $i--) {
        return $items->[$i]{section} if $items->[$i]{kind} eq 'header';
    }
    return 'skills';  # default
}

# --- The actual subcommand ------------------------------------------

sub cmd_select_interactive {
    my %opts = @_;
    my $file = $opts{selection_file} or die "--selection-file required\n";

    my $state   = load_state($file);
    my $skills  = discover_skills(%opts);
    my $plugins = discover_plugins(%opts);
    my $mcp     = discover_mcp(%opts);

    my %avail_skill  = map { $_->{name} => 1 } @$skills;
    my %avail_plugin = map { $_->{key}  => 1 } @$plugins;

    # Silent prune of dead entries from selected/known.
    $state->{selected}         = [ grep { $avail_skill{$_} }  @{$state->{selected}} ];
    $state->{known}            = [ grep { $avail_skill{$_} }  @{$state->{known}} ];
    $state->{selected_plugins} = [ grep { $avail_plugin{$_} } @{$state->{selected_plugins}} ];
    $state->{known_plugins}    = [ grep { $avail_plugin{$_} } @{$state->{known_plugins}} ];

    my %known_skills  = map { $_ => 1 } @{$state->{known}};
    my %known_plugins = map { $_ => 1 } @{$state->{known_plugins}};
    my @new_skills    = grep { !$known_skills{$_->{name}} }  @$skills;
    my @new_plugins   = grep { !$known_plugins{$_->{key}} }  @$plugins;

    my %is_new_skill  = map { $_->{name} => 1 } @new_skills;
    my %is_new_plugin = map { $_->{key}  => 1 } @new_plugins;
    my %sel_skill     = map { $_ => 1 } @{$state->{selected}};

    # Partitioned discovery slices, used by both the items builder and the
    # write path. discover_plugins emits `partition` and `enabled`; discover_mcp
    # emits `partition`, `enabled`, `disabled`, `stale`, `list_membership`.
    my @project_plugins    = grep { $_->{partition} eq 'project' }    @$plugins;
    my @suggestion_plugins = grep { $_->{partition} eq 'suggestion' } @$plugins;
    my @defined_mcp        = grep { $_->{defined_in_mcp_json} } @$mcp;
    my @project_mcp        = grep { $_->{partition} eq 'project' }    @defined_mcp;
    my @suggestion_mcp     = grep { $_->{partition} eq 'suggestion' } @defined_mcp;
    my @stale_mcp          = grep { $_->{stale} } @$mcp;

    # Initial selection state, keyed by (section, partition):
    # - Project plugin: pre-checked iff `enabled == true` in settings.json
    # - Suggestion plugin: always unchecked (opt-in clone)
    # - Project MCP: pre-checked iff `enabled && !disabled` (treat any explicit
    #   disable as unchecked — settings.json disabledMcpjsonServers wins)
    # - Suggestion MCP: always unchecked (opt-in clone)
    # - Stale: unchecked = drop; checked = keep (default unchecked → drop)
    my %sel_plugin_project    = map { $_->{key}  => 1 } grep { $_->{enabled} } @project_plugins;
    my %sel_plugin_suggestion;
    my %sel_mcp_project       = map { $_->{name} => 1 }
                                grep { $_->{enabled} && !$_->{disabled} } @project_mcp;
    my %sel_mcp_suggestion;
    my %keep_stale_mcp;

    # Build the unified item list (headers + subheaders + rows).
    my @items;

    # --- Skills section (no partitioning) -----------------------------
    push @items, { kind => 'header', section => 'skills', label => 'Skills' };
    for my $s (@$skills) {
        push @items, {
            kind    => 'row',
            section => 'skills',
            id      => $s->{name},
            display => $s->{name},
            is_new  => $is_new_skill{$s->{name}} ? 1 : 0,
        };
    }

    # --- Plugins section (Project / Suggestions) ----------------------
    push @items, { kind => 'header', section => 'plugins', label => 'Plugins' };
    if (@$plugins) {
        if (@project_plugins) {
            push @items, {
                kind         => 'subheader',
                section      => 'plugins',
                partition    => 'project',
                label        => 'Project',
                counter_verb => 'enabled',
            };
            for my $p (@project_plugins) {
                push @items, {
                    kind      => 'row',
                    section   => 'plugins',
                    partition => 'project',
                    id        => $p->{key},
                    display   => $p->{key},
                    is_new    => $is_new_plugin{$p->{key}} ? 1 : 0,
                };
            }
        }
        if (@suggestion_plugins) {
            push @items, {
                kind         => 'subheader',
                section      => 'plugins',
                partition    => 'suggestion',
                label        => 'Suggestions',
                counter_verb => 'to clone',
            };
            for my $p (@suggestion_plugins) {
                my $disp = $p->{key};
                # Show scope tag so the user can tell where the suggestion
                # comes from before cloning.
                $disp .= " [user]"  if $p->{scope} eq 'user';
                $disp .= " [local]" if $p->{scope} eq 'local';
                push @items, {
                    kind      => 'row',
                    section   => 'plugins',
                    partition => 'suggestion',
                    id        => $p->{key},
                    display   => $disp,
                    is_new    => $is_new_plugin{$p->{key}} ? 1 : 0,
                };
            }
        }
    } else {
        push @items, {
            kind     => 'row',
            section  => 'plugins',
            id       => '',
            display  => "(no plugins installed for this project)",
            disabled => 1,
        };
    }

    # --- MCP section (Project / Suggestions / Stale) ------------------
    push @items, { kind => 'header', section => 'mcp', label => 'MCP Servers' };
    if (@defined_mcp) {
        if (@project_mcp) {
            push @items, {
                kind         => 'subheader',
                section      => 'mcp',
                partition    => 'project',
                label        => 'Project',
                counter_verb => 'enabled',
            };
            for my $m (@project_mcp) {
                my $disp = $m->{name};
                $disp .= " ($m->{type})" if defined $m->{type} && $m->{type} ne 'unknown';
                push @items, {
                    kind      => 'row',
                    section   => 'mcp',
                    partition => 'project',
                    id        => $m->{name},
                    display   => $disp,
                };
            }
        }
        if (@suggestion_mcp) {
            push @items, {
                kind         => 'subheader',
                section      => 'mcp',
                partition    => 'suggestion',
                label        => 'Suggestions',
                counter_verb => 'to clone',
            };
            for my $m (@suggestion_mcp) {
                my $disp = $m->{name};
                $disp .= " ($m->{type})" if defined $m->{type} && $m->{type} ne 'unknown';
                push @items, {
                    kind      => 'row',
                    section   => 'mcp',
                    partition => 'suggestion',
                    id        => $m->{name},
                    display   => $disp,
                };
            }
        }
    } else {
        push @items, {
            kind     => 'row',
            section  => 'mcp',
            id       => '',
            display  => "(no .mcp.json in this project)",
            disabled => 1,
        };
    }
    if (@stale_mcp) {
        push @items, {
            kind      => 'subheader',
            section   => 'mcp',
            partition => 'stale',
            label     => 'Stale',
        };
        for my $s (@stale_mcp) {
            push @items, {
                kind       => 'row',
                section    => 'mcp',
                partition  => 'stale',
                id         => $s->{name},
                display    => $s->{name},
                is_stale   => 1,
                stale_list => $s->{list_membership} // 'enabled',
            };
        }
    }

    my $project_label = $opts{project_path};
    if (defined $project_label && length $project_label) {
        $project_label =~ s|.*/||;  # basename
    }

    # If anything to choose from is empty AND no MCP entries exist, write
    # selection-file with empty state and exit.
    if (!@$skills && !@$plugins && !@$mcp) {
        save_state($file, $state);
        return 0;
    }

    # Verify stdin is a TTY; if not, fall back to auto-confirm with whatever's
    # already in the state file.
    if (! -t STDIN || ! -t STDOUT) {
        warn "Note: not a TTY; using existing selection without prompting.\n";
        $state->{known}         = [ map { $_->{name} } @$skills ];
        $state->{known_plugins} = [ map { $_->{key}  } @$plugins ];
        save_state($file, $state);
        return 0;
    }

    tui_enter();

    my $cursor = tui_first_row(\@items);
    my $confirmed = 0;
    my $cancelled = 0;

    # tui_render looks up the right selection hash per row using the
    # _sel_key_for_row helper. Stale rows use 'mcp_stale'; other rows use
    # '<section>_<partition>'.
    my $sel_by_section = {
        skills             => \%sel_skill,
        plugins_project    => \%sel_plugin_project,
        plugins_suggestion => \%sel_plugin_suggestion,
        mcp_project        => \%sel_mcp_project,
        mcp_suggestion     => \%sel_mcp_suggestion,
        mcp_stale          => \%keep_stale_mcp,
    };

    while (1) {
        tui_render(\@items, $cursor, $sel_by_section, $project_label);
        my $key = tui_read_key();
        last unless defined $key;  # EOF on stdin

        if ($key eq 'UP') {
            $cursor = tui_advance_cursor(\@items, $cursor, -1);
        } elsif ($key eq 'DOWN') {
            $cursor = tui_advance_cursor(\@items, $cursor, +1);
        } elsif ($key eq 'HOME' || $key eq 'g') {
            $cursor = tui_first_row(\@items);
        } elsif ($key eq 'END' || $key eq 'G') {
            $cursor = tui_last_row(\@items);
        } elsif ($key eq 'SPACE') {
            my $it = $items[$cursor];
            next if !$it || $it->{kind} ne 'row' || $it->{disabled};
            my $sect_key = _sel_key_for_row($it);
            my $sel = $sel_by_section->{$sect_key};
            if ($sel->{$it->{id}}) { delete $sel->{$it->{id}} }
            else                    { $sel->{$it->{id}} = 1 }
        } elsif ($key eq 'a') {
            # 'all in section' fills every subsection in the cursor's section.
            # For Stale that means "keep all" — semantically consistent.
            my $sect = tui_current_section(\@items, $cursor);
            if ($sect eq 'skills') {
                %sel_skill = map { $_->{name} => 1 } @$skills;
            } elsif ($sect eq 'plugins') {
                %sel_plugin_project    = map { $_->{key}  => 1 } @project_plugins;
                %sel_plugin_suggestion = map { $_->{key}  => 1 } @suggestion_plugins;
            } elsif ($sect eq 'mcp') {
                %sel_mcp_project    = map { $_->{name} => 1 } @project_mcp;
                %sel_mcp_suggestion = map { $_->{name} => 1 } @suggestion_mcp;
                %keep_stale_mcp     = map { $_->{name} => 1 } @stale_mcp;
            }
        } elsif ($key eq 'n') {
            my $sect = tui_current_section(\@items, $cursor);
            if ($sect eq 'skills') {
                %sel_skill = ();
            } elsif ($sect eq 'plugins') {
                %sel_plugin_project    = ();
                %sel_plugin_suggestion = ();
            } elsif ($sect eq 'mcp') {
                %sel_mcp_project    = ();
                %sel_mcp_suggestion = ();
                %keep_stale_mcp     = ();
            }
        } elsif ($key eq 'ENTER') {
            $confirmed = 1;
            last;
        } elsif ($key eq 'q' || $key eq 'ESC') {
            $cancelled = 1;
            last;
        }
        # ignore unrecognized keys
    }

    tui_exit();
    print "\n";

    if ($cancelled) {
        # Don't persist anything - launcher should bail.
        return 2;
    }

    # ==================================================================
    # Write path. Phased so a single read-modify-write per file is enough,
    # and so a Phase A clone hands off its enable to the Phase B batch.
    # ==================================================================
    my $project_path_norm = normalize_path($opts{project_path});

    # Phase A — clone accepted suggestions (plugins only; MCP needs no
    # plugins-file work). Each clone goes through the locked helper, so
    # concurrent launches against different keys serialize cleanly.
    #
    # We track which clones actually landed so Phase B doesn't write
    # `enabledPlugins[K] = true` for a key whose project-scope install
    # never made it onto disk. Setting the enable without the install
    # would leave settings.json pointing at whatever non-project install
    # discover_plugins picks next time — partition would stay "suggestion"
    # so the row would still render as a suggestion, but with enabled=true,
    # which is confusing. Skipping the enable on failure means the next
    # TUI run shows the suggestion in its original (unchecked) state and
    # the user can retry.
    my %accepted_plugin_suggestions = %sel_plugin_suggestion;
    my %accepted_mcp_suggestions    = %sel_mcp_suggestion;
    my %phase_a_landed;
    if (defined $project_path_norm && length $project_path_norm
        && %accepted_plugin_suggestions) {
        my $plugins_file = $opts{plugins_file}
            // home() . "/.claude/plugins/installed_plugins.json";
        for my $key (sort keys %accepted_plugin_suggestions) {
            eval {
                _append_project_install_locked($key, $project_path_norm, $plugins_file);
                $phase_a_landed{$key} = 1;
            };
            if ($@) {
                warn "Warning: clone-to-project for plugin '$key' failed: $@";
            }
        }
    }

    # Phase B — single settings.json read-modify-write.
    if (defined $project_path_norm && length $project_path_norm) {
        my $settings_file = "$project_path_norm/.claude/settings.json";

        my %ep_changes;     # enabledPlugins[K] = true|false
        my @mcp_add;
        my @mcp_remove;
        my @disabled_add;
        my @disabled_remove;

        # Project plugin rows: drive the checkbox state straight into
        # enabledPlugins[K]. Unchecked → explicit `false` (not delete), so
        # the user's intent is preserved across runs and partition stays
        # "project" for next discovery. Note this *will* overwrite a prior
        # explicit `false` if the user toggles the row on — the user is
        # actively interacting with the same setting the explicit false
        # represented, so respecting the click is the right UX.
        for my $p (@project_plugins) {
            $ep_changes{$p->{key}} = $sel_plugin_project{$p->{key}} ? 1 : 0;
        }
        # Accepted suggestion plugins: enable in settings.json (Phase A
        # already appended the install entry). Gated on Phase A success
        # so we never write an enable for a key whose install didn't land.
        #
        # Diverges from `clone-to-project`'s "preserve explicit false"
        # idempotency rule: that rule guards a scripted/CLI invocation
        # from accidentally re-enabling a deliberately-disabled plugin.
        # In the TUI the user is clicking the checkbox themselves, so the
        # explicit click overrides any prior `false`. The trade-off is a
        # deliberate UX choice — checking a Suggestion means "I want this
        # active in the project".
        for my $key (sort keys %accepted_plugin_suggestions) {
            $ep_changes{$key} = 1 if $phase_a_landed{$key};
        }

        # Project MCP rows: maintain mutual exclusivity between the two
        # lists. Checked → add to enabled, remove from disabled. Unchecked
        # → flip.
        for my $m (@project_mcp) {
            if ($sel_mcp_project{$m->{name}}) {
                push @mcp_add,         $m->{name};
                push @disabled_remove, $m->{name};
            } else {
                push @mcp_remove,      $m->{name};
                push @disabled_add,    $m->{name};
            }
        }
        # Accepted suggestion MCPs: enable in settings.json. By the
        # partition rule, these aren't currently in settings.json at all,
        # so we just need an `add`.
        for my $name (sort keys %accepted_mcp_suggestions) {
            push @mcp_add, $name;
        }
        # Stale entries the user did NOT check: drop from settings.json
        # lists wherever the name might be (idempotent remove).
        for my $s (@stale_mcp) {
            next if $keep_stale_mcp{$s->{name}};
            push @mcp_remove,      $s->{name};
            push @disabled_remove, $s->{name};
        }

        eval {
            _apply_settings_json_changes($settings_file,
                enabledPlugins         => \%ep_changes,
                enabledMcpjsonServers  => { add => \@mcp_add,      remove => \@mcp_remove      },
                disabledMcpjsonServers => { add => \@disabled_add, remove => \@disabled_remove },
            );
        };
        if ($@) {
            warn "Warning: settings.json update failed: $@";
        }
    }

    # Phase C — settings.local.json cleanup, scoped to stale drops only.
    # No other writes ever target this file under the new model. The legacy
    # `write-mcp-state` subcommand keeps the wholesale-overwrite behavior
    # for any external caller.
    if (my $settings_local = $opts{settings_local_file}) {
        my %drop_names;
        for my $s (@stale_mcp) {
            next if $keep_stale_mcp{$s->{name}};
            $drop_names{$s->{name}} = 1;
        }
        if (%drop_names && -f $settings_local) {
            my $local = read_json($settings_local);
            $local = {} unless ref $local eq 'HASH';
            my $changed = 0;
            for my $list_name ('enabledMcpjsonServers', 'disabledMcpjsonServers') {
                next unless ref $local->{$list_name} eq 'ARRAY';
                my @before = @{$local->{$list_name}};
                my @after  = grep { !$drop_names{$_} } @before;
                if (scalar @after != scalar @before) {
                    $local->{$list_name} = [ sort { $a cmp $b } @after ];
                    $changed = 1;
                }
            }
            if ($changed) {
                eval { write_json_atomic($settings_local, $local) };
                warn "Warning: settings.local.json stale cleanup failed: $@" if $@;
            }
        }
    }

    # Phase D — selection-file state. `selected_plugins` lists what the user
    # wants ACTIVE post-confirm: enabled project plugins + accepted suggestions
    # (which are now project-enabled in settings.json). Discovery is still
    # pinned to the snapshot from session start, so we walk the snapshot's
    # discovery order to keep the list stable across runs.
    $state->{selected} = [ grep { $sel_skill{$_} } map { $_->{name} } @$skills ];
    $state->{known}    = [ map { $_->{name} } @$skills ];

    my @final_selected_plugins;
    for my $p (@$plugins) {
        my $key = $p->{key};
        if ($p->{partition} eq 'project') {
            push @final_selected_plugins, $key if $sel_plugin_project{$key};
        } elsif ($p->{partition} eq 'suggestion') {
            # Same gate as Phase B: only treat a checked suggestion as
            # selected when its Phase A clone actually landed. Otherwise
            # selected_plugins would refer to a key that isn't really
            # active in this project, and downstream record-mount /
            # materialize-plugins would silently use whatever non-project
            # install discover_plugins picks.
            push @final_selected_plugins, $key
                if $sel_plugin_suggestion{$key} && $phase_a_landed{$key};
        }
    }
    $state->{selected_plugins} = \@final_selected_plugins;
    $state->{known_plugins}    = [ map { $_->{key} } @$plugins ];
    save_state($file, $state);

    return 0;
}

# =====================================================================
# Subcommand: mounts
# =====================================================================

sub cmd_mounts {
    my %opts = @_;
    my $file = $opts{selection_file} or die "--selection-file required\n";
    my $state = load_state($file);
    my $skills = discover_skills(%opts);
    my %by_name = map { $_->{name} => $_ } @$skills;

    for my $name (@{$state->{selected}}) {
        my $s = $by_name{$name};
        if (!$s) {
            # Selected but not discoverable right now. Surface this loudly so the
            # user knows their picked skill won't be in the container.
            warn "Warning: selected skill '$name' is no longer discoverable; not mounting.\n";
            next;
        }
        # Also verify the path still exists on disk (TOCTOU between discover
        # and the podman create downstream).
        if (!-d $s->{path}) {
            warn "Warning: skill '$name' path '$s->{path}' vanished; not mounting.\n";
            next;
        }
        print "$s->{path}\t$name\n";
    }
    return 0;
}

# =====================================================================
# Subcommand: record-mount
# =====================================================================

sub cmd_record_mount {
    my %opts = @_;
    my $file = $opts{selection_file} or die "--selection-file required\n";
    my $state = load_state($file);
    my $skills = discover_skills(%opts);
    my $plugins = discover_plugins(%opts);
    my %by_name = map { $_->{name} => $_ } @$skills;
    my %by_key  = map { $_->{key}  => $_ } @$plugins;

    my @mounted_at_create;
    for my $name (@{$state->{selected}}) {
        my $s = $by_name{$name} or next;
        push @mounted_at_create, {
            name   => $name,
            source => $s->{source},
            path   => $s->{path},
        };
    }
    $state->{mounted_at_create} = \@mounted_at_create;

    my @mounted_plugins_at_create;
    for my $key (@{$state->{selected_plugins}}) {
        my $p = $by_key{$key} or next;
        push @mounted_plugins_at_create, {
            key          => $key,
            install_path => $p->{install_path},
            scope        => $p->{scope},
            version      => $p->{version},
        };
    }
    $state->{mounted_plugins_at_create} = \@mounted_plugins_at_create;

    save_state($file, $state);
    return 0;
}

# =====================================================================
# Subcommand: manifest (for container self-audit)
# =====================================================================

sub cmd_manifest {
    my %opts = @_;
    my $file = $opts{selection_file} or die "--selection-file required\n";
    my $output = $opts{output};
    my $state = load_state($file);

    my @mounted_skills;
    for my $m (@{$state->{mounted_at_create}}) {
        if (ref $m eq 'HASH') {
            push @mounted_skills, {
                name           => $m->{name},
                source         => $m->{source},
                container_path => "/root/.claude/skills/$m->{name}",
            };
        } else {
            push @mounted_skills, {
                name           => $m,
                source         => undef,
                container_path => "/root/.claude/skills/$m",
            };
        }
    }

    my @mounted_plugins;
    for my $m (@{$state->{mounted_plugins_at_create}}) {
        next unless ref $m eq 'HASH';
        push @mounted_plugins, {
            key     => $m->{key},
            scope   => $m->{scope},
            version => $m->{version},
        };
    }

    my $manifest = {
        schema_version  => $SCHEMA_VERSION,
        mounted_skills  => \@mounted_skills,
        mounted_plugins => \@mounted_plugins,
        generated_at    => now_iso(),
    };

    if (defined $output && length $output) {
        my $dir = dirname($output);
        make_path($dir) unless -d $dir;
        my $tmp = "$output.tmp.$$";
        open my $fh, '>:raw', $tmp or die "write $tmp: $!\n";
        print $fh JSON::PP->new->canonical(1)->pretty->utf8->encode($manifest);
        close $fh or die "close $tmp: $!\n";
        rename $tmp, $output or do {
            unlink $tmp;
            die "rename $tmp -> $output: $!\n";
        };
    } else {
        print JSON::PP->new->canonical(1)->pretty->encode($manifest);
    }
    return 0;
}

# =====================================================================
# Subcommand: materialize-plugins
# =====================================================================
#
# Emits a container-shaped installed_plugins.json containing only the
# user-selected plugins, with all paths rewritten so a Linux container
# at /root/.claude/plugins/* can resolve them.
#
# Required: --selection-file FILE --output FILE [--project-path P]
sub cmd_materialize_plugins {
    my %opts = @_;
    my $file   = $opts{selection_file} or die "--selection-file required\n";
    my $output = $opts{output}         or die "--output required\n";

    my $state = load_state($file);
    my $plugins = discover_plugins(%opts);
    my %by_key = map { $_->{key} => $_ } @$plugins;

    # Also load the host installed_plugins.json so we can carry forward
    # metadata fields (gitCommitSha, installedAt, lastUpdated) that
    # discover_plugins doesn't surface. Claude Code treats plugins with
    # missing/empty installedAt as "not recorded" and won't load them.
    my $host_plugins_file = $opts{plugins_file}
        // home() . "/.claude/plugins/installed_plugins.json";
    my $host_data = -f $host_plugins_file ? read_json($host_plugins_file) : {};
    $host_data = {} unless ref $host_data eq 'HASH';
    my $host_plugins = (ref $host_data->{plugins} eq 'HASH')
        ? $host_data->{plugins} : {};
    my $project_path = normalize_path($opts{project_path});

    # The host-side prefix that needs to be replaced with the container's
    # plugin root. Discovery normalizes paths to Git Bash form, e.g.
    # /c/Users/Andre/.claude/plugins/cache/...; we strip everything up to
    # and including ".claude/plugins/" and prepend the container root.
    my $rewrite = sub {
        my $host_path = shift;
        return undef unless defined $host_path && length $host_path;
        my $copy = $host_path;
        # Match ".claude/plugins/" with optional preceding slashes/backslashes
        if ($copy =~ s|^.*?\.claude/plugins/||) {
            return "$CONTAINER_PLUGINS_ROOT/$copy";
        }
        # Fallback: last-resort substring match
        if ($copy =~ s|^.*?/plugins/||) {
            return "$CONTAINER_PLUGINS_ROOT/$copy";
        }
        warn "Warning: could not rewrite plugin path '$host_path' to container form; leaving as-is.\n";
        return $host_path;
    };

    # For a given plugin key, find the host install entry that best matches
    # the current project. Same ranking as discover_plugins's chooser:
    # project-scope-matching > local-scope-matching > user-scope > nothing.
    my $best_host_install = sub {
        my $key = shift;
        my $installs = $host_plugins->{$key};
        return undef unless ref $installs eq 'ARRAY';
        my ($best, $best_rank);
        for my $inst (@$installs) {
            next unless ref $inst eq 'HASH';
            my $scope = $inst->{scope} // 'local';
            my $inst_project = normalize_path($inst->{projectPath} // '');
            my $matches_project = defined $project_path && length $project_path
                && length $inst_project
                && lc($inst_project) eq lc($project_path);
            my $rank;
            if    ($scope eq 'project' && $matches_project) { $rank = 1 }
            elsif ($scope eq 'local'   && $matches_project) { $rank = 2 }
            elsif ($scope eq 'user')                        { $rank = 3 }
            else { next }
            if (!defined $best_rank || $rank <= $best_rank) {
                $best      = $inst;
                $best_rank = $rank;
            }
        }
        return $best;
    };

    my %plugins_out;
    my @missing;
    for my $key (@{$state->{selected_plugins}}) {
        my $p = $by_key{$key};
        if (!$p) {
            push @missing, $key;
            next;
        }
        # Start from the host install entry (preserves gitCommitSha /
        # installedAt / lastUpdated and anything else the host writes).
        my $host_inst = $best_host_install->($key);
        my $entry = $host_inst ? { %$host_inst } : {};

        # Overwrite path + scope fields with container-side values.
        $entry->{installPath} = $rewrite->($p->{install_path});
        $entry->{scope}       = $p->{scope};
        $entry->{version}     = $p->{version};
        if ($p->{scope} eq 'local' || $p->{scope} ne 'user') {
            $entry->{projectPath} = $CONTAINER_PROJECT_PATH;
        } else {
            delete $entry->{projectPath};
        }

        # Wrap in a single-element installs array (matches host file shape).
        $plugins_out{$key} = [$entry];
    }

    if (@missing) {
        warn "Warning: selected plugins not in current discovery; skipping: ", join(", ", @missing), "\n";
    }

    my $registry = { plugins => \%plugins_out };

    my $dir = dirname($output);
    make_path($dir) unless -d $dir;
    my $tmp = "$output.tmp.$$";
    open my $fh, '>:raw', $tmp or die "write $tmp: $!\n";
    print $fh JSON::PP->new->canonical(1)->pretty->utf8->encode($registry);
    close $fh or die "close $tmp: $!\n";
    rename $tmp, $output or do {
        unlink $tmp;
        die "rename $tmp -> $output: $!\n";
    };
    return 0;
}

# =====================================================================
# Subcommand: materialize-known-marketplaces
# =====================================================================
#
# Emits a container-shaped known_marketplaces.json. The host file holds
# Windows-shaped paths (e.g. C:\Users\Andre\...\marketplaces\foo) inside
# `installLocation`; inside the Linux container those don't resolve. The
# host also registers `directory`-source marketplaces whose source path
# isn't a Linux directory in the container (e.g. ccpraxis-local).
#
# Per-entry policy:
#   - source.source == "github" (or any non-"directory" remote-shaped source):
#     keep the entry; rewrite `installLocation` to the container-side path
#     under /root/.claude/plugins/marketplaces/<name>. The launcher
#     bind-mounts the host's marketplaces/ dir at that container path RO,
#     so the rewritten installLocation resolves to real data.
#
#   - source.source == "directory":
#     DROP the entry. The current launcher does not bind-mount arbitrary
#     host directories into the container, so the marketplace's source.path
#     wouldn't resolve. The launcher would need to learn to bind-mount the
#     source.path before this entry could be kept. When that lands, swap
#     this branch for: bind-mount source.path inside the container, then
#     rewrite source.path AND installLocation to the mount target. See
#     ccpraxis-local for the canonical "directory" entry shape on Windows.
#
# Output is a per-launch file written under .claude-data/plugins/ on the
# host so it appears at /root/.claude/plugins/known_marketplaces.json as a
# REAL file (not a single-file bind), letting Claude Code's atomic write
# pattern (write tmp + rename) succeed when it updates `lastUpdated`.
# Single-file binds reject rename-over-mount with EROFS.
#
# Required: --output FILE [--host-marketplaces FILE]
sub cmd_materialize_known_marketplaces {
    my %opts = @_;
    my $output = $opts{output} or die "--output required\n";
    my $host_file = $opts{host_marketplaces}
        // home() . "/.claude/plugins/known_marketplaces.json";

    # Same retry rationale as materialize-credentials: Claude Code on the
    # host atomically rewrites this file on every marketplace refresh.
    my $host = -f $host_file ? read_json_with_retry($host_file) : {};
    $host = {} unless ref $host eq 'HASH';

    my %out;
    my @dropped;
    for my $name (sort keys %$host) {
        my $entry = $host->{$name};
        next unless ref $entry eq 'HASH';
        my $src = $entry->{source};
        next unless ref $src eq 'HASH';
        my $src_type = $src->{source} // '';

        my $container_install = "$CONTAINER_PLUGINS_ROOT/marketplaces/$name";

        if ($src_type eq 'directory') {
            # Directory-source marketplace (e.g. ccpraxis-local): plugins
            # live AT source.path on the host, not in a separate cache
            # subdir. The launcher bind-mounts source.path into the
            # container at /root/.claude/plugins/marketplaces/<name>, so
            # rewrite BOTH source.path AND installLocation to that target.
            # Claude-code resolves directory-source plugin code by reading
            # <source.path>/.claude-plugin/marketplace.json and following
            # each plugin's relative `source` field, so the bind target
            # must contain that whole tree (which is the host source.path
            # verbatim — that's what gets mounted).
            my %rewritten_src = %{$src};
            $rewritten_src{path} = $container_install;
            my %rewritten = %$entry;
            $rewritten{installLocation} = $container_install;
            $rewritten{source} = \%rewritten_src;
            $out{$name} = \%rewritten;
            next;
        }

        my %rewritten = %$entry;
        $rewritten{installLocation} = $container_install;
        $out{$name} = \%rewritten;
    }

    if (@dropped) {
        warn "materialize-known-marketplaces: dropped marketplaces not usable inside sandbox:\n",
            map { "  - $_\n" } @dropped;
    }

    my $dir = dirname($output);
    make_path($dir) unless -d $dir;
    my $tmp = "$output.tmp.$$";
    open my $fh, '>:raw', $tmp or die "write $tmp: $!\n";
    print $fh JSON::PP->new->canonical(1)->pretty->utf8->encode(\%out);
    close $fh or die "close $tmp: $!\n";
    rename $tmp, $output or do {
        unlink $tmp;
        die "rename $tmp -> $output: $!\n";
    };
    return 0;
}

# =====================================================================
# Settings/install helpers shared by clone-to-project and the TUI write path
# =====================================================================

# Run $code_ref under an exclusive flock on installed_plugins.json's sibling
# .lock file. $code_ref receives the parsed data hash and must return a
# truthy value iff it mutated the data and wants the write committed. The
# helper handles flock acquisition + release, mtime CAS guard against a
# concurrent Claude Code write, and atomic file replacement. Dies on hard
# error (bad file, lock failure, CAS conflict, write failure).
sub _with_plugins_file_lock {
    my ($plugins_file, $code_ref) = @_;
    -f $plugins_file
        or die "plugins file does not exist: $plugins_file\n";

    my $lockfile = "$plugins_file.lock";
    open my $lockfh, '>>', $lockfile
        or die "open $lockfile for locking: $!\n";
    flock($lockfh, LOCK_EX)
        or die "flock $lockfile: $!\n";

    my $err;
    {
        local $@;
        eval {
            my $mtime_at_read = (stat($plugins_file))[9];

            my $data = read_json($plugins_file);
            defined $data && ref $data eq 'HASH'
                or die "$plugins_file is malformed or unreadable\n";
            $data->{plugins} //= {};
            ref $data->{plugins} eq 'HASH'
                or die "$plugins_file 'plugins' has unexpected shape\n";

            # Note: `return` from inside an eval BLOCK exits only the eval,
            # not the enclosing sub (verified via perldoc and runtime test).
            # We still use an explicit if/else here so a future reader doesn't
            # have to look that detail up — the flow is structurally obvious.
            if ($code_ref->($data)) {
                # CAS guard: refuse to write if the file changed under us.
                # Catches a concurrent Claude Code `/plugin install` that
                # landed between our read and our rename. Loud abort is safer
                # than silent clobber — the user just re-runs.
                my $mtime_now = (stat($plugins_file))[9];
                if (defined $mtime_now && defined $mtime_at_read
                    && $mtime_now != $mtime_at_read) {
                    die "$plugins_file was modified concurrently mid-read; aborting to avoid clobbering another writer — please re-run\n";
                }

                write_json_atomic($plugins_file, $data);
            }
        };
        $err = $@;
    }
    flock($lockfh, LOCK_UN);
    close $lockfh;
    die $err if $err;
}

# Decide the new scope=project install entry to append for ($key, $project_path),
# given the existing $installs array. Stateless — no I/O. Returns:
#   ($new_install_hashref, undef)   on success
#   (undef, $reason)                if we should skip the append
# Dies if the key has no candidate source install (means caller is asking
# to promote a non-suggestion — that's a programming error worth surfacing).
sub _compute_new_project_install_entry {
    my ($key, $project_path, $installs) = @_;

    # Idempotency: if a scope=project entry for this project is already
    # present, skip (caller will record an actions_skipped entry).
    for my $inst (@$installs) {
        next unless ref $inst eq 'HASH';
        next unless ($inst->{scope} // '') eq 'project';
        my $ip = normalize_path($inst->{projectPath} // '');
        if (length $ip && lc($ip) eq lc($project_path)) {
            return (undef, "scope=project entry for $project_path already exists");
        }
    }

    # Source install: best non-project entry for this project, using the same
    # scope priority as discover_plugins (local-matching > user).
    my ($source, $source_rank);
    for my $inst (@$installs) {
        next unless ref $inst eq 'HASH';
        my $ipath = $inst->{installPath};
        next unless defined $ipath && length $ipath;
        my $scope = $inst->{scope} // 'local';
        next if $scope eq 'project';  # skipping project-tier as source
        my $inst_project = normalize_path($inst->{projectPath} // '');
        my $matches = length $inst_project
            && lc($inst_project) eq lc($project_path);
        my $rank;
        if    ($scope eq 'local' && $matches) { $rank = 2 }
        elsif ($scope eq 'user')              { $rank = 3 }
        elsif ($matches)                      { $rank = 2 }
        else { next }
        if (!defined $source_rank || $rank <= $source_rank) {
            $source      = $inst;
            $source_rank = $rank;
        }
    }
    defined $source
        or die "plugin '$key' has no suggestion install for $project_path to clone from\n";

    # Store project path in the same form Claude Code itself uses on this
    # platform (Windows-backslashed on Windows; pass-through on Linux).
    my $stored_project_path = denormalize_to_windows($project_path);
    my $now = now_iso();
    my $new_install = {
        scope       => 'project',
        projectPath => $stored_project_path,
        installPath => $source->{installPath},  # copied verbatim
        version     => $source->{version},
        installedAt => $now,
        lastUpdated => $now,
    };
    $new_install->{gitCommitSha} = $source->{gitCommitSha}
        if defined $source->{gitCommitSha};

    return ($new_install, undef);
}

# Append a scope=project install for ($key, $project_path) to
# installed_plugins.json under flock+CAS. Returns ($new_install, undef) on
# successful append, or (undef, $skip_reason) if idempotency kicked in. Dies
# on hard error.
sub _append_project_install_locked {
    my ($key, $project_path, $plugins_file) = @_;

    my $new_install;
    my $skip_reason;
    _with_plugins_file_lock($plugins_file, sub {
        my $data = shift;
        my $installs = $data->{plugins}{$key};
        defined $installs && ref $installs eq 'ARRAY' && @$installs
            or die "plugin key '$key' has no installs in $plugins_file\n";

        my ($entry, $reason) = _compute_new_project_install_entry($key, $project_path, $installs);
        if (!defined $entry) {
            $skip_reason = $reason;
            return 0;  # no write
        }
        push @$installs, $entry;
        $new_install = $entry;
        return 1;
    });
    return ($new_install, $skip_reason);
}

# Apply a batch of changes to a single settings.json file atomically. Reads
# once, mutates, writes once (only if anything actually changed). Used by:
# clone helpers (single-key changes), the TUI write path (mixed batch from a
# confirm), and the TUI stale-cleanup pass for settings.json.
#
# %change_set keys (all optional):
#   enabledPlugins         => { K => true|false|undef-to-delete, ... }
#   enabledMcpjsonServers  => { add => [...], remove => [...] }
#   disabledMcpjsonServers => { add => [...], remove => [...] }
#
# List entries are deduplicated and sorted on write so diffs stay stable.
# Returns the number of distinct mutations applied (0 means nothing written).
sub _apply_settings_json_changes {
    my ($settings_file, %change_set) = @_;

    my $settings = -f $settings_file ? read_json($settings_file) : {};
    $settings = {} unless ref $settings eq 'HASH';

    my $changes = 0;

    if (my $ep_changes = $change_set{enabledPlugins}) {
        $settings->{enabledPlugins} //= {};
        ref $settings->{enabledPlugins} eq 'HASH'
            or die "$settings_file enabledPlugins has unexpected shape (not an object)\n";
        for my $key (keys %$ep_changes) {
            my $new_val = $ep_changes->{$key};
            if (!defined $new_val) {
                # Delete request
                if (exists $settings->{enabledPlugins}{$key}) {
                    delete $settings->{enabledPlugins}{$key};
                    $changes++;
                }
                next;
            }
            my $new_bool   = $new_val ? JSON::PP::true : JSON::PP::false;
            my $new_truthy = $new_val ? 1 : 0;
            if (!exists $settings->{enabledPlugins}{$key}) {
                $settings->{enabledPlugins}{$key} = $new_bool;
                $changes++;
            } else {
                my $cur = $settings->{enabledPlugins}{$key};
                my $cur_truthy = $cur ? 1 : 0;
                if ($cur_truthy != $new_truthy) {
                    $settings->{enabledPlugins}{$key} = $new_bool;
                    $changes++;
                }
            }
        }
    }

    for my $list_name ('enabledMcpjsonServers', 'disabledMcpjsonServers') {
        my $list_changes = $change_set{$list_name} or next;
        $settings->{$list_name} //= [];
        ref $settings->{$list_name} eq 'ARRAY'
            or die "$settings_file $list_name has unexpected shape (not an array)\n";
        my %current = map { $_ => 1 } @{$settings->{$list_name}};
        my $before  = scalar keys %current;
        for my $n (@{$list_changes->{add} // []}) {
            $current{$n} = 1;
        }
        for my $n (@{$list_changes->{remove} // []}) {
            delete $current{$n};
        }
        my @after = sort { $a cmp $b } keys %current;
        # Detect any change relative to the original list (ordering or membership).
        my @orig_sorted = sort { $a cmp $b } @{$settings->{$list_name}};
        my $differs = (scalar @after != scalar @orig_sorted);
        if (!$differs) {
            for my $i (0 .. $#after) {
                if ($after[$i] ne $orig_sorted[$i]) { $differs = 1; last }
            }
        }
        if ($differs) {
            $settings->{$list_name} = \@after;
            $changes++;
        }
    }

    if ($changes) {
        my $sdir = dirname($settings_file);
        make_path($sdir) unless -d $sdir;
        write_json_atomic($settings_file, $settings);
    }
    return $changes;
}

# =====================================================================
# Subcommand: clone-to-project
# =====================================================================
#
# Promotes a Suggestion to Project status, idempotently. Two modes
# (mutually exclusive):
#
#   --plugin-key K: appends { scope: "project", projectPath: P, installPath:
#                   <copied from best non-project install for P> } to the
#                   key's installs array in installed_plugins.json; then
#                   sets enabledPlugins[K] = true in
#                   <project>/.claude/settings.json. Both steps idempotent:
#                   skipped if the project-scope entry / enable flag is
#                   already there.
#
#   --mcp-name N:   sets settings.json enabledMcpjsonServers to include N
#                   (sorted, deduplicated). No installed_plugins.json
#                   change — MCP definitions live in .mcp.json which is
#                   already project-level. Requires N to be defined in
#                   <project>/.mcp.json (else die — we don't enable
#                   undefined servers).
#
# Never edits existing installed_plugins.json entries — only appends.
# Never touches settings.local.json (TUI in D5 handles broader writes).
#
# Required: --project-path P (--plugin-key K | --mcp-name N)
sub cmd_clone_to_project {
    my %opts = @_;

    my $project_path_raw = $opts{project_path};
    die "--project-path required\n" unless defined $project_path_raw && length $project_path_raw;
    my $project_path = normalize_path($project_path_raw);

    my $plugin_key = $opts{plugin_key};
    my $mcp_name   = $opts{mcp_name};
    if ((defined $plugin_key && defined $mcp_name) ||
        (!defined $plugin_key && !defined $mcp_name)) {
        die "specify exactly one of --plugin-key or --mcp-name\n";
    }

    # Require project dir to exist. Don't synthesize arbitrary directories;
    # only the .claude/ subdir is auto-created (it commonly doesn't exist yet
    # on a fresh project) — anything higher should be a real failure.
    -d $project_path_raw or -d $project_path
        or die "project path does not exist: $project_path_raw\n";

    my $result = {
        actions         => [],
        actions_skipped => [],
        no_op           => JSON::PP::false,
    };

    if (defined $plugin_key) {
        clone_plugin_to_project($plugin_key, $project_path, $project_path_raw,
                                $result, %opts);
    } else {
        clone_mcp_to_project($mcp_name, $project_path, $project_path_raw,
                             $result, %opts);
    }

    if (!@{$result->{actions}}) {
        $result->{no_op} = JSON::PP::true;
    }
    print JSON::PP->new->canonical(1)->pretty->encode($result);
    return 0;
}

sub clone_plugin_to_project {
    my ($key, $project_path, $project_path_raw, $result, %opts) = @_;

    my $plugins_file = $opts{plugins_file} // home() . "/.claude/plugins/installed_plugins.json";

    # Installed_plugins.json half — flock+CAS via the shared helper.
    my ($new_install, $skip_reason) =
        _append_project_install_locked($key, $project_path, $plugins_file);

    if (defined $new_install) {
        push @{$result->{actions}}, {
            target => 'installed_plugins.json',
            action => 'append_project_install',
            key    => $key,
            entry  => $new_install,
        };
    } else {
        # Rephrase the reason with the raw (un-normalized) path so the
        # user sees the path shape they typed.
        my $msg = $skip_reason;
        $msg =~ s/\Q$project_path\E/$project_path_raw/g if defined $msg && length $project_path;
        push @{$result->{actions_skipped}}, {
            target => 'installed_plugins.json',
            reason => $msg // "scope=project entry for $project_path_raw already exists",
        };
    }

    # Settings.json half — read once to enforce the "preserve explicit false"
    # idempotency rule, then delegate the write to the shared helper.
    # Different file, different lock domain than the plugins write above; in
    # practice settings.json is small and writes are fast so the race window
    # is tiny.
    my $settings_file = "$project_path/.claude/settings.json";
    my $settings = -f $settings_file ? read_json($settings_file) : {};
    $settings = {} unless ref $settings eq 'HASH';
    $settings->{enabledPlugins} //= {};
    ref $settings->{enabledPlugins} eq 'HASH'
        or die "$settings_file enabledPlugins has unexpected shape (not an object)\n";

    if (!exists $settings->{enabledPlugins}{$key}) {
        _apply_settings_json_changes($settings_file,
            enabledPlugins => { $key => 1 });
        push @{$result->{actions}}, {
            target => 'settings.json',
            action => 'set_enabled_plugin',
            key    => $key,
        };
    } else {
        my $cur = $settings->{enabledPlugins}{$key};
        my $cur_str = (ref $cur && $cur->isa('JSON::PP::Boolean'))
            ? ($cur ? 'true' : 'false')
            : (defined $cur ? "'$cur'" : 'null');
        push @{$result->{actions_skipped}}, {
            target => 'settings.json',
            reason => "enabledPlugins['$key'] already set ($cur_str); not overriding",
        };
    }
}

sub clone_mcp_to_project {
    my ($name, $project_path, $project_path_raw, $result, %opts) = @_;

    my $mcp_file = "$project_path/.mcp.json";
    -f $mcp_file
        or die "$mcp_file does not exist — cannot clone MCP for a project without .mcp.json\n";

    my $mcp_data = read_json($mcp_file);
    defined $mcp_data && ref $mcp_data eq 'HASH'
        or die "$mcp_file is malformed or unreadable\n";
    ref $mcp_data->{mcpServers} eq 'HASH' && exists $mcp_data->{mcpServers}{$name}
        or die "MCP server '$name' is not defined in $mcp_file\n";

    my $settings_file = "$project_path/.claude/settings.json";
    my $settings = -f $settings_file ? read_json($settings_file) : {};
    $settings = {} unless ref $settings eq 'HASH';
    $settings->{enabledMcpjsonServers} //= [];
    ref $settings->{enabledMcpjsonServers} eq 'ARRAY'
        or die "$settings_file enabledMcpjsonServers has unexpected shape (not an array)\n";

    my %already = map { $_ => 1 } @{$settings->{enabledMcpjsonServers}};
    if (!$already{$name}) {
        _apply_settings_json_changes($settings_file,
            enabledMcpjsonServers => { add => [$name] });
        push @{$result->{actions}}, {
            target => 'settings.json',
            action => 'add_enabled_mcp',
            name   => $name,
        };
    } else {
        push @{$result->{actions_skipped}}, {
            target => 'settings.json',
            reason => "enabledMcpjsonServers already contains '$name'",
        };
    }
}

# =====================================================================
# MCP server discovery
# =====================================================================
#
# Reads the project's .mcp.json + .claude/settings.json + settings.local.json
# and returns one entry per MCP server, partitioned by which settings file
# owns the enable/disable decision:
#   partition: "project"    => name appears in any list of settings.json
#                              (the project's source of truth — decision is
#                              project-level, whether or not git-tracked).
#   partition: "suggestion" => name appears only in settings.local.json, or
#                              isn't listed anywhere (defined-only).
#
# When a name appears in BOTH files, settings.json wins for partition.
# `enabled` / `disabled` flags preserve the prior "any file wins" merge.
#
# Stale entries (names listed in settings files but not defined in .mcp.json)
# get the same partition treatment so the TUI can decide whether they belong
# in the Project or Suggestions subsection.
#
# Returns: [ { name, type, defined_in_mcp_json: bool, enabled: bool,
#              disabled: bool, stale: bool, partition: str
#              [, list_membership: 'enabled'|'disabled'] } ]
sub discover_mcp {
    my %opts = @_;

    if (my $snap = $opts{mcp_snapshot}) {
        if (-f $snap) {
            my $data = read_json($snap);
            if (ref $data eq 'ARRAY') {
                return $data;
            }
            warn "Warning: MCP snapshot $snap is malformed; falling back to live discovery.\n";
        }
    }

    my $project_path = normalize_path($opts{project_path}) // '';
    return [] unless length $project_path;

    # Resolve back to a real filesystem path on Git Bash if needed.
    # discover_mcp is read-only; just use the path as given.
    my $mcp_file       = "$project_path/.mcp.json";
    my $settings_main  = "$project_path/.claude/settings.json";
    my $settings_local = "$project_path/.claude/settings.local.json";

    my %defined;  # name => { type, ... }
    if (-f $mcp_file) {
        my $d = read_json($mcp_file);
        if (ref $d eq 'HASH' && ref $d->{mcpServers} eq 'HASH') {
            for my $name (keys %{$d->{mcpServers}}) {
                my $entry = $d->{mcpServers}{$name};
                $defined{$name} = {
                    type => (ref $entry eq 'HASH' ? ($entry->{type} // 'unknown') : 'unknown'),
                };
            }
        }
    }

    # Track which file each name's enable/disable comes from. We can't merge
    # into one hash like before — partition depends on knowing the source file.
    my (%enabled_main, %disabled_main, %enabled_local, %disabled_local);
    if (-f $settings_main) {
        my $d = read_json($settings_main);
        if (ref $d eq 'HASH') {
            if (ref $d->{enabledMcpjsonServers}  eq 'ARRAY') {
                $enabled_main{$_}  = 1 for @{$d->{enabledMcpjsonServers}};
            }
            if (ref $d->{disabledMcpjsonServers} eq 'ARRAY') {
                $disabled_main{$_} = 1 for @{$d->{disabledMcpjsonServers}};
            }
        }
    }
    if (-f $settings_local) {
        my $d = read_json($settings_local);
        if (ref $d eq 'HASH') {
            if (ref $d->{enabledMcpjsonServers}  eq 'ARRAY') {
                $enabled_local{$_}  = 1 for @{$d->{enabledMcpjsonServers}};
            }
            if (ref $d->{disabledMcpjsonServers} eq 'ARRAY') {
                $disabled_local{$_} = 1 for @{$d->{disabledMcpjsonServers}};
            }
        }
    }

    my $is_enabled  = sub { my $n = shift; $enabled_main{$n}  || $enabled_local{$n}  };
    my $is_disabled = sub { my $n = shift; $disabled_main{$n} || $disabled_local{$n} };
    # Partition assignment: if a name appears in any list of settings.json
    # (enabled OR disabled), it's a project-level decision. Otherwise it
    # lives only in settings.local.json — a suggestion the user can promote.
    my $partition_of = sub {
        my $n = shift;
        return 'project' if $enabled_main{$n} || $disabled_main{$n};
        return 'suggestion';
    };

    my @out;
    for my $name (sort keys %defined) {
        push @out, {
            name                 => $name,
            type                 => $defined{$name}{type},
            defined_in_mcp_json  => JSON::PP::true,
            enabled              => ($is_enabled->($name)  ? JSON::PP::true : JSON::PP::false),
            disabled             => ($is_disabled->($name) ? JSON::PP::true : JSON::PP::false),
            stale                => JSON::PP::false,
            partition            => $partition_of->($name),
        };
    }

    # Stale entries: names in any settings list but not defined in .mcp.json.
    # list_membership remembers which list (enabled vs disabled) the entry
    # came from so a "keep" decision in the TUI can restore it correctly.
    my %seen_stale;
    for my $name (sort(keys %enabled_main),  sort(keys %disabled_main),
                  sort(keys %enabled_local), sort(keys %disabled_local)) {
        next if $defined{$name};
        next if $seen_stale{$name}++;
        # Match partition's settings.json-wins priority: if the name appears
        # in settings.json, the project owns the membership decision; only
        # fall back to settings.local.json when settings.json doesn't list it.
        # Within each file, enabled wins over disabled — a contradictory
        # in-file state (both lists contain the name) is ambiguous data, and
        # preserving "enabled" is the user-friendlier read.
        my $membership = $enabled_main{$name}  ? 'enabled'
                       : $disabled_main{$name} ? 'disabled'
                       : $enabled_local{$name} ? 'enabled'
                       :                         'disabled';
        push @out, {
            name                 => $name,
            type                 => undef,
            defined_in_mcp_json  => JSON::PP::false,
            enabled              => ($is_enabled->($name)  ? JSON::PP::true : JSON::PP::false),
            disabled             => ($is_disabled->($name) ? JSON::PP::true : JSON::PP::false),
            stale                => JSON::PP::true,
            list_membership      => $membership,
            partition            => $partition_of->($name),
        };
    }

    return \@out;
}

# =====================================================================
# Subcommand: discover-mcp
# =====================================================================

sub cmd_discover_mcp {
    my %opts = @_;
    my $mcp = discover_mcp(%opts);
    print JSON::PP->new->canonical(1)->pretty->encode($mcp);
    return 0;
}

# =====================================================================
# Subcommand: write-mcp-state
# =====================================================================
#
# Updates `enabledMcpjsonServers` + `disabledMcpjsonServers` in the project's
# `.claude/settings.local.json`. Preserves all other keys. Atomic write.
# Also prunes stale entries (names not present in .mcp.json) — the user
# asked for stale cleanup as part of this work.
#
# Required: --settings-local FILE --enabled "a,b,c" --disabled "d,e"
#           --project-path PATH (needed to find .mcp.json for prune)
sub cmd_write_mcp_state {
    my %opts = @_;
    my $file = $opts{settings_local} or die "--settings-local required\n";
    my $enabled_csv  = $opts{enabled}  // '';
    my $disabled_csv = $opts{disabled} // '';

    my @enabled  = grep { length } split /,/, $enabled_csv;
    my @disabled = grep { length } split /,/, $disabled_csv;

    # Trust the caller (the TUI) for the exact list contents - it handles
    # the keep/prune decision per stale entry explicitly. No auto-pruning here.

    # Read existing settings.local.json (preserve everything except the two
    # MCP arrays). Create empty hash if file doesn't exist.
    my $existing = -f $file ? read_json($file) : {};
    $existing = {} unless ref $existing eq 'HASH';

    # Deterministic ordering - sort alphabetically so the file diff is stable.
    @enabled  = sort { $a cmp $b } @enabled;
    @disabled = sort { $a cmp $b } @disabled;

    $existing->{enabledMcpjsonServers}  = \@enabled;
    $existing->{disabledMcpjsonServers} = \@disabled;

    # Make sure the directory exists (first-time write).
    my $dir = dirname($file);
    make_path($dir) unless -d $dir;

    write_json_atomic($file, $existing);
    return 0;
}

# =====================================================================
# Subcommand: materialize-credentials
# =====================================================================
#
# Generates a sandboxed copy of ~/.claude/.credentials.json that the
# container can use without inheriting the host's MCP OAuth tokens.
#
# - Always copies the host's `claudeAiOauth` (refreshed on every launcher
#   run, so the container stays in sync with the user's Claude account).
# - PRESERVES the container's own `mcpOAuth` entries from previous runs,
#   so plugin auth done inside the sandbox persists across rebuilds.
# - DOES NOT propagate any host `mcpOAuth` entries. Every MCP server in
#   the container starts fresh; the user authenticates again inside the
#   sandbox (separate trust domain from the host).
# - Strips any other unknown top-level keys defensively.
# - Both copied values must be of HASH type. A malformed value (null,
#   string, array, scalar) is silently dropped — guards against a
#   corrupted-but-parseable JSON propagating undefined behavior into
#   Claude Code's parser, and matches the documented "missing -> fresh
#   auth" failure mode rather than producing confusing runtime errors.
# - Output is chmod'd 0600 before rename so the OAuth token is not left
#   world-readable on Linux/WSL2 hosts where the file is bind-mounted
#   into the container. (On Windows, Perl's chmod only twiddles the
#   read-only bit; the call is harmless and keeps one code path for all
#   platforms.)
#
# Required: --output FILE [--host-credentials FILE]
sub cmd_materialize_credentials {
    my %opts = @_;
    my $output = $opts{output} or die "--output required\n";
    my $host_file = $opts{host_credentials} // home() . "/.claude/.credentials.json";

    # Host file is concurrently rewritten by the host's Claude session whenever
    # the Anthropic OAuth token rotates. read_json returns undef on a torn read
    # mid-rename; the original code silently fell back to `{}` here, which
    # propagated as a sandbox booting without `claudeAiOauth` (unauthenticated
    # container). Retry 3x with 100ms backoff covers the race window without
    # masking a genuinely corrupt host file.
    my $host = -f $host_file ? read_json_with_retry($host_file) : {};
    $host = {} unless ref $host eq 'HASH';

    # Same retry pattern for the per-sandbox accumulator: a torn read here
    # would silently drop in-container mcpOAuth tokens the user already
    # authed for. Existence of the output is optional (first launch), but
    # if it does exist, a parse failure should not be swallowed.
    my $existing = -f $output ? read_json_with_retry($output) : {};
    $existing = {} unless ref $existing eq 'HASH';

    my $merged = {};
    # 1. Claude account OAuth: always from host (rotates as host refreshes).
    #    Strict HASH guard: a null/string/array `claudeAiOauth` is dropped
    #    so the container sees no token rather than a malformed one.
    if (exists $host->{claudeAiOauth} && ref $host->{claudeAiOauth} eq 'HASH') {
        $merged->{claudeAiOauth} = $host->{claudeAiOauth};
    }
    # 2. MCP OAuth: preserve whatever the CONTAINER has accumulated; never
    #    inject host entries. First run yields empty mcpOAuth -> container
    #    does its own auth flow on first MCP use. Strict HASH guard for
    #    same reason as above — a corrupted container-side mcpOAuth (e.g.
    #    array, scalar) is dropped so Claude Code's parser doesn't choke.
    if (exists $existing->{mcpOAuth} && ref $existing->{mcpOAuth} eq 'HASH') {
        $merged->{mcpOAuth} = $existing->{mcpOAuth};
    }

    my $dir = dirname($output);
    make_path($dir) unless -d $dir;
    my $tmp = "$output.tmp.$$";
    open my $fh, '>:raw', $tmp or die "write $tmp: $!\n";
    print $fh JSON::PP->new->canonical(1)->pretty->utf8->encode($merged);
    close $fh or die "close $tmp: $!\n";
    # Restrict to owner-only BEFORE rename so the destination path is never
    # briefly world-readable. chmod failure is non-fatal (Windows can't honor
    # the full mode; we still want the write to succeed there).
    chmod 0600, $tmp or warn "chmod 0600 $tmp: $!\n";
    rename $tmp, $output or do {
        unlink $tmp;
        die "rename $tmp -> $output: $!\n";
    };
    return 0;
}

# =====================================================================
# Subcommand: help
# =====================================================================

sub cmd_help {
    print <<'USAGE';
Usage: plugins/sandbox/scripts/skills.pl <command> [options]

Commands:
  discover                                          List available custom skills as JSON.
  discover-plugins    --project-path P              List plugins for this project as JSON.
  discover-mcp        --project-path P              List project MCP servers + state as JSON.
  load-selection      --selection-file FILE         Print current state (migrates v1->v3).
  prune               --selection-file FILE         Drop dead entries; write state.
  diff                --selection-file FILE         Compare discovery to mounted baseline.
  select-interactive  --selection-file FILE         TUI selector for skills/plugins/MCP;
                                                    writes selection + settings.local.json.
  mounts              --selection-file FILE         Emit host_path<TAB>name per line.
  record-mount        --selection-file FILE         Set mounted_at_create = selected.
  manifest            --selection-file FILE [--output FILE]
                                                    Emit container-side manifest JSON.
  materialize-plugins --selection-file FILE --output FILE
                                                    Emit container-shaped installed_plugins.json.
  clone-to-project    --project-path P (--plugin-key K | --mcp-name N)
                                                    Promote a Suggestion to Project: append
                                                    scope=project install (plugins) or add to
                                                    enabledMcpjsonServers (MCP) in settings.json.
                                                    Idempotent; only ADDS, never edits existing.
  materialize-credentials --output FILE             Emit sandbox-isolated .credentials.json:
                                                    claudeAiOauth from host, mcpOAuth from
                                                    previous container state only.
  materialize-known-marketplaces --output FILE      Emit container-shaped known_marketplaces.json:
                                                    rewrites Windows installLocation paths to the
                                                    container mount target; drops directory-source
                                                    marketplaces whose source.path isn't mounted.
  write-mcp-state     --settings-local FILE --enabled "..." --disabled "..."
                                                    Overwrite enabled/disabled MCP lists in
                                                    settings.local.json. Caller-authoritative
                                                    (no auto-pruning); TUI decides.
  help                                              Show this help.

Common options:
  --plugins-file FILE          Override $HOME/.claude/plugins/installed_plugins.json.
  --discovery-snapshot FILE    Use a frozen skills discovery snapshot.
  --plugins-snapshot FILE      Use a frozen plugins discovery snapshot.
  --project-path PATH          Current project (Git Bash form); needed for plugin scope filtering.

All subcommands return exit 0 on success, non-zero on hard error.
USAGE
    return 0;
}

# =====================================================================
# Arg parser + dispatch
# =====================================================================

sub parse_args {
    # Decode all argv entries from UTF-8 at the entry point. Without this,
    # any non-ASCII char in a path (e.g. "André" in $HOME) arrives as raw
    # UTF-8 bytes and gets double-encoded on JSON write (or compared against
    # already-decoded JSON-source paths and silently mismatches). Decoding
    # here makes every downstream subcommand path-safe.
    my @argv = map { from_fs($_) } @_;
    my %opts;
    while (@argv) {
        my $arg = shift @argv;
        if ($arg =~ /^--([^=]+)=(.*)$/) {
            (my $key = $1) =~ tr/-/_/;
            $opts{$key} = $2;
        } elsif ($arg =~ /^--(.+)$/) {
            (my $key = $1) =~ tr/-/_/;
            die "--$1 requires a value\n" unless @argv;
            $opts{$key} = shift @argv;
        } else {
            die "Unexpected positional argument: $arg\n";
        }
    }
    return %opts;
}

my %DISPATCH = (
    'discover'            => \&cmd_discover,
    'discover-plugins'    => \&cmd_discover_plugins,
    'load-selection'      => \&cmd_load_selection,
    'prune'               => \&cmd_prune,
    'diff'                => \&cmd_diff,
    'select-interactive'  => \&cmd_select_interactive,
    'mounts'              => \&cmd_mounts,
    'record-mount'        => \&cmd_record_mount,
    'manifest'            => \&cmd_manifest,
    'discover-mcp'            => \&cmd_discover_mcp,
    'write-mcp-state'         => \&cmd_write_mcp_state,
    'materialize-plugins'              => \&cmd_materialize_plugins,
    'materialize-credentials'          => \&cmd_materialize_credentials,
    'materialize-known-marketplaces'   => \&cmd_materialize_known_marketplaces,
    'clone-to-project'        => \&cmd_clone_to_project,
    'help'                    => \&cmd_help,
    '--help'              => \&cmd_help,
    '-h'                  => \&cmd_help,
);

# SANDBOX_SKILLS_NO_DISPATCH lets the test harness `require` this file
# to call sub helpers directly without triggering the normal CLI dispatch
# (which would consume @ARGV and exit). Production launchers never set it.
unless ($ENV{SANDBOX_SKILLS_NO_DISPATCH}) {
    my $cmd = shift @ARGV;
    $cmd //= '';
    unless (exists $DISPATCH{$cmd}) {
        print STDERR "Unknown command: '$cmd'\n\n" if length $cmd;
        cmd_help();
        exit 1;
    }
    my %opts = parse_args(@ARGV);
    exit $DISPATCH{$cmd}->(%opts);
}

1;  # for require
