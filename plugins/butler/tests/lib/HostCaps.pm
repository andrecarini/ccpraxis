package HostCaps;
# HostCaps -- functional probes for host capabilities the butler oracles assume.
#
# WHY THIS EXISTS
#
# These oracles were written against the sandbox container: Linux, overlayfs,
# real POSIX signals, jq on PATH, /root writable, and no .ccpraxis-local-data
# anywhere above /tmp. Run the same files on the Windows host and they do not
# report "this cannot be checked here" -- they report FAILURE, or die outright
# and take every later assertion in the file down with them. Both are lies: the
# first says the code is broken when only the environment differs, and the
# second hides however many hundred assertions came after the die.
#
# The rule this module encodes: a capability the host genuinely lacks must
# produce a LOUD SKIP naming the uncovered ground, never a red assertion and
# never a dead file. A skip is honest -- it says "not checked here". A failure
# claims something false, and a die claims nothing at all.
#
# EVERY PROBE IS FUNCTIONAL, NOT DECLARATIVE. Asking `$^O` or "is the sub
# implemented" is exactly how this suite got its worst false signal: perl on
# Windows IMPLEMENTS symlink(), so `eval { symlink(...); 1 }` returns true --
# and then the call fails at runtime anyway. Probes here DO the thing in a
# throwaway directory and check the result.

use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(
    same_path signal_status_visible
    symlink_works chmod_works signals_work have_jq
    data_dir_ancestor native_tmp tempdir_args git_path
);

use File::Temp qw(tempdir);
use File::Spec;
use File::Path qw(make_path);
use Cwd qw(abs_path);

my %cache;

# --- native_tmp / tempdir_args --------------------------------------------
#
# A temp root that NATIVE Windows binaries can resolve. Several oracles
# `require` bp-orchestrator.pl (or bp-drive-next.pl / bp-usage-gate.pl), whose
# BEGIN block sets MSYS2_ARG_CONV_EXCL='*' -- disabling MSYS argv translation
# for the WHOLE test process from that line on. A bare tempdir() then yields
# /tmp/XXXX; perl resolves it, but `git -C /tmp/XXXX` hands git.exe a POSIX
# path that Windows resolves against the current DRIVE as C:\tmp\XXXX. That is
# the drive-root landmine documented in the user-global CLAUDE.md -- the one
# that left 576 stray entries and prompted steward's t/09.
#
# Opting out of conversion is only safe TOGETHER WITH hand-translating your own
# paths. This is the translation half: anchor in %TEMP%, already a C:/... path,
# so every derived path is correct under EITHER conversion state instead of
# depending on one.
sub native_tmp {
    return $cache{native_tmp} if exists $cache{native_tmp};
    my $t = $ENV{TEMP} // $ENV{TMP};
    $cache{native_tmp} =
        ($^O =~ /^(MSWin32|cygwin|msys)$/ && defined $t && length $t && -d $t)
            ? do { (my $p = $t) =~ s{\\}{/}g; $p }
            : undef;
    return $cache{native_tmp};
}

# Splice into a tempdir() call: tempdir(HostCaps::tempdir_args(), CLEANUP => 1)
#
# NOTE: prefer git_path() below for fixtures whose paths are also COMPARED
# against abs_path() results. Anchoring the tempdir itself in %TEMP% makes it a
# Windows-form path, while abs_path() on MSYS always returns POSIX form, so
# `is($got, "$ROOT/x")` starts failing on the path STYLE rather than on the
# behaviour under test. Measured: it silently broke four otherwise-correct
# assertions in t/22. Translate at the call site instead of at the source when
# the path has perl-side readers as well as native ones.
sub tempdir_args {
    my $base = native_tmp();
    return $base ? (DIR => $base) : ();
}

# --- git_path --------------------------------------------------------------
#
# The house translation (mirrors vault-sync.pl's git_path): rewrite a POSIX path
# into the forward-slash Windows form that git.exe and podman.exe both accept.
# Correct under EITHER MSYS conversion state, which is the whole point -- a test
# that `require`s bp-orchestrator.pl has conversion disabled from that line on,
# and one that does not still has it enabled. A path that works both ways cannot
# be broken by which modules a file happens to load.
#
#   /c/Users/x  -> C:/Users/x        (drive-letter rule, as in vault-sync.pl)
#   /tmp/abc    -> <native TEMP>/abc (MSYS maps /tmp to the Windows temp dir;
#                                     without this, git.exe resolves the leading
#                                     slash against the current DRIVE and looks
#                                     for C:\tmp\abc, which does not exist)
sub git_path {
    my $p = shift;
    return $p unless defined $p;
    return $p unless $^O =~ /^(MSWin32|cygwin|msys)$/;
    my $tmp = native_tmp();
    $p =~ s{^/tmp(?=/|\z)}{$tmp} if defined $tmp;
    $p =~ s{^/([a-zA-Z])(?=/|\z)}{uc($1) . ":"}e;
    return $p;
}

# --- same_path -------------------------------------------------------------
#
# Do two strings name the same directory? On Windows one path can be spelled
# several equally-valid ways -- C:/Users/ANDR~1/... (8.3 short name, what %TEMP%
# yields) and /c/Users/André/... (POSIX long name, what abs_path returns) are
# the SAME directory. An `is($got, $expected)` between two spellings compares
# spelling, not behaviour, and reports a defect where there is none. Resolve
# both through abs_path and compare that.
sub same_path {
    my ($a, $b) = @_;
    return 0 unless defined $a && defined $b;
    my $ra = abs_path($a) // $a;
    my $rb = abs_path($b) // $b;
    for ($ra, $rb) { s{\\}{/}g; s{/+$}{} }
    return ($^O =~ /^(MSWin32|cygwin|msys)$/) ? (lc($ra) eq lc($rb)) : ($ra eq $rb);
}

# --- symlink_works ---------------------------------------------------------
#
# Requires BOTH a link to a real directory AND a dangling link, because Windows
# needs to know the target type at creation time and fails ENOENT on a dangling
# one -- which is precisely the case the red-team groups exercise.
sub symlink_works {
    return $cache{symlink} if exists $cache{symlink};
    my $probe = tempdir(tempdir_args(), CLEANUP => 1);
    my $real  = File::Spec->catdir($probe, 'real');
    make_path($real);
    $cache{symlink} = eval {
        symlink($real, File::Spec->catdir($probe, 'to-real')) or die;
        symlink(File::Spec->catfile($probe, 'nope'), File::Spec->catdir($probe, 'dangling')) or die;
        (-l File::Spec->catdir($probe, 'to-real') && -l File::Spec->catdir($probe, 'dangling')) ? 1 : 0;
    } ? 1 : 0;
    return $cache{symlink};
}

# --- chmod_works -----------------------------------------------------------
#
# Several oracles assert permission-based isolation (a 0600 credential file, a
# jail that must deny reads). Those properties are meaningless where the
# filesystem does not carry POSIX modes: NTFS through Git-Bash perl accepts
# chmod and reports back whatever it likes. Write a file, chmod 0600, and
# require the mode to read back exactly -- anything else and the security
# property under test cannot be observed here at all.
sub chmod_works {
    return $cache{chmod} if exists $cache{chmod};
    my $probe = tempdir(tempdir_args(), CLEANUP => 1);
    my $f = File::Spec->catfile($probe, 'mode-probe');
    $cache{chmod} = eval {
        open my $fh, '>', $f or die;
        print {$fh} "x"; close $fh;
        chmod 0600, $f or die;
        my $mode = (stat $f)[2] & 07777;
        $mode == 0600 or die;
        # 0644 too: a filesystem that reports 0600 for everything would pass the
        # check above while carrying no real mode information at all.
        chmod 0644, $f or die;
        (((stat $f)[2] & 07777) == 0644) ? 1 : 0;
    } ? 1 : 0;
    return $cache{chmod};
}

# --- signals_work ----------------------------------------------------------
#
# The kill/SIGKILL/wait-status protocol the timeout and killed-subprocess groups
# rely on. Windows perl emulates fork with threads and has no real signals, so
# `kill 'KILL'` and the $? & 127 sentinel do not mean what those tests assert.
sub signals_work {
    return $cache{signals} if exists $cache{signals};
    $cache{signals} = 0;
    return 0 if $^O =~ /^MSWin32$/;
    my $ok = eval {
        my $pid = fork();
        return 0 unless defined $pid;
        if (!$pid) { sleep 30; POSIX_exit(); }
        kill('KILL', $pid) or do { waitpid($pid, 0); die };
        waitpid($pid, 0);
        (($? & 127) == 9) ? 1 : 0;
    };
    $cache{signals} = $ok ? 1 : 0;
    return $cache{signals};
}
# _exit without running END blocks (which would delete the caller's tempdirs).
sub POSIX_exit { eval { require POSIX; POSIX::_exit(0) }; exit 0 }

# --- signal_status_visible -------------------------------------------------
#
# Narrower than signals_work(), and the difference matters. signals_work()
# probes perl's own fork/kill/waitpid, which SUCCEEDS under MSYS. What several
# oracles actually depend on is different: spawn a shell-script child that kills
# ITSELF, and read a signal wait-status back through system(). Under MSYS that
# round trip does not survive — the parent sees an ordinary non-zero exit rather
# than ($? & 127), so a "$? >> 8 reads SIGKILL as 0" regression test cannot
# distinguish the bug from the fix.
#
# Probe the exact mechanism, not a nearby one: a self-killing shell script,
# observed through system().
sub signal_status_visible {
    return $cache{sigstat} if exists $cache{sigstat};
    $cache{sigstat} = 0;
    my $probe = tempdir(tempdir_args(), CLEANUP => 1);
    my $sh = File::Spec->catfile($probe, 'selfkill.sh');
    if (open my $fh, '>', $sh) {
        print {$fh} "#!/bin/sh\nkill -KILL \$\$\nsleep 5\n";
        close $fh;
        chmod 0755, $sh;
        system('/bin/sh', $sh);
        $cache{sigstat} = (($? != -1) && (($? & 127) == 9)) ? 1 : 0;
    }
    return $cache{sigstat};
}

# --- have_jq ---------------------------------------------------------------
#
# The shell hooks (ledger-guard.sh, wait-shape-guard.sh, bp-lib.sh's
# require_cmd) hard-depend on jq. It ships in the container and not on this
# Windows host. Probe by RUNNING it, not by scanning PATH -- a jq on PATH that
# cannot execute is the same as no jq.
sub have_jq {
    return $cache{jq} if exists $cache{jq};
    my $out = `jq --version 2>/dev/null`;
    $cache{jq} = (defined $out && $out =~ /jq/) ? 1 : 0;
    return $cache{jq};
}

# --- data_dir_ancestor -----------------------------------------------------
#
# Returns the nearest ancestor of $dir containing .ccpraxis-local-data, or
# undef. Tests asserting that <data> resolution FAILS presume a scratch dir with
# no such ancestor. On this host that presumption is false in both temp layouts:
# Git-Bash maps /tmp under C:\Users\<user>\, and %TEMP% is under it too, so a
# real ~/.ccpraxis-local-data makes the walk-up legitimately succeed. Such a
# test is not failing -- its premise is.
sub data_dir_ancestor {
    my ($dir) = @_;
    return undef unless defined $dir;
    $dir = abs_path($dir) // $dir;
    while (1) {
        return $dir if -d File::Spec->catdir($dir, '.ccpraxis-local-data');
        my $parent = abs_path(File::Spec->catdir($dir, File::Spec->updir));
        last if !defined $parent || $parent eq $dir;
        $dir = $parent;
    }
    return undef;
}

1;
