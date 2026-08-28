#!/usr/bin/env perl
# 175-hook-payload-read-bound.t -- the hook payload read is BOUNDED.
#
# WHAT THIS PINS. Every butler hook used `PAYLOAD=$(cat)`, an unbounded read.
# With stdin at EOF -- what Claude Code's own hook dispatch produces -- that is
# instant and correct. With stdin an inherited pipe that never closes, `cat`
# blocks FOREVER at essentially no CPU, and nothing upstream notices.
#
# Bug report 20260828-095201-7c1e: a perl.exe running a throwaway probe out of a
# session scratchpad was found alive NINE DAYS after its session had exited,
# having burnt 0.016s of CPU in total -- blocked on a read, holding 11 MB and 135
# handles, orphaned. That report GUESSED the cause was one of five specific
# payloads wedging guard-git-mutations.sh. Replaying its own probe disproves that
# -- all five classify correctly in seconds. The defect is the unbounded read,
# and it was in nine hooks.
#
# WHY A TEST AND NOT JUST THE FIX. The failure mode is invisible: a wedged hook
# produces no output, no error and no CPU. Nothing else in this suite would
# notice the bound being removed, and the natural "simplification" -- putting
# `$(cat)` back because it is shorter -- reintroduces it silently.
#
# EVERY CASE HERE IS BOUNDED BY alarm(). A test for a hang that can itself hang
# is worse than no test: it would wedge the sweep exactly the way the bug wedges
# a session. The FIFO cases hold a writer open deliberately, so the alarm is the
# only thing standing between this file and the nine-day process it describes.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use POSIX qw(WIFEXITED WEXITSTATUS);

my $HOOKS = "$Bin/../../hooks";
my $GUARD = "$HOOKS/guard-git-mutations.sh";
my $LIB   = "$HOOKS/lib.sh";

# guard-git-mutations.sh is the subject for the behavioural cases SPECIFICALLY
# because it is the one hook with NO bp_hook_gate -- by design, see its header.
# Every other hook exits 0 before reading unless the BP_* contract is exported,
# so on a plain host they cannot exercise the read at all.
plan skip_all => 'guard-git-mutations.sh not found' unless -f $GUARD;
plan skip_all => 'lib.sh not found'                 unless -f $LIB;

my $BASH = 'bash';
my $have_bash = do {
    my $out = `$BASH -c 'echo ok' 2>&1`;
    (defined $out && $out =~ /ok/) ? 1 : 0;
};
plan skip_all => 'no usable bash' unless $have_bash;

my $TMP = tempdir(CLEANUP => 1);

# run_guard(\%opt) -> ($exit, $output). Bounded by alarm; returns exit -1 if the
# alarm fires, which IS the regression this file exists to catch.
sub run_guard {
    my (%opt) = @_;
    my $stdin_file = $opt{stdin_file};
    my $timeout    = $opt{read_timeout};
    my $wall       = $opt{wall} || 25;

    my $env = defined $timeout ? "BP_PAYLOAD_READ_TIMEOUT=$timeout " : '';
    my $cmd = "$env$BASH '$GUARD' < '$stdin_file' 2>&1";

    my ($exit, $out) = (-1, '');
    eval {
        local $SIG{ALRM} = sub { die "alarm\n" };
        alarm $wall;
        $out  = `$cmd`;
        $exit = WIFEXITED($?) ? WEXITSTATUS($?) : -1;
        alarm 0;
        1;
    } or do { alarm 0; $exit = -1 };
    return ($exit, defined $out ? $out : '');
}

sub write_file {
    my ($path, $content) = @_;
    open my $fh, '>', $path or die "cannot write $path: $!";
    print $fh $content;
    close $fh;
    return $path;
}

# ===========================================================================
# AC1 -- the helper exists, is bounded, and is documented as global-setting.
# ===========================================================================
{
    open my $fh, '<', $LIB or die "cannot read lib.sh: $!";
    my $src = do { local $/; <$fh> };
    close $fh;

    like($src, qr/bp_read_payload\s*\(\)/,
        'AC1: lib.sh defines bp_read_payload');
    like($src, qr/read\s+-r\s+-d\s+''\s+-t\s+/,
        'AC1: the read is bounded with -t (a bash builtin -- no external binary)');

    # NOT `timeout`. On this host a bare `timeout` resolves to
    # C:\Windows\System32\timeout.exe, the *pause* command, which rejects these
    # arguments outright -- bug report 20260825-193930-fff0, where that exact
    # mistake silently killed all six resources probes before they ran.
    unlike($src, qr/^\s*(?:PAYLOAD|payload)=\$\(\s*timeout\b/m,
        'AC1: the bound is NOT an external `timeout` (it resolves to timeout.exe on this host)');

    # The subshell trap: `PAYLOAD=$(bp_read_payload)` would run the exit in a
    # subshell, so the hook would continue with an empty payload having printed
    # a denial nobody acted on.
    like($src, qr/NEVER as `PAYLOAD=\$\(bp_read_payload\)`/,
        'AC1: the subshell trap is documented at the definition');
}

# ===========================================================================
# AC2 -- no hook still uses the unbounded read, and the ONE deliberate
# exception is asserted as deliberate rather than merely absent from a list.
# ===========================================================================
{
    my @hooks = glob("$HOOKS/*.sh");
    ok(scalar(@hooks) >= 8,
        sprintf('AC2: precondition -- %d hook scripts found, not an empty glob', scalar @hooks));

    for my $h (@hooks) {
        my ($base) = $h =~ m{([^/\\]+)\z};
        open my $fh, '<', $h or do { fail("AC2: $base is readable"); next };
        my $src = do { local $/; <$fh> };
        close $fh;
        $src =~ s/^[ \t]*#[^\n]*$//mg;   # whole-line comments only

        # mark-wakeup.sh's `cmd=$(cat)` is INSIDE bp_wakeup_arm_check, whose two
        # callers both pipe from `printf '%s' "$VAR"` -- a producer that closes
        # immediately, so it cannot wedge. It is also called inside $(...), where
        # an exit would be subshell-local and therefore wrong. Left alone
        # deliberately; asserted here so "it was missed" and "it was excluded on
        # purpose" cannot be confused later.
        # lib.sh's own bp_repeat_hash reads stdin argument-less too, and is the
        # second deliberate exception: its only caller is
        # `HASH=$(bp_repeat_hash <<<"$PAYLOAD")` -- a here-string, which closes,
        # so it cannot wedge. It is also invoked inside $(...), where the
        # helper's exit would be subshell-local and therefore wrong. Asserted,
        # not skipped, so "excluded on purpose" stays distinguishable from
        # "missed".
        if ($base eq 'lib.sh') {
            like($src, qr/bp_repeat_hash\s*\(\)\s*\{.*?payload=\$\(cat/s,
                'AC2: lib.sh keeps its $(cat) inside bp_repeat_hash, whose only caller feeds it a here-string');
            next;
        }
        if ($base eq 'mark-wakeup.sh') {
            like($src, qr/bp_wakeup_arm_check\s*\(\)\s*\{[^}]*?\bcmd=\$\(cat\)/s,
                "AC2: $base keeps its \$(cat) inside bp_wakeup_arm_check, whose callers always close the pipe");
            next;
        }
        # EVERY UNBOUNDED SHAPE, not just the tidy one. The first version of
        # this assertion matched only `PAYLOAD=$(cat)` and reported all 21 hooks
        # green -- while TEN of them were reading
        # `PAYLOAD=$(cat 2>/dev/null || true)`, which suppresses stderr and
        # bounds nothing. A guard whose pattern is narrower than the defect
        # confirms whatever you already believe, so the pattern is now anchored
        # on `$(cat` itself and the tolerant suffixes are covered by it.
        # ARGUMENT-LESS cat ONLY. `$(cat "$MARKER" 2>/dev/null || true)` reads a
        # NAMED FILE and is bounded by definition -- five hooks do that
        # legitimately, and a pattern that flags them would be noise nobody
        # keeps. What can wedge is a cat with no operand, which reads stdin:
        # `$(cat)`, `$(cat 2>/dev/null)`, `$(cat 2>/dev/null || true)`. So the
        # operand position is what this matches on.
        unlike($src, qr/^\s*[A-Za-z_][A-Za-z0-9_]*=\$\(\s*cat\s*(?:[)|]|\d?>)/m,
            "AC2: $base has no argument-less \$(cat) reading stdin unbounded");

        # And it must actually be using the shared helper, so "no $(cat)"
        # cannot be satisfied by a hook that stopped reading its payload at all.
        if ($src =~ /\bPAYLOAD\b/) {
            like($src, qr/^\s*bp_read_payload\s+(?:closed|open)\s*$/m,
                "AC2: $base reads its payload through bp_read_payload, with an explicit fail direction");
        }
    }
}

# ===========================================================================
# AC3 -- ordinary payloads are unaffected. The bound must not change a single
# allow/deny decision, or it has traded a hang for a broken guard.
# ===========================================================================
{
    my @cases = (
        [ 'allow: read-only git',   '{"tool_input":{"command":"git status"}}',                 0 ],
        [ 'deny: git stash',        '{"tool_input":{"command":"git stash push -m wip"}}',      2 ],
        [ 'deny: reset --hard',     '{"tool_input":{"command":"git reset --hard"}}',           2 ],
        [ 'allow: stash list',      '{"tool_input":{"command":"git stash list"}}',             0 ],
        [ 'allow: empty command',   '{"tool_input":{"command":""}}',                           0 ],
    );
    my $i = 0;
    for my $c (@cases) {
        my ($label, $json, $want) = @$c;
        my $f = write_file("$TMP/p" . $i++ . ".json", $json);
        my ($exit) = run_guard(stdin_file => $f);
        is($exit, $want, "AC3 ($label): exit $want -- the bound changed no decision");
    }

    # A multi-line payload is the case a line-oriented read would silently
    # truncate. `read -d ''` reads to EOF; this fails if that ever becomes `-d
    # $'\n'` or a plain `read`.
    my $ml = write_file("$TMP/multiline.json",
        qq({\n "tool_name": "Bash",\n "tool_input": {\n  "command": "git reset --hard"\n }\n}\n));
    my ($mexit) = run_guard(stdin_file => $ml);
    is($mexit, 2, 'AC3 (multi-line payload): still denied -- the read spans newlines, not just the first line');
}

# ===========================================================================
# AC4 -- THE REGRESSION ITSELF. A writer that never closes must not hang the
# hook. Requires a working FIFO; skipped rather than faked where mkfifo is
# unavailable, because a fake would pin nothing.
# ===========================================================================
SKIP: {
    my $fifo = "$TMP/payload.fifo";
    my $mk = system("mkfifo '$fifo' 2>/dev/null");
    skip('mkfifo unavailable on this host -- the wedge case cannot be built', 3)
        if $mk != 0 || !-p $fifo;

    # A writer held open for far longer than the read bound, so the ONLY way the
    # hook can return is its own timeout.
    my $writer = fork();
    if (!defined $writer) { skip('fork unavailable', 3) }
    if ($writer == 0) {
        exec($BASH, '-c', "sleep 60 > '$fifo'");
        exit 127;
    }

    my $start = time;
    my ($exit, $out) = run_guard(stdin_file => $fifo, read_timeout => 2, wall => 25);
    my $elapsed = time - $start;

    kill 'TERM', $writer;
    waitpid($writer, 0);

    isnt($exit, -1,
        'AC4: the hook RETURNS when stdin never closes -- it does not block forever (this is the nine-day bug)');
    is($exit, 2,
        'AC4: and it fails CLOSED -- an unread payload cannot be checked, so it must not be allowed');
    cmp_ok($elapsed, '<', 20,
        sprintf('AC4: it returns promptly (%ds elapsed against a 2s bound), rather than at some outer wall', $elapsed));
    like($out, qr/did not arrive within/,
        'AC4: and it SAYS why -- a silent denial is as hard to diagnose as the hang was');
}

done_testing();
