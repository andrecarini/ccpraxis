#!/usr/bin/env perl
# platform: host
# The backup's two checkouts (plugins/steward/scripts/DevClone.pm): the live
# install is only read, the dev clone is where an export goes. Covers
#   A  DevClone::locate -- the dev clone is the live install's origin, valid
#      only as a local git work tree with a main branch that is not the live
#      install; a GitHub origin (a machine set up the old way) is not one.
#   B  DevClone::payload_check -- the dev clone's payload, at HEAD and in its
#      working tree, must equal the live install's committed payload.
#   C  ccpraxis-helpers.pl check-claude-md / install-claude-md and
#      sync-export.pl's CLAUDE.md item -- ~/.claude/CLAUDE.md is compared with
#      what promote.pl builds from the LIVE install's payload for this host.
#   D  sync-export.pl reads skills from the live install and the export
#      files from the dev clone.
#
# Fixtures: a throwaway HOME, a bare "GitHub" repo, a dev clone whose origin
# it is, and a live install cloned from the dev clone (so its origin is the
# dev clone, exactly as promote.pl leaves it). Nothing outside the temp root
# is touched.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use lib "$Bin/../../scripts";
use File::Path qw(make_path);
use File::Temp qw(tempfile);
use JSON::PP;
use Test::More;
use StewardTest qw(temproot make_machine init_remote write_text read_text);
use DevClone ();
use GlobalClaudeMd ();

my $S        = "$Bin/../../scripts";
my $HELPERS  = "$S/ccpraxis-helpers.pl";
my $SYNC     = "$S/sync-export.pl";
my $IS_WIN   = ($^O eq 'MSWin32' || $^O eq 'cygwin' || $^O eq 'msys') ? 1 : 0;

sub _native_path { my ($p) = @_; (my $q = $p) =~ s{\\}{/}g; $q =~ s{^/([A-Za-z])/}{\u$1:/}; return $q; }

my $HOME;   # set per fixture; git and the scripts both see it
sub _env {
    return (HOME => $HOME, USERPROFILE => $HOME, GIT_CONFIG_GLOBAL => "$HOME/.gitconfig",
            GIT_CONFIG_SYSTEM => '/dev/null', GIT_TERMINAL_PROMPT => '0');
}

sub git {
    my ($dir, @args) = @_;
    my %e = _env();
    local @ENV{ keys %e } = values %e;
    my @t = map { (defined $_ && m{^/}) ? _native_path($_) : $_ } @args;
    system('git', '-C', _native_path($dir), @t) == 0 or die "git -C $dir @args failed\n";
}

# Run a command, stderr to a real temp file; returns ($exit, $stdout, $stderr).
sub run {
    my ($extra, @cmd) = @_;
    my %e = (_env(), %{ $extra // {} });
    local @ENV{ keys %e } = values %e;
    my ($efh, $ename) = tempfile(UNLINK => 1);
    close $efh;
    open(my $saved, '>&', \*STDERR) or die;
    open(STDERR, '>', $ename) or die;
    my $out = '';
    if (open(my $fh, '-|', @cmd)) { local $/; $out = <$fh> // ''; close $fh; }
    my $rc = $? >> 8;
    open(STDERR, '>&', $saved);
    close $saved;
    return ($rc, $out, read_text($ename) // '');
}

sub json_of { my ($s) = @_; my $j = eval { decode_json($s) }; return $j; }

# fixture(%opts) -> { home, gh, clone, live }
sub fixture {
    my (%o) = @_;
    my $scratch = temproot();
    $HOME = make_machine($scratch, 'host');
    my $gh    = init_remote($scratch);
    my $clone = "$scratch/devclone";
    my $live  = "$HOME/.claude/ccpraxis";
    make_path($clone, "$HOME/.claude");
    git($clone, 'init', '-q', '-b', 'main');
    write_text("$clone/.gitignore", "*.pre-merge.*\n.backup-preferences.json\n");
    write_text("$clone/README.md", "# fixture\n");
    write_text("$clone/global-config/CLAUDE.md", "# shared\nevery host\n");
    write_text("$clone/global-config/CLAUDE.windows.md", "# windows part\nwin only\n");
    write_text("$clone/global-config/CLAUDE.macos.md", "# macos part\nmac only\n");
    write_text("$clone/global-config/settings.json", qq({"theme":"dark"}\n));
    write_text("$clone/plugins/sandbox/container/settings.json", "{}\n");
    write_text("$clone/skills/live-skill/SKILL.md", "---\nname: live-skill\n---\n");
    git($clone, 'add', '-A');
    git($clone, 'commit', '-q', '-m', 'fixture');
    git($clone, 'remote', 'add', 'origin', $gh);
    git($clone, 'push', '-q', '-u', 'origin', 'main');
    git($scratch, 'clone', '-q', $clone, $live);
    return { home => $HOME, gh => $gh, clone => $clone, live => $live, scratch => $scratch };
}

sub locate_in { my ($f, %a) = @_; my %e = _env(); local @ENV{ keys %e } = values %e; return DevClone::locate(live_root => $f->{live}, %a); }
sub check_in  { my ($f) = @_; my %e = _env(); local @ENV{ keys %e } = values %e; return DevClone::payload_check(live_root => $f->{live}, dev_clone => $f->{clone}); }

# ---------------------------------------------------------------------------
# A. locate
# ---------------------------------------------------------------------------
{
    my $f = fixture();
    my $loc = locate_in($f);
    ok(defined $loc->{dev_clone}, 'A1: the live install\'s origin (the dev clone) is located') or diag(explain $loc);
    ok(DevClone::same_dir($loc->{dev_clone} // '', $f->{clone}), 'A1: ...and it is the dev clone');
    is($loc->{source}, 'origin', 'A1: ...found through origin');

    git($f->{live}, 'remote', 'set-url', 'origin', 'https://github.com/someone/ccpraxis.git');
    $loc = locate_in($f);
    ok(!defined $loc->{dev_clone}, 'A2: an https origin (set up the old way) is not a dev clone');
    like($loc->{reason}, qr{https://github\.com/someone/ccpraxis\.git}, 'A2: the reason names the origin URL');
    like($loc->{fix}, qr/promote\.pl/, 'A2: the fix names promote.pl');

    git($f->{live}, 'remote', 'set-url', 'origin', 'git@github.com:someone/ccpraxis.git');
    ok(!defined locate_in($f)->{dev_clone}, 'A3: an scp-style origin is not a dev clone');

    git($f->{live}, 'remote', 'set-url', 'origin', 'file://' . _native_path($f->{clone}));
    $loc = locate_in($f);
    ok(defined $loc->{dev_clone} && DevClone::same_dir($loc->{dev_clone}, $f->{clone}),
        'A4: a file:// origin is the local path it spells') or diag(explain $loc);

    my $plain = "$f->{scratch}/not-a-repo";
    make_path($plain);
    git($f->{live}, 'remote', 'set-url', 'origin', $plain);
    $loc = locate_in($f);
    ok(!defined $loc->{dev_clone}, 'A5: an origin that is not a git work tree is not a dev clone');
    like($loc->{reason}, qr/not a git work tree/, 'A5: ...and the reason says so');

    my $nomain = "$f->{scratch}/no-main";
    make_path($nomain);
    git($nomain, 'init', '-q', '-b', 'trunk');
    write_text("$nomain/x", "x\n");
    git($nomain, 'add', '-A');
    git($nomain, 'commit', '-q', '-m', 'x');
    git($f->{live}, 'remote', 'set-url', 'origin', $nomain);
    $loc = locate_in($f);
    ok(!defined $loc->{dev_clone}, 'A6: a repo without a main branch is not a dev clone');
    like($loc->{reason}, qr/no main branch/, 'A6: ...and the reason says so');

    git($f->{live}, 'remote', 'set-url', 'origin', $f->{live});
    $loc = locate_in($f);
    ok(!defined $loc->{dev_clone}, 'A7: an origin pointing at the live install itself is refused');
    like($loc->{reason}, qr/live install itself/, 'A7: ...and the reason says so');

    git($f->{live}, 'remote', 'remove', 'origin');
    $loc = locate_in($f);
    ok(!defined $loc->{dev_clone}, 'A8: no origin, no dev clone');
    like($loc->{reason}, qr/no origin remote/, 'A8: ...and the reason says so');

    $loc = locate_in($f, override => $f->{clone});
    ok(defined $loc->{dev_clone} && $loc->{source} eq 'override', 'A9: BACKUP_CLONE_DIR overrides origin, still validated');
    $loc = locate_in($f, override => $plain);
    ok(!defined $loc->{dev_clone}, 'A9: ...and an invalid override is refused');
}

# ---------------------------------------------------------------------------
# B. payload_check
# ---------------------------------------------------------------------------
{
    my $f = fixture();
    my $c = check_in($f);
    is($c->{equal}, 1, 'B1: a freshly promoted pair has equal payloads') or diag(explain $c);

    write_text("$f->{clone}/README.md", "# fixture\nedited outside the payload\n");
    is(check_in($f)->{equal}, 1, 'B2: an uncommitted change outside the payload does not matter');

    write_text("$f->{clone}/global-config/settings.json", qq({"theme":"light"}\n));
    $c = check_in($f);
    is($c->{equal}, 0, 'B3: an uncommitted payload change in the dev clone makes them differ');
    is_deeply([ map { "$_->{path}|$_->{why}" } @{ $c->{differing} } ],
        [ 'global-config/settings.json|uncommitted in the dev clone' ], 'B3: ...naming the file and why');

    git($f->{clone}, 'commit', '-q', '-am', 'payload change, not promoted');
    $c = check_in($f);
    is($c->{equal}, 0, 'B4: a committed, unpromoted payload change makes them differ');
    is_deeply([ map { "$_->{path}|$_->{why}" } @{ $c->{differing} } ],
        [ 'global-config/settings.json|committed in the dev clone, not promoted' ], 'B4: ...naming the file and why');

    git($f->{live}, 'pull', '-q', '--ff-only', 'origin', 'main');
    is(check_in($f)->{equal}, 1, 'B5: once the live install has it (promotion), they are equal again');

    write_text("$f->{clone}/global-config/new-part.md", "new\n");
    $c = check_in($f);
    is($c->{equal}, 0, 'B6: an untracked file in global-config/ is a payload difference');
    unlink "$f->{clone}/global-config/new-part.md";

    write_text("$f->{clone}/plugins/sandbox/container/settings.json", qq({"x":1}\n));
    is(check_in($f)->{equal}, 0, 'B7: the container settings file is part of the payload');
    git($f->{clone}, 'checkout', '-q', '--', 'plugins/sandbox/container/settings.json');

    write_text("$f->{clone}/global-config/settings.json.pre-merge.123", "backup\n");
    is(check_in($f)->{equal}, 1, 'B8: an ignored file (a settings-export-merge pre-merge copy) is not a difference');
}

# ---------------------------------------------------------------------------
# C. CLAUDE.md: compared with the build of the LIVE install's payload
# ---------------------------------------------------------------------------
{
    my $f = fixture();
    my $build = GlobalClaudeMd::render_from_dir($f->{live});
    my $home_md = "$HOME/.claude/CLAUDE.md";
    my @roots = ('--live-root', $f->{live});

    # The dev clone carries a payload edit that is not live yet: it must not
    # be what ~/.claude/CLAUDE.md is compared with.
    write_text("$f->{clone}/global-config/CLAUDE.md", "# shared\nevery host\nnot promoted yet\n");

    write_text($home_md, $build);
    my ($rc, $out, $err) = run({}, $^X, $HELPERS, 'check-claude-md', @roots);
    my $j = json_of($out) // {};
    is($j->{status}, 'in_sync', 'C1: a regular file equal to the build of the live payload is in sync') or diag("$out$err");
    my $part = GlobalClaudeMd::host_part_relpath();
    if (defined $part) {
        like($build, qr/only\n\z/, "C1: (fixture) this host's build carries its part ($part)");
    }

    ($rc, $out) = run({}, $^X, $SYNC, '--live-root', $f->{live}, '--repo-root', $f->{clone});
    my $items = json_of($out) // [];
    my ($md) = grep { ($_->{file} // '') eq 'CLAUDE.md' } @$items;
    is($md->{status} // '', 'identical', 'C2: sync-export reports an in-sync CLAUDE.md as identical (no symlink expected)')
        or diag($out);
    is($md->{repo_file} // '', 'global-config/CLAUDE.md', 'C2: ...paired with global-config/CLAUDE.md, never the repo root');

    my $edited = $build;
    $edited =~ s/every host\n/every host\na hand edit \x{c3}\x{a9}\n/;
    write_text($home_md, $edited);
    ($rc, $out) = run({}, $^X, $HELPERS, 'check-claude-md', @roots);
    $j = json_of($out) // {};
    is($j->{status}, 'differs', 'C3: a hand edit makes it differ');
    is_deeply([ map { $_->{text} } @{ $j->{extra_lines} // [] } ], [ "a hand edit \x{e9}" ],
        'C3: the edited line is named (decoded once, not double-encoded)');
    is($j->{extra_lines}[0]{n}, 3, 'C3: ...with its line number');
    like($j->{resolve} // '', qr/dev clone's global-config\/CLAUDE\.md/, 'C3: the resolution says to fold it into the dev clone');

    ($rc, $out) = run({}, $^X, $SYNC, '--live-root', $f->{live}, '--repo-root', $f->{clone});
    ($md) = grep { ($_->{file} // '') eq 'CLAUDE.md' } @{ json_of($out) // [] };
    is($md->{status} // '', 'claude_md_differs', 'C4: sync-export reports the hand edit as claude_md_differs');
    is_deeply([ map { $_->{text} } @{ $md->{extra_lines} // [] } ], [ "a hand edit \x{e9}" ],
        'C4: ...carrying the same lines check-claude-md reports');

    ($rc, $out, $err) = run({}, $^X, $HELPERS, 'install-claude-md', @roots);
    $j = json_of($out) // {};
    is($j->{status}, 'rendered', 'C5: install-claude-md rebuilds it') or diag("$out$err");
    is(read_text($home_md), $build, 'C5: ...from the live install\'s payload, not the dev clone\'s');
    ok(defined $j->{backup} && -f $j->{backup}, 'C5: ...after a backup copy');
    is(read_text($j->{backup} // '/nonexistent'), $edited, 'C5: ...which holds the replaced bytes');
    like($j->{backup} // '', qr{/\.claude/\.promotion-backups/\d{8}-\d{6}(?:-\d+)?/CLAUDE\.md\z},
        'C5: ...in ~/.claude/.promotion-backups/<timestamp>/, as promote.pl does');

    ($rc, $out) = run({}, $^X, $HELPERS, 'install-claude-md', @roots);
    is((json_of($out) // {})->{status}, 'unchanged', 'C6: a second rebuild changes nothing');

    unless ($IS_WIN) {
        unlink $home_md;
        symlink("$f->{live}/global-config/CLAUDE.md", $home_md) or die "symlink: $!";
        ($rc, $out) = run({}, $^X, $HELPERS, 'check-claude-md', @roots);
        $j = json_of($out) // {};
        if (defined $part) {
            is($j->{status}, 'differs', 'C7: a link to the shared file is not enough on a host with a part');
        }
        else {
            is($j->{status}, 'linked', 'C7: a link to the shared file is the build on a host with no part');
        }

        my $other = "$f->{scratch}/elsewhere.md";
        write_text($other, "somebody else's file\n");
        unlink $home_md;
        symlink($other, $home_md) or die "symlink: $!";
        ($rc, $out) = run({}, $^X, $HELPERS, 'install-claude-md', @roots);
        is($rc, 1, 'C8: install-claude-md refuses a link to another file');
        ok(-l $home_md && readlink($home_md) eq $other, 'C8: ...and leaves the link alone');
    }
}

# ---------------------------------------------------------------------------
# D. sync-export: skills from the live install, export files from the dev clone
# ---------------------------------------------------------------------------
{
    my $f = fixture();
    write_text("$f->{clone}/skills/dev-only-skill/SKILL.md", "---\nname: dev-only-skill\n---\n");
    write_text("$HOME/.claude/settings.json", qq({"theme":"dark"}\n));
    my ($rc, $out, $err) = run({}, $^X, $SYNC, '--live-root', $f->{live}, '--repo-root', $f->{clone});
    is($rc, 0, 'D1: sync-export runs') or diag($err);
    my %by = map { ($_->{file} // '') => $_ } @{ json_of($out) // [] };
    ok(exists $by{'skills/live-skill'}, 'D1: a skill of the live install is checked');
    ok(!exists $by{'skills/dev-only-skill'}, 'D1: a skill only the dev clone has is not (it does not run)');
    is($by{'settings.json'}{status} // '', 'identical', 'D2: settings.json is compared with the dev clone\'s payload');

    write_text("$f->{clone}/global-config/settings.json", qq({"theme":"light"}\n));
    ($rc, $out) = run({}, $^X, $SYNC, '--live-root', $f->{live}, '--repo-root', $f->{clone});
    %by = map { ($_->{file} // '') => $_ } @{ json_of($out) // [] };
    is($by{'settings.json'}{status} // '', 'settings_changed', 'D2: ...a dev clone change shows up');

    # Defaults: --repo-root comes from the live install's origin.
    ($rc, $out, $err) = run({}, $^X, $SYNC);
    %by = map { ($_->{file} // '') => $_ } @{ json_of($out) // [] };
    is($by{'settings.json'}{status} // '', 'settings_changed', 'D3: without arguments the dev clone is the live install\'s origin')
        or diag("$out$err");
    git($f->{live}, 'remote', 'set-url', 'origin', 'https://github.com/someone/ccpraxis.git');
    ($rc, $out, $err) = run({}, $^X, $SYNC);
    is($rc, 2, 'D4: with a GitHub origin and no --repo-root there is nothing to compare against');
    like($err, qr/promote\.pl/, 'D4: ...and the error says how to fix it');
}

# ---------------------------------------------------------------------------
# E. settings-export-merge, selective (as the backup driver always runs it):
#    only the units sent to the payload change.
# ---------------------------------------------------------------------------
{
    my $f = fixture();
    write_text("$f->{clone}/global-config/settings.json",
        qq({"a":"payload-a","b":"payload-b","env":{"X":"px","Y":"py"},"gone":"payload-only"}\n));
    write_text("$HOME/.claude/settings.json",
        qq({"a":"live-a","b":"live-b","env":{"X":"lx","Y":"ly"},"newKey":"live-only"}\n));
    my @roots = ('--live-root', $f->{live}, '--repo-root', $f->{clone});
    my ($rc, $out, $err) = run({}, $^X, $HELPERS, 'settings-export-merge', @roots,
        '--only-key', 'a', '--only-key', 'env.X', '--remove-key', 'gone');
    is($rc, 0, 'E1: a selective merge runs') or diag("$out$err");
    my $j = json_of($out) // {};
    ok($j->{selective}, 'E1: ...and says it was selective');
    my $p = json_of(read_text("$f->{clone}/global-config/settings.json")) // {};
    is($p->{a}, 'live-a', 'E1: a key sent to the payload takes the ~/.claude value');
    is($p->{b}, 'payload-b', 'E1: a differing key NOT sent keeps the payload value');
    is($p->{env}{X}, 'lx', 'E1: a dotted unit sent to the payload takes the ~/.claude value');
    is($p->{env}{Y}, 'py', 'E1: its sibling unit, not sent, keeps the payload value');
    ok(!exists $p->{newKey}, 'E1: a ~/.claude-only key not sent stays out of the payload');
    ok(!exists $p->{gone}, 'E1: --remove-key drops a payload-only key');
    ($rc, $out) = run({}, $^X, $HELPERS, 'settings-export-merge', @roots, '--only-key', 'nosuch');
    is_deeply((json_of($out) // {})->{only_keys_unmatched}, [ 'nosuch' ], 'E2: an --only-key that matches nothing is reported');
}

# ---------------------------------------------------------------------------
# F. promote_outcome: exit 1 after the fast-forward is a promotion that
#    happened (with refusals to report); exit 2, or a live install that did
#    not move, is a stop.
# ---------------------------------------------------------------------------
{
    my $out = "merge: fast-forward a..b (1 commits)\nclaude-md: refused-local-edit 1 line(s) the payload never had\n  L3: x\n  resolve: fold ...\nsettings: unchanged\n";
    my $o = DevClone::promote_outcome(exit => 0, output => "merge: up-to-date\n", live_head_after => 'b', target => 'b');
    ok($o->{ok} && !defined $o->{reason}, 'F1: exit 0 is a promotion');
    $o = DevClone::promote_outcome(exit => 1, output => $out, live_head_after => 'b', target => 'b');
    ok($o->{ok}, 'F2: exit 1 with the live install at the target is a promotion');
    is_deeply($o->{refusals}, [ 'claude-md: refused-local-edit 1 line(s) the payload never had', '  L3: x', '  resolve: fold ...' ],
        'F2: ...whose refusal lines are kept');
    $o = DevClone::promote_outcome(exit => 1, output => $out, live_head_after => 'a', target => 'b');
    ok(!$o->{ok}, 'F3: exit 1 with the live install NOT at the target is a stop');
    $o = DevClone::promote_outcome(exit => 2, output => "merge: refused-dirty\n", live_head_after => 'b', target => 'b');
    ok(!$o->{ok}, 'F4: exit 2 is a stop');
    like($o->{reason}, qr/exited 2/, 'F4: ...naming the exit code');
    my @argv = DevClone::promote_argv(dev_clone => '/c', live_root => '/l', home => '/h', keep_keys => [ 'a', 'env.X' ], perl => 'perl');
    is(join(' ', @argv), 'perl /c/scripts/promote.pl --clone /c --live /l --home /h --keep-key a --keep-key env.X',
        'F5: promote_argv passes each kept key');
}

done_testing();
