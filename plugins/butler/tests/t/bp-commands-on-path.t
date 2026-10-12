#!/usr/bin/env perl
# platform: any
# Oracle for blueprint butler-gate-ergonomics, package 04-bp-on-path.
# Derived from
# .ccpraxis-local-data/blueprints/butler-gate-ergonomics/specs/04-bp-on-path-spec.md
#
# AC1 shims exist under plugins/butler/bin/ for bp-drive-next, bp-ledger and
#     bp-dispatch-log, executable, and structurally match bp-drive-next.sh's
#     shape (BASH_SOURCE resolution, missing-script diagnostic, `exec perl
#     ... "$@"` tail). The bp-watch and bp-continuity shims (and their .pl
#     targets) were deleted by package 16 batch E1.
# AC2 each shim's stdout+exit code byte-match the direct
#     `perl plugins/butler/scripts/<name>.pl` invocation, for one cheap
#     read-only verb per script.
# AC3 a shim invoked via its absolute path from an unrelated cwd still
#     resolves (BASH_SOURCE-based, not cwd-relative).
# AC4 `_install-bin-helper.pl` PATH wiring is idempotent -- applying twice
#     does not duplicate a PATH entry.
# AC5 nothing in the touched files writes to a PATH-shaped file/profile/
#     registry directly -- only ever reaches scripts/_install-bin-helper.pl.
# AC6 plugins/backpack/tests/t/bin-dirs-validation.t and bin-dirs-security.t
#     are pre-existing regression guards (test_paths), unmodified here -- run
#     them separately post-implementation. No assertions for AC6 live in this
#     file by design (see package instructions: do not edit those files).
# AC7 a sandbox-shaped fixture -- bin/+scripts/ copied to a throwaway tempdir
#     at a different absolute path than this repo -- proves the shim does
#     not hardcode any host-specific path (the c724d0d regression).
#
# SAFETY NOTE ON AC4. This host's perl reports $^O eq 'cygwin', so
# _install-bin-helper.pl's `apply` mode would write to the REAL Windows User
# PATH registry via powershell.exe -- exactly what the blueprint's BINDING
# SAFETY CONSTRAINT (and the user-global CLAUDE.md "Modifying the Windows
# User PATH" section) forbid an unattended process from touching. This file
# therefore never invokes the helper's real Windows registry branch. Instead
# it exercises the file-based `run_unix` branch END TO END (real appends,
# real "already present" detection, real idempotency check) by `do`-ing the
# helper script with $^O and $ENV{HOME} both locally overridden to an
# isolated tempdir -- never touching this host's real PATH by any path. See
# the AC4 block below for the full reasoning.
#
use strict;
use warnings;

# A test must never actuate a real wake-lock (test-wakelock-hygiene.t).
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Copy qw(copy);
use Cwd qw(getcwd);

my $PLUGIN  = "$Bin/../..";                     # plugins/butler
my $BIN_DIR = "$PLUGIN/bin";
my $SCRIPTS = "$PLUGIN/scripts";
my $REPO    = "$Bin/../../../..";                # repo root
my $HELPER  = "$REPO/scripts/_install-bin-helper.pl";

# The template shim used to be the old continuity CLI's shim; package 16
# batch E1 deleted it (and the old bin/ hold shim, and its perl script) along
# with the rest of the old continuity path. bp-drive-next.sh is structurally identical (same
# BASH_SOURCE resolution, same missing-script diagnostic, same exec tail) and
# survives the cutover, so it is the template now.
ok(-f "$BIN_DIR/bp-drive-next.sh", 'sanity: the template shim this oracle is derived from exists')
    or BAIL_OUT('bp-drive-next.sh is missing -- nothing below can be judged against it');
ok(-f $HELPER, 'sanity: the shared PATH helper this package must delegate to exists')
    or BAIL_OUT('_install-bin-helper.pl is missing');

my @NAMES = qw(bp-drive-next bp-ledger bp-dispatch-log);

sub slurp {
    my ($p) = @_;
    open my $fh, '<:raw', $p or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

my $HAVE_BASH;
sub have_bash {
    unless (defined $HAVE_BASH) {
        my $v = `bash -c "echo ok" 2>&1`;
        $HAVE_BASH = (($v // '') =~ /ok/) ? 1 : 0;
        diag('bash unavailable -- shim execution assertions (AC2/AC3/AC7) are not running')
            unless $HAVE_BASH;
    }
    return $HAVE_BASH;
}

# Runs an external command, feeding it an optional stdin string, capturing
# stdout and stderr SEPARATELY (so AC2 can compare each independently) plus
# the exit code. $stdin undef means "inherit /dev/null". Never dies on a
# spawn failure -- CORE::exit(126/127) in the child surfaces as a distinct
# exit code instead, so a broken invocation shows up as a failing assertion
# rather than aborting the rest of the file.
sub run_out_err_rc {
    my ($cmd, $stdin) = @_;
    my ($efh, $efile) = File::Temp::tempfile(UNLINK => 1);
    close $efh;
    my $ifile;
    if (defined $stdin) {
        my $ifh;
        (undef, $ifile) = File::Temp::tempfile(UNLINK => 1);
        open($ifh, '>', $ifile) or die "write $ifile: $!";
        print $ifh $stdin;
        close $ifh;
    }
    my $pid = open(my $fh, '-|');
    die "fork failed: $!" unless defined $pid;
    if ($pid == 0) {
        if (defined $ifile) {
            open(STDIN, '<', $ifile) or CORE::exit(126);
        } else {
            open(STDIN, '<', '/dev/null') or CORE::exit(126);
        }
        open(STDERR, '>', $efile) or CORE::exit(126);
        exec(@$cmd);
        CORE::exit(127);
    }
    my $out;
    { local $/; $out = <$fh>; }
    close $fh;
    my $rc = $? >> 8;
    my $err = slurp($efile) // '';
    return ($out // '', $err, $rc);
}

# ===========================================================================
# AC1 -- existence, executable bit, structural match to the old continuity shim.
# ===========================================================================
{
    my $template = slurp("$BIN_DIR/bp-drive-next.sh");
    ok(defined $template, 'AC1 template bp-drive-next.sh is readable')
        or BAIL_OUT('cannot read the template shim');

    for my $name (@NAMES) {
        my $sh = "$BIN_DIR/$name.sh";
        unless (ok(-f $sh, "AC1 $name.sh exists under plugins/butler/bin/")) {
            fail("AC1 $name.sh: executable bit skipped -- file does not exist");
            fail("AC1 $name.sh: structural-match skipped -- file does not exist");
            next;
        }

        my $mode = (stat($sh))[2];
        ok(defined($mode) && ($mode & 0100), "AC1 $name.sh has the user-execute bit set");

        my $content = slurp($sh);
        unless (ok(defined $content, "AC1 $name.sh is readable")) {
            fail("AC1 $name.sh: structural-match skipped -- unreadable");
            next;
        }

        like($content, qr/^#!\/bin\/bash/m, "AC1 $name.sh: #!/bin/bash shebang");
        like($content, qr/^set -e/m, "AC1 $name.sh: set -e (matches template's fail-fast)");
        like(
            $content,
            qr/BIN_DIR=\$\(cd -P "\$\(dirname "\$\{BASH_SOURCE\[0\]\}"\)" && pwd -P\)/,
            "AC1 $name.sh: resolves its own dir via BASH_SOURCE[0], physically (-P, symlink-safe -- never \$HOME, never a hardcoded path)"
        );
        like(
            $content,
            qr/SCRIPT=\$\(cd -P "\$BIN_DIR\/\.\." && pwd -P\)\/scripts\/\Q$name\E\.pl/,
            "AC1 $name.sh: locates the sibling ../scripts/$name.pl relative to BIN_DIR, physically resolved"
        );
        like(
            $content,
            qr/^if \[ -z "\$\{BASH_VERSION:-\}" \]; then exec bash "\$0" "\$@"; fi/m,
            "AC1 $name.sh: dash safety net -- re-execs under bash if invoked via a non-bash sh"
        );
        like(
            $content,
            qr/if \[ ! -f "\$SCRIPT" \]; then/,
            "AC1 $name.sh: has the missing-script diagnostic guard"
        );
        like(
            $content,
            qr/\Q$name.pl\E not found at \$SCRIPT/,
            "AC1 $name.sh: missing-script diagnostic names $name.pl (not a copy-pasted message from the old continuity CLI)"
        );
        like($content, qr/exit 1/, "AC1 $name.sh: the missing-script branch exits 1");
        like(
            $content,
            qr/exec perl "\$SCRIPT" "\$@"/,
            "AC1 $name.sh: execs perl on the resolved script, forwarding argv, replacing the shell process"
        );

        # Negative-space: guards against a shim that was copy-pasted without
        # updating BOTH the exec target and the diagnostic -- a shim that still
        # names bp-drive-next.pl anywhere (its own name aside) is wrong even
        # if the mechanical shape above matches.
        unlike(
            $content,
            qr/bp-drive-next\.pl/,
            "AC1 $name.sh: does not still reference bp-drive-next.pl anywhere (fully substituted, not partially)"
        ) unless $name eq 'bp-drive-next';
    }
}

# ===========================================================================
# AC2 -- shim output byte-matches the direct `perl <name>.pl` invocation, for
# one cheap read-only verb per script.
# ===========================================================================
SKIP: {
    skip 'bash unavailable on this host', 1 unless have_bash();

    my $tmp = tempdir(CLEANUP => 1);

    # One (args, note) pair per script -- picked to be read-only and cheap.
    # bp-drive-next: --help is a pure usage dump, exit 0, no disk touch.
    # bp-ledger: `validate --stdin` IS the real read-only verb; fed empty
    #   stdin it deterministically reports "no parseable frontmatter" and
    #   exits 2 -- a real read-only path, not a fabricated invalid one.
    # bp-dispatch-log: `list --root <empty dir>` is read-only and
    #   deterministically empty / exit 0.
    my %verbs = (
        'bp-drive-next'  => { args => ['--help'],                         stdin => undef },
        'bp-ledger'      => { args => ['validate', '--stdin'],            stdin => '' },
        'bp-dispatch-log'=> { args => ['list', '--root', "$tmp/dispatch"],stdin => undef },
    );
    mkdir "$tmp/dispatch";

    for my $name (@NAMES) {
        my $sh   = "$BIN_DIR/$name.sh";
        my $pl   = "$SCRIPTS/$name.pl";
        my $spec = $verbs{$name};

        unless (ok(-f $sh, "AC2 $name.sh exists (precondition for comparison)")) {
            fail("AC2 $name: comparison skipped -- shim missing");
            next;
        }
        ok(-f $pl, "AC2 $name.pl exists (comparison baseline)")
            or do { fail("AC2 $name: comparison skipped -- .pl target missing"); next };

        my ($shim_out, $shim_err, $shim_rc)   = run_out_err_rc(['bash', $sh, @{ $spec->{args} }], $spec->{stdin});
        my ($direct_out, $direct_err, $direct_rc) = run_out_err_rc([$^X, $pl, @{ $spec->{args} }], $spec->{stdin});

        is($shim_out, $direct_out, "AC2 $name: stdout byte-identical (shim vs. direct perl)")
            or diag("  shim:   [$shim_out]\n  direct: [$direct_out]");
        is($shim_rc, $direct_rc, "AC2 $name: exit code identical (shim vs. direct perl)")
            or diag("  shim rc=$shim_rc direct rc=$direct_rc");
    }
}

# ===========================================================================
# AC3 -- a shim invoked via its absolute path from an unrelated cwd resolves.
# ===========================================================================
SKIP: {
    skip 'bash unavailable on this host', 2 unless have_bash();

    my $othercwd = tempdir(CLEANUP => 1);
    my $name = 'bp-drive-next';
    my $sh   = "$BIN_DIR/$name.sh";

    unless (-f $sh) {
        fail('AC3: skipped -- bp-drive-next.sh does not exist yet');
        fail('AC3: skipped -- bp-drive-next.sh does not exist yet (2nd assertion)');
        last;
    }

    my $cwd = getcwd();
    chdir $othercwd or die "chdir $othercwd: $!";
    my ($out, $err, $rc) = run_out_err_rc(['bash', $sh, '--help'], undef);
    chdir $cwd;

    is($rc, 0, 'AC3: shim invoked via absolute path from an unrelated cwd still exits 0');
    like($out, qr/bp-drive-next\.pl/, 'AC3: ...and its output is the real script output, not a "not found" error')
        or diag("  out: [$out]\n  err: [$err]");
}

# ===========================================================================
# AC4 -- PATH wiring via _install-bin-helper.pl is idempotent: applying
# twice does not duplicate a PATH entry.
#
# Exercised via the helper's file-based `run_unix` branch (real appends,
# real detection), with $^O and $ENV{HOME} both overridden to an isolated
# tempdir, so this NEVER touches the real Windows User PATH registry that
# `apply` would otherwise reach on this host ($^O eq 'cygwin' here). See the
# file header for the full safety reasoning.
# ===========================================================================
{
    my $fake_home = tempdir(CLEANUP => 1);
    my $bindir    = tempdir(CLEANUP => 1); # stands in for plugins/butler/bin

    # Pre-seed an empty .bashrc so the helper's own rc-selection logic
    # (".bashrc if present, else .profile") deterministically picks .bashrc
    # -- the common real-world case -- rather than this test depending on
    # which fallback the helper happens to choose for a bare-empty $HOME.
    open(my $seed, '>', "$fake_home/.bashrc") or die "seed .bashrc: $!";
    close $seed;

    my $run = sub {
        my ($mode) = @_;
        local $ENV{HOME} = $fake_home;
        local $^O = 'linux'; # force the file-based branch; never the registry one
        local @ARGV = ($mode, $bindir);
        my $capture;
        my ($ofh, $ofile) = File::Temp::tempfile(UNLINK => 1);
        open(my $saved_stdout, '>&', \*STDOUT) or die $!;
        open(STDOUT, '>&', $ofh) or die $!;
        my $ok = do {
            no warnings 'redefine'; # `do`-ing the same file twice in-process
            eval { do $HELPER; 1 };
        };
        my $err = $@;
        open(STDOUT, '>&', $saved_stdout) or die $!;
        close $ofh;
        $capture = slurp($ofile) // '';
        return ($capture, $ok, $err);
    };

    my ($out1, $ok1, $err1) = $run->('apply');
    ok($ok1, 'AC4: first isolated apply run completes without dying')
        or diag("  died: $err1");

    my $bashrc = "$fake_home/.bashrc";
    ok(-f $bashrc, 'AC4: first apply writes the isolated fake $HOME/.bashrc')
        or diag('  the helper is expected to persist a PATH fragment via the shell rc file '
              . '(run_unix branch) -- read _install-bin-helper.pl to confirm the artifact shape '
              . 'if this fails for a reason other than "no rc file written at all"');

    my $content_after_1 = slurp($bashrc) // '';
    my $count_after_1   = () = $content_after_1 =~ /export PATH=/g;
    is($count_after_1, 1, 'AC4: exactly one PATH export line after the first apply');

    my ($out2, $ok2, $err2) = $run->('apply');
    ok($ok2, 'AC4: second isolated apply run completes without dying')
        or diag("  died: $err2");

    my $content_after_2 = slurp($bashrc) // '';
    my $count_after_2   = () = $content_after_2 =~ /export PATH=/g;
    is($count_after_2, 1, 'AC4: STILL exactly one PATH export line after a second, repeated apply -- idempotent, not duplicated')
        or diag("  bashrc content:\n$content_after_2");

    like($out2, qr/already present/i, 'AC4: the second apply reports "already present" rather than re-appending');
}

# ===========================================================================
# AC8 -- Done-criterion assertion (fix-batch addition, MEDIUM-2's test-gap
# half): after a real (isolated, file-based) install, `command -v
# bp-<name>.sh` genuinely resolves on PATH -- the ".sh" spelling specifically,
# per the ledger's 2026-09-22 re-ratified Done criteria (a bare/extensionless
# claim is NOT made here; run_unix only symlinks the extensionless alias as a
# bonus, and this package's Done criterion was narrowed to the .sh spelling
# on every platform). Reuses AC4's isolation technique (fake $HOME, $^O
# forced to 'linux' so only the file-based run_unix branch executes) --
# never touches the real Windows PATH/registry. Additive only: does not
# alter any AC1-AC7 assertion.
# ===========================================================================
SKIP: {
    skip 'bash unavailable on this host', 1 unless have_bash();

    my $fake_home = tempdir(CLEANUP => 1);
    # Nested INSIDE $fake_home, mirroring the real-world layout (the real
    # bindir lives under the real $HOME too) -- the helper's rc line is
    # $HOME-relative (`$bindir_rel =~ s|^\Q$home\E/?||`), so a bindir OUTSIDE
    # $HOME would not be stripped and would produce a bogus doubled path
    # (a separate, pre-existing, out-of-scope defect noted by red-team as
    # "adjacent, lower impact" -- not one this fix-batch is scoped to fix).
    my $bindir = "$fake_home/plugins/butler/bin"; # stands in for plugins/butler/bin
    mkdir "$fake_home/plugins" or die $!;
    mkdir "$fake_home/plugins/butler" or die $!;
    mkdir $bindir or die $!;

    open(my $seed, '>', "$fake_home/.bashrc") or die "seed .bashrc: $!";
    close $seed;

    # Copy the REAL shims (as built by this package) into the isolated
    # bindir, so `apply`'s glob("$bindir/*.sh") + chmod + symlink logic has
    # real files to act on, and the subsequently-sourced PATH genuinely
    # fronts a directory containing bp-drive-next.sh et al.
    for my $name (@NAMES) {
        my $src = "$BIN_DIR/$name.sh";
        next unless -f $src;
        copy($src, "$bindir/$name.sh") or die "copy $src -> $bindir: $!";
        chmod 0755, "$bindir/$name.sh";
    }

    {
        local $ENV{HOME} = $fake_home;
        local $^O = 'linux'; # force the file-based branch; never the registry one
        local @ARGV = ('apply', $bindir);
        my ($ofh, $ofile) = File::Temp::tempfile(UNLINK => 1);
        open(my $saved_stdout, '>&', \*STDOUT) or die $!;
        open(STDOUT, '>&', $ofh) or die $!;
        eval { do $HELPER; 1 };
        my $err = $@;
        open(STDOUT, '>&', $saved_stdout) or die $!;
        close $ofh;
        diag("AC8: isolated apply run for PATH-resolution check died: $err") if $err;
    }

    # Spawn a real bash with a SCRUBBED environment (env -i): a minimal PATH
    # (just enough for bash/command themselves) and HOME pointed at the
    # isolated fixture -- deliberately NOT a login shell (`-l`), since Git
    # Bash's login-shell /etc/profile rebuilds PATH from the real Windows
    # registry and would silently re-admit this host's REAL (already
    # installed) bp-continuity, making the assertion pass for the wrong
    # reason. A plain, scrubbed, non-login shell that only sources the
    # fixture's own .bashrc is the actually-isolated check.
    for my $name (@NAMES) {
        my $probe = "env -i HOME=" . quotemeta($fake_home)
            . " PATH=/usr/bin:/bin bash -c 'source \$HOME/.bashrc >/dev/null 2>&1; command -v $name.sh'";
        my $resolved = `$probe`;
        chomp $resolved;
        like(
            $resolved,
            qr/\Q$name.sh\E$/,
            "AC8: after an isolated install, \`command -v $name.sh\` resolves on PATH "
          . "(Done criterion: the .sh spelling resolves after an install, every platform)"
        ) or diag("  command -v output: [$resolved]");
    }
}

# ===========================================================================
# AC5 -- no PATH-writing code introduced anywhere in this package's write set
# outside of calling scripts/_install-bin-helper.pl.
# ===========================================================================
{
    my @touched = ((map { "$BIN_DIR/$_.sh" } @NAMES), "$PLUGIN/ccpraxis-install.pl");
    for my $f (@touched) {
        unless (ok(-f $f, "AC5: $f exists (precondition for the direct-PATH-write scan)")) {
            fail("AC5: $f: PATH-write scan skipped -- file missing");
            next;
        }
        my $content = slurp($f) // '';
        unlike($content, qr/\.bashrc|\.zshrc|\.profile\b/,
            "AC5: $f does not reference a shell rc file directly");
        unlike($content, qr/SetEnvironmentVariable|Environment\]::/,
            "AC5: $f does not touch the Windows registry PATH directly");
        unlike($content, qr/>>\s*["']?\$?\{?ENV\{PATH\}|PATH\s*=.*:\$PATH/,
            "AC5: $f does not hand-assemble a PATH string itself");
    }
}

# ===========================================================================
# AC7 -- sandbox-shaped fixture: bin/+scripts/ copied to a throwaway tempdir
# at a DIFFERENT absolute path than this repo, proving the shim does not
# hardcode any host-specific path (the c724d0d regression).
# ===========================================================================
SKIP: {
    skip 'bash unavailable on this host', 1 unless have_bash();

    my $sandbox = tempdir(CLEANUP => 1);
    my $sbin    = "$sandbox/bin";
    my $sscripts = "$sandbox/scripts";
    mkdir $sbin    or die "mkdir $sbin: $!";
    mkdir $sscripts or die "mkdir $sscripts: $!";

    my @sh_files = glob("$BIN_DIR/*.sh");
    my @pl_files = glob("$SCRIPTS/*.pl");
    my @pm_files = glob("$SCRIPTS/*.pm");

    unless (@sh_files >= 3) {
        fail('AC7: skipped -- fewer than 3 shims exist under plugins/butler/bin/ to copy into the fixture');
        last;
    }

    for my $f (@sh_files, @pl_files, @pm_files) {
        my $base = (split m{[\\/]}, $f)[-1];
        my $dest = $f =~ /\.sh$/ ? "$sbin/$base" : "$sscripts/$base";
        copy($f, $dest) or die "copy $f -> $dest: $!";
        chmod 0755, $dest if $dest =~ /\.sh$/;
    }
    # Module subtrees too: bp-drive-next.pl requires scripts/BpHook/PromptWatch.pm,
    # and a top-level *.pm glob never reached it, so the fixture shim died with
    # "Can't locate .../BpHook/PromptWatch.pm" rather than testing resolution.
    require File::Find;
    require File::Path;
    File::Find::find({ no_chdir => 1, wanted => sub {
        return unless -f $_ && /\.pm\z/;
        (my $rel = $_) =~ s{\A\Q$SCRIPTS\E/}{};
        return unless $rel =~ m{/};                 # top level was copied above
        my $dest = "$sscripts/$rel";
        (my $ddir = $dest) =~ s{/[^/]+\z}{};
        File::Path::make_path($ddir) unless -d $ddir;
        copy($_, $dest) or die "copy $_ -> $dest: $!";
    } }, $SCRIPTS);

    ok(-d "$sandbox/bin" && -d "$sandbox/scripts",
        'AC7: sandbox-shaped fixture directory built (bin/ + scripts/ siblings, different absolute path)');

    my $name = 'bp-drive-next';
    my $shim = "$sbin/$name.sh";
    unless (-f $shim) {
        fail("AC7: skipped -- $name.sh was not among the copied shims");
        last;
    }

    my ($out, $err, $rc) = run_out_err_rc(['bash', $shim, '--help'], undef);
    is($rc, 0, 'AC7: the shim, run from an entirely different absolute path, still exits 0')
        or diag("  err: $err");
    like($out, qr/bp-drive-next\.pl/,
        'AC7: ...and resolves to the FIXTURE copy of the .pl script (proves BASH_SOURCE resolution, not a hardcoded repo path)')
        or diag("  out: [$out]\n  err: [$err]");
    unlike($out . $err, qr/\Q$Bin\E/,
        'AC7: nothing in the output leaks this real repo\'s own path (would indicate a hardcoded fallback)');
}

done_testing();
