#!/usr/bin/env perl
# platform: any
# Fix-batch B2/B3 (redteam-step6.md HIGH-3, MEDIUM-4) coverage for
# scripts/_install-bin-helper.pl (repo root -- out of package 04's write
# set, fixed in place per .ccpraxis-local-data/guidance/
# fix-ccpraxis-defects-in-place.md).
#
# B2 (HIGH-3): a failed powershell.exe read of the User PATH used to be
# silently laundered into "PATH is empty", after which a subsequent write
# could overwrite the ENTIRE User-scope PATH registry value with just the
# new bin dir -- with no snapshot to recover from. Fixed: ps_get_env now
# checks the child's exit status and dies rather than returning empty; and
# run_windows snapshots the current PATH to ~/.claude/.path-snapshots/
# before its first registry write.
#
# B3 (MEDIUM-4): glob() word-splits its pattern on whitespace, so any
# install path containing a space silently returned the wrong/empty
# @launchers list, disabling chmod + extensionless-alias creation with no
# error. Fixed: File::Glob::bsd_glob.
#
# ISOLATION. Never touches this host's real Windows PATH/registry. B2's
# tests intercept powershell.exe via the CCPRAXIS_TEST_POWERSHELL_GET_ARGV
# / CCPRAXIS_TEST_POWERSHELL_SET_ARGV testability seams (added by this same
# fix, inert unless set) rather than a real fake .exe -- a batch/script file
# named *.exe is not a valid Win32 application and would make `open` fail
# for the wrong reason. B3's test forces $^O to force the file-based
# run_unix branch, same technique as bp-commands-on-path.t's AC4/AC8 (never
# reaches run_windows/the registry). $HOME is always overridden to an
# isolated tempdir, so a real snapshot write (B2) never touches the real
# ~/.claude/.path-snapshots/.
#
# Runs standalone: perl this file
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Spec;

my $HELPER = "$Bin/../../../../scripts/_install-bin-helper.pl";
ok(-f $HELPER, 'sanity: _install-bin-helper.pl exists')
    or BAIL_OUT('_install-bin-helper.pl is missing');

sub slurp {
    my ($p) = @_;
    open my $fh, '<:raw', $p or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

# Runs the helper's top-level code via `do`, with $^O/$ENV{HOME}/@ARGV/the
# powershell-argv testability env vars all locally overridden -- identical
# harness shape to bp-commands-on-path.t's AC4/AC8 blocks. Captures STDOUT.
# Returns (stdout, ok-without-dying, $@).
sub run_helper {
    my (%opt) = @_;
    local $ENV{HOME} = $opt{home};
    local $^O = $opt{os} // 'cygwin';
    local @ARGV = ($opt{mode} // 'apply', $opt{bindir});
    local $ENV{CCPRAXIS_TEST_POWERSHELL_GET_ARGV} = $opt{get_argv};
    local $ENV{CCPRAXIS_TEST_POWERSHELL_SET_ARGV} = $opt{set_argv};
    delete $ENV{CCPRAXIS_TEST_POWERSHELL_GET_ARGV} unless defined $opt{get_argv};
    delete $ENV{CCPRAXIS_TEST_POWERSHELL_SET_ARGV} unless defined $opt{set_argv};

    my ($ofh, $ofile) = File::Temp::tempfile(UNLINK => 1);
    open(my $saved_stdout, '>&', \*STDOUT) or die $!;
    open(STDOUT, '>&', $ofh) or die $!;
    # DELIBERATELY NOT `eval { do $HELPER; 1 }` -- that is a documented Perl
    # gotcha: `do FILE` traps its own die internally and sets $@ WITHOUT
    # propagating an exception to an enclosing eval, so the enclosing eval
    # completes "successfully" and CLEARS $@ back to '' at exit, silently
    # erasing the very failure this test exists to detect. Check $@
    # immediately after the bare `do`, before anything else can touch it.
    no warnings 'redefine'; # `do`-ing the same file more than once in-process
    my $ret = do $HELPER;
    my $ok  = defined $ret;
    my $err = $@;
    open(STDOUT, '>&', $saved_stdout) or die $!;
    close $ofh;
    my $out = slurp($ofile) // '';
    return ($out, $ok, $err);
}

# ===========================================================================
# B2(i) -- a simulated powershell-read-failure aborts rather than proceeding.
# ===========================================================================
{
    my $home   = tempdir(CLEANUP => 1);
    my $bindir = tempdir(CLEANUP => 1);
    # A fake "powershell" that always exits nonzero -- exercised via the
    # ARGV testability seam, never a real .exe.
    my $fail_argv = join("\x1f", $^X, '-e', 'exit 1;');

    my ($out, $ok, $err) = run_helper(
        home => $home, bindir => $bindir, os => 'cygwin',
        get_argv => $fail_argv,
    );
    ok(!$ok, 'B2(i): a failed powershell PATH read makes the install run die, not proceed')
        or diag("  helper completed without dying; stdout was: [$out]");
    like($err, qr/powershell\.exe exited with status/,
        'B2(i): ...and the death message names the real cause (a read failure), not a '
      . 'downstream symptom')
        or diag("  err: [$err]");

    ok(!-d "$home/.claude/.path-snapshots" || !glob("$home/.claude/.path-snapshots/*"),
        'B2(i) non-vacuity: since the read failed before any write was attempted, no '
      . 'snapshot was written either -- the abort happens BEFORE the point a snapshot '
      . 'would even be needed');
}

# ===========================================================================
# B2(ii) -- on a SUCCESSFUL run that does reach the registry-write branch, a
# PATH snapshot is written to ~/.claude/.path-snapshots/ before the first
# simulated registry write.
# ===========================================================================
{
    my $home   = tempdir(CLEANUP => 1);
    my $bindir = tempdir(CLEANUP => 1);

    require MIME::Base64;
    my $fake_current_path = 'C:\\Windows\\system32;C:\\Windows';
    my $b64 = MIME::Base64::encode_base64($fake_current_path, '');
    # Fake "powershell" GET: prints the base64'd fake current PATH for any
    # query (PATH, PATHEXT/User, PATHEXT/Machine alike) -- good enough to
    # drive run_windows through its normal apply path without ever
    # shelling out to a real powershell.exe.
    my $get_argv = join("\x1f", $^X, '-e', "print '$b64';");
    # Fake "powershell" SET: always succeeds (exit 0), so ps_set_env never
    # dies and the run completes -- what we care about is snapshot-before-
    # write ORDERING, not the (mocked) write's own content.
    my $set_argv = join("\x1f", $^X, '-e', 'exit 0;');

    my ($out, $ok, $err) = run_helper(
        home => $home, bindir => $bindir, os => 'cygwin',
        get_argv => $get_argv, set_argv => $set_argv,
    );
    ok($ok, 'B2(ii) setup: the simulated-success run completes without dying')
        or diag("  died: $err");

    my @snaps = glob("$home/.claude/.path-snapshots/*.txt");
    ok(@snaps >= 1,
        'B2(ii): a PATH snapshot file was written under ~/.claude/.path-snapshots/ '
      . 'during a run that reaches the registry-write branch')
        or diag("  snapshot dir contents: " . join(', ', glob("$home/.claude/.path-snapshots/*")));

    if (@snaps) {
        my $content = slurp($snaps[0]) // '';
        is($content, $fake_current_path,
            'B2(ii): ...and the snapshot holds the PATH value that was actually current '
          . 'at the time of the write, not something stale or empty');
    }

    like($out, qr/snapshot:/,
        'B2(ii): the run\'s own stdout narrates the snapshot -- an operator watching '
      . '`apply` run sees it happened, not a silent side effect');
}

# ===========================================================================
# B3 -- glob("$bindir/*.sh") word-splits on whitespace; bsd_glob does not.
# Exercised via the file-based run_unix branch (never the registry), same
# isolation technique as bp-commands-on-path.t AC4/AC8: $^O forced to
# 'linux', $HOME an isolated tempdir.
# ===========================================================================
{
    my $home = tempdir(CLEANUP => 1);
    my $bindir = File::Spec->catdir(tempdir(CLEANUP => 1), 'a dir with spaces');
    mkdir $bindir or die "mkdir $bindir: $!";

    # A minimal, real, executable .sh launcher -- content is irrelevant,
    # only its presence/extension matters to this code path.
    my $launcher = "$bindir/bp-example.sh";
    open my $fh, '>', $launcher or die "write $launcher: $!";
    print {$fh} "#!/bin/bash\nexit 0\n";
    close $fh;
    chmod 0644, $launcher; # deliberately NOT executable yet -- apply should chmod it

    open(my $seed, '>', "$home/.bashrc") or die "seed .bashrc: $!";
    close $seed;

    my ($out, $ok, $err) = run_helper(
        home => $home, bindir => $bindir, os => 'linux',
    );
    ok($ok, 'B3 setup: an isolated apply run against a space-containing bindir completes')
        or diag("  died: $err");

    my $mode = (stat($launcher))[2];
    ok(defined($mode) && ($mode & 0100),
        'B3: the launcher under the space-containing path IS chmod +x -- bsd_glob found it '
      . '(the pre-fix glob() would have word-split the pattern and found nothing here)')
        or diag("  stat mode: " . (defined $mode ? sprintf('%o', $mode) : 'undef'));

    ok(-e "$bindir/bp-example",
        'B3: ...and the extensionless alias symlink was created too -- both effects that '
      . 'silently never happened pre-fix for any space-containing install path');
}

# ===========================================================================
# B4 -- the rc line names a directory that exists, and lands in a file the
# shell reads (macOS port, 2026-10-29). run_unix only, $^O forced.
#
#   (a) A bin dir outside $HOME used to become `$HOME//abs/path`: the strip of
#       the $HOME prefix matched nothing and "$HOME/" was prepended anyway.
#   (b) On macOS a login bash (what Terminal.app and iTerm2 start) reads the
#       first of .bash_profile/.bash_login/.profile and never .bashrc, so a
#       line appended to .bashrc never reached PATH.
# ===========================================================================
sub rc_after {
    my (%o) = @_;
    my $home = tempdir(CLEANUP => 1);
    my $bindir = $o{bindir_under_home} ? "$home/.claude/ccpraxis/plugins/x/bin" : tempdir(CLEANUP => 1) . '/bin';
    File::Path::make_path($bindir);
    for my $f (@{ $o{seed} || [] }) { open my $s, '>', "$home/$f" or die $!; print {$s} "# seeded\n"; close $s; }
    local $ENV{SHELL} = $o{shell};
    delete local $ENV{ZSH_VERSION};
    my ($out, $ok, $err) = run_helper(home => $home, bindir => $bindir, os => $o{os});
    ok($ok, "B4 setup ($o{label}): apply completes") or diag("  died: $err");
    my %rc = map { ($_ => slurp("$home/$_")) } grep { -f "$home/$_" } qw(.zshrc .bashrc .bash_profile .bash_login .profile);
    return (\%rc, $bindir, $home);
}
{
    require File::Path;
    my ($rc, $bindir) = rc_after(label => 'outside HOME', os => 'linux', shell => '/bin/zsh');
    unlike($rc->{'.zshrc'} // '', qr{\$HOME//}, 'B4(a): a bin dir outside $HOME never yields a $HOME// path');
    like($rc->{'.zshrc'} // '', qr{^export PATH="\Q$bindir\E:\$PATH"$}m, 'B4(a): ...it is written as its absolute path');

    ($rc, $bindir) = rc_after(label => 'under HOME', os => 'linux', shell => '/bin/zsh', bindir_under_home => 1);
    like($rc->{'.zshrc'} // '', qr{^export PATH="\$HOME/\.claude/ccpraxis/plugins/x/bin:\$PATH"$}m,
        'B4(a): a bin dir under $HOME stays $HOME-relative (unchanged)');

    ($rc) = rc_after(label => 'darwin bash, no rc', os => 'darwin', shell => '/bin/bash', bindir_under_home => 1);
    like($rc->{'.bash_profile'} // '', qr{^export PATH=}m, 'B4(b): darwin bash with no rc files writes .bash_profile');

    ($rc) = rc_after(label => 'darwin bash, .bashrc only', os => 'darwin', shell => '/bin/bash', bindir_under_home => 1, seed => ['.bashrc']);
    like($rc->{'.bash_profile'} // '', qr{^export PATH=}m, 'B4(b): darwin bash ignores .bashrc, which a login shell never reads');
    unlike($rc->{'.bashrc'} // '', qr{export PATH}, 'B4(b): ...and leaves .bashrc alone');

    ($rc) = rc_after(label => 'darwin bash, .profile', os => 'darwin', shell => '/bin/bash', bindir_under_home => 1, seed => ['.profile']);
    like($rc->{'.profile'} // '', qr{^export PATH=}m, 'B4(b): darwin bash with an existing .profile appends there');
    ok(!exists $rc->{'.bash_profile'}, 'B4(b): ...and does NOT create .bash_profile, which would stop .profile being read');

    ($rc) = rc_after(label => 'linux bash, .bashrc', os => 'linux', shell => '/bin/bash', bindir_under_home => 1, seed => ['.bashrc']);
    like($rc->{'.bashrc'} // '', qr{^export PATH=}m, 'B4: Linux bash keeps using .bashrc (unchanged)');
}

# ===========================================================================
# B5 -- never write inside a git work tree. A bin dir under a `.git` is
# tracked content: an install-time chmod or alias symlink there dirties the
# live install and makes the next promote refuse it. The helper reports what
# the repo must track instead. run_unix only, $^O forced.
# ===========================================================================
{
    my $home = tempdir(CLEANUP => 1);
    my $repo = tempdir(CLEANUP => 1);
    mkdir "$repo/.git" or die $!;
    File::Path::make_path("$repo/plugins/x/bin");
    my $bindir = "$repo/plugins/x/bin";
    my $launcher = "$bindir/bp-example.sh";
    open my $fh, '>', $launcher or die $!; print {$fh} "#!/bin/bash\nexit 0\n"; close $fh;
    chmod 0644, $launcher;
    open my $seed, '>', "$home/.bashrc" or die $!; close $seed;

    local $ENV{SHELL} = "/bin/bash";
    delete local $ENV{ZSH_VERSION};
    my ($out, $ok, $err) = run_helper(home => $home, bindir => $bindir, os => 'linux');
    ok($ok, 'B5 setup: apply inside a work tree completes') or diag("  died: $err");
    ok(!((stat($launcher))[2] & 0111), 'B5: the launcher was NOT chmod +x inside the work tree');
    ok(!-e "$bindir/bp-example" && !-l "$bindir/bp-example", 'B5: no alias symlink was created inside the work tree');
    like($out, qr/MISSING executable bit.*bp-example\.sh/, 'B5: the missing exec bit is reported');
    like($out, qr/MISSING tracked extensionless alias: bp-example\b/, 'B5: the missing alias is reported');
    like(slurp("$home/.bashrc") // '', qr/export PATH=/, 'B5: the PATH line is still written (it lives in $HOME, not the repo)');
}

done_testing();
