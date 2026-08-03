#!/usr/bin/env perl
# b15-wait-shape-and-pipe-guards oracle. Derived ONLY from
# .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/specs/b15-wait-shape-and-pipe-guards-spec.md
# §2 (interfaces & contracts), §3 (observable behaviours 1..20), §4 (AC-1..AC-37) and §5 (edge
# cases 1..11), plus the harness contract in the package ledger's 09:36Z entry.
#
# WRITTEN BLIND TO ANY IMPLEMENTATION. plugins/butler/hooks/wait-shape-guard.sh does not exist at
# the time this file was authored, and hooks.json carries no wait-shape-guard entry. Every AC
# assertion below must therefore fail on MISSING BEHAVIOUR -- `bash "$HOOK"` on an absent file
# exits 127, and `source` of an absent file leaves every bp_ws_* helper undefined so the pure
# callers echo nothing -- never on a perl/harness bug of this file. The assertions labelled
# FIXTURE-SANITY: are deliberate harness self-checks and are expected to PASS even with the hook
# absent; they are the evidence that the red below is attributable to the missing hook and not to
# broken scaffolding.
#
# HARNESS RULES (binding, from the 09:36Z ledger entry and spec §4.1 -- not re-derived here):
#   * %CLEAN_ENV strips EVERY ambient BP_*. This suite is run BY coordinator sessions and harvest
#     judges that export BP_LEDGER/BP_DIR/BP_PROJECT_ROOT; an inherited value silently turns AC-23
#     ("inert outside a butler session") into a FALSE PASS. This is the single most important rule
#     in this file.
#   * run_hook writes the payload to a temp file and runs
#     `timeout N bash "$HOOK" < payload > outfile 2> errfile`. Invoking via `bash` (never by
#     executing the file directly) means a missing exec bit cannot produce a false red. rc 124
#     would mean the hook HUNG -- a real risk for a guard that shells out to grep -- and is asserted
#     against in AC-25 via run_hook_bounded.
#   * done_testing(), NOT a hand-counted `plan tests => N`. t/62's hardcoded plan is described in
#     t/64's own header as "half of the blocker this package already carries".
#   * ALL fixtures are SYNTHESIZED under File::Temp. No live ledger under
#     .ccpraxis-local-data/blueprints/*/packages/ is read, and above all none is written -- those
#     are live orchestration state for a running fleet.
#   * Output is captured to temp files, never by reopening STDOUT/STDERR onto an in-memory scalar
#     (Git-for-Windows perl fails there with "Bad file descriptor"; project CLAUDE.md landmine).
#   * Never shell out to rg: ripgrep is .gitignore-aware and returns a FALSE CLEAN for anything
#     under .ccpraxis-local-data/.
#   * The pure-helper groups run UNCONDITIONALLY (spec §2.1: the file is sourceable by the D1
#     main-guard precisely so matcher correctness has coverage on the jq-less Windows host). Only
#     the subprocess/hook groups are wrapped in one jq-gated SKIP.
#
# NO `use utf8` HERE, DELIBERATELY. The mandated deny messages (§2.10) carry an em dash; it is
# spelled below as the explicit bytes "\xE2\x80\x94" so this file never depends on its own source
# encoding, and every command string stays a byte string -- the bytes a real command carries.
#
# KNOWN-RED, NOT THIS FILE'S BUSINESS (spec §7 E-1): registering the fifth PreToolUse block turns
# exactly one assertion red in t/62-repeat-guard.t and one in t/64-ledger-guard.t. Both are outside
# b15's write set and this file deliberately asserts nothing about them.
#
# DELIBERATE OMISSION: AC-37 ("perl t/67-wait-shape-guard.t exits 0 with zero not ok") is
# self-referential and untestable from inside this file; the coordinator judges it at step 5. There
# is deliberately no AC-37 block below (t/64 records the same ruling for its own AC-38).
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP;
use POSIX qw(mkfifo);

(my $HOOKS = "$Bin/../../hooks") =~ s{\\}{/}g;
my $HOOK       = "$HOOKS/wait-shape-guard.sh";
my $LIB        = "$HOOKS/lib.sh";
my $HOOKSJSON  = "$HOOKS/hooks.json";
my $SELFTEST_T = "$Bin/14-hooks-selftest.t";

my $J    = JSON::PP->new->canonical;
my $ROOT = tempdir(CLEANUP => 1);
my $pn   = 0;
my $bpn  = 0;

my $have_jq = do { my $o = `bash -c 'command -v jq' 2>/dev/null`; $o =~ /\S/ ? 1 : 0 };

sub fwd { (my $p = shift) =~ s{\\}{/}g; $p }

# A hook test must control the hook's environment COMPLETELY (t/62:76, t/64:65).
my %CLEAN_ENV = map { ($_ => $ENV{$_}) } grep { !/^BP_/ } keys %ENV;

diag("subject under test: $HOOK "
     . (-e $HOOK
        ? "(present)"
        : "(ABSENT -- every AC assertion below is expected to fail on MISSING BEHAVIOUR)"));

# =====================================================================================
# Scaffolding
# =====================================================================================

sub write_file {
    my ($path, $bytes) = @_;
    open my $w, '>', $path or die "write $path: $!";
    binmode $w;
    print $w $bytes;
    close $w;
}

sub read_file {
    my ($path) = @_;
    open my $r, '<', $path or return '';
    binmode $r;
    my $c = do { local $/; <$r> }; close $r;
    return defined $c ? $c : '';
}

# A fresh blueprint dir (with its own runs/) plus a separate project root, per case.
sub mk_bp {
    my $n = ++$bpn;
    my $d = "$ROOT/bp$n";
    mkdir $d or die "mkdir $d: $!";
    mkdir "$d/$_" or die "mkdir $d/$_: $!" for qw(packages reports specs runs);
    my $p = "$ROOT/proj$n";
    mkdir $p or die "mkdir $p: $!";
    return (fwd($d), fwd($p));
}

# BP_PACKAGE is 'p' so the taskpoll state file is "p.taskpoll-<TOKEN>.log" (AC-21).
sub env_for {
    my ($bp, $proj) = @_;
    return (BP_DIR          => $bp,
            BP_PROJECT_ROOT => $proj,
            BP_LEDGER       => "$bp/packages/fixture-pkg.md",
            BP_PACKAGE      => 'p');
}

# NB: returns @f (not `sort ...` directly) so the eleven `scalar(runs_files($bp))`
# call sites get a COUNT. `return sort ...` is undef in scalar context, which made
# every one of those assertions fail against any implementation.
sub runs_files { my ($bp) = @_; my @f = sort map { fwd($_) } glob("$bp/runs/*"); return @f; }

# Every hook invocation is recorded so AC-28 and AC-31 can assert over ALL of them at the end.
my @CALLS;

# payload -> temp file -> `timeout N bash "$HOOK" < payload > out 2> err`.
# Returns (rc, stderr, stdout). stdout and stderr are captured SEPARATELY because AC-31 asserts
# stdout is always empty, which a 2>&1 combined capture could not distinguish.
sub run_hook_ex {
    my ($payload, $tmo, %env) = @_;
    my $n  = ++$pn;
    my $pf = "$ROOT/payload.$n.json";
    my $of = "$ROOT/stdout.$n.txt";
    my $ef = "$ROOT/stderr.$n.txt";
    write_file($pf, $payload);
    my $rc;
    {
        local %ENV = (%CLEAN_ENV, %env,
                      HOOKPATH => fwd($HOOK), PFILE => fwd($pf),
                      OFILE    => fwd($of),   EFILE => fwd($ef));
        system('bash', '-c',
               qq{timeout $tmo bash "\$HOOKPATH" < "\$PFILE" > "\$OFILE" 2> "\$EFILE"});
        $rc = $? >> 8;
    }
    my $out = read_file($of);
    my $err = read_file($ef);
    push @CALLS, { rc => $rc, out => $out, err => $err };
    return ($rc, $err, $out);
}

sub run_hook         { my ($p, %e) = @_;      return run_hook_ex($p, 60, %e) }
sub run_hook_bounded { my ($p, $t, %e) = @_;  return run_hook_ex($p, $t, %e) }

# --- pure-helper invocation (spec §2.1: MANDATED form, arg0 'h' so $0 differs from the guard path,
#     which is what keeps the main-guard from running the enforcement body). stderr goes to a temp
#     file so a missing guard cannot pollute this file's TAP stream.
sub ws_call {
    my ($fn, $sfile, @args) = @_;
    my $ef = "$ROOT/wserr." . (++$pn) . ".txt";
    local %ENV = (%CLEAN_ENV,
                  GUARDSH => fwd($HOOK),
                  SFILE   => (defined $sfile ? fwd($sfile) : '/dev/null'),
                  EFILE   => fwd($ef));
    open(my $f, '-|', 'bash', '-c',
         qq{{ source "\$GUARDSH"; $fn "\$@"; } < "\$SFILE" 2>"\$EFILE"}, 'h', @args)
        or die "bash: $!";
    my $o = do { local $/; <$f> }; close $f;
    $o = '' unless defined $o;
    $o =~ s/\s+\z//;
    return $o;
}

sub is_wait_loop         { return ws_call('bp_ws_is_wait_loop',         undef, $_[0]) }
sub is_false_green_pipe  { return ws_call('bp_ws_is_false_green_pipe',  undef, $_[0]) }
sub is_task_artifact_poll{ return ws_call('bp_ws_is_task_artifact_poll',undef, $_[0]) }
sub action_of            { return ws_call('bp_ws_action_of',            undef, $_[0]) }

sub state_path_call {
    my ($token, $dir, $pkg) = @_;
    my $ef = "$ROOT/wserr." . (++$pn) . ".txt";
    local %ENV = (%CLEAN_ENV, GUARDSH => fwd($HOOK), EFILE => fwd($ef),
                  BP_DIR => $dir, (defined $pkg ? (BP_PACKAGE => $pkg) : ()));
    open(my $f, '-|', 'bash', '-c',
         '{ source "$GUARDSH"; bp_ws_state_path "$1"; } 2>"$EFILE"', 'h', $token) or die "bash: $!";
    my $o = do { local $/; <$f> }; close $f;
    $o = '' unless defined $o;
    $o =~ s/\s+\z//;
    return $o;
}

# bp_ws_count_window TASKTOK NOW WINDOW_SECONDS, state lines on stdin.
sub count_window {
    my ($tok, $now, $win, @lines) = @_;
    my $sf = "$ROOT/cw." . (++$pn) . ".txt";
    open my $w, '>', $sf or die "write $sf: $!";
    binmode $w;
    print $w "$_\n" for @lines;
    close $w;
    return ws_call('bp_ws_count_window', $sf, $tok, $now, $win);
}

# lib.sh's sanitiser, reused read-only (spec §2.6 mandates the same token function).
sub session_token {
    my ($raw) = @_;
    local %ENV = (%CLEAN_ENV, LIBSH => $LIB);
    open(my $f, '-|', 'bash', '-c', 'source "$LIBSH"; bp_repeat_session_token "$1"', 'h', $raw)
        or die "bash: $!";
    my $o = do { local $/; <$f> }; close $f;
    $o = '' unless defined $o;
    $o =~ s/\s+\z//;
    return $o;
}

# PATH containing every executable on the ambient PATH EXCEPT $name (t/62:472, t/64:279).
sub path_without {
    my ($name) = @_;
    my $d = "$ROOT/no-$name-bin";
    return fwd($d) if -d $d;
    mkdir $d or die "mkdir $d: $!";
    my %seen;
    for my $dir (split(/:/, ($CLEAN_ENV{PATH} // '')), '/usr/bin', '/bin', '/usr/local/bin') {
        next unless length $dir && -d $dir;
        opendir(my $dh, $dir) or next;
        for my $f (readdir $dh) {
            next if $f eq $name || $f =~ /^\./;
            next if $seen{$f}++;
            my $src = "$dir/$f";
            next unless -f $src && -x $src;
            symlink($src, "$d/$f");
        }
        closedir $dh;
    }
    return fwd($d);
}

# --- payload builders ---------------------------------------------------------------
my $SESSION = 'b15sess0001';

sub pl_bash {
    my ($cmd, %extra) = @_;
    return $J->encode({ tool_name => 'Bash', session_id => $SESSION, cwd => '/project',
                        tool_input => { command => $cmd, %extra } });
}
sub pl_tool {
    my ($tool, $ti) = @_;
    return $J->encode({ tool_name => $tool, session_id => $SESSION, cwd => '/project',
                        tool_input => $ti });
}
sub pl_taskoutput {
    my ($id, $i) = @_;   # arguments DIFFER between calls (AC-18) while the target does not
    return pl_tool('TaskOutput', { task_id => $id, offset => 100 * $i, limit => 50 + $i });
}

# --- the mandated deny messages (§2.10), verbatim. The em dash is spelled as explicit bytes so
#     this file never depends on its own source encoding.
my $DASH = "\xE2\x80\x94";
my $PFX  = "WAIT-SHAPE-GUARD: BLOCKED $DASH ";
my $SKILL = 'plugins/butler/skills/coordinator-protocol/SKILL.md';

my $MSG_R1 = $PFX . 'wait-loop: this command polls in a shell loop (a while/until/for containing a'
  . ' sleep). Waiting this way burns your turn budget and your context and produces no information.'
  . ' Do not poll: run the work in the FOREGROUND and read its result, or dispatch it and let the'
  . ' completion notification come back to you, or record what you are waiting for under'
  . " '## Next action' in the ledger and stop. See the waiting discipline in $SKILL.";

my $MSG_R2 = $PFX . 'false-green-pipe: this pipes a command into tail/head and then reads $?, which'
  . " is the exit status of tail/head, not of the command $DASH a failing command reads as green."
  . ' Correct form: run it unpiped and capture the status on the very next statement, e.g.'
  . ' cmd > /tmp/out.txt 2>&1; echo "exit=$?"; tail -20 /tmp/out.txt. A command substitution also'
  . " preserves the status: out=\$(cmd 2>&1); rc=\$?. See the waiting discipline in $SKILL.";

my $MSG_R3B = $PFX . "task-output-poll: this command sleeps while probing a subagent's"
  . " tasks/<id>.output transcript. That file is the subagent's full JSONL stream: reading it"
  . ' overflows your context, and watching it grow tells you nothing you can act on. Wait for the'
  . " worker's own report file instead, or record what you are waiting for under '## Next action'"
  . " in the ledger and stop. See the waiting discipline in $SKILL.";

sub msg_r3a {
    my ($n, $id, $w) = @_;
    return $PFX . "task-output-poll: this is TaskOutput call #$n against task $id within the last"
      . " $w seconds. The arguments differ between these calls but the target does not, so this is"
      . ' polling. This SUPERSEDES the REPEAT-GUARD advisory\'s "keep polling with those" carve-out'
      . ' for repeated polls at one target: that carve-out covers waiting, not re-reading the same'
      . ' target. Stop polling this task: wait for its report file, or record what you are waiting'
      . " for under '## Next action' in the ledger and stop. See the waiting discipline in $SKILL."
      . " Target: task $id";
}

# §2.10 command echo-back: newlines/CR/tabs -> a single space, truncated to 200 chars with ASCII '...'.
sub flat_cmd { my $c = shift; $c =~ s/[\n\r\t]/ /g; return $c }

# Assert a denial line: exact equality when the flattened command fits in the 200-char budget,
# otherwise prefix + ASCII-'...' truncation shape. Never weakened below "one line, exact prefix".
sub like_deny {
    my ($err, $base, $cmd, $label) = @_;
    my $flat = flat_cmd($cmd);
    is(scalar(() = $err =~ /\n/g), 1, "$label: exactly one newline-terminated stderr line");
    if (length($flat) <= 200) {
        is($err, "$base Command: $flat\n", "$label: stderr is the mandated message VERBATIM with the full command echoed back");
    }
    else {
        my $want_prefix = "$base Command: ";
        is(index($err, $want_prefix), 0, "$label: stderr begins with the mandated message VERBATIM followed by ' Command: '");
        my $tail = length($err) > length($want_prefix) ? substr($err, length($want_prefix)) : '';
        $tail =~ s/\n\z//;
        ok(length($tail) >= 190 && length($tail) <= 210,
           "$label: the echoed command is truncated to the 200-char budget (got " . length($tail) . ")");
        like($tail, qr/\.\.\.\z/, "$label: truncation marker is ASCII '...'");
        ok(length($tail) >= 150 && index($flat, substr($tail, 0, 150)) == 0,
           "$label: the echo-back is the FLATTENED command's leading bytes");
    }
    unlike($err, qr/\xE2\x80\xA6/, "$label: no non-ASCII ellipsis byte sequence on the stderr line");
    unlike($err, qr/[\t\r]/,       "$label: no tab or CR survives into the stderr line");
}

# =====================================================================================
# The corpus strings. Every one is verbatim from the two step-1 reports as quoted by spec §4,
# except those the spec itself marks (instantiated).
# =====================================================================================

my $W1 = q{until grep -q '^_status: complete\|^## Summary\|^## Attack 5' .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/reports/b09-judge-starvation-and-verdict-archive/redteam-step6.md; do sleep 10; done};

my $W2 = q{until [ -f .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/reports/b09-judge-starvation-and-verdict-archive/implementer-step7-batch1.md ]; do sleep 15; done; echo "report created"};

my $W3 = q{S=.ccpraxis-local-data/blueprints/sandbox-butler-overhaul/specs/b10-repeat-command-guard-spec.md; timeout 570 bash -c 'until [ -s "$0" ]; do sleep 10; done' "$S" ; if [ -s "$S" ]; then echo "SPEC PRESENT: $(wc -c < "$S") bytes"; else echo "STILL WAITING (architect in flight)"; fi};

# W4/W5 carry REAL newlines (spec §5.1), not \n escapes -- the landmine that under-counted the corpus.
my $W4 = join("\n",
    q{cd /project},
    q{timeout 420 bash -c '},
    q{  while [ ! -f .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/reports/b08-dag-integrity-and-deadlock/testwriter-chunk1.md ]; do sleep 5; done},
    q{  echo REPORT_PRESENT},
    q{'});

my $W5 = join("\n",
    q{T=/project/plugins/butler/tests/t/77-feedback-intake.t},
    q{B=$(stat -c %Y "$T"); n=0},
    q{until [ "$(stat -c %Y "$T")" != "$B" ] || [ $n -ge 40 ]; do sleep 15; n=$((n+1)); done},
    q{echo "t/77: $(stat -c %s "$T") bytes"});

# W6: corpus family 3 -- `for` ONLY, no while/until. The shape a naive matcher misses.
my $W6 = q{for i in $(seq 1 40); do [ -s "$R" ] && break; sleep 6; done; echo "waited"};

my @WAITS = (['W1 until grep -q (b09)', $W1], ['W2 until [ -f ] (b09)', $W2],
             ['W3 until [ -s ] inside timeout (b10)', $W3], ['W4 while [ ! -f ], real newlines (b08)', $W4],
             ['W5 counter-bounded until, real newlines (b25)', $W5], ['W6 for i in $(seq 1 N) (family 3)', $W6]);

my $AC2a = q{while [ ! -s .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/reports/b09-judge-starvation-and-verdict-archive/redteam-step6.md ]; do sleep 10; done};
my $AC2b = q{while true; do sleep 30; done};
my @AC2 = (['while [ ! -s <report> ] (instantiated from DC-W1)', $AC2a],
           ['while true; do sleep 30; done (instantiated)', $AC2b]);

# AC-6: legitimate loop-free sleeps. THE NEGATIVE CRITERION -- a false positive here blocks real
# work fleet-wide, so these matter as much as the denials.
my @AC6 = (
    ['one-shot sleep 2 (the criterion\'s own case)', q{echo start; sleep 2; echo done}],
    ['mtime-resolution probe, sleep 1.1',           q{perl -e 'print "a"' > /tmp/x; sleep 1.1; perl -e 'print "b"' > /tmp/x}],
    ['race setup before a signal, sleep 0.05',      q{sleep 0.05; kill -INT %1}],
    ['backgrounded synthetic PID',                  q{sleep 300 & MYPID=$!}],
    ['deliberate backoff inside timeout',           q{timeout 200 bash -c 'sleep 180'}],
    ['deliberate backoff',                          q{sleep 20 && echo "backoff done"}],
);

# AC-7: `sleep` as a NON-COMMAND token.
my @AC7 = (
    ['a Time::HiRes module import',  q{perl -MTime::HiRes=time,sleep -e 'print time'}],
    ['a grep pattern containing "sleep *=>"', q{grep -n 'usleep\|sleep *=>\|nanosleep' plugins/butler/scripts/bp-orchestrator.pl}],
);

# §5.2: `sleep 30` inside quoted perl program text, spared because it carries no loop keyword.
my $QUOTED_PERL = q{printf '%s' 'shim("$R/hang", "sleep 30;")' > /tmp/fixture-frag.txt};

my $AC8 = q{for f in plugins/butler/tests/t/*.t; do out=$(timeout 120 perl "$f" 2>&1); rc=$?; nok=$(printf '%s' "$out" | grep -c '^not ok'); echo "$f rc=$rc nok=$nok"; done};

my $AC9 = q{echo "=== hooks.json matchers across ALL installed plugins (evidence for wildcard) ==="; find /root/.claude -name 'hooks.json' 2>/dev/null | while read f; do echo "--- $f"; jq -r '.hooks | to_entries[] | "\(.key): " + ([.value[] | (.matcher // "<none>")] | join(" , "))' "$f" 2>/dev/null; done | head -60};

# AC-11: the false-green-pipe true positives.
my $P7 = join("\n", q{perl plugins/butler/tests/t/64-ledger-guard.t 2>&1 | tail -20}, q{echo "EXIT=$?"});
# Single-quoted on purpose: this must hold a LITERAL `$?`, not the interpolated
# value of the last exit status. See the AC-11 message assertion below.
my $CORRECT_FORM = q{cmd > /tmp/out.txt 2>&1; echo "exit=$?"};

my @AC11 = (
    ['t/62 into tail -20 then EXIT=$?',      q{perl plugins/butler/tests/t/62-repeat-guard.t 2>&1 | tail -20; echo "EXIT=$?"}],
    ['t/73 into tail -5 then exit=$?',       q{perl plugins/butler/tests/t/73-status-recognition.t 2>&1 | tail -5; echo "exit=$?"}],
    ['timeout perl t/52 into tail -60',      q{timeout 120 perl plugins/sandbox/tests/t/52-detector-hardening.t 2>&1 | tail -60; echo "EXIT=$?"}],
    ['run-tests.pl into tail -25',           q{perl plugins/sandbox/tests/run-tests.pl 2>&1 | tail -25; echo "EXIT=$?"}],
    ['leading && then setsid prove | tail',  q{cd /project && perl -c plugins/butler/scripts/bp-orchestrator.pl && setsid prove plugins/butler/tests/t/20-turns.t 2>&1 | tail -20; echo "EXIT=$?"}],
    ['head form, rc=$? (instantiated)',      q{npm run lint 2>&1 | head -5; rc=$?}],
    ['NEWLINE-separated adjacency (instantiated)', $P7],
);

# AC-13: a pipe into tail/head with NO $? read. THE SECOND NEGATIVE CRITERION.
my @AC13 = (
    ['ls -la repeat-guard.sh | tail -1',  q{ls -la /project/plugins/butler/hooks/repeat-guard.sh 2>&1 | tail -1}],
    ['ls -la specs/ | tail -20',          q{ls -la .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/specs/ 2>&1 | tail -20}],
    ['| while read ... done | head -60',  $AC9],
);

# AC-14: the CORRECT forms -- 287 in-corpus instances the naive matcher would have denied.
my @AC14 = (
    ['redirect then echo "exit=$?" then tail (287 instances)', q{prove plugins/sandbox/tests/t/52-detector-hardening.t > /tmp/prove2.txt 2>&1; echo "exit=$?"; tail -3 /tmp/prove2.txt}],
    ['command substitution then rc=$?',                        q{out=$(perl plugins/butler/tests/t/62-repeat-guard.t 2>&1); rc=$?}],
);

# AC-15: META-04's regex must NOT be implemented.
my @AC15 = (
    ['(a) the mandated test-runner idiom -- META-04\'s confirmed in-corpus false positive', $AC8],
    ['(b) $? two statements after the pipeline (instantiated)', q{cmd | tail -5; echo done; rc=$?}],
    ['(c) tail is not the last pipeline stage, so $? is grep\'s (instantiated)', q{cmd | tail -20 | grep foo; echo $?}],
);

# AC-16: the DOCUMENTED KNOWN MISSES of D4 (§2.9), pinned so nobody "fixes" the gap into an
# over-blocking matcher without a fresh decision.
my @AC16 = (
    ['sleep 120; cat <report> | tail -20', q{sleep 120; cat .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/reports/b09-judge-starvation-and-verdict-archive/implementer-step7-batch1.md | tail -20}],
    ['sleep 45; grep -n <report>',         q{sleep 45; grep -n '^## Attack\|^_status\|^## Summary' .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/reports/b09-judge-starvation-and-verdict-archive/redteam-step6.md}],
);

# AC-17: R3b.
my @AC17 = (
    ['wc -c <tasks/id.output>; sleep 90; wc -c ...', q{wc -c /tmp/claude-0/-project/x/tasks/a8f15ee1ec26598b5.output; sleep 90; echo "--- 90s later ---"; wc -c /tmp/claude-0/-project/x/tasks/a8f15ee1ec26598b5.output}],
    ['F=<tasks/id.output>; stat; sleep 20; stat',    q{F=/tmp/claude-0/-project/x/tasks/af531f5f871ddac8c.output; s1=$(stat -c%s "$F" 2>/dev/null); sleep 20; s2=$(stat -c%s "$F" 2>/dev/null); echo "transcript bytes: $s1 -> $s2"}],
);
my $AC17_ALLOW = q{for id in a49213afc416089fd a712a884417c60e49; do printf '%s %s\n' "$id" "$(stat -c %s "$T/$id.output")"; done};

# §2.13 rule precedence R1 -> R3b -> R2, first match wins.
my $PREC_R1_R3B = q{until [ -s /tmp/claude-0/-project/x/tasks/a8f15ee1ec26598b5.output ]; do sleep 10; done};
my $PREC_R3B_R2 = q{sleep 30; cat /tmp/claude-0/-project/x/tasks/a8f15ee1ec26598b5.output | tail -20; echo "EXIT=$?"};
my $PREC_R1_R2  = q{for i in $(seq 1 3); do sleep 6; done; perl plugins/butler/tests/t/62-repeat-guard.t 2>&1 | tail -20; echo "EXIT=$?"};

# index()-based substring assertions: a literal like `rc=$?` or `${BASH_SOURCE[0]}` cannot go inside
# an interpolating qr// without perl eating it, and \Q...\E does NOT prevent interpolation.
sub has_str  { my ($hay, $needle, $label) = @_; ok(index($hay, $needle) >= 0, $label) }
sub lacks_str{ my ($hay, $needle, $label) = @_; ok(index($hay, $needle) <  0, $label) }

# =====================================================================================
# FIXTURE SANITY -- these must pass with or without the hook. They are what proves the red
# below is "hook missing", not "harness broken".
# =====================================================================================
{
    my %seen;
    $seen{$_->[1]}++ for @WAITS;
    is(scalar(keys %seen), 6, 'FIXTURE-SANITY: the six wait constructs are SIX TEXTUALLY DISTINCT strings (DC-W2)');

    unlike($W6, qr/\bwhile\b/, 'FIXTURE-SANITY: W6 carries no "while" keyword');
    unlike($W6, qr/\buntil\b/, 'FIXTURE-SANITY: W6 carries no "until" keyword -- it is the family-3 shape a while|until matcher misses');
    like($W6,   qr/\bfor\b/,   'FIXTURE-SANITY: W6 is a `for` loop');

    like($W4, qr/\n/, 'FIXTURE-SANITY: W4 carries REAL newlines, not backslash-n escapes');
    like($W5, qr/\n/, 'FIXTURE-SANITY: W5 carries REAL newlines, not backslash-n escapes');
    unlike($W4, qr/\\n/, 'FIXTURE-SANITY: W4 carries no literal backslash-n (the corpus-pass landmine)');
    like($W3, qr/\btimeout 570\b/, 'FIXTURE-SANITY: W3 is timeout-wrapped (AC-5: timeout is not an exemption)');
    like($W4, qr/\btimeout 420\b/, 'FIXTURE-SANITY: W4 is timeout-wrapped');

    for my $c (@AC6) {
        like($c->[1], qr/sleep/, "FIXTURE-SANITY: AC-6 [$c->[0]] really contains the token 'sleep'");
        unlike($c->[1], qr/(^|[^A-Za-z0-9_-])(while|until|for)[[:space:]]/,
               "FIXTURE-SANITY: AC-6 [$c->[0]] carries NO loop keyword (that is why it is legitimate)");
    }
    for my $c (@AC7) {
        like($c->[1], qr/sleep/, "FIXTURE-SANITY: AC-7 [$c->[0]] really contains the token 'sleep'");
        unlike($c->[1], qr/(^|[^A-Za-z0-9_-])sleep[[:space:]]+[0-9]/,
               "FIXTURE-SANITY: AC-7 [$c->[0]] has no whitespace+digit after 'sleep' -- it is not a sleep command");
    }
    like($QUOTED_PERL, qr/sleep 30/, 'FIXTURE-SANITY: the quoted-perl-program-text case really embeds "sleep 30"');
    unlike($QUOTED_PERL, qr/(^|[^A-Za-z0-9_-])(while|until|for)[[:space:]]/,
           'FIXTURE-SANITY: the quoted-perl-program-text case carries no loop keyword');

    like($AC8, qr/\bfor f in\b/, 'FIXTURE-SANITY: AC-8 is a loop');
    unlike($AC8, qr/sleep/,      'FIXTURE-SANITY: AC-8 contains no "sleep" at all -- loop WITHOUT sleep');
    has_str($AC8, q{rc=$?},      'FIXTURE-SANITY: AC-8 does read $? (it is META-04\'s false positive)');
    like($AC8, qr/\|/,           'FIXTURE-SANITY: AC-8 does contain a pipe');
    like($AC8, qr/tests/,        'FIXTURE-SANITY: AC-8 contains the literal "test" fragment META-04\'s alternation matched');

    like($AC9, qr/\| *head -60/, 'FIXTURE-SANITY: AC-9 ends in a pipe into head');
    lacks_str($AC9, q{$?},       'FIXTURE-SANITY: AC-9 never reads $?');

    for my $c (@AC11) {
        like($c->[1], qr/\|[[:space:]]*(tail|head)/, "FIXTURE-SANITY: AC-11 [$c->[0]] pipes into tail/head");
        has_str($c->[1], q{$?},                      "FIXTURE-SANITY: AC-11 [$c->[0]] reads \$?");
    }
    like($P7, qr/\n/, 'FIXTURE-SANITY: the AC-11 adjacency variant is NEWLINE-separated (spec §5.1 flattening)');

    unlike($AC14[0][1], qr/\|[[:space:]]*tail/, 'FIXTURE-SANITY: AC-14 redirect form has NO pipe into tail (the 287-instance correct form)');
    like($AC14[0][1],   qr/tail -3/,            'FIXTURE-SANITY: AC-14 redirect form does invoke tail, just not through a pipe');
    like($AC14[1][1],   qr/\Qout=$(\E/,         'FIXTURE-SANITY: AC-14 substitution form uses a command substitution');

    for my $c (@AC17) {
        like($c->[1], qr{tasks/[A-Za-z0-9_-]+\.output}, "FIXTURE-SANITY: AC-17 [$c->[0]] references a tasks/<id>.output path");
        like($c->[1], qr/(^|[^A-Za-z0-9_-])sleep[[:space:]]+[0-9]/, "FIXTURE-SANITY: AC-17 [$c->[0]] carries a numeric sleep");
    }
    unlike($AC17_ALLOW, qr/sleep/, 'FIXTURE-SANITY: the sleepless R3b control carries no sleep at all');

    is(length($DASH), 3, 'FIXTURE-SANITY: the em dash in the mandated prefix is three raw bytes (no use utf8 in this file)');
    is($PFX, "WAIT-SHAPE-GUARD: BLOCKED \xE2\x80\x94 ", 'FIXTURE-SANITY: the mandated deny prefix is byte-exact');
    like($MSG_R1, qr/FOREGROUND/,           'FIXTURE-SANITY: the R1 expectation string carries the mandated FOREGROUND clause');
    has_str($MSG_R2, q{out=$(cmd 2>&1); rc=$?}, 'FIXTURE-SANITY: the R2 expectation string carries the mandated command-substitution advice');
    like(msg_r3a(6, 'tok', 600), qr/SUPERSEDES/, 'FIXTURE-SANITY: the R3a expectation string carries the SUPERSEDES clause');

    ok(-e $LIB && -s $LIB, 'FIXTURE-SANITY: hooks/lib.sh is present (its bp_repeat_session_token is reused read-only)');
    my $tok = session_token($SESSION);
    like($tok, qr/\A[A-Za-z0-9_-]{1,16}\z/, 'FIXTURE-SANITY: lib.sh sanitises the fixture session id to a usable token');
    ok(-e $HOOKSJSON && -s $HOOKSJSON, 'FIXTURE-SANITY: hooks/hooks.json is present and non-empty');
    ok($have_jq, 'FIXTURE-SANITY: jq is available on this host (the hook-behaviour groups will run)');

    my ($bp, $proj) = mk_bp();
    ok(-d "$bp/runs", 'FIXTURE-SANITY: mk_bp creates a fresh, EMPTY runs/ per case');
    is(scalar(runs_files($bp)), 0, 'FIXTURE-SANITY: a fresh BP_DIR/runs/ starts with zero files');
    my %e = env_for($bp, $proj);
    is($e{BP_PACKAGE}, 'p', 'FIXTURE-SANITY: BP_PACKAGE is "p", so the taskpoll state file is p.taskpoll-<TOKEN>.log');
    ok(!grep({ /^BP_/ } keys %CLEAN_ENV),
       'FIXTURE-SANITY: %CLEAN_ENV carries ZERO ambient BP_* vars (without this, AC-23 false-passes)');
}

# =====================================================================================
# [pure] Matcher-level coverage. Runs UNCONDITIONALLY -- spec §2.1/§4.1: the D1 main-guard exists
# precisely so this group keeps its value on the jq-less Windows host, where the highest-risk part
# of the package (false positives that block real work fleet-wide) would otherwise have zero
# coverage. Each helper is invoked with arg0 'h' per the MANDATED §2.1 source form.
# =====================================================================================

# --- AC-10: bp_ws_is_wait_loop ------------------------------------------------------
for my $c (@WAITS) {
    is(is_wait_loop($c->[1]), 'yes', "AC-10 [pure]: bp_ws_is_wait_loop echoes yes for $c->[0]");
}
for my $c (@AC2) {
    is(is_wait_loop($c->[1]), 'yes', "AC-10 [pure]: bp_ws_is_wait_loop echoes yes for $c->[0]");
}
for my $c (@AC6) {
    is(is_wait_loop($c->[1]), 'no', "AC-10 [pure]: bp_ws_is_wait_loop echoes NO for the legitimate loop-free sleep [$c->[0]]");
}
for my $c (@AC7) {
    is(is_wait_loop($c->[1]), 'no', "AC-10 [pure]: bp_ws_is_wait_loop echoes NO for sleep-as-a-non-command-token [$c->[0]]");
}
is(is_wait_loop($QUOTED_PERL), 'no', 'AC-10 [pure]: bp_ws_is_wait_loop echoes NO for a quoted perl program text embedding "sleep 30" (§5.2)');
is(is_wait_loop($AC8), 'no', 'AC-10 [pure]: bp_ws_is_wait_loop echoes NO for the mandated test-runner idiom (loop WITHOUT sleep)');
is(is_wait_loop($AC9), 'no', 'AC-10 [pure]: bp_ws_is_wait_loop echoes NO for `find | while read ... done | head -60`');
for my $c (@AC13, @AC14, @AC15, @AC16, @AC11) {
    is(is_wait_loop($c->[1]), 'no', "AC-10 [pure]: bp_ws_is_wait_loop echoes NO for the pipe-group string [$c->[0]]");
}
is(is_wait_loop($AC17_ALLOW), 'no', 'AC-10 [pure]: bp_ws_is_wait_loop echoes NO for the sleepless task-output listing');
is(is_wait_loop($PREC_R1_R3B), 'yes', 'AC-10 [pure]: bp_ws_is_wait_loop echoes yes for the R1+R3b overlap string');
is(is_wait_loop($PREC_R1_R2),  'yes', 'AC-10 [pure]: bp_ws_is_wait_loop echoes yes for the R1+R2 overlap string');
is(is_wait_loop(''),           'no',  'AC-10 [pure]: bp_ws_is_wait_loop echoes no for the empty command');

# --- [pure] §2.2/§2.4: bp_ws_is_false_green_pipe -------------------------------------
for my $c (@AC11) {
    is(is_false_green_pipe($c->[1]), 'yes', "§2.4 [pure]: bp_ws_is_false_green_pipe echoes yes for $c->[0]");
}
for my $c (@AC13) {
    is(is_false_green_pipe($c->[1]), 'no', "§2.4 [pure]: bp_ws_is_false_green_pipe echoes NO for a pipe into tail/head with no \$? read [$c->[0]]");
}
for my $c (@AC14) {
    is(is_false_green_pipe($c->[1]), 'no', "§2.4 [pure]: bp_ws_is_false_green_pipe echoes NO for the CORRECT form [$c->[0]]");
}
for my $c (@AC15) {
    is(is_false_green_pipe($c->[1]), 'no', "§2.4 [pure]: bp_ws_is_false_green_pipe echoes NO for META-04's discriminating case [$c->[0]]");
}
for my $c (@AC16) {
    is(is_false_green_pipe($c->[1]), 'no', "§2.4 [pure]: bp_ws_is_false_green_pipe echoes NO for the known-miss string [$c->[0]]");
}
is(is_false_green_pipe(q{cmd | tail -20 || echo "failed $?"}), 'no',
   '§5.4 [pure]: `|| ` after a pipeline is a recorded, accepted evasion -- under-matching is the safe direction');
is(is_false_green_pipe(''), 'no', '§2.4 [pure]: bp_ws_is_false_green_pipe echoes no for the empty command');

# --- [pure] §2.5: bp_ws_is_task_artifact_poll ----------------------------------------
for my $c (@AC17) {
    is(is_task_artifact_poll($c->[1]), 'yes', "§2.5 [pure]: bp_ws_is_task_artifact_poll echoes yes for $c->[0]");
}
is(is_task_artifact_poll($AC17_ALLOW), 'no', '§2.5 [pure]: bp_ws_is_task_artifact_poll echoes NO for the sleepless task-output listing');
is(is_task_artifact_poll($PREC_R1_R3B), 'yes', '§2.5 [pure]: bp_ws_is_task_artifact_poll echoes yes for the R1+R3b overlap string');
for my $c (@AC6, @AC7) {
    is(is_task_artifact_poll($c->[1]), 'no', "§2.5 [pure]: bp_ws_is_task_artifact_poll echoes NO for [$c->[0]] (no tasks/<id>.output token)");
}
is(is_task_artifact_poll(q{sleep 30; cat /tmp/x/tasks/bad id.output}), 'no',
   '§2.5 [pure]: a tasks/ path with a space in the id does not satisfy tasks/[A-Za-z0-9_-]+\.output');
is(is_task_artifact_poll(''), 'no', '§2.5 [pure]: bp_ws_is_task_artifact_poll echoes no for the empty command');

# --- AC-29 [pure] bp_ws_action_of: the deliberate C-5 INVERSION of b10's mapping -----
is(action_of(''),      'deny', 'AC-29 [pure]: bp_ws_action_of "" -> deny (the default is enforcement)');
is(action_of('deny'),  'deny', 'AC-29 [pure]: bp_ws_action_of "deny" -> deny');
is(action_of('off'),   'off',  'AC-29 [pure]: bp_ws_action_of "off" -> off (the operational escape hatch)');
is(action_of('bogus'), 'deny', 'AC-29 [pure]: bp_ws_action_of "bogus" -> DENY (a typo must never silently disarm the guard)');
is(action_of('nudge'), 'deny', 'AC-29 [pure]: bp_ws_action_of "nudge" -> DENY (b10\'s vocabulary is not b15\'s)');
is(action_of('Off'),   'deny', 'AC-29 [pure]: bp_ws_action_of "Off" -> DENY (case-sensitive; not "off")');
is(action_of('0'),     'deny', 'AC-29 [pure]: bp_ws_action_of "0" -> DENY');

# --- [pure] §2.2/§2.6: bp_ws_state_path, and the b10 filename divergence -------------
{
    my $tok = 'TOK1';
    is(state_path_call($tok, '/tmp/bpx', 'p'), '/tmp/bpx/runs/p.taskpoll-TOK1.log',
       '§2.6 [pure]: bp_ws_state_path is $BP_DIR/runs/$BP_PACKAGE.taskpoll-<TOKEN>.log');
    is(state_path_call($tok, '/tmp/bpx', undef), '/tmp/bpx/runs/pkg.taskpoll-TOK1.log',
       '§2.6 [pure]: bp_ws_state_path falls back to "pkg" when BP_PACKAGE is unset');
    unlike(state_path_call($tok, '/tmp/bpx', 'p'), qr/\.repeat-/,
           '§2.6 [pure]: the state filename is NOT b10\'s repeat-<TOKEN>.log (writing there would corrupt b10\'s window)');
}

# --- [pure] §2.2/§2.6: bp_ws_count_window -- CUMULATIVE in a window, not a trailing run ----
{
    is(count_window('t1', 1000, 600), '1',
       '§2.6 [pure]: no prior state -> count is 1 (the current, not-yet-written call)');
    is(count_window('t1', 1000, 600, "900\tt1", "920\tt1", "940\tt1"), '4',
       '§2.6 [pure]: three in-window lines at the same task -> 4 (three plus the current call)');
    is(count_window('t1', 1000, 600, "900\tt1", "910\tt2", "920\tt1"), '3',
       '§2.6 [pure]: an INTERVENING different task does not break the scan -- cumulative, not a trailing run');
    is(count_window('t1', 1000, 600, "100\tt1", "950\tt1"), '2',
       '§2.6 [pure]: a line older than the window is excluded');
    is(count_window('t1', 1000, 0, "100\tt1", "950\tt1"), '3',
       '§2.6 [pure]: WINDOW_SECONDS 0 disables the time filter');
    is(count_window('t1', 1000, 600, "garbage", "abc\tt1", "900\tt1\textra", "900\tt1"), '2',
       '§2.6 [pure]: malformed state lines are skipped, never fatal');
    is(count_window('t2', 1000, 600, "900\tt1", "920\tt1"), '1',
       '§2.6 [pure]: a different task id counts separately');
    is(count_window('t1', 'notanum', 600, "900\tt1"), '1',
       '§2.6 [pure]: a non-integer NOW fails OPEN to 1');
    is(count_window('t1', 1000, 'notanum', "900\tt1"), '1',
       '§2.6 [pure]: a non-integer WINDOW_SECONDS fails OPEN to 1');
}

# --- AC-30 [pure] sourcing the guard is SILENT and INERT, with and without the butler env ----
{
    my @cases = (
        ['with the full butler env set', { BP_DIR => '/tmp/x', BP_PROJECT_ROOT => '/tmp/y', BP_LEDGER => '/tmp/z.md' }],
        ['with the butler env unset',    {}],
    );
    for my $c (@cases) {
        my ($label, $env) = @$c;
        my $n  = ++$pn;
        my $of = "$ROOT/src-out.$n.txt";
        my $ef = "$ROOT/src-err.$n.txt";
        my $rc;
        {
            local %ENV = (%CLEAN_ENV, %$env, GUARDSH => fwd($HOOK), OFILE => fwd($of), EFILE => fwd($ef));
            system('bash', '-c',
                   'timeout 20 bash -c \'source "$GUARDSH"; echo REACHED\' h > "$OFILE" 2> "$EFILE"');
            $rc = $? >> 8;
        }
        is($rc, 0, "AC-30 ($label): sourcing the guard and continuing exits 0 -- the enforcement body did NOT run");
        is(read_file($of), "REACHED\n", "AC-30 ($label): stdout is exactly REACHED (sourcing writes nothing of its own)");
        is(read_file($ef), '',          "AC-30 ($label): sourcing produces no stderr");
    }
}

# =====================================================================================
# [file] Source-text criteria. No jq, no hook process -- pure greps over the guard source.
# =====================================================================================
{
    my $src = -e $HOOK ? read_file($HOOK) : undef;
    ok(defined $src && length $src, 'AC-33: plugins/butler/hooks/wait-shape-guard.sh exists and is non-empty');
    $src = '' unless defined $src;

    my @lines     = split /\n/, $src, -1;
    my @code      = grep { !/^\s*#/ } @lines;
    my $code      = join("\n", @code);

    # AC-26 (DC-H2): the judge opt-out must be ABSENT. Its presence would silently fail
    # "applies to judges too" while every other test stayed green (§2.11).
    is(scalar(() = $src =~ /BP_ROLE/g), 0,
       'AC-26: the guard source contains ZERO occurrences of BP_ROLE (the gate-stop.sh judge opt-out must not be copied in)');

    # AC-27: fail-OPEN on infrastructure, and nothing that could clobber the deliberate exit 2.
    is(scalar(() = $src =~ /bp_hook_require_jq/g), 0,
       'AC-27: the guard source contains ZERO occurrences of bp_hook_require_jq (that helper is fail-CLOSED)');
    is(scalar(grep { /^set -e/ || /trap .* EXIT/ } @lines), 0,
       'AC-27: the guard source has no `set -e` and no `trap ... EXIT` (either would clobber the deliberate exit 2)');
    like($code, qr/command -v jq/, 'AC-27: the guard reaches for the fail-open `command -v jq` idiom instead');

    # AC-21: b10's state-path helper must never be called.
    is(scalar(() = $src =~ /bp_repeat_state_path/g), 0,
       'AC-21: the guard source contains ZERO occurrences of bp_repeat_state_path (it would corrupt b10\'s rolling window)');

    # AC-5: `timeout`-wrapping is NOT an exemption -- no matcher regex may carry a timeout clause.
    my @re_lines = grep { /BP_WS_(LOOP|SLEEP|PIPE|TASKOUT)_RE=/ } @lines;
    is(scalar(grep { /timeout/ } @re_lines), 0,
       'AC-5: no BP_WS_*_RE assignment mentions "timeout" (18 of 21 observed constructs are timeout-wrapped and still pathological)');
    is(scalar(grep { /timeout/ } @code), 0,
       'AC-5: no non-comment line of the guard mentions "timeout" at all (§2.3-5: none may be added)');

    # §2.1 D1: the mandated bottom-of-file main-guard idiom, verbatim.
    # index()-based per the rule at the top of this file: `${BASH_SOURCE[0]}` and `$0`
    # interpolate inside qr// and \Q...\E does not stop it (that spelling was a compile error).
    has_str($code, q{if [ "${BASH_SOURCE[0]}" = "$0" ]; then},
            '§2.1/AC-30: the guard carries the MANDATED main-guard condition verbatim');
    like($code, qr/\Qbp_ws_main\E/, '§2.1: the guard defines/invokes bp_ws_main');

    # §2.3/§2.4/§2.5: the mandated EREs, verbatim.
    like($code, qr/\QBP_WS_LOOP_RE='(^|[^A-Za-z0-9_-])(while|until|for)[[:space:]]'\E/,
         '§2.3: BP_WS_LOOP_RE is the mandated ERE verbatim (it includes `for`, not just while|until)');
    like($code, qr/\QBP_WS_SLEEP_RE='(^|[^A-Za-z0-9_-])sleep[[:space:]]+[0-9]'\E/,
         '§2.3: BP_WS_SLEEP_RE is the mandated ERE verbatim (a numeric argument is required after sleep)');
    like($code, qr/\QBP_WS_PIPE_RE='\|[[:space:]]*(tail|head)([[:space:]][^;&|]*)?[;&]+[^;&|]*\$\?'\E/,
         '§2.4: BP_WS_PIPE_RE is the mandated strict-adjacency ERE verbatim');
    like($code, qr/\QBP_WS_TASKOUT_RE='tasks\/[A-Za-z0-9_-]+\.output'\E/,
         '§2.5: BP_WS_TASKOUT_RE is the mandated ERE verbatim');

    # §2.4: META-04's REJECTED alternation must not appear.
    unlike($code, qr/analyze\|test\|lint\|build/,
           '§2.4: META-04\'s command alternation is NOT implemented (1 confirmed FP, 0 TP in corpus)');
}

# =====================================================================================
# AC-32..AC-35 [file] hooks.json registration. THIS is where the registration evidence lives --
# t/14-hooks-selftest.t never opens hooks.json (ledger 09:14Z), so it proves nothing here.
# Needs no jq and no hook process.
# =====================================================================================
{
    my $raw = read_file($HOOKSJSON);
    ok(length $raw, 'AC-32: hooks.json is readable and non-empty');
    my $H = eval { $J->decode($raw) };
    ok(defined $H, 'AC-32: hooks.json still parses as valid JSON') or diag("parse error: $@");

    my $cmd_of = sub { my $f = shift; return qq(bash "\${CLAUDE_PLUGIN_ROOT}/hooks/$f") };
    my $pre = ($H && $H->{hooks}{PreToolUse}) // [];

    # AC-33: b15's block is matcher-less with exactly one entry.
    #
    # LOCATED BY COMMAND, not by position (relaxed 2026-08-03, b43). This originally
    # asserted b15's block was the LAST in the array. That is a positional
    # over-specification: hooks in a PreToolUse array ALL run, so order carries no
    # meaning, and "last" simply forbids any later package from appending — which b43
    # then legitimately did, breaking this oracle for no behavioural reason.
    # Exactly the shape b26 documented and b15 itself hit on the block COUNT
    # (`== 4` -> `>= 4`, operator-approved); this is the same lesson one axis over.
    # Nothing is weakened: every property b15 actually guards — its block exists, is
    # matcher-less, has exactly one entry, and that entry is byte-exact — is still
    # asserted, and now cannot be satisfied by some OTHER package's block happening to
    # sit last.
    ok(scalar(@$pre) >= 5, 'AC-33: PreToolUse carries at least five blocks (b15 appends a fifth)');
    my ($b15_block) = grep {
        scalar(@{ $_->{hooks} // [] }) == 1
        && ($_->{hooks}[0]{command} // '') eq $cmd_of->('wait-shape-guard.sh')
    } @$pre;
    ok(defined $b15_block, "AC-33: b15's wait-shape-guard.sh block is registered in PreToolUse")
        or diag('no PreToolUse block invokes wait-shape-guard.sh');
    my $last = $b15_block // {};
    ok(defined $b15_block && !exists $last->{matcher},
       'AC-33: b15\'s PreToolUse block has NO matcher key (match-all-by-omission, the in-tree idiom for a universal hook)');
    is(scalar(@{ $last->{hooks} // [] }), 1, 'AC-33: b15\'s PreToolUse block has exactly one hook entry');
    is_deeply($last->{hooks}[0],
              { type => 'command', command => $cmd_of->('wait-shape-guard.sh'), timeout => 15 },
              'AC-33: the entry is exactly { type: command, command: bash "${CLAUDE_PLUGIN_ROOT}/hooks/wait-shape-guard.sh", timeout: 15 }');

    # AC-34: blocks 0-3 are byte-for-byte what they read today; PostToolUse and Stop untouched.
    my $b0 = $pre->[0] // {};
    is($b0->{matcher}, 'Edit|Write|MultiEdit|NotebookEdit', 'AC-34: block 0 matcher unchanged');
    is_deeply([ map { $_->{command} } @{ $b0->{hooks} // [] } ],
              [ $cmd_of->('gate-shutdown.sh'), $cmd_of->('guard-writes.sh'), $cmd_of->('ledger-guard.sh') ],
              'AC-34: block 0 command list unchanged, in order');
    my $b1 = $pre->[1] // {};
    is($b1->{matcher}, 'Bash', 'AC-34: block 1 matcher is still Bash');
    is_deeply([ map { $_->{command} } @{ $b1->{hooks} // [] } ], [ $cmd_of->('guard-bash.sh') ],
              'AC-34: block 1 command list unchanged (b15 must NOT append here)');
    my $b2 = $pre->[2] // {};
    is($b2->{matcher}, 'Task', 'AC-34: block 2 matcher unchanged');
    is_deeply([ map { $_->{command} } @{ $b2->{hooks} // [] } ],
              [ $cmd_of->('gate-shutdown.sh'), $cmd_of->('track-dispatch.sh') ],
              'AC-34: block 2 command list unchanged, in order');
    my $b3 = $pre->[3] // {};
    ok(!exists $b3->{matcher}, 'AC-34: block 3 (b10 repeat-guard) still has NO matcher key');
    is_deeply([ map { $_->{command} } @{ $b3->{hooks} // [] } ], [ $cmd_of->('repeat-guard.sh') ],
              'AC-34: block 3 command list unchanged (b15 must NOT append here either)');

    my $post = ($H && $H->{hooks}{PostToolUse}) // [];
    is(scalar(@$post), 1, 'AC-34: PostToolUse still has exactly one block');
    is($post->[0]{matcher}, 'Task', 'AC-34: PostToolUse matcher unchanged');
    is_deeply([ map { $_->{command} } @{ $post->[0]{hooks} // [] } ], [ $cmd_of->('log-dispatch.sh') ],
              'AC-34: PostToolUse hook list unchanged');
    my $stop = ($H && $H->{hooks}{Stop}) // [];
    is(scalar(@$stop), 1, 'AC-34: Stop still has exactly one block');
    ok(!exists $stop->[0]{matcher}, 'AC-34: Stop block still has no matcher key');
    is_deeply([ map { $_->{command} } @{ $stop->[0]{hooks} // [] } ], [ $cmd_of->('gate-stop.sh') ],
              'AC-34: Stop hook list unchanged');

    # AC-35(a): the absence of a matcher key IS the "reached for every tool" evidence. (b) is the
    # behavioural conjunction asserted in the jq-gated group below.
    ok(defined $b15_block && !exists $last->{matcher},
       'AC-35(a): b15\'s block is matcher-less, which is how it is reached for BOTH Bash and TaskOutput');
    # `>= 2`, not `== 2`, for the same reason AC-33 no longer says "last": a later
    # package may legitimately register another matcher-less universal hook, and that
    # says nothing about whether b10's and b15's are still correct. Both are asserted
    # individually — b15's immediately above, b10's in t/62 — so this is a floor, not
    # a licence. An exact count here would forbid extension, which is the standoff
    # b26 was written to end.
    cmp_ok(scalar(grep { !exists $_->{matcher} } @$pre), '>=', 2,
       'AC-35(a): at least two PreToolUse blocks are matcher-less -- b10\'s and b15\'s');
}

# =====================================================================================
# AC-36 [file] t/14-hooks-selftest.t stays green. Captured through a pipe so the child's TAP never
# pollutes this file's stream. Per the 09:14Z ledger entry this criterion is NON-DISCRIMINATING --
# t/14 never reads hooks.json -- so it is asserted for completeness only. AC-32..AC-35 are the
# registration evidence.
# =====================================================================================
{
    my $out14 = do { local %ENV = %CLEAN_ENV; `perl "$SELFTEST_T" 2>&1` };
    my $rc14 = $? >> 8;
    is($rc14, 0, 'AC-36: perl plugins/butler/tests/t/14-hooks-selftest.t exits 0');
    my $notok = () = ($out14 // '') =~ /^not ok /mg;
    is($notok, 0, 'AC-36: 14-hooks-selftest.t emits zero "not ok" lines');
}

# =====================================================================================
# Every remaining group drives the hook PROCESS, which needs jq present to get past
# `command -v jq || exit 0` (§2.13). One SKIP keeps this file useful on the jq-less
# Git-for-Windows host, mirroring t/62:465 and t/64:404. AC-25's jq-scrubbed case lives INSIDE it
# because it still needs the hook to run at all.
# =====================================================================================
SKIP: {
    skip "jq is not available on this host; every hook-behaviour group needs it present to get past `command -v jq`", 1
        unless $have_jq;

    # =================================================================================
    # AC-1 / AC-3 / AC-5 [R1] the six textually-distinct wait constructs, each denied
    # INDIVIDUALLY -- first and only invocation in its own fresh BP_DIR, so no repeat-counting
    # can be what fires (DC-W2, §2.8). AC-20 rides along: no state file may appear.
    # =================================================================================
    my %seen_bp;
    for my $c (@WAITS) {
        my ($label, $cmd) = @$c;
        my ($bp, $proj) = mk_bp();
        ok(!$seen_bp{$bp}++, "AC-3 [$label]: runs in its own SEPARATE BP_DIR (no cross-case state can exist)");
        is(scalar(runs_files($bp)), 0, "AC-3 [$label]: that BP_DIR/runs/ is empty BEFORE the single invocation");
        my ($rc, $err, $out) = run_hook(pl_bash($cmd), env_for($bp, $proj));
        is($rc, 2, "AC-1 [$label]: the FIRST AND ONLY invocation denies (exit 2)");
        like($err, qr/\Q$PFX\Ewait-loop:/, "AC-1 [$label]: stderr names the wait-loop rule with the mandated prefix");
        is($out, '', "AC-1 [$label]: stdout is empty");
        is(scalar(runs_files($bp)), 0, "AC-20 [$label]: the R1 denial wrote NO file under \$BP_DIR/runs/ (R1 is stateless)");
    }

    # AC-5: the two timeout-wrapped constructs are among the six above, and they denied.
    {
        my ($bp, $proj) = mk_bp();
        my ($rc3) = run_hook(pl_bash($W3), env_for($bp, $proj));
        is($rc3, 2, 'AC-5: W3 is `timeout 570`-wrapped and still denies -- timeout is NOT an exemption');
        my ($bp2, $proj2) = mk_bp();
        my ($rc4) = run_hook(pl_bash($W4), env_for($bp2, $proj2));
        is($rc4, 2, 'AC-5: W4 is `timeout 420`-wrapped and still denies');
    }

    # =================================================================================
    # AC-2 [R1] the two shapes DC-W1 names that W1..W6 do not literally contain.
    # =================================================================================
    for my $c (@AC2) {
        my ($label, $cmd) = @$c;
        my ($bp, $proj) = mk_bp();
        my ($rc, $err) = run_hook(pl_bash($cmd), env_for($bp, $proj));
        is($rc, 2, "AC-2 [$label]: denied (exit 2)");
        like($err, qr/\Q$PFX\Ewait-loop:/, "AC-2 [$label]: stderr names the wait-loop rule");
    }

    # =================================================================================
    # AC-4 [R1] the message points at the cheaper alternative, and is the mandated text VERBATIM.
    # =================================================================================
    {
        my ($bp, $proj) = mk_bp();
        my ($rc, $err) = run_hook(pl_bash($W6), env_for($bp, $proj));
        is($rc, 2, 'AC-4: W6 denies');
        like($err, qr/FOREGROUND/,   'AC-4: the R1 message names running the work in the FOREGROUND');
        like($err, qr/notification/, 'AC-4: the R1 message names the completion notification route');
        like($err, qr{\Qplugins/butler/skills/coordinator-protocol/SKILL.md\E},
             'AC-4: the R1 message cites the waiting discipline in the coordinator protocol skill');
        like($err, qr/\Q## Next action\E/, 'AC-4: the R1 message names the "## Next action" park route');
        like_deny($err, $MSG_R1, $W6, 'AC-4/§2.10 [R1, short command]');
    }

    # §2.10: a LONG multi-line command is flattened and truncated onto ONE stderr line.
    {
        my ($bp, $proj) = mk_bp();
        my ($rc, $err) = run_hook(pl_bash($W1), env_for($bp, $proj));
        is($rc, 2, '§2.10: the long single-line W1 denies');
        like_deny($err, $MSG_R1, $W1, '§2.10 [R1, long command]');

        my ($bp2, $proj2) = mk_bp();
        my ($rc2, $err2) = run_hook(pl_bash($W4), env_for($bp2, $proj2));
        is($rc2, 2, '§2.10: the multi-line W4 denies');
        like_deny($err2, $MSG_R1, $W4, '§2.10 [R1, multi-line command]');
    }

    # =================================================================================
    # AC-6 / AC-7 / AC-8 / AC-9 [R1 NEGATIVE] *** THE FALSE-POSITIVE CRITERION ***
    # A false positive here blocks real work fleet-wide; these matter as much as the denials.
    # =================================================================================
    {
        my ($bp, $proj) = mk_bp();
        my %env = env_for($bp, $proj);
        for my $c (@AC6) {
            my ($rc, $err, $out) = run_hook(pl_bash($c->[1]), %env);
            is($rc,  0,  "AC-6 [$c->[0]]: a legitimate loop-free sleep is ALLOWED (exit 0)");
            is($err, '', "AC-6 [$c->[0]]: emits nothing on stderr");
            is($out, '', "AC-6 [$c->[0]]: emits nothing on stdout");
        }
        for my $c (@AC7) {
            my ($rc, $err) = run_hook(pl_bash($c->[1]), %env);
            is($rc,  0,  "AC-7 [$c->[0]]: `sleep` as a non-command token is ALLOWED (exit 0)");
            is($err, '', "AC-7 [$c->[0]]: emits nothing");
        }
        my ($rcq, $errq) = run_hook(pl_bash($QUOTED_PERL), %env);
        is($rcq,  0,  '§5.2: a quoted perl program text embedding "sleep 30;" is ALLOWED (no loop keyword)');
        is($errq, '', '§5.2: emits nothing');

        my ($rc8, $err8) = run_hook(pl_bash($AC8), %env);
        is($rc8,  0,  'AC-8: the project\'s MANDATED test-runner idiom (loop without sleep) is ALLOWED (exit 0)');
        is($err8, '', 'AC-8: emits nothing -- the highest-value false-positive specimen');

        my ($rc9, $err9) = run_hook(pl_bash($AC9), %env);
        is($rc9,  0,  'AC-9: `find | while read f; do ... done | head -60` is ALLOWED (exit 0)');
        is($err9, '', 'AC-9: emits nothing');

        is(scalar(runs_files($bp)), 0, 'AC-20: none of the allowed Bash commands created a file under $BP_DIR/runs/');
    }

    # =================================================================================
    # AC-11 / AC-12 [R2] the false-green pipe, denied on STRICT ADJACENCY.
    # =================================================================================
    {
        my ($bp, $proj) = mk_bp();
        my %env = env_for($bp, $proj);
        for my $c (@AC11) {
            my ($rc, $err, $out) = run_hook(pl_bash($c->[1]), %env);
            is($rc, 2, "AC-11 [$c->[0]]: denied (exit 2)");
            like($err, qr/\Q$PFX\Efalse-green-pipe:/, "AC-11 [$c->[0]]: stderr names the false-green-pipe rule");
            # Coordinator fix: `qr{\Q...exit=$?\E}` did NOT assert what it reads as.
            # \Q quotes metacharacters but does NOT suppress interpolation, so `$?`
            # (last exit status) expanded and the pattern compiled to `exit\=0` —
            # demanding the literal text "exit=0" while the spec mandates the message
            # carry a verbatim `$?`. No implementation could satisfy both. Build the
            # literal in a single-quoted variable, then \Q the variable.
            like($err, qr/\Q$CORRECT_FORM\E/,
                 "AC-11 [$c->[0]]: the message shows the redirect-then-\$? correct form");
            is($out, '', "AC-11 [$c->[0]]: stdout is empty");
        }
        is(scalar(runs_files($bp)), 0, 'AC-20: an R2 denial wrote NO file under $BP_DIR/runs/ (R2 is stateless)');

        # AC-12: DC-P1's named alternation is covered by a strict SUPERSET.
        # Coordinator fix: the fourth pair asserted $AC11[2][1] contains the literal
        # substring 'timeout perl', but that fixture is `timeout 120 perl ...` — the
        # two words are never adjacent, so the assertion could never pass regardless
        # of implementation. Mismatched fixture/assertion pairing; the intent is that
        # the denied set covers a timeout-wrapped perl invocation.
        for my $t (['prove', $AC11[4][1]], ['perl', $AC11[0][1]], ['npm', $AC11[5][1]], ['timeout 120 perl', $AC11[2][1]]) {
            like($t->[1], qr/\Q$t->[0]\E/, "AC-12: the denied set includes a '$t->[0]' command from DC-P1's alternation");
        }

        # Exact, mandated message text for a short case.
        my ($rc, $err) = run_hook(pl_bash($AC11[5][1]), %env);
        is($rc, 2, 'AC-11: the short `npm run lint | head -5; rc=$?` case denies');
        like_deny($err, $MSG_R2, $AC11[5][1], 'AC-11/§2.10 [R2]');
    }

    # =================================================================================
    # AC-13 / AC-14 / AC-15 [R2 NEGATIVE] *** THE SECOND FALSE-POSITIVE CRITERION ***
    # The corpus has 287 instances of the redirect form against 36 true positives; denying them
    # would punish the exact behaviour the deny message recommends.
    # =================================================================================
    {
        my ($bp, $proj) = mk_bp();
        my %env = env_for($bp, $proj);
        for my $c (@AC13) {
            my ($rc, $err) = run_hook(pl_bash($c->[1]), %env);
            is($rc,  0,  "AC-13 [$c->[0]]: a pipe into tail/head with NO \$? read is ALLOWED (exit 0)");
            is($err, '', "AC-13 [$c->[0]]: emits nothing");
        }
        for my $c (@AC14) {
            my ($rc, $err) = run_hook(pl_bash($c->[1]), %env);
            is($rc,  0,  "AC-14 [$c->[0]]: the CORRECT form is ALLOWED (exit 0)");
            is($err, '', "AC-14 [$c->[0]]: emits nothing");
        }
        for my $c (@AC15) {
            my ($rc, $err) = run_hook(pl_bash($c->[1]), %env);
            is($rc,  0,  "AC-15 [$c->[0]]: exit 0 -- META-04's regex is NOT implemented");
            is($err, '', "AC-15 [$c->[0]]: emits nothing");
        }
    }

    # =================================================================================
    # AC-16 [D4 KNOWN MISS] bare one-shot `sleep` polling stays ALLOWED, deliberately (§2.9).
    # Asserted so nobody later "fixes" this gap into an over-blocking matcher without a decision.
    # =================================================================================
    {
        my ($bp, $proj) = mk_bp();
        my %env = env_for($bp, $proj);
        for my $c (@AC16) {
            my ($rc, $err) = run_hook(pl_bash($c->[1]), %env);
            is($rc,  0,  "AC-16 KNOWN MISS [$c->[0]]: allowed (exit 0) -- D4 is deliberately out of scope");
            is($err, '', "AC-16 KNOWN MISS [$c->[0]]: emits nothing");
        }
    }

    # =================================================================================
    # AC-17 [R3b] the Bash-side task-output artifact poll.
    # =================================================================================
    {
        my ($bp, $proj) = mk_bp();
        my %env = env_for($bp, $proj);
        for my $c (@AC17) {
            my ($rc, $err, $out) = run_hook(pl_bash($c->[1]), %env);
            is($rc, 2, "AC-17 [$c->[0]]: denied (exit 2)");
            like($err, qr/\Q$PFX\Etask-output-poll:/, "AC-17 [$c->[0]]: stderr names the task-output-poll rule");
            is($out, '', "AC-17 [$c->[0]]: stdout is empty");
            like_deny($err, $MSG_R3B, $c->[1], "AC-17/§2.10 [$c->[0]]");
        }
        is(scalar(runs_files($bp)), 0, 'AC-20: an R3b denial wrote NO file under $BP_DIR/runs/ (R3b is stateless)');

        my ($rc, $err) = run_hook(pl_bash($AC17_ALLOW), %env);
        is($rc,  0,  'AC-17: the SLEEPLESS corpus form listing tasks/*.output sizes is ALLOWED (exit 0)');
        is($err, '', 'AC-17: emits nothing');
    }

    # =================================================================================
    # §2.13 rule precedence R1 -> R3b -> R2, first match wins: a command matching two rules
    # always produces the same single message.
    # =================================================================================
    {
        my ($bp, $proj) = mk_bp();
        my %env = env_for($bp, $proj);

        my ($rc1, $err1) = run_hook(pl_bash($PREC_R1_R3B), %env);
        is($rc1, 2, '§2.13: a command matching R1 AND R3b denies');
        like($err1,   qr/\Q$PFX\Ewait-loop:/,        '§2.13: R1 wins over R3b');
        unlike($err1, qr/task-output-poll/,          '§2.13: the R3b message is not emitted as well');

        my ($rc2, $err2) = run_hook(pl_bash($PREC_R3B_R2), %env);
        is($rc2, 2, '§2.13: a command matching R3b AND R2 denies');
        like($err2,   qr/\Q$PFX\Etask-output-poll:/, '§2.13: R3b wins over R2');
        unlike($err2, qr/false-green-pipe/,          '§2.13: the R2 message is not emitted as well');

        my ($rc3, $err3) = run_hook(pl_bash($PREC_R1_R2), %env);
        is($rc3, 2, '§2.13: a command matching R1 AND R2 denies');
        like($err3,   qr/\Q$PFX\Ewait-loop:/,        '§2.13: R1 wins over R2');
        unlike($err3, qr/false-green-pipe/,          '§2.13: the R2 message is not emitted as well');
    }

    # =================================================================================
    # AC-18 / AC-21 [R3a] the TaskOutput per-task-id counter. Arguments DIFFER between the six
    # calls -- this is exactly the case b10's hash structurally cannot see.
    # =================================================================================
    my $TOK = session_token($SESSION);
    {
        my ($bp, $proj) = mk_bp();
        my %env = env_for($bp, $proj);
        my $id  = 'a8f15ee1ec26598b5';
        my $idtok = session_token($id);

        # AC-21: b10's own state file, pre-created, must be byte-identical afterwards.
        my $b10file = "$bp/runs/p.repeat-$TOK.log";
        my $b10body = "1700000000\tdeadbeefcafe\t1\n1700000060\tdeadbeefcafe\t1\n";
        write_file($b10file, $b10body);

        for my $i (1 .. 5) {
            my ($rc, $err, $out) = run_hook(pl_taskoutput($id, $i), %env);
            is($rc,  0,  "AC-18: TaskOutput call $i of 6 at one task id (default threshold 6) -> exit 0");
            is($err, '', "AC-18: TaskOutput call $i emits nothing");
            is($out, '', "AC-18: TaskOutput call $i writes nothing to stdout");
        }
        my ($rc6, $err6, $out6) = run_hook(pl_taskoutput($id, 6), %env);
        is($rc6, 2, 'AC-18 (DC-W3): TaskOutput call 6 at the SAME task id with DIFFERENT arguments -> exit 2');
        like($err6, qr/\Q$PFX\Etask-output-poll:/, 'AC-18: stderr names the task-output-poll rule');
        like($err6, qr/call #6/,                   'AC-18: stderr states the call count as #6');
        like($err6, qr/SUPERSEDES/,                'AC-18: stderr carries the mandated SUPERSEDES clause');
        like($err6, qr/\Qkeep polling with those\E/,
             'AC-18: stderr quotes the REPEAT-GUARD carve-out it supersedes');
        is($out6, '', 'AC-18: stdout is empty');
        is($err6, msg_r3a(6, $idtok, 600) . "\n",
           'AC-18/§2.10: the R3a stderr line is the mandated message VERBATIM, naming the task token and the 600s window');

        # AC-21: b15's own state file, and b10's untouched.
        my $mine = "$bp/runs/p.taskpoll-$TOK.log";
        ok(-f $mine, "AC-21: b15 wrote its own state file $mine");
        is(read_file($b10file), $b10body, "AC-21: b10's p.repeat-$TOK.log is BYTE-IDENTICAL after the run");
        my @unexpected = grep { $_ ne fwd($mine) && $_ ne fwd($b10file) } runs_files($bp);
        is(scalar(@unexpected), 0, 'AC-21: no other file appeared under $BP_DIR/runs/')
            or diag("unexpected: @unexpected");

        # Denial is STICKY (§2.6): every call at or past the threshold denies.
        my ($rc7, $err7) = run_hook(pl_taskoutput($id, 7), %env);
        is($rc7, 2, '§2.6: the denial is STICKY -- call 7 denies too (there is no once-per-run flag)');
        like($err7, qr/call #7/, '§2.6: the sticky denial reports the new count');
    }

    # A fresh BP_DIR proves the taskpoll file did not exist beforehand.
    {
        my ($bp, $proj) = mk_bp();
        my %env = env_for($bp, $proj);
        is(scalar(runs_files($bp)), 0, 'AC-21: a fresh BP_DIR/runs/ has no taskpoll file before any TaskOutput call');
        my ($rc) = run_hook(pl_taskoutput('zz11', 1), %env);
        is($rc, 0, 'AC-21: the first TaskOutput call at a new id exits 0');
        is_deeply([ runs_files($bp) ], [ fwd("$bp/runs/p.taskpoll-$TOK.log") ],
                  'AC-21: exactly ONE state file is created, and it is b15\'s taskpoll log -- never b10\'s repeat log');
    }

    # =================================================================================
    # AC-19 [R3a] the counter is CUMULATIVE IN A WINDOW, not b10's trailing-consecutive run.
    # =================================================================================
    {
        # (a) an intervening Bash call between TaskOutput 3 and 4 must NOT reset the count.
        my ($bp, $proj) = mk_bp();
        my %env = env_for($bp, $proj);
        my $id  = 'af531f5f871ddac8c';
        for my $i (1 .. 3) {
            my ($rc) = run_hook(pl_taskoutput($id, $i), %env);
            is($rc, 0, "AC-19a: TaskOutput call $i -> exit 0");
        }
        my ($rcb, $errb) = run_hook(pl_bash(q{echo "an unrelated, entirely legitimate command"}), %env);
        is($rcb,  0,  'AC-19a: an INTERVENING Bash call is itself allowed (exit 0)');
        is($errb, '', 'AC-19a: the intervening Bash call emits nothing');
        for my $i (4 .. 5) {
            my ($rc) = run_hook(pl_taskoutput($id, $i), %env);
            is($rc, 0, "AC-19a: TaskOutput call $i after the interleave -> exit 0");
        }
        my ($rc6, $err6) = run_hook(pl_taskoutput($id, 6), %env);
        is($rc6, 2, 'AC-19a: call 6 STILL denies -- an intervening different tool call does not reset the count');
        like($err6, qr/call #6/, 'AC-19a: the count is 6, not restarted at 3');

        # (b) two different task ids, five calls each, interleaved -> every call exits 0.
        my ($bp2, $proj2) = mk_bp();
        my %env2 = env_for($bp2, $proj2);
        for my $i (1 .. 5) {
            my ($rcA) = run_hook(pl_taskoutput('aaaa1111aaaa1111', $i), %env2);
            my ($rcB) = run_hook(pl_taskoutput('bbbb2222bbbb2222', $i), %env2);
            is($rcA, 0, "AC-19b: task A call $i -> exit 0 (a different task id counts separately)");
            is($rcB, 0, "AC-19b: task B call $i -> exit 0");
        }
    }

    # =================================================================================
    # AC-22 [R3a] no extractable task id -> exit 0, no state file. The field name is unknown
    # because the corpus contains no sample, and a guessed field must never produce a block.
    # =================================================================================
    {
        my ($bp, $proj) = mk_bp();
        my %env = env_for($bp, $proj);
        for my $i (1 .. 10) {
            my ($rc, $err) = run_hook(pl_tool('TaskOutput', { offset => $i, limit => 20 }), %env);
            is($rc,  0,  "AC-22: TaskOutput payload $i of 10 with no task_id/taskId/id -> exit 0");
            is($err, '', "AC-22: TaskOutput payload $i emits nothing");
        }
        is(scalar(runs_files($bp)), 0, 'AC-22: ten id-less TaskOutput calls wrote NO state file');
    }

    # The three accepted id field names all work (§2.6).
    for my $field (qw(task_id taskId id)) {
        my ($bp, $proj) = mk_bp();
        my %env = env_for($bp, $proj);
        my $rc;
        for my $i (1 .. 6) {
            ($rc) = run_hook(pl_tool('TaskOutput', { $field => 'cccc3333cccc3333', offset => 10 * $i }), %env);
        }
        is($rc, 2, "§2.6: the task id is extracted from .tool_input.$field -- call 6 denies");
    }

    # =================================================================================
    # AC-23 (DC-H1) *** INERT OUTSIDE A BUTLER SESSION *** with a payload that would otherwise
    # deny. %CLEAN_ENV above is what makes this a real assertion rather than a false pass.
    # =================================================================================
    {
        my @cases = (
            ['BP_LEDGER unset',        sub { my %e = @_; delete $e{BP_LEDGER};       %e }],
            ['BP_LEDGER empty',        sub { my %e = @_; $e{BP_LEDGER} = '';         %e }],
            ['BP_DIR unset',           sub { my %e = @_; delete $e{BP_DIR};          %e }],
            ['BP_DIR empty',           sub { my %e = @_; $e{BP_DIR} = '';            %e }],
            ['BP_PROJECT_ROOT unset',  sub { my %e = @_; delete $e{BP_PROJECT_ROOT}; %e }],
            ['BP_PROJECT_ROOT empty',  sub { my %e = @_; $e{BP_PROJECT_ROOT} = '';   %e }],
            ['all three unset',        sub { my %e = @_; delete @e{qw(BP_LEDGER BP_DIR BP_PROJECT_ROOT)}; %e }],
        );
        for my $c (@cases) {
            my ($label, $mut) = @$c;
            my ($bp, $proj) = mk_bp();
            my %env = $mut->(env_for($bp, $proj));
            my ($rc, $err, $out) = run_hook(pl_bash($W1), %env);
            is($rc,  0,  "AC-23 ($label): a wait-loop that would otherwise deny -> exit 0");
            is($err, '', "AC-23 ($label): stderr is empty");
            is($out, '', "AC-23 ($label): stdout is empty");
            is(scalar(runs_files($bp)), 0, "AC-23 ($label): no filesystem access under \$BP_DIR/runs/");
        }
    }

    # =================================================================================
    # AC-24 (DC-H2) applies to JUDGES exactly as to coordinators. bp-judge.sh exports all three
    # gate vars, so the failure mode here is ADDING a BP_ROLE opt-out line, not omitting one.
    # =================================================================================
    for my $role (qw(conformance-judge resolve-judge harvest-judge)) {
        my ($bp, $proj) = mk_bp();
        my %env = (env_for($bp, $proj), BP_ROLE => $role);
        my ($rc, $err) = run_hook(pl_bash($W1), %env);
        is($rc, 2, "AC-24: BP_ROLE=$role with the full butler env -> exit 2 (judges are in scope)");
        like($err, qr/\Q$PFX\Ewait-loop:/, "AC-24: BP_ROLE=$role gets the same wait-loop message");
    }
    {
        my ($bp, $proj) = mk_bp();
        my %env = (env_for($bp, $proj), BP_ROLE => 'coordinator');
        my ($rc) = run_hook(pl_bash($W1), %env);
        is($rc, 2, 'AC-24: BP_ROLE=coordinator -> exit 2 (the baseline the judge cases are compared against)');
    }

    # =================================================================================
    # AC-25 (D7) fail-OPEN on EVERY infrastructure failure: exit 0, empty stderr, never exit 2.
    # =================================================================================
    {
        # (a) jq absent from PATH.
        {
            my ($bp, $proj) = mk_bp();
            my %env = (env_for($bp, $proj), PATH => path_without('jq'));
            my ($rc, $err) = run_hook(pl_bash($W1), %env);
            is($rc,  0,  'AC-25 (jq scrubbed from PATH): exit 0 -- fail OPEN, NOT bp_hook_require_jq\'s fail-closed exit 2');
            is($err, '', 'AC-25 (jq scrubbed from PATH): stderr is empty');
        }

        # (b) payload-level degradations.
        my ($bp, $proj) = mk_bp();
        my %env = env_for($bp, $proj);
        my @cases = (
            ['empty payload',            ''],
            ['whitespace-only payload',  "   \n"],
            ['malformed JSON',           'this is not json at all {'],
            ['empty JSON object',        '{}'],
            ['tool_name present, .tool_input.command empty', pl_bash('')],
            ['tool_name present, no tool_input at all',      $J->encode({ tool_name => 'Bash', session_id => $SESSION })],
            ['unrecognised tool: Read',  pl_tool('Read', { file_path => '/tmp/x' })],
            ['unrecognised tool: Monitor (never blocked, §6)',        pl_tool('Monitor', { command => $W1 })],
            ['unrecognised tool: ScheduleWakeup (never blocked, §6)', pl_tool('ScheduleWakeup', { seconds => 600 })],
            ['unrecognised tool carrying a wait loop',                pl_tool('Edit', { command => $W1 })],
        );
        for my $c (@cases) {
            my ($label, $payload) = @$c;
            my ($rc, $err, $out) = run_hook($payload, %env);
            is($rc,  0,  "AC-25 ($label): exit 0");
            is($err, '', "AC-25 ($label): stderr is empty");
            is($out, '', "AC-25 ($label): stdout is empty");
        }
        is(scalar(runs_files($bp)), 0, 'AC-25: no infrastructure-failure case touched $BP_DIR/runs/');

        # (c) the taskpoll state path pre-created as a DIRECTORY.
        {
            my ($bpd, $projd) = mk_bp();
            my %envd = env_for($bpd, $projd);
            my $sp = "$bpd/runs/p.taskpoll-$TOK.log";
            mkdir $sp or die "mkdir $sp: $!";
            my ($rc, $err) = run_hook(pl_taskoutput('dddd4444dddd4444', 1), %envd);
            is($rc,  0,  'AC-25 (state path is a DIRECTORY): exit 0');
            is($err, '', 'AC-25 (state path is a DIRECTORY): stderr is empty');
            ok(-d $sp,   'AC-25 (state path is a DIRECTORY): the directory is left alone');
        }

        # (d) the taskpoll state path pre-created as a FIFO. b10's F4: reading it before a type
        #     check hangs FOREVER. run_hook_bounded's rc must be 0, and must NEVER be 124.
        SKIP: {
            my ($bpf, $projf) = mk_bp();
            my %envf = env_for($bpf, $projf);
            my $sp = "$bpf/runs/p.taskpoll-$TOK.log";
            my $made = eval { mkfifo($sp, 0600) };
            skip "mkfifo unavailable on this host", 3 unless $made;
            my ($rc, $err) = run_hook_bounded(pl_taskoutput('eeee5555eeee5555', 1), 20, %envf);
            isnt($rc, 124, 'AC-25 (state path is a FIFO): the hook did NOT hang (rc is not 124)');
            is($rc,  0,    'AC-25 (state path is a FIFO): exit 0 -- type-checked before any read');
            is($err, '',   'AC-25 (state path is a FIFO): stderr is empty');
            unlink $sp;
        }

        # (e) runs/ made read-only. NOTE: this suite usually runs as root inside the sandbox
        #     container, where mode bits are advisory; the assertion is still that the guard
        #     never turns an unwritable state path into a denial.
        {
            my ($bpr, $projr) = mk_bp();
            my %envr = env_for($bpr, $projr);
            chmod 0500, "$bpr/runs" or die "chmod: $!";
            my ($rc, $err) = run_hook(pl_taskoutput('ffff6666ffff6666', 1), %envr);
            chmod 0700, "$bpr/runs";
            is($rc,  0,  'AC-25 (runs/ read-only): exit 0');
            is($err, '', 'AC-25 (runs/ read-only): stderr is empty');
        }
    }

    # =================================================================================
    # AC-29 [end-to-end] the kill switch, with the sign INVERTED from b10, deliberately.
    # =================================================================================
    {
        my ($bp, $proj) = mk_bp();
        my ($rc_off, $err_off) = run_hook(pl_bash($W1), (env_for($bp, $proj), BP_WAITSHAPE_ACTION => 'off'));
        is($rc_off,  0,  'AC-29: BP_WAITSHAPE_ACTION=off -> exit 0 on an otherwise-denied payload');
        is($err_off, '', 'AC-29: the off case emits nothing');

        my ($bp2, $proj2) = mk_bp();
        my ($rc_bog, $err_bog) = run_hook(pl_bash($W1), (env_for($bp2, $proj2), BP_WAITSHAPE_ACTION => 'bogus'));
        is($rc_bog, 2, 'AC-29: BP_WAITSHAPE_ACTION=bogus -> exit 2 (an unrecognised value must NOT silently disarm the guard)');
        like($err_bog, qr/\Q$PFX\Ewait-loop:/, 'AC-29: the bogus-value case still emits the mandated message');

        my ($bp3, $proj3) = mk_bp();
        my ($rc_dfl) = run_hook(pl_bash($W1), (env_for($bp3, $proj3), BP_WAITSHAPE_ACTION => ''));
        is($rc_dfl, 2, 'AC-29: BP_WAITSHAPE_ACTION="" -> exit 2 (the default is enforcement)');
    }

    # =================================================================================
    # AC-35(b) [behaviour] the guard is reached for BOTH Bash and TaskOutput, and exits 0 on an
    # unrelated tool -- the conjunction that, with AC-35(a)'s matcher-less block, constitutes
    # "reached for both tools".
    # =================================================================================
    {
        my ($bp, $proj) = mk_bp();
        my %env = env_for($bp, $proj);
        my ($rcB, $errB) = run_hook(pl_bash($W1), %env);
        is($rcB, 2, 'AC-35(b): invoked directly with a Bash payload, the guard denies');
        like($errB, qr/\Q$PFX\E/, 'AC-35(b): the Bash denial carries the mandated prefix');

        my ($bp2, $proj2) = mk_bp();
        my %env2 = env_for($bp2, $proj2);
        my $rcT;
        for my $i (1 .. 6) { ($rcT) = run_hook(pl_taskoutput('9999aaaa9999aaaa', $i), %env2) }
        is($rcT, 2, 'AC-35(b): invoked directly with a TaskOutput payload at threshold, the guard denies');

        my ($rcR) = run_hook(pl_tool('Read', { file_path => '/tmp/x' }), %env2);
        is($rcR, 0, 'AC-35(b): an unrelated tool exits 0');
    }
}

# =====================================================================================
# AC-28 / AC-31 [aggregate] asserted over EVERY hook invocation this file made.
# =====================================================================================
{
    my $n = scalar @CALLS;
    ok($n > 0, "AC-31: this file made $n hook invocations to assert over");

    my ($bad_stdout, $bad_rc, $bad_deny_lines, $bad_allow_stderr, $kill_switch, $nonascii) = (0) x 6;
    my @bad_rcs;
    for my $c (@CALLS) {
        $bad_stdout++ if length $c->{out};
        if ($c->{rc} == 0) {
            $bad_allow_stderr++ if length $c->{err};
        }
        elsif ($c->{rc} == 2) {
            $bad_deny_lines++ unless $c->{err} =~ /\A[^\n]+\n\z/;
        }
        else {
            $bad_rc++;
            push @bad_rcs, $c->{rc};
        }
        $kill_switch++ if $c->{err} =~ /BP_WAITSHAPE_ACTION/;
        $nonascii++    if $c->{err} =~ /\xE2\x80\xA6/;
    }
    is($bad_stdout, 0, "AC-31: stdout was empty on all $n invocations");
    is($bad_rc, 0, "AC-31: every exit code was 0 or 2 across all $n invocations")
        or diag("unexpected exit codes seen: " . join(',', sort { $a <=> $b } @bad_rcs));
    is($bad_deny_lines, 0, 'AC-31: every denial emitted EXACTLY ONE newline-terminated stderr line');
    is($bad_allow_stderr, 0, 'AC-31: every exit-0 invocation emitted nothing on stderr');
    is($kill_switch, 0, 'AC-28: no deny message ever mentions BP_WAITSHAPE_ACTION (the kill switch is not handed out)');
    is($nonascii, 0, 'C-4/§2.10: no stderr line carries a non-ASCII ellipsis');
}

done_testing();
