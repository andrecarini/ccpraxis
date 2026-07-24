#!/usr/bin/env perl
# Tests for CcpraxisSelfHost — worktree provisioning module (p02).
#
# IMMUTABLE ORACLE: derived from the p02 spec, not from any implementation.
# All seams injected (no real repo/git/podman) except AC-13 (real fs) and
# AC-14 (structural grep of launcher.pl).
#
# Criterion mapping:
#   AC-1   : worktree_plan absent-state argv + branch + target
#   AC-2   : default_worktree_path override precedence + tilde expansion
#   AC-3   : blueprint_copy_plan exact src/dst pair
#   AC-4   : worktree_plan complete-state idempotent (needs_add=0, git_argv=[]) + provision_state complete
#   AC-5   : worktree_plan branch-exists-no-worktree (omits -b, needs_branch=0)
#   AC-6   : provision_state — all five fixture classifications
#   AC-7   : provision_repair_plan — absent / partial(lock+wrong-branch) / complete
#   AC-8   : fleet_live — container-running / fresh-marker / stale+down / undef-marker
#   AC-9   : structural — fleet_live no-clobber branch reaches re-exec with no provisioning ops between
#   AC-10  : André-byte paths round-trip byte-identical (!utf8::is_utf8)
#   AC-11  : RO-bind source == live_root/plugins, project-independent
#   AC-12  : selfhost_route(worktree, hint=live_root) eq 'passthrough'
#   AC-13  : real PluginSync::copy_tree — André-path, byte-for-byte identity
#   AC-14  : structural launcher.pl wiring assertions (t/09 grep style)
#   AC-15  : EXCLUDED (full-suite regression — driver step, not test-writer scope)

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

use CcpraxisSelfHost qw(
    default_worktree_path
    worktree_plan
    blueprint_copy_plan
    provision_state
    provision_repair_plan
    fleet_live
    selfhost_route
    canon_path
    live_install_dir
);
use PluginSync qw(copy_tree);

# =====================================================================
# Shared fabricated paths (never touch real filesystem in pure tests)
# =====================================================================

my $LIVE   = 'C:/r/ccpraxis';
my $WT     = 'C:/Users/Andre/ccpraxis-sandbox-workcopy';
my $HOME   = 'C:/Users/Andre';
my $BRANCH = 'ccpraxis-sandbox-workcopy';

# André-byte equivalents (UTF-8 bytes, utf8 flag OFF)
my $HOME_A  = "C:/Users/Andr\x{c3}\x{a9}";
my $LIVE_A  = "C:/r/ccpraxis";
my $WT_A    = "C:/Users/Andr\x{c3}\x{a9}/ccpraxis-sandbox-workcopy";

# Synthetic git worktree list --porcelain helper
# Returns a porcelain string with a HEAD record followed by one record at $path/$branch.
sub _porcelain_with {
    my (%a) = @_;
    my $path   = $a{path}   // $WT;
    my $branch = $a{branch} // "refs/heads/$BRANCH";
    my $head   = $a{head}   // "$LIVE";
    return "worktree $head\nHEAD deadbeef\nbranch refs/heads/main\n\nworktree $path\nHEAD cafebabe\nbranch $branch\n\n";
}

# Empty (absent) porcelain
my $PORCELAIN_ABSENT = "worktree $LIVE\nHEAD deadbeef\nbranch refs/heads/main\n\n";

# =====================================================================
# AC-1: worktree_plan absent — argv, branch, target
# =====================================================================

{
    my $plan = worktree_plan({ live_root => $LIVE, home => $HOME, state => 'absent' });
    ok(defined $plan, 'AC-1: worktree_plan returns defined value');
    is($plan->{branch}, $BRANCH, 'AC-1: branch eq ccpraxis-sandbox-workcopy');
    is($plan->{target}, "$HOME/ccpraxis-sandbox-workcopy", 'AC-1: target is home/ccpraxis-sandbox-workcopy');
    is_deeply(
        $plan->{git_argv},
        ['git', '-C', $LIVE, 'worktree', 'add', "$HOME/ccpraxis-sandbox-workcopy", '-b', 'ccpraxis-sandbox-workcopy'],
        'AC-1: git_argv list-form worktree add with -b for absent state (spec §3 vector)'
    );
    is($plan->{needs_add},    1, 'AC-1: needs_add=1 for absent');
    is($plan->{needs_branch}, 1, 'AC-1: needs_branch=1 for absent');
}

# =====================================================================
# AC-2: default_worktree_path override precedence + tilde expansion
# =====================================================================

# §3 obs-1 vector 1: home default
is(default_worktree_path({ home => "C:/Users/Andr\x{c3}\x{a9}" }),
   "C:/Users/Andr\x{c3}\x{a9}/ccpraxis-sandbox-workcopy",
   'AC-2: default path is home/ccpraxis-sandbox-workcopy');

# §3 obs-1 vector 2: explicit override wins
is(default_worktree_path({ home => 'C:/h', worktree_path => 'D:/wt' }),
   'D:/wt',
   'AC-2: explicit worktree_path override wins over home default');

# §3 obs-1 vector 3: env override (higher priority than home, lower than explicit)
is(default_worktree_path({ home => 'C:/h', env => { CCPRAXIS_WORKTREE_PATH => 'E:/x' } }),
   'E:/x',
   'AC-2: env CCPRAXIS_WORKTREE_PATH override wins over home');

# §3 obs-1 vector 4: tilde expansion against home
is(default_worktree_path({ home => "C:/Users/Andr\x{c3}\x{a9}", worktree_path => '~/wc' }),
   "C:/Users/Andr\x{c3}\x{a9}/wc",
   'AC-2: tilde in worktree_path expanded against home');

# No home + no override -> undef
is(default_worktree_path({ env => {} }),
   undef,
   'AC-2: no home and no override yields undef (never fabricate relative path)');

# Explicit worktree_path still wins when env is also set
is(default_worktree_path({ home => 'C:/h', worktree_path => 'D:/x', env => { CCPRAXIS_WORKTREE_PATH => 'E:/y' } }),
   'D:/x',
   'AC-2: explicit worktree_path beats env override (precedence order)');

# =====================================================================
# AC-3: blueprint_copy_plan exact src/dst
# =====================================================================

{
    my $cp = blueprint_copy_plan('C:/r/ccpraxis', 'C:/w/wc');
    is_deeply(
        $cp,
        { src => 'C:/r/ccpraxis/.ccpraxis-local-data/blueprints',
          dst => 'C:/w/wc/.ccpraxis-local-data/blueprints' },
        'AC-3: blueprint_copy_plan returns exact src/dst pair (spec §3 obs-5)'
    );
}

# =====================================================================
# AC-4: worktree_plan complete-state idempotent + provision_state complete
# =====================================================================

{
    # Complete state: worktree registered on correct branch
    my $porcelain = _porcelain_with(path => $WT, branch => "refs/heads/$BRANCH");

    my $state = provision_state({
        worktree_list => $porcelain,
        target        => $WT,
        branch        => $BRANCH,
        copy_probe    => sub { 'complete' },
        lock_probe    => sub { 0 },
    });
    is($state, 'complete', 'AC-4: provision_state complete for worktree+right-branch+copy-complete+no-lock');

    my $plan = worktree_plan({ live_root => $LIVE, home => $HOME, state => 'complete' });
    is($plan->{needs_add}, 0,  'AC-4: needs_add=0 for complete state (idempotent re-run)');
    is_deeply($plan->{git_argv}, [], 'AC-4: git_argv=[] for complete state (no duplicate worktree add)');
}

# =====================================================================
# AC-5: worktree_plan branch-exists-no-worktree (omits -b, needs_branch=0)
# =====================================================================

{
    my $plan = worktree_plan({
        live_root    => $LIVE,
        home         => $HOME,
        state        => 'branch_exists',   # branch exists but no worktree at target
    });
    is($plan->{needs_add},    1, 'AC-5: needs_add=1 when branch exists but no worktree');
    is($plan->{needs_branch}, 0, 'AC-5: needs_branch=0 when branch already exists');
    my $argv = $plan->{git_argv};
    my $has_dash_b = grep { $_ eq '-b' } @$argv;
    is($has_dash_b, 0, 'AC-5: git_argv does NOT contain -b flag (reuses existing branch)');
    # Confirm argv has the branch name as positional (not -b <branch>)
    my $last = $argv->[-1];
    is($last, $BRANCH, 'AC-5: last argv element is the branch name (positional, no -b)');
}

# =====================================================================
# AC-6: provision_state — all five fixture classifications
# =====================================================================

# 6a: empty worktree_list -> absent
is(provision_state({ worktree_list => '', target => $WT, branch => $BRANCH }),
   'absent', 'AC-6a: empty worktree_list -> absent');

# 6b: undef worktree_list -> absent
is(provision_state({ worktree_list => undef, target => $WT, branch => $BRANCH }),
   'absent', 'AC-6b: undef worktree_list -> absent');

# 6c: record present, right branch, copy complete -> complete
{
    my $porcelain = _porcelain_with(path => $WT, branch => "refs/heads/$BRANCH");
    is(provision_state({
            worktree_list => $porcelain,
            target        => $WT,
            branch        => $BRANCH,
            copy_probe    => sub { 'complete' },
            lock_probe    => sub { 0 },
        }),
       'complete', 'AC-6c: registered+right-branch+complete-copy -> complete');
}

# 6d: matching record but copy_probe partial -> partial (interrupted-copy fixture)
{
    my $porcelain = _porcelain_with(path => $WT, branch => "refs/heads/$BRANCH");
    is(provision_state({
            worktree_list => $porcelain,
            target        => $WT,
            branch        => $BRANCH,
            copy_probe    => sub { 'partial' },
            lock_probe    => sub { 0 },
        }),
       'partial', 'AC-6d: registered+right-branch+partial-copy -> partial (interrupted-copy)');
}

# 6e: wrong branch -> partial
{
    my $porcelain = _porcelain_with(path => $WT, branch => 'refs/heads/some-other-branch');
    is(provision_state({
            worktree_list => $porcelain,
            target        => $WT,
            branch        => $BRANCH,
            copy_probe    => sub { 'complete' },
            lock_probe    => sub { 0 },
        }),
       'partial', 'AC-6e: registered+wrong-branch -> partial');
}

# 6f: lock_probe true -> partial
{
    my $porcelain = _porcelain_with(path => $WT, branch => "refs/heads/$BRANCH");
    is(provision_state({
            worktree_list => $porcelain,
            target        => $WT,
            branch        => $BRANCH,
            copy_probe    => sub { 'complete' },
            lock_probe    => sub { 1 },
        }),
       'partial', 'AC-6f: registered+right-branch+complete-copy+lock -> partial');
}

# 6g: no matching record (different path) -> absent
{
    my $porcelain = _porcelain_with(path => 'C:/other/path', branch => "refs/heads/$BRANCH");
    is(provision_state({
            worktree_list => $porcelain,
            target        => $WT,
            branch        => $BRANCH,
            copy_probe    => sub { 'complete' },
        }),
       'absent', 'AC-6g: no record for target -> absent');
}

# =====================================================================
# AC-7: provision_repair_plan
# =====================================================================

# 7a: absent -> [worktree_add, copy_tree]
{
    my $rp = provision_repair_plan('absent', {
        live_root => $LIVE,
        target    => $WT,
        branch    => $BRANCH,
    });
    is($rp->{noop}, 0, 'AC-7a: repair absent -> noop=0');
    my @ops = map { $_->{op} } @{ $rp->{steps} };
    is_deeply(\@ops, ['worktree_add', 'copy_tree'],
        'AC-7a: absent repair steps are [worktree_add, copy_tree] in order');
    # git argv must be list-form
    my ($add_step) = grep { $_->{op} eq 'worktree_add' } @{ $rp->{steps} };
    ok(ref $add_step->{argv} eq 'ARRAY', 'AC-7a: worktree_add step carries array argv');
    my $has_git = $add_step->{argv}[0] eq 'git';
    is($has_git, 1, 'AC-7a: worktree_add argv starts with git');
    # No worktree remove
    my $has_remove = grep { $_->{op} =~ /remove|rm/ } @{ $rp->{steps} };
    is($has_remove, 0, 'AC-7a: absent repair has no remove step (no clobber)');
}

# 7b: partial with lock + wrong branch -> [clear_lock, fix_branch, copy_tree]
{
    my $rp = provision_repair_plan('partial', {
        live_root    => $LIVE,
        target       => $WT,
        branch       => $BRANCH,
        branch_wrong => 1,
        lock         => 1,
    });
    is($rp->{noop}, 0, 'AC-7b: repair partial(lock+wrong-branch) -> noop=0');
    my @ops = map { $_->{op} } @{ $rp->{steps} };
    # order: clear_lock first, fix_branch second, copy_tree last
    is($ops[0], 'clear_lock',  'AC-7b: first partial repair step is clear_lock');
    is($ops[1], 'fix_branch',  'AC-7b: second partial repair step is fix_branch');
    is($ops[-1], 'copy_tree',  'AC-7b: last partial repair step is copy_tree');
    # No worktree_add (no duplicate registration)
    my $has_add = grep { $_->{op} eq 'worktree_add' } @{ $rp->{steps} };
    is($has_add, 0, 'AC-7b: partial repair has no worktree_add (no duplicate worktree)');
    # No worktree remove
    my $has_remove = grep { $_->{op} =~ /remove|rm/ } @{ $rp->{steps} };
    is($has_remove, 0, 'AC-7b: partial repair has no remove step (no delete-first half-copy window)');
    # fix_branch argv is list-form git switch
    my ($fb) = grep { $_->{op} eq 'fix_branch' } @{ $rp->{steps} };
    ok(ref $fb->{argv} eq 'ARRAY', 'AC-7b: fix_branch carries array argv');
    like(join(' ', @{ $fb->{argv} }), qr/\bgit\b.*\bswitch\b/,
        'AC-7b: fix_branch argv contains git switch (list-form)');
    like(join(' ', @{ $fb->{argv} }), qr/ccpraxis-sandbox-workcopy/,
        'AC-7b: fix_branch argv targets the ccpraxis-sandbox-workcopy branch');
}

# 7c: complete -> noop=1, steps=[]
{
    my $rp = provision_repair_plan('complete', {});
    is($rp->{noop}, 1, 'AC-7c: repair complete -> noop=1');
    is_deeply($rp->{steps}, [], 'AC-7c: repair complete -> empty steps');
}

# =====================================================================
# AC-8: fleet_live liveness logic
# =====================================================================

# 8a: container_running true -> 1 (regardless of marker)
is(fleet_live({
        container_name    => 'claude-x-abcd1234',
        container_running => sub { 1 },
        marker_probe      => sub { undef },
    }),
   1, 'AC-8a: fleet_live=1 when container_running true (spec §3 obs-10)');

# 8b: container down, fresh marker -> 1
{
    my $now = time();
    is(fleet_live({
            container_name    => 'claude-x-abcd1234',
            container_running => sub { 0 },
            marker_probe      => sub { $now - 10 },
            now               => $now,
        }),
       1, 'AC-8b: fleet_live=1 when container down but marker fresh (now-10 within 900s window)');
}

# 8c: container down, stale marker -> 0
{
    my $now = time();
    is(fleet_live({
            container_name    => 'claude-x-abcd1234',
            container_running => sub { 0 },
            marker_probe      => sub { $now - 100000 },
            now               => $now,
        }),
       0, 'AC-8c: fleet_live=0 when container down AND marker stale (spec §3 obs-10)');
}

# 8d: container down, marker undef -> 0
is(fleet_live({
        container_name    => 'claude-x-abcd1234',
        container_running => sub { 0 },
        marker_probe      => sub { undef },
    }),
   0, 'AC-8d: fleet_live=0 when container down AND marker_probe returns undef');

# 8e: custom fresh_window respected
{
    my $now = time();
    # 500s old, default window 900 -> fresh
    is(fleet_live({
            container_name    => 'claude-x-abcd1234',
            container_running => sub { 0 },
            marker_probe      => sub { $now - 500 },
            now               => $now,
            fresh_window      => 900,
        }),
       1, 'AC-8e: fleet_live=1 when marker age (500s) < fresh_window (900s)');
    # 500s old, tight window 100 -> stale
    is(fleet_live({
            container_name    => 'claude-x-abcd1234',
            container_running => sub { 0 },
            marker_probe      => sub { $now - 500 },
            now               => $now,
            fresh_window      => 100,
        }),
       0, 'AC-8e: fleet_live=0 when marker age (500s) > fresh_window (100s)');
}

# =====================================================================
# AC-9: structural — no-clobber: fleet_live branch reaches re-exec without
# provisioning ops between it and the re-exec call. Pure structural text check.
# =====================================================================

{
    my $launcher = "$Bin/../../scripts/launcher.pl";
    ok(-f $launcher, 'AC-9 prereq: launcher.pl exists') or BAIL_OUT('launcher.pl missing');

    open my $fh, '<', $launcher or BAIL_OUT("cannot open launcher.pl: $!");
    my @lines = <$fh>;
    close $fh;

    # Find fleet_live call line
    my $fleet_line_idx;
    for my $i (0 .. $#lines) {
        if ($lines[$i] =~ /fleet_live\s*\(/) { $fleet_line_idx = $i; last; }
    }

    SKIP: {
        # If fleet_live is not yet in launcher.pl that is expected (p02 not wired yet).
        # The test MUST fail red — so we assert fleet_live IS present.
        ok(defined $fleet_line_idx,
            'AC-9 structural: launcher.pl calls fleet_live in the accept branch');

        skip 'fleet_live not yet in launcher.pl (expected: p02 not wired)', 3
            unless defined $fleet_line_idx;

        # Between fleet_live and the re-exec that follows (on the true/live branch),
        # there must be NO provision_state / provision_repair_plan / copy_tree calls.
        # We scan a reasonable window (up to 30 lines) for the live-fleet re-exec.
        my $reexec_idx;
        my $provision_state_in_live_branch = 0;
        my $repair_plan_in_live_branch = 0;
        my $copy_tree_in_live_branch = 0;

        for my $i ($fleet_line_idx + 1 .. $fleet_line_idx + 30) {
            last if $i > $#lines;
            my $l = $lines[$i];
            # The re-exec for the live-fleet path (attach/resume)
            if (!defined $reexec_idx && $l =~ /_reexec_launcher|exec\s*\(/) {
                $reexec_idx = $i;
                last;
            }
            $provision_state_in_live_branch  = 1 if $l =~ /provision_state\s*\(/;
            $repair_plan_in_live_branch      = 1 if $l =~ /provision_repair_plan\s*\(/;
            $copy_tree_in_live_branch        = 1 if $l =~ /copy_tree\s*\(/;
        }

        ok(defined $reexec_idx,
            'AC-9 structural: a re-exec call follows fleet_live on the live-fleet branch');
        is($provision_state_in_live_branch + $repair_plan_in_live_branch + $copy_tree_in_live_branch,
           0,
           'AC-9 structural: no provision_state/provision_repair_plan/copy_tree between fleet_live and live-fleet re-exec (no clobber, Decision #14b)');
    }
}

# =====================================================================
# AC-10: André-byte paths round-trip byte-identical through all pure fns
# =====================================================================

{
    # default_worktree_path with André-byte home
    my $got_wt = default_worktree_path({ home => $HOME_A });
    is($got_wt, $WT_A, 'AC-10: default_worktree_path André-byte home -> correct André-byte result');
    ok(!utf8::is_utf8($got_wt), 'AC-10: result is a byte string (no wide-char utf8 flag)');

    # worktree_plan with André-byte live_root and home
    my $plan = worktree_plan({ live_root => $LIVE_A, home => $HOME_A, state => 'absent' });
    is($plan->{target}, $WT_A, 'AC-10: worktree_plan target André-byte path byte-identical');
    ok(!utf8::is_utf8($plan->{target}), 'AC-10: worktree_plan target is a byte string');

    # blueprint_copy_plan with André-byte live_root and worktree
    my $cp = blueprint_copy_plan($LIVE_A, $WT_A);
    my $expected_src = "$LIVE_A/.ccpraxis-local-data/blueprints";
    my $expected_dst = "$WT_A/.ccpraxis-local-data/blueprints";
    is($cp->{src}, $expected_src, 'AC-10: blueprint_copy_plan src André-byte path byte-identical');
    is($cp->{dst}, $expected_dst, 'AC-10: blueprint_copy_plan dst André-byte path byte-identical');
    ok(!utf8::is_utf8($cp->{src}), 'AC-10: blueprint_copy_plan src is a byte string');

    # provision_state: target with André bytes
    my $porcelain_a = _porcelain_with(path => $WT_A, branch => "refs/heads/$BRANCH");
    my $state = provision_state({
        worktree_list => $porcelain_a,
        target        => $WT_A,
        branch        => $BRANCH,
        copy_probe    => sub { 'complete' },
        lock_probe    => sub { 0 },
    });
    is($state, 'complete', 'AC-10: provision_state handles André-byte target path correctly');

    # Wide-char vs byte normalization: a wide-char (JSON-decoded) path and its
    # UTF-8-byte twin must compare equal after _utf8_bytes normalization.
    # We simulate by passing the decoded wide-char registry path through live_install_dir.
    my $wide_plugins = do { my $s = "C:/Users/Andr\x{e9}/ccpraxis/plugins"; utf8::upgrade($s); $s };
    ok(utf8::is_utf8($wide_plugins), 'AC-10 prereq: wide_plugins has utf8 flag (wide-char)');
    my $reg_wide = { 'ccpraxis-local' => { source => { source => 'directory', path => $wide_plugins } } };
    my $lid_wide = live_install_dir({ registry => $reg_wide });
    my $byte_root = "C:/Users/Andr\x{c3}\x{a9}/ccpraxis";
    is($lid_wide, $byte_root,
        'AC-10: live_install_dir normalizes wide-char JSON path to UTF-8 bytes (byte-identical to fs path)');
    ok(defined $lid_wide && !utf8::is_utf8($lid_wide),
        'AC-10: live_install_dir result is a byte string (no wide-char flag)');
}

# =====================================================================
# AC-11: RO-bind source == live_root/plugins, project-independent
# =====================================================================

{
    # Replicate the launcher's RO-bind source derivation:
    # source = registry source.path (which is <live_root>/plugins)
    # This is project-independent: it must equal <live_root>/plugins regardless
    # of whether $PROJECT_PATH is the live root or the worktree.

    my $LIVE_PLUGINS = "$LIVE/plugins";
    my $reg = {
        'ccpraxis-local' => {
            source => { source => 'directory', path => $LIVE_PLUGINS }
        }
    };

    # When PROJECT_PATH = live root
    my $lid_live = live_install_dir({ registry => $reg });
    my $bind_src_live = "$lid_live/plugins" if defined $lid_live;
    is($bind_src_live, $LIVE_PLUGINS,
        'AC-11: RO-bind source == live_root/plugins when PROJECT_PATH is live root');
    ok(defined $bind_src_live && index($bind_src_live, $WT) == -1,
        'AC-11: RO-bind source does NOT contain worktree path when PROJECT_PATH is live root');

    # When PROJECT_PATH = worktree (simulated by using the same registry — registry anchors live root)
    my $lid_wt = live_install_dir({ registry => $reg });
    my $bind_src_wt = "$lid_wt/plugins" if defined $lid_wt;
    is($bind_src_wt, $LIVE_PLUGINS,
        'AC-11: RO-bind source == live_root/plugins when PROJECT_PATH is worktree (project-independent)');
    ok(defined $bind_src_wt && index($bind_src_wt, $WT) == -1,
        'AC-11: RO-bind source does NOT contain worktree path when PROJECT_PATH is worktree');

    # Symmetry: both derivations yield the same string
    is($bind_src_live, $bind_src_wt,
        'AC-11: RO-bind source string is identical whether project is live root or worktree (Decision #5)');
}

# =====================================================================
# AC-12: selfhost_route(worktree, hint=live_root) -> 'passthrough'
# =====================================================================

{
    my $exists_wt = sub {
        my $p = shift;
        return 1 if $p eq "$WT/plugins/.claude-plugin/marketplace.json";
        return 1 if $p eq "$WT/plugins/sandbox/scripts/launcher.pl";
        return 0;
    };
    my $route = selfhost_route($WT, {
        live_install_hint => $LIVE,
        git_commondir     => sub { "$LIVE/.git" },
        exists            => $exists_wt,
        realpath          => sub { $_[0] },
    });
    is($route, 'passthrough',
        'AC-12: selfhost_route(worktree, hint=live_root) eq passthrough (re-exec sees passthrough, no re-offer loop, Decision #10)');
}

# =====================================================================
# AC-13: PRODUCTION-FAITHFUL — real PluginSync::copy_tree with André-byte path
# =====================================================================

{
    # Build a real tempdir. The André-byte subpath is the test of opendir/readdir
    # handling of non-ASCII directory names (the p01 cardinal-sin guard).
    my $base = eval { tempdir(CLEANUP => 1) };
    if (!defined $base) {
        BAIL_OUT('AC-13: could not create tempdir: ' . ($@ // 'unknown'));
    }

    # Create an André-named subdir under the tempdir
    # The subdir name uses UTF-8 bytes for the é character (\xc3\xa9)
    my $andre_subdir = "$base/Andr\x{c3}\x{a9}-src";
    my $ok = eval { make_path($andre_subdir); 1 };

    SKIP: {
        skip 'AC-13: OS cannot create non-ASCII dir (genuine inability)', 10
            unless $ok && -d $andre_subdir;

        # Build fixture tree:
        #   blueprints/test-bp/specs/x.md
        #   blueprints/test-bp/runs/.orchestrator
        #   blueprints/test-bp/high-bytes.bin  (file with high/non-ASCII bytes)
        my $src_bp = "$andre_subdir/blueprints/test-bp";
        make_path("$src_bp/specs");
        make_path("$src_bp/runs");

        # Write all files :raw as UTF-8 bytes
        _write_raw("$src_bp/specs/x.md",
            "# Blueprint spec\n\xc3\xa9 is the UTF-8 byte sequence for \xc3\xa9\n");
        _write_raw("$src_bp/runs/.orchestrator",
            "orchestrator-marker\n");
        # High bytes / binary-ish content
        _write_raw("$src_bp/high-bytes.bin",
            "\x00\x01\xfe\xff\xc3\xa9\x80\x9f\xbf\xef\xbb\xbf");

        # Destination: also André-byte named
        my $andre_dst = "$base/Andr\x{c3}\x{a9}-dst";

        # Run the REAL copy_tree
        eval { copy_tree("$andre_subdir/blueprints", "$andre_dst/blueprints") };
        is($@, '', 'AC-13: copy_tree does not die on André-byte path');

        # Assert byte-for-byte identity of every copied file
        my @files = (
            'test-bp/specs/x.md',
            'test-bp/runs/.orchestrator',
            'test-bp/high-bytes.bin',
        );
        for my $rel (@files) {
            my $src_f = "$andre_subdir/blueprints/$rel";
            my $dst_f = "$andre_dst/blueprints/$rel";

            ok(-f $dst_f, "AC-13: copied file exists: $rel");
            is(-s $dst_f, -s $src_f, "AC-13: byte size matches: $rel");

            my $src_bytes = _read_raw($src_f);
            my $dst_bytes = _read_raw($dst_f);
            is($dst_bytes, $src_bytes, "AC-13: byte content identical: $rel");
        }

        # Assert nested directory structure reproduced under André dst
        ok(-d "$andre_dst/blueprints/test-bp/specs",
            'AC-13: nested specs/ dir reproduced under André dst');
        ok(-d "$andre_dst/blueprints/test-bp/runs",
            'AC-13: nested runs/ dir reproduced under André dst');
    }
}

# =====================================================================
# AC-14: structural launcher.pl wiring assertions (t/09 grep style)
# Must NOT require/execute launcher.pl.
# =====================================================================

{
    my $launcher = "$Bin/../../scripts/launcher.pl";
    ok(-f $launcher, 'AC-14: launcher.pl is present') or BAIL_OUT('launcher.pl missing for AC-14');

    open my $fh, '<', $launcher or BAIL_OUT("cannot open launcher.pl: $!");
    my @lines = <$fh>;
    close $fh;

    # (i) No surviving "not yet implemented (p02)" stub text
    my $has_stub = grep { /not yet implemented.*p02/i } @lines;
    is($has_stub, 0,
        'AC-14i: accept branch has no "not yet implemented (p02)" stub text');

    # (ii) References all required p02 symbols + re-exec
    my $src = join('', @lines);
    ok($src =~ /\bdefault_worktree_path\b/,
        'AC-14ii: launcher.pl references default_worktree_path');
    ok($src =~ /\bfleet_live\b/,
        'AC-14ii: launcher.pl references fleet_live');
    ok($src =~ /\bprovision_state\b/,
        'AC-14ii: launcher.pl references provision_state');
    ok($src =~ /\bprovision_repair_plan\b/,
        'AC-14ii: launcher.pl references provision_repair_plan');
    ok($src =~ /\bPluginSync::copy_tree\b/,
        'AC-14ii: launcher.pl references PluginSync::copy_tree');
    ok($src =~ /_reexec_launcher|exec\s*\{?\s*\$\^X\b|exec\s*['"]powershell/,
        'AC-14ii: launcher.pl has a launcher re-exec idiom in the accept branch');

    # (iii) accept block at a line index BEFORE SandboxLock::acquire
    my $sandboxlock_line_idx;
    for my $i (0 .. $#lines) {
        if ($lines[$i] =~ /SandboxLock::acquire\s*\(/) { $sandboxlock_line_idx = $i; last; }
    }
    ok(defined $sandboxlock_line_idx,
        'AC-14 prereq: found SandboxLock::acquire in launcher.pl');

    my $default_wt_line_idx;
    for my $i (0 .. $#lines) {
        if ($lines[$i] =~ /default_worktree_path\s*\(/) { $default_wt_line_idx = $i; last; }
    }
    SKIP: {
        skip 'AC-14iii: default_worktree_path not in launcher yet (expected for p02 not wired)', 1
            unless defined $default_wt_line_idx && defined $sandboxlock_line_idx;
        ok($default_wt_line_idx < $sandboxlock_line_idx,
            'AC-14iii: accept block (default_worktree_path) is BEFORE SandboxLock::acquire (no lock held at re-exec)');
    }
    # Assert even when not wired (this is expected to fail red):
    if (!defined $default_wt_line_idx) {
        fail('AC-14iii: default_worktree_path not found in launcher.pl (p02 wiring missing — expected red)');
    }

    # (iv) No qx/backtick git in the entire launcher (list-form only — RCE canary)
    my $has_qx_git = grep { /qx\s*[\{\(\/'"]\s*[^\n]*git/ } @lines;
    is($has_qx_git, 0,
        'AC-14iv: launcher.pl has no qx{...} git invocations (list-form only, RCE guard)');
    my $has_bt_git = grep { /`[^`\n]*\bgit\b[^`\n]*`/ } @lines;
    is($has_bt_git, 0,
        'AC-14iv: launcher.pl has no backtick git invocations (list-form only, RCE guard)');
}

# =====================================================================
# Helpers
# =====================================================================

sub _write_raw {
    my ($path, $bytes) = @_;
    open my $fh, '>:raw', $path or die "cannot write $path: $!";
    print $fh $bytes;
    close $fh;
}

sub _read_raw {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "cannot read $path: $!";
    local $/;
    my $b = <$fh>;
    close $fh;
    return $b;
}

# =====================================================================
# AC-16 — MAJOR-1 (red-team redteam-05): branch-exists re-provision must NOT
# use -b. `git worktree remove` leaves the branch; a re-provision with -b
# hard-fails ("branch already exists"). provision_repair_plan must honor a
# branch_exists opt for the 'absent' case.
# =====================================================================
{
    my $rp = provision_repair_plan('absent', {
        live_root => $LIVE, target => $WT, branch => $BRANCH, branch_exists => 1,
    });
    my ($add) = grep { $_->{op} eq 'worktree_add' } @{ $rp->{steps} };
    ok($add, 'AC-16: absent+branch_exists still emits a worktree_add step');
    my $has_dash_b = grep { $_ eq '-b' } @{ $add->{argv} };
    is($has_dash_b, 0, 'AC-16: worktree_add omits -b when the branch already exists (reuse — no "branch exists" failure)');
    is($add->{argv}[-1], $BRANCH, 'AC-16: worktree_add ends with the branch name (positional reuse)');

    my $rp2 = provision_repair_plan('absent', {
        live_root => $LIVE, target => $WT, branch => $BRANCH, branch_exists => 0,
    });
    my ($add2) = grep { $_->{op} eq 'worktree_add' } @{ $rp2->{steps} };
    my $has_b2 = grep { $_ eq '-b' } @{ $add2->{argv} };
    is($has_b2, 1, 'AC-16: worktree_add includes -b when the branch does not exist (create)');
}

# =====================================================================
# AC-17 — MAJOR-1 wiring (structural): the launcher DERIVES branch existence
# and threads it, so the branch_exists path is not dead code.
# =====================================================================
{
    my $launcher = "$Bin/../../scripts/launcher.pl";
    open my $fh, '<', $launcher or BAIL_OUT("cannot open launcher.pl: $!");
    my $src = do { local $/; <$fh> }; close $fh;
    ok($src =~ /branch_exists/, 'AC-17: launcher references branch_exists (threads the state)');
    ok($src =~ /branch\s+--list|show-ref|for-each-ref|rev-parse\s+--verify/,
       'AC-17: launcher probes whether the branch already exists (git branch --list / show-ref / rev-parse --verify)');
}

# =====================================================================
# AC-18 — MAJOR-2 (red-team): the fleet_live container name MUST match the
# real launch's container name. canon_path uppercases the drive while the
# launch's abs_path/winify yields lowercase → md5 mismatch → fleet_live's
# container signal is always dead → clobber of an idle-but-live run.
# Enforce ONE shared _container_name_for helper used at both sites.
# =====================================================================
{
    my $launcher = "$Bin/../../scripts/launcher.pl";
    open my $fh, '<', $launcher or BAIL_OUT("cannot open launcher.pl: $!");
    my $src = do { local $/; <$fh> }; close $fh;
    ok($src =~ /_container_name_for\s*\(/,
       'AC-18: launcher defines/uses a shared _container_name_for helper');
    my $uses = () = ($src =~ /_container_name_for\s*\(/g);
    ok($uses >= 2,
       'AC-18: _container_name_for called at >= 2 sites (fleet_live check + main launch) so names cannot diverge');
    ok($src !~ /md5_of_string\(\s*\$wt\s*\)/,
       'AC-18: fleet_live container name is NOT md5_of_string($wt) directly (avoids the canon-vs-abs_path drive-case divergence)');
}

done_testing();
