#!/usr/bin/env perl
# platform: any
# IMMUTABLE ORACLE for package 14-guards-remake batch 1 (blueprint
# hook-continuity-remake), GB-1..GB-15 and the applicable SH-1..SH-9 of
# specs/14-guards-remake-spec.md sec 3.1/4.3/4.4: the guard-bash successor
# (GuardBash), running on the package-03 hook core.
#
# hooks/guard-bash.sh and BpHook/Guards/GuardBash.pm (and its
# siblings Common.pm, Shell.pm) DO NOT EXIST YET. Every in-process call goes
# through GuardHarness::run_module(), which mirrors BpHook::main()'s own
# require-and-call contract, so a missing module fails open (rc 0) exactly
# as the real wrapper would -- legibly, never a crash in this file. Every
# [wrapper]/[shim] case spawns the real bash file at that path and gets a
# plain "No such file or directory" until the implementer writes it.
#
# WRITTEN BLIND TO THE IMPLEMENTATION: derived only from the spec text
# above, never from reading guard-bash.sh, its old separate validation-interlock counterpart or
# any other source hook.
#
# NOT RE-EXPRESSED (Decision 26/Decision 6 exemptions, and every case the
# spec's sec 4.4 "Not:" list retires; codes per sec 4.2):
#   old file / assertion label                          | code
#   ---------------------------------------------------- | ----
#   old headless-background file, cases D2/D3            | OTHER (mark-wakeup markers, retired)
#   old headless-background file, "hook file exists"     | SRC
#   old validation-interlock file, section C and F       | OTHER (moved to track-dispatch's oracle)
#   old validation-interlock file, ".drive-solo/"-only B | D3  (project-wide detection replaced by per-session)
#   old tree-interlock file, A6/A7/A15/A17               | REG/SRC
#   old tree-interlock file, A13                         | MSG (denial may not name the hatch)
#   old tree-interlock file, A14                         | LIB
#   old driver-guard-reach file, AC-16/AC-17              | SRC (the rest of that file is package 13's)
#   old quote-strip file, jq-availability plumbing        | LIB (bp_hook_require_jq/bp_json_get; the
#                                                            module never calls jq at all -- SH-1..SH-9)
#
# R9-RM3 (review M3): GB-9/GB-10 corpus gaps named by the review, re-expressed
# below where practical; anything not re-expressed is listed here with a
# code, per sec 4.2:
#   old file / assertion label                            | code | reason
#   ------------------------------------------------------ | ---- | ------
#   A2e (crafted marker content sanitised in the denial)   | MSG  | GB-10 already asserts the sanitised
#                                                                    role/blueprint/package appear in the
#                                                                    message (like/qr checks); a second,
#                                                                    adversarial-content variant adds no
#                                                                    new code path over the existing GB-10
#                                                                    assertions and _sanitize() is already
#                                                                    exercised by them.
#   A10a/A10b (misnamed or absent blueprints root)         | OTHER | _tree_check() returns undef whenever
#                                                                    $root fails -d (GuardBash.pm), which is
#                                                                    the SAME early-return GB-10's own setup
#                                                                    already relies on implicitly (no
#                                                                    blueprints/ dir -> no scan); not an
#                                                                    independently observable branch to
#                                                                    re-pin without reading the source.
#   VALIDATION_RE alternatives not individually pinned     | OTHER | GB-9's corpus below now covers every
#   (npx vitest/jest/mocha/playwright, pytest/prove,          |      | top-level alternative in the regex
#   go/cargo/flutter/dart test|analyze)                       |      | (R9-RM3 block); only the exact
#                                                                    | flutter/pytest spellings the old
#                                                                    | files used are re-expressed, not
#                                                                    | every permutation.
#
# Runs standalone: perl this file
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use File::Spec ();
use JSON::PP ();

BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }

use lib dirname(__FILE__) . '/../lib';
use GuardHarness;

# ---------------------------------------------------------------------------
# Ambient isolation for the WHOLE file, up front, before any fixture runs.
# R9-RM4 (review M4): GuardHarness.pm itself now isolates the environment
# (deletes BP_*/CCPRAXIS_*/CLAUDE_*, deletes any inherited BUTLER_STATE_DIR,
# pins a decoy HOME/USERPROFILE) unconditionally at "use GuardHarness;"
# above, so this block is redundant, not load-bearing. It is kept only so
# this file reads the same before/after "use GuardHarness" for a human
# skimming it; the PRIOR claim here that "every individual block wraps its
# own env changes in local %ENV = %ENV" was false (no such wrap exists
# anywhere in this file) and is removed rather than repeated.
# ---------------------------------------------------------------------------
delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
$ENV{CCPRAXIS_NO_WAKELOCK} = 1;

my $BUTLER_DIR = dirname(__FILE__) . '/../..';
(my $BPLIB = "$BUTLER_DIR/scripts/bp-lib.sh") =~ s{\\}{/}g;

sub read_bytes {
    my ($p) = @_;
    open(my $fh, '<:raw', $p) or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

# ---------------------------------------------------------------------------
# payload(%o) -- a Bash tool_input payload. %o: cmd, run_in_background,
# session_id, agent_id, transcript_path, cwd.
# ---------------------------------------------------------------------------
sub payload {
    my (%o) = @_;
    my $ti = { command => $o{cmd} };
    $ti->{run_in_background} = $o{run_in_background} if exists $o{run_in_background};
    my $p = { tool_name => 'Bash', tool_input => $ti };
    $p->{session_id}      = $o{session_id}      if exists $o{session_id};
    $p->{agent_id}        = $o{agent_id}         if exists $o{agent_id};
    $p->{transcript_path} = $o{transcript_path}  if exists $o{transcript_path};
    $p->{cwd}              = $o{cwd}              if exists $o{cwd};
    return $p;
}

# ---------------------------------------------------------------------------
# gb($payload, %env) -- GuardHarness::run_module for Guards::GuardBash.
# ---------------------------------------------------------------------------
sub gb {
    my ($p, %env) = @_;
    return GuardHarness::run_module('Guards::GuardBash', $p, env => \%env);
}

# ---------------------------------------------------------------------------
# marker helpers (spec sec 2.5 / 3.1 GB-d).
# ---------------------------------------------------------------------------
sub write_coordinator_marker {
    my ($bp_dir, $pkg, $content) = @_;
    make_path("$bp_dir/runs");
    open(my $fh, '>:raw', "$bp_dir/runs/$pkg.active-worker") or die $!;
    print {$fh} $content;
    close $fh;
}

sub write_worker_marker {
    my ($data_dir, $tool_use_id, %f) = @_;
    make_path("$data_dir/.drive-solo/workers");
    my $rec = {
        at => ($f{at} // time()),
        session_id => $f{session_id},
        subagent_type => $f{subagent_type},
        tool_use_id => $tool_use_id,
    };
    my $path = "$data_dir/.drive-solo/workers/$tool_use_id";
    open(my $fh, '>:raw', $path) or die $!;
    print {$fh} JSON::PP->new->utf8->canonical->encode($rec) . "\n";
    close $fh;
    if (exists $f{mtime}) { utime($f{mtime}, $f{mtime}, $path) }
    return $path;
}

sub write_meta_json {
    my ($transcript_path, $session_id, $agent_id, $tool_use_id) = @_;
    my $dir = dirname($transcript_path) . "/$session_id/subagents";
    make_path($dir);
    open(my $fh, '>:raw', "$dir/agent-$agent_id.meta.json") or die $!;
    print {$fh} JSON::PP->new->utf8->canonical->encode({ toolUseId => $tool_use_id });
    close $fh;
}

my $STALE_SECS = 180 * 60; # default CCPRAXIS_VALIDATION_STALE_MIN

# ===========================================================================
# SH-1/SH-2 -- static shape. Skipped legibly until the implementer writes
# the files (each is a real done criterion of THIS package, not of batch 1's
# test step, so a missing file is reported, not papered over).
# ===========================================================================
{
    my $wrapper = "$BUTLER_DIR/hooks/guard-bash.sh";
    my $module  = "$BUTLER_DIR/scripts/BpHook/Guards/GuardBash.pm";
    ok(-f $wrapper, 'SH-1 precondition: guard-bash.sh exists on disk')
        or diag("missing: $wrapper (package 14 has not written it yet)");
  SKIP: {
        skip 'SH-1: wrapper missing', 2 unless -f $wrapper;
        my $rc = system('bash', '-n', $wrapper);
        is($rc, 0, 'SH-1: bash -n on guard-bash.sh passes');
        my @lines = grep { /\S/ } split /\n/, (read_bytes($wrapper) // '');
        is($lines[-1] // '', 'exec bash "$d/run-hook.sh" Guards::GuardBash --pre ledger,driver -- "$@"',
           'SH-1: the exec line carries exactly the documented clause and module name');
    }
    ok(-f $module, 'SH-2 precondition: BpHook/Guards/GuardBash.pm exists on disk')
        or diag("missing: $module (package 14 has not written it yet)");
  SKIP: {
        skip 'SH-2: module missing', 2 unless -f $module;
        my $rc = system('perl', "-I$BUTLER_DIR/scripts", '-c', $module);
        is($rc, 0, 'SH-2: perl -c on GuardBash.pm passes');
        my $src = read_bytes($module) // '';
        $src =~ s/^\s*#.*$//mg;
        unlike($src, qr/\bsystem\s*\(|\bexec\s*\(|\bexec\s+\S|`|\bqx\b|open\s*\([^)]*\|/,
               'SH-2: the module source never spawns (no system/exec/backtick/qx/pipe-open)');
    }
}

# ===========================================================================
# GB-1/GB-2 -- GB-a rules, denies and allows, under BP_LEDGER set.
# ===========================================================================
{
    my %COORD_ENV = (BP_LEDGER => '/x/ledger.md');

    my @deny_cases = (
        ['git checkout main'                     => 'git checkout: real invocation'],
        ['git reset --hard HEAD~1'               => 'git reset --hard'],
        [q{sh -c ' git reset --hard'}             => 'shellword invocation, leading space'],
        [q{zsh -c 'git reset --hard'}             => 'shellword invocation flush against the quote'],
        [q{echo $(git reset --hard)}             => 'command substitution, verb flush against paren'],
        [q{(git reset --hard)}                   => 'subshell command position'],
        ['git stash'                              => 'git stash mutation'],
        [q{echo `git stash`}                      => 'git stash inside a backtick carrier'],
        ['rm -rf /srv/x'                          => 'rm -rf outside the allowed roots'],
        ['firebase deploy --project x'            => 'firebase deploy'],
        ['gcloud app deploy'                      => 'gcloud deploy'],
        ['npm publish'                            => 'npm publish'],
    );
    for my $c (@deny_cases) {
        my ($cmd, $label) = @$c;
        my $res = gb(payload(cmd => $cmd), %COORD_ENV);
        is($res->{rc}, 2, "GB-1/GB-2: $label -> deny") or diag("cmd: $cmd");
    }

    my @allow_cases = (
        [q{perl x.pl --text "don't run git checkout"}       => 'quoted mention: git checkout'],
        [q{perl x.pl --text "never run rm -rf on prod"}     => 'quoted mention: rm -rf'],
        [q{perl x.pl --text "CI handles firebase deploy"}   => 'quoted mention: firebase deploy'],
        [q{perl x.pl --text "a prohibited git stash broke it"} => 'quoted mention: git stash'],
        ['git stash list'                                    => 'git stash list (explicitly allowed)'],
        ['git stash show'                                    => 'git stash show (explicitly allowed)'],
        ['git diff --stat'                                   => 'read-only git'],
        [q{perl -e 'print "never git reset --hard"'}         => 'verb quoted inside prose, no shell carrier'],
    );
    for my $c (@allow_cases) {
        my ($cmd, $label) = @$c;
        my $res = gb(payload(cmd => $cmd), %COORD_ENV);
        is($res->{rc}, 0, "GB-1/GB-2: $label -> allow") or diag("cmd: $cmd");
    }

    my $res_git = gb(payload(cmd => 'git checkout main'), %COORD_ENV);
    is($res_git->{err}, "BLOCKED: git working-tree/history mutations are reserved for the orchestrator. Coordinators and workers change files only via Edit/Write.\nCommand: git checkout main\n",
       'GB-2: the exact GB-a line-1 text and "Command: <cmd>" line');
}

# ===========================================================================
# GB-3 -- rm -rf exemptions: /tmp/, BP_DIR, else deny (with or without BP_DIR).
# ===========================================================================
{
    my $tmp = tempdir(CLEANUP => 1);
    (my $bp_dir = "$tmp/bp") =~ s{\\}{/}g;
    make_path($bp_dir);
    my %env = (BP_LEDGER => '/x/ledger.md', BP_DIR => $bp_dir);

    is(gb(payload(cmd => 'rm -rf /tmp/x'), %env)->{rc}, 0, 'GB-3: rm -rf /tmp/x -> allow');
    is(gb(payload(cmd => "rm -rf $bp_dir/x"), %env)->{rc}, 0, 'GB-3: rm -rf <BP_DIR>/x -> allow');
    is(gb(payload(cmd => 'rm -rf /srv/x'), %env)->{rc}, 2, 'GB-3: rm -rf /srv/x -> deny');

    my %env_no_bpdir = (BP_LEDGER => '/x/ledger.md');
    is(gb(payload(cmd => 'rm -rf /srv/x'), %env_no_bpdir)->{rc}, 2,
       'GB-3: rm -rf /srv/x still denies with BP_DIR unset');
}

# ===========================================================================
# GB-4 -- BP_BASH_EXTRA_DENY.
# ===========================================================================
{
    my %env = (BP_LEDGER => '/x/ledger.md', BP_BASH_EXTRA_DENY => 'curl .*prod');
    is(gb(payload(cmd => 'curl https://api.prod.example/deploy'), %env)->{rc}, 2,
       'GB-4: a matching BP_BASH_EXTRA_DENY regex denies');
    my %env_bad = (BP_LEDGER => '/x/ledger.md', BP_BASH_EXTRA_DENY => '(');
    is(gb(payload(cmd => 'curl https://api.prod.example/deploy'), %env_bad)->{rc}, 0,
       'GB-4: an uncompilable BP_BASH_EXTRA_DENY regex never denies');
}

# ===========================================================================
# GB-5 -- unarmed, BP_LEDGER unset: every GB-a/b/c positive allows.
# ===========================================================================
{
    my %env = ();
    for my $c (
        ['git checkout main' => 'GB-a positive'],
        [q{echo x && pnpm run test}, 'GB-c-shaped positive without BP_ROLE'],
    ) {
        my ($cmd, $label) = @$c;
        is(gb(payload(cmd => $cmd), %env)->{rc}, 0, "GB-5: $label allows unarmed/no-ledger");
    }
    my %env_bg = (); # GB-b needs run_in_background regardless of ledger
    is(gb(payload(cmd => 'sleep 999', run_in_background => JSON::PP::true()), %env_bg)->{rc}, 0,
       'GB-5: GB-b positive (run_in_background) allows with BP_LEDGER unset');
}

# ===========================================================================
# GB-6 -- headless background.
# ===========================================================================
{
    my %env = (BP_LEDGER => '/x/ledger.md');
    my $res = gb(payload(cmd => 'pnpm run build', run_in_background => JSON::PP::true()), %env);
    is($res->{rc}, 2, 'GB-6: run_in_background true, headless -> deny');
    like($res->{err}, qr/run_in_background/, 'GB-6: message names run_in_background');
    like($res->{err}, qr/foreground/, 'GB-6: message names foreground');
    like($res->{err}, qr/coordinator/, 'GB-6: BP_ROLE empty -> message names coordinator');

    my %env_role = (BP_LEDGER => '/x/ledger.md', BP_ROLE => 'harvest-judge');
    my $res_role = gb(payload(cmd => 'pnpm run build', run_in_background => JSON::PP::true()), %env_role);
    is($res_role->{rc}, 2, 'GB-6: a non-coordinator role also denies');
    like($res_role->{err}, qr/harvest-judge/, 'GB-6: the message names the role when it is not coordinator');

    is(gb(payload(cmd => 'pnpm run build', run_in_background => JSON::PP::false()), %env)->{rc}, 0,
       'GB-6: run_in_background:false -> allow');
    is(gb(payload(cmd => 'pnpm run build'), %env)->{rc}, 0,
       'GB-6: run_in_background absent -> allow');
}

# ===========================================================================
# GB-7 -- the butler-hold exemption.
# ===========================================================================
{
    my %env = (BP_LEDGER => '/x/ledger.md');
    for my $c (
        ['butler-hold a1 b2' => 'sole butler-hold call, plain'],
        ['perl /x/butler-hold.pl a1' => 'sole butler-hold call, via perl'],
    ) {
        my ($cmd, $label) = @$c;
        is(gb(payload(cmd => $cmd, run_in_background => JSON::PP::true()), %env)->{rc}, 0,
           "GB-7: $label in the background -> allow");
    }
    for my $c (
        ['butler-hold x; sleep 3000' => 'butler-hold plus a trailing command'],
        ['butler-hold x && y'         => 'butler-hold chained with &&'],
        ['sleep 1'                    => 'not butler-hold at all'],
    ) {
        my ($cmd, $label) = @$c;
        is(gb(payload(cmd => $cmd, run_in_background => JSON::PP::true()), %env)->{rc}, 2,
           "GB-7: $label in the background -> deny");
    }
}

# ===========================================================================
# GB-8 -- judge checks.
# ===========================================================================
{
    my %env_judge = (BP_LEDGER => '/x/ledger.md', BP_ROLE => 'harvest-judge');
    for my $cmd (
        'pnpm run test',
        'npm test',
        'yarn run build',
        './node_modules/.bin/pnpm lint',
    ) {
        is(gb(payload(cmd => $cmd), %env_judge)->{rc}, 2, "GB-8: '$cmd' denies under harvest-judge");
    }
    is(gb(payload(cmd => q{echo "run pnpm test later"}), %env_judge)->{rc}, 0,
       'GB-8: a quoted mention allows even under harvest-judge');

    my %env_coord = (BP_LEDGER => '/x/ledger.md', BP_ROLE => 'coordinator');
    is(gb(payload(cmd => 'pnpm run test'), %env_coord)->{rc}, 0, 'GB-8: BP_ROLE=coordinator allows');
    my %env_other = (BP_LEDGER => '/x/ledger.md', BP_ROLE => 'resolve-judge');
    is(gb(payload(cmd => 'pnpm run test'), %env_other)->{rc}, 0, 'GB-8: BP_ROLE=resolve-judge allows');
    my %env_noledger = (BP_ROLE => 'harvest-judge');
    is(gb(payload(cmd => 'pnpm run test'), %env_noledger)->{rc}, 0, 'GB-8: BP_LEDGER unset allows');
}

# ===========================================================================
# GB-9 -- coordinator interlock (validation, rule a).
# ===========================================================================
{
    my $tmp = tempdir(CLEANUP => 1);
    (my $bp_dir = "$tmp/bp") =~ s{\\}{/}g;
    my %env = (BP_LEDGER => '/x/ledger.md', BP_DIR => $bp_dir, BP_PACKAGE => 'pkg1');

    write_coordinator_marker($bp_dir, 'pkg1', 'bp-implementer');
    for my $cmd (
        'timeout 3600 perl scripts/run-tests.pl',
        'perl -Ilib scripts/run-tests.pl',
        'pnpm run test',
    ) {
        is(gb(payload(cmd => $cmd), %env)->{rc}, 2, "GB-9: '$cmd' denies with a fresh writer marker");
    }
    for my $cmd (
        'cat scripts/run-tests.pl',
        "cp \\\nfoo bar",
        # A prose mention of a test command, quoted, is not a validation
        # invocation: strip_noise() masks the double-quoted span before the
        # VTEXT validation-shaped check runs, so "npm test" never surfaces
        # there. (Not "git commit -m ..." as originally drafted: GB-a rule 1
        # denies ANY git commit for a coordinator -- BP_LEDGER is set in
        # %env above -- before GB-d ever runs, so that command could never
        # exercise rule (a) at all; see spec sec 3.1 GB-a rule 1 and GB-d.)
        q{echo "note: npm test passes"},
    ) {
        is(gb(payload(cmd => $cmd), %env)->{rc}, 0, "GB-9: '$cmd' allows (not validation-shaped / not a real invocation)");
    }

    write_coordinator_marker($bp_dir, 'pkg1', 'bp-scout');
    is(gb(payload(cmd => 'pnpm run test'), %env)->{rc}, 0, 'GB-9: a non-writer marker allows');

    write_coordinator_marker($bp_dir, 'pkg1', '');
    is(gb(payload(cmd => 'pnpm run test'), %env)->{rc}, 0, 'GB-9: an empty marker allows');

    write_coordinator_marker($bp_dir, 'pkg1', 'bp-implementer');
    utime(time() - $STALE_SECS - 60, time() - $STALE_SECS - 60, "$bp_dir/runs/pkg1.active-worker");
    is(gb(payload(cmd => 'pnpm run test'), %env)->{rc}, 0, 'GB-9: a marker older than STALE_MIN allows');
}

# ===========================================================================
# GB-10 -- tree interlock (validation, rule b).
# ===========================================================================
{
    my $data = tempdir(CLEANUP => 1);
    (my $data_n = $data) =~ s{\\}{/}g;
    my $bp_root = "$data_n/blueprints";
    make_path($bp_root);
    my $self_bp  = "$bp_root/self-bp";
    my $other_bp = "$bp_root/other-bp";
    make_path("$self_bp/runs", "$other_bp/runs");
    my %env = (BP_LEDGER => '/x/ledger.md', BP_DIR => $self_bp, BP_PACKAGE => 'p1');

    # Deliberately NO self marker (self_bp/runs/p1.active-worker) written
    # here: rule (a) and the tree scan's SELF path both name that exact
    # file, so a FRESH WRITER self marker always trips rule (a) first (spec
    # sec 3.1 GB-d, "(a) The coordinator marker (2.5) is non-empty ... ->
    # deny (a)"), before rule (b)'s SELF-exclusion could ever be
    # distinguished from "no file at all". A self marker that is stale,
    # empty or non-writer would dodge (a), but at that point it is
    # indistinguishable from an absent file for (b)'s purposes too, since
    # skipping SELF "by exact string before counting" (sec 3.1) never
    # inspects the file's content -- there is no marker shape that trips
    # (a) shut while still probing (b)'s SELF-exclusion, so that exclusion
    # is not independently observable here. The tree-check assertions below
    # therefore exercise rule (b) alone; the final assertion in this block
    # is what still covers self's marker under rule (a).
    write_coordinator_marker($other_bp, 'op1', 'bp-implementer');
    my $res = gb(payload(cmd => 'pnpm run test'), %env);
    is($res->{rc}, 2, 'GB-10: a foreign fresh writer marker denies (tree interlock)');
    like($res->{err}, qr/bp-implementer/, 'GB-10: the message names the sanitised writer role');
    like($res->{err}, qr/other-bp/,       'GB-10: the message names the sanitised blueprint');
    like($res->{err}, qr/op1/,            'GB-10: the message names the sanitised package');
    # where-things-go/10 parked on this refusal, 2026-10-22.
    like($res->{err}, qr/not a reason to park or block/,
        'GB-10: the tree refusal says waiting is not a reason to park');

    write_coordinator_marker($other_bp, 'op1', 'bp-implementer');
    utime(time() - $STALE_SECS - 60, time() - $STALE_SECS - 60, "$other_bp/runs/op1.active-worker");
    is(gb(payload(cmd => 'pnpm run test'), %env)->{rc}, 0, 'GB-10: a stale foreign marker allows');

    write_coordinator_marker($other_bp, 'op1', 'bp-implementer');
    utime(time() + 3600, time() + 3600, "$other_bp/runs/op1.active-worker");
    # R9-B1 (driver ruling, review B1): SANCTIONED CHANGE to an existing
    # assertion -- this line previously asserted rc 2 ("treated as fresh ->
    # denies"), which the review found inverted against the old hook, spec
    # 3.1(b) ("fresh under the stale policy: future or unknown mtime = stale")
    # and spec GB-10 ("stale or future foreign marker allows"), and the old
    # tree-interlock A10f/B16 case (allow). Flipped to rc 0, A10f-shaped.
    is(gb(payload(cmd => 'pnpm run test'), %env)->{rc}, 0, 'GB-10 (R9-B1, A10f): a future-dated foreign marker is STALE under the stale policy -> allows');

    write_coordinator_marker($other_bp, 'op1', 'bp-implementer');
    my %env_off = (%env, CCPRAXIS_TREE_INTERLOCK_OFF => 1);
    is(gb(payload(cmd => 'pnpm run test'), %env_off)->{rc}, 0,
       'GB-10: CCPRAXIS_TREE_INTERLOCK_OFF=1 allows despite a fresh foreign marker');

    my $hatch = "$data_n/.tree-interlock-off";
    open(my $hfh, '>', $hatch) or die $!;
    close $hfh;
    is(gb(payload(cmd => 'pnpm run test'), %env)->{rc}, 0,
       'GB-10: a fresh .tree-interlock-off hatch file allows');
    utime(time() - 3660, time() - 3660, $hatch); # past the default 60-minute TTL
    my $res_expired = gb(payload(cmd => 'pnpm run test'), %env);
    is($res_expired->{rc}, 2, 'GB-10: a past-TTL hatch file is not honoured -> still denies');
    ok(!-e $hatch, 'GB-10: ...and the expired hatch file was deleted');

    my %env_a_only = (BP_LEDGER => '/x/ledger.md', BP_DIR => $self_bp, BP_PACKAGE => 'p1',
                       CCPRAXIS_TREE_INTERLOCK_OFF => 1);
    write_coordinator_marker($self_bp, 'p1', 'bp-implementer');
    is(gb(payload(cmd => 'pnpm run test'), %env_a_only)->{rc}, 2,
       'GB-10: the tree hatch never disables rule (a) -- self-blueprint writer marker still denies');
}

# ===========================================================================
# GB-11 -- driver interlock.
# ===========================================================================
{
    my $base = GuardHarness::fresh_state();
    my $sid  = 'gb11-s';
    ok(GuardHarness::arm($sid, 'driver'), 'GB-11 setup: session armed driver');

    my $data = tempdir(CLEANUP => 1);
    (my $data_n = $data) =~ s{\\}{/}g;
    my %env = (CCPRAXIS_DATA_DIR => $data_n);
    write_worker_marker($data_n, 'T1', session_id => $sid, subagent_type => 'bp-implementer');

    is(gb(payload(cmd => 'npm test', session_id => $sid), %env)->{rc}, 2,
       'GB-11: a main-thread npm test in the armed driving session denies (a)');

    my $tp = "$data_n/transcript.jsonl";
    write_meta_json($tp, $sid, 'a1', 'T1');
    is(gb(payload(cmd => 'npm test', session_id => $sid, agent_id => 'a1', transcript_path => $tp), %env)->{rc}, 0,
       'GB-11: a subagent whose meta.json binds it to T1 (the marker itself) allows');

    write_meta_json($tp, $sid, 'a2', 'T2');
    is(gb(payload(cmd => 'npm test', session_id => $sid, agent_id => 'a2', transcript_path => $tp), %env)->{rc}, 2,
       'GB-11: a subagent bound to T2 (a different, marker-less binding) still denies on T1');

    is(gb(payload(cmd => 'npm test', session_id => $sid, agent_id => 'a3', transcript_path => $tp), %env)->{rc}, 0,
       'GB-11: a subagent with no meta.json at all allows (fail open, cannot tell it apart)');
}

# ===========================================================================
# GB-12 -- Decision 3: another session's arm/marker never crosses sessions.
# ===========================================================================
{
    my $base = GuardHarness::fresh_state();
    my $sidA = 'gb12-a';
    my $sidB = 'gb12-b';
    ok(GuardHarness::arm($sidB, 'driver'), 'GB-12 setup: session B armed driver');

    my $data = tempdir(CLEANUP => 1);
    (my $data_n = $data) =~ s{\\}{/}g;
    my %env = (CCPRAXIS_DATA_DIR => $data_n);
    write_worker_marker($data_n, 'TB', session_id => $sidB, subagent_type => 'bp-implementer');

    is(gb(payload(cmd => 'npm test', session_id => $sidA), %env)->{rc}, 0,
       'GB-12: session A (unarmed) is unaffected by session B being armed driver');

    ok(GuardHarness::arm($sidA, 'driver'), 'GB-12 setup: session A now also armed driver');
    is(gb(payload(cmd => 'npm test', session_id => $sidA), %env)->{rc}, 0,
       "GB-12: session A, armed driver, is unaffected by session B's fresh marker (different session_id field)");
}

# ===========================================================================
# GB-13 -- strip parity with bp-lib.sh's bp_strip_shell_noise, in-process.
# ===========================================================================
{
    my $lib_src = read_bytes($BPLIB);
    ok(defined $lib_src && length $lib_src, 'GB-13 setup: bp-lib.sh is readable');
    my ($prog) = ($lib_src // '') =~ /bp_strip_shell_noise\s*\(\)\s*\{\s*perl\s+-0777\s+-ne\s+'(.*?)'\s*2>\/dev\/null\s*\n\}/s;
    ok(defined $prog && length $prog, 'GB-13 setup: extracted the bp_strip_shell_noise perl program body')
        or diag('could not locate/extract the program from bp-lib.sh');

    my $lib_strip = sub {
        my ($cmd) = @_;
        return undef unless defined $prog;
        my $out = '';
        my $ok = eval {
            open(my $capfh, '>', \$out) or die $!;
            local *STDOUT = $capfh;
            local $_ = $cmd;
            eval $prog; ## no critic
            close $capfh;
            1;
        };
        return $ok ? $out : undef;
    };
    my $mod_strip = sub {
        my ($cmd) = @_;
        local $@;
        my $ok = eval { require BpHook::Guards::Shell; 1 };
        return undef unless $ok;
        return eval { BpHook::Guards::Shell::strip_noise($cmd) };
    };

    my @corpus = (
        q{echo "hi # not a comment" # real comment},
        q{echo 'single $(quoted) `backtick`'},
        q{echo "double $(cmd) `bt` still live"},
        "cat <<'EOF'\nsome heredoc body\nEOF\n",
        "cat <<-EOF\n\ttabbed heredoc\nEOF\n",
        q{echo a && git checkout main},
        q{echo \# escaped hash not a comment},
        q{git commit -m "npm test passes"},
        '',
    );
    for my $cmd (@corpus) {
        my $expected = $lib_strip->($cmd);
        my $got = $mod_strip->($cmd);
        is($got, $expected, 'GB-13: Shell::strip_noise matches bp_strip_shell_noise for one corpus command')
            or diag('cmd: ' . (defined $cmd ? $cmd : '<undef>'));
    }
    is($mod_strip->(''), '', 'GB-13: empty input returns the empty string');
}

# ===========================================================================
# GB-14 -- order: a command both git-denied and validation-shaped prints
# only the GB-a message.
# ===========================================================================
{
    my $tmp = tempdir(CLEANUP => 1);
    (my $bp_dir = "$tmp/bp") =~ s{\\}{/}g;
    make_path($bp_dir);
    write_coordinator_marker($bp_dir, 'pkg1', 'bp-implementer');
    my %env = (BP_LEDGER => '/x/ledger.md', BP_DIR => $bp_dir, BP_PACKAGE => 'pkg1');

    my $cmd = 'git checkout main && pnpm run test';
    my $res = gb(payload(cmd => $cmd), %env);
    is($res->{rc}, 2, 'GB-14: a compound git+validation command denies');
    like($res->{err}, qr/git working-tree\/history mutations/, 'GB-14: the GB-a message is the one printed');
    unlike($res->{err}, qr/validation interlock/, 'GB-14: the validation-interlock message is NOT also printed');
}

# ===========================================================================
# GB-15 -- SH-1..SH-9 (SH-3/SH-4 process-budget halves).
# ===========================================================================
{
    my $tmp = tempdir(CLEANUP => 1);
    my (undef, $ppath_notapplies) = tempfile();
    open(my $fh1, '>:raw', $ppath_notapplies) or die $!;
    print {$fh1} JSON::PP->new->utf8->canonical->encode(payload(cmd => 'ls -la'));
    close $fh1;

    # SH-3: BP_LEDGER unset, session unarmed -> exit 0, no output, 0 perl.
    # The fixture carries a session_id for an UNARMED session (rather than
    # none at all) so the not-applies path is exercised for the reason the
    # spec gives, not by accident: run-hook.sh deliberately falls toward
    # spawning perl when no session id is readable at all (package 03's
    # design, so BpHook::main can still log/decide), so an absent session_id
    # would not actually prove "0 perl launches" means "guard-bash's --pre
    # ledger,driver clause didn't apply" -- it could just as well mean
    # run-hook.sh's own no-session-id fallback took a different bash-only
    # path for an unrelated reason.
    {
        my $sid = 'gb15-sh3-unarmed';
        my $res = GuardHarness::run_shim('guard-bash.sh', payload(cmd => 'ls -la', session_id => $sid), env => {});
        is($res->{rc}, 0, 'GB-15/SH-3: not-applies (no ledger, unarmed) -> exit 0');
        is($res->{out}, '', 'GB-15/SH-3: empty stdout');
        is($res->{err}, '', 'GB-15/SH-3: empty stderr');
        is(GuardHarness::count_lines($res->{shim_log}, 'perl'), 0, 'GB-15/SH-3: 0 perl launches');
        is(GuardHarness::count_lines($res->{shim_log}, 'jq'), 0, 'GB-15/SH-3: 0 jq launches');
    }

    # SH-4: BP_LEDGER set, applies path (a deny) -> exactly 1 perl, rc 2.
    {
        my $res = GuardHarness::run_shim('guard-bash.sh', payload(cmd => 'git checkout main'),
            env => { BP_LEDGER => '/x/ledger.md' });
        is($res->{rc}, 2, 'GB-15/SH-4: applies path (BP_LEDGER set, a deny) -> exit 2');
        is(GuardHarness::count_lines($res->{shim_log}, 'perl'), 1, 'GB-15/SH-4: exactly 1 perl launch');
        is(GuardHarness::count_lines($res->{shim_log}, 'jq'), 0, 'GB-15/SH-4: 0 jq launches');
    }
}

# ===========================================================================
# SH-5 -- run() leaves BpHook::parse_count() unchanged, deny and allow.
# ===========================================================================
{
    my %env = (BP_LEDGER => '/x/ledger.md');
    my $res_deny = gb(payload(cmd => 'git checkout main'), %env);
    is($res_deny->{parse_delta}, 0, 'SH-5: parse_count unchanged on a deny path');
    my $res_allow = gb(payload(cmd => 'git diff --stat'), %env);
    is($res_allow->{parse_delta}, 0, 'SH-5: parse_count unchanged on an allow path');
}

# ===========================================================================
# SH-6 -- budget and forbidden vocabulary on every deny collected above.
# ===========================================================================
{
    my %env = (BP_LEDGER => '/x/ledger.md');
    my @denies = (
        gb(payload(cmd => 'git checkout main'), %env),
        gb(payload(cmd => 'git stash'), %env),
        gb(payload(cmd => 'rm -rf /srv/x'), %env),
        gb(payload(cmd => 'firebase deploy'), %env),
        gb(payload(cmd => 'pnpm run build', run_in_background => JSON::PP::true()), %env),
    );
    is(scalar(@denies), 5, 'SH-6 setup: five deny fixtures collected');
    for my $i (0 .. $#denies) {
        my $res = $denies[$i];
        is($res->{rc}, 2, "SH-6: fixture $i is really a deny") or next;
        my @lines = split /\n/, $res->{err};
        pop @lines while @lines && $lines[-1] eq '';
        cmp_ok(scalar(@lines), '<=', 2, "SH-6: fixture $i has at most the guard-bash budget of 2 lines");
        for my $l (@lines) {
            cmp_ok(length($l), '<=', 160, "SH-6: fixture $i line length <= 160");
            unlike($l, qr/\.run-finished|stop-ok|\.subagent-guard\/force-stop|CCPRAXIS_[A-Z_]*_STOP_OK|MAX_BLOCKS|bp-watch|bp-continuity\.pl|bp-runstate/,
                   "SH-6: fixture $i line names no retired mechanism");
            unlike($l, qr/BP_[A-Z_]*_ACTION|_OFF\b|threshold/i,
                   "SH-6: fixture $i line names no disable-a-guard hatch");
        }
        is($res->{out}, '', "SH-6: fixture $i stdout is empty");
    }
}

# ===========================================================================
# SH-7 -- bad JSON, {} -> exit 0, no output. The truncated-payload row is
# AMENDED per Decision 25 (2)/(supersedes this row's old fail-open): a
# truncated Bash payload is now denied with the over-size remedy, because a
# real BpHook truncation only ever happens at 8 MiB, always over the new
# 1 MiB pre-decode cap.
# ===========================================================================
{
    my %env = (BP_LEDGER => '/x/ledger.md');
    for my $c (
        ['not json at all'                          => 'malformed JSON'],
        ['{}'                                        => 'empty object'],
    ) {
        my ($raw, $label) = @$c;
        my $res = gb($raw, %env);
        is($res->{rc}, 0, "SH-7: $label -> exit 0");
        is($res->{out}, '', "SH-7: $label -> empty stdout");
        is($res->{err}, '', "SH-7: $label -> empty stderr");
    }

    {
        my %e = %env;
        $e{BP_PAYLOAD_TRUNCATED} = 1;
        my $res = gb('{"tool_input":{"command":"git checkout', %e);
        is($res->{rc}, 2,
            'SH-7 (Decision 25 (2), AMENDED): truncated JSON -> denied with the over-size remedy');
        like($res->{err}, qr/script file/i,
            'SH-7: the truncated-payload denial names the over-size remedy')
            or diag("stderr: $res->{err}");
        is($res->{out}, '', 'SH-7: truncated JSON -> empty stdout');
    }
}

# ===========================================================================
# SH-9 -- opt-in timing block, gated, never asserted (Decision 33).
# ===========================================================================
{
  SKIP: {
        skip 'SH-9: opt-in timing run (set GUARDS_REMAKE_TIME=1 and run this file alone)', 1
            unless $ENV{GUARDS_REMAKE_TIME};
        pass('SH-9: opt-in timing harness placeholder -- run this file alone with '
           . 'GUARDS_REMAKE_TIME=1 to record medians against the package-01 item (g) '
           . 'floor + 100ms; wall time itself is never asserted here');
    }
}

# ===========================================================================
# Harness self-check -- confirms GuardHarness itself works, against a
# real EXISTING successor (stop-gate.sh, package 06), not guard-bash.sh.
# Proves a red result above is guard-bash's absence, not a harness defect.
# ===========================================================================
{
    my $stopgate = "$BUTLER_DIR/hooks/stop-gate.sh";
    ok(-f $stopgate, 'self-check precondition: stop-gate.sh (package 06) exists on disk');
    my $base = GuardHarness::fresh_state();
    my $res_wrapper = GuardHarness::run_wrapper($stopgate,
        { session_id => 'selfcheck-1', hook_event_name => 'Stop', stop_hook_active => JSON::PP::false() });
    is($res_wrapper->{rc}, 0, 'self-check: run_wrapper against the real stop-gate.sh (unarmed) allows');

    my $res_shim = GuardHarness::run_shim($stopgate,
        { session_id => 'selfcheck-2', hook_event_name => 'Stop', stop_hook_active => JSON::PP::false() });
    is($res_shim->{rc}, 0, 'self-check: run_shim against the real stop-gate.sh (unarmed) allows');
    is(GuardHarness::count_lines($res_shim->{shim_log}, 'perl'), 0,
       'self-check: run_shim reports 0 perl launches on stop-gate.sh\'s not-applies path (unarmed)');

    ok(GuardHarness::arm('selfcheck-3', 'manual'), 'self-check: GuardHarness::arm() armed a session');
    my $res_shim_armed = GuardHarness::run_shim($stopgate,
        { session_id => 'selfcheck-3', hook_event_name => 'Stop', stop_hook_active => JSON::PP::false() });
    is($res_shim_armed->{rc}, 2, 'self-check: run_shim against stop-gate.sh, now armed -> denies (applies path)');
    is(GuardHarness::count_lines($res_shim_armed->{shim_log}, 'perl'), 1,
       'self-check: ...with exactly 1 perl launch');

    # The three checks above all go through run_wrapper()/run_shim() -- a
    # REAL bash subprocess. Every ORDINARY (non-[wrapper]/[shim]) AC in this
    # whole package instead goes through GuardHarness::run_module(), the
    # in-process seam, which production's own BpHook::main() reaches only
    # after "perl -I<scripts>" (run-hook.sh:250) has put the scripts dir on
    # @INC for the WHOLE process, before it does
    # "require \"BpHook/\$relpath.pm\"" -- a require-by-RELATIVE-PATH string
    # that resolves only via @INC. Driver-verified implementation attempt 1
    # found run_module() issuing that exact require with no such directory
    # on @INC: the require silently failed, run() never ran at all, and
    # EVERY in-process AC in every guards-remake-*.t file failed open (rc 0)
    # for that reason -- invisible on the allow side (already rc 0) and
    # showing up only as a wrong-reason red on the deny side. This checks
    # run_module() itself, against a real EXISTING module this package did
    # not write (BpHook::StopGate, package 06) rather than guard-bash's own
    # GuardBash.pm, so a green result here cannot be explained by anything
    # this package's implementer did -- only by run_module() genuinely
    # requiring and calling an existing module's run().
    ok(GuardHarness::arm('selfcheck-run-module-armed', 'manual'),
       'self-check/run_module setup: a distinct session armed');
    my $res_module_armed = GuardHarness::run_module('StopGate',
        { session_id => 'selfcheck-run-module-armed', hook_event_name => 'Stop',
          stop_hook_active => JSON::PP::false() });
    is($res_module_armed->{rc}, 2,
       'self-check: run_module("StopGate", ...) against the real StopGate.pm, armed -> denies '
       . '(proves run_module really requires BpHook/StopGate.pm by relative path and calls its '
       . 'run(), rather than failing open silently)');

    my $res_module_unarmed = GuardHarness::run_module('StopGate',
        { session_id => 'selfcheck-run-module-unarmed', hook_event_name => 'Stop',
          stop_hook_active => JSON::PP::false() });
    is($res_module_unarmed->{rc}, 0,
       'self-check: run_module("StopGate", ...) against the real StopGate.pm, a DIFFERENT and '
       . 'never-armed session -> allows');
}

# ===========================================================================
# R9 -- regression round (review.md/redteam.md, fix-batch-first). Every
# assertion below is a NEW regression against the CURRENT implementation;
# see the per-id comment for what it targets.
# ===========================================================================

# ---------------------------------------------------------------------------
# R9-TH2 (redteam H2): "git -C <dir> <verb>" and "git -c k=v <verb>" must
# deny in GuardBash's own GB-a rule 1 (checkout/switch/restore/reset/clean/
# rebase/merge/commit/push), exactly as a flagless invocation does. CLAUDE.md
# tells agents to use "git -C" instead of "cd &&", making this the LIKELY
# spelling of a revert in this repo.
# ---------------------------------------------------------------------------
{
    my %env = (BP_LEDGER => '/x/ledger.md');
    for my $c (
        ['git -C /c/x checkout -- f.txt' => 'git -C <dir> checkout'],
        ['git -c core.x=y reset --hard'  => 'git -c k=v reset --hard'],
        ['git -C x stash'                => 'git -C <dir> stash'],
        ['git -C x push origin main'     => 'git -C <dir> push'],
    ) {
        my ($cmd, $label) = @$c;
        is(gb(payload(cmd => $cmd), %env)->{rc}, 2, "R9-TH2: $label -> deny") or diag("cmd: $cmd");
    }
    # a read-only invocation with -C must still allow.
    is(gb(payload(cmd => 'git -C /c/x status'), %env)->{rc}, 0,
       'R9-TH2: git -C <dir> status (read-only) -> allow');
}

# ---------------------------------------------------------------------------
# R9-TM2 (redteam M2, GuardBash half): bash -lc/eval/heredoc hide a
# coordinator git mutation from GB-a. GuardGitMutations already covers
# checkout/reset/clean/stash through these forms (guards-remake-git-
# mutations.t's own GG-1 corpus); push/commit/merge/rebase are GB-a's alone,
# and GB-a's shellword regex requires a SEPARATE "-c" token, missing the
# combined "-lc" spelling, and has no eval/heredoc check at all.
# ---------------------------------------------------------------------------
{
    my %env = (BP_LEDGER => '/x/ledger.md');
    for my $c (
        [q{bash -lc 'git push'}                    => q{bash -lc 'git push'}],
        [q{eval "git commit -m x"}                  => q{eval "git commit -m x"}],
        ["bash <<'EOF'\ngit push\nEOF"              => 'heredoc fed to bash containing git push'],
    ) {
        my ($cmd, $label) = @$c;
        is(gb(payload(cmd => $cmd), %env)->{rc}, 2, "R9-TM2: $label -> deny") or diag("cmd: $cmd");
    }
}

# ---------------------------------------------------------------------------
# never-halt/01 ESCALATED (reports/01-redteam.md S6): _strip_heredocs looks
# for a heredoc operator "<<WORD" with no regard to quoting, so a QUOTED
# '<<EOF' inside another word is wrongly treated as a real heredoc start,
# and everything after it on later lines is dropped as a "heredoc body" and
# never parsed at all -- including an unrelated real command on the next
# line. The fix belongs to BpHook.pm (only a real heredoc operator may start
# a heredoc), which is outside package 01's normal write set but was added
# to it for this escalation. Regression lives here because this is where
# heredoc stripping is already exercised (R9-TM2, above).
# ---------------------------------------------------------------------------
{
    my $tmp = tempdir(CLEANUP => 1);
    (my $repo = "$tmp/repo") =~ s{\\}{/}g;
    make_path("$repo/.git");
    my %env = (BP_LEDGER => '/x/ledger.md', CLAUDE_PROJECT_DIR => $repo);
    for my $c (
        [qq{grep -n '<<EOF' README.md\nrm -rf .git} => q{a quoted '<<EOF' inside a grep pattern, then rm -rf .git on the next line}],
        [qq{echo '<<X'\ncd Y} => q{a quoted '<<X' inside an echo argument, then cd on the next line}],
    ) {
        my ($cmd, $label) = @$c;
        is(gb(payload(cmd => $cmd, cwd => $repo), %env)->{rc}, 2, "never-halt/01 ESCALATED (redteam S6): $label -> deny")
            or diag("cmd: " . $cmd);
    }
}

# ---------------------------------------------------------------------------
# R9-TM3 (redteam M3): the stash list/show exemption is checked against the
# WHOLE command, not the matched occurrence, so "look, then pop" passes.
# ---------------------------------------------------------------------------
{
    my %env = (BP_LEDGER => '/x/ledger.md');
    is(gb(payload(cmd => 'git stash list && git stash pop'), %env)->{rc}, 2,
       'R9-TM3: git stash list && git stash pop -> deny (the pop is a real mutation)');
    is(gb(payload(cmd => 'git stash show; git stash drop'), %env)->{rc}, 2,
       'R9-TM3: git stash show; git stash drop -> deny');
}

# ---------------------------------------------------------------------------
# R9-TM1 (redteam M1): the validation interlock (GB-d rule a) misses command
# substitution, subshells and sh -c wrapping of a validation command, and
# also a bare single-test-file invocation, against a fresh writer marker.
# ---------------------------------------------------------------------------
{
    my $tmp = tempdir(CLEANUP => 1);
    (my $bp_dir = "$tmp/bp") =~ s{\\}{/}g;
    make_path($bp_dir);
    write_coordinator_marker($bp_dir, 'pkg1', 'bp-implementer');
    my %env = (BP_LEDGER => '/x/ledger.md', BP_DIR => $bp_dir, BP_PACKAGE => 'pkg1');

    for my $c (
        [q{$(npm test)}          => 'command substitution around npm test'],
        [q{(npm test)}           => 'subshell around npm test'],
        [q{bash -c 'npm test'}   => q{bash -c 'npm test'}],
        # This repo's own documented single-file test convention
        # (plugins/butler/tests/t/name.t via "perl <path>"), which the
        # driver named explicitly -- there is no VALIDATION_RE alternative
        # for a bare "perl <path>.t" invocation today.
        ['perl t/x.t'            => 'perl t/x.t (bare single-file test run)'],
    ) {
        my ($cmd, $label) = @$c;
        is(gb(payload(cmd => $cmd), %env)->{rc}, 2, "R9-TM1: $label denies with a fresh writer marker") or diag("cmd: $cmd");
    }
}

# ---------------------------------------------------------------------------
# R9-RM3 (review M3): GB-9/GB-10 corpus gaps -- the remaining VALIDATION_RE
# alternatives (npx vitest/jest/mocha/playwright, pytest/prove, go/cargo/
# flutter/dart test|analyze), A3 (deny, then retry after clearing), A11c (a
# fresh hatch survives -- i.e. is not itself deleted by an allowed call).
# ---------------------------------------------------------------------------
{
    my $tmp = tempdir(CLEANUP => 1);
    (my $bp_dir = "$tmp/bp") =~ s{\\}{/}g;
    make_path($bp_dir);
    write_coordinator_marker($bp_dir, 'pkg1', 'bp-implementer');
    my %env = (BP_LEDGER => '/x/ledger.md', BP_DIR => $bp_dir, BP_PACKAGE => 'pkg1');

    for my $cmd (
        'npx vitest run',
        'npx jest',
        'npx mocha',
        'npx playwright test',
        'pytest -x',
        'prove -v t/foo.t',
        'go test ./...',
        'cargo test',
        'flutter test',
        'dart test',
        'dart analyze',
    ) {
        is(gb(payload(cmd => $cmd), %env)->{rc}, 2, "R9-RM3: VALIDATION_RE alternative '$cmd' denies with a fresh writer marker")
            or diag("cmd: $cmd");
    }
}
{
    # A3: deny, then retry after clearing the marker.
    my $tmp = tempdir(CLEANUP => 1);
    (my $bp_dir = "$tmp/bp") =~ s{\\}{/}g;
    make_path($bp_dir);
    write_coordinator_marker($bp_dir, 'pkg1', 'bp-implementer');
    my %env = (BP_LEDGER => '/x/ledger.md', BP_DIR => $bp_dir, BP_PACKAGE => 'pkg1');
    is(gb(payload(cmd => 'pnpm run test'), %env)->{rc}, 2, 'R9-RM3 (A3): denies while the marker holds a writer');
    unlink("$bp_dir/runs/pkg1.active-worker");
    is(gb(payload(cmd => 'pnpm run test'), %env)->{rc}, 0, 'R9-RM3 (A3): allows on retry after the marker is cleared');
}
{
    # A11c: a FRESH hatch file allows, and is left in place (not deleted --
    # only a past-TTL hatch is deleted, per GB-10's own "expired hatch was
    # deleted" assertion above).
    my $data = tempdir(CLEANUP => 1);
    (my $data_n = $data) =~ s{\\}{/}g;
    my $bp_root = "$data_n/blueprints";
    make_path($bp_root);
    my $self_bp  = "$bp_root/self-bp";
    my $other_bp = "$bp_root/other-bp";
    make_path("$self_bp/runs", "$other_bp/runs");
    write_coordinator_marker($other_bp, 'op1', 'bp-implementer');
    my %env = (BP_LEDGER => '/x/ledger.md', BP_DIR => $self_bp, BP_PACKAGE => 'p1');
    my $hatch = "$data_n/.tree-interlock-off";
    open(my $hfh, '>', $hatch) or die $!;
    close $hfh;
    is(gb(payload(cmd => 'pnpm run test'), %env)->{rc}, 0, 'R9-RM3 (A11c): a fresh hatch file allows');
    ok(-e $hatch, 'R9-RM3 (A11c): ...and the fresh hatch file survives (is not deleted)');
}

# ---------------------------------------------------------------------------
# R9-RM4 (review M4), the refuse/BAIL_OUT half: run in a SEPARATE subprocess
# (BAIL_OUT would otherwise kill this whole file's own run). The child sets
# HOME to a FIXTURE "real home" (never this repo's actual ~/.claude) before
# loading GuardHarness, so GuardHarness's own load-time snapshot captures
# THAT path as "the real state root" -- then, after load, re-points
# BUTLER_STATE_DIR straight back at it (simulating a leaked ambient value
# surviving past isolation) and calls GuardHarness::arm(), which must
# BAIL_OUT rather than silently writing into it.
# ---------------------------------------------------------------------------
{
    my $fixture_home = tempdir(CLEANUP => 1);
    (my $fixture_home_n = $fixture_home) =~ s{\\}{/}g;
    my $lib_dir = "$BUTLER_DIR/tests/lib";
    my $prog =
        'local $ENV{HOME} = $ENV{FIXTURE_HOME}; local $ENV{USERPROFILE} = $ENV{FIXTURE_HOME}; ' .
        'require GuardHarness; ' .
        '$ENV{BUTLER_STATE_DIR} = "$ENV{FIXTURE_HOME}/.claude/butler-state"; ' .
        'GuardHarness::arm("r9rm4-sid", "manual"); print "SHOULD-NOT-REACH-HERE\n";';
    my (undef, $out_path) = tempfile();
    my (undef, $err_path) = tempfile();
    my $child_env = "FIXTURE_HOME=$fixture_home_n";
    system("env $child_env perl -I$lib_dir -e '$prog' > $out_path 2> $err_path");
    my $rc = ($? == -1) ? -1 : ($? >> 8);
    my $out = read_bytes($out_path) // '';
    my $err = read_bytes($err_path) // '';
    unlink $out_path, $err_path;
    isnt($rc, 0, 'R9-RM4: a child process that re-points BUTLER_STATE_DIR at a "real" HOME and calls arm() does NOT exit 0');
    unlike($out, qr/SHOULD-NOT-REACH-HERE/, 'R9-RM4: ...and never reaches the line after arm() -- BAIL_OUT stopped it');
    like($out . $err, qr/Bail out|hermetic/i, 'R9-RM4: ...with a hermeticity refusal message (Test::More::BAIL_OUT writes to stdout)');
}

$? = 0;
done_testing();
