#!/usr/bin/env perl
# 09-no-drive-root-strays.t — regression guard for the C:\c and C:\tmp leak.
#
# WHAT HAPPENED
#
# On 2026-06-12 a steward test run left 576 entries at the DRIVE ROOT: a full
# mirror of POSIX paths under C:\c (C:\c\Users\Public\steward-*\remote.git — a
# real bare git repo) plus leaked fixtures under C:\tmp. Cause: the suite keeps
# paths in POSIX `/c/...` form because msys-perl's file ops need that, then hands
# them to NATIVE git.exe. Native git cannot resolve a bare `/c/...` when MSYS
# arg-conversion is off, and Windows resolves the leading `/` against the current
# drive — so `/c/Users/Public/x` becomes `C:\c\Users\Public\x`, silently created.
#
# Arg-conversion is off exactly when MSYS2_ARG_CONV_EXCL=* is set, which the
# user-global CLAUDE.md RECOMMENDS as a belt-and-suspenders setting. So the
# hostile configuration is the documented one.
#
# The fix (e52bf17, 2026-06-15) is vault-sync.pl's git_path(): it rewrites
# `/c/...` to `C:/...` before every git call, which native git resolves whether
# or not MSYS rewrites it — independent of the env var rather than fighting it.
#
# WHAT THIS TEST DOES
#
# Runs a real vault flow (clone + git -C operations) with MSYS2_ARG_CONV_EXCL='*'
# deliberately set, then asserts the drive root is untouched. It asserts the flow
# SUCCEEDED first — a sentinel that passes because nothing ran is worthless.
#
# Windows-only for the sentinel; the git_path source guard runs everywhere.

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use StewardTest qw(ok is diag done_testing run_vs temproot make_machine
                   init_remote write_text path_exists vault_sync_script);
use File::Path qw(remove_tree);

my $WIN = ($^O =~ /^(MSWin32|cygwin|msys)$/) ? 1 : 0;

# Paths a mis-converted POSIX path would materialise at. Recorded BEFORE the
# flow runs: we must never delete one that already existed for other reasons.
my @SENTINELS = ('C:/c', 'C:/tmp');
my %pre_existing = map { $_ => (-e $_ ? 1 : 0) } @SENTINELS;

# ── source guard: the mechanism itself ──────────────────────────────
# Behavioural checks below prove the leak is absent TODAY. This proves the
# thing that prevents it is still wired, so a refactor that drops git_path()
# from a call site fails here rather than at the next drive-root litter.
{
    my $script = vault_sync_script();
    open my $fh, '<:raw', $script or die "cannot open $script: $!";
    my $src = do { local $/; <$fh> };
    close $fh;

    ok($src =~ /^sub\s+git_path\b/m,
       'vault-sync.pl still defines git_path() (the /c/... -> C:/... rewrite)');

    # Every `git -C <path>` must pass its path through git_path(). A bare -C
    # argument is precisely the shape that created C:\c\Users\Public\....
    my @bare;
    while ($src =~ /'-C',\s*([^\s,)]+)/g) {
        my $arg = $1;
        push @bare, $arg unless $arg =~ /^git_path\(/;
    }
    is(scalar(@bare), 0,
       "every `git -C` argument is wrapped in git_path() (found " . scalar(@bare) . " bare)")
        or diag("bare -C arguments: @bare");
}

# ── behavioural sentinel ────────────────────────────────────────────
# Set the hostile ambient value the global CLAUDE.md recommends. run_vs
# deliberately does NOT scrub it (see StewardTest) — leaving it set is what
# proves vault-sync.pl's own defence, rather than the harness hiding the bug.
$ENV{MSYS2_ARG_CONV_EXCL} = '*';

my $root   = temproot();
my $remote = init_remote($root);
my $home   = make_machine($root, 'home1');
my $proj   = "$root/proj";
mkdir $proj or die "mkdir $proj: $!";

# `init` performs the git clone whose argv carried the POSIX path in the
# original incident, so this alone exercises the critical call site.
# Check the EXIT CODE, not merely that stdout parsed as JSON: vault-sync.pl
# emits well-formed JSON on failure too, so a {json} truthiness check passes
# against a run that exited 1 (observed while mutation-testing this file).
my $init = run_vs($home, 'init', '--url', $remote);
ok($init->{exit} == 0 && $init->{json},
   'vault init succeeded with MSYS2_ARG_CONV_EXCL=* set')
    or diag("exit=$init->{exit} out=$init->{out}");

# A register + push additionally exercises the `git -C <vault>` paths.
my $hp = run_vs($home, 'host-memory-path', '--cwd', $proj);
if ($hp->{json} && $hp->{json}{memory_dir}) {
    write_text("$hp->{json}{memory_dir}/MEMORY.md", "drive-root sentinel\n");
}
my $reg = run_vs($home, 'register', '--fresh', '--cwd', $proj,
                 '--slug', 'sentinel', '--files', '_host-memory');
ok($reg->{exit} == 0 && $reg->{json},
   'vault register succeeded (exercises `git -C <vault>`)')
    or diag("exit=$reg->{exit} out=$reg->{out}");

# ── the assertion the incident would have failed ────────────────────
for my $s (@SENTINELS) {
    my $exists_now = -e $s ? 1 : 0;
    my $leaked = ($exists_now && !$pre_existing{$s}) ? 1 : 0;

    if (!$WIN) {
        ok(1, "$s: not applicable off Windows (drive-letter paths are meaningless here)");
        next;
    }

    ok(!$leaked, "$s was NOT created by the vault flow (no drive-root stray)")
        or diag("A POSIX path reached a native binary unconverted. This is the "
              . "2026-06-12 leak: `/c/...` resolved against the current drive as "
              . "`C:\\c\\...`. Check that every absolute path handed to git goes "
              . "through vault-sync.pl's git_path().");

    # Clean up ONLY what this run created, and only when it did not pre-exist.
    # Never remove a drive-root directory the test found already present.
    if ($leaked) {
        remove_tree($s, { safe => 1 });
        diag("removed the stray $s that this test run created");
    }
}

# Non-vacuity: if the flow silently no-opped, the sentinel above proves nothing.
ok($init->{exit} == 0, 'sentinel is non-vacuous: the vault flow actually ran (exit 0)')
    or diag("init exited $init->{exit}; the drive-root assertions above are meaningless");

done_testing();
