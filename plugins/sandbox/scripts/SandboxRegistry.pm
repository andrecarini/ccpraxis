package SandboxRegistry;
# SandboxRegistry.pm -- this machine's list of sandboxed projects.
#
# /steward:backup compares each sandbox's settings.json with the sandbox
# preset, so it needs to know where the sandboxes are. Nothing recorded that:
# a sandbox is a project directory anywhere on disk with a
# .ccpraxis-local-data/claude-home/ the launcher made. This module keeps the
# list. ONE WRITER, ONE READER: launcher.pl registers the project it launches
# (register), and scripts/backup/Export.pm reads the list (entries).
#
# WHERE: <home>/.claude/ccpraxis-sandbox-projects.json, next to the other
# machine-local files ccpraxis keeps there (ccpraxis-protected-paths.json,
# almanac-global-counts.json). Not inside any project: a project is
# bind-mounted read-write into its container, so a list kept there would be
# writable by every sandbox it names. Not in the live install either: that
# is a git checkout promote.pl refuses to fast-forward while it holds a file
# it does not know, and a launcher run from a dev clone or a fork would have
# no business writing into it. ~/.claude is mounted into no container (single
# read-only files at most), and the vault copies nothing from its top level.
# Machine-local by nature: the paths are this machine's.
#
# THE PROJECT ID. Preferences the backup remembers for one sandbox are keyed
# by an id, not by the path, so they survive moving or renaming the project.
# The id is minted once and kept in the project at claude-home/.launcher/
# sandbox-id (read-only inside the container, like every launcher record).
#   moved or renamed  the id travels with the directory; the entry's path is
#                     updated on the next launch.
#   copied            two directories carry the same id. The one already
#                     registered keeps it; the copy is given a fresh id, so
#                     its answers never apply to the original.
#   .launcher deleted the id file is gone; the entry for this path, if any,
#                     gives it back, so remembered answers are not lost.
#
# Format: { "format": 1, "projects": { "<id>": { "path", "launcher",
# "container", "registered_at", "updated_at" } } }. "launcher" is the
# launcher identity (SandboxIdentity $ID) that registered it, so a fork's
# sandboxes, given a different preset, can be told apart from ccpraxis's.
#
# Entries whose directory no longer exists are pruned whenever the launcher
# registers a project. Core modules only.
use strict;
use warnings;
use Digest::MD5 ();
use Encode ();
use Fcntl qw(:flock);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Temp ();
use JSON::PP ();
use POSIX qw(strftime);

our $FORMAT = 1;
our $FILE_NAME = 'ccpraxis-sandbox-projects.json';

# registry_path($claude_dir) -> the registry file under <home>/.claude.
sub registry_path {
    my ($claude_dir) = @_;
    (my $d = defined $claude_dir ? $claude_dir : '') =~ s{\\}{/}g;
    $d =~ s{/+\z}{};
    return "$d/$FILE_NAME";
}

# Where a project keeps its sandbox data.
sub claude_home_for  { my ($project) = @_; return "$project/.ccpraxis-local-data/claude-home"; }
sub launcher_dir_for { my ($project) = @_; return claude_home_for($project) . '/.launcher'; }
sub id_file          { my ($launcher_dir) = @_; return "$launcher_dir/sandbox-id"; }

sub valid_id { my ($id) = @_; return (defined $id && !ref $id && $id =~ /\A[0-9a-f]{16}\z/) ? 1 : 0; }

# read_registry($path) -> ($data, $error). Absent is an empty registry.
sub read_registry {
    my ($path) = @_;
    return ({ format => $FORMAT, projects => {} }, undef) unless -e $path;
    open my $fh, '<:raw', $path or return (undef, "cannot read $path: $!");
    local $/;
    my $raw = <$fh>;
    close $fh;
    my $data = eval { JSON::PP->new->utf8->decode($raw) };
    return (undef, "$path is not valid JSON") if $@ || ref($data) ne 'HASH';
    return (undef, "$path has an unknown format") unless ($data->{format} // 0) == $FORMAT;
    $data->{projects} = {} unless ref($data->{projects}) eq 'HASH';
    # Text in the file, bytes in memory: a path is used for file operations,
    # and those take its UTF-8 bytes (a non-ASCII home such as C:/Users/André).
    for my $e (values %{ $data->{projects} }) {
        next unless ref($e) eq 'HASH';
        $e->{$_} = _to_bytes($e->{$_}) for grep { defined $e->{$_} && !ref $e->{$_} } qw(path launcher container);
    }
    return ($data, undef);
}

# The file form of a registry: every string as text, so the ->utf8 encoder
# encodes each non-ASCII character exactly once (never byte by byte).
sub _file_form {
    my ($data) = @_;
    my %projects;
    for my $id (keys %{ $data->{projects} }) {
        my %e = %{ $data->{projects}{$id} };
        $e{$_} = _to_chars($e{$_}) for grep { defined $e{$_} && !ref $e{$_} } qw(path launcher container);
        $projects{$id} = \%e;
    }
    return { %$data, projects => \%projects };
}

sub _to_bytes {
    my ($s) = @_;
    return utf8::is_utf8($s) ? Encode::encode('UTF-8', $s) : $s;
}

sub _to_chars {
    my ($s) = @_;
    return $s if utf8::is_utf8($s);
    my $probe = $s;
    my $c = eval { Encode::decode('UTF-8', $probe, Encode::FB_CROAK()) };
    return defined $c ? $c : Encode::decode('ISO-8859-1', $s);
}

# entries(registry => PATH, launcher => ID?) -> ($list, $error)
# $list: [ { id, path, launcher, container, registered_at, updated_at } ],
# sorted by path; only entries the given launcher identity registered when
# launcher is passed. The reader never prunes and never writes.
sub entries {
    my (%o) = @_;
    my ($data, $err) = read_registry($o{registry});
    return ([], $err) if defined $err;
    my @out;
    for my $id (sort keys %{ $data->{projects} }) {
        my $e = $data->{projects}{$id};
        next unless valid_id($id) && ref($e) eq 'HASH' && defined $e->{path} && length $e->{path};
        next if defined $o{launcher} && ($e->{launcher} // '') ne $o{launcher};
        push @out, { %$e, id => $id };
    }
    @out = sort { $a->{path} cmp $b->{path} || $a->{id} cmp $b->{id} } @out;
    return (\@out, undef);
}

# register(registry => PATH, project_path => DIR, launcher => ID,
#          container => NAME, now => EPOCH?, fold_case => 0|1?)
#   -> { id, changed, reminted, pruned => [ids], error }
# Idempotent: a launch that changes nothing rewrites nothing. fold_case
# (default: this host's rule -- case-insensitive on Windows and macOS)
# decides whether two spellings of a path are one directory.
sub register {
    my (%o) = @_;
    my $now  = $o{now} // time;
    my $fold = exists $o{fold_case} ? ($o{fold_case} ? 1 : 0) : _host_folds_case();
    my $key  = sub { _path_key($_[0], $fold) };
    my $project = $o{project_path};
    my %r = (id => undef, changed => 0, reminted => 0, pruned => [], error => undef);
    return { %r, error => 'no project path' } unless defined $project && length $project;

    my $path = $o{registry};
    make_path(dirname($path)) unless -d dirname($path);
    open(my $lock, '>>', "$path.lock") or return { %r, error => "cannot open $path.lock: $!" };
    my $locked = 0;
    for (1 .. 50) {
        if (flock($lock, LOCK_EX | LOCK_NB)) { $locked = 1; last; }
        select(undef, undef, undef, 0.1);
    }
    unless ($locked) { close $lock; return { %r, error => "$path is locked by another launcher" }; }

    my $out = eval {
        my ($data, $err) = read_registry($path);
        if (defined $err) {
            # The list is rebuilt by launches; a corrupt one is set aside, not
            # trusted and not silently overwritten.
            my $aside = "$path.corrupt-" . strftime('%Y%m%dT%H%M%SZ', gmtime($now));
            rename $path, $aside;
            $data = { format => $FORMAT, projects => {} };
        }
        my $before = JSON::PP->new->canonical->encode($data);
        my $projects = $data->{projects};

        for my $id (sort keys %$projects) {
            my $e = $projects->{$id};
            unless (valid_id($id) && ref($e) eq 'HASH' && defined $e->{path} && -d $e->{path}) {
                delete $projects->{$id};
                push @{ $r{pruned} }, $id;
            }
        }

        my $pk = $key->($project);
        my ($by_path) = grep { $key->($projects->{$_}{path}) eq $pk } sort keys %$projects;
        my $id_path = id_file(launcher_dir_for($project));
        my $id = _read_id($id_path);
        my $write_id = 0;
        if (!valid_id($id)) {
            $id = $by_path // _mint_id($project, $now);
            $write_id = 1;
        }
        elsif ($projects->{$id} && $key->($projects->{$id}{path}) ne $pk) {
            my $other = $projects->{$id}{path};
            if (-d $other && (_read_id(id_file(launcher_dir_for($other))) // '') eq $id) {
                # A copy: the registered directory still carries this id.
                $id = (defined $by_path && $by_path ne $id) ? $by_path : _mint_id($project, $now);
                $write_id = 1;
                $r{reminted} = 1;
            }
            # else the project moved: the id stays, the path is updated below.
        }
        for my $other_id (keys %$projects) {
            delete $projects->{$other_id}
                if $other_id ne $id && $key->($projects->{$other_id}{path}) eq $pk;
        }
        _write_atomic($id_path, "$id\n") if $write_id;

        my $e = $projects->{$id} // { registered_at => $now };
        $e->{path}      = $project;
        $e->{launcher}  = $o{launcher} if defined $o{launcher};
        $e->{container} = $o{container} if defined $o{container};
        $projects->{$id} = $e;
        my $mid = JSON::PP->new->canonical->encode($data);
        if ($mid ne $before) {
            $e->{updated_at} = $now;
            _write_atomic($path, JSON::PP->new->utf8->canonical->pretty->encode(_file_form($data)));
            $r{changed} = 1;
        }
        $r{id} = $id;
        1;
    };
    $r{error} = "registry update failed: $@" unless $out;
    flock($lock, LOCK_UN);
    close $lock;
    return \%r;
}

# Case-insensitive filesystems: the Windows family and macOS (APFS). The host
# flags are HostPlatform's (same directory), loaded only by the writer, so the
# backup's reader does not need it.
sub _host_folds_case {
    require HostPlatform;
    no warnings q{once};
    return ($HostPlatform::WINDOWS_FAMILY || $HostPlatform::DARWIN) ? 1 : 0;
}

sub _path_key {
    my ($p, $fold) = @_;
    (my $k = defined $p ? $p : '') =~ s{\\}{/}g;
    $k =~ s{(?<=.)/+\z}{};
    return $fold ? lc $k : $k;
}

sub _read_id {
    my ($path) = @_;
    return undef unless -f $path;
    open my $fh, '<:raw', $path or return undef;
    my $line = <$fh>;
    close $fh;
    return undef unless defined $line;
    $line =~ s/\s+\z//;
    return valid_id($line) ? $line : undef;
}

sub _mint_id {
    my ($project, $now) = @_;
    return substr(Digest::MD5::md5_hex(join '|', $project, $now, $$, rand(), time), 0, 16);
}

sub _write_atomic {
    my ($path, $bytes) = @_;
    my $dir = dirname($path);
    make_path($dir) unless -d $dir;
    my ($fh, $tmp) = File::Temp::tempfile('.registry-XXXXXXXX', DIR => $dir, UNLINK => 0);
    binmode $fh;
    print {$fh} $bytes;
    close $fh or do { my $e = $!; unlink $tmp; die "cannot write $tmp: $e\n" };
    chmod 0644 & ~umask, $tmp;
    rename $tmp, $path or do { my $e = $!; unlink $tmp; die "cannot rename $tmp -> $path: $e\n" };
    return 1;
}

1;
