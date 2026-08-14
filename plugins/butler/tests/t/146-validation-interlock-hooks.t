#!/usr/bin/env perl
# 146-validation-interlock-hooks.t — oracle for w03-validation-interlock,
# derived ONLY from
# .ccpraxis-local-data/blueprints/butler-and-dashboard-overhaul/specs/w03-validation-interlock-spec.md
# section 2.1 (guard-validation-interlock.sh), 2.3 (track-worker-solo.sh),
# 2.4 (untrack-worker-solo.sh), 2.5 (hooks.json registration), and the
# package's done criteria 1/3/4/5.
#
# WRITTEN BLIND TO ANY IMPLEMENTATION. None of guard-validation-interlock.sh,
# track-worker-solo.sh, untrack-worker-solo.sh exist at the time this file
# was authored (grep of plugins/butler/hooks/ confirmed only lib.sh,
# guard-writes.sh, track-dispatch.sh, mark-wakeup.sh and siblings, none of
# the three names above). Every assertion that runs one of these hooks is
# therefore expected to fail on MISSING BEHAVIOUR: `bash "$HOOK" <payload`
# against a nonexistent file exits 127 with bash's own diagnostic on stderr,
# never a perl/harness error from this file. Sections marked FIXTURE-SANITY
# are deliberate harness self-checks that must pass even with the hooks
# absent -- they are the evidence a red below is attributable to the missing
# hook and not to broken scaffolding.
#
# HOST NOTE: this host genuinely has no `jq` on PATH (verified while writing
# this file: `command -v jq` exits 1). Every hook invocation below therefore
# exercises bp_json_get's perl+JSON::PP fallback for real, not hypothetically
# -- this is spec behavior 8's host, not a simulation of it.
#
# HARNESS RULES (mirroring t/79, t/120):
#   * %CLEAN_ENV strips every ambient BP_*/CCPRAXIS_*-adjacent var so an
#     inherited value from the coordinator session running this suite cannot
#     produce a false pass or a false red.
#   * Payloads are built with JSON::PP->new->canonical->encode(\%hash), never
#     by interpolating values into a string -- the exact malformed-fixture
#     defect class this run's own report has already been burned by once.
#   * Payloads reach the hook via a real temp FILE redirected onto stdin
#     (never a shell heredoc), so no quoting/escaping question can arise at
#     the harness boundary either.
#   * done_testing(), not a hand-counted plan.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP ();

(my $HOOKS = "$Bin/../../hooks") =~ s{\\}{/}g;
my $GUARD    = "$HOOKS/guard-validation-interlock.sh";
my $TRACK    = "$HOOKS/track-worker-solo.sh";
my $UNTRACK  = "$HOOKS/untrack-worker-solo.sh";
my $HOOKSJSON = "$HOOKS/hooks.json";

for my $h ($GUARD, $TRACK, $UNTRACK) {
    diag("subject under test: $h "
         . (-e $h ? "(present)"
                  : "(ABSENT -- assertions exercising it are expected to fail on MISSING BEHAVIOUR)"));
}

my %CLEAN_ENV = map { ($_ => $ENV{$_}) }
    grep { !/^BP_/ && !/^CCPRAXIS_/ } keys %ENV;

sub fwd { (my $p = shift) =~ s{\\}{/}g; return $p; }

my $ROOT = tempdir(CLEANUP => 1);
my $fn = 0;

sub write_file {
    my ($path, $bytes) = @_;
    open my $w, '>', $path or die "write $path: $!";
    binmode $w;
    print $w $bytes;
    close $w;
}
sub read_file {
    my ($path) = @_;
    return '' unless -e $path;
    open my $r, '<', $path or die "read $path: $!";
    binmode $r;
    local $/;
    my $c = <$r>;
    close $r;
    return defined $c ? $c : '';
}

# ---------------------------------------------------------------------------
# json_payload(%kv) — builds a Bash/Task/Agent-shaped PreToolUse payload with
# a real JSON encoder. tool_input is itself a hash ref, never a raw string.
# ---------------------------------------------------------------------------
sub json_payload {
    my (%kv) = @_;
    my $doc = {
        session_id => $kv{session_id} // 'sess-1',
        cwd        => $kv{cwd},
        tool_name  => $kv{tool_name} // 'Bash',
        tool_input => $kv{tool_input} // {},
    };
    return JSON::PP->new->canonical->encode($doc);
}

# ---------------------------------------------------------------------------
# run_hook(HOOK, PAYLOAD_STRING, %envover) -> (rc, stdout, stderr)
# Feeds PAYLOAD_STRING via a real temp file on stdin -- never a heredoc.
# ---------------------------------------------------------------------------
sub run_hook {
    my ($hook, $payload, %envover) = @_;
    my $pf  = "$ROOT/payload." . (++$fn) . ".json";
    my $ef  = "$ROOT/stderr."  . (++$fn) . ".txt";
    write_file($pf, $payload);
    local %ENV = (%CLEAN_ENV, %envover,
                  HOOK_BIN => fwd($hook), PAYLOAD_FILE => fwd($pf), ERR_FILE => fwd($ef));
    open(my $rf, '-|', 'bash', '-c',
         'exec timeout 15 bash "$HOOK_BIN" <"$PAYLOAD_FILE" 2>"$ERR_FILE"', 'bash')
        or die "bash: $!";
    binmode $rf;
    my $out = do { local $/; <$rf> };
    close $rf;
    my $rc = $? >> 8;
    my $err = read_file($ef);
    return ($rc, defined $out ? $out : '', $err);
}

# ---------------------------------------------------------------------------
# Fixture builders.
# ---------------------------------------------------------------------------
# A headless coordinator's BP_DIR, with a marker at $BP_DIR/runs/$pkg.active-worker.
sub mk_headless {
    my (%opt) = @_;
    my $n = ++$fn;
    my $bp = "$ROOT/bp$n";
    make_path("$bp/runs");
    my $proj = "$ROOT/proj$n";
    make_path($proj);
    my $pkg = $opt{pkg} // 'w03test';
    my %env = (BP_LEDGER => "$bp/packages/$pkg.md", BP_DIR => fwd($bp),
               BP_PROJECT_ROOT => fwd($proj), BP_PACKAGE => $pkg);
    return ($bp, $pkg, \%env);
}

sub write_marker {
    my ($path, $content, %opt) = @_;
    make_path((File::Basename::dirname($path)));
    write_file($path, $content);
    if (defined $opt{age_minutes}) {
        my $t = time() - ($opt{age_minutes} * 60);
        utime($t, $t, $path) or die "utime $path: $!";
    }
}

# An interactive drive-solo session's data dir, with .drive-solo/ present.
sub mk_interactive {
    my $n = ++$fn;
    my $data = "$ROOT/data$n/.ccpraxis-local-data";
    make_path("$data/.drive-solo");
    return $data;
}

use File::Basename ();

# ===========================================================================
# A. guard-validation-interlock.sh — HEADLESS branch (DC1, DC3, DC4).
# ===========================================================================
{
    my ($bp, $pkg, $env) = mk_headless();
    my $marker = "$bp/runs/$pkg.active-worker";
    write_marker($marker, 'butler:bp-implementer');
    my $payload = json_payload(tool_input => { command => 'npm test' });

    my ($rc, $out, $err) = run_hook($GUARD, $payload, %$env);
    is($rc, 2,
       'A1 (-> DC1, DC3): a live, fresh, writer marker + a denylisted Bash command '
     . 'is DENIED with exit code 2 -- never the exit code of any test runner, since the '
     . 'command structurally never ran')
        or diag("stdout=[$out] stderr=[$err]");
    like($err, qr/was\s+not\s+executed/i,
       'A2 (-> DC3): stderr contains the required "was NOT executed" phrase (or case-insensitive '
     . 'equivalent) -- the one sentence a red test-runner summary never contains')
        or diag("stderr=[$err]");
}

{
    # A3 (-> DC1 behavior 2): same live marker, but a NON-denylisted command
    # (e.g. git status) -- must be allowed, unaffected.
    my ($bp, $pkg, $env) = mk_headless();
    write_marker("$bp/runs/$pkg.active-worker", 'butler:bp-implementer');
    my $payload = json_payload(tool_input => { command => 'git status' });
    my ($rc, $out, $err) = run_hook($GUARD, $payload, %$env);
    is($rc, 0,
       'A3 (-> DC1): a live writer marker does NOT block a command outside VALIDATION_DENYLIST '
     . '(git status) -- the interlock is scoped to test/build/lint-shaped commands only')
        or diag("stderr=[$err]");
}

{
    # A4 (-> behavior 3): no marker at all -- allowed.
    my ($bp, $pkg, $env) = mk_headless();
    my $payload = json_payload(tool_input => { command => 'npm test' });
    my ($rc, $out, $err) = run_hook($GUARD, $payload, %$env);
    is($rc, 0, 'A4 (-> DC1 behavior 3): no marker present at all -- allowed')
        or diag("stderr=[$err]");
}

{
    # A5 (-> behavior 3): marker names a NON-writer worker (bp-scout) -- allowed.
    my ($bp, $pkg, $env) = mk_headless();
    write_marker("$bp/runs/$pkg.active-worker", 'butler:bp-scout');
    my $payload = json_payload(tool_input => { command => 'npm test' });
    my ($rc, $out, $err) = run_hook($GUARD, $payload, %$env);
    is($rc, 0,
       'A5 (-> DC1 behavior 3): a marker naming a read-only worker (bp-scout) does not block '
     . 'validation -- a read-only worker cannot leave writable-toolchain contamination')
        or diag("stderr=[$err]");
}

{
    # A6 (-> DC4, behavior 4): a STALE writer marker (older than STALE_MIN,
    # default 180 minutes) self-heals -- must NOT block.
    my ($bp, $pkg, $env) = mk_headless();
    write_marker("$bp/runs/$pkg.active-worker", 'butler:bp-implementer', age_minutes => 185);
    my $payload = json_payload(tool_input => { command => 'npm test' });
    my ($rc, $out, $err) = run_hook($GUARD, $payload, %$env);
    is($rc, 0,
       'A6 (-> DC4): a writer marker older than the default 180-minute STALE_MIN allows '
     . 'validation -- a crashed worker'."'".'s leftover marker must not wedge the interlock forever')
        or diag("stderr=[$err]");
}

{
    # A7 (counter-fixture for A6): a marker that is fresh (well under the
    # default TTL) still blocks -- proves A6'"'"'s allow is attributable to
    # staleness, not to the interlock never firing at all.
    my ($bp, $pkg, $env) = mk_headless();
    write_marker("$bp/runs/$pkg.active-worker", 'butler:bp-implementer', age_minutes => 1);
    my $payload = json_payload(tool_input => { command => 'npm test' });
    my ($rc, $out, $err) = run_hook($GUARD, $payload, %$env);
    is($rc, 2,
       'A7 (counter-fixture to A6): a 1-minute-old writer marker still blocks -- A6'."'".'s allow '
     . 'is attributable to the staleness bound, not to the interlock being inert')
        or diag("stderr=[$err]");
}

{
    # A8 (-> spec §5 edge case, fail-open): malformed/non-JSON payload, even
    # with a live fresh writer marker present, must NOT block.
    my ($bp, $pkg, $env) = mk_headless();
    write_marker("$bp/runs/$pkg.active-worker", 'butler:bp-implementer');
    my ($rc, $out, $err) = run_hook($GUARD, "not valid json at all {{{", %$env);
    is($rc, 0,
       'A8 (fail-open): a malformed/non-JSON payload allows the command through even with a live '
     . 'writer marker present -- ambiguity must resolve to allow, never to a wedge')
        or diag("stderr=[$err]");
}

# ===========================================================================
# B. guard-validation-interlock.sh — INTERACTIVE (drive-solo) branch (DC1
#    behavior 5, DC4 behavior 7).
# ===========================================================================
{
    my $data = mk_interactive();
    write_marker("$data/.drive-solo/.active-worker", 'bp-implementer');
    my $payload = json_payload(cwd => $data, tool_input => { command => 'flutter test' });
    my ($rc, $out, $err) = run_hook($GUARD, $payload, CCPRAXIS_DATA_DIR => fwd($data));
    is($rc, 2,
       'B1 (-> DC1 behavior 5): an interactive drive-solo session with a live writer marker '
     . 'at $DATA/.drive-solo/.active-worker denies a denylisted Bash command, same as the '
     . 'headless case (A1)')
        or diag("stderr=[$err]");
    like($err, qr/was\s+not\s+executed/i,
       'B2 (-> DC3): same required phrase in the interactive branch'."'".' denial')
        or diag("stderr=[$err]");
}

{
    # B3 (-> DC4 behavior 7): stale interactive marker self-heals independently
    # of untrack-worker-solo.sh ever having run.
    my $data = mk_interactive();
    write_marker("$data/.drive-solo/.active-worker", 'bp-implementer', age_minutes => 185);
    my $payload = json_payload(cwd => $data, tool_input => { command => 'flutter test' });
    my ($rc, $out, $err) = run_hook($GUARD, $payload, CCPRAXIS_DATA_DIR => fwd($data));
    is($rc, 0,
       'B3 (-> DC4 behavior 7): a stale interactive writer marker (crashed worker, PostToolUse '
     . 'never ran) self-heals -- allowed, independent of untrack-worker-solo.sh')
        or diag("stderr=[$err]");
}

{
    # B4: a project with NO .drive-solo dir at all -- nothing to gate.
    my $n = ++$fn;
    my $data = "$ROOT/nods$n/.ccpraxis-local-data";
    make_path($data);
    my $payload = json_payload(cwd => $data, tool_input => { command => 'npm test' });
    my ($rc, $out, $err) = run_hook($GUARD, $payload, CCPRAXIS_DATA_DIR => fwd($data));
    is($rc, 0,
       'B4 (edge case): no .drive-solo directory at all -- not a drive-solo session, allowed')
        or diag("stderr=[$err]");
}

# ===========================================================================
# C. track-worker-solo.sh (feeds guard-validation-interlock.sh'"'"'s interactive
#    branch -- DC1 behavior 5's precondition).
# ===========================================================================
{
    my $data = mk_interactive();
    my $payload = json_payload(cwd => $data, tool_name => 'Task',
                                tool_input => { subagent_type => 'butler:bp-implementer' });
    my ($rc, $out, $err) = run_hook($TRACK, $payload);
    is($rc, 0, 'C1: track-worker-solo.sh never blocks a Task dispatch')
        or diag("stderr=[$err]");
    my $marker = "$data/.drive-solo/.active-worker";
    ok(-f $marker, 'C2 (-> DC1 behavior 5 precondition): a write-capable Task dispatch writes '
                 . '$DATA/.drive-solo/.active-worker')
        or diag('this marker is what guard-validation-interlock.sh'."'".'s interactive branch reads (test B1)');
    like(read_file($marker), qr/bp-implementer/,
       'C3: the marker'."'".' content identifies the writer worker');
}

{
    # C4: a read-only worker (bp-scout) must NOT be recorded.
    my $data = mk_interactive();
    my $payload = json_payload(cwd => $data, tool_name => 'Task',
                                tool_input => { subagent_type => 'butler:bp-scout' });
    run_hook($TRACK, $payload);
    ok(!-f "$data/.drive-solo/.active-worker",
       'C4 (-> spec §5 edge case): a read-only worker dispatch (bp-scout) is never recorded');
}

{
    # C5: BP_LEDGER set (headless coordinator) -- track-worker-solo.sh must be
    # a no-op; track-dispatch.sh already covers that case.
    my $data = mk_interactive();
    my $payload = json_payload(cwd => $data, tool_name => 'Task',
                                tool_input => { subagent_type => 'butler:bp-implementer' });
    run_hook($TRACK, $payload, BP_LEDGER => '/fake/ledger.md');
    ok(!-f "$data/.drive-solo/.active-worker",
       'C5: with BP_LEDGER set (a headless coordinator process), track-worker-solo.sh writes '
     . 'nothing -- that surface is track-dispatch.sh'."'".'s job');
}

# ===========================================================================
# D. untrack-worker-solo.sh (DC1 behavior 6: the block being lifted once the
#    dispatch that armed it returns).
# ===========================================================================
{
    my $data = mk_interactive();
    write_marker("$data/.drive-solo/.active-worker", 'bp-implementer');
    my $payload = json_payload(cwd => $data, tool_name => 'Task',
                                tool_input => { subagent_type => 'butler:bp-implementer' });
    my ($rc) = run_hook($UNTRACK, $payload);
    is($rc, 0, 'D1: untrack-worker-solo.sh never blocks a PostToolUse Task return');
    ok(!-f "$data/.drive-solo/.active-worker",
       'D2 (-> DC1 behavior 6): the marker is cleared once the dispatch'."'".' PostToolUse fires');
}

{
    # D3: end-to-end -- track, then a Bash validation call is blocked, then
    # untrack, then the SAME Bash call is allowed. This is behavior 5 + 6
    # chained, the exact sequence the package exists to make safe.
    my $data = mk_interactive();
    my $task_payload = json_payload(cwd => $data, tool_name => 'Task',
                                     tool_input => { subagent_type => 'butler:bp-implementer' });
    run_hook($TRACK, $task_payload);
    my $bash_payload = json_payload(cwd => $data, tool_input => { command => 'pytest' });
    my ($rc1, undef, $err1) = run_hook($GUARD, $bash_payload, CCPRAXIS_DATA_DIR => fwd($data));
    is($rc1, 2, 'D3a: validation is blocked while the interactive dispatch is live')
        or diag("stderr=[$err1]");

    run_hook($UNTRACK, $task_payload);
    my ($rc2, undef, $err2) = run_hook($GUARD, $bash_payload, CCPRAXIS_DATA_DIR => fwd($data));
    is($rc2, 0, 'D3b (-> DC3 framing): the SAME Bash call is allowed once the dispatch returns '
              . '-- the block was distinguishable from a red and lifted cleanly, not a wedge')
        or diag("stderr=[$err2]");
}

# ===========================================================================
# F. fixbatch step7 / F1 -- untrack-worker-solo.sh must be a COMPARE-AND-CLEAR,
#    not an unconditional clear. Red-team HIGH-3, verified live: an unrelated
#    Task/Agent return (a read-only worker in the same session, or a DIFFERENT
#    session's dispatch) was wiping a still-live writer's marker.
# ===========================================================================
{
    # F1 (repro 1): a write-capable worker is tracked, then a read-only worker
    # (bp-scout) is ALSO dispatched in the same session and returns FIRST.
    # bp-scout's own PostToolUse must NOT clear the still-live writer's marker.
    my $data = mk_interactive();
    my $impl_payload = json_payload(cwd => $data, tool_name => 'Task',
                                     tool_input => { subagent_type => 'butler:bp-implementer' });
    run_hook($TRACK, $impl_payload);
    ok(-f "$data/.drive-solo/.active-worker",
       'F1-setup: the write-capable worker'."'".' dispatch armed the marker');

    my $scout_payload = json_payload(cwd => $data, tool_name => 'Task',
                                      tool_input => { subagent_type => 'butler:bp-scout' });
    run_hook($UNTRACK, $scout_payload);
    ok(-f "$data/.drive-solo/.active-worker",
       'F1 (-> F1, HIGH-3 repro 1): a read-only worker'."'".' (bp-scout) PostToolUse return does NOT '
     . 'clear a different, still-live write-capable worker'."'".'s marker in the same session');

    my $bash_payload = json_payload(cwd => $data, tool_input => { command => 'npm test' });
    my ($rc) = run_hook($GUARD, $bash_payload, CCPRAXIS_DATA_DIR => fwd($data));
    is($rc, 2,
       'F1b: validation is still correctly blocked after the read-only worker'."'".'s return -- the '
     . 'interlock was not silently disarmed');
}

{
    # F2 (repro 2): two DIFFERENT sessions in the same project each dispatch a
    # write-capable worker (two terminals). Session A's PostToolUse return must
    # NOT clear session B's still-live marker.
    my $data = mk_interactive();
    my $payload_a = json_payload(cwd => $data, session_id => 'sessA', tool_name => 'Task',
                                  tool_input => { subagent_type => 'butler:bp-implementer' });
    my $payload_b = json_payload(cwd => $data, session_id => 'sessB', tool_name => 'Task',
                                  tool_input => { subagent_type => 'butler:bp-implementer' });
    run_hook($TRACK, $payload_a);
    run_hook($TRACK, $payload_b);   # session B's dispatch is the one now recorded as owner

    run_hook($UNTRACK, $payload_a);
    ok(-f "$data/.drive-solo/.active-worker",
       'F2 (-> F1, HIGH-3 repro 2): session A'."'".'s PostToolUse return does not clear session B'."'".'s '
     . 'still-live marker (two-terminal / two-session scenario)');

    my $bash_payload = json_payload(cwd => $data, session_id => 'sessB',
                                     tool_input => { command => 'npm test' });
    my ($rc) = run_hook($GUARD, $bash_payload, CCPRAXIS_DATA_DIR => fwd($data));
    is($rc, 2,
       'F2b: validation in session B is still blocked -- session B'."'".'s write-capable worker is '
     . 'demonstrably still in flight, and the interlock was not disarmed by session A'."'".'s return');

    # The owning session (B) returning DOES clear it -- proves F2's allow above
    # is attributable to session scoping, not to untrack being inert.
    run_hook($UNTRACK, $payload_b);
    ok(!-f "$data/.drive-solo/.active-worker",
       'F2c (counter-fixture): the OWNING session'."'".'s (B) own return still clears the marker -- '
     . 'untrack is scoped, not disabled');
}

# ===========================================================================
# G. fixbatch step7 / F2 -- VALIDATION_RE must not fire on a denylisted phrase
#    merely MENTIONED inside an unrelated quoted string or comment. Red-team
#    HIGH-2, verified live: an ordinary `git commit -m "...npm test..."` was
#    falsely denied. Ruled ACCIDENT threat model (see hook header): the false
#    block is the defect to fix; the quote-reconstruction bypass (HIGH-1) is
#    an accepted, documented limit, not asserted here.
# ===========================================================================
{
    my $data = mk_interactive();
    write_marker("$data/.drive-solo/.active-worker", 'bp-implementer');
    my $payload = json_payload(cwd => $data,
        tool_input => { command => 'git commit -m "fix: npm test now passes"' });
    my ($rc, $out, $err) = run_hook($GUARD, $payload, CCPRAXIS_DATA_DIR => fwd($data));
    is($rc, 0,
       'G1 (-> F2, HIGH-2): an ordinary git commit whose MESSAGE merely mentions "npm test" is NOT '
     . 'denied -- the phrase is inert, quoted text, not an executed validation command')
        or diag("stderr=[$err]");
}

{
    my $data = mk_interactive();
    write_marker("$data/.drive-solo/.active-worker", 'bp-implementer');
    my $payload = json_payload(cwd => $data,
        tool_input => { command => 'echo "remember to run npm test after lunch"' });
    my ($rc, $out, $err) = run_hook($GUARD, $payload, CCPRAXIS_DATA_DIR => fwd($data));
    is($rc, 0,
       'G2 (-> F2, HIGH-2): an echo reminder that merely mentions "npm test" inside a quoted string '
     . 'is NOT denied')
        or diag("stderr=[$err]");
}

{
    # Counter-fixture: an UNQUOTED, bare denylisted command must still be
    # denied -- proves G1/G2's allow is attributable to the quote-stripping
    # fix, not to VALIDATION_RE no longer matching "npm test" at all (this is
    # exactly A1, re-asserted here as the explicit counter-fixture for G1/G2).
    my $data = mk_interactive();
    write_marker("$data/.drive-solo/.active-worker", 'bp-implementer');
    my $payload = json_payload(cwd => $data, tool_input => { command => 'npm test' });
    my ($rc, $out, $err) = run_hook($GUARD, $payload, CCPRAXIS_DATA_DIR => fwd($data));
    is($rc, 2,
       'G3 (counter-fixture to G1/G2): a bare, unquoted "npm test" is still denied -- the interlock '
     . 'was not accidentally disabled by the quote-stripping fix')
        or diag("stderr=[$err]");
}

# ===========================================================================
# E. hooks.json registration (spec §2.5) -- additive only, feeds DC1/DC5
#    because a hook that exists on disk but is never registered never fires.
# ===========================================================================
{
    ok(-f $HOOKSJSON, 'FIXTURE-SANITY: hooks.json exists') or BAIL_OUT('no hooks.json');
    my $raw = read_file($HOOKSJSON);
    my $doc = eval { JSON::PP->new->decode($raw) };
    ok(ref $doc eq 'HASH', 'E1: hooks.json parses as JSON after any edit') or diag("decode failed: $@");

    my (@guard_blocks, @track_pre_blocks, @untrack_post_blocks);
    for my $entry (@{ $doc->{hooks}{PreToolUse} // [] }) {
        next unless ref $entry eq 'HASH';
        for my $h (@{ $entry->{hooks} // [] }) {
            next unless ref $h eq 'HASH';
            my $cmd = $h->{command} // '';
            push @guard_blocks, $entry if $cmd =~ /guard-validation-interlock\.sh/;
            push @track_pre_blocks, $entry if $cmd =~ /track-worker-solo\.sh/;
        }
    }
    for my $entry (@{ $doc->{hooks}{PostToolUse} // [] }) {
        next unless ref $entry eq 'HASH';
        for my $h (@{ $entry->{hooks} // [] }) {
            next unless ref $h eq 'HASH';
            push @untrack_post_blocks, $entry if ($h->{command} // '') =~ /untrack-worker-solo\.sh/;
        }
    }

    is(scalar(@guard_blocks), 1,
       'E2 (-> DC1/DC5): hooks.json registers guard-validation-interlock.sh exactly once under '
     . 'PreToolUse')
        or diag('an unregistered hook can exist on disk and never fire for a real session');
    if (@guard_blocks) {
        my @alts = split /\|/, ($guard_blocks[0]{matcher} // '');
        ok((grep { $_ eq 'Bash' } @alts) ? 1 : 0,
           'E3: ...under a matcher that includes Bash as its own alternative');
    }

    is(scalar(@track_pre_blocks), 1,
       'E4 (-> DC1 behavior 5): hooks.json registers track-worker-solo.sh exactly once under '
     . 'PreToolUse');
    if (@track_pre_blocks) {
        my @alts = split /\|/, ($track_pre_blocks[0]{matcher} // '');
        ok((grep { $_ eq 'Task' } @alts) && (grep { $_ eq 'Agent' } @alts),
           'E5: ...under a matcher covering both Task and Agent as their own alternatives');
    }

    is(scalar(@untrack_post_blocks), 1,
       'E6 (-> DC1 behavior 6): hooks.json registers untrack-worker-solo.sh exactly once under '
     . 'PostToolUse');
    if (@untrack_post_blocks) {
        my @alts = split /\|/, ($untrack_post_blocks[0]{matcher} // '');
        ok((grep { $_ eq 'Task' } @alts) && (grep { $_ eq 'Agent' } @alts),
           'E7: ...under a matcher covering both Task and Agent as their own alternatives');
    }

    # E8/E9 (regression guard, spec §2.5): track-dispatch.sh's existing Task
    # block must NOT be widened to include Agent as a side effect of this
    # package -- that widening reads subagent_type, unverified for Agent.
    my $track_dispatch_matcher = '';
    for my $entry (@{ $doc->{hooks}{PreToolUse} // [] }) {
        next unless ref $entry eq 'HASH';
        for my $h (@{ $entry->{hooks} // [] }) {
            next unless ref $h eq 'HASH';
            $track_dispatch_matcher = $entry->{matcher} // ''
                if ($h->{command} // '') =~ /track-dispatch\.sh/;
        }
    }
    unlike($track_dispatch_matcher, qr/\bAgent\b/,
       'E8 (regression guard): track-dispatch.sh'."'".' own matcher is not widened to Agent as a '
     . 'side effect of this package'."'".'s additive hooks.json edit');
}

done_testing();
