#!/usr/bin/env perl
# platform: any
# ImagePrune.pm (bug report 20261118-004944-c84a): a successful build removes
# the images it superseded, and a build that ran the machine's disk full says so.
#
#   A. parsing: `images` rows of both runtimes, ids, repositories, CreatedAt.
#   B. selection, project layer: current kept, newest previous kept, in-use
#      kept, another project never a candidate, the rest removed.
#   C. selection, shared base: :latest and its image are current, ordering by
#      version, a non-version tag is left alone.
#   D. cleanup through a stubbed runner (NO real podman, ever): the exact
#      calls, never a forced rmi, a refusal that means "still needed", a
#      failure reported in one line, listing failure removes nothing, a
#      timeout ends the cleanup.
#   E. disk-full detection and the message.
#   F. launcher.pl wiring (source only; the launcher is never spawned).
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;

my $have = eval { require ImagePrune; 1 } ? 1 : 0;
ok($have, 'ImagePrune.pm loads') or diag($@);
unless ($have) { done_testing(); exit 0 }

my $H1 = 'a' x 64;   # current project layer
my $H2 = 'b' x 64;   # newest previous
my $H3 = 'c' x 64;   # older, used by a stopped container
my $H4 = 'd' x 64;   # oldest, unused
my $H5 = 'e' x 64;   # another project's image
my $B1 = '1' x 64;   # base 2.1.282 == latest
my $B2 = '2' x 64;   # base 2.1.257
my $B3 = '3' x 64;   # base 2.1.219
my $B4 = '4' x 64;   # base 2.1.100, in use by another project's container
my $B5 = '5' x 64;   # someone's own tag in the base repository

my $REPO  = 'localhost/claude-app-1234abcd-image';
my $OTHER = 'localhost/claude-other-99999999-image';

sub row { my ($id, $repo, $tag, $when) = @_; return "sha256:$id\t$repo\t$tag\t$when +0000 UTC" }

my $IMAGES = join "\n",
    row($H1, $REPO,  'aaaaaaaaaaaa', '2026-11-18 01:00:00.123456789'),
    row($H2, $REPO,  'bbbbbbbbbbbb', '2026-11-10 01:00:00'),
    row($H3, $REPO,  'cccccccccccc', '2026-11-01 01:00:00'),
    row($H4, $REPO,  'dddddddddddd', '2026-10-01 01:00:00'),
    row($H5, $OTHER, 'eeeeeeeeeeee', '2026-09-01 01:00:00'),
    row($B1, 'localhost/claude-sandbox', '2.1.282', '2026-11-18 00:30:00'),
    row($B1, 'localhost/claude-sandbox', 'latest',  '2026-11-18 00:30:00'),
    row($B2, 'localhost/claude-sandbox', '2.1.257', '2026-11-01 00:30:00'),
    row($B3, 'localhost/claude-sandbox', '2.1.219', '2026-10-01 00:30:00'),
    row($B4, 'localhost/claude-sandbox', '2.1.100', '2026-12-01 00:30:00'),   # newer DATE, older version
    row($B5, 'localhost/claude-sandbox', 'mine',    '2026-01-01 00:30:00'),
    "sha256:" . ('f' x 64) . "\t<none>\t<none>\t2026-11-18 00:00:00 +0000 UTC",
    '';

# ---------------------------------------------------------------------------
# A. parsing
# ---------------------------------------------------------------------------
{
    my $rows = ImagePrune::parse_images($IMAGES);
    is(scalar @$rows, 11, 'A: every tagged row parsed; the <none> row dropped');
    is($rows->[0]{id}, $H1, 'A: the sha256: prefix is stripped from ids');
    is($rows->[0]{ref}, "$REPO:aaaaaaaaaaaa", 'A: ref is repo:tag as listed');
    cmp_ok($rows->[0]{created}, '>', $rows->[1]{created}, 'A: CreatedAt (with fractional seconds) orders');
    is(ImagePrune::parse_created('2026-11-18 02:00:00 +0200 CEST'), ImagePrune::parse_created('2026-11-18 00:00:00 +0000 UTC'),
       'A: the zone offset is honoured');
    is(ImagePrune::parse_created('1763427600'), 1763427600, 'A: a bare epoch is accepted');
    ok(ImagePrune::same_id(substr($H1, 0, 12), "sha256:$H1"), 'A: a truncated id matches the full one');
    ok(!ImagePrune::same_id(substr($H1, 0, 6), $H1), 'A: ...but not one shorter than 12');
    is(ImagePrune::norm_repo('docker.io/library/claude-sandbox'), 'claude-sandbox', 'A: docker prefix normalised');
    is(ImagePrune::norm_repo('localhost/claude-sandbox'), 'claude-sandbox', 'A: podman prefix normalised');
    is_deeply([ ImagePrune::split_ref("$REPO:aaaaaaaaaaaa") ], [ $REPO, 'aaaaaaaaaaaa' ], 'A: split_ref');
    is_deeply(ImagePrune::parse_ids("$H3\n\n sha256:$B4 \n"), [ $H3, $B4 ], 'A: parse_ids');
}

my $ROWS = ImagePrune::parse_images($IMAGES);
sub kept_why { my ($sel, $ref) = @_; my ($k) = grep { $_->{ref} eq $ref } @{ $sel->{keep} }; return $k ? $k->{why} : undef }

# ---------------------------------------------------------------------------
# B. selection, project layer
# ---------------------------------------------------------------------------
{
    my $sel = ImagePrune::select_removals(images => $ROWS, in_use => [ $H3, $B4 ],
                                          repo => $REPO, current_tag => 'aaaaaaaaaaaa', kind => 'project');
    is_deeply($sel->{remove}, [ "$REPO:dddddddddddd" ], 'B: only the oldest unused layer is removed');
    is(kept_why($sel, "$REPO:aaaaaaaaaaaa"), 'current', 'B: the layer just built is kept');
    is(kept_why($sel, "$REPO:bbbbbbbbbbbb"), 'previous', 'B: the newest previous is kept as the fallback');
    is(kept_why($sel, "$REPO:cccccccccccc"), 'in use by a container', 'B: a layer a stopped container uses is kept');
    ok(!grep({ /other/ } @{ $sel->{remove} }, map { $_->{ref} } @{ $sel->{keep} }),
       'B: another project\'s image is not even a candidate');

    my $none = ImagePrune::select_removals(images => $ROWS, in_use => [], repo => $REPO,
                                           current_tag => 'aaaaaaaaaaaa', kind => 'project', keep_previous => 0);
    is_deeply([ sort @{ $none->{remove} } ], [ map { "$REPO:$_" } qw(bbbbbbbbbbbb cccccccccccc dddddddddddd) ],
              'B: keep_previous => 0 keeps only the current layer');
    my $repo_typed = ImagePrune::select_removals(images => $ROWS, in_use => [ $H3 ], repo => 'claude-app-1234abcd-image',
                                                 current_tag => 'aaaaaaaaaaaa', kind => 'project');
    is_deeply($repo_typed->{remove}, [ "$REPO:dddddddddddd" ], 'B: the repository matches with or without localhost/');
    is_deeply(ImagePrune::select_removals(images => $ROWS, repo => 'claude-nothing-image', current_tag => 'x')->{remove}, [],
              'B: an unknown repository removes nothing');
}

# ---------------------------------------------------------------------------
# C. selection, shared base
# ---------------------------------------------------------------------------
{
    my $sel = ImagePrune::select_removals(images => $ROWS, in_use => [ $H3, $B4 ],
                                          repo => 'claude-sandbox', current_tag => '2.1.282', kind => 'base');
    is_deeply($sel->{remove}, [ 'localhost/claude-sandbox:2.1.219' ], 'C: only the older unused version is removed');
    is(kept_why($sel, 'localhost/claude-sandbox:latest'), 'current', 'C: :latest is current');
    is(kept_why($sel, 'localhost/claude-sandbox:2.1.282'), 'current', 'C: the version just built is current');
    is(kept_why($sel, 'localhost/claude-sandbox:2.1.257'), 'previous', 'C: the newest previous VERSION is the fallback (not the newest date)');
    is(kept_why($sel, 'localhost/claude-sandbox:2.1.100'), 'in use by a container', 'C: a version another project\'s container uses is kept');
    is(kept_why($sel, 'localhost/claude-sandbox:mine'), 'not a version tag', 'C: a tag that is not ours is left alone');
    ok(!grep({ /claude-app|claude-other/ } @{ $sel->{remove} }), 'C: project layers are never base candidates');

    # The launcher's version is newer than what :latest holds (an image kept stale):
    # the tags on :latest's image are still current.
    my $stale = ImagePrune::select_removals(images => $ROWS, in_use => [], repo => 'claude-sandbox',
                                            current_tag => '2.1.300', kind => 'base');
    is(kept_why($stale, 'localhost/claude-sandbox:2.1.282'), 'current', 'C: a version tag on :latest\'s image is current');
}

# ---------------------------------------------------------------------------
# D. cleanup through a stubbed runner
# ---------------------------------------------------------------------------
sub stub {
    my (%o) = @_;
    my @calls;
    my $run = sub {
        my ($argv) = @_;
        push @calls, [ @$argv ];
        my $line = join ' ', @$argv[1 .. $#$argv];
        for my $rule (@{ $o{rules} || [] }) {
            my ($re, $res) = @$rule;
            return { timed_out => 0, out => '', err => '', %$res } if $line =~ $re;
        }
        return { rc => 0, out => '', err => '', timed_out => 0 };
    };
    return ($run, \@calls);
}
my @LIST_OK = (
    [ qr/\Aimages /,            { rc => 0, out => $IMAGES } ],
    [ qr/\Aps -a -q/,           { rc => 0, out => "c1\nc2\n" } ],
    [ qr/\Acontainer inspect /, { rc => 0, out => "$H3\nsha256:$B4\n" } ],
);
my @TARGETS = ({ repo => $REPO, current_tag => 'aaaaaaaaaaaa', kind => 'project' },
               { repo => 'claude-sandbox', current_tag => '2.1.282', kind => 'base' });
{
    my ($run, $calls) = stub(rules => [ @LIST_OK ]);
    my $res = ImagePrune::cleanup(run => $run, cli => 'podman', targets => \@TARGETS);
    my @rmi = map { $_->[2] } grep { $_->[1] eq 'rmi' } @$calls;
    is_deeply(\@rmi, [ "$REPO:dddddddddddd", 'localhost/claude-sandbox:2.1.219' ], 'D: rmi exactly the superseded unused tags');
    ok(!grep({ my $c = $_; grep { /\A-f\z|\A--force\z/ } @$c[1 .. $#$c] and $c->[1] eq 'rmi' } @$calls), 'D: rmi is never forced');
    is_deeply($calls->[-1], [ 'podman', 'image', 'prune', '-f', '--filter', 'until=1h' ], 'D: dangling images an hour old are pruned last (-f, never -a; fresh layers of a concurrent build are spared)');
    ok(!grep({ grep { $_ eq '-a' || $_ eq '--all' } @$_ and $_->[1] eq 'image' } @$calls), 'D: prune never takes --all');
    is_deeply($calls->[2], [ 'podman', 'container', 'inspect', '--format', '{{.Image}}', 'c1', 'c2' ],
              'D: the in-use set comes from every container, running or stopped');
    is_deeply($res->{removed}, [ "$REPO:dddddddddddd", 'localhost/claude-sandbox:2.1.219' ], 'D: removed reported');
    is($res->{pruned}, 1, 'D: prune reported');
    is_deeply($res->{lines}, [], 'D: a clean run says nothing alarming');
}
{
    my ($run, $calls) = stub(rules => [ @LIST_OK,
        [ qr/\Armi .*2\.1\.219/, { rc => 125 << 8, err => 'Error: image has dependent children' } ],
        [ qr/\Armi .*dddd/,      { rc => 125 << 8, err => "Error: boom\nsecond line" } ] ]);
    my $res = ImagePrune::cleanup(run => $run, cli => 'podman', targets => \@TARGETS);
    ok((grep { $_->{ref} eq 'localhost/claude-sandbox:2.1.219' && $_->{why} =~ /still needed/ } @{ $res->{kept} }),
       'D: a base an image is built on is refused by podman and counted as kept, not failed');
    is(scalar @{ $res->{failed} }, 1, 'D: a real failure is recorded');
    is(scalar @{ $res->{lines} }, 1, 'D: ...and reported in ONE line');
    like($res->{lines}[0], qr/dddddddddddd \(Error: boom second line\)/, 'D: the line names the image and the error');
    unlike($res->{lines}[0], qr/\n/, 'D: the line has no newline in it');
    is($res->{pruned}, 1, 'D: a failed rmi does not stop the prune');
}
{
    my ($run, $calls) = stub(rules => [ [ qr/\Aimages /, { rc => 125 << 8, err => 'cannot connect' } ] ]);
    my $res = ImagePrune::cleanup(run => $run, cli => 'podman', targets => \@TARGETS);
    is(scalar(grep { $_->[1] eq 'rmi' || $_->[1] eq 'image' } @$calls), 0, 'D: listing failed -> nothing removed or pruned');
    like($res->{skipped}, qr/listing/, 'D: ...and skipped says why');
    is(scalar @{ $res->{lines} }, 1, 'D: ...in one line');
}
{
    my ($run, $calls) = stub(rules => [ @LIST_OK[0, 1], [ qr/\Acontainer inspect /, { rc => 125 << 8, out => '' } ] ]);
    my $res = ImagePrune::cleanup(run => $run, cli => 'podman', targets => \@TARGETS);
    is(scalar(grep { $_->[1] eq 'rmi' } @$calls), 0, 'D: an unknown in-use set is not an empty one: nothing removed');
}
{
    my ($run, $calls) = stub(rules => [ @LIST_OK, [ qr/\Armi /, { rc => 124 << 8, timed_out => 1 } ] ]);
    my $res = ImagePrune::cleanup(run => $run, cli => 'podman', targets => \@TARGETS);
    is(scalar(grep { $_->[1] eq 'rmi' } @$calls), 1, 'D: a timed-out rmi ends the cleanup (one bound, not one per tag)');
    is(scalar(grep { $_->[1] eq 'image' } @$calls), 0, 'D: ...prune included');
    is(scalar @{ $res->{lines} }, 1, 'D: ...reported in one line');
}
{
    my $res = ImagePrune::cleanup(run => sub { die "runner exploded\n" }, cli => 'podman', targets => \@TARGETS);
    ok(defined $res->{skipped}, 'D: a dying runner is a skipped cleanup, not a died launch');
}

# ---------------------------------------------------------------------------
# E. disk full
# ---------------------------------------------------------------------------
{
    my $log = ("STEP 12/40: RUN curl ... | sh\n" x 4500)
            . "Error: committing container for step {...}: copying layer: write /var/lib/containers/storage/overlay/x: no space left on device\n";
    ok(ImagePrune::disk_full($log), 'E: "no space left on device" at the end of a long log is found');
    ok(ImagePrune::disk_full('ERRO[0003] ... No Space Left On Device'), 'E: case-insensitive');
    ok(!ImagePrune::disk_full("Error: building at STEP \"RUN false\": exit status 1\n"), 'E: an ordinary failure is not a full disk');
    ok(!ImagePrune::disk_full(undef), 'E: no output is not a full disk');
    my @l = ImagePrune::disk_full_lines(df => "Filesystem Size Used Avail Use% Mounted on\n/dev/sdc 30G 26G 4.7G 85% /\n",
                                        cli_name => 'podman');
    my $t = join "\n", @l;
    like($l[0], qr/disk is full/, 'E: the first line says the disk is full, plainly');
    like($t, qr/4\.7G/, 'E: the free space is shown when known');
    like($t, qr/podman system df/, 'E: names podman system df');
    like($t, qr/podman image prune -a/, 'E: names the cleanup command');
    unlike(join("\n", ImagePrune::disk_full_lines()), qr/Free space in the machine/, 'E: no df, no df section');
    like(join("\n", ImagePrune::disk_full_lines(cli_name => 'docker')), qr/docker system df/, 'E: docker hosts get docker commands');
}

# ---------------------------------------------------------------------------
# F. launcher wiring, by source (never spawned)
# ---------------------------------------------------------------------------
{
    my $path = "$Bin/../../scripts/launcher.pl";
    open my $fh, '<:raw', $path or die "read $path: $!";
    my $src = do { local $/; <$fh> };
    close $fh;
    my ($bi)  = $src =~ /^(sub build_image \{\n.*?\n\}\n)/ms;
    my ($epi) = $src =~ /^(sub ensure_project_image \{\n.*?\n\}\n)/ms;
    ok(defined $bi && defined $epi, 'F: both build functions found');
    like($bi // '',  qr/image_build_ok.*_image_cleanup\(\{ repo => \$SandboxIdentity::ID.*kind => 'base'/s,
         'F: build_image cleans the base AFTER a successful build');
    like($epi // '', qr/project_image_build_ok.*_image_cleanup\(\{ repo => \$repo.*kind => 'project'/s,
         'F: ensure_project_image cleans the project repository AFTER a successful build');
    like($bi // '',  qr/podman build failed \(exit.*\n\s*_build_cause_lines\(\)/, 'F: the base build failure carries the cause');
    like($epi // '', qr/project image layer failed \(exit.*\n\s*_build_cause_lines\(\)/, 'F: the project build failure carries the cause');
    my ($cl) = $src =~ /^(sub _image_cleanup \{\n.*?\n\}\n)/ms;
    like($cl // '', qr/_bounded_quiet/, 'F: cleanup calls are bounded and can never fail the launch');
    my ($df) = $src =~ /^(sub _machine_df \{\n.*?\n\}\n)/ms;
    like($df // '', qr/if \(\$WINDOWS_FAMILY\) \{.*?'wsl'.*?\} else \{/s, 'F: Windows reads df through wsl, not podman machine ssh (NUL file)');
    like($src, qr/\$LAST_TEE_OUT = defined \$r->\{out\}/, 'F: _tee_system keeps the last podman output');
}

done_testing();
