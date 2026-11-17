package PodmanMachine;
# PodmanMachine.pm -- The macOS podman machine: what it shares and how, the
# machine-local list that says so, and the plan/apply that recreates it to
# match. podman-machine.pl is its command line.
#
# WHY THIS EXISTS. `podman machine init` with no arguments creates a ROOTLESS
# VM that shares /Users, /private, /var/folders and ~/.config/containers (at
# /etc/containers) READ-WRITE. Containers see only what the launcher mounts,
# but a process that escaped a container into that VM could read and write
# the whole home folder, and plant code in folders whose scripts later run on
# the Mac (~/.config/containers itself holds the machine's own config). The
# operator decided (2026-10-30) that the machine is ROOTFUL and shares only
# what the sandbox mounts, and that machinery keeps it that way: a doc telling
# the operator which init flags to type is how a hand-made machine drifts.
#
# THE DESIRED MACHINE
#   rootful    container root is root in the VM. Image builds can create device
#              nodes (the bp-jail skeleton gets real /dev nodes); the VM, not a
#              user namespace, is the boundary.
#   resources  CPUs, memory and disk of the current machine, unless given
#              (--cpus 6 --memory 12288 for a new one; disk is podman's 100).
#   shares     each mounted at its own path in the VM, because podman hands a
#              bind source to the VM as written:
#     ro  the live-install mirror (~/.cache/ccpraxis/live-mirror, LiveMirror.pm):
#         a copy of the live install's plugins/ marketplace (backpack scripts
#         included), skills/ and scripts/statusline.pl, which the launcher
#         binds read-only. Refreshed by promote.pl and before each container
#         create and start. NEVER the live install itself: "ro" is not enforced
#         here (below), and the Mac runs the live install's hooks and scripts;
#     ro  container-files (~/.cache/ccpraxis/container-files): host files a
#         container reads; today a copy of ~/.claude/almanac-global-counts.json,
#         which the launcher refreshes. ~/.claude itself is never shared;
#     rw  container-test-scratch (~/.cache/ccpraxis/container-test-scratch):
#         fixtures for ccpraxis's own container tests (TestSandbox), nothing
#         else; on by default because those tests cannot run without it,
#         `test-scratch off` drops it;
#     rw  every project directory in the list (add-project / remove-project);
#         the list starts empty.
#     ro  any other directory-source marketplace in known_marketplaces.json,
#         which the launcher binds too (none on a usual machine).
#   Nothing else: not /Users, /private, /var/folders or ~/.config/containers.
#   The VM has its own /etc/containers; the host copy was a convenience
#   (podman 6.0 release notes: "allowing users to edit the config files").
#
# READ-ONLY IS RECORDED, NOT ENFORCED, ON APPLEHV. Measured from the shipped
# binaries and source (podman 6.1.4, vfkit 0.6.4): `-v SRC:DST:ro` is parsed
# and stored as Mounts[].ReadOnly, but vfkit's virtio-fs device has no
# read-only option and the VM's .mount unit carries no `ro`. Inside the VM an
# "ro" share is writable. A container's own `:ro` bind IS enforced by podman.
# The plan says so; the mode is still recorded, so the launcher refuses a
# read-write bind through a read-only share and a future provider enforces it.
#
# WHERE THE LIST LIVES: ~/.claude/ccpraxis-podman-machine.json. ~/.claude is
# the host's ccpraxis config home, never shared with the VM (it holds
# transcripts and the vault), not a repository, and not exported by backup. A
# list inside any share would let the VM add shares to the next apply.
#
# darwin only. Windows keeps its WSL machine, which reaches every drive
# through /mnt; Linux runs containers natively. Every podman call goes through
# a seam (run / stream), so the tests drive plan and apply without a runtime.
use strict;
use warnings;
use Cwd ();
use Encode ();
use File::Basename qw(dirname);
use File::Spec ();
use File::Path ();
use JSON::PP ();
use POSIX ();
use HostPlatform ();
use LiveMirror ();
use SandboxIdentity ();

our $DEFAULT_MACHINE = 'podman-machine-default';
our %NEW_MACHINE     = (cpus => 6, memory => 12288, disk => 100);
our $STATE_SCHEMA    = 1;

# Top-level directories of the VM a share must not be mounted over or under
# (podman refuses the exact paths; anything below them is the VM's own OS).
our @VM_RESERVED = qw(bin boot dev etc home lib lib64 media mnt opt proc root
                      run sbin srv sys sysroot ostree tmp usr var);

# ---------------------------------------------------------------------------
# Layout: every path this module and its callers derive, from one home.
# ---------------------------------------------------------------------------

# layout(home => $h) -> { home, state_file, install_root, cache_dir,
#                         container_files, test_scratch, live_mirror }
# live_mirror is the live install's mirror; another install root has its own
# (LiveMirror::mirror_dir).
sub layout {
    my (%o) = @_;
    my $home = $o{home};
    die "PodmanMachine::layout: no home directory\n" unless defined $home && length $home;
    $home =~ s{/+\z}{} unless $home eq '/';
    my $cache = "$home/.cache/ccpraxis";
    return {
        home            => $home,
        state_file      => "$home/.claude/ccpraxis-podman-machine.json",
        install_root    => "$home/.claude/ccpraxis",
        cache_dir       => $cache,
        container_files => "$cache/container-files",
        test_scratch    => "$cache/container-test-scratch",
        live_mirror     => LiveMirror::mirror_dir(os => 'darwin', home => $home),
    };
}

# live_mirror_for($layout, $install_root) -> the mirror the machine shares for
# that install root (the share list's install_root, or the live install).
sub live_mirror_for {
    my ($L, $install) = @_;
    return LiveMirror::mirror_dir(os => 'darwin', home => $L->{home},
                                  install_root => (defined $install ? $install : $L->{install_root}));
}

# account_home() -> the home the machine's shares were laid out under: the
# OS-recorded home (getpwuid), else $HOME. A redirected HOME (the test
# runner's per-file sandbox) does not move what the VM shares.
sub account_home {
    my $h = HostPlatform::owner_home();
    $h = $ENV{HOME} unless defined $h && length $h;
    return $h;
}

sub _darwin_dir {
    my ($key, %o) = @_;
    my $os = defined $o{os} ? $o{os} : $^O;
    return undef unless $os eq 'darwin';
    my $h = defined $o{home} ? $o{home} : account_home();
    return undef unless defined $h && length $h;
    return layout(home => $h)->{$key};
}

# container_files_dir(%o) -> the read-only share holding host files a
# container reads, or undef off darwin (there the launcher binds them where
# they are). %o: os, home.
sub container_files_dir { return _darwin_dir('container_files', @_) }

# test_scratch_dir(%o) -> the read-write share for container-test fixtures,
# or undef off darwin. %o: os, home.
sub test_scratch_dir { return _darwin_dir('test_scratch', @_) }

# ensure_share_dirs($layout, @more) -> list of problems (empty = ok). The
# dedicated shares must exist before the machine starts: vfkit refuses to start
# a VM whose shared directory is missing. @more: the live-install mirror the
# machine shares (it may be keyed by another install root), created empty here;
# the launcher fills it before any container starts.
sub ensure_share_dirs {
    my ($L, @more) = @_;
    my @err;
    for my $d ($L->{container_files}, $L->{test_scratch}, grep { defined && length } @more) {
        next if -d $d;
        eval { File::Path::make_path($d); 1 };
        push @err, "cannot create $d" unless -d $d;
    }
    return @err;
}

# missing_share_sources(\@shares) -> the shared folders that do not exist.
sub missing_share_sources {
    my ($shares) = @_;
    return () unless ref $shares eq 'ARRAY';
    return grep { defined $_ && length $_ && !-d $_ } map { ref $_ eq 'HASH' ? $_->{source} : $_ } @$shares;
}

# missing_share_remedy(\@shares) -> () when every shared folder exists, else
# the lines that explain why the machine cannot start and what fixes it.
# vfkit refuses to start a VM whose shared folder is gone, and "try podman
# machine start" cannot fix that: the folder must come back, or the share must
# go (remove-project, which recreates the machine).
sub missing_share_remedy {
    my ($shares) = @_;
    my @gone = missing_share_sources($shares);
    return () unless @gone;
    my $s = 'perl ' . HostPlatform::machine_script_path();
    return ("  The podman machine shares " . (@gone == 1 ? 'a folder that no longer exists' : 'folders that no longer exist')
                . ', and it cannot start without ' . (@gone == 1 ? 'it' : 'them') . ':',
            (map { "    $_" } @gone),
            '  Recreate ' . (@gone == 1 ? 'it' : 'them') . ', or stop sharing a project folder you removed:',
            (map { "    $s remove-project $_ --confirm" } @gone));
}

# ---------------------------------------------------------------------------
# The share list (machine-local state file)
# ---------------------------------------------------------------------------

sub default_state { return { projects => [], test_scratch => 1, install_root => undef, exists => 0 } }

# read_state($path) -> ($state, undef) | (undef, $error). An absent file is the
# default state (no projects, test scratch on). A present but unreadable or
# malformed file is an ERROR, never "empty": treating it as empty would drop
# every project share on the next apply.
sub read_state {
    my ($path) = @_;
    return (default_state(), undef) unless -e $path;
    open my $fh, '<:raw', $path or return (undef, "cannot read $path: $!");
    local $/;
    my $raw = <$fh>;
    close $fh;
    my $d = eval { JSON::PP->new->utf8->decode(defined $raw ? $raw : '') };
    return (undef, "$path is not valid JSON; fix or delete it (deleting it means: no projects shared)")
        unless ref $d eq 'HASH';
    return (undef, "$path has schema " . (defined $d->{schema} ? $d->{schema} : '(none)')
                 . "; this script reads schema $STATE_SCHEMA")
        unless defined $d->{schema} && !ref $d->{schema} && "$d->{schema}" eq "$STATE_SCHEMA";
    my $projects = defined $d->{projects} ? $d->{projects} : [];
    return (undef, "$path: projects must be a list of absolute paths")
        unless ref $projects eq 'ARRAY' && !grep { !defined $_ || ref $_ || $_ !~ m{\A/} } @$projects;
    my $ts = exists $d->{test_scratch} ? $d->{test_scratch} : 1;
    $ts = JSON::PP::is_bool($ts) ? ($ts ? 1 : 0) : (defined $ts && !ref $ts && $ts =~ /\A[01]\z/ ? 0 + $ts : undef);
    return (undef, "$path: test_scratch must be true or false") unless defined $ts;
    my $ir = $d->{install_root};
    return (undef, "$path: install_root must be an absolute path")
        if defined $ir && (ref $ir || $ir !~ m{\A/});
    my @p = map { my $x = $_; $x =~ s{/+\z}{}; $x } @$projects;
    return ({ projects => \@p, test_scratch => $ts, install_root => $ir, exists => 1 }, undef);
}

# write_state($path, $state) -> (1, undef) | (0, $error). Atomic: temp file in
# the same directory, then rename.
sub write_state {
    my ($path, $st) = @_;
    my %doc = (
        schema       => $STATE_SCHEMA,
        projects     => [ @{ $st->{projects} || [] } ],
        test_scratch => ($st->{test_scratch} ? JSON::PP::true() : JSON::PP::false()),
    );
    $doc{install_root} = $st->{install_root} if defined $st->{install_root};
    my $dir = dirname($path);
    eval { File::Path::make_path($dir) unless -d $dir; 1 };
    return (0, "cannot create $dir") unless -d $dir;
    my $tmp = "$path.tmp.$$";
    open my $fh, '>:raw', $tmp or return (0, "cannot write $tmp: $!");
    my $ok = print {$fh} JSON::PP->new->utf8->canonical->pretty->encode(\%doc);
    $ok = close($fh) && $ok;
    unless ($ok && rename($tmp, $path)) {
        my $e = $!;
        unlink $tmp;
        return (0, "cannot write $path: $e");
    }
    return (1, undef);
}

# ---------------------------------------------------------------------------
# Project directories
# ---------------------------------------------------------------------------

# _fold($path, $os) -> the spelling APFS treats as equal: case-folded on darwin
# (as characters, so a non-ASCII letter folds too), unchanged elsewhere.
sub _fold {
    my ($p, $os) = @_;
    return $p unless $os eq 'darwin' && defined $p;
    my $copy = $p;
    my $chars = eval { Encode::decode('UTF-8', $copy, Encode::FB_CROAK()) };
    return lc $p unless defined $chars;
    return Encode::encode('UTF-8', lc $chars);
}
sub _under { my ($p, $d) = @_; return $d eq '/' || $p eq $d || index($p, "$d/") == 0 }
sub _overlap {
    my ($x, $y, $os) = @_;
    ($x, $y) = (_fold($x, $os), _fold($y, $os));
    return _under($x, $y) || _under($y, $x);
}

# canonical_project($dir, %o) -> ($path, undef) | (undef, $error). The spelling
# the launcher will bind: symlinks resolved (abs_path; /tmp becomes
# /private/tmp) and the case APFS stores (HostPlatform::canonical_dir).
sub canonical_project {
    my ($dir, %o) = @_;
    my $os = defined $o{os} ? $o{os} : $^O;
    return (undef, 'no directory given') unless defined $dir && length $dir;
    return (undef, "$dir is not a directory") unless -d $dir;
    my $abs = Cwd::abs_path($dir);
    return (undef, "cannot resolve $dir") unless defined $abs && length $abs;
    $abs = HostPlatform::canonical_dir($abs, os => $os);
    $abs =~ s{/+\z}{} unless $abs eq '/';
    return ($abs, undef);
}

# Folders that hold keys, or podman's own machine config and disk (whose
# contents run on the Mac at the next `podman machine start`): never shared.
sub _sensitive_dirs {
    my ($L) = @_;
    my $h = $L->{home};
    return ("$h/.ssh", "$h/.gnupg", "$h/.config/containers", "$h/.local/share/containers", "$h/Library");
}

# _shape_problem($path, $layout, $os) -> undef | why no share may have this
# path at all.
sub _shape_problem {
    my ($p, $L, $os) = @_;
    return "a ':' in the path cannot be passed to `podman machine init --volume`" if $p =~ /:/;
    return "a ',' in the path would break vfkit's virtio-fs device options and the launcher's --mount spec"
        if $p =~ /,/;
    return 'the path contains a control character' if $p =~ /[\x00-\x1f\x7f]/;
    my @parts = grep { length } split m{/}, $p;
    return 'sharing a top-level folder would hand the VM everything under it' if @parts < 2;
    return "/$parts[0] is the VM's own system directory there; a share cannot be mounted at that path"
        if grep { lc($parts[0]) eq $_ } @VM_RESERVED;
    return 'it contains your home folder' if _under(_fold($L->{home}, $os), _fold($p, $os));
    for my $s (_sensitive_dirs($L)) {
        return "it overlaps $s, which holds keys or podman's own machine files" if _overlap($p, $s, $os);
    }
    return "it overlaps ccpraxis's own share folders ($L->{cache_dir})" if _overlap($p, $L->{cache_dir}, $os);
    return undef;
}

# project_problem($path, $layout, %o) -> undef | why this directory must not
# be shared read-write with the VM. $path is canonical. %o: os, install_root.
sub project_problem {
    my ($p, $L, %o) = @_;
    my $os = defined $o{os} ? $o{os} : $^O;
    my $install = defined $o{install_root} ? $o{install_root} : $L->{install_root};
    my $why = _shape_problem($p, $L, $os);
    return $why if defined $why;
    return '~/.claude holds transcripts, credentials, the vault and this share list; it is never shared'
        if _overlap($p, "$L->{home}/.claude", $os);
    return "it overlaps the live install ($install), whose hooks and scripts run on the Mac; the VM gets a copy of it instead"
        if _overlap($p, $install, $os);
    return undef;
}

# install_root_problem($path, $layout, %o) -> undef | why the share list's
# install_root must not be shared. Inside ~/.claude is expected (the default
# is ~/.claude/ccpraxis); ~/.claude itself, or anything containing it, is not.
sub install_root_problem {
    my ($p, $L, %o) = @_;
    my $os = defined $o{os} ? $o{os} : $^O;
    my $why = _shape_problem($p, $L, $os);
    return $why if defined $why;
    return 'it contains ~/.claude (transcripts, credentials, the vault, this share list)'
        if _under(_fold("$L->{home}/.claude", $os), _fold($p, $os));
    return undef;
}

# state_problems($state, $layout, %o) -> list of "path: why" for entries a
# hand-edited share list must not hold. Checked before every plan, so an edit
# cannot share the home folder by the back door.
sub state_problems {
    my ($st, $L, %o) = @_;
    my @bad;
    if (defined $st->{install_root}) {
        my $why = install_root_problem($st->{install_root}, $L, %o);
        push @bad, "install_root $st->{install_root}: $why" if defined $why;
    }
    for my $p (@{ $st->{projects} || [] }) {
        my $why = project_problem($p, $L, %o, install_root => $st->{install_root});
        push @bad, "$p: $why" if defined $why;
    }
    return @bad;
}

# directory_marketplaces($layout, $install, %o) -> ( { source, problem } ... ):
# every directory-source marketplace in ~/.claude/plugins/known_marketplaces.json
# whose folder the launcher would bind read-only, except ccpraxis-local, which
# the launcher serves from the install's own plugins/ (SandboxIdentity::
# directory_marketplace_source), and any inside the part of the install the
# live-install mirror copies (the launcher binds those from the mirror).
# `problem` says why one must not be shared; such a marketplace makes every
# launch refuse at create for as long as it stays registered.
sub directory_marketplaces {
    my ($L, $install, %o) = @_;
    my $os = defined $o{os} ? $o{os} : $^O;
    my $raw = _slurp_file("$L->{home}/.claude/plugins/known_marketplaces.json");
    return () unless defined $raw;
    my $d = eval { JSON::PP::decode_json($raw) };
    return () unless ref $d eq 'HASH';
    my @out;
    for my $name (sort keys %$d) {
        next if $name eq 'ccpraxis-local';
        my $src = ref $d->{$name} eq 'HASH' ? $d->{$name}{source} : undef;
        next unless ref $src eq 'HASH' && ($src->{source} // '') eq 'directory';
        my $p = $src->{path};
        next unless defined $p && !ref $p && length $p;
        $p = Encode::encode('UTF-8', $p) if utf8::is_utf8($p);
        $p =~ s{\\}{/}g;
        $p =~ s{/+\z}{} unless $p eq '/';
        next unless $p =~ m{\A/} && -d $p;
        next if grep { _under(_fold($p, $os), _fold("$install/$_", $os)) } @LiveMirror::PATHS;
        my $why = _shape_problem($p, $L, $os);
        $why = "it is inside the live install ($install), which is never shared, and outside the part its mirror copies"
            if !defined $why && _under(_fold($p, $os), _fold($install, $os));
        $why = 'it is inside ~/.claude, which is never shared'
            if !defined $why && _overlap($p, "$L->{home}/.claude", $os);
        push @out, { source => $p, name => $name, problem => $why };
    }
    return @out;
}

# ---------------------------------------------------------------------------
# Current and desired machine
# ---------------------------------------------------------------------------

sub _run_ok { my ($r) = @_; return ref $r eq 'HASH' && defined $r->{rc} && $r->{rc} == 0 }
sub _one_line {
    my ($s) = @_;
    $s = '' unless defined $s;
    $s =~ s/\s+/ /g;
    $s =~ s/\A\s+|\s+\z//g;
    return length $s ? $s : '(no output)';
}

# current_machine(%env) -> ($machine, undef) | (undef, $error).
# $machine is { exists => 0 } when podman has no machine, else
#   { exists => 1, name, vm_type, state, rootful, cpus, memory, disk,
#     shares => [ {source,target,readonly} ], config_file }
# %env: podman, run, read_file.
sub current_machine {
    my (%e) = @_;
    my $pod = $e{podman};
    my $l = $e{run}->([$pod, 'machine', 'list', '--format', 'json']);
    return (undef, "`$pod machine list` failed: " . _one_line($l->{err} || $l->{out})) unless _run_ok($l);
    my $list = eval { JSON::PP->new->decode($l->{out}) };
    return (undef, "`$pod machine list` printed something that is not a JSON list") unless ref $list eq 'ARRAY';
    my @m = grep { ref $_ eq 'HASH' } @$list;
    return ({ exists => 0 }, undef) unless @m;
    my ($pick) = grep { HostPlatform::boolish($_->{Default}) } @m;
    $pick = $m[0] unless $pick;
    my $name = $pick->{Name};
    return (undef, "`$pod machine list` names no machine") unless defined $name && !ref $name && length $name;
    $name =~ s/\*\z//;

    my $i = $e{run}->([$pod, 'machine', 'inspect', $name]);
    return (undef, "`$pod machine inspect $name` failed: " . _one_line($i->{err} || $i->{out})) unless _run_ok($i);
    my $info = HostPlatform::parse_machine_inspect($i->{out});
    return (undef, "`$pod machine inspect $name` printed something unreadable") unless $info;
    my $cfg_file = (defined $info->{config_dir} && length $info->{config_dir})
        ? "$info->{config_dir}/$info->{name}.json" : undef;
    my $cfg = defined $cfg_file ? HostPlatform::parse_machine_config_details(scalar $e{read_file}->($cfg_file)) : undef;
    my $shares = (ref $info->{mounts} eq 'ARRAY' && @{ $info->{mounts} }) ? $info->{mounts}
               : ($cfg && ref $cfg->{mounts} eq 'ARRAY') ? $cfg->{mounts} : undef;
    return (undef, "cannot read the share list of machine $name"
                 . (defined $cfg_file ? " from $cfg_file" : '')) unless $shares;
    my %res = (%{ ($cfg && $cfg->{resources}) || {} }, %{ $info->{resources} || {} });
    my $rootful = defined $info->{rootful} ? $info->{rootful} : ($cfg ? $cfg->{rootful} : undef);
    my $state = $info->{state};
    unless (defined $state) {
        my $run = HostPlatform::boolish($pick->{Running});
        $state = defined $run ? ($run ? 'running' : 'stopped') : 'unknown';
    }
    return ({
        exists      => 1,
        name        => $info->{name},
        vm_type     => (defined $pick->{VMType} && !ref $pick->{VMType}) ? $pick->{VMType} : undef,
        state       => $state,
        rootful     => $rootful ? 1 : 0,
        cpus        => $res{cpus},
        memory      => $res{memory},
        disk        => $res{disk},
        shares      => $shares,
        config_file => $cfg_file,
    }, undef);
}

my %WHY = (
    'live-mirror'   => "a copy of the live install's plugins, skills and statusline, refreshed by promote and by each launch; the Mac never runs anything from it",
    'container-files' => 'host files a container reads: the copy of almanac-global-counts.json the launcher refreshes (~/.claude itself is never shared)',
    'test-scratch'  => "fixtures for ccpraxis's container tests, nothing else (drop it with: test-scratch off)",
    project         => 'a project directory, mounted read-write at /project (add-project / remove-project)',
    marketplace     => 'a directory-source plugin marketplace registered on the Mac, bound read-only into every sandbox',
);
sub why_text { my ($role) = @_; return $WHY{$role} // '' }

# desired_machine(%o) -> { name, rootful, cpus, memory, disk, install_root,
#                          shares => [ {source,target,readonly,role} ] }
# %o: layout, state, current, overrides => { cpus, memory, disk },
#     marketplaces => [ { source, problem } ] (directory_marketplaces).
sub desired_machine {
    my (%o) = @_;
    my ($L, $st, $cur) = @o{qw(layout state current)};
    my $ov = $o{overrides} || {};
    my $have = $cur && $cur->{exists};
    my $install = defined $st->{install_root} ? $st->{install_root} : $L->{install_root};
    my $share = sub { my ($src, $ro, $role) = @_; return { source => $src, target => $src, readonly => $ro, role => $role } };
    my @shares = (
        $share->(live_mirror_for($L, $install), 1, 'live-mirror'),
        $share->($L->{container_files}, 1, 'container-files'),
        ($st->{test_scratch} ? $share->($L->{test_scratch}, 0, 'test-scratch') : ()),
        (map { $share->($_->{source}, 1, 'marketplace') } grep { !defined $_->{problem} } @{ $o{marketplaces} || [] }),
        (map { $share->($_, 0, 'project') } @{ $st->{projects} || [] }),
    );
    my $pick = sub {
        my ($k) = @_;
        return $ov->{$k} if defined $ov->{$k};
        return $cur->{$k} if $have && defined $cur->{$k};
        return $NEW_MACHINE{$k};
    };
    return {
        name         => ($have ? $cur->{name} : $DEFAULT_MACHINE),
        rootful      => 1,
        cpus         => $pick->('cpus'),
        memory       => $pick->('memory'),
        disk         => $pick->('disk'),
        install_root => $install,
        shares       => \@shares,
    };
}

# ---------------------------------------------------------------------------
# Plan
# ---------------------------------------------------------------------------

# compute_plan(%o) -> { action => none|set|recreate|create, current, desired,
#   rootful_change, resource_changes => [ [key, from, to] ], set_args => [...],
#   shares => [ { op => keep|add|remove|mode, ...share..., from_readonly } ],
#   missing => [ { source, role } ] }
# %o: current, desired. Shares are matched by their exact host path: the VM
# is case-sensitive, so /Users/u/App and /Users/u/app are different mounts
# there even though APFS calls them one folder.
sub compute_plan {
    my (%o) = @_;
    my ($cur, $want) = @o{qw(current desired)};
    my %p = (current => $cur, desired => $want, resource_changes => [], set_args => [], shares => [], missing => []);

    # The live install is not shared, but its mirror is filled from it: without
    # it there is nothing for a sandbox to mount.
    my $inst = $want->{install_root};
    push @{ $p{missing} }, { source => $inst, role => 'install' } if defined $inst && !-d $inst;
    for my $s (@{ $want->{shares} }) {
        push @{ $p{missing} }, { source => $s->{source}, role => $s->{role} } unless -d $s->{source};
    }
    # A live install from before the mirror still binds the live install itself
    # (and, older still, ~/.claude/almanac-global-counts.json and test fixtures
    # under /private/tmp); against this machine every launch from it would be
    # refused.
    $p{stale_install} = (defined $inst && -d $inst && !-f "$inst/plugins/sandbox/scripts/LiveMirror.pm") ? 1 : 0;

    unless ($cur && $cur->{exists}) {
        $p{action} = 'create';
        push @{ $p{shares} }, map { { %$_, op => 'add' } } @{ $want->{shares} };
        return \%p;
    }

    my $recreate = 0;
    $p{rootful_change} = ($cur->{rootful} ? 1 : 0) != ($want->{rootful} ? 1 : 0) ? 1 : 0;
    $recreate = 1 if $p{rootful_change};

    my %cur_by = map { ($_->{source} => $_) } @{ $cur->{shares} };
    my %want_seen;
    for my $s (@{ $want->{shares} }) {
        my $k = $s->{source};
        $want_seen{$k} = 1;
        my $c = $cur_by{$k};
        if (!$c) {
            push @{ $p{shares} }, { %$s, op => 'add' };
            $recreate = 1;
        } elsif ($c->{target} ne $s->{target}) {
            push @{ $p{shares} }, { %$c, op => 'remove' }, { %$s, op => 'add' };
            $recreate = 1;
        } elsif (($c->{readonly} ? 1 : 0) != ($s->{readonly} ? 1 : 0)) {
            push @{ $p{shares} }, { %$s, op => 'mode', from_readonly => ($c->{readonly} ? 1 : 0) };
            $recreate = 1;
        } else {
            push @{ $p{shares} }, { %$s, op => 'keep' };
        }
    }
    for my $c (@{ $cur->{shares} }) {
        next if $want_seen{ $c->{source} };
        push @{ $p{shares} }, { %$c, op => 'remove' };
        $recreate = 1;
    }

    for my $k (qw(cpus memory disk)) {
        my ($from, $to) = ($cur->{$k}, $want->{$k});
        next if defined $from && defined $to && $from == $to;
        next unless defined $to;
        push @{ $p{resource_changes} }, [$k, $from, $to];
        # podman machine set grows a disk; it cannot shrink one.
        $recreate = 1 if $k eq 'disk' && defined $from && $to < $from;
        push @{ $p{set_args} }, ($k eq 'cpus' ? '--cpus' : $k eq 'memory' ? '--memory' : '--disk-size'), $to;
    }

    $p{action} = $recreate ? 'recreate' : @{ $p{resource_changes} } ? 'set' : 'none';
    return \%p;
}

my %LABEL = (cpus => 'cpus', memory => 'memory (MiB)', disk => 'disk (GiB)');

# render_plan($plan, %o) -> lines. %o: state_file, state_exists, marketplaces,
# pending (leftover image archives), home, account_home.
sub render_plan {
    my ($p, %o) = @_;
    my ($cur, $want) = @{$p}{qw(current desired)};
    my @l;
    if ($cur && $cur->{exists}) {
        push @l, sprintf('podman machine: %s (%s, %s)', $cur->{name},
            defined $cur->{vm_type} ? $cur->{vm_type} : 'unknown provider', $cur->{state});
        push @l, "  config:     $cur->{config_file}" if defined $cur->{config_file};
    } else {
        push @l, "podman machine: none yet; apply creates $want->{name}";
    }
    push @l, "  share list: $o{state_file}" . ($o{state_exists} ? '' : ' (not written yet: defaults)')
        if defined $o{state_file};
    push @l, '';
    my $yn = sub { my ($v) = @_; return !defined $v ? '?' : $v ? 'yes' : 'no' };
    my $v  = sub { my ($x) = @_; return defined $x ? $x : '?' };
    my $have = $cur && $cur->{exists};
    push @l, sprintf('  %-14s %-12s %s', '', 'current', 'desired');
    push @l, sprintf('  %-14s %-12s %s', 'rootful', $have ? $yn->($cur->{rootful}) : '-', $yn->($want->{rootful}));
    for my $k (qw(cpus memory disk)) {
        push @l, sprintf('  %-14s %-12s %s', $LABEL{$k}, $have ? $v->($cur->{$k}) : '-', $v->($want->{$k}));
    }
    push @l, '';
    push @l, 'Shares (host folder; mounted at the same path inside the VM unless shown):';
    my %opname = (keep => 'keep', add => 'add', remove => 'remove', mode => 'change');
    for my $s (@{ $p->{shares} }) {
        my $mode = $s->{readonly} ? 'ro' : 'rw';
        $mode = ($s->{from_readonly} ? 'ro' : 'rw') . "->$mode" if $s->{op} eq 'mode';
        my $t = (defined $s->{target} && $s->{target} ne $s->{source}) ? " -> $s->{target}" : '';
        push @l, sprintf('  %-7s %-6s %s%s', $opname{ $s->{op} }, $mode, $s->{source}, $t);
        push @l, '                 ' . why_text($s->{role}) if $s->{role} && $s->{op} ne 'remove';
    }
    unless (grep { ($_->{role} // '') eq 'project' && $_->{op} ne 'remove' } @{ $p->{shares} }) {
        push @l, '  (no project directory is shared; sandbox launches are refused until one is: add-project <dir>)';
    }
    if (grep { $_->{readonly} && $_->{op} ne 'remove' } @{ $p->{shares} }) {
        push @l, '',
            'Note: "ro" is recorded, not enforced, on this provider. podman 6.1.4 on applehv stores the flag but vfkit 0.6.4 has no read-only virtio-fs share and the VM mounts it read-write, so a process that escaped into the VM could write an "ro" folder. Containers still get read-only binds.';
    }
    if ($p->{stale_install}) {
        push @l, '', "The live install ($want->{install_root}) predates the live-install mirror: its launcher binds the live install itself, which this machine does not share, so every launch from it would be refused. Promote first (perl scripts/promote.pl in the dev clone); apply refuses until then.";
    }
    push @l, '', 'Missing on disk:' if @{ $p->{missing} };
    for my $m (@{ $p->{missing} }) {
        my $fix = ($m->{role} eq 'container-files' || $m->{role} eq 'test-scratch') ? 'apply creates it'
                : $m->{role} eq 'live-mirror' ? 'apply creates it; promote and each launch fill it'
                : $m->{role} eq 'install' ? 'promote first (perl scripts/promote.pl in the dev clone); apply refuses until it exists'
                : 'remove-project it, or recreate the directory; apply refuses until then';
        push @l, "  $m->{source} ($fix)";
    }
    my @bad_mkt = grep { defined $_->{problem} } @{ $o{marketplaces} || [] };
    if (@bad_mkt) {
        push @l, '', 'Not shared, so every launch is refused while it stays registered:',
                 map { "  $_->{source} (marketplace $_->{name}): $_->{problem}" } @bad_mkt;
    }
    if (ref $o{pending} eq 'ARRAY' && @{ $o{pending} }) {
        push @l, '', 'Images saved by an earlier apply that did not finish (apply --confirm loads them):',
                 map { "  $_" } @{ $o{pending} };
    }
    if (defined $o{account_home} && defined $o{home} && $o{account_home} ne $o{home}) {
        push @l, '', "Note: HOME ($o{home}) is not your account's home ($o{account_home}); the launcher",
                 '  and the tests lay their folders out under the account home, so shares planned here would miss them.';
    }
    push @l, '';
    return @l;
}

# cost_lines($plan) -> what apply --confirm will do and what it costs.
sub cost_lines {
    my ($p, %o) = @_;
    my $cur = $p->{current};
    my $act = $p->{action};
    return ('The machine already matches; nothing to do.') if $act eq 'none';
    if ($act eq 'set') {
        return ('apply will change resources in place (podman machine set), keeping every container and image:',
                '  ' . join(', ', map { "$LABEL{$_->[0]} " . (defined $_->[1] ? $_->[1] : '?') . " -> $_->[2]" } @{ $p->{resource_changes} }),
                '  The machine is stopped for the change and started again if it was running.');
    }
    if ($act eq 'create') {
        return ('apply will CREATE the machine:',
                '  podman downloads the machine OS image first (about 1 GB) unless it has it cached.',
                '  apply starts it once to check that podman talks to the rootful service, then stops it;',
                '  claude-sandbox starts it when it is needed.');
    }
    my @l = ('apply will RECREATE the machine (podman machine rm, then init):',
             '  - every container in the VM is deleted. Sandbox containers are recreated by the next launch;',
             '    each project\'s claude-home (sessions, settings, credentials) lives on the Mac and is kept.',
             "  - $SandboxIdentity::ID* images are kept: saved with podman save before the rm and loaded into the new machine, which starts with empty storage.",
             '    Other images (e.g. the test probe image) are not kept; they are pulled again when needed.',
             '  - podman downloads the machine OS image again (about 1 GB) unless it has it cached.');
    if ($cur && !$cur->{rootful}) {
        push @l, '  - the kept images were built on this rootless machine, so their bp-jail skeleton has no device nodes (/opt/bp-jail-skel/dev/.no-device-nodes); the first image build on the rootful machine bakes them (take claude-sandbox\'s rebuild offer, or podman rmi the image).';
    }
    if (ref $o{images} eq 'ARRAY') {
        push @l, @{ $o{images} } ? '  - images to keep: ' . join(', ', @{ $o{images} }) : '  - no images to keep.';
    } elsif ($cur && ($cur->{state} // '') ne 'running') {
        push @l, '  - the machine is stopped, so apply starts it to list and save the images.';
    }
    my @foreign = ref $o{containers} eq 'ARRAY' ? grep { !is_sandbox_container($_) } @{ $o{containers} } : ();
    my @vols    = ref $o{volumes} eq 'ARRAY' ? @{ $o{volumes} } : ();
    if (ref $o{containers} eq 'ARRAY' && @{ $o{containers} }) {
        push @l, '  - containers that will be deleted: ' . join(', ', @{ $o{containers} });
    }
    if (@foreign || @vols) {
        push @l, '  - apply refuses until you remove what the sandbox does not recreate: '
                 . join(', ', (map { "container $_" } @foreign), (map { "volume $_" } @vols));
    }
    push @l, '  - apply refuses while any container is running, and before deleting a container or volume',
             '    the sandbox does not recreate itself (it lists them once the machine runs).';
    push @l, '  - the machine is left ' . (($cur && ($cur->{state} // '') eq 'running') ? 'running' : 'stopped') . ', as it was.';
    return @l;
}

# ---------------------------------------------------------------------------
# Images and containers (machine must be running)
# ---------------------------------------------------------------------------

# keep_image_names($images_json) -> sorted names worth carrying across a
# recreate: every tag of every image whose repository is the sandbox's own
# (SandboxIdentity's ID, any `localhost/` prefix), e.g. claude-sandbox:latest
# and claude-sandbox:<claude version>.
sub keep_image_names {
    my ($raw) = @_;
    my $d = eval { JSON::PP->new->decode(defined $raw ? $raw : '') };
    return () unless ref $d eq 'ARRAY';
    my $id = $SandboxIdentity::ID;
    my %n;
    for my $img (@$d) {
        next unless ref $img eq 'HASH' && ref $img->{Names} eq 'ARRAY';
        for my $name (@{ $img->{Names} }) {
            next unless defined $name && !ref $name;
            $n{$name} = 1 if $name =~ m{\A(?:localhost/)?\Q$id\E[^/:]*:[^/:]+\z};
        }
    }
    return sort keys %n;
}

# container_names($ps_json) -> one display name per container.
sub container_names {
    my ($raw) = @_;
    my $d = eval { JSON::PP->new->decode(defined $raw ? $raw : '') };
    return () unless ref $d eq 'ARRAY';
    my @n;
    for my $c (@$d) {
        next unless ref $c eq 'HASH';
        my $names = $c->{Names};
        my $n = ref $names eq 'ARRAY' ? join(',', grep { defined } @$names)
              : (defined $names && !ref $names) ? $names
              : (defined $c->{Id} && !ref $c->{Id}) ? substr($c->{Id}, 0, 12) : '?';
        push @n, $n;
    }
    return @n;
}

# init_args($desired) -> the `podman machine init` argv after `podman`.
sub init_args {
    my ($want) = @_;
    my @shares = @{ $want->{shares} || [] };
    # An init with no --volume gets podman's DEFAULT list (/Users, /private,
    # /var/folders, ~/.config/containers): exactly what this exists to stop.
    die "PodmanMachine::init_args: refusing an init with no shares (podman would share its defaults)\n"
        unless @shares;
    my @a = ('machine', 'init', '--rootful',
             '--cpus', $want->{cpus}, '--memory', $want->{memory}, '--disk-size', $want->{disk});
    push @a, '--volume', "$_->{source}:$_->{target}" . ($_->{readonly} ? ':ro' : '') for @shares;
    push @a, $want->{name};
    return @a;
}

# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------

sub _archive_dir   { my ($L) = @_; return $L->{cache_dir} }

# pending_archives($layout) -> image archives a finished save left behind
# (an apply that died after `podman save`). A save writes <name>.tar.partial
# and renames it only once podman save succeeded, so a killed save never
# looks like a pending archive.
sub pending_archives {
    my ($L) = @_;
    my $d = _archive_dir($L);
    opendir(my $dh, $d) or return ();
    my @a = sort map { "$d/$_" } grep { /\Apodman-machine-images-[0-9T]+\.tar\z/ } readdir $dh;
    closedir $dh;
    return grep { -f $_ } @a;
}

# is_sandbox_container($name) -> 1 when the sandbox recreates this container by
# itself: a launcher container (SandboxIdentity's <prefix>-<project>-<hash8>),
# a container-test probe, or a container-lane run. Anything else is the
# operator's, and a recreate would delete it.
sub is_sandbox_container {
    my ($n) = @_;
    return 0 unless defined $n && length $n;
    return 1 if $n =~ /\Aclaude-sandbox-test-/ || $n =~ /\Accpraxis-container-lane-/;
    return SandboxIdentity::is_sandbox_container_name($n) ? 1 : 0;
}

# volume_names($volume_ls_json) -> names of podman volumes.
sub volume_names {
    my ($raw) = @_;
    my $d = eval { JSON::PP->new->decode(defined $raw ? $raw : '') };
    return () unless ref $d eq 'ARRAY';
    return map { (ref $_ eq 'HASH' && defined $_->{Name} && !ref $_->{Name}) ? $_->{Name} : () } @$d;
}

# other_image_names($images_json) -> tagged images a recreate does NOT keep.
sub other_image_names {
    my ($raw) = @_;
    my %keep = map { $_ => 1 } keep_image_names($raw);
    my $d = eval { JSON::PP->new->decode(defined $raw ? $raw : '') };
    return () unless ref $d eq 'ARRAY';
    my %n;
    for my $img (@$d) {
        next unless ref $img eq 'HASH' && ref $img->{Names} eq 'ARRAY';
        $n{$_} = 1 for grep { defined && !ref && !$keep{$_} } @{ $img->{Names} };
    }
    return sort keys %n;
}

# dedicated_missing($plan) -> the missing share folders that are ccpraxis's own
# (container-files, test-scratch, the live-install mirror): apply creates them.
sub dedicated_missing {
    my ($p) = @_;
    return grep { my $r = $_->{role} // ''; $r eq 'container-files' || $r eq 'test-scratch' || $r eq 'live-mirror' }
           @{ $p->{missing} || [] };
}

# apply(%o) -> exit code. %o: env (podman, run, stream, out, now), layout,
# plan, confirm, images, containers. Prints the plan's cost, refuses what it
# must, and with confirm executes the plan.
sub apply {
    my (%o) = @_;
    my ($e, $L, $p) = @o{qw(env layout plan)};
    my $out = $e->{out};
    my $pod = $e->{podman};
    my $cur = $p->{current};
    my $want = $p->{desired};
    my $act = $p->{action};
    my @pending = pending_archives($L);

    # ccpraxis's own share folders (cleanup tools empty ~/.cache) are created
    # even when the machine itself matches: vfkit will not start it without them.
    my @absent = dedicated_missing($p);
    if ($act eq 'none' && !@pending) {
        unless (@absent) {
            $out->('The machine already matches; nothing to do.');
            return 0;
        }
        unless ($o{confirm}) {
            $out->('The machine matches, but it cannot start without these folders it shares:',
                   (map { "  $_->{source}" } @absent),
                   '', 'Nothing has changed. To create them, run again with --confirm.');
            return 0;
        }
        my @err = ensure_share_dirs($L, map { $_->{source} } grep { $_->{role} eq 'live-mirror' } @absent);
        if (@err) { $out->("Refusing: $_") for @err; return 1 }
        $out->('The machine already matched; created the folders it shares:', map { "  $_->{source}" } @absent);
        return 0;
    }

    # Preconditions that need no machine: every share source must exist (vfkit
    # will not start a VM with a missing shared folder). The dedicated folders
    # and the mirror are created below; the project folders are the operator's,
    # and so is the live install the mirror is filled from.
    my @blocking = grep { $_->{role} eq 'install' || $_->{role} eq 'project' } @{ $p->{missing} };
    if (@blocking && $act ne 'none') {
        $out->("Refusing: these folders do not exist on disk:", map { "  $_->{source}" } @blocking);
        return 1;
    }
    if ($p->{stale_install} && $act ne 'none') {
        $out->("Refusing: the live install $want->{install_root} predates the live-install mirror; promote first.");
        return 1;
    }

    $out->(cost_lines($p, images => $o{images}, containers => $o{containers}, volumes => $o{volumes})) unless $act eq 'none';
    unless ($o{confirm}) {
        $out->('', 'Nothing has changed. To do this, run again with --confirm.');
        return 0;
    }
    $out->('');

    my @mk = ensure_share_dirs($L, map { $_->{source} } grep { $_->{role} eq 'live-mirror' } @{ $want->{shares} });
    if (@mk) { $out->("Refusing: $_") for @mk; return 1 }

    my $step = sub {
        my (@argv) = @_;
        $out->('$ ' . join(' ', map { /[\s'"]/ ? "'$_'" : $_ } $pod, @argv));
        return $e->{stream}->([$pod, @argv]);
    };
    my $query = sub {
        my ($what, @argv) = @_;
        my $r = $e->{run}->([$pod, @argv]);
        return $r if _run_ok($r);
        $out->("Refusing: cannot list $what: " . _one_line($r->{err} || $r->{out}));
        return undef;
    };
    my $have        = $cur && $cur->{exists};
    my $was_running = $have && ($cur->{state} // '') eq 'running';
    my $name        = $want->{name};
    my $started     = 0;     # this run started the machine (so stops it again)
    my $restore     = sub { $step->('machine', 'stop', $name) if $started && !$was_running; return };
    my $ensure_running = sub {
        return 1 if $was_running || $started;
        return 0 if $step->('machine', 'start', $name) != 0;
        $started = 1;
        return 1;
    };
    my $running_refusal = sub {
        my $ps = $query->('running containers', 'ps', '--format', 'json') or return 1;
        my @run = container_names($ps->{out});
        return 0 unless @run;
        $out->('Refusing: these containers are running, and changing the machine would stop them:',
               (map { "  $_" } @run),
               'Stop them first (quit their sandboxes, or podman stop <name>), then run apply --confirm again.');
        return 1;
    };

    my @archives = @pending;
    my %written;             # archives this run saved (always loaded)

    if ($act eq 'set') {
        if ($was_running) {
            return 1 if $running_refusal->();
            return _fail($out, 'podman machine stop failed; nothing was changed') if $step->('machine', 'stop', $name) != 0;
        }
        return _fail($out, 'podman machine set failed; the machine is unchanged')
            if $step->('machine', 'set', @{ $p->{set_args} }, $name) != 0;
        if ($was_running && $step->('machine', 'start', $name) != 0) {
            return _fail($out, 'podman machine start failed after the change');
        }
        $out->('The machine resources were changed in place.');
    }

    if ($act eq 'recreate') {
        return _fail($out, 'podman machine start failed; nothing was changed') unless $ensure_running->();
        if ($running_refusal->()) { $restore->(); return 1 }

        # Everything the rm deletes, now that it can be listed. Only what the
        # sandbox recreates by itself may go without the operator removing it.
        my $all = $query->('containers', 'ps', '-a', '--format', 'json') or do { $restore->(); return 1 };
        my $vol = $query->('volumes', 'volume', 'ls', '--format', 'json') or do { $restore->(); return 1 };
        my $im  = $query->('images', 'images', '--format', 'json') or do { $restore->(); return 1 };
        my @containers = container_names($all->{out});
        my @foreign = grep { !is_sandbox_container($_) } @containers;
        my @volumes = volume_names($vol->{out});
        if (@foreign || @volumes) {
            $out->('Refusing: the recreate would delete these, which the sandbox does not recreate:',
                   (map { "  container $_" } @foreign), (map { "  volume $_" } @volumes),
                   'Remove them yourself (podman rm / podman volume rm) if they can go, then run apply --confirm again.');
            $restore->();
            return 1;
        }
        $out->('Deleting with the machine: ' . (@containers ? join(', ', @containers) : 'no containers') . '.');
        my @other = other_image_names($im->{out});
        $out->('Not kept (pulled again when needed): ' . join(', ', @other) . '.') if @other;

        my @keep = keep_image_names($im->{out});
        if (@keep) {
            my $dir = _archive_dir($L);
            eval { File::Path::make_path($dir) unless -d $dir; 1 };
            my $ts = POSIX::strftime('%Y%m%dT%H%M%S', localtime($e->{now} ? $e->{now}->() : time));
            my $archive = "$dir/podman-machine-images-$ts.tar";
            my $partial = "$archive.partial";
            unlink $partial;
            my ($ok, $err) = _write_names("$archive.names", \@keep);
            unless ($ok) { $out->("Refusing: $err"); $restore->(); return 1 }
            $out->('Saving images: ' . join(', ', @keep));
            if ($step->('save', '-m', '-o', $partial, @keep) != 0 || !-s $partial || !rename($partial, $archive)) {
                unlink $partial, "$archive.names";
                $out->('Refusing: podman save failed; nothing was removed.');
                $restore->();
                return 1;
            }
            push @archives, $archive;
            $written{$archive} = 1;
        } else {
            $out->("No $SandboxIdentity::ID images to keep.");
        }
        if ($step->('machine', 'rm', '-f', $name) != 0) {
            return _fail($out, 'podman machine rm failed. The old machine may still exist; check `podman machine list`.',
                         @archives ? ('Saved images: ' . join(' ', @archives)) : ());
        }
        $started = 0;
    }

    if ($act eq 'recreate' || $act eq 'create') {
        if ($step->(init_args($want)) != 0) {
            return _fail($out, 'podman machine init failed.' . ($have ? ' The old machine is already removed.' : ''),
                         @archives ? ('Saved images are kept in ' . join(' ', @archives) . ';') : (),
                         'fix the cause and run apply --confirm again: it creates the machine and loads them.');
        }
        if ($step->('machine', 'start', $name) != 0) {
            return _fail($out, 'podman machine start failed on the new machine.',
                         @archives ? ('Saved images are kept in ' . join(' ', @archives) . '; apply --confirm loads them once it starts.') : ());
        }
        $started = 1;

        # The client must talk to THIS machine's rootful service, whatever
        # connection was the default before (another machine's, or the
        # rootless one): make it the default, then check.
        $step->('system', 'connection', 'default', "$name-root");
        my $r = $e->{run}->([$pod, 'info', '--format', '{{.Host.Security.Rootless}}']);
        my $rootless = _run_ok($r) ? _one_line($r->{out}) : 'unknown';
        $out->("WARNING: podman reports Rootless=$rootless after the switch; check `podman system connection list`.")
            if $rootless ne 'false';
    }

    my $load_failed = 0;
    if (@archives) {
        unless ($ensure_running->()) {
            return _fail($out, 'podman machine start failed; the saved images are kept in ' . join(' ', @archives));
        }
        for my $archive (@archives) {
            my @names = _read_names("$archive.names");
            unless (@names) {
                # Without the names there is nothing to verify a load against.
                $out->("WARNING: $archive.names is missing or unreadable; $archive is kept, load it by hand: podman load -i $archive");
                $load_failed = 1;
                next;
            }
            unless ($written{$archive}) {
                # Left by an earlier run. If the machine already has any of its
                # names (a launch built a fresh image meanwhile), loading it
                # would point them back at the older image.
                my @there = grep { _run_ok($e->{run}->([$pod, 'image', 'exists', $_])) } @names;
                if (@there) {
                    $out->("Not loading $archive: the machine already has @there, and loading it would replace them",
                           "  with the older images. Delete it, or load it by hand (podman load -i $archive).");
                    next;
                }
            }
            if ($step->('load', '-i', $archive) != 0) {
                $out->("WARNING: podman load failed for $archive; it is kept.");
                $load_failed = 1;
                next;
            }
            my @missing = grep { !_run_ok($e->{run}->([$pod, 'image', 'exists', $_])) } @names;
            if (@missing) {
                $out->("WARNING: after loading $archive these images are missing: @missing; the archive is kept.");
                $load_failed = 1;
                next;
            }
            unlink $archive, "$archive.names";
        }
    }

    $restore->();
    if ($act eq 'recreate' || $act eq 'create') {
        $out->('', 'Done: the machine is rootful and shares only:',
               map { "  $_" } HostPlatform::share_lines($want->{shares}));
    } elsif ($act eq 'none') {
        $out->('', 'Done with the images left by the earlier apply.') unless $load_failed;
    }
    $out->('Some images were not restored; see the warnings above.') if $load_failed;
    return $load_failed ? 1 : 0;
}

sub _fail { my ($out, @msg) = @_; $out->("ERROR: $msg[0]", map { "  $_" } @msg[1 .. $#msg]); return 1 }

sub _write_names {
    my ($path, $names) = @_;
    open my $fh, '>:raw', $path or return (0, "cannot write $path: $!");
    print {$fh} JSON::PP->new->canonical->encode($names);
    close $fh or return (0, "cannot write $path: $!");
    return (1, undef);
}

sub _read_names {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return ();
    local $/;
    my $d = eval { JSON::PP->new->decode(scalar <$fh>) };
    close $fh;
    return ref $d eq 'ARRAY' ? grep { defined && !ref } @$d : ();
}

# ---------------------------------------------------------------------------
# Real seams
# ---------------------------------------------------------------------------

# run_capture(\@argv, timeout => secs) -> { rc, out, err }. No shell; stdin is
# /dev/null; bounded by alarm (rc 124 on timeout).
sub run_capture {
    my ($argv, %o) = @_;
    my $timeout = defined $o{timeout} ? $o{timeout} : 60;
    require File::Temp;
    my $fo = File::Temp->new;
    my $fe = File::Temp->new;
    my $pid = fork;
    return { rc => 127, out => '', err => "fork failed: $!" } unless defined $pid;
    if (!$pid) {
        open STDIN, '<', '/dev/null';
        open STDOUT, '>&', $fo;
        open STDERR, '>&', $fe;
        { no warnings 'exec'; exec { $argv->[0] } @$argv; }
        print STDERR "cannot run $argv->[0]: $!\n";
        POSIX::_exit(127);
    }
    my $rc;
    my $ok = eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm $timeout;
        waitpid($pid, 0);
        alarm 0;
        1;
    };
    if ($ok) {
        $rc = ($? & 127) ? 128 + ($? & 127) : $? >> 8;
    } else {
        alarm 0;
        kill 'TERM', $pid;
        sleep 1;
        kill 'KILL', $pid;
        waitpid($pid, 0);
        $rc = 124;
    }
    my $slurp = sub {
        my ($f) = @_;
        open my $fh, '<:raw', $f->filename or return '';
        local $/;
        my $c = <$fh>;
        close $fh;
        return defined $c ? $c : '';
    };
    return { rc => $rc, out => $slurp->($fo), err => ($rc == 124 ? "timed out after ${timeout}s" : $slurp->($fe)) };
}

# run_stream(\@argv) -> exit code; the child shares this terminal, so podman's
# own progress (image download, save, load) is visible as it happens.
sub run_stream {
    my ($argv) = @_;
    my $rc = system { $argv->[0] } @$argv;
    return 127 if $rc == -1;
    return ($rc & 127) ? 128 + ($rc & 127) : $rc >> 8;
}

sub _slurp_file {
    my ($p) = @_;
    open my $fh, '<:raw', $p or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

# ---------------------------------------------------------------------------
# Command line
# ---------------------------------------------------------------------------

sub usage_lines {
    my $s = 'perl ' . HostPlatform::machine_script_path();
    return (
        "Usage: $s <command> [options]",
        '',
        'Keeps the macOS podman machine rootful and sharing only what the sandbox needs.',
        '',
        '  plan                        show the current machine next to the desired one',
        '  apply                       recreate (or create) the machine to match; prints the plan first',
        '  add-project <dir>           share a project directory read-write, then apply',
        '  remove-project <dir>        stop sharing a project directory, then apply',
        '  test-scratch on|off         share the container-test scratch folder or not, then apply',
        '',
        '  --confirm                   actually change the machine (without it nothing changes)',
        '  --cpus N  --memory MiB  --disk-size GiB',
        '                              resources for this apply (default: keep the current machine\'s;',
        "                              a new machine gets --cpus $NEW_MACHINE{cpus} --memory $NEW_MACHINE{memory})",
        '',
        'The share list is kept in ~/.claude/ccpraxis-podman-machine.json.',
        'Details: plugins/sandbox/docs/podman-machine.md',
    );
}

sub _not_darwin_lines {
    my ($os) = @_;
    return ('On Windows the sandbox uses a WSL2 podman machine, which reaches every drive through /mnt;',
            'it is managed with podman and wsl themselves (see plugins/sandbox/docs/podman-machine.md).',
            'This script manages only the macOS machine; nothing to do here.')
        if $os =~ /^(MSWin32|cygwin|msys)$/;
    return ('On Linux containers run natively, with no podman machine; nothing to do here.');
}

# cli(\@argv, %seams) -> exit code.
# %seams (tests): os, home, account_home, podman, run, stream, read_file, out, now.
sub cli {
    my ($argv, %s) = @_;
    my @args = @{ $argv || [] };
    my $out = $s{out} || sub { print "$_\n" for @_ };
    my $os  = defined $s{os} ? $s{os} : $^O;

    my (%opt, @pos);
    while (@args) {
        my $arg = shift @args;
        if    ($arg eq '--confirm')            { $opt{confirm} = 1 }
        elsif ($arg eq '-h' || $arg eq '--help') { $opt{help} = 1 }
        elsif ($arg =~ /\A--(cpus|memory|disk-size)(?:=(.*))?\z/) {
            my ($k, $v) = ($1, $2);
            $v = shift @args unless defined $v;
            unless (defined $v && $v =~ /\A[1-9][0-9]*\z/) {
                $out->("--$k needs a positive whole number", '', usage_lines());
                return 2;
            }
            $opt{ $k eq 'disk-size' ? 'disk' : $k } = 0 + $v;
        }
        elsif ($arg =~ /\A-/) { $out->("Unknown option: $arg", '', usage_lines()); return 2 }
        else                  { push @pos, $arg }
    }
    my $cmd = shift @pos;

    unless ($os eq 'darwin') {
        $out->(_not_darwin_lines($os));
        return 0;
    }
    if ($opt{help} || !defined $cmd) {
        $out->(usage_lines());
        return defined $cmd || $opt{help} ? 0 : 2;
    }
    my %arity = (plan => 0, apply => 0, 'add-project' => 1, 'remove-project' => 1, 'test-scratch' => 1);
    unless (exists $arity{$cmd}) { $out->("Unknown command: $cmd", '', usage_lines()); return 2 }
    unless (@pos == $arity{$cmd}) {
        $out->("$cmd takes " . ($arity{$cmd} ? 'one argument' : 'no arguments'), '', usage_lines());
        return 2;
    }
    if ($cmd eq 'test-scratch' && $pos[0] !~ /\A(?:on|off)\z/) {
        $out->('test-scratch takes on or off', '', usage_lines());
        return 2;
    }

    my $home = defined $s{home} ? $s{home} : $ENV{HOME};
    unless (defined $home && length $home && -d $home) { $out->('ERROR: HOME is not set to a directory.'); return 1 }
    my $L = layout(home => $home);
    my $podman = $s{podman};
    unless (defined $podman) {
        my $o = $ENV{ HostPlatform::OVERRIDE_VAR() };
        $podman = (defined $o && length $o && HostPlatform::valid_override($o)) ? $o : 'podman';
    }
    my %env = (
        podman    => $podman,
        run       => $s{run}    || sub { run_capture($_[0], timeout => 60) },
        stream    => $s{stream} || \&run_stream,
        read_file => $s{read_file} || \&_slurp_file,
        out       => $out,
        now       => $s{now},
    );

    my ($state, $serr) = read_state($L->{state_file});
    if ($serr) { $out->("ERROR: $serr"); return 1 }
    my %new = (%$state, projects => [ @{ $state->{projects} } ]);
    my $changed = 0;

    if ($cmd eq 'add-project') {
        my ($p, $err) = canonical_project($pos[0], os => $os);
        if ($err) { $out->("ERROR: $err"); return 1 }
        my $why = project_problem($p, $L, os => $os, install_root => $state->{install_root});
        if ($why) { $out->("Refusing to share $p: $why."); return 1 }
        my ($same) = grep { _fold($_, $os) eq _fold($p, $os) } @{ $new{projects} };
        if (defined $same && $same eq $p) {
            $out->("$p is already in the share list.");
        } else {
            # A folder renamed by case alone (APFS: one folder; the VM: two
            # paths) replaces its old spelling, which the launcher no longer binds.
            $out->("Replacing $same with its current spelling.") if defined $same;
            $new{projects} = [ sort((grep { _fold($_, $os) ne _fold($p, $os) } @{ $new{projects} }), $p) ];
            $changed = 1;
        }
    } elsif ($cmd eq 'remove-project') {
        my $given = $pos[0];
        my ($p) = -d $given ? canonical_project($given, os => $os) : ();
        unless (defined $p) {
            $p = $given =~ m{\A/} ? $given : File::Spec->rel2abs($given);
            $p =~ s{/+\z}{} unless $p eq '/';
        }
        my @keep = grep { _fold($_, $os) ne _fold($p, $os) } @{ $new{projects} };
        if (@keep == @{ $new{projects} }) {
            $out->("$p is not in the share list. It holds:",
                   @{ $new{projects} } ? (map { "  $_" } @{ $new{projects} }) : ('  (no projects)'));
        } else {
            $new{projects} = \@keep;
            $changed = 1;
        }
    } elsif ($cmd eq 'test-scratch') {
        my $want = $pos[0] eq 'on' ? 1 : 0;
        if (($new{test_scratch} ? 1 : 0) == $want) {
            $out->("The test scratch share is already $pos[0].");
        } else {
            $new{test_scratch} = $want;
            $changed = 1;
        }
    }

    # A hand-edited list must not share what add-project refuses. remove-project
    # stays usable, since it is how a bad entry is taken out.
    my @bad = state_problems(\%new, $L, os => $os);
    if (@bad) {
        $out->("ERROR: the share list $L->{state_file} holds entries that must not be shared:",
               (map { "  $_" } @bad),
               'Take them out (remove-project <dir>, or edit the file), then run this again.');
        return 1;
    }

    my ($cur, $cerr) = current_machine(%env);
    if ($cerr) { $out->("ERROR: $cerr"); return 1 }
    my $install = defined $new{install_root} ? $new{install_root} : $L->{install_root};
    my @mkts = directory_marketplaces($L, $install, os => $os);
    my $want = desired_machine(layout => $L, state => \%new, current => $cur, marketplaces => \@mkts,
                               overrides => { map { exists $opt{$_} ? ($_ => $opt{$_}) : () } qw(cpus memory disk) });
    my $plan = compute_plan(current => $cur, desired => $want);
    $out->(render_plan($plan, state_file => $L->{state_file}, state_exists => $state->{exists},
                       marketplaces => \@mkts, pending => [ pending_archives($L) ],
                       home => $L->{home}, account_home => $s{account_home} // account_home()));

    # What a running machine can tell before anything changes: the images a
    # recreate keeps, the containers it deletes and any volume. Read-only
    # queries; a stopped machine is not started for them.
    my ($images, $containers, $volumes);
    if ($cur->{exists} && ($cur->{state} // '') eq 'running' && $plan->{action} eq 'recreate') {
        my $im = $env{run}->([$podman, 'images', '--format', 'json']);
        $images = [ keep_image_names($im->{out}) ] if _run_ok($im);
        my $ps = $env{run}->([$podman, 'ps', '-a', '--format', 'json']);
        $containers = [ container_names($ps->{out}) ] if _run_ok($ps);
        my $vl = $env{run}->([$podman, 'volume', 'ls', '--format', 'json']);
        $volumes = [ volume_names($vl->{out}) ] if _run_ok($vl);
    }

    if ($cmd eq 'plan') {
        $out->(cost_lines($plan, images => $images, containers => $containers, volumes => $volumes));
        $out->('', 'To make the machine match: ' . 'perl ' . HostPlatform::machine_script_path() . ' apply --confirm')
            unless $plan->{action} eq 'none' && !dedicated_missing($plan);
        return 0;
    }

    if ($changed && $opt{confirm}) {
        my ($ok, $werr) = write_state($L->{state_file}, \%new);
        unless ($ok) { $out->("ERROR: $werr"); return 1 }
        $out->("Share list updated: $L->{state_file}");
    } elsif ($changed) {
        $out->('(The share list is written only with --confirm.)');
    }
    my $rc = apply(env => \%env, layout => $L, plan => $plan, confirm => $opt{confirm},
                   images => $images, containers => $containers, volumes => $volumes);
    if ($rc != 0 && $changed && $opt{confirm}) {
        $out->("The share list already includes this change; once the cause is fixed, run apply --confirm to bring the machine in line.");
    }
    return $rc;
}

1;
