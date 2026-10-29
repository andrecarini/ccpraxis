#!/usr/bin/env perl
# platform: windows
# 167 -- oracle for t09-guard-hooks-stripping's guard-bash.sh
# changes (spec .ccpraxis-local-data/blueprints/tui-operator-feedback/specs/
# t09-guard-hooks-stripping-spec.md SS2.2/SS2.3/SS3/SS4).
#
# THIS IS GUARD-BASH.SH'S FIRST BEHAVIOR TEST, EVER (spec AC19 / scout open question 5).
# The scout confirmed only registration/route tests existed before this file
# (hooks-json-route-registration.t, the retired mark-wakeup-agent-dispatch coverage) -- neither
# exercises guard-bash.sh's own matcher logic. This file IS the "baseline before edit"
# the ledger's done criterion 5 demands for this hook: it is a FRESHLY-AUTHORED
# baseline, not an inherited one, exactly as AC19 rules. Run once against the pre-fix
# guard-bash.sh (AC5/AC7 expected RED -- no stripping exists yet, mirroring 106's own
# documented AC-16 pattern) and once green post-fix.
#
# WRITTEN BLIND TO THE IMPLEMENTATION.
#
# jq AVAILABILITY. guard-bash.sh hard-requires jq (bp_hook_require_jq, fail-closed) --
# unlike guard-git-mutations.sh's jq-or-perl bp_json_get. jq does not exist on this
# Windows host, so every subprocess assertion below is gated behind a runtime check and
# SKIPped on a jq-less host, matching the retired guard-judge-checks coverage's own documented
# convention -- a SKIP here reads as "not exercised on this host", never as a false
# green or a harness bug.
#
# TECHNIQUE NOTE (guard evasion). Every fixture reaches guard-bash.sh only as JSON
# payload TEXT in a temp file (Write tool / this test's own file writes), never as
# literal text in a Bash tool_input.command this session issues. The hook is invoked as
# a subprocess via `bash "$GPATH" < "$PFILE"`.
#
# Runs standalone: perl this file
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use JSON::PP;
use Cwd ();

(my $HOOKS = "$Bin/../../hooks") =~ s{\\}{/}g;
my $GUARD  = "$HOOKS/guard-bash.sh";

ok(-f $GUARD, 'guard-bash.sh exists at plugins/butler/hooks/guard-bash.sh')
    or BAIL_OUT('subject hook missing');

# Kept distinct from $HAVE_JQ below: one case (AC17) removes perl from PATH, and
# the shim is written in perl, so that case is only meaningful with a real jq.
my $HAVE_REAL_JQ = `command -v jq 2>/dev/null` ne '';
my $HAVE_JQ = $HAVE_REAL_JQ;

# A jq SHIM, so this host stops skipping the only assertions that exercise the
# hook rather than reading it.
#
# guard-bash.sh hard-requires jq (bp_hook_require_jq, fail-closed), and jq does
# not exist on the Git-for-Windows host. The behavioural half of this file was
# therefore skipped here -- twelve assertions that never ran anywhere a developer
# could see them, on a BLOCKING guard. That is the worst place to have coverage
# that only exists in principle: a false negative here is a prohibited command
# executing, and 20260819-164901-52d3 is exactly such a gap living undetected
# behind this skip.
#
# The shim implements ONE filter -- `.tool_input.command // empty` -- because
# that is the only jq invocation in the hook. It is deliberately not a general
# jq: if the hook ever grows a second filter, the shim prints nothing, the hook
# sees an empty command and exits 0, and the DENY cases below fail loudly rather
# than passing on a stub that quietly agrees with everything.
my $SHIM_DIR;
unless ($HAVE_JQ) {
    $SHIM_DIR = tempdir(CLEANUP => 1);
    open my $s, '>', "$SHIM_DIR/jq" or die "cannot write jq shim: $!";
    print {$s} <<'SHIM';
#!/usr/bin/env perl
use strict; use warnings; use JSON::PP;
my @a = grep { $_ ne '-r' } @ARGV;
my $filter = shift(@a) // '';
# Accept bp_json_get's parenthesised form, "(.tool_input.command) // empty", as
# well as the bare one. The hook now reads its payload through bp_json_get so it
# works without jq at all, and that helper wraps the path in parens. Parens and
# spacing are normalised away; anything that is not this ONE logical filter
# still dies, which is the narrowness this shim exists for.
my $norm = $filter;
$norm =~ s/[()]//g;
$norm =~ s/\s+/ /g;
$norm =~ s/^ | $//g;
die "jq shim: unsupported filter '$filter'\n"
    unless $norm eq '.tool_input.command // empty';
my $in = do { local $/; <STDIN> };
my $j = eval { JSON::PP->new->decode($in) } or exit 0;
my $v = eval { $j->{tool_input}{command} };
print $v if defined $v && !ref $v && length $v;
exit 0;
SHIM
    close $s;
    chmod 0755, "$SHIM_DIR/jq";
    $ENV{PATH} = "$SHIM_DIR" . ($^O eq 'MSWin32' ? ';' : ':') . $ENV{PATH};
    $HAVE_JQ = `command -v jq 2>/dev/null` ne '';
}
ok($HAVE_JQ, 'jq (real or shimmed) is available, so the behavioural cases below actually run');

my $J    = JSON::PP->new->canonical;
my $ROOT = tempdir(CLEANUP => 1);
sub fwd { (my $p = shift) =~ s{\\}{/}g; $p }

my %CLEAN_ENV = map { ($_ => $ENV{$_}) } grep { !/^BP_/ } keys %ENV;

my $pn = 0;
sub run_guard {
    my ($cmd, %extra_env) = @_;
    my $n = ++$pn;
    my $payload = $J->encode({ tool_name => 'Bash', tool_input => { command => $cmd } });
    my $pf = "$ROOT/payload.$n.json";
    open my $w, '>', $pf or die; print $w $payload; close $w;
    # bp_hook_gate requires all three of BP_LEDGER/BP_DIR/BP_PROJECT_ROOT.
    my %env = (%CLEAN_ENV, %extra_env,
               BP_LEDGER       => "$ROOT/fake-ledger.md",
               BP_DIR          => $ROOT,
               BP_PROJECT_ROOT => $ROOT,
               GPATH => fwd($GUARD), PFILE => fwd($pf));
    local %ENV = %env;
    open(my $f, '-|', 'bash', '-c', '"$GPATH" < "$PFILE" 2>&1') or die "bash: $!";
    my $o = do { local $/; <$f> }; close $f;
    return ($? >> 8, $o);
}

# PATH containing everything on the ambient PATH EXCEPT perl (t/67's own precedent).
# SUBTRACT THE DIRECTORIES THAT CONTAIN $name -- do not mirror every other
# executable into a new one.
#
# This used to build a shadow bin/ by symlinking every executable on PATH (plus
# /usr/bin, /bin, /usr/local/bin) except $name. Measured on this host that is
# 6401 symlinks, and in t/168 -- which had the identical helper -- it made that
# file the slowest in the repository by a wide margin: 237s, of which ~20s was
# creating them and ~167s was File::Temp's CLEANUP deleting them again at
# process exit. The teardown dominated because File::Path::rmtree is pure Perl
# walking one entry at a time through the MSYS layer; native `rm -rf` does the
# same directory in 1.4s. After this change t/168 runs in 0.6s.
#
# The intent is "a PATH on which $name cannot be found". Removing the
# directories that contain it expresses exactly that, costs one stat per PATH
# entry instead of thousands of symlinks, and creates nothing to clean up.
#
# It is also MORE faithful than the mirror was: the mirror silently dropped
# anything that was not a regular executable file, so the code under test ran
# under a PATH subtly unlike the real one. This keeps the real PATH minus $name.
sub path_without {
    my ($name) = @_;
    my @keep;
    for my $dir (split /:/, ($CLEAN_ENV{PATH} // '')) {
        next unless length $dir;
        next if -x "$dir/$name" || -x "$dir/$name.exe";
        push @keep, $dir;
    }
    return join ':', @keep;
}

# =====================================================================================
# AC1/AC3/AC3b (DC1/DC2) -- REMOVED (reason code SRC, package 16 batch-B fix round):
# these pinned literal bash source text (the ACCIDENT/ADVERSARY rationale comment,
# five `grep -Eq` regex strings, and a bash-only `ANCHOR_CLASS='...'` default branch)
# inside guard-bash.sh itself. Package 14 moved that whole matcher into
# BpHook::Guards::GuardBash::_gb_a/_anchor_for (plugins/butler/scripts/BpHook/Guards/
# GuardBash.pm) as perl qr// regexes; guard-bash.sh is now an 8-line exec shim with no
# inline matcher text left to pin. The underlying behaviors this block was guarding --
# quoted mentions of git checkout/rm -rf/firebase deploy/git stash ALLOW, the real
# unquoted invocations DENY, and BP_BASH_EXTRA_DENY matching -- are re-expressed
# behaviorally (not as source pins) in plugins/butler/tests/t/guards-remake-bash.t:
# GB-1/GB-2 (quoted-mention allow + real-invocation deny, including the exact GB-a
# line-1 text), GB-3 (rm -rf exemptions), and GB-4 (BP_BASH_EXTRA_DENY match/no-match).
# The command-position-anchor property AC3b asserted (openers bind, quotes don't) is
# exercised by the same GB-1/GB-2 quoted-mention cases. No behavior assertion is
# weakened; only the OLD monolith's now-nonexistent source text is dropped.
# =====================================================================================

SKIP: {
    skip 'jq is not installed on this host; guard-bash.sh hard-requires it (bp_hook_require_jq, fail-closed)', 12
        unless $HAVE_JQ;

    # =================================================================================
    # AC5 (DC4, observable behavior 1) -- a forbidden verb ONLY inside a quoted
    # argument is ALLOWED.
    # =================================================================================
    for my $row (
        [ 'git checkout, quoted mention' => q{perl x.pl --text "don't run git checkout"} ],
        [ 'rm -rf, quoted mention'       => q{perl x.pl --text "never run rm -rf on the repo root"} ],
        [ 'firebase deploy, quoted'      => q{perl x.pl --text "CI handles firebase deploy, not us"} ],
        [ 'git stash, quoted'            => q{perl x.pl --text "a prohibited git stash destroyed a fix-batch"} ],
    ) {
        my ($label, $cmd) = @$row;
        my ($rc, $out) = run_guard($cmd);
        is($rc, 0, "AC5: $label is ALLOWED (quoted mention, not a real invocation)") or diag("hook output: $out");
    }

    # =================================================================================
    # AC6 (DC4, observable behavior 2) -- a REAL unquoted invocation is DENIED.
    # =================================================================================
    {
        my ($rc, $out) = run_guard('git checkout main');
        is($rc, 2, 'AC6: "git checkout main" (unquoted, real invocation) is DENIED');
        like($out, qr/BLOCKED:/, 'AC6: stderr contains "BLOCKED:"');
        like($out, qr/\QCommand: git checkout main\E/, 'AC6: stderr contains "Command: git checkout main"');
    }

    # =================================================================================
    # AC7 (DC1, DC4, observable behavior 3) -- a command exceeding
    # BP_GUARD_MAX_STRIP_BYTES (default 8000) whose UNQUOTED tail is a real mutation is
    # still DENIED: stripping is skipped above the cutoff, never the match.
    # =================================================================================
    {
        my $pad = 'echo "' . ('x' x 8100) . '" && git checkout main';
        ok(length($pad) > 8000, 'AC7 fixture sanity: constructed command exceeds 8000 characters');
        my ($rc, $out) = run_guard($pad);
        is($rc, 2, 'AC7: a >8000-byte command with a real unquoted mutation in its tail is DENIED (raw-fallback catches it)')
            or diag("hook output: $out");
    }

    # =================================================================================
    # AC17 (DC4, observable behavior 12) -- bp_strip_shell_noise unavailable (perl
    # absent from PATH): behavior must be IDENTICAL to pre-t09 (raw match) -- i.e. the
    # AC5 quoted-mention case, which the RAW regex also matches (no quote-awareness),
    # must DEGRADE TO DENY, exactly as today's guard-bash.sh (unmodified) already
    # behaves for this exact input. NEVER allow unconditionally.
    # =================================================================================
  SKIP: {
        # UNREPRODUCIBLE UNDER THE SHIM, and saying so beats a red line that
        # means nothing. This case removes perl from PATH to prove the hook
        # degrades to raw matching when bp_strip_shell_noise cannot run. The jq
        # shim IS perl, so removing perl also removes the hook's JSON parser: it
        # then reads an empty command and exits 0 at the `[ -n "$CMD" ]` guard,
        # never reaching a matcher. The 0 that results is not the hook silently
        # allowing a mutation -- it is the hook never seeing one.
        #
        # On a host with real jq this runs exactly as before. Skipping is
        # honest; asserting 2 here would be asserting something the harness,
        # not the hook, determines.
        #
        # RETIRED on every host since the hook-core remake (macOS port,
        # 2026-10-29). guard-bash.sh now execs run-hook.sh, which exits 0
        # when perl cannot be started -- deliberately: every hook fails open
        # there (hook-core-spawn-budget.t S5f), and guards-remake-bash.t
        # lists this file's jq/perl-availability plumbing as LIB, not
        # re-expressed. There is no bash-side raw matcher left to degrade to.
        # The real-jq gate kept this off the Windows host; macOS has jq, ran
        # it, and got the remake's documented 0.
        skip 'AC17 pins the retired bash guard (raw-match deny without perl); the remake '
           . 'fails open without perl by design (hook-core-spawn-budget.t S5f)', 1;
        my $noperl = path_without('perl');
        my ($rc, $out) = run_guard(q{perl x.pl --text "don't run git checkout"}, PATH => $noperl);
        is($rc, 2, 'AC17: with perl unavailable, the quoted-mention case DEGRADES to raw-match DENY '
                 . '(today\'s pre-fix behavior) -- never silently allows')
            or diag("hook output: $out");
    }

    # =================================================================================
    # almanac 20260819-164901-52d3 -- the command-position boundary.
    #
    # Every matcher required the verb to follow start-of-string or [;&|<space>].
    # A quote or an opening paren is in neither class, so an invocation sitting
    # immediately after one was NOT matched. The report's own table, reproduced
    # here as executable cases:
    #
    #     sh -c ' git reset --hard'    DENY   (leading space)
    #     zsh -c 'git reset --hard'    ALLOW  <-- gap
    #     sh -e -c 'git reset --hard'  ALLOW  <-- gap
    #     echo $(git reset --hard)     ALLOW  <-- gap
    #
    # The first two differ by ONE SPACE. Whether a blocking guard fired depended
    # on incidental whitespace inside a quoted argument, which is not a property
    # anyone would predict or rely on.
    # =================================================================================
    for my $row (
        [ q{sh -c ' git reset --hard'},   'a shellword invocation with a leading space (already worked)' ],
        [ q{zsh -c 'git reset --hard'},   'a shellword invocation flush against the quote' ],
        [ q{sh -e -c 'git reset --hard'}, 'a shellword invocation with an intervening flag' ],
        [ q{echo $(git reset --hard)},    'a command substitution, verb flush against the paren' ],
        [ q{(git reset --hard)},          'a subshell -- `(` opens a command position' ],
        [ q{x=1; {git reset --hard; }},   'a brace group -- `{` opens a command position' ],
        [ q{(rm -rf /etc)},               'rm -rf inside a subshell' ],
    ) {
        my ($cmd, $why) = @$row;
        my ($rc, $out) = run_guard($cmd);
        is($rc, 2, "52d3: DENY -- $why") or diag("hook output: $out");
    }

    # The false-positive controls. Widening the boundary must not start matching
    # MENTIONS, which is the failure mode that makes a guard something people
    # route around rather than obey.
    for my $row (
        [ q{perl -e 'print "never git reset --hard"'}, 'a verb quoted inside prose, no shell carrier' ],
        [ q{git diff --stat},                          'read-only git' ],
        [ q{git stash list},                           'the explicitly allowed stash read' ],
    ) {
        my ($cmd, $why) = @$row;
        my ($rc, $out) = run_guard($cmd);
        is($rc, 0, "52d3 control: ALLOW -- $why") or diag("hook output: $out");
    }

    # The `rm -rf /tmp/...` control is kept separate from the loop above because
    # its ALLOW outcome depends on the environment two different ways, and only
    # one of them is safe to control for here:
    #
    #   1. GB-a's own literal-text exemption (52d3, the rule this file targets)
    #      matches the SUBSTRING "/tmp/" in the command text -- unaffected by
    #      the environment. The command below must keep that literal spelling
    #      so this remains a test of quote-stripping/matching, not of GB-a's
    #      exemption text.
    #   2. GB-h ("hygiene", a later rule in the same chain) independently
    #      resolves the actual filesystem target and checks it by STAT IDENTITY
    #      against the TMP/TEMP/TMPDIR roots (spec SS2.7: no hardcoded /tmp for
    #      those roots). Under a bare `perl file.t`, TMP is the real Windows
    #      temp dir and Git Bash's /tmp is bind-mounted on that same directory,
    #      so /tmp resolves inside TMP and GB-h allows. Under
    #      scripts/run-tests.pl's per-file sandbox, TMP/TEMP/TMPDIR are
    #      overridden to a fresh SUBdirectory, and /tmp is that subdirectory's
    #      PARENT -- outside TMP -- so GB-h correctly denies, per spec. That
    #      denial is right; it is just not what THIS control is about.
    #
    # So: keep the literal "/tmp/" text (exercises 52d3 exactly as before), but
    # point TMP/TEMP at wherever /tmp itself actually resolves ON THIS RUN, so
    # GB-h's stat-identity check independently agrees with GB-a regardless of
    # which runner invoked this file. Passed as %extra_env (not `local
    # $ENV{...}`): run_guard() builds the subprocess's environment from
    # %CLEAN_ENV, a snapshot of %ENV taken once at file-load time -- long
    # before this block runs -- so a live %ENV override here would never
    # reach it. %extra_env is layered on top of that snapshot specifically so
    # a single call can override it.
    {
        my $tmp_target = Cwd::abs_path('/tmp');
        my %tmp_env = (defined $tmp_target && length $tmp_target)
            ? (TMP => $tmp_target, TEMP => $tmp_target)
            : ();
        my ($rc, $out) = run_guard('rm -rf /tmp/scratch', %tmp_env);
        is($rc, 0, '52d3 control: ALLOW -- rm -rf under /tmp') or diag("hook output: $out");
    }
}

# ---------------------------------------------------------------------------
# THE GUARD MUST STILL ENFORCE WITH NO jq AT ALL.
#
# Bug report 20260901-133230-bcd8. This hook used to hard-require jq and read its
# payload with a direct `jq` call, so on a host without jq it blocked every Bash
# call instead of guarding anything -- and the jq check in bp-preflight.pl is
# skipped on win32, so nothing said so. It now reads through bp_json_get, which
# falls back to perl + JSON::PP.
#
# Everything above runs against a SHIM on PATH, so it exercises the jq branch.
# That proves the shim still matches; it does not prove the fallback works, and
# the fallback is what every jq-less host actually runs. So: scrub PATH of jq
# entirely and assert the guard still DENIES.
if ($HAVE_REAL_JQ) {
    diag('bcd8 NOT RUN: this host has a real jq, which cannot be removed from PATH '
       . 'without also removing the tools the harness needs. The case is meaningful '
       . 'only where jq is genuinely absent, which is the platform it is about.');
    ok(1, 'bcd8: skipped, real jq present (see diag)');
}
else {
    # PATH minus the shim directory only. Emptying PATH outright also removes
    # bash, which run_guard needs -- the first attempt did exactly that and the
    # file died at "Can't exec bash" rather than testing anything.
    my $sep = ($^O eq 'MSWin32') ? ';' : ':';
    my $nojq = join $sep, grep { $_ ne $SHIM_DIR } split /\Q$sep\E/, $ENV{PATH};

    my ($rc, $out) = run_guard('git reset --hard HEAD~1', PATH => $nojq);

    is($rc, 2, 'bcd8: with NO jq on PATH, a prohibited command is still DENIED')
        or diag("rc=$rc output: $out");
    like($out, qr/BLOCKED:/, 'bcd8: it blocks for the right reason, not a missing-parser abort')
        or diag("output: $out");

    # Non-vacuity: the same scrubbed PATH must still ALLOW something harmless.
    # Without this, a hook that blocked unconditionally -- the exact old bug --
    # would satisfy the assertion above.
    my ($rc2, $out2) = run_guard('git diff --stat', PATH => $nojq);
    is($rc2, 0, 'bcd8 non-vacuity: read-only git is still ALLOWED with no jq')
        or diag("rc=$rc2 output: $out2");
}

done_testing();
