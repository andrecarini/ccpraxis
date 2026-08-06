#!/usr/bin/env perl
# t/75-effort-and-profiles.t — immutable oracle for b23-effort-quality-and-turn-sizing.
#
# Derived ONLY from
# .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/specs/b23-effort-quality-and-turn-sizing-spec.md
# (C1..C8, §3, plus the vacuity gate). Four things are being built by this package, NONE of them
# exist on disk yet at the time this oracle was written:
#   1. effort plumbing (ledger `effort:` -> DAG `effort` column -> bp-orchestrator -> bp-launch.sh
#      -> `claude --effort <level>`) -- grepped: bp-launch.sh's two `claude` invocation sites pass
#      only --model/--max-turns/--dangerously-skip-permissions, never --effort.
#   2. BP_MAX_PARALLEL 2 -> 3 at bp-orchestrator.pl's two sites (_tunables_base's `// 2` and the
#      per-tick `local $ENV{BP_MAX_PARALLEL} = $t->{max_par} // 2`).
#   3. raised max_turns authoring defaults, documented in authoring-protocol/SKILL.md (today:
#      "backstop (default 80)").
#   4. the always-ask, no-default quality-profile question at authoring time (operator ruling R-03).
#
# WRITTEN BLIND TO THE FIX. Every assertion below is expected to fail on ABSENCE OF THE FEATURE
# (a missing flag, a stale default, missing doc prose), never on a Perl exception, a missing module,
# a wrong require path, or a bash syntax error — bp-launch.sh and bp-orchestrator.pl are both
# well-formed, callable scripts today; only the FOUR behaviours above are missing.
#
# TECHNIQUE: no existing butler test invokes bp-launch.sh directly (t/06/t/08/t/80/t/82 all inject
# a `launch` closure that stands in for it). Per the driver's explicit instruction, THIS file drives
# the real bp-launch.sh with a stub `claude` shadowing PATH (house style borrowed from
# t/82-worker-model-preference.t's FAKE_BACKEND: a fake binary on PATH, invoked via `bash -c` +
# `timeout`, argv captured to a delimited log file) so C1..C4 are asserted on the ACTUAL CONSTRUCTED
# COMMAND LINE bp-launch.sh hands to `claude`, per the spec's own C1 instruction ("assert on the
# built command, not a helper's return value"). This is NOT the launcher.pl/container-build class of
# test the project CLAUDE.md forbids spawning unguarded — bp-launch.sh here execs only a tiny fake
# shell script that sleeps ~2s and exits; every invocation is wrapped in `timeout` as a safety net.
# We are inside the sandbox (IS_SANDBOX=1 already set), so bp_require_sandbox never trips.
#
# C5/C6 are asserted in-process against bp-orchestrator.pl (required as a module, exactly like
# t/80/t/82: BpOrch::parse_dag called directly; BpOrch::run({...}) driven with injected
# now/sleep/http_get/http_post/spawn_judge seams and `once=>1` — never bp-orchestrator.pl's own CLI
# entry point, never launcher.pl, never a container).
#
# C7/C8 are asserted as textual invariants against the two SKILL.md files named in the write set
# (plugins/blueprint/skills/authoring-protocol/, plugins/blueprint/skills/create/) — the only
# testable surface for an authoring-time interactive protocol.
#
# =====================================================================================
# MANDATORY VACUITY GATE (spec's own standing rule, verified explicitly here):
#
#   * C3 ("absent effort -> no flag, byte-identical to today's command line") is negative-only and
#     passes trivially against an implementation that NEVER passes --effort at all (i.e. against
#     today's actual code). It is therefore asserted with the SAME comparison function used for
#     C1/C2: `strip_effort_pair()` + `normalize_argv()` compute the exact expected baseline argv
#     (cold and warm, byte-for-byte, every flag in order) and require C3's actual argv to equal it
#     EXACTLY, while C1/C2 require the actual argv to equal it exactly ONLY AFTER a single adjacent
#     ('--effort', <level>) pair is stripped out — and separately require that pair to have been
#     FOUND (`ok($found, ...)`) with the RIGHT VALUE. A never-pass-effort implementation satisfies
#     the C3 shape (nothing to strip, already equal) but FAILS C1/C2's "found" assertion outright.
#     This is asserted for BOTH call sites separately (C2's own per-site requirement) — the
#     cold-present/warm-present checks sit directly next to the cold-absent/warm-absent checks in
#     the SAME block, sharing the same ledger fixtures and comparison function.
#   * C4 asserts, in this order: (a) nothing was appended to the fake claude's call log (no argv
#     recorded at all — the strongest form of "nothing was launched"), (b) no runs/<pkg>.pid file
#     was written, (c) the package has no entry in runs/registry.json, and only THEN (d) that
#     bp-launch.sh exited non-zero, and (e) stderr names the cause. Asserting (a)-(c) before (d)
#     is deliberate: a script that prints an error to stderr and STILL execs claude would pass a
#     naive "check the exit code" gate; it is refused here on the stronger "nothing launched"
#     ground the spec names explicitly.
#   * C7's "no default" is likewise negative: the block below first asserts POSITIVELY that the
#     normal-vs-higher question is reachable (present, and framed as mandatory) in BOTH skill docs,
#     UNCONDITIONALLY runs the negative check right after (never behind a skip/conditional — a doc
#     that never mentions the question at all would otherwise pass the negative vacuously; both
#     halves must be read together, and the positive half is what would catch that).
# =====================================================================================

use strict;
use warnings;
use FindBin qw($Bin);

# The BP_MAX_PARALLEL default, read from bp-launch.sh rather than hardcoded.
# b23 raised it 2 -> 3; the operator reversed that on 2026-08-04 and it is 2
# again. C6 pinned the literal both times, so BOTH the raise and the reversal
# read as regressions here. What C6 protects is that the orchestrator's two
# sites agree with bp-launch.sh -- they HAD silently diverged (2 vs 3), which
# is the bug the literal could never catch. Derive it, and the assertion
# survives any future tuning while still catching divergence.
my $DEFAULT_PAR = do {
    open my $fh, '<', "$Bin/../../scripts/bp-launch.sh" or die "cannot read bp-launch.sh: $!";
    local $/; my $c = <$fh>; close $fh;
    my ($n) = $c =~ /BP_MAX_PARALLEL:-(\d+)/;
    die "no BP_MAX_PARALLEL default in bp-launch.sh\n" unless $n;
    $n + 0;
};

use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

(my $ROOT_BUTLER = "$Bin/../..") =~ s{\\}{/}g;
my $LAUNCH = "$ROOT_BUTLER/scripts/bp-launch.sh";

# bp-launch.sh hard-requires jq (bp-lib.sh's require_cmd) and exits before doing
# anything without it. jq ships in the container and not on the Windows host, so
# on a host run every launch-driven assertion inverts: the positive ones fail
# because nothing launched, and — worse — the NEGATIVE ones ("no --effort token",
# "nothing was launched", "no pid file") PASS VACUOUSLY, for the wrong reason.
# A group that can only pass vacuously is not coverage, so skip the whole thing
# rather than bank the false green.
my $HAVE_JQ = do { my $o = `jq --version 2>/dev/null`; (defined $o && $o =~ /jq/) ? 1 : 0 };
my $NO_JQ   = 'jq is not installed on this host; bp-launch.sh exits at require_cmd, so no launch '
            . 'happens and neither the positive NOR the negative assertions mean anything here';
my $ORCH   = "$ROOT_BUTLER/scripts/bp-orchestrator.pl";
(my $AUTH_SKILL   = "$Bin/../../../blueprint/skills/authoring-protocol/SKILL.md") =~ s{\\}{/}g;
(my $CREATE_SKILL = "$Bin/../../../blueprint/skills/create/SKILL.md")             =~ s{\\}{/}g;

ok(-e $LAUNCH,     "subject under test present: bp-launch.sh (path: $LAUNCH)");
ok(-r $ORCH,       "subject under test present: bp-orchestrator.pl (path: $ORCH)");
ok(-r $AUTH_SKILL, "subject under test present: authoring-protocol/SKILL.md (path: $AUTH_SKILL)");
ok(-r $CREATE_SKILL, "subject under test present: create/SKILL.md (path: $CREATE_SKILL)");

diag("IS_SANDBOX=" . ($ENV{IS_SANDBOX} // '(unset)') . " — bp-launch.sh's bp_require_sandbox gate");

require $ORCH;   # BpOrch:: — also requires bp-govern.pl etc transitively (bp-orchestrator.pl:52-59)

# ---------------------------------------------------------------------------
# shared fixture plumbing (house style: t/80/t/82)
# ---------------------------------------------------------------------------
my %CLEAN_ENV = map { ($_ => $ENV{$_}) } grep { !/^BP_/ } keys %ENV;
my $REAL_PATH = $CLEAN_ENV{PATH} // '/usr/bin:/bin';
my $ROOT = tempdir(CLEANUP => 1);
my $J = JSON::PP->new->canonical;

sub write_file {
    my ($path, $bytes) = @_;
    (my $dir = $path) =~ s{[/\\][^/\\]+$}{};
    make_path($dir) if length($dir) && !-d $dir;
    open my $w, '>', $path or die "write $path: $!";
    binmode $w; print $w $bytes; close $w;
}
sub read_file {
    my ($path) = @_;
    return undef unless -e $path;
    open my $r, '<', $path or return undef;
    binmode $r; my $c = do { local $/; <$r> }; close $r;
    return defined $c ? $c : '';
}

# A fake `claude`: records its own argv (delimited with \x1f so spaces/quotes in the prompt never
# break parsing) to $FAKE_CALLLOG, emits a stream-json init line carrying a session_id (so
# bp-launch.sh's own session-id capture loop is satisfied quickly), then stays alive for
# $FAKE_ALIVE_SECS (default 2) before exiting 0 — long enough to survive bp-launch.sh's own
# "did the coordinator die immediately" liveness check at the end of the script, which would
# otherwise misreport a legitimately-fast fake process as a crashed launch.
my $FAKEBIN = "$ROOT/fakebin";
make_path($FAKEBIN);
my $FAKE_CLAUDE = "$FAKEBIN/claude";
write_file($FAKE_CLAUDE, <<'SH');
#!/usr/bin/env bash
set -u
if [ -n "${FAKE_CALLLOG:-}" ]; then
  { printf 'CALL'; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "$FAKE_CALLLOG"
fi
printf '{"type":"system","subtype":"init","session_id":"fake-sid-%s"}\n' "$$"
sleep "${FAKE_ALIVE_SECS:-2}"
exit "${FAKE_EXIT:-0}"
SH
chmod 0755, $FAKE_CLAUDE or die "chmod $FAKE_CLAUDE: $!";

my $ctr = 0;

# mk_bp_dir: a fresh { project_root, data_dir, bp_dir } triple, isolated in $ROOT — bp-launch.sh's
# own bp_project_root()/bp_data_dir() honor BP_PROJECT_ROOT / CCPRAXIS_DATA_DIR explicitly, so this
# NEVER touches the live .ccpraxis-local-data/ (forbidden by the driver's instructions).
sub mk_bp_dir {
    my $n = ++$ctr;
    my $proj = "$ROOT/proj$n";
    my $data = "$proj/.ccpraxis-local-data";
    # Blueprint name is fixed ("T"), not derived from $n: each caller gets its OWN isolated
    # $data (a fresh CCPRAXIS_DATA_DIR), so there is no cross-case collision risk, and a fixed
    # name means callers never have to keep a separately-hardcoded blueprint-name literal in
    # sync with this counter (that mismatch is exactly the bug this comment replaced).
    my $bp   = "$data/blueprints/T";
    make_path("$proj", "$bp/packages", "$bp/runs");
    return ($proj, $data, $bp);
}

sub mk_ledger {
    my ($bp, $pkg, %fm) = @_;
    my @L = ('---', "package: $pkg", 'blueprint: T', 'status: pending',
             "write_set: p/$pkg/", "test_paths: p/$pkg/",
             'model: sonnet', 'max_turns: 80');
    push @L, "effort: $fm{effort}" if defined $fm{effort};
    push @L, 'last_updated: 2026-06-24T00:00:00Z', '---', '', "# $pkg", '',
             '## Next action', '', 'go', '';
    write_file("$bp/packages/$pkg.md", join("\n", @L) . "\n");
}

# run_launch: invokes the REAL bp-launch.sh with the fake claude shadowing PATH. Returns
# (rc, stdout, stderr, argv_or_undef, calllog_path) where argv_or_undef is the parsed
# \x1f-delimited argv the fake claude recorded, or undef if it was never invoked at all (the
# calllog is never even created in that case).
sub run_launch {
    my ($proj, $data, $bpname, $pkg, $extra_args, %envover) = @_;
    my $n = ++$ctr;
    my $calllog = "$data/CALL-$n.log";
    my $errfile = "$data/stderr-$n.txt";
    local %ENV = (%CLEAN_ENV, PATH => "$FAKEBIN:$REAL_PATH",
                  BP_PROJECT_ROOT => $proj, CCPRAXIS_DATA_DIR => $data,
                  IS_SANDBOX => 1, FAKE_CALLLOG => $calllog, FAKE_ALIVE_SECS => 2,
                  LAUNCH_BIN => $LAUNCH, ERRFILE => $errfile, %envover);
    open(my $fh, '-|', 'bash', '-c',
         'exec timeout 30 "$LAUNCH_BIN" "$@" 2>"$ERRFILE"', 'bash', $bpname, $pkg, @$extra_args)
        or die "bash: $!";
    my $out = do { local $/; <$fh> }; close $fh;
    my $rc  = $? >> 8;
    my $err = -e $errfile ? read_file($errfile) : '';
    my $argv;
    if (-e $calllog) {
        my $content = read_file($calllog) // '';
        # NOTE: do NOT split on "\n" — the recorded argv includes the multi-line dispatch
        # PROMPT itself, so a real newline appears INSIDE a field, not just between records.
        # Exactly one invocation is ever written to a given $calllog (a fresh path per
        # run_launch call), so the whole file (minus its own leading "CALL" and single
        # trailing "\n" terminator) is the one \x1f-delimited record.
        if ($content =~ /\S/) {
            $content =~ s/\ACALL//;
            $content =~ s/\n\z//;
            my @f = split /\x1f/, $content, -1;
            shift @f;    # drop the empty field before the first \x1f
            $argv = \@f;
        }
    }
    return ($rc, defined $out ? $out : '', $err, $argv, $calllog);
}

sub normalize_argv {   # blank out the (dynamic, template-generated) prompt text at index 1
    my (@a) = @_;
    $a[1] = 'PROMPT' if @a > 1;
    return @a;
}
sub strip_effort_pair {   # -> ($found, $value_or_undef, \@argv_with_pair_removed)
    my (@a) = @_;
    for my $i (0 .. $#a - 1) {
        next unless $a[$i] eq '--effort';
        my @out = @a;
        my $val = $out[$i + 1];
        splice(@out, $i, 2);
        return (1, $val, \@out);
    }
    return (0, undef, \@a);
}
sub expected_baseline {   # today's exact command line, no effort anywhere
    my (%o) = @_;   # kind => cold|warm, model, maxt, sid (warm only)
    my @b = ('-p', 'PROMPT');
    push @b, '--resume', $o{sid} if $o{kind} eq 'warm';
    push @b, '--output-format', 'stream-json', '--verbose',
             '--model', $o{model}, '--max-turns', $o{maxt},
             '--dangerously-skip-permissions';
    return @b;
}

# ===========================================================================
# C1 + C2 + C3 (asserted together, per the vacuity gate above) — bp-launch.sh's
# TWO real invocation sites, driven with a stub claude on PATH.
# ===========================================================================
SKIP: {
    skip $NO_JQ . ' (C1/C2/C3 NOT exercised)', 14 unless $HAVE_JQ;
    # Each of the four invocations below gets its OWN project/data dir (mk_bp_dir()) rather
    # than sharing one: bp-launch.sh's own count_running_global() counts every live PID
    # registered under $CCPRAXIS_DATA_DIR/blueprints/*/runs/registry.json, and the fake
    # claude stays alive for FAKE_ALIVE_SECS(=2)s — sharing one data dir across sequential
    # calls in the same block would let an earlier call's still-alive fake process count
    # against BP_MAX_PARALLEL(=2 today) and spuriously trip bp-launch.sh's OWN unrelated
    # concurrency cap (exit 3, "coordinators already running"), which is not what any of
    # C1/C2/C3 is testing.

    # ---- cold (fresh) launch, WITH effort in the ledger --------------------
    my ($proj1, $data1, $bp1) = mk_bp_dir();
    mk_ledger($bp1, 'p-eff', effort => 'high');
    my ($rc1, $out1, $err1, $argv1) = run_launch($proj1, $data1, 'T', 'p-eff', []);
    ok(defined $argv1, "C1/C2 setup: cold launch (p-eff) actually invoked claude")
        or diag("rc=$rc1 out=$out1 err=$err1");
    {
        # null-safe: an undef $argv1 (claude never invoked) must fail the checks
        # below outright, not skip them and not die — asserted unconditionally.
        my @a1 = defined $argv1 ? @$argv1 : ();
        my ($found, $val, $stripped) = strip_effort_pair(@a1);
        ok($found, "C2 (COLD site): --effort appears in the cold-launch command line");
        is($val, 'high', "C1: cold-launch --effort value matches the ledger's effort: high");
        is_deeply([ normalize_argv(@$stripped) ],
                   [ expected_baseline(kind => 'cold', model => 'sonnet', maxt => 80) ],
                   "C1/C3 shared baseline: cold argv minus the --effort pair equals today's exact command line")
            or diag("argv1=@{[ map { qq(\"$_\") } @a1 ]}");
    }

    # ---- warm (--resume) launch, WITH effort in the ledger ------------------
    my ($proj2, $data2, $bp2) = mk_bp_dir();
    mk_ledger($bp2, 'p-eff', effort => 'high');
    my ($rc2, $out2, $err2, $argv2) = run_launch($proj2, $data2, 'T', 'p-eff',
        ['--resume-session', 'sid-warm-eff-0001']);
    ok(defined $argv2, "C1/C2 setup: warm launch (p-eff) actually invoked claude")
        or diag("rc=$rc2 out=$out2 err=$err2");
    {
        my @a2 = defined $argv2 ? @$argv2 : ();
        my ($found, $val, $stripped) = strip_effort_pair(@a2);
        ok($found, "C2 (WARM/--resume site): --effort appears in the warm-launch command line");
        is($val, 'high', "C1: warm-launch --effort value matches the ledger's effort: high");
        is_deeply([ normalize_argv(@$stripped) ],
                   [ expected_baseline(kind => 'warm', model => 'sonnet', maxt => 80, sid => 'sid-warm-eff-0001') ],
                   "C1/C3 shared baseline: warm argv minus the --effort pair equals today's exact command line")
            or diag("argv2=@{[ map { qq(\"$_\") } @a2 ]}");
    }

    # ---- cold launch, NO effort in the ledger — must be byte-identical to
    #      today's baseline (C3), asserted with the SAME comparator as above.
    my ($proj3, $data3, $bp3) = mk_bp_dir();
    mk_ledger($bp3, 'p-noeff');   # no effort key at all
    my ($rc3, $out3, $err3, $argv3) = run_launch($proj3, $data3, 'T', 'p-noeff', []);
    ok(defined $argv3, "C3 setup: cold launch (p-noeff) actually invoked claude")
        or diag("rc=$rc3 out=$out3 err=$err3");
    {
        my @a3 = defined $argv3 ? @$argv3 : ();
        my ($found, $val, $stripped) = strip_effort_pair(@a3);
        ok(!$found, "C3 (COLD site): no --effort token anywhere when the ledger declares none");
        is_deeply([ normalize_argv(@a3) ],
                   [ expected_baseline(kind => 'cold', model => 'sonnet', maxt => 80) ],
                   "C3: cold argv with no ledger effort is byte-identical to today's command line")
            or diag("argv3=@{[ map { qq(\"$_\") } @a3 ]}");
    }

    # ---- warm launch, NO effort in the ledger -------------------------------
    my ($proj4, $data4, $bp4) = mk_bp_dir();
    mk_ledger($bp4, 'p-noeff');   # no effort key at all
    my ($rc4, $out4, $err4, $argv4) = run_launch($proj4, $data4, 'T', 'p-noeff',
        ['--resume-session', 'sid-warm-noeff-0002']);
    ok(defined $argv4, "C3 setup: warm launch (p-noeff) actually invoked claude")
        or diag("rc=$rc4 out=$out4 err=$err4");
    {
        my @a4 = defined $argv4 ? @$argv4 : ();
        my ($found, $val, $stripped) = strip_effort_pair(@a4);
        ok(!$found, "C3 (WARM/--resume site): no --effort token anywhere when the ledger declares none");
        is_deeply([ normalize_argv(@a4) ],
                   [ expected_baseline(kind => 'warm', model => 'sonnet', maxt => 80, sid => 'sid-warm-noeff-0002') ],
                   "C3: warm argv with no ledger effort is byte-identical to today's command line")
            or diag("argv4=@{[ map { qq(\"$_\") } @a4 ]}");
    }
}

# ===========================================================================
# C4 — an unknown effort value is refused, and NOTHING IS LAUNCHED.
# ===========================================================================
SKIP: {
    skip $NO_JQ . ' (C4 NOT exercised — its "nothing was launched" assertions would '
       . 'pass vacuously, since nothing launches here for an unrelated reason)', 5 unless $HAVE_JQ;
    my ($proj, $data, $bp) = mk_bp_dir();
    mk_ledger($bp, 'p-bad', effort => 'totally-bogus-level-zz');

    my ($rc, $out, $err, $argv, $calllog) = run_launch($proj, $data, 'T', 'p-bad', []);

    # (a) strongest form: nothing was even appended to the fake claude's call log.
    ok(!defined $argv, "C4 (a): claude's call log records NOTHING for an unknown effort value")
        or diag("argv=@{[ map { qq(\"$_\") } @{$argv || []} ]} rc=$rc out=$out err=$err");
    # (b) no pid marker for the package.
    ok(!-e "$bp/runs/p-bad.pid", "C4 (b): no runs/p-bad.pid was written — nothing launched");
    # (c) no registry entry for the package.
    my $reg_txt = read_file("$bp/runs/registry.json") // '';
    unlike($reg_txt, qr/"p-bad"/, "C4 (c): package has no entry in runs/registry.json");
    # (d) only now, the exit code.
    isnt($rc, 0, "C4 (d): bp-launch.sh exits non-zero on an unknown effort value");
    # (e) and a NAMED cause on stderr, not a silent refusal.
    like($err, qr/effort/i, "C4 (e): stderr names the cause (mentions 'effort')")
        or diag("stderr was: $err");
}

# ===========================================================================
# C5 — parse_dag output is byte-identical with/without the new `effort`
# column, and survives an adversarial cell containing the literal 'depends_on'.
# ===========================================================================
{
    my $table_no_effort = <<'MD';
# T

## Package status

| pkg | deliverable | depends_on | model | status |
|--|--|--|--|--|
| pkg-a | d | — | sonnet | pending |
| pkg-b | d | pkg-a | sonnet | pending |
MD

    my $table_with_effort = <<'MD';
# T

## Package status

| pkg | deliverable | depends_on | model | effort | status |
|--|--|--|--|--|--|
| pkg-a | d | — | sonnet | high | pending |
| pkg-b | d | pkg-a | sonnet | medium | pending |
MD

    # adversarial: an effort-column CELL literally contains the token 'depends_on'
    # (SYN-14: parse_dag latches onto the first pipe-row carrying that token as its header).
    my $adversarial_cell = 'depends_on_conflict';
    ok(index($adversarial_cell, 'depends_on') >= 0,
        "fixture sanity: the adversarial effort-column cell genuinely contains the literal 'depends_on'");
    my $table_adversarial = <<"MD";
# T

## Package status

| pkg | deliverable | depends_on | model | effort | status |
|--|--|--|--|--|--|
| pkg-a | d | — | sonnet | $adversarial_cell | pending |
| pkg-b | d | pkg-a | sonnet | medium | pending |
MD

    my $dag_baseline    = BpOrch::parse_dag($table_no_effort);
    my $dag_with_effort = BpOrch::parse_dag($table_with_effort);
    my $dag_adversarial = BpOrch::parse_dag($table_adversarial);

    is_deeply($dag_baseline, { 'pkg-a' => [], 'pkg-b' => ['pkg-a'] },
        "C5 setup sanity: the baseline (no effort column) table parses to the expected DAG shape");
    is_deeply($dag_with_effort, $dag_baseline,
        "C5: parse_dag output is byte-identical with vs without the new 'effort' column");
    is_deeply($dag_adversarial, $dag_baseline,
        "C5: parse_dag is unaffected even when an effort-column cell contains the literal 'depends_on' (SYN-14)");
}

# ===========================================================================
# C6 — BP_MAX_PARALLEL defaults to 3 at BOTH sites; the env var still overrides
# at both.
# ===========================================================================
{
    # ---- site 1: _tunables_base()'s own `$ENV{BP_MAX_PARALLEL} // 2` -------
    {
        local %ENV = %ENV;
        delete $ENV{BP_MAX_PARALLEL};
        my $t = BpOrch::_tunables_base();
        is($t->{max_par}, $DEFAULT_PAR,
            "C6 (site 1: _tunables_base default): BP_MAX_PARALLEL matches bp-launch.sh's default with no env override");
    }
    {
        local %ENV = %ENV;
        $ENV{BP_MAX_PARALLEL} = 7;
        my $t = BpOrch::_tunables_base();
        is($t->{max_par}, 7,
            "C6 (site 1): the env var still overrides _tunables_base's default");
    }

    # ---- site 2: the per-tick `local $ENV{BP_MAX_PARALLEL} = $t->{max_par} // 2`,
    #      observed live from inside the launch seam during a real BpOrch::run tick
    #      (no injected `tunables` hash — that would bypass _tunables()/site 2 entirely).
    my $USAGE_OK = $J->encode({
        five_hour => { utilization => 10, resets_at => '2099-01-01T00:00:00+00:00' },
        seven_day => { utilization => 5,  resets_at => '2099-01-01T12:00:00+00:00' },
    });
    my $on = 0;
    my $mk_orch_bp = sub {
        my $dir = "$ROOT/orchbp" . (++$on);
        make_path("$dir/packages", "$dir/runs");
        write_file("$dir/blueprint.md",
            "# T\n\n## Package status\n\n| pkg | deliverable | depends_on | model | status |\n"
            . "|--|--|--|--|--|\n| pkg1 | d | \x{2014} | sonnet | pending |\n");
        write_file("$dir/packages/pkg1.md",
            "---\npackage: pkg1\nblueprint: T\nstatus: pending\nwrite_set: p/pkg1/\ntest_paths: p/pkg1/\n"
            . "last_updated: 2026-06-24T00:00:00Z\n---\n# pkg1\n\n## Next action\n\ngo\n");
        write_file("$dir/creds.json", $J->encode({ claudeAiOauth => {
            accessToken => 'sk-ant-SCN-aaaaaaaaaaaaaaaaaaaa', refreshToken => 'sk-ant-SCNREF-bbbbbbbbbbbbbbbb',
            expiresAt => (time + 5 * 3600) * 1000, scopes => ['user:inference'],
            subscriptionType => 'max', rateLimitTier => 'x' } }));
        return $dir;
    };

    {
        local %ENV = %ENV;
        delete $ENV{BP_MAX_PARALLEL};
        my $dir = $mk_orch_bp->();
        my @seen;
        my $seam = sub { push @seen, $ENV{BP_MAX_PARALLEL}; return 0; };
        my $err;
        eval {
            BpOrch::run({ blueprint => 'T', bp_dir => $dir, creds_path => "$dir/creds.json",
                once => 1, now => sub { time }, sleep => sub { },
                http_get => sub { { status => 200, content => $USAGE_OK } },
                http_post => sub { { status => 200, content => '{}' } },
                spawn_judge => sub { 0 }, launch => $seam });
            1;
        } or $err = $@;
        ok(@seen >= 1, "C6 (site 2) setup: the launch seam fired at least once this tick")
            or diag("err=" . ($err // '(none)'));
        is((@seen ? $seen[0] : undef), $DEFAULT_PAR,
            "C6 (site 2: per-tick local export): BP_MAX_PARALLEL unset -> the per-tick export matches bp-launch.sh's default");
    }
    {
        local %ENV = %ENV;
        $ENV{BP_MAX_PARALLEL} = 9;
        my $dir = $mk_orch_bp->();
        my @seen;
        my $seam = sub { push @seen, $ENV{BP_MAX_PARALLEL}; return 0; };
        my $err;
        eval {
            BpOrch::run({ blueprint => 'T', bp_dir => $dir, creds_path => "$dir/creds.json",
                once => 1, now => sub { time }, sleep => sub { },
                http_get => sub { { status => 200, content => $USAGE_OK } },
                http_post => sub { { status => 200, content => '{}' } },
                spawn_judge => sub { 0 }, launch => $seam });
            1;
        } or $err = $@;
        ok(@seen >= 1, "C6 (site 2, override) setup: the launch seam fired at least once this tick")
            or diag("err=" . ($err // '(none)'));
        is((@seen ? $seen[0] : undef), 9, "C6 (site 2): the env var still overrides the per-tick export");
    }
}

# ===========================================================================
# C7 — authoring ALWAYS asks normal-vs-higher; there is NO DEFAULT.
# ===========================================================================
{
    my $auth_txt   = read_file($AUTH_SKILL)   // '';
    my $create_txt = read_file($CREATE_SKILL) // '';
    my $combined   = "$auth_txt\n$create_txt";

    # ---- positive: the question is actually reachable, and framed as mandatory.
    like($combined, qr/quality[\s-]?profile/i,
        "C7 (positive): a 'quality profile' concept is documented in the authoring skills");
    like($combined, qr/\bnormal\b/i, "C7 (positive): the 'normal' profile option is named");
    like($combined, qr/\bhigher\b/i, "C7 (positive): the 'higher' profile option is named");
    like($combined, qr/(always ask|must ask|asks? the user|no default|never default)/i,
        "C7 (positive): the doc frames the profile question as mandatory / undefaulted");

    # ---- negative: no phrasing anywhere establishes a default (asserted
    #      UNCONDITIONALLY, never behind a skip — see vacuity-gate note above).
    unlike($combined, qr/default(?:s|ed|ing)?\s+(?:to|is|of)\s+["']?normal\b/i,
        "C7 (negative): no prose defaults the quality profile to 'normal'");
    unlike($combined, qr/default(?:s|ed|ing)?\s+(?:to|is|of)\s+["']?higher\b/i,
        "C7 (negative): no prose defaults the quality profile to 'higher'");
    unlike($combined, qr/if\s+(?:not|un)(?:specified|stated|given|answered)[^.\n]{0,40}(?:normal|higher)/i,
        "C7 (negative): no fallback phrasing silently picks a profile when the user doesn't answer");

    # ---- defensive: neither script hardcodes a silent quality-profile default either.
    my $orch_src   = read_file($ORCH)   // '';
    my $launch_src = read_file($LAUNCH) // '';
    unlike("$orch_src\n$launch_src",
        qr/quality_profile\s*(?:\|\|=|\/\/=|=)\s*["']?(normal|higher)/i,
        "C7 (defensive): neither bp-orchestrator.pl nor bp-launch.sh hardcodes a quality-profile default");
}

# ===========================================================================
# C8 — the max_turns AUTHORING defaults are raised (above today's 80) and
# documented in the authoring protocol.
# ===========================================================================
{
    # RETARGETED BY b51 (SYN-21: a mandated later feature invalidating a done
    # sibling's assertion, owned and updated rather than left red).
    #
    # C8 originally required a NUMERIC max_turns default in the authoring prose.
    # That assertion was itself enforcing the duplication that caused three
    # silent divergences: b23 raised this prose 80 -> 150 and never touched
    # templates/package-ledger.md (still 80) or agents/bp-scout.md (still 15).
    # Prose that restates a number is another copy to drift, so b51 moved the
    # canonical value into plugins/butler/turn-caps.json and made the prose
    # POINT at it.
    #
    # C8's intent is preserved exactly: the authoring default is above the old
    # 80, and it is documented. Only the location of the number changed.
    my $auth_txt = read_file($AUTH_SKILL) // '';
    my $caps_path = "$Bin/../../turn-caps.json";
    my $caps_txt  = read_file($caps_path) // '';
    my ($canonical) = $caps_txt =~ /"coordinator_default"\s*:\s*(\d+)/;

    ok(defined $canonical,
        "C8 (setup): the canonical source declares a coordinator_default")
        or diag("no coordinator_default found in $caps_path");

    # null-safe sentinel (-1) so an absent match fails the numeric check outright rather than
    # skipping it — a skip here would be exactly the "condition is the failure state" anti-pattern.
    my $default_for_check = defined $canonical ? $canonical : -1;
    cmp_ok($default_for_check, '>', 80,
        "C8: the canonical max_turns authoring default has been raised above today's 80"
        . (defined $canonical ? " (found: $canonical)" : " (no default was found on disk)"));

    like($auth_txt, qr/turn-caps\.json/,
        "C8: the authoring protocol points at the canonical source instead of restating a literal");
}

done_testing();
