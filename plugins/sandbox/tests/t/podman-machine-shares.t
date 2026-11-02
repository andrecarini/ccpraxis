#!/usr/bin/env perl
# platform: any
# podman-machine.pl / PodmanMachine.pm: the macOS podman machine is rootful
# and shares only what the sandbox mounts, set up by the script, never by a
# hand-typed `podman machine init`.
#
#   A. layout: one home -> the share list file, the live install, the two
#      dedicated share folders; macOS only.
#   B. the share list file: defaults, round trip, and a malformed file is an
#      error, never "no projects".
#   C. which directories may be shared read-write (add-project's refusals).
#   D. plan: desired vs current, against the shapes podman 6.1.4 printed on
#      this Mac (default rootless machine sharing /Users, /private,
#      /var/folders and ~/.config/containers).
#   E. init argv: --rootful, resources, one --volume per share, ":ro" where
#      read-only, and never an init with no --volume (podman's defaults).
#   F. images carried across a recreate.
#   G. apply, through the cli with every podman call a seam: nothing without
#      --confirm; the full save -> rm -> init -> start -> load sequence; the
#      refusals (running containers, failed save); a failed init keeps the
#      saved images and the next run loads them.
#   H. add-project / remove-project / test-scratch edit the list only with
#      --confirm.
#   I. Windows and Linux: says so, exits 0, runs nothing.
#   J. darwin: the real script end to end against a fake podman (never the
#      real one: CCPRAXIS_CONTAINER_CLI names the fake, PATH is /usr/bin:/bin).
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path remove_tree);
use Cwd ();
use JSON::PP ();
use PodmanMachine ();
use LiveMirror ();
use HostPlatform ();

my $SCRIPT = Cwd::abs_path("$Bin/../../scripts/podman-machine.pl");

sub spew { my ($p, $c) = @_; open my $fh, '>:raw', $p or die "write $p: $!"; print {$fh} $c; close $fh }
sub slurp { my ($p) = @_; open my $fh, '<:raw', $p or return undef; local $/; my $c = <$fh>; close $fh; $c }

# A fake home with the live install in place (apply refuses without it).
sub fake_home {
    my $h = Cwd::abs_path(tempdir(CLEANUP => 1));
    make_path("$h/.claude/ccpraxis/plugins/sandbox/scripts", "$h/Projects/app", "$h/Projects/other");
    spew("$h/.claude/ccpraxis/plugins/sandbox/scripts/$_", "1;\n") for qw(PodmanMachine.pm LiveMirror.pm);   # a promoted install
    return $h;
}

# ---------------------------------------------------------------------------
# A. layout
# ---------------------------------------------------------------------------
{
    my $L = PodmanMachine::layout(home => '/Users/u/');
    is($L->{state_file},      '/Users/u/.claude/ccpraxis-podman-machine.json', 'A: the share list lives in ~/.claude (never shared)');
    is($L->{install_root},    '/Users/u/.claude/ccpraxis',                     'A: the live install claude-sandbox runs from');
    is($L->{container_files}, '/Users/u/.cache/ccpraxis/container-files',      'A: the read-only container-files share');
    is($L->{test_scratch},    '/Users/u/.cache/ccpraxis/container-test-scratch', 'A: the read-write test-scratch share');
    is($L->{live_mirror},     '/Users/u/.cache/ccpraxis/live-mirror',         'A: the read-only live-install mirror share');
    is(PodmanMachine::container_files_dir(os => 'darwin', home => '/Users/u'), $L->{container_files},
        'A: container_files_dir on darwin');
    is(PodmanMachine::test_scratch_dir(os => 'darwin', home => '/Users/u'), $L->{test_scratch}, 'A: test_scratch_dir on darwin');
    for my $os (qw(cygwin msys MSWin32 linux)) {
        ok(!defined PodmanMachine::container_files_dir(os => $os, home => '/Users/u'), "A: no container-files folder on $os");
        ok(!defined PodmanMachine::test_scratch_dir(os => $os, home => '/Users/u'),    "A: no test-scratch folder on $os");
    }
}

# ---------------------------------------------------------------------------
# B. the share list file
# ---------------------------------------------------------------------------
{
    my $d = tempdir(CLEANUP => 1);
    my ($st, $err) = PodmanMachine::read_state("$d/none.json");
    ok(!$err, 'B: an absent list is not an error');
    is_deeply([$st->{projects}, $st->{test_scratch}, $st->{exists}], [[], 1, 0],
        'B: ...it is the default: no projects (the list starts EMPTY), test scratch on');

    my ($ok) = PodmanMachine::write_state("$d/sub/list.json",
        { projects => ['/Users/u/Projects/app'], test_scratch => 0 });
    ok($ok, 'B: write_state creates the folder and writes');
    ($st, $err) = PodmanMachine::read_state("$d/sub/list.json");
    is_deeply([$st->{projects}, $st->{test_scratch}, $st->{exists}], [['/Users/u/Projects/app'], 0, 1], 'B: ...and reads back');
    ok(!-e "$d/sub/list.json.tmp.$$", 'B: no temp file is left behind');

    PodmanMachine::write_state("$d/ir.json", { projects => [], test_scratch => 1, install_root => '/opt/ccp' });
    my ($ir) = PodmanMachine::read_state("$d/ir.json");
    is($ir->{install_root}, '/opt/ccp', 'B: an install_root key round-trips');
    my $want = PodmanMachine::desired_machine(layout => PodmanMachine::layout(home => '/Users/u'), state => $ir,
                                              current => { exists => 0 });
    is_deeply([ map { "$_->{role}:$_->{source}" } grep { $_->{readonly} } @{ $want->{shares} } ],
        ['live-mirror:' . LiveMirror::mirror_dir(os => 'darwin', home => '/Users/u', install_root => '/opt/ccp'),
         'container-files:/Users/u/.cache/ccpraxis/container-files'],
        'B: ...and the desired machine shares that install\'s own mirror read-only, not the install and not ~/.claude/ccpraxis\'s mirror');
    like($want->{shares}[0]{source}, qr{\A/Users/u/\.cache/ccpraxis/live-mirror-[0-9a-f]{8}\z}, 'B: ...keyed by that install root');

    spew("$d/bad.json", '{ not json');
    ($st, $err) = PodmanMachine::read_state("$d/bad.json");
    ok(!$st && $err =~ /not valid JSON/, 'B: a malformed list is an ERROR (treating it as empty would drop every project share)');
    spew("$d/schema.json", '{"schema":2,"projects":[]}');
    (undef, $err) = PodmanMachine::read_state("$d/schema.json");
    like($err, qr/schema 2/, 'B: an unknown schema is refused');
    spew("$d/rel.json", '{"schema":1,"projects":["relative/dir"]}');
    (undef, $err) = PodmanMachine::read_state("$d/rel.json");
    like($err, qr/absolute paths/, 'B: a relative project path is refused');
}

# ---------------------------------------------------------------------------
# C. what may be shared read-write
# ---------------------------------------------------------------------------
{
    my $L = PodmanMachine::layout(home => '/Users/u');
    my %cases = (
        '/Users/u'                         => qr/contains your home folder/,
        '/Users'                           => qr/top-level folder/,
        '/Users/u/.claude'                 => qr/never shared/,
        '/Users/u/.claude/projects'        => qr/never shared/,
        '/Users/u/.claude/ccpraxis/x'      => qr/never shared|live install/,
        '/Users/u/.cache/ccpraxis'         => qr/share folders/,
        '/Users/u/.cache'                  => qr/share folders/,
        '/usr/local/src'                   => qr/system directory/,
        '/opt/homebrew/x'                  => qr/system directory/,
        '/Users/u/odd:name'                => qr/':'/,
        '/Users/u/odd,name'                => qr/','/,
        '/Users/u/.ssh'                    => qr/holds keys/,
        '/Users/u/.config/containers/x'    => qr/podman's own machine files/,
        '/Users/u/.local/share/containers' => qr/podman's own machine files/,
        '/Users/u/Library/Mobile'          => qr/holds keys/,
        '/'                                => qr/top-level/,
    );
    for my $p (sort keys %cases) {
        like(PodmanMachine::project_problem($p, $L, os => 'darwin') // '(allowed)', $cases{$p}, "C: refuses $p");
    }
    is(PodmanMachine::project_problem('/Users/u/Projects/app', $L, os => 'darwin'), undef, 'C: allows ~/Projects/app');
    is(PodmanMachine::project_problem('/Volumes/Data/work', $L, os => 'darwin'), undef, 'C: allows a folder on another volume');
    like(PodmanMachine::project_problem('/users/U/.CLAUDE', $L, os => 'darwin') // '', qr/never shared/,
        'C: compared case-insensitively on darwin (APFS)');
    my $e_acute = "\xc3\xa9"; my $E_acute = "\xc3\x89";   # UTF-8 bytes, as paths arrive
    is(PodmanMachine::_fold("/Users/u/Caf$E_acute", 'darwin'), "/users/u/caf$e_acute", 'C: case folding covers non-ASCII letters (as characters, not bytes)');
    is(PodmanMachine::install_root_problem('/Users/u/.claude/ccpraxis', $L, os => 'darwin'), undef, 'C: install_root inside ~/.claude is fine');
    like(PodmanMachine::install_root_problem('/Users/u/.claude', $L, os => 'darwin') // '', qr/contains ~\/\.claude/, 'C: install_root may not be ~/.claude itself');
    like(PodmanMachine::install_root_problem('/Users/u', $L, os => 'darwin') // '', qr/home folder/, 'C: ...nor the home folder');
}

# ---------------------------------------------------------------------------
# Fixtures: what podman 6.1.4 printed on this Mac for its default machine.
# ---------------------------------------------------------------------------
sub list_json {
    my (%o) = @_;
    return '[]' if $o{absent};
    return JSON::PP->new->canonical->encode([{ CPUs => 6, Default => JSON::PP::true(), DiskSize => '107374182400',
        Memory => '12884901888', Name => 'podman-machine-default', Running => ($o{running} ? JSON::PP::true() : JSON::PP::false()),
        Starting => JSON::PP::false(), VMType => 'applehv' }]);
}
sub inspect_json {
    my (%o) = @_;
    return JSON::PP->new->canonical->encode([{
        ConfigDir => { Path => "$o{cfgdir}" },
        ConnectionInfo => { PodmanSocket => { Path => '/var/folders/xx/T/podman/podman-machine-default-api.sock' } },
        Name => 'podman-machine-default',
        Resources => { CPUs => 6, DiskSize => 100, Memory => 12288, USBs => [] },
        Rootful => ($o{rootful} ? JSON::PP::true() : JSON::PP::false()),
        State => ($o{running} ? 'running' : 'stopped'),
    }]);
}
sub default_config {
    my ($home) = @_;
    return JSON::PP->new->canonical->encode({ Name => 'podman-machine-default',
        HostUser => { Rootful => JSON::PP::false(), UID => 501 },
        Resources => { CPUs => 6, DiskSize => 100, Memory => 12288 },
        Mounts => [ map { { ReadOnly => JSON::PP::false(), Source => $_->[0], Target => $_->[1], Type => 'virtiofs' } }
                    ['/Users', '/Users'], ['/private', '/private'], ['/var/folders', '/var/folders'],
                    ["$home/.config/containers", '/etc/containers'] ] });
}
sub narrow_config {
    my ($home, @projects) = @_;
    my $L = PodmanMachine::layout(home => $home);
    my @m = ([$L->{live_mirror}, 1], [$L->{container_files}, 1], [$L->{test_scratch}, 0], map { [$_, 0] } @projects);
    return JSON::PP->new->canonical->encode({ Name => 'podman-machine-default',
        HostUser => { Rootful => JSON::PP::true() },
        Resources => { CPUs => 6, DiskSize => 100, Memory => 12288 },
        Mounts => [ map { { ReadOnly => ($_->[1] ? JSON::PP::true() : JSON::PP::false()), Source => $_->[0], Target => $_->[0] } } @m ] });
}

my $IMAGES = JSON::PP->new->encode([
    { Id => 'aaa', Names => ['localhost/claude-sandbox:latest', 'localhost/claude-sandbox:2.1.301'], Size => 1 },
    { Id => 'bbb', Names => ['docker.io/library/debian:bookworm-slim'] },
    { Id => 'ccc' },
    { Id => 'ddd', Names => ['localhost/not-claude-sandbox:latest'] },
]);

# A scripted podman: answers queries from %$r, records every call. stream
# calls (the ones apply runs with the operator watching) are recorded too.
sub fake_podman {
    my (%r) = @_;
    my @calls;
    my $run = sub {
        my ($argv) = @_;
        my @a = @$argv[1 .. $#$argv];
        push @calls, "run: @a";
        my $k = join ' ', @a;
        my $h = $r{handlers} || {};
        for my $pat (sort keys %$h) {
            return $h->{$pat}->(@a) if $k =~ /\A\Q$pat\E/;
        }
        return { rc => 0, out => '', err => '' };
    };
    my $stream = sub {
        my ($argv) = @_;
        my @a = @$argv[1 .. $#$argv];
        push @calls, "stream: @a";
        my $k = join ' ', @a;
        my $h = $r{streams} || {};
        for my $pat (sort keys %$h) {
            return $h->{$pat}->(@a) if $k =~ /\A\Q$pat\E/;
        }
        return 0;
    };
    return ($run, $stream, \@calls);
}

sub machine_seams {
    my (%o) = @_;
    my $home = $o{home};
    my $cfgdir = "$home/.config/containers/podman/machine/applehv";
    make_path($cfgdir);
    spew("$cfgdir/podman-machine-default.json", $o{config} // default_config($home));
    my %state = (absent => $o{absent} ? 1 : 0, running => $o{running} ? 1 : 0);
    # The images the (fake) machine holds: what `images` reports, emptied by
    # an rm, filled by a load from the archive's .names file.
    my $imgs = JSON::PP->new->decode($o{images} // $IMAGES);
    my %present = $o{absent} ? () : map { $_ => 1 } map { @{ $_->{Names} || [] } } @$imgs;
    my %handlers = (
        'machine list'    => sub { { rc => 0, out => list_json(%state), err => '' } },
        'machine inspect' => sub { { rc => 0, out => inspect_json(cfgdir => $cfgdir, running => $state{running}, rootful => $o{rootful}), err => '' } },
        'images'          => sub { { rc => 0, out => ($o{images} // $IMAGES), err => '' } },
        # ps lists running containers, ps -a all of them.
        'ps'              => sub { my $all = grep { $_ eq '-a' } @_;
                                   my $l = JSON::PP->new->decode($o{ps} // '[]');
                                   $l = [ grep { ($_->{State} // '') eq 'running' } @$l ] unless $all;
                                   { rc => 0, out => JSON::PP->new->encode($l), err => '' } },
        'info'            => sub { { rc => 0, out => ($o{rootless} // "false\n"), err => '' } },
        'image exists'    => sub { { rc => ($present{ $_[2] } ? 0 : 1), out => '', err => '' } },
        'volume ls'       => sub { { rc => 0, out => ($o{volumes} // '[]'), err => '' } },
        %{ $o{handlers} || {} },
    );
    my %streams = (
        'machine start' => sub { $state{running} = 1; 0 },
        'machine stop'  => sub { $state{running} = 0; 0 },
        'machine rm'    => sub { $state{absent} = 1; $state{running} = 0; %present = (); 0 },
        'machine init'  => sub { $state{absent} = 0; 0 },
        'save'          => sub { my @a = @_; my ($i) = grep { $a[$_] eq '-o' } 0 .. $#a; spew($a[$i + 1], 'TAR'); 0 },
        'load'          => sub { my @a = @_; my $n = slurp("$a[2].names"); $present{$_} = 1 for @{ $n ? JSON::PP->new->decode($n) : [] }; 0 },
        %{ $o{streams} || {} },
    );
    my ($run, $stream, $calls) = fake_podman(handlers => \%handlers, streams => \%streams);
    my @out;
    return (calls => $calls, out => \@out, state => \%state,
            seams => { os => 'darwin', home => $home, account_home => $home, podman => 'podman', run => $run, stream => $stream,
                       out => sub { push @out, @_ }, now => sub { 1_800_000_000 } });
}

sub cli_run {
    my ($argv, %m) = @_;
    @{ $m{out} } = ();
    @{ $m{calls} } = ();
    my $rc = PodmanMachine::cli($argv, %{ $m{seams} });
    return ($rc, join("\n", @{ $m{out} }), [ @{ $m{calls} } ]);
}

# ---------------------------------------------------------------------------
# D. plan
# ---------------------------------------------------------------------------
{
    my $home = fake_home();
    my %m = machine_seams(home => $home);
    my ($rc, $text, $calls) = cli_run(['plan'], %m);
    is($rc, 0, 'D: plan exits 0');
    like($text, qr/podman machine: podman-machine-default \(applehv, stopped\)/, 'D: names the machine, provider and state');
    like($text, qr/rootful\s+no\s+yes/, 'D: rootful: no -> yes');
    like($text, qr/cpus\s+6\s+6/, 'D: CPUs preserved from the current machine');
    like($text, qr/memory \(MiB\)\s+12288\s+12288/, 'D: memory preserved');
    like($text, qr/disk \(GiB\)\s+100\s+100/, 'D: disk preserved');
    like($text, qr{add\s+ro\s+\Q$home\E/\.cache/ccpraxis/live-mirror\n\s+a copy of the live install's plugins, skills and statusline, refreshed by promote and by each launch; the Mac never runs anything from it\n},
        'D: adds the live-install mirror read-only, and says what it is');
    unlike($text, qr{(?:add|keep)\s+\S+\s+\Q$home\E/\.claude/ccpraxis\n}, 'D: the live install itself is NOT shared (the VM can write an "ro" share; the Mac runs that code)');
    like($text, qr{add\s+ro\s+\Q$home\E/\.cache/ccpraxis/container-files\n}, 'D: adds container-files read-only');
    like($text, qr{add\s+rw\s+\Q$home\E/\.cache/ccpraxis/container-test-scratch\n}, 'D: adds the test scratch read-write');
    like($text, qr{remove\s+rw\s+/Users\n}, 'D: removes /Users');
    like($text, qr{remove\s+rw\s+/private\n}, 'D: removes /private');
    like($text, qr{remove\s+rw\s+/var/folders\n}, 'D: removes /var/folders');
    like($text, qr{remove\s+rw\s+\Q$home\E/\.config/containers -> /etc/containers}, 'D: removes ~/.config/containers -> /etc/containers');
    like($text, qr/no project directory is shared; sandbox launches are refused until one is: add-project <dir>/,
        'D: says that with an empty list every launch is refused, and how to share one');
    like($text, qr/"ro" is recorded, not enforced/, 'D: says that applehv does not enforce read-only');
    like($text, qr/apply will RECREATE the machine/, 'D: the action is a recreate');
    like($text, qr/claude-sandbox\* images are kept/, 'D: ...and says images are kept');
    like($text, qr/the machine is stopped, so apply starts it to list and save the images/, 'D: ...and that a stopped machine is started for it');
    is_deeply([ grep { /\Astream:/ } @$calls ], [], 'D: plan changes nothing (no start/stop/rm/init/save)');
    is_deeply([ grep { /\Arun: (?:images|ps)/ } @$calls ], [], 'D: ...and does not query a stopped machine');
    ok(!-e PodmanMachine::layout(home => $home)->{state_file}, 'D: ...and writes no share list');

    my %r = machine_seams(home => $home, running => 1,
        ps => '[{"Names":["claude-app-12345678"],"State":"exited"}]');
    (undef, $text, $calls) = cli_run(['plan'], %r);
    like($text, qr/images to keep: localhost\/claude-sandbox:2\.1\.301, localhost\/claude-sandbox:latest/,
        'D: a running machine lists the images it will keep');
    like($text, qr/containers that will be deleted: claude-app-12345678/, 'D: ...and the containers it will delete');
}

{
    my $home = fake_home();
    my $L = PodmanMachine::layout(home => $home);
    make_path($L->{container_files}, $L->{test_scratch}, $L->{live_mirror});
    spew($L->{state_file}, JSON::PP->new->encode({ schema => 1, projects => ["$home/Projects/app"], test_scratch => JSON::PP::true() }));
    my %m = machine_seams(home => $home, config => narrow_config($home, "$home/Projects/app"), rootful => 1);
    my ($rc, $text) = cli_run(['plan'], %m);
    like($text, qr/The machine already matches; nothing to do\./, 'D: a machine that matches the list: nothing to do');
    unlike($text, qr/apply --confirm/, 'D: ...and no apply hint');

    # The same machine with one of ccpraxis's share folders emptied away (cleanup
    # tools empty ~/.cache): vfkit would refuse to start it, so apply creates it.
    rmdir $L->{live_mirror} or die "rmdir: $!";
    my $calls;
    ($rc, $text) = cli_run(['plan'], %m);
    like($text, qr/Missing on disk:\n  \Q$L->{live_mirror}\E \(apply creates it/, 'D: a matching machine with its mirror folder gone: plan says so');
    like($text, qr/To make the machine match: .* apply --confirm/, 'D: ...and gives the apply command');
    ($rc, $text, $calls) = cli_run(['apply'], %m);
    like($text, qr/cannot start without these folders it shares:\n  \Q$L->{live_mirror}\E\n\nNothing has changed/, 'D: apply without --confirm names the folder and changes nothing');
    ok(!-d $L->{live_mirror}, 'D: ...nothing is created');
    ($rc, $text, $calls) = cli_run(['apply', '--confirm'], %m);
    is($rc, 0, 'D: apply --confirm succeeds') or diag($text);
    ok(-d $L->{live_mirror}, 'D: ...and creates the folder');
    is_deeply([ grep { /\Astream:/ } @$calls ], [], 'D: ...without touching the machine');
    ($rc, $text) = cli_run(['plan', '--cpus', '8'], %m);
    like($text, qr/in place \(podman machine set\)/, 'D: a resources-only change is a podman machine set, not a recreate');
    ($rc, $text) = cli_run(['plan', '--disk-size', '50'], %m);
    like($text, qr/RECREATE/, 'D: a smaller disk needs a recreate (set cannot shrink a disk)');

    my %a = machine_seams(home => fake_home(), absent => 1);
    ($rc, $text) = cli_run(['plan'], %a);
    like($text, qr/podman machine: none yet; apply creates podman-machine-default/, 'D: no machine: apply creates one');
    like($text, qr/cpus\s+-\s+6\n.*memory \(MiB\)\s+-\s+12288\n.*disk \(GiB\)\s+-\s+100/s,
        'D: ...with --cpus 6 --memory 12288 and podman\'s 100 GiB disk');
}

# ---------------------------------------------------------------------------
# E. init argv
# ---------------------------------------------------------------------------
{
    my $want = { name => 'm', cpus => 6, memory => 12288, disk => 100,
                 shares => [ { source => '/a', target => '/a', readonly => 1 }, { source => '/b', target => '/b', readonly => 0 } ] };
    is_deeply([PodmanMachine::init_args($want)],
        ['machine', 'init', '--rootful', '--cpus', 6, '--memory', 12288, '--disk-size', 100,
         '--volume', '/a:/a:ro', '--volume', '/b:/b', 'm'],
        'E: --rootful, the resources, --volume SRC:DST:ro for read-only, SRC:DST for read-write, the name last');
    eval { PodmanMachine::init_args({ %$want, shares => [] }) };
    like($@, qr/podman would share its defaults/, 'E: an init with no --volume is refused (podman would share /Users etc.)');
}

# ---------------------------------------------------------------------------
# F. images
# ---------------------------------------------------------------------------
is_deeply([PodmanMachine::keep_image_names($IMAGES)],
    ['localhost/claude-sandbox:2.1.301', 'localhost/claude-sandbox:latest'],
    'F: every tag of the sandbox image is kept; other repositories and untagged images are not');
is_deeply([PodmanMachine::keep_image_names('garbage')], [], 'F: unreadable output keeps nothing (and does not die)');

# ---------------------------------------------------------------------------
# G. apply
# ---------------------------------------------------------------------------
{
    my $home = fake_home();
    my $L = PodmanMachine::layout(home => $home);
    my %m = machine_seams(home => $home);
    my ($rc, $text, $calls) = cli_run(['apply'], %m);
    is($rc, 0, 'G: apply without --confirm exits 0');
    like($text, qr/Nothing has changed\. To do this, run again with --confirm\./, 'G: ...says nothing changed');
    is_deeply([ grep { /\Astream:/ } @$calls ], [], 'G: ...and runs no start, stop, save, rm or init');
    ok(!-d $L->{container_files}, 'G: ...and creates no share folder');

    ($rc, $text, $calls) = cli_run(['apply', '--confirm'], %m);
    is($rc, 0, 'G: apply --confirm succeeds') or diag($text);
    my @streams = map { s/\Astream: //r } grep { /\Astream:/ } @$calls;
    my $archive = "$L->{cache_dir}/podman-machine-images-" . POSIX::strftime('%Y%m%dT%H%M%S', localtime(1_800_000_000)) . '.tar';
    is_deeply(\@streams, [
        'machine start podman-machine-default',
        "save -m -o $archive.partial localhost/claude-sandbox:2.1.301 localhost/claude-sandbox:latest",
        'machine rm -f podman-machine-default',
        "machine init --rootful --cpus 6 --memory 12288 --disk-size 100"
          . " --volume $L->{live_mirror}:$L->{live_mirror}:ro"
          . " --volume $L->{container_files}:$L->{container_files}:ro"
          . " --volume $L->{test_scratch}:$L->{test_scratch}"
          . " podman-machine-default",
        'machine start podman-machine-default',
        'system connection default podman-machine-default-root',
        "load -i $archive",
        'machine stop podman-machine-default',
    ], 'G: start (to save) -> save the sandbox images (to .partial, renamed when whole) -> rm -> init rootful with only the desired shares -> start -> make its -root connection the default -> load -> stop (it was stopped)')
        or diag(join "\n", @$calls);
    my $before_rm = join "\n", @$calls[0 .. (grep { $calls->[$_] =~ /machine rm/ } 0 .. $#$calls)[0]];
    like($before_rm, qr/run: ps --format json/, 'G: running containers are checked before the rm');
    ok((grep { $_ eq 'run: image exists localhost/claude-sandbox:latest' } @$calls)
       && (grep { $_ eq 'run: image exists localhost/claude-sandbox:2.1.301' } @$calls),
        'G: every saved name is verified after the load');
    ok(!-e $archive && !-e "$archive.names", 'G: the archive is deleted once every image is back');
    ok(-d $L->{container_files} && -d $L->{test_scratch} && -d $L->{live_mirror}, 'G: the dedicated share folders and the mirror exist before init (vfkit needs them)');
    like(join("\n", @$calls), qr/run: info --format \{\{\.Host\.Security\.Rootless\}\}/, 'G: podman is asked whether it now talks to the rootful service');
    like($text, qr/Done: the machine is rootful and shares only:\n  ro  \Q$L->{live_mirror}\E\n/, 'G: the summary lists the shares');
    ok(!-e $L->{state_file}, 'G: apply alone does not write the share list');
}

{   # running containers: refused before anything is removed; the machine it started is stopped again
    my $home = fake_home();
    my %m = machine_seams(home => $home, ps => '[{"Names":["claude-app-12345678"],"State":"running"}]');
    my ($rc, $text, $calls) = cli_run(['apply', '--confirm'], %m);
    is($rc, 1, 'G: running containers -> apply refuses');
    like($text, qr/these containers are running.*claude-app-12345678/s, 'G: ...naming them');
    is_deeply([ grep { /\Astream:/ } @$calls ], ['stream: machine start podman-machine-default', 'stream: machine stop podman-machine-default'],
        'G: ...after starting the machine only to look, and stopping it again; no save, rm or init');
}

{   # a failed save removes nothing
    my $home = fake_home();
    my %m = machine_seams(home => $home, running => 1, streams => { save => sub { 125 } });
    my ($rc, $text, $calls) = cli_run(['apply', '--confirm'], %m);
    is($rc, 1, 'G: a failed podman save -> apply refuses');
    unlike(join("\n", @$calls), qr/machine rm|machine init/, 'G: ...and nothing is removed');
    unlike(join("\n", @$calls), qr/machine stop/, 'G: ...and a machine that was running is left running');
}

{   # init fails after the rm: the saved images survive, and the next run loads them
    my $home = fake_home();
    my $L = PodmanMachine::layout(home => $home);
    my $fail = 1;
    my %m = machine_seams(home => $home, streams => { 'machine init' => sub { $fail ? 125 : 0 } });
    my ($rc, $text) = cli_run(['apply', '--confirm'], %m);
    is($rc, 1, 'G: a failed init -> exit 1');
    like($text, qr/podman machine init failed\. The old machine is already removed\./, 'G: ...says the old machine is gone');
    my @kept = glob("$L->{cache_dir}/podman-machine-images-*.tar");
    is(scalar(@kept), 1, 'G: ...the saved images are kept') or diag($text);
    like($text, qr/Saved images are kept in \Q$kept[0]\E/, 'G: ...and where');

    $m{state}{absent} = 1;   # what podman reports after the rm
    $fail = 0;
    my $calls;
    ($rc, $text, $calls) = cli_run(['apply', '--confirm'], %m);
    is($rc, 0, 'G: the next apply --confirm creates the machine') or diag($text);
    ok((grep { $_ eq "stream: load -i $kept[0]" } @$calls), 'G: ...and loads the images the failed run saved');
    ok(!-e $kept[0], 'G: ...then deletes them');
}

{   # a resources-only change runs podman machine set, keeping the machine
    my $home = fake_home();
    my $L = PodmanMachine::layout(home => $home);
    make_path($L->{container_files}, $L->{test_scratch});
    my %m = machine_seams(home => $home, config => narrow_config($home), rootful => 1, running => 1);
    my ($rc, $text, $calls) = cli_run(['apply', '--cpus', '8', '--confirm'], %m);
    is($rc, 0, 'G: apply --cpus 8 on a matching machine succeeds') or diag($text);
    is_deeply([ grep { /\Astream:/ } @$calls ], [
        'stream: machine stop podman-machine-default',
        'stream: machine set --cpus 8 podman-machine-default',
        'stream: machine start podman-machine-default',
    ], 'G: ...as stop, podman machine set, start (it was running): no rm, no init');
    ok((grep { $_ eq 'run: ps --format json' } @$calls), 'G: ...after checking that no container is running');

    # A leftover archive (an earlier apply died after saving) is loaded even
    # when the machine already matches -- when the machine lacks its images.
    my $left = "$L->{cache_dir}/podman-machine-images-20300101T000000.tar";
    spew($left, 'TAR');
    spew("$left.names", '["localhost/claude-sandbox:latest"]');
    my %s = machine_seams(home => $home, config => narrow_config($home), rootful => 1, images => '[]');
    ($rc, $text, $calls) = cli_run(['plan'], %s);
    like($text, qr/Images saved by an earlier apply that did not finish.*\Q$left\E/s, 'G: plan lists a leftover image archive');
    ($rc, $text, $calls) = cli_run(['apply', '--confirm'], %s);
    is($rc, 0, 'G: a matching machine with a leftover image archive: apply succeeds') or diag($text);
    is_deeply([ grep { /\Astream:/ } @$calls ], [
        'stream: machine start podman-machine-default',
        "stream: load -i $left",
        'stream: machine stop podman-machine-default',
    ], 'G: ...it starts the machine, loads the archive and stops it again');
    ok(!-e $left && !-e "$left.names", 'G: ...and removes the archive once its images are back');

    # ...but never over images the machine already has: a launch may have built
    # a fresh image since, and loading would point the tags back at the old one.
    spew($left, 'TAR');
    spew("$left.names", '["localhost/claude-sandbox:latest"]');
    my %f = machine_seams(home => $home, config => narrow_config($home), rootful => 1);
    ($rc, $text, $calls) = cli_run(['apply', '--confirm'], %f);
    unlike(join("\n", @$calls), qr/stream: load/, 'G: a leftover archive whose names the machine already has is NOT loaded');
    like($text, qr/Not loading \Q$left\E: the machine already has localhost\/claude-sandbox:latest/, 'G: ...and says why');
    ok(-e $left, 'G: ...and keeps it for the operator to decide');

    # An archive without its .names file cannot be verified, so it is kept.
    unlink "$left.names";
    ($rc, $text, $calls) = cli_run(['apply', '--confirm'], %f);
    is($rc, 1, 'G: an archive with no .names file -> exit 1');
    like($text, qr/\.names is missing or unreadable; \Q$left\E is kept/, 'G: ...it is kept, with the manual load command');
    unlink $left;
}

{   # podman still talking to the rootless service after init
    my $home = fake_home();
    my %m = machine_seams(home => $home, absent => 1, rootless => "true\n");
    my (undef, $text, $calls) = cli_run(['apply', '--confirm'], %m);
    ok((grep { $_ eq 'stream: system connection default podman-machine-default-root' } @$calls),
        'G: when podman reports Rootless=true after init, the -root connection is made the default');
    like($text, qr/WARNING: podman reports Rootless=true after the switch/, 'G: a connection that stays rootless is reported');
}

{   # a live install from before the mirror blocks apply: its launcher binds the
    # live install itself, which the machine will not share
    my $home = fake_home();
    unlink "$home/.claude/ccpraxis/plugins/sandbox/scripts/LiveMirror.pm";
    my %m = machine_seams(home => $home);
    my ($rc, $text, $calls) = cli_run(['plan'], %m);
    like($text, qr/predates the live-install mirror: its launcher binds the live install itself.*Promote first/s, 'G: plan says an unpromoted live install must be promoted first');
    ($rc, $text, $calls) = cli_run(['apply', '--confirm'], %m);
    is($rc, 1, 'G: ...and apply --confirm refuses');
    is_deeply([ grep { /\Astream:/ } @$calls ], [], 'G: ...before touching the machine');
}

{   # a missing project folder blocks apply before anything happens
    my $home = fake_home();
    my $L = PodmanMachine::layout(home => $home);
    spew($L->{state_file}, JSON::PP->new->encode({ schema => 1, projects => ["$home/Projects/gone"] }));
    my %m = machine_seams(home => $home);
    my ($rc, $text, $calls) = cli_run(['apply', '--confirm'], %m);
    is($rc, 1, 'G: a listed project folder that no longer exists -> apply refuses');
    like($text, qr/do not exist on disk:\n  \Q$home\E\/Projects\/gone/, 'G: ...naming it');
    is_deeply([ grep { /\Astream:/ } @$calls ], [], 'G: ...before touching the machine');
}

# ---------------------------------------------------------------------------
# H. add-project / remove-project / test-scratch
# ---------------------------------------------------------------------------
{
    my $home = fake_home();
    my $L = PodmanMachine::layout(home => $home);
    my %m = machine_seams(home => $home);
    my ($rc, $text, $calls) = cli_run(['add-project', "$home/Projects/app/"], %m);
    is($rc, 0, 'H: add-project without --confirm exits 0');
    like($text, qr{add\s+rw\s+\Q$home\E/Projects/app\n}, 'H: ...shows the project as a read-write share to add');
    unlike($text, qr/no project directory is shared/, 'H: ...and no longer says that none is');
    ok(!-e $L->{state_file}, 'H: ...but writes nothing without --confirm');
    is_deeply([ grep { /\Astream:/ } @$calls ], [], 'H: ...and changes no machine');

    ($rc, $text, $calls) = cli_run(['add-project', "$home/Projects/app", '--confirm'], %m);
    is($rc, 0, 'H: add-project --confirm succeeds') or diag($text);
    my ($st) = PodmanMachine::read_state($L->{state_file});
    is_deeply($st->{projects}, ["$home/Projects/app"], 'H: ...the list holds the canonical path');
    like(join("\n", @$calls), qr{--volume \Q$home\E/Projects/app:\Q$home\E/Projects/app podman-machine-default},
        'H: ...and the machine is recreated sharing it read-write');

    ($rc, $text) = cli_run(['add-project', "$home/.claude", '--confirm'], %m);
    is($rc, 1, 'H: add-project ~/.claude is refused');
    like($text, qr/Refusing to share \Q$home\E\/\.claude: ~\/\.claude holds transcripts/, 'H: ...with the reason');
    ($rc, $text) = cli_run(['add-project', "$home/nope", '--confirm'], %m);
    is($rc, 1, 'H: a directory that does not exist is refused');

    ($rc, $text) = cli_run(['remove-project', "$home/Projects/app", '--confirm'], %m);
    ($st) = PodmanMachine::read_state($L->{state_file});
    is_deeply($st->{projects}, [], 'H: remove-project --confirm drops it from the list');

    ($rc, $text) = cli_run(['test-scratch', 'off'], %m);
    unlike($text, qr{\Q$L->{test_scratch}\E}, 'H: test-scratch off: the desired machine no longer shares the test scratch');
    ($st) = PodmanMachine::read_state($L->{state_file});
    is($st->{test_scratch}, 1, 'H: ...but only --confirm writes it');
    ($rc, $text) = cli_run(['test-scratch', 'off', '--confirm'], %m);
    ($st) = PodmanMachine::read_state($L->{state_file});
    is($st->{test_scratch}, 0, 'H: test-scratch off --confirm records it');
    ($rc, $text) = cli_run(['test-scratch', 'maybe'], %m);
    is($rc, 2, 'H: test-scratch takes on or off');
    ($rc, $text) = cli_run(['frobnicate'], %m);
    is($rc, 2, 'H: an unknown command is a usage error');
}

{   # a stopped machine: what the rm would delete is listed once apply has started it,
    # and anything the sandbox does not recreate blocks the recreate
    my $home = fake_home();
    my %m = machine_seams(home => $home,
        ps => '[{"Names":["claude-app-12345678"],"State":"exited"},{"Names":["postgres"],"State":"exited"}]',
        volumes => '[{"Name":"pgdata"}]');
    my ($rc, $text, $calls) = cli_run(['apply', '--confirm'], %m);
    is($rc, 1, 'G: an operator container or a volume in the VM -> apply refuses');
    like($text, qr/would delete these, which the sandbox does not recreate:\n  container postgres\n  volume pgdata/,
        'G: ...naming the container and the volume (the sandbox container is not in that list)');
    unlike(join("\n", @$calls), qr/stream: (?:save|machine rm|machine init)/, 'G: ...before saving or removing anything');
    is((grep { /\Astream: machine stop/ } @$calls), 1, 'G: ...and stops the machine it started only to look');

    my %ok = machine_seams(home => $home, ps => '[{"Names":["claude-app-12345678"],"State":"exited"},{"Names":["claude-sandbox-test-1-1-c"]}]');
    ($rc, $text, $calls) = cli_run(['apply', '--confirm'], %ok);
    is($rc, 0, 'G: only sandbox containers in the VM -> the recreate goes ahead') or diag($text);
    like($text, qr/Deleting with the machine: claude-app-12345678, claude-sandbox-test-1-1-c\./, 'G: ...listing what goes with it');
    like($text, qr/Not kept \(pulled again when needed\): docker\.io\/library\/debian:bookworm-slim, localhost\/not-claude-sandbox:latest\./,
        'G: ...and the images it does not keep');
}

{   # add-project after a rename by case alone replaces the old spelling
    my $home = fake_home();
    my $L = PodmanMachine::layout(home => $home);
    make_path("$home/Projects/Mixed");
    spew($L->{state_file}, JSON::PP->new->encode({ schema => 1, projects => ["$home/Projects/mixed"] }));
    my %m = machine_seams(home => $home);
    my ($rc, $text) = cli_run(['add-project', "$home/Projects/Mixed"], %m);
    if ($^O eq 'darwin') {
        like($text, qr/Replacing \Q$home\E\/Projects\/mixed with its current spelling\./,
            'H: add-project of a folder renamed by case replaces the stale spelling (APFS: one folder, the VM: two paths)');
        like($text, qr{add\s+rw\s+\Q$home\E/Projects/Mixed\n}, 'H: ...and the plan shares the current spelling');
    } else {
        pass('H: (case-rename check needs APFS)') for 1 .. 2;
    }

    # a hand-edited list cannot share the home folder
    spew($L->{state_file}, JSON::PP->new->encode({ schema => 1, projects => [$home] }));
    ($rc, $text) = cli_run(['plan'], %m);
    is($rc, 1, 'H: a hand-edited list that shares the home folder -> refused');
    like($text, qr/holds entries that must not be shared:\n  \Q$home\E: it contains your home folder/, 'H: ...naming the entry');
    ($rc, $text) = cli_run(['remove-project', $home], %m);
    is($rc, 0, 'H: ...and remove-project still works, to take it out') or diag($text);

    # remove-project of a deleted folder, given relative to the current directory
    spew($L->{state_file}, JSON::PP->new->encode({ schema => 1, projects => ["$home/Projects/gone"] }));
    my $cwd = Cwd::getcwd();
    chdir "$home/Projects" or die;
    ($rc, $text) = cli_run(['remove-project', 'gone', '--confirm'], %m);
    chdir $cwd;
    my ($st) = PodmanMachine::read_state($L->{state_file});
    is_deeply($st->{projects}, [], 'H: remove-project takes a relative path for a folder that no longer exists');
    ($rc, $text) = cli_run(['remove-project', '/Users/nobody/x'], %m);
    like($text, qr/is not in the share list\. It holds:\n  \(no projects\)/, 'H: ...and shows the list when the path is not in it');
}

{   # directory-source marketplaces registered on the Mac
    my $home = fake_home();
    my $mkt = "$home/dev/my-marketplace";
    make_path($mkt, "$home/.claude/plugins", "$home/.claude/local-mkt");
    spew("$home/.claude/plugins/known_marketplaces.json", JSON::PP->new->encode({
        'ccpraxis-local' => { source => { source => 'directory', path => "$home/.claude/ccpraxis/plugins" } },
        'mine'           => { source => { source => 'directory', path => "$mkt/" } },
        'inside-claude'  => { source => { source => 'directory', path => "$home/.claude/local-mkt" } },
        'official'       => { source => { source => 'github', repo => 'x/y' } },
    }));
    my %m = machine_seams(home => $home);
    my ($rc, $text) = cli_run(['plan'], %m);
    like($text, qr{add\s+ro\s+\Q$mkt\E\n\s+a directory-source plugin marketplace}, 'M: another directory marketplace is shared read-only');
    unlike($text, qr{add\s+\S+\s+\Q$home\E/\.claude/ccpraxis/plugins\n}, 'M: ccpraxis-local is served by the mirror share, not a second one');
    like($text, qr{Not shared, so every launch is refused while it stays registered:\n  \Q$home\E/\.claude/local-mkt \(marketplace inside-claude\): it is inside ~/\.claude},
        'M: one inside ~/.claude is not shared, and the plan says what that costs');

    # Inside the live install: served from the mirror when it lies in the part
    # the mirror copies, refused when it does not (the install is never shared).
    make_path("$home/.claude/ccpraxis/plugins/extra-mkt", "$home/.claude/ccpraxis/references/mkt");
    spew("$home/.claude/plugins/known_marketplaces.json", JSON::PP->new->encode({
        'in-plugins' => { source => { source => 'directory', path => "$home/.claude/ccpraxis/plugins/extra-mkt" } },
        'in-refs'    => { source => { source => 'directory', path => "$home/.claude/ccpraxis/references/mkt" } },
    }));
    my @mk = PodmanMachine::directory_marketplaces(PodmanMachine::layout(home => $home), "$home/.claude/ccpraxis", os => 'darwin');
    is_deeply([ map { $_->{name} } @mk ], ['in-refs'], 'M: one inside the mirrored plugins/ needs no share of its own');
    like($mk[0]{problem} // '', qr/inside the live install .*never shared.*outside the part its mirror copies/,
        'M: one elsewhere in the live install is not shared, and the plan says why');
}

{   # the machine this change finds on a Mac: rootful, sharing the live install
    # itself. The plan moves that share to the mirror.
    my $home = fake_home();
    my $L = PodmanMachine::layout(home => $home);
    make_path($L->{container_files}, $L->{test_scratch});
    my $old = JSON::PP->new->canonical->encode({ Name => 'podman-machine-default', HostUser => { Rootful => JSON::PP::true() },
        Resources => { CPUs => 6, DiskSize => 100, Memory => 12288 },
        Mounts => [ map { { ReadOnly => ($_->[1] ? JSON::PP::true() : JSON::PP::false()), Source => $_->[0], Target => $_->[0] } }
                    [$L->{install_root}, 1], [$L->{container_files}, 1], [$L->{test_scratch}, 0] ] });
    my %m = machine_seams(home => $home, config => $old, rootful => 1);
    my ($rc, $text) = cli_run(['plan'], %m);
    like($text, qr{add\s+ro\s+\Q$L->{live_mirror}\E\n}, 'MIG: the mirror is added read-only');
    like($text, qr{remove\s+ro\s+\Q$home\E/\.claude/ccpraxis\n}, 'MIG: the live install share is removed');
    like($text, qr{keep\s+ro\s+\Q$L->{container_files}\E\n}, 'MIG: container-files is kept');
    like($text, qr/apply will RECREATE the machine/, 'MIG: a share change is a recreate');
    like($text, qr{Missing on disk:\n  \Q$L->{live_mirror}\E \(apply creates it; promote and each launch fill it\)},
        'MIG: a mirror not made yet is created by apply, and filled by promote and each launch');

    # The live install itself missing: nothing to fill the mirror from.
    remove_tree("$home/.claude/ccpraxis");
    my $calls;
    ($rc, $text, $calls) = cli_run(['apply', '--confirm'], %m);
    is($rc, 1, 'MIG: no live install -> apply refuses');
    like($text, qr/do not exist on disk:\n  \Q$home\E\/\.claude\/ccpraxis/, 'MIG: ...naming it');
    is_deeply([ grep { /\Astream:/ } @$calls ], [], 'MIG: ...before touching the machine');
}

{   # HOME is not the account home
    my $home = fake_home();
    my %m = machine_seams(home => $home);
    $m{seams}{account_home} = '/Users/someone-else';
    my (undef, $text) = cli_run(['plan'], %m);
    like($text, qr/Note: HOME \(\Q$home\E\) is not your account's home \(\/Users\/someone-else\)/, 'H: plan notes a HOME that is not the account home');
}

{   # a deleted project folder stops the machine from starting: say which, and the fix
    my $home = fake_home();
    my @remedy = PodmanMachine::missing_share_remedy([
        { source => "$home/Projects/app", target => "$home/Projects/app", readonly => 0 },
        { source => "$home/Projects/gone", target => "$home/Projects/gone", readonly => 0 } ]);
    my $r = join "\n", @remedy;
    like($r, qr/shares a folder that no longer exists, and it cannot start without it:\n    \Q$home\E\/Projects\/gone/,
        'M1: missing_share_remedy names the missing shared folder');
    like($r, qr/\Q$SCRIPT\E remove-project \Q$home\E\/Projects\/gone --confirm/, 'M1: ...and the remove-project command');
    unlike($r, qr{Projects/app\b}, 'M1: ...and not the folders that exist');
    is_deeply([PodmanMachine::missing_share_remedy([{ source => "$home/Projects/app" }])], [], 'M1: nothing to say when every folder exists');

    my $src = slurp("$Bin/../../scripts/launcher.pl");
    like($src, qr/PodmanMachine::missing_share_sources\(\$shares\)/, 'M1: the launcher checks the shares before it starts the machine');
    like($src, qr/ref \$r->\{remedy\} eq 'ARRAY' && \@\{ \$r->\{remedy\} \}\s*\?\s*\@\{ \$r->\{remedy\} \} : HostPlatform::machine_remedy_lines/,
        'M1: ...and shows that remedy instead of "podman machine start"');

    # "Mounts": null -- a machine created with no shares at all
    my %m = machine_seams(home => $home, config => '{"Name":"podman-machine-default","HostUser":{"Rootful":true},"Mounts":null}', rootful => 1);
    my ($rc, $text) = cli_run(['plan'], %m);
    is($rc, 0, 'L9: a machine config with "Mounts": null plans (no shares yet)') or diag($text);
    like($text, qr{add\s+ro\s+\Q$home\E/\.cache/ccpraxis/live-mirror\n}, 'L9: ...adding every share');
}

# ---------------------------------------------------------------------------
# I. Windows and Linux
# ---------------------------------------------------------------------------
for my $os (qw(cygwin msys linux)) {
    my @out;
    my $ran = 0;
    my $rc = PodmanMachine::cli(['apply', '--confirm'], os => $os, out => sub { push @out, @_ },
        run => sub { $ran++; { rc => 0, out => '', err => '' } }, stream => sub { $ran++; 0 });
    is($rc, 0, "I: $os: exits 0");
    is($ran, 0, "I: $os: runs nothing");
    like(join("\n", @out), $os eq 'linux' ? qr/natively, with no podman machine/ : qr/WSL2 podman machine.*only the macOS machine/s,
        "I: $os: says the machine is the platform's own business");
}

# ---------------------------------------------------------------------------
# J. the real script, end to end, against a fake podman (darwin only)
# ---------------------------------------------------------------------------
SKIP: {
    skip 'J: the script acts only on darwin', 9 unless $^O eq 'darwin';
    my $home = fake_home();
    my $L = PodmanMachine::layout(home => $home);
    my $fake = Cwd::abs_path(tempdir(CLEANUP => 1));
    my $cfgdir = "$home/.config/containers/podman/machine/applehv";
    make_path($cfgdir);
    spew("$cfgdir/podman-machine-default.json", default_config($home));
    spew("$fake/list.json", list_json());
    spew("$fake/inspect.json", inspect_json(cfgdir => $cfgdir));
    spew("$fake/images.json", $IMAGES);
    spew("$fake/podman", <<'PERL');
#!/usr/bin/perl
use strict; use warnings;
my $d = $ENV{FAKE_PODMAN_DIR} or die "FAKE_PODMAN_DIR unset\n";
open my $log, '>>', "$d/log" or die; print {$log} join(' ', @ARGV), "\n"; close $log;
sub cat { my ($f) = @_; open my $fh, '<', "$d/$f" or return; local $/; print scalar <$fh> }
my $k = join ' ', @ARGV;
if    ($k =~ /\Amachine list/)    { cat('list.json') }
elsif ($k =~ /\Amachine inspect/) { cat('inspect.json') }
elsif ($k =~ /\Aimages/)          { cat('images.json') }
elsif ($k =~ /\Aps/)              { print "[]\n" }
elsif ($k =~ /\Ainfo/)            { print "false\n" }
elsif ($k =~ /\Asave/)            { my ($i) = grep { $ARGV[$_] eq '-o' } 0 .. $#ARGV; open my $fh, '>', $ARGV[$i + 1] or die; print {$fh} "TAR"; close $fh }
exit 0;
PERL
    chmod 0755, "$fake/podman";
    local $ENV{HOME} = $home;
    local $ENV{FAKE_PODMAN_DIR} = $fake;
    local $ENV{CCPRAXIS_CONTAINER_CLI} = "$fake/podman";
    local $ENV{PATH} = '/usr/bin:/bin';

    my $plan = `"$^X" "$SCRIPT" plan 2>&1`;
    is($? >> 8, 0, 'J: podman-machine.pl plan exits 0') or diag($plan);
    like($plan, qr/rootful\s+no\s+yes/, 'J: ...and prints the plan');
    my $log = slurp("$fake/log") // '';
    unlike($log, qr/^(?:machine (?:start|stop|rm|init)|save|load)/m, 'J: plan ran no changing command') or diag($log);

    my $apply = `"$^X" "$SCRIPT" add-project "$home/Projects/app" --confirm 2>&1`;
    is($? >> 8, 0, 'J: add-project --confirm exits 0') or diag($apply);
    $log = slurp("$fake/log") // '';
    like($log, qr/^machine rm -f podman-machine-default$/m, 'J: the machine was removed');
    like($log, qr{^machine init --rootful --cpus 6 --memory 12288 --disk-size 100 --volume \Q$L->{live_mirror}\E:\Q$L->{live_mirror}\E:ro .*--volume \Q$home\E/Projects/app:\Q$home\E/Projects/app podman-machine-default$}m,
        'J: ...and created rootful, sharing the live-install mirror read-only and the project read-write');
    unlike($log, qr{--volume \Q$home\E/\.claude/ccpraxis:}, 'J: ...and never the live install itself');
    like($log, qr/^load -i \Q$L->{cache_dir}\E\/podman-machine-images-\d{8}T\d{6}\.tar$/m, 'J: ...and the saved images were loaded');
    my ($st) = PodmanMachine::read_state($L->{state_file});
    is_deeply($st->{projects}, ["$home/Projects/app"], 'J: the share list records the project');
    unlike($log, qr{/Users:/Users|/private:/private|/var/folders:|/etc/containers}, 'J: none of podman\'s default shares came back');
}

# ---------------------------------------------------------------------------
# The launcher refuses with the script's remedy, by source text (it is never run).
# ---------------------------------------------------------------------------
{
    my $src = slurp("$Bin/../../scripts/launcher.pl");
    like($src, qr/HostPlatform::rw_binds_under_ro_shares\(\\\@binds, \$shares\)/,
        'launcher: the refusal also checks read-write binds under read-only shares');
    like($src, qr/outside_shares_message\(\\\@outside, \$shares,\s*read_only => \\\@ro, project => \$PROJECT_PATH\)/,
        'launcher: ...and hands the message the project, so it can name add-project <dir>');
    like($src, qr/_refuse_unshared_mounts\('preflight', \{ source => \$PROJECT_PATH, readonly => 0 \},\s*\{ source => \(\$LIVE_MIRROR \/\/ \$INSTALL_ROOT\), readonly => 1 \}\)/,
        'launcher: preflight checks the project read-write and the install\'s binds (its mirror on macOS) read-only');
    like($src, qr/_refuse_unshared_mounts\('create', HostPlatform::bind_mounts\(\@podman_args\)\)/,
        'launcher: create checks every bind with its mode');
}

done_testing();
