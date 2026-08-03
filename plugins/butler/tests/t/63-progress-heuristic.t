#!/usr/bin/env perl
# t/63-progress-heuristic.t — immutable oracle for b11-progress-heuristic-turns-backstop.
#
# Derived ONLY from
# .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/specs/b11-progress-heuristic-turns-backstop-spec.md
# (section 3, C1..C8, plus the vacuity gate) and the two existing signals it replaces:
# BpOrch::progress_verdict and BpOrch::snapshot_progressed (bp-orchestrator.pl), whose old
# behaviour is asserted directly (required in-process) for contrast, never re-derived.
#
# WRITTEN BLIND TO ANY IMPLEMENTATION: plugins/butler/scripts/bp-progress.pl does not exist on
# disk yet. Every assertion against it is expected to fail on ABSENCE OF THE SCRIPT (perl's own
# "Can't open perl script ... No such file or directory" / a non-zero exit with no meaningful
# stdout from the `system()` call), never on a bug, missing module, or wrong path in THIS file.
#
# =====================================================================================
# INTERFACE CONTRACT ASSUMED BY THIS ORACLE -- bp-progress.pl does not exist, so nothing here is
# "confirmed against real source" (unlike t/82's bp-orchestrator.pl precedent); this section PINS
# the interface bp-progress.pl must satisfy, mirroring t/85-cache-state.t's own precedent of
# pinning a CLI contract ahead of an unwritten sibling script. The implementer's job is to match
# this, not the other way around.
#
#   CLI: perl bp-progress.pl verdict <bp> <pkg> [--now=EPOCH] [--repeat-flagged=0|1]
#        perl bp-progress.pl capped  <bp> <pkg> [--now=EPOCH]
#
#   - <bp>/<pkg> resolve exactly like bp-cache-state.pl's own convention (t/85 precedent),
#     itself mirroring bp-lib.sh's bp_dir/bp_ledger layout: CCPRAXIS_DATA_DIR/blueprints/<bp>/
#     packages/<pkg>.md, .../runs/<pkg>.jsonl, .../runs/registry.json. CCPRAXIS_DATA_DIR is the
#     existing env-var seam bp_data_dir() already reads. --now=EPOCH mirrors bp-cache-state.pl's
#     own injectable clock (needed so cadence/throttle fixtures don't depend on a moving wall
#     clock).
#   - `verdict` prints exactly one line "VERDICT\tREASON" to stdout (VERDICT one of
#     progressing|looping|stuck, REASON a non-empty one-line string), exit 0 always -- classifying
#     is this script's entire job, so even a maximally broken input must produce a verdict line,
#     never a language-level death (per C3's own "no ambiguous input may kill" framing, applied
#     to the process itself, not just the semantics).
#   - `--repeat-flagged=1` is how b10's already-fired mechanical repeat guard is CONSUMED as an
#     input (spec section 1: "consumes b10's repeat signal as an input rather than re-deriving
#     it"). When set, verdict returns "looping" immediately WITHOUT invoking the model seam (C6)
#     -- the hook already did the (free) classification; the (costly) semantic call must not
#     re-derive what is already known.
#   - The semantic classification itself is delegated to an INJECTED MODEL SEAM so this suite
#     runs offline/deterministically, per the task's own "no network, no real model calls"
#     requirement: the env var BP_PROGRESS_MODEL_CMD names a shell command. bp-progress.pl execs
#     it, writes the JSON-encoded transcript tail (an array of decoded jsonl objects) to its
#     stdin, and reads back exactly one line "VERDICT\tREASON" from its stdout. If the env var is
#     unset, the command fails to exec, exits non-zero, or its stdout does not parse as
#     "VERDICT\tREASON" with VERDICT in {progressing,looping,stuck} -- the model is being, in
#     effect, UNAVAILABLE, and C3 requires "progressing" with a stated reason.
#   - Bounded read: the transcript tail is read via bp-orchestrator.pl's existing seek-from-end
#     reader (_last_nonempty_line at bp-orchestrator.pl:853, or its already-shipped multi-line
#     sibling _tail_jsonl_objs at bp-orchestrator.pl:919, itself built on the same seek-from-end
#     discipline) -- reused via `require`, never reimplemented (C4).
#   - Throttle state persists at runs/<pkg>.progress-state.json: at minimum
#     {last_checked_at, last_verdict, last_reason}. A `verdict` call within
#     BP_PROGRESS_CADENCE_SEC (env, integer seconds, default assumed >0) of last_checked_at
#     returns the cached verdict/reason WITHOUT invoking the model seam again (C5 cadence half).
#   - Never-concurrent: a lock file at runs/<pkg>.progress.lock. A `verdict` call that finds this
#     lock already present must NOT invoke the model seam for that call (C5 concurrency half),
#     and must still emit a valid, non-crashing "progressing\tREASON" line (uncertainty rule,
#     C3's spirit applied to a locked-out tick).
#   - `capped` logs a DISTINCT condition to runs/orchestrator.log (JSON lines, one per line, the
#     house log shape already used by bp-orchestrator.pl's own `_log`) meaning "the heuristic
#     failed" -- pinned here as `type` containing the substring "heuristic" -- and never touches
#     the package's ledger file or registry.json (C7): reaching the cap is a signal about the
#     guard, not a package failure.
#
# SYN-23: nothing below cites a line number in bp-progress.pl (it doesn't exist). Line numbers
# cited against bp-orchestrator.pl (_last_nonempty_line:853, _tail_jsonl_objs:919,
# progress_verdict, snapshot_progressed) are grepped, not assumed.
#
# =====================================================================================
# MANDATORY VACUITY GATE (task's own standing rule, restated in the coordinator brief):
# C1 ("same command varied only cosmetically -> looping") and C2/C3 ("varied advancing work, and
# every ambiguous input -> progressing") are mutually constraining: a bp-progress.pl that always
# returns "looping" passes C1 and fails C2 and C3; one that always returns "progressing" passes
# C2 and C3 and fails C1. Both are driven off model-seam stubs that answer DIFFERENTLY per
# fixture (looping for C1's tail, progressing for C2's tail) so a bp-progress.pl that merely
# hardcodes a constant -- ignoring the seam entirely -- cannot satisfy both. An explicit
# cross-check after C3 asserts the C1 and C2 verdicts actually DIFFER, in the same file, so no
# constant-returning implementation of ANY kind (model-driven or hardcoded) can pass silently.
#
# C4/C5/C6 are negative-only ("no slurp", "not every tick", "not invoked") and each is preceded
# by a POSITIVE assertion that the operation in question actually happened first:
#   - C4: a POSITIVE well-formed-fixture read (a real epoch extracted) is asserted before the
#     10.3MB bounded-read / reader-reuse checks.
#   - C5: the model seam's invocation counter is asserted to have incremented at least once
#     (real activity happened) before the "cadence" and "lock" cases assert it does NOT
#     increment again.
#   - C6: the SAME fixture WITHOUT --repeat-flagged is asserted to invoke the model seam (proving
#     a semantic call WOULD otherwise occur) immediately before the --repeat-flagged=1 case
#     asserts the counter does NOT move.
# No SKIP appears anywhere in this file. Absence is always a FAILURE, never a skip.
# =====================================================================================

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use Cwd qw(abs_path);
use File::Temp qw(tempdir tempfile);
use File::Copy qw(copy);
use JSON::PP;

sub fwd { (my $p = shift) =~ s{\\}{/}g; $p }

my $TESTS  = fwd("$Bin");
my $BUTLER = fwd(abs_path("$Bin/../..") // "$Bin/../..");
my $PROJ   = fwd(abs_path("$Bin/../../../..") // "$Bin/../../../..");

my $SCRIPT          = "$BUTLER/scripts/bp-progress.pl";
my $ORCH_SCRIPT     = "$BUTLER/scripts/bp-orchestrator.pl";
my $REAL_TRANSCRIPT = "$PROJ/.ccpraxis-local-data/blueprints/sandbox-butler-overhaul/runs/b25-feedback-intake.jsonl";

diag("subject under test: $SCRIPT " . (-e $SCRIPT ? "(present)" : "(ABSENT -- every C1..C8 assertion below is expected to fail)"));

# The OLD signals being replaced. Required in-process (t/82's own house idiom) so C1/C8's
# contrast assertions call the REAL, unmodified functions -- never a re-derivation of them.
require $ORCH_SCRIPT;

my $J = JSON::PP->new->canonical;

# =====================================================================================
# Scaffolding (t/85's own house idiom, reused verbatim where possible)
# =====================================================================================

sub read_file {
    my ($path) = @_;
    open my $r, '<:raw', $path or return undef;
    local $/;
    my $c = <$r>;
    close $r;
    return defined $c ? $c : '';
}

sub write_file {
    my ($path, $content) = @_;
    (my $d = $path) =~ s{[\\/][^\\/]+$}{};
    require File::Path; File::Path::make_path($d) unless -d $d;
    open(my $fh, '>:raw', $path) or die "cannot write $path: $!";
    print {$fh} $content;
    close $fh;
    return $path;
}

sub write_json { my ($path, $data) = @_; return write_file($path, $J->encode($data)) }

sub iso_of {
    my ($e) = @_;
    my @g = gmtime($e);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $g[5]+1900, $g[4]+1, $g[3], $g[2], $g[1], $g[0]);
}

sub jsonl_line { my ($h) = @_; return $J->encode($h) }

# a single assistant turn making ONE tool call -- the shape the tail reader must be able to walk.
sub tool_event {
    my (%o) = @_;
    return {
        type      => 'assistant',
        timestamp => iso_of($o{epoch}),
        session_id=> $o{session_id} // 'sess-fixture',
        message   => {
            role    => 'assistant',
            content => [ { type => 'tool_use', name => ($o{tool} // 'Bash'), input => ($o{input} // {}) } ],
        },
    };
}

my $bp_counter = 0;
sub new_bp_root {
    my $root = tempdir(CLEANUP => 1);
    my $bp   = 'tbp';
    $bp_counter++;
    my $pkg  = "pkg$bp_counter";
    write_file("$root/blueprints/$bp/packages/$pkg.md",
        "---\npackage: $pkg\nstatus: running\nwrite_set: p/$pkg/\n---\n\n# $pkg\n\n## Next action\n\nIn flight.\n");
    return ($root, $bp, $pkg);
}

sub transcript_path { my ($root,$bp,$pkg) = @_; return "$root/blueprints/$bp/runs/$pkg.jsonl" }
sub registry_path    { my ($root,$bp,$pkg) = @_; return "$root/blueprints/$bp/runs/registry.json" }
sub ledger_path      { my ($root,$bp,$pkg) = @_; return "$root/blueprints/$bp/packages/$pkg.md" }
sub orch_log_path    { my ($root,$bp)      = @_; return "$root/blueprints/$bp/runs/orchestrator.log" }

sub write_transcript {
    my ($root, $bp, $pkg, @events) = @_;
    write_file(transcript_path($root,$bp,$pkg), join('', map { jsonl_line($_) . "\n" } @events));
}

# run_bp($verb, $root, $bp, $pkg, %opt) -> ($rc, $stdout, $stderr)
# Subprocess invocation ONLY (t/85's own house idiom for CLI scripts) -- real fd-backed temp
# files for stdout/stderr, never an in-memory scalar filehandle (Windows landmine).
sub run_bp {
    my ($verb, $root, $bp, $pkg, %opt) = @_;
    my ($ofh, $opath) = tempfile('t63-outXXXXXX', TMPDIR => 1); close $ofh;
    my ($efh, $epath) = tempfile('t63-errXXXXXX', TMPDIR => 1); close $efh;

    my @args = ($verb, $bp, $pkg);
    push @args, "--now=$opt{now}"                       if defined $opt{now};
    push @args, "--repeat-flagged=$opt{repeat_flagged}"  if defined $opt{repeat_flagged};

    local %ENV = %ENV;
    $ENV{CCPRAXIS_DATA_DIR} = $root;
    if (exists $opt{model_cmd}) {
        if (defined $opt{model_cmd}) { $ENV{BP_PROGRESS_MODEL_CMD} = $opt{model_cmd} }
        else                          { delete $ENV{BP_PROGRESS_MODEL_CMD} }
    }
    $ENV{BP_PROGRESS_CADENCE_SEC} = $opt{cadence} if defined $opt{cadence};

    my @cmd = (qq{"$^X"}, qq{"$SCRIPT"}, map { qq{"$_"} } @args);
    my $cmd = join(' ', @cmd) . qq{ >"$opath" 2>"$epath"};
    system($cmd);
    my $rc = $? >> 8;

    my $out = read_file($opath) // '';
    my $err = read_file($epath) // '';
    unlink $opath, $epath;
    $out =~ s/\s+\z//;
    return ($rc, $out, $err);
}

sub parse_verdict {
    my ($out) = @_;
    my ($verdict, $reason) = split /\t/, $out, 2;
    return ($verdict // '', $reason // '');
}

sub not_crashed {
    my ($err) = @_;
    return $err !~ /\bDied\b|Can't (?:locate|call)|Undefined subroutine|panic:|Segmentation fault/;
}

# ---- model-seam stub builder --------------------------------------------------------
# Writes a tiny perl script that: (1) drains stdin (never inspects it -- the test fixture
# already differs per call site, so a fixed canned answer per stub is sufficient to prove the
# WIRING, which is this oracle's job; the model's actual intelligence is out of scope), (2)
# appends one line to a counter file (proving whether/how-often it was invoked), (3) prints
# "VERDICT\tREASON" to stdout, (4) exits 0.
my $stub_counter = 0;
sub mk_model_stub {
    my (%o) = @_;
    my $verdict   = $o{verdict}   // 'progressing';
    my $reason    = $o{reason}    // 'stub reason';
    my $exit_code = $o{exit_code} // 0;
    my $garbage   = $o{garbage}   // 0;
    $stub_counter++;
    my $dir = tempdir(CLEANUP => 1);
    my $counter_file = "$dir/calls.log";
    write_file($counter_file, '');
    my $stub_path = "$dir/stub$stub_counter.pl";
    my $body = $garbage
        ? qq{#!/usr/bin/env perl\nopen(my \$f,'>>','$counter_file') or exit 1; print \$f "1\\n"; close \$f;\n<STDIN>;\nprint "not a valid verdict line at all\\n";\nexit $exit_code;\n}
        : qq{#!/usr/bin/env perl\nopen(my \$f,'>>','$counter_file') or exit 1; print \$f "1\\n"; close \$f;\n<STDIN>;\nprint "$verdict\\t$reason\\n";\nexit $exit_code;\n};
    write_file($stub_path, $body);
    chmod 0755, $stub_path;
    my $cmd = qq{"$^X" "$stub_path"};
    return ($cmd, $counter_file);
}

sub call_count {
    my ($counter_file) = @_;
    my $t = read_file($counter_file) // '';
    return scalar(grep { /\S/ } split /\n/, $t);
}

# =====================================================================================
# C1 -- the pathology is caught: a tail showing the same command varied only cosmetically
# returns "looping". ALSO: the OLD progress_verdict (bp-orchestrator.pl) is asserted to return
# 'growing' for the SAME shape of input (stream-log byte growth on every repeated call) -- the
# improvement is DEMONSTRATED against the real old function, not merely claimed.
# =====================================================================================
my ($c1_verdict, $c1_reason);
{
    my ($root, $bp, $pkg) = new_bp_root();
    my $NOW = 2_000_000_000;
    # Twenty turns of the SAME command, varied only cosmetically (whitespace, quoting) --
    # exactly the shape the spec says progress_verdict scores as maximally healthy.
    my @cmds = map {
        my $i = $_;
        $i % 2 == 0 ? "grep -rn 'TODO' src/"
                    : "grep  -rn  \"TODO\"   src/"
    } (1..20);
    my @events;
    my $t = $NOW - 20*60;
    for my $cmd (@cmds) {
        push @events, tool_event(epoch => $t, tool => 'Bash', input => { command => $cmd });
        $t += 60;
    }
    write_transcript($root, $bp, $pkg, @events);

    my ($model_cmd, $counter) = mk_model_stub(verdict => 'looping', reason => 'same command repeated with only cosmetic variation');
    my ($rc, $out, $err) = run_bp('verdict', $root, $bp, $pkg, now => $NOW, model_cmd => $model_cmd);
    is($rc, 0, 'C1: verdict exits 0 for the cosmetic-repeat fixture') or diag("stderr=$err");
    ($c1_verdict, $c1_reason) = parse_verdict($out);
    is($c1_verdict, 'looping',
        'C1: a tail showing the same command varied only cosmetically returns looping')
        or diag("stdout=[$out] stderr=$err");
    ok(length($c1_reason) > 0, 'C1: a one-line reason accompanies the looping verdict');
    ok(call_count($counter) >= 1, 'C1: the model seam was actually invoked for this fixture');

    # ---- the OLD signal, demonstrated on the SAME pathology ----
    # Each repeated call appends bytes to the coordinator's own stream log -- so cur_size grows
    # on every single tick, which is exactly what progress_verdict treats as healthy.
    my $prev_size = 1000;
    my $cur_size  = 1000 + 20 * length(jsonl_line($events[0]));  # strictly growing
    my $old = BpOrch::progress_verdict($cur_size, $NOW, $prev_size, $NOW, 600);
    is($old, 'growing',
        'C1 CONTRAST: the OLD progress_verdict scores this exact pathology "growing" (maximally '
        . 'healthy) -- proving the improvement is demonstrated, not merely asserted')
        or diag("old progress_verdict returned: $old");
}

# =====================================================================================
# C2 -- genuine work is not killed: forty turns inside one pipeline step, with varied and
# advancing tool calls, returns "progressing" -- the snapshot_progressed failure case (a
# coordinator can do 40 turns of real work and register ZERO checkbox/status change).
# =====================================================================================
my $c2_verdict;
{
    my ($root, $bp, $pkg) = new_bp_root();
    my $NOW = 2_000_000_000;
    my @events;
    my $t = $NOW - 40*60;
    for my $i (1..40) {
        my ($tool, $input) = $i % 3 == 0
            ? ('Bash',  { command => "perl -c lib/Module$i.pm" })
            : $i % 3 == 1
            ? ('Read',  { file_path => "lib/Module$i.pm" })
            : ('Edit',  { file_path => "lib/Module$i.pm", old_string => "sub v$i", new_string => "sub v${i}_fixed" });
        push @events, tool_event(epoch => $t, tool => $tool, input => $input);
        $t += 60;
    }
    write_transcript($root, $bp, $pkg, @events);

    my ($model_cmd, $counter) = mk_model_stub(verdict => 'progressing', reason => 'forty varied, advancing tool calls within one step');
    my ($rc, $out, $err) = run_bp('verdict', $root, $bp, $pkg, now => $NOW, model_cmd => $model_cmd);
    is($rc, 0, 'C2: verdict exits 0 for the forty-varied-turns fixture') or diag("stderr=$err");
    my $reason;
    ($c2_verdict, $reason) = parse_verdict($out);
    is($c2_verdict, 'progressing',
        'C2: forty turns of varied, advancing tool calls within one pipeline step returns progressing')
        or diag("stdout=[$out] stderr=$err");
    ok(length($reason) > 0, 'C2: a one-line reason accompanies the progressing verdict');
    ok(call_count($counter) >= 1, 'C2: the model seam was actually invoked for this fixture');

    # ---- the OLD signal, demonstrated on the SAME pathology (snapshot_progressed's own
    # failure case) -- a snapshot with an unchanged status/checkbox count registers ZERO
    # progress despite forty turns of genuine, varied work having happened.
    my $prev_snap = { status => 'running', checkboxes => 2 };
    my $cur_snap  = { status => 'running', checkboxes => 2 };  # unchanged: no checkbox ticked yet
    my $old = BpOrch::snapshot_progressed($prev_snap, $cur_snap);
    is($old, 0,
        'C2 CONTRAST: the OLD snapshot_progressed registers ZERO progress for forty turns of real '
        . 'work with no checkbox/status change yet -- the exact failure this package fixes');
}

# =====================================================================================
# C3 -- THE CRITICAL ONE. Uncertainty must return "progressing", never "looping"/"stuck".
# Unparseable transcript, absent transcript, empty tail, and unavailable model each return
# "progressing" with a stated (non-empty) reason. No ambiguous input may produce a kill verdict.
# =====================================================================================
my @c3_results;
{
    # (a) absent transcript -- no jsonl file exists at all.
    my ($root, $bp, $pkg) = new_bp_root();
    my $NOW = 2_000_000_000;
    # deliberately do NOT write a transcript file.
    my ($model_cmd, $counter) = mk_model_stub(verdict => 'looping', reason => 'model would say looping if asked');
    my ($rc, $out, $err) = run_bp('verdict', $root, $bp, $pkg, now => $NOW, model_cmd => $model_cmd);
    is($rc, 0, 'C3a: verdict exits 0 with the transcript absent') or diag("stderr=$err");
    my ($v, $r) = parse_verdict($out);
    is($v, 'progressing', 'C3a: absent transcript yields progressing (never looping/stuck)');
    ok(length($r) > 0, 'C3a: a stated reason accompanies the absent-transcript verdict');
    ok(not_crashed($err), 'C3a: no crash signature on stderr');
    push @c3_results, { case => 'absent transcript', verdict => $v, reason => $r };
}
{
    # (b) unparseable transcript -- binary garbage, not a single valid JSON line.
    my ($root, $bp, $pkg) = new_bp_root();
    my $NOW = 2_000_000_000;
    write_file(transcript_path($root,$bp,$pkg), "\x00\x01\xFF not json at all {{{\n\x02\x03");
    my ($model_cmd, $counter) = mk_model_stub(verdict => 'looping', reason => 'model would say looping if asked');
    my ($rc, $out, $err) = run_bp('verdict', $root, $bp, $pkg, now => $NOW, model_cmd => $model_cmd);
    is($rc, 0, 'C3b: verdict exits 0 with an unparseable transcript') or diag("stderr=$err");
    my ($v, $r) = parse_verdict($out);
    is($v, 'progressing', 'C3b: unparseable transcript yields progressing (never looping/stuck)');
    ok(length($r) > 0, 'C3b: a stated reason accompanies the unparseable-transcript verdict');
    ok(not_crashed($err), 'C3b: no crash signature on stderr');
    push @c3_results, { case => 'unparseable transcript', verdict => $v, reason => $r };
}
{
    # (c) empty tail -- transcript file exists but is zero bytes / all blank lines.
    my ($root, $bp, $pkg) = new_bp_root();
    my $NOW = 2_000_000_000;
    write_file(transcript_path($root,$bp,$pkg), "\n\n   \n\n");
    my ($model_cmd, $counter) = mk_model_stub(verdict => 'looping', reason => 'model would say looping if asked');
    my ($rc, $out, $err) = run_bp('verdict', $root, $bp, $pkg, now => $NOW, model_cmd => $model_cmd);
    is($rc, 0, 'C3c: verdict exits 0 with an empty tail') or diag("stderr=$err");
    my ($v, $r) = parse_verdict($out);
    is($v, 'progressing', 'C3c: empty tail yields progressing (never looping/stuck)');
    ok(length($r) > 0, 'C3c: a stated reason accompanies the empty-tail verdict');
    ok(not_crashed($err), 'C3c: no crash signature on stderr');
    push @c3_results, { case => 'empty tail', verdict => $v, reason => $r };
}
{
    # (d) unavailable model -- a WELL-FORMED, otherwise-ambiguous-free transcript, but the model
    # seam is entirely unset (simulating the model being unreachable/misconfigured).
    my ($root, $bp, $pkg) = new_bp_root();
    my $NOW = 2_000_000_000;
    write_transcript($root, $bp, $pkg,
        tool_event(epoch => $NOW - 300, tool => 'Bash', input => { command => 'echo hi' }));
    my ($rc, $out, $err) = run_bp('verdict', $root, $bp, $pkg, now => $NOW, model_cmd => undef);
    is($rc, 0, 'C3d: verdict exits 0 with the model seam unavailable') or diag("stderr=$err");
    my ($v, $r) = parse_verdict($out);
    is($v, 'progressing', 'C3d: unavailable model yields progressing (never looping/stuck)');
    ok(length($r) > 0, 'C3d: a stated reason accompanies the unavailable-model verdict');
    ok(not_crashed($err), 'C3d: no crash signature on stderr');
    push @c3_results, { case => 'unavailable model', verdict => $v, reason => $r };
}
{
    # (d-ii) unavailable model, alternate shape: the seam IS set but returns garbage output
    # (nonparseable "VERDICT\tREASON") -- also "unavailable" in effect.
    my ($root, $bp, $pkg) = new_bp_root();
    my $NOW = 2_000_000_000;
    write_transcript($root, $bp, $pkg,
        tool_event(epoch => $NOW - 300, tool => 'Bash', input => { command => 'echo hi' }));
    my ($model_cmd, $counter) = mk_model_stub(garbage => 1);
    my ($rc, $out, $err) = run_bp('verdict', $root, $bp, $pkg, now => $NOW, model_cmd => $model_cmd);
    is($rc, 0, 'C3e: verdict exits 0 with a garbage-output model seam') or diag("stderr=$err");
    my ($v, $r) = parse_verdict($out);
    is($v, 'progressing', 'C3e: garbage/unparseable model output yields progressing (never looping/stuck)');
    ok(length($r) > 0, 'C3e: a stated reason accompanies the garbage-model-output verdict');
    push @c3_results, { case => 'garbage model output', verdict => $v, reason => $r };
}

# Explicit cross-check: NO ambiguous input, across every case above, may have produced a kill
# verdict.
{
    my @bad = grep { $_->{verdict} ne 'progressing' } @c3_results;
    is(scalar(@bad), 0,
        'C3 CROSS-CHECK: every ambiguous-input case returned progressing -- none produced '
        . 'looping/stuck')
        or diag('offending cases: ' . join('; ', map { "$_->{case}=$_->{verdict}" } @bad));
}

# =====================================================================================
# VACUITY GATE for C1/C2/C3, asserted together: a constant "always looping" implementation
# would have passed C1 above but must fail here (C2/C3 verdicts would also read "looping"); a
# constant "always progressing" implementation would have passed C2/C3 but must fail here (C1's
# verdict would also read "progressing"). The cross-check below requires C1 to actually DIFFER
# from C2 and from every C3 case, in the SAME file, driven by model-seam stubs that answer
# differently per fixture -- so no constant-returning bp-progress.pl (model-driven or
# hardcoded) can pass all of C1, C2 and C3 simultaneously.
# =====================================================================================
{
    isnt($c1_verdict, $c2_verdict,
        'VACUITY GATE: C1 (looping) and C2 (progressing) verdicts differ -- rules out both '
        . '"always looping" and "always progressing" constant implementations');
    for my $r (@c3_results) {
        isnt($c1_verdict, $r->{verdict},
            "VACUITY GATE: C1's looping verdict differs from C3's '$r->{case}' progressing verdict");
    }
    is($c2_verdict, 'progressing', 'VACUITY GATE: C2 verdict is the same progressing value C3 uses');
}

# =====================================================================================
# C4 -- tail only: the 10.3 MB transcript is processed WITHOUT a slurp (bounded read), and
# _last_nonempty_line's reader is reused, not reimplemented.
# =====================================================================================
{
    # (1) POSITIVE GATE: a small well-formed fixture actually gets read and classified (proves
    # the reader is functioning at all before the bounded-read/reuse checks).
    my ($root, $bp, $pkg) = new_bp_root();
    my $NOW = 2_000_000_000;
    write_transcript($root, $bp, $pkg,
        tool_event(epoch => $NOW - 60, tool => 'Bash', input => { command => 'echo hi' }));
    my ($model_cmd, $counter) = mk_model_stub(verdict => 'progressing', reason => 'fine');
    my ($rc, $out, $err) = run_bp('verdict', $root, $bp, $pkg, now => $NOW, model_cmd => $model_cmd);
    is($rc, 0, 'C4 POSITIVE GATE: verdict exits 0 against a well-formed small fixture') or diag($err);
    ok(call_count($counter) >= 1, 'C4 POSITIVE GATE: the model seam was actually invoked (the tail was really read)');
}
{
    # (2) Mechanism: bp-progress.pl reuses _last_nonempty_line / _tail_jsonl_objs rather than
    # reimplementing the seek-from-end reader.
    my $src = read_file($SCRIPT) // '';
    like($src, qr/_last_nonempty_line|_tail_jsonl_objs/,
        'C4: bp-progress.pl references _last_nonempty_line or _tail_jsonl_objs (bp-orchestrator.pl) '
        . '-- the shared seek-from-end reader')
        or diag('bp-progress.pl does not reference either reader -- expected pre-implementation');
    unlike($src, qr/sub\s+_last_nonempty_line\s*\{/,
        'C4: bp-progress.pl does NOT redefine its own _last_nonempty_line (reuse, not a second reader)');
    unlike($src, qr/sub\s+_tail_jsonl_objs\s*\{/,
        'C4: bp-progress.pl does NOT redefine its own _tail_jsonl_objs (reuse, not a second reader)');
}
{
    # (3) Bounded peak-RSS read against the REAL 10.3MB transcript, mirroring t/85 C9's own
    # bounded-read proof technique exactly (same fixture file, same size assertion).
    my ($root, $bp, $pkg) = new_bp_root();
    write_transcript($root, $bp, $pkg,
        tool_event(epoch => 2_000_000_000 - 60, tool => 'Bash', input => { command => 'echo hi' }));

    my ($root_big, $bp_big, $pkg_big) = new_bp_root();
    ok(-f $REAL_TRANSCRIPT && -s $REAL_TRANSCRIPT == 10_351_554,
        'C4 FIXTURE-SANITY: the real 10.3MB transcript is present for the bounded-read check');
    require File::Path; File::Path::make_path("$root_big/blueprints/$bp_big/runs") unless -d "$root_big/blueprints/$bp_big/runs";
    copy($REAL_TRANSCRIPT, transcript_path($root_big,$bp_big,$pkg_big))
        or die "failed to copy real transcript fixture: $!";

    my ($model_cmd, undef) = mk_model_stub(verdict => 'progressing', reason => 'fine');

    sub peak_rss_kb {
        my ($script, $args, $env) = @_;
        my ($ofh, $opath) = tempfile('t63-rss-outXXXXXX', TMPDIR => 1); close $ofh;
        local %ENV = %ENV;
        $ENV{$_} = $env->{$_} for keys %$env;
        my $pid = fork();
        if (!defined $pid) { return undef }
        if ($pid == 0) {
            open(STDOUT, '>', $opath) or exit 1;
            open(STDERR, '>', '/dev/null');
            exec($^X, $script, @$args) or exit 1;
        }
        my $peak = 0;
        my $tries = 0;
        while (1) {
            my $r = waitpid($pid, 1); # WNOHANG
            if (-r "/proc/$pid/status") {
                if (open(my $sfh, '<', "/proc/$pid/status")) {
                    local $/;
                    my $t = <$sfh>; close $sfh;
                    if ($t && $t =~ /VmRSS:\s*(\d+)\s*kB/) { $peak = $1 if $1 > $peak }
                }
            }
            last if $r == $pid;
            $tries++;
            last if $tries > 200_000;
        }
        waitpid($pid, 0) if $pid;
        unlink $opath;
        return $peak;
    }

    my ($small_peak, $big_peak) = (0, 0);
    for (1..5) {
        my $s = peak_rss_kb($SCRIPT, ['verdict', $bp, $pkg],
            { CCPRAXIS_DATA_DIR => $root, BP_PROGRESS_MODEL_CMD => $model_cmd });
        $small_peak = $s if defined $s && $s > $small_peak;
        my $b = peak_rss_kb($SCRIPT, ['verdict', $bp_big, $pkg_big],
            { CCPRAXIS_DATA_DIR => $root_big, BP_PROGRESS_MODEL_CMD => $model_cmd });
        $big_peak = $b if defined $b && $b > $big_peak;
    }
    ok($small_peak > 0 && $big_peak > 0,
        'C4 HARNESS: peak RSS was actually sampled for both the tiny and the 10.3MB fixture')
        or diag("small_peak=$small_peak big_peak=$big_peak");

    my $delta_kb = $big_peak - $small_peak;
    cmp_ok($delta_kb, '<', 6_000,
        'C4: peak RSS delta between the tiny fixture and the 10.3MB real transcript is well under '
        . "6MB -- proves the read is bounded (seek-from-end), not a slurp "
        . "(small_peak=${small_peak}KB big_peak=${big_peak}KB delta=${delta_kb}KB)");
}

# =====================================================================================
# C5 -- throttled: fires on its cadence, not every tick, never concurrently for one package.
# POSITIVE GATE FIRST: the model seam's counter is asserted to have moved on a real call, before
# the "not every tick" / "never concurrent" negative assertions.
# =====================================================================================
{
    my ($root, $bp, $pkg) = new_bp_root();
    my $NOW = 2_000_000_000;
    write_transcript($root, $bp, $pkg,
        tool_event(epoch => $NOW - 60, tool => 'Bash', input => { command => 'echo hi' }));
    my ($model_cmd, $counter) = mk_model_stub(verdict => 'progressing', reason => 'fine');

    # First call: cadence window empty -> the seam IS invoked.
    my ($rc1, $out1, $err1) = run_bp('verdict', $root, $bp, $pkg, now => $NOW, model_cmd => $model_cmd, cadence => 300);
    is($rc1, 0, 'C5 POSITIVE GATE: first verdict call exits 0') or diag($err1);
    my $count_after_first = call_count($counter);
    ok($count_after_first >= 1, 'C5 POSITIVE GATE: the model seam was actually invoked on the first call');

    # Second call, seconds later, well inside the 300s cadence -> must NOT invoke the seam again.
    my ($rc2, $out2, $err2) = run_bp('verdict', $root, $bp, $pkg, now => $NOW + 5, model_cmd => $model_cmd, cadence => 300);
    is($rc2, 0, 'C5: second (in-cadence) verdict call exits 0') or diag($err2);
    is(call_count($counter), $count_after_first,
        'C5: a second call inside the cadence window does not invoke the model seam again -- '
        . 'not every tick')
        or diag('call count grew across an in-cadence call');
    my ($v2) = parse_verdict($out2);
    ok(length($v2) > 0, 'C5: the in-cadence call still returns a valid cached verdict');

    # Third call, well past the cadence -> the seam SHOULD fire again.
    my ($rc3, $out3, $err3) = run_bp('verdict', $root, $bp, $pkg, now => $NOW + 400, model_cmd => $model_cmd, cadence => 300);
    is($rc3, 0, 'C5: third (past-cadence) verdict call exits 0') or diag($err3);
    ok(call_count($counter) > $count_after_first,
        'C5: a call past the cadence window DOES invoke the model seam again -- fires on its cadence');
}
{
    # Never-concurrent: a lock already held for this package must suppress the model call for
    # that tick.
    my ($root, $bp, $pkg) = new_bp_root();
    my $NOW = 2_000_000_000;
    write_transcript($root, $bp, $pkg,
        tool_event(epoch => $NOW - 60, tool => 'Bash', input => { command => 'echo hi' }));
    my ($model_cmd, $counter) = mk_model_stub(verdict => 'looping', reason => 'would be looping if asked');

    require File::Path; File::Path::make_path("$root/blueprints/$bp/runs") unless -d "$root/blueprints/$bp/runs";
    write_file("$root/blueprints/$bp/runs/$pkg.progress.lock", "$$\n");

    my ($rc, $out, $err) = run_bp('verdict', $root, $bp, $pkg, now => $NOW, model_cmd => $model_cmd, cadence => 300);
    is($rc, 0, 'C5 (lock): verdict exits 0 when a concurrency lock is already held') or diag($err);
    is(call_count($counter), 0,
        'C5 (lock): the model seam is NOT invoked while a concurrency lock for this package is held '
        . '-- never concurrently for one package');
    my ($v, $r) = parse_verdict($out);
    is($v, 'progressing', 'C5 (lock): a locked-out tick defers to progressing rather than guessing');
    ok(length($r) > 0, 'C5 (lock): a stated reason accompanies the locked-out verdict');
}

# =====================================================================================
# C6 -- a package b10's hook already flagged is treated as "looping" WITHOUT a fresh semantic
# call. Vacuity gate: the IDENTICAL fixture WITHOUT --repeat-flagged is asserted to invoke the
# model seam FIRST, proving a semantic call would otherwise have occurred.
# =====================================================================================
{
    my ($root, $bp, $pkg) = new_bp_root();
    my $NOW = 2_000_000_000;
    write_transcript($root, $bp, $pkg,
        tool_event(epoch => $NOW - 60, tool => 'Bash', input => { command => 'grep foo bar.pl' }));
    my ($model_cmd, $counter) = mk_model_stub(verdict => 'progressing', reason => 'would be progressing if asked');

    # WITHOUT the flag: the model seam IS invoked (proves a call would otherwise happen).
    my ($rc0, $out0, $err0) = run_bp('verdict', $root, $bp, $pkg, now => $NOW, model_cmd => $model_cmd, cadence => 0);
    is($rc0, 0, 'C6 VACUITY GATE: verdict (no repeat flag) exits 0') or diag($err0);
    ok(call_count($counter) >= 1,
        'C6 VACUITY GATE: WITHOUT --repeat-flagged, the model seam IS invoked for this fixture -- '
        . 'proving a semantic call would otherwise have occurred');

    # WITH the flag, on a fresh package (so cadence/state can't be the reason for no call):
    my ($root2, $bp2, $pkg2) = new_bp_root();
    write_transcript($root2, $bp2, $pkg2,
        tool_event(epoch => $NOW - 60, tool => 'Bash', input => { command => 'grep foo bar.pl' }));
    my ($model_cmd2, $counter2) = mk_model_stub(verdict => 'progressing', reason => 'would be progressing if asked');
    my ($rc1, $out1, $err1) = run_bp('verdict', $root2, $bp2, $pkg2, now => $NOW, model_cmd => $model_cmd2,
        repeat_flagged => 1, cadence => 0);
    is($rc1, 0, 'C6: verdict (repeat-flagged=1) exits 0') or diag($err1);
    my ($v1, $r1) = parse_verdict($out1);
    is($v1, 'looping',
        "C6: a package b10's hook already flagged (--repeat-flagged=1) is treated as looping")
        or diag("stdout=[$out1] stderr=$err1");
    ok(length($r1) > 0, 'C6: a stated reason accompanies the repeat-flagged looping verdict');
    is(call_count($counter2), 0,
        'C6: with --repeat-flagged=1, the model seam is NOT invoked -- the semantic check does not '
        . "re-derive what b10's hook already established");
}

# =====================================================================================
# C7 -- the cap is now a backstop: reaching it logs a DISTINCT condition meaning "the heuristic
# failed", and is NOT queued as a package failure (the ledger is left untouched by this call).
# =====================================================================================
{
    my ($root, $bp, $pkg) = new_bp_root();
    my $NOW = 2_000_000_000;
    my $ledger_before = read_file(ledger_path($root,$bp,$pkg));

    my ($rc, $out, $err) = run_bp('capped', $root, $bp, $pkg, now => $NOW);
    is($rc, 0, 'C7: the capped subcommand exits 0') or diag("stderr=$err");
    ok(not_crashed($err), 'C7: no crash signature on stderr for the capped condition');

    my $log_txt = read_file(orch_log_path($root, $bp)) // '';
    ok(length($log_txt) > 0, 'C7 POSITIVE GATE: the capped subcommand actually wrote a log entry')
        or diag('runs/orchestrator.log is empty or missing after the capped subcommand ran');

    my @events = map { eval { $J->decode($_) } || {} } grep { /\S/ } split /\n/, $log_txt;
    my @heuristic_events = grep { ($_->{type} // '') =~ /heuristic/i } @events;
    ok(scalar(@heuristic_events) >= 1,
        'C7: a log event with a type naming the heuristic (meaning "the heuristic failed") was '
        . 'written')
        or diag('logged event types: ' . join(', ', map { $_->{type} // '?' } @events));

    # NOT queued as a package failure: known package-failure-shaped event types from the
    # existing orchestrator must not be what got logged here, and the ledger must be untouched.
    my @failure_shaped = grep {
        my $t = $_->{type} // '';
        $t eq 'watchdog_block' || $t eq 'package_failed' || $t eq 'judge_marker_orphaned'
    } @events;
    is(scalar(@failure_shaped), 0,
        'C7: reaching the cap is not logged under any of the existing package-failure-shaped event '
        . 'types -- it is a distinct condition about the guard, not the package');

    my $ledger_after = read_file(ledger_path($root,$bp,$pkg));
    is($ledger_after, $ledger_before,
        'C7: the capped subcommand does not touch the package ledger -- reaching the cap is not '
        . 'queued as a package failure');

    ok(! -e registry_path($root, $bp, $pkg) || read_file(registry_path($root,$bp,$pkg)) eq '',
        'C7: the capped subcommand does not write/mutate registry.json either')
        or diag('registry.json was created/modified by the capped subcommand');
}

# =====================================================================================
# C8 -- status oscillation alone no longer counts as progress (closes E2). Contrast: the OLD
# snapshot_progressed DOES count a bare status flip (and flip-back) as progress; the new
# semantic verdict is proven independent of ledger status entirely -- mutating ONLY the
# package's ledger status between two verdict calls over the IDENTICAL looping transcript never
# changes the verdict.
# =====================================================================================
{
    # ---- OLD signal: a bare status oscillation registers as progress, both directions.
    my $old_a = BpOrch::snapshot_progressed({ status => 'running', checkboxes => 0 },
                                             { status => 'blocked', checkboxes => 0 });
    is($old_a, 1,
        'C8 CONTRAST: the OLD snapshot_progressed counts a bare status flip (running->blocked) as '
        . 'progress, with no other change');
    my $old_b = BpOrch::snapshot_progressed({ status => 'blocked', checkboxes => 0 },
                                             { status => 'running', checkboxes => 0 });
    is($old_b, 1,
        'C8 CONTRAST: the OLD snapshot_progressed ALSO counts the flip back (blocked->running) as '
        . 'progress -- an oscillation can look like continuous progress forever under the old rule');

    # ---- NEW signal: rerun C1's own looping tail, oscillating ONLY the ledger status field
    # between two verdict calls, and assert the verdict never flips to progressing because of it.
    my ($root, $bp, $pkg) = new_bp_root();
    my $NOW = 2_000_000_000;
    my @events;
    my $t = $NOW - 20*60;
    for my $i (1..20) {
        my $cmd = $i % 2 == 0 ? "grep -rn 'TODO' src/" : "grep  -rn  \"TODO\"   src/";
        push @events, tool_event(epoch => $t, tool => 'Bash', input => { command => $cmd });
        $t += 60;
    }
    write_transcript($root, $bp, $pkg, @events);
    write_file(ledger_path($root,$bp,$pkg),
        "---\npackage: $pkg\nstatus: running\nwrite_set: p/$pkg/\n---\n\n# $pkg\n\nfirst state.\n");

    my ($model_cmd, $counter) = mk_model_stub(verdict => 'looping', reason => 'same command repeated cosmetically');
    my ($rc1, $out1, $err1) = run_bp('verdict', $root, $bp, $pkg, now => $NOW, model_cmd => $model_cmd, cadence => 0);
    is($rc1, 0, 'C8: first verdict call (status=running) exits 0') or diag($err1);
    my ($v1) = parse_verdict($out1);
    is($v1, 'looping', 'C8 POSITIVE GATE: the first call over the looping tail is looping');

    # Mutate ONLY the ledger status (an oscillation, exactly like the old-signal contrast above).
    write_file(ledger_path($root,$bp,$pkg),
        "---\npackage: $pkg\nstatus: blocked\nwrite_set: p/$pkg/\n---\n\n# $pkg\n\nstatus oscillated.\n");

    my ($rc2, $out2, $err2) = run_bp('verdict', $root, $bp, $pkg, now => $NOW, model_cmd => $model_cmd, cadence => 0);
    is($rc2, 0, 'C8: second verdict call (status=blocked, transcript unchanged) exits 0') or diag($err2);
    my ($v2) = parse_verdict($out2);
    is($v2, 'looping',
        'C8: mutating ONLY the ledger status (an oscillation) between two verdict calls over the '
        . 'IDENTICAL looping transcript never flips the verdict to progressing -- status oscillation '
        . 'alone no longer counts as progress');
    is($v1, $v2, 'C8: the verdict is unchanged by the ledger-status oscillation');
}

done_testing();
