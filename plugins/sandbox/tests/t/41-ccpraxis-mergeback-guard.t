#!/usr/bin/env perl
# Tests for CcpraxisWorkCopy — mergeback/discard guard (p03).
#
# IMMUTABLE ORACLE: derived from the p03 spec, not from any implementation.
# All seams injected (no real repo/git/podman) except AC-10 (real fs/git).
# Must NOT execute ccpraxis-mergeback.pl.
#
# Criterion mapping:
#   AC-1  : mergeback_guard blocked/clear matrix (container-running, fresh, stale, undef)
#   AC-2  : crash-resilience: stale+down => clear; fresh OR running => blocked
#   AC-3  : mergeback_plan clear: step op-name ORDER + every git argv list-form
#   AC-4  : blocked => both plans steps=[], noop=1, guard='blocked'
#   AC-5  : confirm < commit index; structural: guard called before --yes branch
#   AC-6  : discard_plan clear: [confirm, worktree_remove, branch_force_delete] + argv shapes
#   AC-7  : discard_plan uses same guard (container_running/stale matrix)
#   AC-8  : list-form argv (ARRAY ref) + Andre-byte live/worktree thread through byte-identical
#   AC-9  : structural ccpraxis-mergeback.pl checks (exists, dispatch, no-qx, guard-first, no-CoAuthor, MSYS2)
#   AC-10 : production-faithful real git repo under Andre-byte path
#   AC-11 : structural plugin.json + both SKILL.md frontmatter checks
#   AC-12 : structural marketplace.json: selfhost entry removed (folded into steward), pre-existing preserved
#   AC-13 : EXCLUDED (full-suite regression -- driver step)

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP ();

use CcpraxisWorkCopy qw(
    mergeback_guard
    mergeback_plan
    discard_plan
    fleet_live
    default_worktree_path
    canon_path
);

# =====================================================================
# Shared fabricated paths (never touch real filesystem in pure tests)
# =====================================================================

my $LIVE   = 'C:/r/ccpraxis';
my $WT     = 'C:/Users/Andre/ccpraxis-sandbox-workcopy';
my $BRANCH = 'ccpraxis-sandbox-workcopy';

# Andre-byte equivalents (UTF-8 bytes, utf8 flag OFF)
my $LIVE_A = "C:/r/ccpraxis";
my $WT_A   = "C:/Users/Andr\x{c3}\x{a9}/ccpraxis-sandbox-workcopy";

# =====================================================================
# AC-1: mergeback_guard blocked/clear matrix
# =====================================================================

# container running => blocked
is(mergeback_guard({ container_running => sub { 1 }, marker_probe => sub { undef } }),
   'blocked',
   'AC-1: mergeback_guard blocked when container_running returns true');

# container down, fresh marker (now-10, within default 900s window) => blocked
{
    my $now = time();
    is(mergeback_guard({
            container_running => sub { 0 },
            marker_probe      => sub { $now - 10 },
            now               => $now,
        }),
       'blocked',
       'AC-1: mergeback_guard blocked when container down but marker fresh (now-10)');
}

# container down, no marker => clear
is(mergeback_guard({ container_running => sub { 0 }, marker_probe => sub { undef } }),
   'clear',
   'AC-1: mergeback_guard clear when container down and marker_probe returns undef');

# =====================================================================
# AC-2: crash-resilience -- stale+down => clear; fresh OR running => blocked
# =====================================================================

# stale marker + container down => clear (no permanent deadlock after crash)
{
    my $now = time();
    is(mergeback_guard({
            container_running => sub { 0 },
            marker_probe      => sub { $now - 100000 },
            now               => $now,
            fresh_window      => 900,
        }),
       'clear',
       'AC-2: mergeback_guard clear when marker stale (100000s old) + container down (crash-resilience, Decision #14b)');
}

# fresh marker (even with container down) => blocked
{
    my $now = time();
    is(mergeback_guard({
            container_running => sub { 0 },
            marker_probe      => sub { $now - 10 },
            now               => $now,
            fresh_window      => 900,
        }),
       'blocked',
       'AC-2: mergeback_guard blocked when marker fresh (10s old) even with container down');
}

# running container => blocked regardless of marker staleness
{
    my $now = time();
    is(mergeback_guard({
            container_running => sub { 1 },
            marker_probe      => sub { $now - 100000 },
            now               => $now,
            fresh_window      => 900,
        }),
       'blocked',
       'AC-2: mergeback_guard blocked when container running regardless of stale marker');
}

# =====================================================================
# AC-3: mergeback_plan clear -- step op-name ORDER + every argv shape
# =====================================================================

{
    my $L = $LIVE;
    my $W = $WT;
    my $plan = mergeback_plan({
        live              => $L,
        worktree          => $W,
        container_running => sub { 0 },
        marker_probe      => sub { undef },
    });

    is($plan->{guard},       'clear',  'AC-3: mergeback_plan guard=clear');
    is($plan->{noop},        0,        'AC-3: mergeback_plan noop=0 when clear');
    is($plan->{on_conflict}, 'abort',  'AC-3: mergeback_plan on_conflict=abort');

    my $steps = $plan->{steps};
    my @op_names = map { $_->{op} } @$steps;
    is_deeply(
        \@op_names,
        [qw(switch_main merge_no_ff_no_commit show_diff confirm commit worktree_remove branch_delete)],
        'AC-3: mergeback_plan step op-names in exact spec order'
    );

    # Step 1: switch_main
    is_deeply(
        $steps->[0]{argv},
        ['git', '-C', $L, 'switch', 'main'],
        'AC-3: step 1 switch_main argv exact list-form'
    );

    # Step 2: merge_no_ff_no_commit
    is_deeply(
        $steps->[1]{argv},
        ['git', '-C', $L, 'merge', '--no-ff', '--no-commit', 'ccpraxis-sandbox-workcopy'],
        'AC-3: step 2 merge_no_ff_no_commit argv exact list-form'
    );

    # Step 3: show_diff
    is_deeply(
        $steps->[2]{argv},
        ['git', '-C', $L, 'diff', '--cached'],
        'AC-3: step 3 show_diff argv exact list-form'
    );

    # Step 4: confirm -- no argv, has note
    is($steps->[3]{op}, 'confirm', 'AC-3: step 4 op=confirm');
    ok(exists $steps->[3]{note}, 'AC-3: confirm step carries note field');
    ok(!exists $steps->[3]{argv}, 'AC-3: confirm step has NO argv (gate marker only)');

    # Step 5: commit -- bare argv, no -m, no Co-Authored-By
    is_deeply(
        $steps->[4]{argv},
        ['git', '-C', $L, 'commit'],
        'AC-3: step 5 commit argv is bare [git -C <live> commit] (no -m, no Co-Authored-By)'
    );

    # Step 6: worktree_remove
    is_deeply(
        $steps->[5]{argv},
        ['git', '-C', $L, 'worktree', 'remove', $W],
        'AC-3: step 6 worktree_remove argv exact list-form'
    );

    # Step 7: branch_delete (safe -d, not -D)
    is_deeply(
        $steps->[6]{argv},
        ['git', '-C', $L, 'branch', '-d', 'ccpraxis-sandbox-workcopy'],
        'AC-3: step 7 branch_delete argv uses -d (safe, branch was just merged)'
    );
}

# =====================================================================
# AC-4: blocked => both plans steps=[], noop=1
# =====================================================================

{
    my $mb_blocked = mergeback_plan({
        live              => $LIVE,
        worktree          => $WT,
        container_running => sub { 1 },
        marker_probe      => sub { undef },
    });
    is($mb_blocked->{guard}, 'blocked', 'AC-4: mergeback_plan guard=blocked when container running');
    is($mb_blocked->{noop},  1,         'AC-4: mergeback_plan noop=1 when blocked');
    is_deeply($mb_blocked->{steps}, [], 'AC-4: mergeback_plan steps=[] when blocked (no merge/cleanup emitted)');

    my $d_blocked = discard_plan({
        live              => $LIVE,
        worktree          => $WT,
        container_running => sub { 1 },
        marker_probe      => sub { undef },
    });
    is($d_blocked->{guard}, 'blocked', 'AC-4: discard_plan guard=blocked when container running');
    is($d_blocked->{noop},  1,         'AC-4: discard_plan noop=1 when blocked');
    is_deeply($d_blocked->{steps}, [], 'AC-4: discard_plan steps=[] when blocked (no discard argv emitted)');
}

# =====================================================================
# AC-5: confirm < commit index in mergeback_plan;
# structural: script calls mergeback_guard before --yes branch
# =====================================================================

{
    my $plan = mergeback_plan({
        live              => $LIVE,
        worktree          => $WT,
        container_running => sub { 0 },
        marker_probe      => sub { undef },
    });
    my $steps = $plan->{steps};

    my ($confirm_idx) = grep { $steps->[$_]{op} eq 'confirm' } 0 .. $#$steps;
    my ($commit_idx)  = grep { $steps->[$_]{op} eq 'commit'  } 0 .. $#$steps;

    ok(defined $confirm_idx, 'AC-5: confirm step exists in mergeback_plan');
    ok(defined $commit_idx,  'AC-5: commit step exists in mergeback_plan');
    ok($confirm_idx < $commit_idx,
       "AC-5: confirm step (index $confirm_idx) precedes commit step (index $commit_idx) -- no auto-merge");
}

# AC-5 structural: script calls mergeback_guard and blocked-exit appears BEFORE --yes branch
{
    my $script = "$Bin/../../scripts/ccpraxis-mergeback.pl";
    SKIP: {
        skip 'AC-5 structural: ccpraxis-mergeback.pl not yet created (expected red)', 3
            unless -f $script;

        open my $fh, '<:raw', $script or die "cannot open $script: $!";
        my @lines = <$fh>;
        close $fh;

        # Find first mergeback_guard call line
        my $guard_line;
        for my $i (0 .. $#lines) {
            if ($lines[$i] =~ /mergeback_guard\s*\(/) { $guard_line = $i; last; }
        }
        ok(defined $guard_line, 'AC-5 structural: script calls mergeback_guard');

        # Find first --yes / yes branch line after the guard
        my $yes_branch_line;
        for my $i ($guard_line // 0 .. $#lines) {
            if ($lines[$i] =~ /--yes|yes\s*=>\s*1|skip.*confirm|skip.*prompt/i) {
                $yes_branch_line = $i; last;
            }
        }

        # Find BLOCKED: exit line
        my $blocked_exit_line;
        for my $i ($guard_line // 0 .. $#lines) {
            if ($lines[$i] =~ /BLOCKED:/i && $lines[$i] =~ /print|say|warn/) {
                $blocked_exit_line = $i; last;
            }
            if ($lines[$i] =~ /exit\s*\d*/ && $i > ($guard_line // 0)) {
                # look for exit after a BLOCKED check
                my $window_start = ($guard_line // 0);
                my $found_blocked = grep { $lines[$_] =~ /blocked/i } $window_start .. $i;
                if ($found_blocked) { $blocked_exit_line = $i; last; }
            }
        }

        ok(defined $blocked_exit_line,
           'AC-5 structural: blocked exit found in script after mergeback_guard call');

        if (defined $yes_branch_line && defined $blocked_exit_line) {
            ok($blocked_exit_line < $yes_branch_line,
               'AC-5 structural: blocked-exit line appears BEFORE --yes branch (guard cannot be skipped by --yes)');
        } else {
            pass('AC-5 structural: --yes branch not yet present or exit ordering not separately tested');
        }
    }
}

# =====================================================================
# AC-6: discard_plan clear -- [confirm, worktree_remove, branch_force_delete] + argv
# =====================================================================

{
    my $L = $LIVE;
    my $W = $WT;
    my $plan = discard_plan({
        live              => $L,
        worktree          => $W,
        container_running => sub { 0 },
        marker_probe      => sub { undef },
    });

    is($plan->{guard}, 'clear', 'AC-6: discard_plan guard=clear');
    is($plan->{noop},  0,       'AC-6: discard_plan noop=0 when clear');
    ok(!exists $plan->{on_conflict}, 'AC-6: discard_plan has no on_conflict key');

    my $steps = $plan->{steps};
    my @op_names = map { $_->{op} } @$steps;
    is_deeply(
        \@op_names,
        [qw(confirm worktree_remove branch_force_delete)],
        'AC-6: discard_plan step op-names in exact spec order'
    );

    # Step 1: confirm -- no argv
    is($steps->[0]{op}, 'confirm', 'AC-6: step 1 op=confirm');
    ok(exists $steps->[0]{note}, 'AC-6: confirm step carries note field');
    ok(!exists $steps->[0]{argv}, 'AC-6: confirm step has NO argv');

    # Step 2: worktree_remove
    is_deeply(
        $steps->[1]{argv},
        ['git', '-C', $L, 'worktree', 'remove', $W],
        'AC-6: step 2 worktree_remove argv exact list-form'
    );

    # Step 3: branch_force_delete -- MUST use -D (force; unmerged commits discarded intentionally)
    is_deeply(
        $steps->[2]{argv},
        ['git', '-C', $L, 'branch', '-D', 'ccpraxis-sandbox-workcopy'],
        'AC-6: step 3 branch_force_delete argv uses -D (force; spec §2.1.3 + done-criterion f)'
    );
}

# =====================================================================
# AC-7: discard_plan uses the SAME guard (matrix matches mergeback_guard)
# =====================================================================

# container running => blocked
{
    my $p = discard_plan({ live => $LIVE, worktree => $WT, container_running => sub { 1 }, marker_probe => sub { undef } });
    is($p->{guard}, 'blocked', 'AC-7: discard_plan blocked when container running');
    is_deeply($p->{steps}, [], 'AC-7: discard_plan steps=[] when blocked');
}

# stale marker + container down => clear
{
    my $now = time();
    my $p = discard_plan({
        live              => $LIVE,
        worktree          => $WT,
        container_running => sub { 0 },
        marker_probe      => sub { $now - 100000 },
        now               => $now,
        fresh_window      => 900,
    });
    is($p->{guard}, 'clear', 'AC-7: discard_plan clear when stale marker + container down (crash-resilience)');
    is($p->{noop},  0,       'AC-7: discard_plan noop=0 when clear (discard allowed)');
}

# fresh marker + container down => blocked
{
    my $now = time();
    my $p = discard_plan({
        live              => $LIVE,
        worktree          => $WT,
        container_running => sub { 0 },
        marker_probe      => sub { $now - 10 },
        now               => $now,
        fresh_window      => 900,
    });
    is($p->{guard}, 'blocked', 'AC-7: discard_plan blocked when fresh marker even with container down');
}

# =====================================================================
# AC-8: list-form argv (ARRAY ref) for every git step + Andre-byte thread-through
# =====================================================================

{
    # Andre-byte paths
    my $L = "C:/Users/Andr\x{c3}\x{a9}/ccpraxis";
    my $W = "C:/Users/Andr\x{c3}\x{a9}/ccpraxis-sandbox-workcopy";

    # Ensure these are byte strings (no utf8 flag)
    ok(!utf8::is_utf8($L), 'AC-8 prereq: Andre-byte live is a byte string');
    ok(!utf8::is_utf8($W), 'AC-8 prereq: Andre-byte worktree is a byte string');

    # mergeback_plan
    my $mb = mergeback_plan({
        live              => $L,
        worktree          => $W,
        container_running => sub { 0 },
        marker_probe      => sub { undef },
    });
    for my $step (@{ $mb->{steps} }) {
        next if $step->{op} eq 'confirm';  # confirm has no argv
        ok(ref $step->{argv} eq 'ARRAY',
           "AC-8: mergeback_plan step '$step->{op}' argv is ARRAY ref (list-form)");
        # Check that live/worktree bytes thread through unchanged
        for my $elem (@{ $step->{argv} }) {
            if ($elem eq $L || $elem eq $W) {
                ok(!utf8::is_utf8($elem),
                   "AC-8: Andre-byte path in step '$step->{op}' argv has no utf8 flag (byte-identical thread-through)");
            }
        }
    }

    # worktree_remove must reference the Andre-byte worktree
    my ($wr) = grep { $_->{op} eq 'worktree_remove' } @{ $mb->{steps} };
    is($wr->{argv}[-1], $W, 'AC-8: mergeback_plan worktree_remove last argv == Andre-byte worktree (byte-identical)');

    # discard_plan
    my $dp = discard_plan({
        live              => $L,
        worktree          => $W,
        container_running => sub { 0 },
        marker_probe      => sub { undef },
    });
    for my $step (@{ $dp->{steps} }) {
        next if $step->{op} eq 'confirm';
        ok(ref $step->{argv} eq 'ARRAY',
           "AC-8: discard_plan step '$step->{op}' argv is ARRAY ref (list-form)");
        for my $elem (@{ $step->{argv} }) {
            if ($elem eq $L || $elem eq $W) {
                ok(!utf8::is_utf8($elem),
                   "AC-8: Andre-byte path in discard step '$step->{op}' argv has no utf8 flag");
            }
        }
    }
    my ($dp_wr) = grep { $_->{op} eq 'worktree_remove' } @{ $dp->{steps} };
    is($dp_wr->{argv}[-1], $W, 'AC-8: discard_plan worktree_remove last argv == Andre-byte worktree (byte-identical)');

    # Verify no step argv is a shell string (scalar non-ref would pass ref check as undef/empty)
    my @mb_bad = grep { $_->{op} ne 'confirm' && ref($_->{argv}) ne 'ARRAY' } @{ $mb->{steps} };
    is(scalar @mb_bad, 0, 'AC-8: NO mergeback_plan step has a scalar/shell-string argv');
    my @dp_bad = grep { $_->{op} ne 'confirm' && ref($_->{argv}) ne 'ARRAY' } @{ $dp->{steps} };
    is(scalar @dp_bad, 0, 'AC-8: NO discard_plan step has a scalar/shell-string argv');
}

# =====================================================================
# AC-9: structural -- ccpraxis-mergeback.pl checks
# Must NOT execute the script.
# =====================================================================

{
    my $script = "$Bin/../../scripts/ccpraxis-mergeback.pl";

    # (i) Script must exist -- FAILS RED until created
    ok(-f $script, 'AC-9i: ccpraxis-mergeback.pl exists');

    SKIP: {
        skip 'AC-9: ccpraxis-mergeback.pl not yet created (expected red)', 12
            unless -f $script;

        open my $fh, '<:raw', $script or die "cannot open $script: $!";
        my @lines = <$fh>;
        close $fh;
        my $src = join('', @lines);

        # (i) Both merge and discard subcommand dispatch
        ok($src =~ /\bmerge\b/,   'AC-9i: script has merge subcommand dispatch');
        ok($src =~ /\bdiscard\b/, 'AC-9i: script has discard subcommand dispatch');

        # (ii) List-form git only -- no qx{}/backtick git (RCE canary, p01 pattern)
        my $has_qx_git = grep { /qx\s*[\{\(\/'"]\s*[^\n]*git/ } @lines;
        is($has_qx_git, 0, 'AC-9ii: no qx{...git...} in ccpraxis-mergeback.pl (list-form only, RCE guard)');
        my $has_bt_git = grep { /`[^`\n]*\bgit\b[^`\n]*`/ } @lines;
        is($has_bt_git, 0, 'AC-9ii: no backtick git in ccpraxis-mergeback.pl (list-form only)');

        # (iii) Calls mergeback_guard
        ok($src =~ /mergeback_guard\s*\(/, 'AC-9iii: script calls mergeback_guard');

        # (iii) BLOCKED: print + exit appears in source before any git merge / worktree remove / branch op
        # Strategy: find first line with mergeback_guard call, find the BLOCKED exit,
        # then assert no git merge/worktree/branch op appears between start and that exit.
        my $guard_line_num;
        for my $i (0 .. $#lines) {
            if ($lines[$i] =~ /mergeback_guard\s*\(/) { $guard_line_num = $i; last; }
        }
        ok(defined $guard_line_num, 'AC-9iii: mergeback_guard call found in script');

        my $blocked_exit_num;
        if (defined $guard_line_num) {
            for my $i ($guard_line_num .. $#lines) {
                if ($lines[$i] =~ /BLOCKED:/i || ($lines[$i] =~ /exit\s*[1-9]/ && $i < $guard_line_num + 10)) {
                    $blocked_exit_num = $i; last;
                }
            }
        }
        ok(defined $blocked_exit_num,
           'AC-9iii: BLOCKED:/exit found after mergeback_guard in script source');

        if (defined $guard_line_num && defined $blocked_exit_num) {
            # Between guard call and blocked exit, there must be no git merge / worktree remove / branch op
            my $git_op_before_exit = 0;
            for my $i ($guard_line_num + 1 .. $blocked_exit_num - 1) {
                if ($lines[$i] =~ /system\s*\(\s*['"]git|exec\s*\(\s*['"]git|open.*\bgit\b/) {
                    $git_op_before_exit = 1; last;
                }
            }
            is($git_op_before_exit, 0,
               'AC-9iii: no git invocation between mergeback_guard call and blocked exit (guard runs before any git op)');
        } else {
            pass('AC-9iii: guard/blocked ordering (deferred -- guard or exit not yet found)');
        }

        # (iv) No Co-Authored-By
        my $has_coauthor = grep { /Co-Authored-By/i } @lines;
        is($has_coauthor, 0, 'AC-9iv: no Co-Authored-By in ccpraxis-mergeback.pl (house rule)');

        # (v) Sets MSYS2_ARG_CONV_EXCL around git
        ok($src =~ /MSYS2_ARG_CONV_EXCL/, 'AC-9v: script sets MSYS2_ARG_CONV_EXCL (MSYS2 path-mangling guard)');

        # (vi) Does not shell-cd (no chained cd && git)
        my $has_cd_chain = grep { /\bcd\b.*&&.*\bgit\b/ } @lines;
        is($has_cd_chain, 0, 'AC-9vi: no cd-chained git in script (list-form -C only)');
    }
}

# =====================================================================
# AC-10: PRODUCTION-FAITHFUL real git repo under Andre-byte path
# =====================================================================

{
    # Check git availability
    my $git_ok = do {
        my $out = `git --version 2>&1`;
        $? == 0 && $out =~ /git version/;
    };

    my $base = eval { tempdir(CLEANUP => 1) };
    BAIL_OUT('AC-10: could not create tempdir: ' . ($@ // 'unknown')) unless defined $base;

    # Create Andre-byte subdir
    my $andre_live = "$base/Andr\x{c3}\x{a9}-live";
    my $can_unicode_dir = eval { make_path($andre_live); 1 } && -d $andre_live;

    SKIP: {
        skip 'AC-10: git unavailable', 20 unless $git_ok;
        skip 'AC-10: OS cannot create non-ASCII dir (genuine inability)', 20 unless $can_unicode_dir;

        my $wt_path = "$base/Andr\x{c3}\x{a9}-wc";

        # Helper: run git command capturing output, return (stdout, exit_code)
        my $git_run = sub {
            my @cmd = @_;
            # Use a temp file to avoid STDOUT-scalar capture bug on Win perl
            my $tmp = "$base/_git_out_$$.txt";
            system(@cmd, '>', $tmp) if 0; # not this way
            # Proper approach: open pipe
            my $out = '';
            open my $ph, '-|', @cmd or return ('', 1);
            { local $/; $out = <$ph>; }
            close $ph;
            my $rc = $? >> 8;
            return ($out, $rc);
        };

        # git init
        {
            my ($o, $rc) = $git_run->('git', 'init', '-b', 'main', $andre_live);
            # older git may not support -b; try without
            if ($rc != 0) {
                ($o, $rc) = $git_run->('git', 'init', $andre_live);
            }
            ok($rc == 0, 'AC-10: git init succeeded in Andre-byte dir');
        }

        # set LOCAL identity (do NOT depend on global git config)
        system('git', '-C', $andre_live, 'config', 'user.email', 'test@test.invalid');
        system('git', '-C', $andre_live, 'config', 'user.name',  'test');

        # Switch to main branch if not already (compatibility with old git)
        {
            my ($branch_out, $rc_b) = $git_run->('git', '-C', $andre_live, 'rev-parse', '--abbrev-ref', 'HEAD');
            chomp($branch_out);
            if ($branch_out ne 'main') {
                system('git', '-C', $andre_live, 'checkout', '-b', 'main');
            }
        }

        # Initial commit on main
        {
            my $readme = "$andre_live/README.md";
            open my $fh, '>:raw', $readme or die "cannot write $readme: $!";
            print $fh "# test\n";
            close $fh;
            system('git', '-C', $andre_live, 'add', '.');
            my ($o, $rc) = $git_run->('git', '-C', $andre_live, 'commit', '-m', 'initial');
            ok($rc == 0, 'AC-10: initial commit on main succeeded');
        }

        # git worktree add <wt_path> -b ccpraxis-sandbox-workcopy
        {
            my ($o, $rc) = $git_run->(
                'git', '-C', $andre_live, 'worktree', 'add', $wt_path, '-b', 'ccpraxis-sandbox-workcopy'
            );
            ok($rc == 0, 'AC-10: git worktree add succeeded under Andre-byte live path');
        }

        # Commit on work-copy branch
        {
            my $wc_file = "$wt_path/work.txt";
            open my $fh, '>:raw', $wc_file or die "cannot write $wc_file: $!";
            print $fh "work copy change\n";
            close $fh;
            system('git', '-C', $wt_path, 'add', '.');
            system('git', '-C', $wt_path, 'config', 'user.email', 'test@test.invalid');
            system('git', '-C', $wt_path, 'config', 'user.name',  'test');
            my ($o, $rc) = $git_run->('git', '-C', $wt_path, 'commit', '-m', 'work-copy commit');
            ok($rc == 0, 'AC-10: commit on work-copy branch succeeded');
        }

        # (a) Parse real git worktree list --porcelain: work-copy path byte-identical
        {
            my ($porcelain, $rc) = $git_run->('git', '-C', $andre_live, 'worktree', 'list', '--porcelain');
            ok($rc == 0, 'AC-10a: git worktree list --porcelain succeeded');

            # Extract worktree paths from porcelain
            my @wt_paths;
            for my $line (split /\n/, $porcelain) {
                if ($line =~ /^worktree (.+)$/) { push @wt_paths, $1; }
            }
            # git resolves the MSYS /tmp mount to the Windows temp form in its output
            # (File::Temp gives /tmp/...; git outputs C:/Users/.../Temp/...), so compare on
            # the byte-identical basename which carries the é (c3a9) — the real round-trip
            # concern. Production passes winify'd Windows-form paths, so this form-difference
            # never arises there (p02 provision_state matches on canon_path both sides).
            my $wt_base = $wt_path; $wt_base =~ s{.*/}{};
            my $found_wt = grep { _normalize_path($_) =~ m{/\Q$wt_base\E$} } @wt_paths;
            ok($found_wt, 'AC-10a: work-copy appears in git worktree list --porcelain with the Andre-byte basename byte-identical (é round-trips)');
        }

        # (a) Parse git branch --list ccpraxis-sandbox-workcopy
        {
            my ($branch_out, $rc) = $git_run->(
                'git', '-C', $andre_live, 'branch', '--list', 'ccpraxis-sandbox-workcopy'
            );
            ok($rc == 0 && $branch_out =~ /ccpraxis-sandbox-workcopy/,
               'AC-10a: git branch --list shows ccpraxis-sandbox-workcopy exists');
        }

        # (b) Drive mergeback_plan/discard_plan on REAL paths; assert argv references real byte paths
        {
            my $mb = mergeback_plan({
                live              => $andre_live,
                worktree          => $wt_path,
                container_running => sub { 0 },
                marker_probe      => sub { undef },
            });
            is($mb->{guard}, 'clear', 'AC-10b: mergeback_plan guard=clear on real paths');

            my ($wr_mb) = grep { $_->{op} eq 'worktree_remove' } @{ $mb->{steps} };
            is($wr_mb->{argv}[-1], $wt_path,
               'AC-10b: mergeback_plan worktree_remove argv references real Andre-byte wt path');

            # All git steps use -C <andre_live>
            for my $step (@{ $mb->{steps} }) {
                next if $step->{op} eq 'confirm';
                my @av = @{ $step->{argv} };
                is($av[0], 'git', "AC-10b: mergeback step '$step->{op}' argv[0] is git");
                is($av[1], '-C',  "AC-10b: mergeback step '$step->{op}' argv[1] is -C");
                is($av[2], $andre_live, "AC-10b: mergeback step '$step->{op}' argv[2] is real Andre-byte live path");
            }

            my $dp = discard_plan({
                live              => $andre_live,
                worktree          => $wt_path,
                container_running => sub { 0 },
                marker_probe      => sub { undef },
            });
            is($dp->{guard}, 'clear', 'AC-10b: discard_plan guard=clear on real paths');

            my ($wr_dp) = grep { $_->{op} eq 'worktree_remove' } @{ $dp->{steps} };
            is($wr_dp->{argv}[-1], $wt_path,
               'AC-10b: discard_plan worktree_remove argv references real Andre-byte wt path');
        }

        # (c) Optional: execute discard worktree_remove + branch_force_delete, assert gone
        SKIP: {
            # Build the discard plan on real paths
            my $dp = discard_plan({
                live              => $andre_live,
                worktree          => $wt_path,
                container_running => sub { 0 },
                marker_probe      => sub { undef },
            });

            my ($wr_step) = grep { $_->{op} eq 'worktree_remove'    } @{ $dp->{steps} };
            my ($bd_step) = grep { $_->{op} eq 'branch_force_delete' } @{ $dp->{steps} };

            skip 'AC-10c: discard steps not emitted (unexpected)', 3
                unless $wr_step && $bd_step;

            # Execute worktree_remove
            my $wr_rc = system(@{ $wr_step->{argv} });
            ok($wr_rc == 0 || !-d $wt_path,
               'AC-10c: worktree_remove succeeded or worktree already gone');

            # Execute branch_force_delete
            my $bd_rc = system(@{ $bd_step->{argv} });
            ok($bd_rc == 0, 'AC-10c: branch_force_delete succeeded');

            # Verify worktree and branch are actually gone
            my ($wt_list, $rc_wl) = $git_run->('git', '-C', $andre_live, 'worktree', 'list', '--porcelain');
            my $wt_still_present = $wt_list =~ /ccpraxis-sandbox-workcopy/;
            ok(!$wt_still_present, 'AC-10c: work-copy worktree is gone after discard');
        }
    }
}

# =====================================================================
# AC-11: structural -- both SKILL.md frontmatter (folded into steward)
# =====================================================================

{
    my $skill_merge_path   = "$Bin/../../../steward/skills/mergeback-sandboxed-ccpraxis-workcopy/SKILL.md";
    my $skill_discard_path = "$Bin/../../../steward/skills/discard-sandboxed-ccpraxis-workcopy/SKILL.md";

    # mergeback SKILL.md must exist under steward
    ok(-f $skill_merge_path, 'AC-11: plugins/steward/skills/mergeback-sandboxed-ccpraxis-workcopy/SKILL.md exists');

    SKIP: {
        skip 'AC-11: mergeback/SKILL.md not yet created (expected red)', 8
            unless -f $skill_merge_path;

        my $fm = _parse_skill_frontmatter($skill_merge_path);
        ok(defined $fm, 'AC-11: mergeback/SKILL.md has parseable YAML frontmatter');
        is($fm->{name}, 'mergeback-sandboxed-ccpraxis-workcopy', 'AC-11: mergeback SKILL.md name=mergeback-sandboxed-ccpraxis-workcopy');
        like($fm->{description} // '', qr/Use when/i,
             'AC-11: mergeback SKILL.md description contains "Use when"');
        like($fm->{description} // '', qr/ALWAYS\s+confirm|always\s+confirm/i,
             'AC-11: mergeback SKILL.md description contains ALWAYS-confirm phrase');
        is($fm->{'user-invocable'}, 'true', 'AC-11: mergeback SKILL.md user-invocable: true');
        is($fm->{'host-only'},      'true', 'AC-11: mergeback SKILL.md host-only: true');
        ok(length($fm->{'argument-hint'} // ''), 'AC-11: mergeback SKILL.md has non-empty argument-hint');
        like($fm->{'allowed-tools'} // '', qr/AskUserQuestion/,
             'AC-11: mergeback SKILL.md allowed-tools includes AskUserQuestion');
    }

    # discard/SKILL.md must exist -- FAILS RED until created
    ok(-f $skill_discard_path, 'AC-11: plugins/steward/skills/discard-sandboxed-ccpraxis-workcopy/SKILL.md exists');

    SKIP: {
        skip 'AC-11: discard/SKILL.md not yet created (expected red)', 8
            unless -f $skill_discard_path;

        my $fm = _parse_skill_frontmatter($skill_discard_path);
        ok(defined $fm, 'AC-11: discard/SKILL.md has parseable YAML frontmatter');
        is($fm->{name}, 'discard-sandboxed-ccpraxis-workcopy', 'AC-11: discard SKILL.md name=discard-sandboxed-ccpraxis-workcopy');
        like($fm->{description} // '', qr/Use when/i,
             'AC-11: discard SKILL.md description contains "Use when"');
        like($fm->{description} // '', qr/ALWAYS\s+confirm|always\s+confirm/i,
             'AC-11: discard SKILL.md description contains ALWAYS-confirm phrase');
        is($fm->{'user-invocable'}, 'true', 'AC-11: discard SKILL.md user-invocable: true');
        is($fm->{'host-only'},      'true', 'AC-11: discard SKILL.md host-only: true');
        ok(length($fm->{'argument-hint'} // ''), 'AC-11: discard SKILL.md has non-empty argument-hint');
        like($fm->{'allowed-tools'} // '', qr/AskUserQuestion/,
             'AC-11: discard SKILL.md allowed-tools includes AskUserQuestion');
    }

    # Cross-reference: mergeback related => discard; discard related => mergeback
    SKIP: {
        skip 'AC-11: SKILL.md files not both present yet (expected red)', 2
            unless -f $skill_merge_path && -f $skill_discard_path;

        my $fm_m = _parse_skill_frontmatter($skill_merge_path);
        my $fm_d = _parse_skill_frontmatter($skill_discard_path);
        like($fm_m->{related} // '', qr/discard/,   'AC-11: mergeback SKILL.md related includes discard');
        like($fm_d->{related} // '', qr/mergeback/,  'AC-11: discard SKILL.md related includes mergeback');
    }
}

# =====================================================================
# AC-12: structural -- marketplace.json: selfhost entry removed (folded into steward) + pre-existing preserved
# =====================================================================

{
    my $market_path = "$Bin/../../../.claude-plugin/marketplace.json";
    ok(-f $market_path, 'AC-12 prereq: marketplace.json exists');

    SKIP: {
        skip 'AC-12: marketplace.json not found', 12
            unless -f $market_path;

        open my $fh, '<:raw', $market_path or die "cannot open $market_path: $!";
        my $raw = do { local $/; <$fh> }; close $fh;
        my $mj = eval { JSON::PP::decode_json($raw) };
        ok(!$@, 'AC-12: marketplace.json parses as valid JSON');

        my @plugins = @{ $mj->{plugins} // [] };
        my %by_name = map { $_->{name} => $_ } @plugins;

        # selfhost entry must be ABSENT -- the two verbs were folded into steward's skills
        ok(!exists $by_name{selfhost}, 'AC-12: marketplace.json has NO selfhost entry (folded into steward)');
        is($by_name{steward}{source}, './steward', 'AC-12: steward source=./steward (host of the folded skills)');
        like($by_name{steward}{description} // '', qr/mergeback-sandboxed-ccpraxis-workcopy/,
             'AC-12: steward description advertises the folded mergeback verb');

        # All seven pre-existing entries must still be present (append, not replace)
        for my $name (qw(beacon backpack sandbox steward blueprint butler todo)) {
            ok(exists $by_name{$name}, "AC-12: pre-existing entry '$name' still present in marketplace.json");
        }
    }
}

# =====================================================================
# Helpers
# =====================================================================

# Normalize a path for comparison (forward slashes, no trailing slash)
sub _normalize_path {
    my ($p) = @_;
    $p =~ s|\\|/|g;
    $p =~ s|/+$||;
    return $p;
}

# Parse YAML frontmatter from a SKILL.md file.
# Returns a hashref of key => value from the --- ... --- block, or undef.
# Minimal parser: no YAML module needed; keys are simple scalars.
sub _parse_skill_frontmatter {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    my @lines = <$fh>;
    close $fh;

    return undef unless @lines && $lines[0] =~ /^---\s*$/;

    my %fm;
    my $last_key;
    for my $i (1 .. $#lines) {
        my $line = $lines[$i];
        chomp $line;
        last if $line =~ /^---\s*$/;
        # Simple key: value
        if ($line =~ /^([\w-]+)\s*:\s*(.*)$/) {
            my ($k, $v) = ($1, $2);
            $v =~ s/^\s*["']?|["']?\s*$//g;  # strip optional quotes
            $fm{$k} = $v;
            $last_key = $k;
        } elsif ($line =~ /^\s+-\s*(.+)$/ && defined $last_key) {
            # YAML list item under the last key (e.g. related: \n  - discard)
            my $item = $1;
            $item =~ s/^\s*["']?|["']?\s*$//g;
            $fm{$last_key} = length($fm{$last_key} // '') ? "$fm{$last_key} $item" : $item;
        }
    }
    return %fm ? \%fm : undef;
}

# =====================================================================
# AC-14 — red-team MEDIUM: fleet_live/guard fail SAFE. A container probe that
# DIES (throws) must be treated as LIVE (blocked), never silently cleared —
# a safety gate must not fail open.
# =====================================================================
is(fleet_live({ container_running => sub { die "podman exploded\n" }, marker_probe => sub { undef } }),
   1, 'AC-14: fleet_live=1 when the container probe throws (fail-safe, not fail-open)');
is(mergeback_guard({ container_running => sub { die "boom\n" }, marker_probe => sub { undef } }),
   'blocked', 'AC-14: mergeback_guard blocked when the container probe throws (fail-safe)');
# A dying MARKER probe (after container down) also fails safe -> blocked
is(fleet_live({ container_running => sub { 0 }, marker_probe => sub { die "stat failed\n" } }),
   1, 'AC-14: fleet_live=1 when the marker probe throws (fail-safe)');
# But a marker probe legitimately returning undef (no marker) + container down => clear (not an error)
is(fleet_live({ container_running => sub { 0 }, marker_probe => sub { undef } }),
   0, 'AC-14: fleet_live=0 when container down AND marker probe returns undef (no error — legitimately not live)');

# =====================================================================
# AC-15 — red-team HIGH: the CLI must query the SAME container engine the
# launcher/fleet uses (docker OR podman via detection), not a hardcoded bare
# 'podman' — else on a docker host the guard never sees the live container.
# =====================================================================
{
    my $script = "$Bin/../../scripts/ccpraxis-mergeback.pl";
    SKIP: {
        skip 'AC-15: ccpraxis-mergeback.pl not present', 2 unless -f $script;
        open my $fh, '<:raw', $script or die "cannot open $script: $!";
        my $src = do { local $/; <$fh> }; close $fh;
        ok(($src =~ /docker/ && $src =~ /podman/) || $src =~ /_detect_container_cli/,
           'AC-15: script detects the container engine (references docker AND podman, or a detect helper) — not a hardcoded podman-only probe');
        ok($src =~ /--version/ || $src =~ /_detect_container_cli/,
           'AC-15: script probes engine availability the launcher way (--version / shared _detect_container_cli)');
    }
}

done_testing();
