package SandboxSettings;
# SandboxSettings.pm -- what happens to a sandbox's own settings.json and
# CLAUDE.md when its container is created, and the backups that protect them.
#
# A sandbox's user settings are <project>/.ccpraxis-local-data/claude-home/
# settings.json (/root/.claude/settings.json in the container). The launcher
# seeds it from the sandbox preset, plugins/sandbox/container/settings.json,
# and keeps the preset the sandbox was last given in claude-home/.launcher/
# container-settings.json (the BASE).
#
# THE MERGE. That file used to be copied over the sandbox's settings.json on
# every container create, so a Rebuild silently discarded every change made
# inside the sandbox, and a recreate that was not a Rebuild even copied the OLD
# preset back. merge_settings() replaces the copy with a per-unit three-way
# merge on the unit model every settings sync shares (SettingsUnits::merge3):
#   base   = the preset this sandbox was last given (the BASE file)
#   local  = the sandbox's current settings.json
#   remote = the current preset
# A unit only the sandbox changed is kept, a unit only the preset changed is
# taken, and a unit both changed is settled by the caller's resolver (the
# launcher asks; with nobody to ask it keeps the sandbox's value). The old file
# is backed up first, and the current preset becomes the new BASE.
#
# CLAUDE.MD stays generated: it is ccpraxis's rendered instructions for the
# container. refresh_claude_md() writes the current render, but when the
# sandbox's copy differs from the last render it was given, that copy is
# backed up first and the caller says so.
#
# THE BACKUPS go to claude-home/.launcher/backups/<UTC stamp>/. .launcher is
# bind-mounted read-only at /root/.claude/.launcher, so nothing working through
# the container's config dir (Claude Code, an agent tidying ~/.claude) can
# change them. That is the same protection the BASE and every other launcher
# record has, and no more: /project is the whole project read-write, so a
# process in the container determined to can reach the same files through
# /project/.ccpraxis-local-data. No place inside the project is out of its
# reach, and a place outside it (~/.claude) would detach a project's backups
# from the project. One consequence: deleting .launcher (sandbox-checkouts.md
# calls it derived state) also deletes these backups and the BASE; the next
# create then merges without a base (every difference is asked about).
#
# THE DECLINED-PRESET MEMORY. Choosing "Continue" at the stale prompt leaves a
# preset change unapplied, and the prompt used to ask again on every launch.
# drift_state() lets the launcher remember the preset version the operator
# declined and stay quiet until the preset changes again.
#
# The unit model is loaded from plugins/steward/scripts/SettingsUnits.pm by
# file path, without adding that directory to @INC (the launcher keeps its
# @INC to its own directory; see ContainerClaudeMd.pm). Core modules only.
# Callers: launcher.pl (at container create, and the stale check),
# scripts/backup/Export.pm (the "sandbox preset vs each sandbox" pair, which
# reverts a sandbox unit through apply_units()).
use strict;
use warnings;
use File::Basename qw(dirname basename);
use File::Path qw(make_path);
use File::Temp ();
use JSON::PP ();
use POSIX qw(strftime);

BEGIN {
    unless (defined &SettingsUnits::merge3) {
        (my $here = __FILE__) =~ s{\\}{/}g;
        my $path = dirname($here) . '/../../steward/scripts/SettingsUnits.pm';
        # A relative path given to require is searched through @INC, not
        # taken from the current directory; "./" makes it the latter.
        $path = "./$path" unless $path =~ m{^(?:/|[A-Za-z]:|\./|\.\./)};
        require $path;
        $INC{'SettingsUnits.pm'} //= $path;
    }
}

# Where a sandbox's backups go, under its launcher dir.
sub backups_root {
    my ($launcher_dir) = @_;
    return "$launcher_dir/backups";
}

# backup_dir_maker($launcher_dir, $now) -> CODE
# The returned sub creates ONE fresh <stamp> directory on its first call and
# returns that same path on every later call, so everything one create backs
# up lands together. A stamp already taken (two creates in a second) gets a
# -2, -3 ... suffix rather than mixing two creates' files.
sub backup_dir_maker {
    my ($launcher_dir, $now) = @_;
    my $made;
    return sub {
        return $made if defined $made;
        my $root  = backups_root($launcher_dir);
        my $stamp = strftime('%Y%m%dT%H%M%SZ', gmtime($now // time));
        make_path($root) unless -d $root;
        my $dir = "$root/$stamp";
        my $n = 1;
        while (!mkdir $dir) {
            die "SandboxSettings: cannot create a backup directory under $root: $!\n" unless -e $dir;
            $n++;
            $dir = "$root/$stamp-$n";
        }
        $made = $dir;
        return $made;
    };
}

# backup_file($src, $dir_maker) -> the backup's path. Bytes, unchanged.
sub backup_file {
    my ($src, $dir_maker) = @_;
    my $bytes = _read_bytes($src);
    die "SandboxSettings: cannot read $src to back it up\n" unless defined $bytes;
    my $dst = $dir_maker->() . '/' . basename($src);
    _write_bytes_atomic($dst, $bytes);
    return $dst;
}

# read_json($path) -> ($data, $error, $exists)
# Absent: (undef, undef, 0). Unreadable or not a JSON object: (undef, $why, 1).
sub read_json {
    my ($path) = @_;
    return (undef, undef, 0) unless -e $path;
    my $bytes = _read_bytes($path);
    return (undef, "cannot read $path", 1) unless defined $bytes;
    my $data = eval { JSON::PP->new->utf8->decode($bytes) };
    return (undef, "$path is not valid JSON", 1) if $@;
    return (undef, "$path is not a JSON object", 1) unless ref($data) eq 'HASH';
    return ($data, undef, 1);
}

# The one format every write here uses: the preset's own (canonical, pretty).
sub encode_json_file {
    my ($data) = @_;
    return JSON::PP->new->utf8->canonical->pretty->encode($data);
}

# merge_settings(%o) -> hashref
#   target     the sandbox's settings.json (claude-home/settings.json)
#   base       the BASE file (claude-home/.launcher/container-settings.json)
#   preset     the current preset (plugins/sandbox/container/settings.json)
#   backup_dir a backup_dir_maker() sub
#   resolve    CODE called once per unit both sides changed, with the
#              SettingsUnits::merge3 conflict record; returns 'keep' or 'take'
#
# status:
#   created             no settings.json yet: the preset, as it is
#   merged              the merge changed the file (backup holds the old one)
#   unchanged           the merge result is the file as it was; not rewritten
#   replaced_unreadable the sandbox's file did not parse: backed up, then the
#                       preset written in its place (what every create did
#                       before, minus the silent loss)
#   preset_unreadable   the preset does not parse: the sandbox's file is left
#                       alone and the BASE is not moved (so the next create
#                       tries again); with no sandbox file the preset bytes are
#                       copied as they are, as before
# Also: backup (path or undef), taken / kept / agreed / conflicts (merge3's),
# base_recorded (1 when BASE now holds the current preset), base_missing,
# warning (text or undef).
sub merge_settings {
    my (%o) = @_;
    my %r = (status => undef, backup => undef, taken => [], kept => [], agreed => [],
             conflicts => [], base_recorded => 0, base_missing => 0, warning => undef);

    my $preset_bytes = _read_bytes($o{preset});
    die "SandboxSettings: cannot read the sandbox preset $o{preset}\n" unless defined $preset_bytes;
    my ($remote, $remote_err) = read_json($o{preset});
    my ($local, $local_err, $local_exists) = read_json($o{target});

    if (defined $remote_err || !defined $remote) {
        $r{status}  = 'preset_unreadable';
        $r{warning} = "the sandbox preset does not parse ($o{preset}); "
                    . ($local_exists ? "the sandbox's settings.json was left as it is"
                                     : 'it was copied in as it is');
        _write_bytes_atomic($o{target}, $preset_bytes) unless $local_exists;
        return \%r;
    }

    if (!$local_exists) {
        _write_bytes_atomic($o{target}, $preset_bytes);
        $r{status} = 'created';
    }
    elsif (defined $local_err) {
        $r{backup}  = backup_file($o{target}, $o{backup_dir});
        _write_bytes_atomic($o{target}, $preset_bytes);
        $r{status}  = 'replaced_unreadable';
        $r{warning} = "the sandbox's settings.json did not parse ($local_err); it was backed up and replaced with the preset";
    }
    else {
        my ($base, $base_err, $base_exists) = read_json($o{base});
        $r{base_missing} = (!$base_exists || defined $base_err) ? 1 : 0;
        my $m = SettingsUnits::merge3(base => $base, local => $local, remote => $remote,
                                      resolve => $o{resolve});
        $r{$_} = $m->{$_} for qw(taken kept agreed conflicts);
        if ($m->{changed}) {
            $r{backup} = backup_file($o{target}, $o{backup_dir});
            _write_bytes_atomic($o{target}, encode_json_file($m->{result}));
            $r{status} = 'merged';
        }
        else {
            $r{status} = 'unchanged';
        }
    }

    _write_bytes_atomic($o{base}, $preset_bytes);
    $r{base_recorded} = 1;
    return \%r;
}

# refresh_claude_md(%o) -> { status => 'written'|'unchanged', backup => path|undef }
#   target       the sandbox's CLAUDE.md (claude-home/CLAUDE.md)
#   last_render  the render the sandbox was last given (.launcher/container-CLAUDE.md)
#   render       the current render (text)
#   backup_dir   a backup_dir_maker() sub
# The sandbox's copy is backed up when it differs from the last render it was
# given -- or, with no record of one, from the current render.
sub refresh_claude_md {
    my (%o) = @_;
    my %r = (status => 'unchanged', backup => undef);
    my $current = _read_bytes($o{target});
    if (defined $current) {
        my $last = _read_bytes($o{last_render});
        my $reference = defined $last ? $last : $o{render};
        $r{backup} = backup_file($o{target}, $o{backup_dir}) if $current ne $reference;
    }
    if (!defined $current || $current ne $o{render}) {
        _write_bytes_atomic($o{target}, $o{render});
        $r{status} = 'written';
    }
    _write_bytes_atomic($o{last_render}, $o{render});
    return \%r;
}

# drift_state(saved => H, current => H, declined => H) -> 'none'|'declined'|'changed'
#   saved     the hash recorded when the sandbox was last given the file
#   current   the hash of what it would be given now
#   declined  the hash the operator answered "Continue" to, if any
# No saved record is not drift (nothing to compare against).
sub drift_state {
    my (%o) = @_;
    my ($saved, $current, $declined) = map { defined $_ ? $_ : '' } @o{qw(saved current declined)};
    s/\s+\z// for $saved, $current, $declined;
    return 'none'     unless length $saved && $saved ne $current;
    return 'declined' if length $declined && $declined eq $current;
    return 'changed';
}

# apply_units(%o) -> { backup => path|undef, error => text|undef, applied => [names] }
#   target      a sandbox's settings.json
#   backup_dir  a backup_dir_maker() sub
#   units       [ { name, path => [k] | [k, sk], found => 0|1, value => V }, ... ]
# Sets each unit to value (found) or removes it (not found), after backing the
# file up. Nothing else in the file changes. Used by /steward:backup's
# "revert this sandbox to the preset's value".
sub apply_units {
    my (%o) = @_;
    my ($data, $err, $exists) = read_json($o{target});
    return { error => "cannot revert: $o{target} does not exist" } unless $exists;
    return { error => "cannot revert: $err" } if defined $err;
    my @applied;
    for my $u (@{ $o{units} || [] }) {
        next unless ref($u) eq 'HASH' && ref($u->{path}) eq 'ARRAY' && @{ $u->{path} };
        my $from = {};
        SettingsUnits::set_at_path($from, $u->{path}, $u->{value}) if $u->{found};
        SettingsUnits::take_at_path($data, $u->{path}, $from);
        push @applied, $u->{name} // join('.', @{ $u->{path} });
    }
    return { applied => [] } unless @applied;
    my $backup = eval { backup_file($o{target}, $o{backup_dir}) };
    return { error => "cannot back up $o{target}: $@" } unless defined $backup;
    my $ok = eval { _write_bytes_atomic($o{target}, encode_json_file($data)); 1 };
    return { error => "cannot write $o{target}: $@", backup => $backup } unless $ok;
    return { backup => $backup, applied => \@applied };
}

sub _read_bytes {
    my ($path) = @_;
    return undef unless defined $path && -f $path;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return defined $c ? $c : '';
}

# Temp file in the destination directory, then rename: a reader (Claude Code
# watching its settings.json) never sees a half-written file. The file keeps
# the mode it had (a new one gets the umask's), not File::Temp's 0600.
sub _write_bytes_atomic {
    my ($path, $bytes) = @_;
    my $dir = dirname($path);
    make_path($dir) unless -d $dir;
    my $mode = (stat $path)[2];
    $mode = defined $mode ? ($mode & 07777) : (0666 & ~umask);
    my ($fh, $tmp) = File::Temp::tempfile('.sandbox-settings-XXXXXXXX', DIR => $dir, UNLINK => 0);
    binmode $fh;
    print {$fh} $bytes;
    unless (close $fh) {
        my $e = $!;
        unlink $tmp;
        die "SandboxSettings: cannot write $tmp: $e\n";
    }
    chmod $mode, $tmp;
    unless (rename $tmp, $path) {
        my $e = $!;
        unlink $tmp;
        die "SandboxSettings: cannot rename $tmp -> $path: $e\n";
    }
    return 1;
}

1;
