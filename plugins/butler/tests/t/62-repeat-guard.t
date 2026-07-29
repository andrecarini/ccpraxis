#!/usr/bin/env perl
# b10-repeat-command-guard oracle. Derived from
# .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/specs/b10-repeat-command-guard-spec.md
# §4 (AC-1..AC-22). Written BLIND to any implementation: repeat-guard.sh does not exist yet and
# lib.sh has none of the bp_repeat_* functions, so every assertion below must fail on MISSING
# BEHAVIOUR (absent file / undefined function / wrong exit code), never on a perl bug of this file.
#
# COORDINATOR RULING (overrides spec RULING 3 / AC-20 verbatim text): the new 4th PreToolUse block
# must OMIT the "matcher" key entirely (match-all-by-omission, as butler's own Stop block already
# does), NOT carry a literal "matcher": "*". AC-20 below asserts the override, not the spec's literal
# words.
#
# [pure] groups (bp_repeat_verdict, bp_repeat_runlen, bp_repeat_config_int, bp_repeat_action_of,
# bp_repeat_session_token, bp_repeat_state_path) need no jq and run UNCONDITIONALLY so this file
# retains value on the jq-less Windows host. [hook] groups and the hash-normalisation [pure] group
# (bp_repeat_hash needs jq) are wrapped in one SKIP: block gated on `command -v jq`, mirroring
# t/09-gate.t:22,223-224. AC-20/AC-21 are file/regression checks that need no jq and run
# unconditionally too.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP;
use Time::HiRes qw(gettimeofday tv_interval);
use POSIX qw(mkfifo);

(my $HOOKS = "$Bin/../../hooks") =~ s{\\}{/}g;
my $LIB       = "$HOOKS/lib.sh";
my $HOOK      = "$HOOKS/repeat-guard.sh";
my $HOOKSJSON = "$HOOKS/hooks.json";

my $have_jq = do { my $o = `bash -c 'command -v jq' 2>/dev/null`; $o =~ /\S/ ? 1 : 0 };

# NO hardcoded plan, deliberately (b26). A hand-counted `plan tests => 259` is precisely what made
# this file brittle: registering ONE new PreToolUse hook in hooks.json makes the per-entry loop
# below (:~344) emit one extra assertion and the plan mismatches, turning a done package's oracle
# red for a change it has no opinion about. t/64-ledger-guard.t already uses done_testing(); follow
# it. The jq-gated SKIP block keeps its own `skip ..., 176` count -- that is a skip count, not a
# plan, and it is not this package's business.

my $J    = JSON::PP->new->canonical;
my $ROOT = tempdir(CLEANUP => 1);
my $pn   = 0;
my $bpn  = 0;

sub fwd { (my $p = shift) =~ s{\\}{/}g; $p }

# b26: block 0's command list is asserted "contains, in relative order" rather than by exact
# equality. AC-20's real intent (b10-repeat-command-guard.md:52-54) is that b10's own registration
# is present, correctly named and correctly ordered -- NOT that hooks.json may never gain a hook.
# Subsequence semantics over EXACT full-command-string matches: every needle must appear, each at a
# position strictly after the previous needle's match. Appended/interleaved foreign commands are
# permitted; a missing, renamed or relatively-reordered needle is NOT. Empty haystack -> 0.
sub cmds_contain_in_order {
    my ($hay, $needles) = @_;
    my $i = 0;
    for my $n (@$needles) {
        $i++ while $i < @$hay && $hay->[$i] ne $n;
        return 0 if $i >= @$hay;
        $i++;
    }
    return 1;
}

sub realpath_m {
    my ($p) = @_; local $ENV{P} = $p;
    open(my $f, '-|', 'bash', '-c', 'realpath -m "$P"') or die "bash: $!";
    my $o = do { local $/; <$f> }; close $f; $o =~ s/\s+\z//; return $o;
}

# A hook test must control the hook's environment COMPLETELY -- see t/09-gate.t:61-69. This suite is
# run by coordinators and harvest judges that export BP_* into the ambient env; AC-12 ("inert outside
# a butler session") is exactly the assertion an ambient BP_* would silently turn into a false pass.
# Strip ALL ambient BP_* before every hook/source-lib.sh invocation.
my %CLEAN_ENV = map { ($_ => $ENV{$_}) } grep { !/^BP_/ } keys %ENV;

# --- pure-function invocation helper (t/09-gate.t:34-42 idiom, generalised to N positional args) ---
sub call_fn {
    my ($fn, $sfile, @args) = @_;
    local %ENV = (%CLEAN_ENV, LIBSH => $LIB, SFILE => (defined $sfile ? fwd($sfile) : '/dev/null'));
    open(my $f, '-|', 'bash', '-c',
         qq{source "\$LIBSH"; $fn "\$@" < "\$SFILE"}, 'h', @args) or die "bash: $!";
    my $o = do { local $/; <$f> }; close $f;
    $o =~ s/\s+\z//;
    return $o;
}

sub verdict4 {
    my ($runlen, $fired, $thresh, $action) = @_;
    return call_fn('bp_repeat_verdict', undef, $runlen, $fired, $thresh, $action);
}

sub runlen_call {
    my ($hash, $now, $win, @lines) = @_;
    my $sf = "$ROOT/runlen-stdin." . (++$pn) . ".txt";
    open my $w, '>', $sf or die "write $sf: $!";
    print $w join("\t", @$_), "\n" for @lines;
    close $w;
    return call_fn('bp_repeat_runlen', $sf, $hash, $now, $win);
}

sub config_int_call { my ($raw, $def, $min) = @_; return call_fn('bp_repeat_config_int', undef, $raw, $def, $min); }
sub action_of_call  { my ($raw) = @_;              return call_fn('bp_repeat_action_of', undef, $raw); }
sub session_token_call { my ($raw) = @_;           return call_fn('bp_repeat_session_token', undef, $raw); }

sub state_path_call {
    my ($token, $dir, $pkg) = @_;
    local %ENV = (%CLEAN_ENV, LIBSH => $LIB, BP_DIR => $dir, (defined $pkg ? (BP_PACKAGE => $pkg) : ()));
    open(my $f, '-|', 'bash', '-c', 'source "$LIBSH"; bp_repeat_state_path "$1"', 'h', $token) or die "bash: $!";
    my $o = do { local $/; <$f> }; close $f; $o =~ s/\s+\z//; return $o;
}

# regression helpers (AC-21), copied from t/09-gate.t:34-53
sub gate_verdict_call {
    my ($tool, $pc, $sig) = @_;
    local %ENV = (%CLEAN_ENV, LIBSH => $LIB);
    open(my $f, '-|', 'bash', '-c',
         'source "$LIBSH"; bp_gate_verdict "$1" "$2" "$3"', 'h', $tool, $pc, $sig) or die "bash: $!";
    my $o = do { local $/; <$f> }; close $f; $o =~ s/\s+\z//; return $o;
}
sub stop_signal_call {
    my ($dir, $pkg) = @_;
    local %ENV = (%CLEAN_ENV, LIBSH => $LIB, BP_DIR => $dir, BP_PACKAGE => $pkg);
    open(my $f, '-|', 'bash', '-c', 'source "$LIBSH"; bp_active_stop_signal') or die "bash: $!";
    my $o = do { local $/; <$f> }; close $f; $o =~ s/\s+\z//; return $o;
}

# --- BP_DIR builder (own runs/ subdir) ---
sub mk_bp {
    my $win = "$ROOT/bp" . (++$bpn);
    mkdir $win  or die "mkdir $win: $!";
    mkdir "$win/runs" or die "mkdir $win/runs: $!";
    return realpath_m(fwd($win));
}

sub default_env {
    my ($dir, %extra) = @_;
    return (BP_DIR => $dir, BP_LEDGER => "$dir/ledger.md", BP_PROJECT_ROOT => $dir, BP_PACKAGE => 'p', %extra);
}

sub state_file_path {
    my ($dir, $pkg, $token) = @_;
    return "$dir/runs/$pkg.repeat-$token.log";
}

sub write_state_lines {
    my ($file, @rows) = @_;   # rows: [ts, hash, fired]
    open my $w, '>', $file or die "write $file: $!";
    print $w join("\t", @$_), "\n" for @rows;
    close $w;
}
sub read_lines {
    my ($file) = @_;
    open my $r, '<', $file or return ();
    my @l = <$r>; close $r; chomp @l; return @l;
}
sub valid_line { return $_[0] =~ /^[0-9]+\t[^\t]+\t[01]$/ }

sub mkpayload { my (%h) = @_; return $J->encode(\%h); }

# hook runner (t/09-gate.t:72-80 idiom: payload to a temp file, "$HOOKPATH" < "$PFILE" 2>&1)
sub run_hook {
    my ($payload, %env) = @_;
    my $pf = "$ROOT/hookpayload." . (++$pn) . ".json";
    open my $w, '>', $pf or die "write $pf: $!";
    print $w $payload;
    close $w;
    local %ENV = (%CLEAN_ENV, %env, HOOKPATH => fwd($HOOK), PFILE => fwd($pf));
    open(my $f, '-|', 'bash', '-c', '"$HOOKPATH" < "$PFILE" 2>&1') or die "bash: $!";
    my $o = do { local $/; <$f> }; close $f;
    return ($? >> 8, $o);
}

# hash caller (needs jq; also supports a PATH override for the missing-jq fail-open test AC-13)
sub hash_call {
    my ($payload, $path_override) = @_;
    my $pf = "$ROOT/hashpayload." . (++$pn) . ".json";
    open my $w, '>', $pf or die "write $pf: $!";
    print $w $payload;
    close $w;
    my %e = (%CLEAN_ENV, LIBSH => $LIB, SFILE => fwd($pf));
    $e{PATH} = $path_override if defined $path_override;
    local %ENV = %e;
    open(my $f, '-|', 'bash', '-c', 'source "$LIBSH"; bp_repeat_hash < "$SFILE"') or die "bash: $!";
    my $o = do { local $/; <$f> }; close $f; $o =~ s/\s+\z//; return $o;
}

# hash caller with a wall-clock measurement and a hard `timeout` safety bound (F1: HIGH-1
# super-linear scrub regression). Returns (hash, elapsed_seconds). The `timeout` wrapper is a
# safety net only -- it must not be what makes the timing assertion fail; the assertion is on
# $elapsed, measured from this side.
sub hash_call_bounded {
    my ($payload, $timeout_secs) = @_;
    my $pf = "$ROOT/hashpayload." . (++$pn) . ".json";
    open my $w, '>', $pf or die "write $pf: $!";
    print $w $payload;
    close $w;
    local %ENV = (%CLEAN_ENV, LIBSH => $LIB, SFILE => fwd($pf));
    my $t0 = [gettimeofday()];
    open(my $f, '-|', 'bash', '-c',
         qq{timeout $timeout_secs bash -c 'source "\$LIBSH"; bp_repeat_hash < "\$SFILE"'})
        or die "bash: $!";
    my $o = do { local $/; <$f> }; close $f;
    my $elapsed = tv_interval($t0);
    $o =~ s/\s+\z//;
    return ($o, $elapsed);
}

# hook runner with a hard `timeout` bound (F4: MEDIUM-3/LOW-4 read-before-typecheck hang). Exit
# code 124 means the bound was hit (the hook hung); this must never be able to hang the suite.
sub run_hook_bounded {
    my ($payload, $timeout_secs, %env) = @_;
    my $pf = "$ROOT/hookpayload." . (++$pn) . ".json";
    open my $w, '>', $pf or die "write $pf: $!";
    print $w $payload;
    close $w;
    local %ENV = (%CLEAN_ENV, %env, HOOKPATH => fwd($HOOK), PFILE => fwd($pf));
    open(my $f, '-|', 'bash', '-c', qq{timeout $timeout_secs "\$HOOKPATH" < "\$PFILE" 2>&1})
        or die "bash: $!";
    my $o = do { local $/; <$f> }; close $f;
    return ($? >> 8, $o);
}

# =====================================================================================
# AC-1 [pure] bp_repeat_verdict matrix (§2.3 table, incl. the AC-1-listed explicit rows)
# =====================================================================================
is(verdict4(10, 0, 4, 'off'),      'pass', 'AC-1: off & runlen>=threshold & fired=0 -> pass');
is(verdict4(10, 1, 4, 'off'),      'pass', 'AC-1: off & runlen>=threshold & fired=1 -> pass');
is(verdict4(2,  0, 4, 'nudge'),    'pass', 'AC-1: runlen<threshold (nudge) -> pass');
is(verdict4(2,  0, 4, 'deny'),     'pass', 'AC-1: runlen<threshold (deny) -> pass');
is(verdict4(5,  0, 4, 'deny'),     'fire', 'AC-1: deny & runlen>=threshold & fired=0 -> fire');
is(verdict4(4,  1, 4, 'deny'),     'fire', 'AC-1: deny & runlen==threshold & fired=1 -> fire (deny is sticky, ignores fired)');
is(verdict4(4,  1, 4, 'nudge'),    'pass', 'AC-1: nudge & runlen==threshold & fired=1 -> pass (already fired)');
is(verdict4(4,  0, 4, 'nudge'),    'fire', 'AC-1: nudge & runlen==threshold & fired=0 -> fire');
is(verdict4('abc', 0, 4, 'nudge'), 'pass', 'AC-1: unparseable RUNLEN -> pass');
is(verdict4(10, 0, 4, 'bogus'),    'pass', 'AC-1: unrecognised ACTION argument -> pass');
is(verdict4(10, '', 4, 'nudge'),   'pass', 'AC-1: missing/empty FIRED -> pass');
is(verdict4(10, 0, '', 'nudge'),   'pass', 'AC-1: missing/empty THRESHOLD -> pass');

# =====================================================================================
# AC-2 [pure] bp_repeat_runlen counting and reset
# =====================================================================================
is(runlen_call('A', 103, 300, [100,'A',0], [101,'A',0], [102,'A',0]), '4 0',
   'AC-2: three trailing identical entries -> runlen 4, fired 0');
is(runlen_call('A', 103, 300, [100,'A',0], [101,'B',0], [102,'A',0]), '2 0',
   'AC-2: an intervening different hash resets the trailing run (runlen 2, not 3)');
is(runlen_call('A', 102, 300, [100,'A',0], [101,'A',1]), '3 1',
   'AC-2: a fired=1 entry INSIDE the trailing run propagates FIRED=1');
is(runlen_call('A', 102, 300, [100,'A',1], [101,'B',0]), '1 0',
   'AC-2: a fired=1 entry OUTSIDE the trailing run (behind a break) does not propagate');
is(runlen_call('A', 100, 300), '1 0',
   'AC-2: empty stdin -> "1 0"');
is(runlen_call('A', 102, 300, [100,'A',0], ['garbage-not-a-valid-line'], [101,'A',0]), '3 0',
   'AC-2: an invalid line is skipped without breaking the run');

# =====================================================================================
# AC-3 [pure] staleness reset
# =====================================================================================
is(runlen_call('A', 1000, 300, [1000-301,'A',0]), '1 0',
   'AC-3: WINDOW_SECONDS=300, trailing entry 301s older -> not part of the run (runlen 1)');
is(runlen_call('A', 1000, 300, [1000-299,'A',0]), '2 0',
   'AC-3: WINDOW_SECONDS=300, trailing entry 299s older -> part of the run (runlen 2)');
is(runlen_call('A', 20000, 0, [20000-10000,'A',0]), '2 0',
   'AC-3: WINDOW_SECONDS=0 disables the staleness stop (10000s-old entry still counted)');

# =====================================================================================
# AC-18 [pure] bp_repeat_config_int / bp_repeat_action_of edge cases
# =====================================================================================
is(config_int_call('',    99, 2), 99,  'AC-18: config_int("") -> default');
is(config_int_call('abc', 99, 2), 99,  'AC-18: config_int("abc") -> default');
is(config_int_call('2.5', 99, 2), 99,  'AC-18: config_int("2.5") -> default');
is(config_int_call('-1',  99, 2), 99,  'AC-18: config_int("-1") -> default');
is(config_int_call('0',   99, 2), 99,  'AC-18: config_int("0") below MIN=2 -> default');
is(config_int_call('1',   99, 2), 99,  'AC-18: config_int("1") below MIN=2 -> default');
is(config_int_call(' 4 ', 99, 2), 99,  'AC-18: config_int(" 4 ") whitespace-padded -> default (not a bare decimal integer)');
is(config_int_call('2',   99, 2), 2,   'AC-18: config_int("2") at MIN -> value');
is(config_int_call('7',   99, 2), 7,   'AC-18: config_int("7") -> value');
is(config_int_call('999', 99, 2), 999, 'AC-18: config_int("999") -> value');

is(action_of_call(''),      'nudge', 'AC-18: action_of("") -> nudge (default)');
is(action_of_call('nudge'), 'nudge', 'AC-18: action_of("nudge") -> nudge');
is(action_of_call('deny'),  'deny',  'AC-18: action_of("deny") -> deny');
is(action_of_call('off'),   'off',   'AC-18: action_of("off") -> off');
is(action_of_call('Nudge'), 'off',   'AC-18: action_of("Nudge") (case mismatch) -> off (unrecognised => disabled)');
is(action_of_call('warn'),  'off',   'AC-18: action_of("warn") -> off (unrecognised => disabled)');
is(action_of_call('yes'),   'off',   'AC-18: action_of("yes") -> off (unrecognised => disabled)');
is(action_of_call('1'),     'off',   'AC-18: action_of("1") -> off (unrecognised => disabled)');

# =====================================================================================
# AC-19 [pure] bp_repeat_session_token / bp_repeat_state_path
# =====================================================================================
is(session_token_call('abc-123'), 'abc-123',        'AC-19: session_token("abc-123") -> unchanged (already valid chars)');
is(session_token_call('a/b c:d'), 'a_b_c_d',        'AC-19: session_token("a/b c:d") -> disallowed chars replaced with _');
is(session_token_call('x' x 40),  ('x' x 16),       'AC-19: session_token of a 40-char id -> truncated to first 16 chars');
is(session_token_call(''),        'nosid',          'AC-19: session_token("") -> nosid');
is(state_path_call('tok123', '/tmp/bpdir', 'mypkg'), '/tmp/bpdir/runs/mypkg.repeat-tok123.log',
   'AC-19: bp_repeat_state_path builds the documented path');
is(state_path_call('tok123', '/tmp/bpdir', undef), '/tmp/bpdir/runs/pkg.repeat-tok123.log',
   'AC-19: bp_repeat_state_path falls back to literal "pkg" when BP_PACKAGE is unset');

# =====================================================================================
# AC-21 [pure] lib.sh regression spot-checks (t/09-gate.t remains the full oracle)
# =====================================================================================
is(gate_verdict_call('Task', '-', 0),         'allow', 'AC-21: regression - bp_gate_verdict(Task,-,0) still "allow"');
is(gate_verdict_call('Edit', 'worksite', 1),  'deny',  'AC-21: regression - bp_gate_verdict(Edit,worksite,1) still "deny"');
{
    my $win = "$ROOT/ac21sig"; mkdir $win; mkdir "$win/runs";
    my $dir = realpath_m(fwd($win));
    is(stop_signal_call($dir, 'p'), '', 'AC-21: regression - bp_active_stop_signal with no marker -> empty');
    open my $h, '>', "$win/runs/.shutdown" or die; close $h;
    is(stop_signal_call($dir, 'p'), 'shutdown', 'AC-21: regression - bp_active_stop_signal detects .shutdown');
}
{
    local %ENV = (%CLEAN_ENV, LIBSH => $LIB, BP_LEDGER => 'x', BP_DIR => 'y', BP_PROJECT_ROOT => 'z');
    open(my $f, '-|', 'bash', '-c', 'source "$LIBSH"; bp_hook_gate; echo REACHED') or die "bash: $!";
    my $o = do { local $/; <$f> }; close $f; $o =~ s/\s+\z//;
    is($o, 'REACHED', 'AC-21: regression - bp_hook_gate does not exit when all three vars are set');
}
{
    local %ENV = (%CLEAN_ENV, LIBSH => $LIB, BP_LEDGER => '', BP_DIR => 'y', BP_PROJECT_ROOT => 'z');
    open(my $f, '-|', 'bash', '-c', 'source "$LIBSH"; bp_hook_gate; echo REACHED') or die "bash: $!";
    my $o = do { local $/; <$f> }; close $f; $o =~ s/\s+\z//;
    is($o, '', 'AC-21: regression - bp_hook_gate exits before REACHED when BP_LEDGER is empty');
}

# =====================================================================================
# AC-20 [file] hooks.json shape (structural, not string match). No jq needed.
# COORDINATOR OVERRIDE applied: block 3 must have NO "matcher" key (not "*").
# =====================================================================================
{
    local $/;
    open my $hf, '<', $HOOKSJSON or die "cannot open $HOOKSJSON: $!";
    my $raw = <$hf>;
    close $hf;
    my $H = eval { $J->decode($raw) };
    ok(defined $H, 'AC-20: hooks.json parses as valid JSON') or diag("parse error: $@");

    my $pre = ($H && $H->{hooks}{PreToolUse}) // [];
    is(scalar(@$pre), 4, 'AC-20: PreToolUse has exactly 4 blocks');

    my $cmd_of = sub { my $f = shift; return qq(bash "\${CLAUDE_PLUGIN_ROOT}/hooks/$f"); };

    my $b0 = $pre->[0] // {};
    is($b0->{matcher}, 'Edit|Write|MultiEdit|NotebookEdit', 'AC-20: block 0 matcher unchanged');
    my @b0_cmds = map { $_->{command} } @{ $b0->{hooks} // [] };
    ok(cmds_contain_in_order(\@b0_cmds,
                             [ $cmd_of->('gate-shutdown.sh'), $cmd_of->('guard-writes.sh') ]),
       'AC-20: block 0 still contains b10-era [gate-shutdown.sh, guard-writes.sh] in relative order (later packages may append or interleave)')
        or diag("block 0 commands: " . join(' | ', @b0_cmds));

    my $b1 = $pre->[1] // {};
    is($b1->{matcher}, 'Bash', 'AC-20: block 1 matcher unchanged');
    is_deeply([ map { $_->{command} } @{ $b1->{hooks} // [] } ],
              [ $cmd_of->('guard-bash.sh') ],
              'AC-20: block 1 command list unchanged');

    my $b2 = $pre->[2] // {};
    is($b2->{matcher}, 'Task', 'AC-20: block 2 matcher unchanged');
    is_deeply([ map { $_->{command} } @{ $b2->{hooks} // [] } ],
              [ $cmd_of->('gate-shutdown.sh'), $cmd_of->('track-dispatch.sh') ],
              'AC-20: block 2 command list unchanged, in order');

    my $n = 0;
    for my $blk ($b0, $b1, $b2) {
        for my $h (@{ $blk->{hooks} // [] }) {
            $n++;
            ok(defined($h->{type}) && $h->{type} eq 'command'
               && defined($h->{timeout}) && $h->{timeout} == 15
               && defined($h->{command}) && $h->{command} =~ m{^bash "\$\{CLAUDE_PLUGIN_ROOT\}/hooks/[a-z-]+\.sh"$},
               "AC-20: existing PreToolUse hook entry #$n has type=command, timeout=15, correct command shape");
        }
    }

    ok(defined $pre->[3], 'AC-20: PreToolUse block 3 (new repeat-guard registration) exists');
    my $b3 = $pre->[3] // {};
    ok(!exists $b3->{matcher}, 'AC-20: block 3 has NO "matcher" key (coordinator override on RULING 3 - match-all-by-omission, not "*")');
    is(scalar(@{ $b3->{hooks} // [] }), 1, 'AC-20: block 3 has exactly one hook entry');
    my $h3 = ($b3->{hooks} // [])->[0] // {};
    is($h3->{command}, $cmd_of->('repeat-guard.sh'), 'AC-20: block 3 hook command is repeat-guard.sh');
    is($h3->{type}, 'command', 'AC-20: block 3 hook type=command');
    is($h3->{timeout}, 15, 'AC-20: block 3 hook timeout=15');

    my $post = ($H && $H->{hooks}{PostToolUse}) // [];
    is(scalar(@$post), 1, 'AC-20: PostToolUse has exactly one block');
    is($post->[0]{matcher}, 'Task', 'AC-20: PostToolUse block matcher is "Task"');
    is_deeply([ map { $_->{command} } @{ $post->[0]{hooks} // [] } ],
              [ $cmd_of->('log-dispatch.sh') ],
              'AC-20: PostToolUse hook list is [log-dispatch.sh]');

    my $stop = ($H && $H->{hooks}{Stop}) // [];
    is(scalar(@$stop), 1, 'AC-20: Stop has exactly one block');
    ok(!exists $stop->[0]{matcher}, 'AC-20: Stop block has NO "matcher" key');
    is_deeply([ map { $_->{command} } @{ $stop->[0]{hooks} // [] } ],
              [ $cmd_of->('gate-stop.sh') ],
              'AC-20: Stop hook list is [gate-stop.sh]');

    for my $f (qw(gate-shutdown.sh guard-writes.sh guard-bash.sh track-dispatch.sh log-dispatch.sh gate-stop.sh repeat-guard.sh)) {
        my $path = "$HOOKS/$f";
        ok(-e $path && -s $path, "AC-20: referenced hook file $f exists and is non-empty");
    }
}

# =====================================================================================
# jq-dependent groups: bp_repeat_hash normalisation ([pure], AC-4/AC-5) and every [hook]
# criterion (AC-6..AC-17, AC-19 hook part, AC-22). Mirrors t/09-gate.t:22,223-224.
# =====================================================================================
SKIP: {
    skip "jq not available on this host (repeat-guard is fail-open without it; these tests need jq present to build fixtures/assert the primary behaviour)", 176
        unless $have_jq;

    # ---- PATH with no jq reachable, everything else intact (for AC-13) ----------------
    my $NOJQ_DIR = "$ROOT/nojq-bin";
    mkdir $NOJQ_DIR;
    {
        my %seen;
        for my $d (split(/:/, ($CLEAN_ENV{PATH} // '')), '/usr/bin', '/bin', '/usr/local/bin') {
            next unless length $d && -d $d;
            opendir(my $dh, $d) or next;
            for my $f (readdir $dh) {
                next if $f eq 'jq' || $f =~ /^\./;
                next if $seen{$f}++;
                my $src = "$d/$f";
                next unless -f $src && -x $src;
                symlink($src, "$NOJQ_DIR/$f");
            }
            closedir $dh;
        }
    }
    my $NOJQ_PATH = fwd($NOJQ_DIR);

    # =================================================================================
    # AC-4 [pure] bp_repeat_hash - normalisation, positive direction (SAME hash)
    # =================================================================================
    my $p1 = mkpayload(tool_name => 'Bash', cwd => '/x', tool_input => { command => 'echo hi', flag => 'y' });
    my $p2 = mkpayload(cwd => '/x', tool_input => { flag => 'y', command => 'echo hi' }, tool_name => 'Bash');
    my $sanity = hash_call($p1);
    ok(length($sanity) > 0, 'AC-4: bp_repeat_hash produces a non-empty token for a well-formed payload (sanity gate)');

    {
        my ($ha, $hb) = (hash_call($p1), hash_call($p2));
        ok(length($ha) && length($hb) && $ha eq $hb,
           'AC-4: JSON key order (top-level and inside tool_input) does not change the hash');
    }
    my $p3 = mkpayload(tool_name => 'Bash', tool_input => { command => "echo  hi\tthere" });
    my $p4 = mkpayload(tool_name => 'Bash', tool_input => { command => "echo hi there" });
    {
        my ($ha, $hb) = (hash_call($p3), hash_call($p4));
        ok(length($ha) && length($hb) && $ha eq $hb,
           'AC-4: runs of interior whitespace in a string value collapse to a single space');
    }
    my $p5 = mkpayload(tool_name => 'Bash', tool_input => { command => "  echo hi there  " });
    {
        my ($ha, $hb) = (hash_call($p5), hash_call($p4));
        ok(length($ha) && length($hb) && $ha eq $hb,
           'AC-4: leading/trailing whitespace of a string value is trimmed');
    }
    {
        my ($h1a, $h1b) = (hash_call($p1), hash_call($p1));
        ok(length($h1a) && $h1a eq $h1b, 'AC-4: hashing the same payload twice is deterministic');
    }

    # =================================================================================
    # AC-5 [pure] bp_repeat_hash - normalisation, negative direction (DIFFERENT hash)
    # =================================================================================
    my $p6 = mkpayload(tool_name => 'Bash', tool_input => { command => 'echo bye' });
    {
        my ($ha, $hb) = (hash_call($p4), hash_call($p6));
        ok(length($ha) && length($hb) && $ha ne $hb, 'AC-5: different tool_input.command text -> different hash');
    }
    my $p7 = mkpayload(tool_name => 'Read', tool_input => { command => 'echo hi there' });
    {
        my ($ha, $hb) = (hash_call($p4), hash_call($p7));
        ok(length($ha) && length($hb) && $ha ne $hb, 'AC-5: same tool_input, different tool_name -> different hash');
    }
    my $p8 = mkpayload(tool_name => 'Edit', tool_input => { file_path => 'a', nested => { x => 1 } });
    my $p9 = mkpayload(tool_name => 'Edit', tool_input => { file_path => 'a', nested => { x => 2 } });
    {
        my ($ha, $hb) = (hash_call($p8), hash_call($p9));
        ok(length($ha) && length($hb) && $ha ne $hb, 'AC-5: tool_input differing only in a nested value -> different hash');
    }
    my $p10 = mkpayload(tool_name => 'Bash', cwd => '/aaa', session_id => 'sess1', tool_input => { command => 'echo z' });
    my $p11 = mkpayload(tool_name => 'Bash', cwd => '/bbb', session_id => 'sess2', tool_input => { command => 'echo z' });
    {
        my ($ha, $hb) = (hash_call($p10), hash_call($p11));
        ok(length($ha) && length($hb) && $ha eq $hb,
           'AC-5: identical tool_name/tool_input with different top-level cwd/session_id -> SAME hash');
    }

    # =================================================================================
    # AC-6 [hook] the benign re-run does not fire (B10) -- exact RULING-2 sequence
    # =================================================================================
    {
        my $cmd = 'perl plugins/butler/tests/t/62-repeat-guard.t';
        my @seq = (
            mkpayload(tool_name => 'Bash', tool_input => { command => $cmd }),
            mkpayload(tool_name => 'Read', tool_input => { file_path => 'plugins/butler/hooks/repeat-guard.sh' }),
            mkpayload(tool_name => 'Edit', tool_input => { file_path => 'plugins/butler/hooks/repeat-guard.sh', old_string => 'a', new_string => 'b' }),
            mkpayload(tool_name => 'Bash', tool_input => { command => $cmd }),
            mkpayload(tool_name => 'Edit', tool_input => { file_path => 'plugins/butler/hooks/repeat-guard.sh', old_string => 'c', new_string => 'd' }),
            mkpayload(tool_name => 'Bash', tool_input => { command => $cmd }),
        );
        my $dir = mk_bp(); my %env = default_env($dir);
        my @outs;
        for my $i (0 .. $#seq) {
            my ($rc, $out) = run_hook($seq[$i], %env);
            is($rc, 0, 'AC-6: benign re-run sequence step ' . ($i + 1) . ' -> exit 0');
            push @outs, $out;
        }
        unlike(join("\n", @outs), qr/REPEAT-GUARD/, 'AC-6: benign re-run sequence never emits a REPEAT-GUARD advisory');
    }

    # =================================================================================
    # AC-7 [hook] a tight loop fires at exactly the threshold (B3, B4)
    # AC-8 [hook] fire exactly once (B5)          -- continues in the same window
    # AC-9 [hook] refire after a reset (B6)       -- continues in the same window
    # =================================================================================
    {
        my $dir = mk_bp(); my %env = default_env($dir);
        my $payload = mkpayload(tool_name => 'Bash', tool_input => { command => 'ac7-loop-command' });

        my ($rc1) = run_hook($payload, %env); is($rc1, 0, 'AC-7: call 1 of 4 identical -> exit 0');
        my ($rc2) = run_hook($payload, %env); is($rc2, 0, 'AC-7: call 2 of 4 identical -> exit 0');
        my ($rc3) = run_hook($payload, %env); is($rc3, 0, 'AC-7: call 3 of 4 identical -> exit 0');
        my ($rc4, $out4) = run_hook($payload, %env);
        is($rc4, 2, 'AC-7: call 4 (threshold reached) -> exit 2');
        like($out4, qr/REPEAT-GUARD/, 'AC-7: call 4 stderr contains REPEAT-GUARD');
        like($out4, qr/Bash/,         'AC-7: call 4 stderr names the tool (Bash)');
        like($out4, qr/\b4\b/,        'AC-7: call 4 stderr states the run length (4)');

        my ($rc5) = run_hook($payload, %env); is($rc5, 0, 'AC-8: call 5 (post-fire repeat) -> exit 0 (fires once)');
        my ($rc6) = run_hook($payload, %env); is($rc6, 0, 'AC-8: call 6 (post-fire repeat) -> exit 0 (fires once)');

        my $different = mkpayload(tool_name => 'Bash', tool_input => { command => 'ac9-distinct-command' });
        my ($rcd) = run_hook($different, %env);
        is($rcd, 0, 'AC-9: an intervening distinct call -> exit 0 (resets the trailing run)');

        my ($rc7)  = run_hook($payload, %env); is($rc7, 0,  'AC-9: after reset, call 1 of the new run -> exit 0');
        my ($rc8)  = run_hook($payload, %env); is($rc8, 0,  'AC-9: after reset, call 2 of the new run -> exit 0');
        my ($rc9)  = run_hook($payload, %env); is($rc9, 0,  'AC-9: after reset, call 3 of the new run -> exit 0');
        my ($rc10, $out10) = run_hook($payload, %env);
        is($rc10, 2, 'AC-9: after reset, call 4 of the new run -> exit 2 (refires)');
        like($out10, qr/REPEAT-GUARD/, 'AC-9: refire stderr contains REPEAT-GUARD');
    }

    # =================================================================================
    # AC-10 [hook] same tool, different args never accumulate (B8)
    # =================================================================================
    {
        my $dir = mk_bp(); my %env = default_env($dir);
        for my $i (1 .. 10) {
            my $payload = mkpayload(tool_name => 'Bash', tool_input => { command => "ac10-distinct-command-$i" });
            my ($rc) = run_hook($payload, %env);
            is($rc, 0, "AC-10: distinct-args call $i of 10 -> exit 0");
        }
    }

    # =================================================================================
    # AC-11 [hook]+[file] bounded window (B11) -- BP_REPEAT_WINDOW=8, THRESHOLD=4
    # =================================================================================
    {
        my $dir = mk_bp();
        my %env = default_env($dir, BP_REPEAT_WINDOW => 8, BP_REPEAT_THRESHOLD => 4);
        my $file = state_file_path($dir, 'p', 'nosid');
        my $any_bad_rc = 0;
        my @checkpoints;
        for my $i (1 .. 40) {
            my $payload = mkpayload(tool_name => 'Bash', tool_input => { command => "ac11-cmd-$i" });
            my ($rc) = run_hook($payload, %env);
            $any_bad_rc = 1 if $rc != 0;
            my @cur = read_lines($file);
            push @checkpoints, [$i, scalar(@cur)] if $i == 10 || $i == 20 || $i == 30;
        }
        ok(!$any_bad_rc, 'AC-11: 40 distinct calls never fire (bound test isolated from repeat detection)');
        for my $cp (@checkpoints) {
            my ($i, $n) = @$cp;
            ok($n > 0 && $n <= 8, "AC-11: after call $i the window file has between 1 and 8 lines (got $n)");
        }
        my @final11 = read_lines($file);
        is(scalar(@final11), 8,
           'AC-11: after 40 distinct calls the window file has exactly max(WINDOW=8,THRESHOLD=4)=8 lines');
    }

    # =================================================================================
    # AC-12 [hook] inert outside a butler session (B1) -- each of the 3 gate vars, individually
    # =================================================================================
    {
        for my $missing (qw(BP_LEDGER BP_DIR BP_PROJECT_ROOT)) {
            my $dir = mk_bp();
            my %env = default_env($dir);
            delete $env{$missing};
            my $payload = mkpayload(tool_name => 'Bash', tool_input => { command => 'ac12-would-fire' });
            my $any_bad = 0;
            for (1 .. 4) {
                my ($rc) = run_hook($payload, %env);
                $any_bad = 1 if $rc != 0;
            }
            ok(!$any_bad, "AC-12: with $missing unset, a would-fire 4-call sequence never exits nonzero (inert outside session)");
            ok(!-e state_file_path($dir, 'p', 'nosid'), "AC-12: with $missing unset, no state file is created under runs/");
        }
    }

    # =================================================================================
    # AC-13 [hook] fail-open: missing jq
    # =================================================================================
    {
        my $dir = mk_bp();
        my %env = default_env($dir, PATH => $NOJQ_PATH);
        my $payload = mkpayload(tool_name => 'Bash', tool_input => { command => 'ac13-would-fire' });
        my @outs;
        for my $i (1 .. 4) {
            my ($rc, $out) = run_hook($payload, %env);
            is($rc, 0, "AC-13: missing jq (PATH stripped of jq), call $i -> exit 0");
            push @outs, $out;
        }
        unlike(join("\n", @outs), qr/jq is required/i,
               'AC-13: missing-jq path never uses the fail-CLOSED bp_hook_require_jq message');
    }

    # =================================================================================
    # AC-14 [hook] fail-open: malformed input
    # =================================================================================
    {
        my @malformed = (
            ['',                                     'empty stdin'],
            ['not json at all',                       'non-JSON garbage'],
            ['{',                                     'truncated/invalid JSON'],
            ['[]',                                    'JSON array, not an object'],
            ['{"tool_input":{"command":"x"}}',         'JSON object with no tool_name'],
            ['{"tool_name":""}',                       'tool_name present but empty'],
        );
        for my $m (@malformed) {
            my ($payload, $desc) = @$m;
            my $dir = mk_bp(); my %env = default_env($dir);
            my ($rc) = run_hook($payload, %env);
            is($rc, 0, "AC-14: malformed input ($desc) -> exit 0");
        }
    }

    # =================================================================================
    # AC-15 [hook] fail-open: bad state file (B14, B15)
    # =================================================================================
    {
        # (a) garbage-filled state file self-heals
        my $dir = mk_bp(); my %env = default_env($dir);
        my $file = state_file_path($dir, 'p', 'nosid');
        open my $w, '>', $file or die; print $w "garbage\n\tbad\t\nnotanumber\thash\t0\n123\tok\tnotdigit\n"; close $w;
        my $payload = mkpayload(tool_name => 'Bash', tool_input => { command => 'ac15a' });
        my ($rc) = run_hook($payload, %env);
        is($rc, 0, 'AC-15a: garbage-filled state file -> exit 0 (fail open)');
        my @bad = grep { !valid_line($_) } read_lines($file);
        is(scalar(@bad), 0, 'AC-15a: after the call the state file contains only valid lines (garbage dropped on rewrite)');
    }
    {
        # (b) state path pre-created as a directory
        my $dir = mk_bp(); my %env = default_env($dir);
        my $file = state_file_path($dir, 'p', 'nosid');
        mkdir $file or die "mkdir $file: $!";
        my $payload = mkpayload(tool_name => 'Bash', tool_input => { command => 'ac15b' });
        my ($rc) = run_hook($payload, %env);
        is($rc, 0, 'AC-15b: state path pre-created as a directory -> exit 0 (fail open)');
    }
    SKIP: {
        # (c) runs/ read-only -- root ignores the permission bit; skip gracefully and stay green
        my $is_root = ($> == 0 || $< == 0);
        skip 'running as root -- permission bits do not restrict root, cannot force an unwritable runs/', 4
            if $is_root;
        my $dir = mk_bp(); my %env = default_env($dir);
        chmod 0500, "$dir/runs";
        my $payload = mkpayload(tool_name => 'Bash', tool_input => { command => 'ac15c' });
        for my $i (1 .. 4) {
            my ($rc) = run_hook($payload, %env);
            is($rc, 0, "AC-15c: runs/ read-only, call $i -> exit 0 (never blocks when state can't be written)");
        }
        chmod 0755, "$dir/runs";
    }

    # =================================================================================
    # AC-16 [hook] defaults are exactly 4 / 64 / 300 / nudge
    # =================================================================================
    {
        my $dir = mk_bp(); my %env = default_env($dir);
        my $payload = mkpayload(tool_name => 'Bash', tool_input => { command => 'ac16-defaults' });
        my ($rc1) = run_hook($payload, %env); is($rc1, 0, 'AC-16: default threshold 4, call 1 -> exit 0');
        my ($rc2) = run_hook($payload, %env); is($rc2, 0, 'AC-16: default threshold 4, call 2 -> exit 0');
        my ($rc3) = run_hook($payload, %env); is($rc3, 0, 'AC-16: default threshold 4, call 3 -> exit 0');
        my ($rc4) = run_hook($payload, %env); is($rc4, 2, 'AC-16: default threshold 4, call 4 -> exit 2');
        my ($rc5) = run_hook($payload, %env); is($rc5, 0, 'AC-16: default action nudge (not deny), call 5 after the block -> exit 0');
    }
    {
        my $dir = mk_bp(); my %env = default_env($dir);
        my $file = state_file_path($dir, 'p', 'nosid');
        for my $i (1 .. 140) {
            my $payload = mkpayload(tool_name => 'Bash', tool_input => { command => "ac16-window-cmd-$i" });
            run_hook($payload, %env);
        }
        my @final16 = read_lines($file);
        is(scalar(@final16), 64, 'AC-16: default window 64 -- 140 distinct calls leave exactly 64 lines');
    }
    {
        my $payload = mkpayload(tool_name => 'Bash', tool_input => { command => 'ac16-stale-check' });
        my $hash = hash_call($payload);
        ok(length($hash) > 0, 'AC-16: precomputed hash for the staleness fixture is non-empty (sanity gate)');

        my $dirA = mk_bp(); my %envA = default_env($dirA);
        my $fileA = state_file_path($dirA, 'p', 'nosid');
        my $nowA = time();
        write_state_lines($fileA, [$nowA-403,$hash,0], [$nowA-402,$hash,0], [$nowA-401,$hash,0]);
        my ($rcA) = run_hook($payload, %envA);
        is($rcA, 0, 'AC-16: staleness -- trailing entry ~400s old does not join the run (default WINDOW_SECONDS=300) -> allowed');

        my $dirB = mk_bp(); my %envB = default_env($dirB);
        my $fileB = state_file_path($dirB, 'p', 'nosid');
        my $nowB = time();
        write_state_lines($fileB, [$nowB-202,$hash,0], [$nowB-201,$hash,0], [$nowB-200,$hash,0]);
        my ($rcB, $outB) = run_hook($payload, %envB);
        is($rcB, 2, 'AC-16: staleness -- trailing entry ~200s old joins the run (default WINDOW_SECONDS=300) -> blocked at threshold 4');
        like($outB, qr/REPEAT-GUARD/, 'AC-16: staleness-join case blocks with a REPEAT-GUARD message');

        my ($rcC) = run_hook($payload, %envB);
        is($rcC, 0, 'AC-16: after the staleness-triggered block, the next identical call is allowed (nudge fires once)');
    }

    # =================================================================================
    # AC-17 [hook] config overrides are honoured
    # =================================================================================
    {
        my $dir = mk_bp(); my %env = default_env($dir, BP_REPEAT_THRESHOLD => 2);
        my $payload = mkpayload(tool_name => 'Bash', tool_input => { command => 'ac17-threshold2' });
        my ($rc1) = run_hook($payload, %env); is($rc1, 0, 'AC-17: BP_REPEAT_THRESHOLD=2, call 1 -> exit 0');
        my ($rc2) = run_hook($payload, %env); is($rc2, 2, 'AC-17: BP_REPEAT_THRESHOLD=2, call 2 -> exit 2 (threshold reached early)');
    }
    {
        my $dir = mk_bp(); my %env = default_env($dir, BP_REPEAT_ACTION => 'off');
        my $payload = mkpayload(tool_name => 'Bash', tool_input => { command => 'ac17-off' });
        for my $i (1 .. 10) {
            my ($rc) = run_hook($payload, %env);
            is($rc, 0, "AC-17: BP_REPEAT_ACTION=off, call $i of 10 -> exit 0 (kill switch)");
        }
        my @lines = read_lines(state_file_path($dir, 'p', 'nosid'));
        ok(scalar(@lines) > 1, 'AC-17: BP_REPEAT_ACTION=off still records state (shadow mode) -- file grew past 1 line');
    }
    {
        my $dir = mk_bp(); my %env = default_env($dir, BP_REPEAT_ACTION => 'deny');
        my $payload = mkpayload(tool_name => 'Bash', tool_input => { command => 'ac17-deny' });
        for my $i (1 .. 3) {
            my ($rc) = run_hook($payload, %env);
            is($rc, 0, "AC-17: BP_REPEAT_ACTION=deny, call $i of 3 (below threshold) -> exit 0");
        }
        for my $i (4 .. 6) {
            my ($rc) = run_hook($payload, %env);
            is($rc, 2, "AC-17: BP_REPEAT_ACTION=deny, call $i -> exit 2 (sticky, fires every time past threshold)");
        }
    }
    {
        my $dir = mk_bp(); my %env = default_env($dir, BP_REPEAT_WINDOW_SECONDS => 0);
        my $payload = mkpayload(tool_name => 'Bash', tool_input => { command => 'ac17-window-seconds-0' });
        my $hash = hash_call($payload);
        ok(length($hash) > 0, 'AC-17: precomputed hash for the WINDOW_SECONDS=0 fixture is non-empty (sanity gate)');
        my $file = state_file_path($dir, 'p', 'nosid');
        my $now = time();
        write_state_lines($file, [$now-10000,$hash,0], [$now-9999,$hash,0], [$now-9998,$hash,0]);
        my ($rc, $out) = run_hook($payload, %env);
        is($rc, 2, 'AC-17: BP_REPEAT_WINDOW_SECONDS=0 -- a 10000s-old trailing run still counts and fires at threshold 4');
        like($out, qr/REPEAT-GUARD/, 'AC-17: WINDOW_SECONDS=0 fire stderr contains REPEAT-GUARD');
    }

    # =================================================================================
    # AC-19 [hook part] per-session keying (B16)
    # =================================================================================
    {
        my $dir = mk_bp(); my %env = default_env($dir);
        my $payload_alpha = mkpayload(tool_name => 'Bash', tool_input => { command => 'ac19-alpha' }, session_id => 'alpha');
        my $payload_beta  = mkpayload(tool_name => 'Bash', tool_input => { command => 'ac19-beta' },  session_id => 'beta');
        for (1 .. 3) { run_hook($payload_alpha, %env); run_hook($payload_beta, %env); }
        my ($rc_a4) = run_hook($payload_alpha, %env);
        is($rc_a4, 2, 'AC-19: session "alpha" reaches its own threshold and fires');
        my ($rc_b4) = run_hook($payload_beta, %env);
        is($rc_b4, 2, 'AC-19: session "beta" independently reaches its own threshold and fires (no cross-session contamination)');

        my $file_a = state_file_path($dir, 'p', 'alpha');
        my $file_b = state_file_path($dir, 'p', 'beta');
        ok(-e $file_a, 'AC-19: session "alpha" has its own state file');
        ok(-e $file_b, 'AC-19: session "beta" has its own state file');
        isnt($file_a, $file_b, 'AC-19: the two sessions write to different files');
        like($file_a, qr{^\Q$dir\E/runs/p\.repeat-.*\.log$}, 'AC-19: state filename matches ^<pkg>.repeat-*.log$ (alpha)');

        my $payload_nosid = mkpayload(tool_name => 'Bash', tool_input => { command => 'ac19-nosid' });
        run_hook($payload_nosid, %env);
        ok(-e state_file_path($dir, 'p', 'nosid'), 'AC-19: absent session_id writes to the ...repeat-nosid.log file');
    }

    # =================================================================================
    # AC-22 [hook] concurrency is harmless
    # =================================================================================
    {
        my $dir = mk_bp(); my %env = default_env($dir);
        my $payload = mkpayload(tool_name => 'Bash', tool_input => { command => 'concurrent-test' }, session_id => 'race');
        my $pf = "$ROOT/race-payload.json";
        open my $w, '>', $pf or die; print $w $payload; close $w;

        my @pids;
        for my $i (0, 1) {
            my $pid = fork();
            die "fork failed: $!" unless defined $pid;
            if ($pid == 0) {
                local %ENV = (%CLEAN_ENV, %env, HOOKPATH => fwd($HOOK), PFILE => fwd($pf));
                open(STDOUT, '>', "$ROOT/race-out-$i.txt") or exit 99;
                open(STDERR, '>&STDOUT') or exit 99;
                exec('bash', '-c', '"$HOOKPATH" < "$PFILE"');
                exit 98;   # exec failed
            }
            push @pids, $pid;
        }
        my @rcs;
        for my $pid (@pids) { waitpid($pid, 0); push @rcs, ($? >> 8); }

        ok(($rcs[0] == 0 || $rcs[0] == 2), "AC-22: concurrent invocation 1 exits 0 or 2 (got $rcs[0])");
        ok(($rcs[1] == 0 || $rcs[1] == 2), "AC-22: concurrent invocation 2 exits 0 or 2 (got $rcs[1])");

        my $file = state_file_path($dir, 'p', 'race');
        my @lines = read_lines($file);
        ok(scalar(@lines) > 0, 'AC-22: the state file exists and has at least one entry after the concurrent writes');
        my @bad = grep { !valid_line($_) } @lines;
        is(scalar(@bad), 0, 'AC-22: state file after concurrent writes contains only valid lines (a lost update is fine, corruption is not)');
    }

    # =================================================================================
    # F1 [pure] bp_repeat_hash must not be super-linear on large payloads (HIGH-1).
    # Ref: redteam-step6.md HIGH-1. Fixed version measures ~0.03s on 256KB; current ~59s.
    # =================================================================================
    {
        my $bigcontent = 'word ' x 51200; # ~256KB, exact redteam repro shape
        my $pbig = mkpayload(tool_name => 'Write', tool_input => { file_path => '/a', content => $bigcontent });
        my ($hbig, $elapsed) = hash_call_bounded($pbig, 90);
        ok($elapsed < 2.0,
           sprintf('F1a: bp_repeat_hash on a ~256KB Write payload completes in under 2s (got %.2fs) [HIGH-1]', $elapsed));
    }
    {
        my $prefix = 'a' x 2048;
        my $pshort = mkpayload(tool_name => 'Write', tool_input => { file_path => '/a', content => $prefix . ('b' x 10) });
        my $plong  = mkpayload(tool_name => 'Write', tool_input => { file_path => '/a', content => $prefix . ('b' x 500) });
        my ($hs) = hash_call_bounded($pshort, 15);
        my ($hl) = hash_call_bounded($plong, 15);
        ok(length($hs) && length($hl) && $hs ne $hl,
           'F1b: two payloads sharing a 2048-char content prefix but differing in total length hash differently [HIGH-1]');
    }
    {
        my $content = 'z' x 65536;
        my $p = mkpayload(tool_name => 'Write', tool_input => { file_path => '/a', content => $content });
        my ($h1) = hash_call_bounded($p, 30);
        my ($h2) = hash_call_bounded($p, 30);
        ok(length($h1) && length($h2) && $h1 eq $h2,
           'F1c: two identical large (64KB) payloads still produce the same hash [HIGH-1]');
    }

    # =================================================================================
    # F2 [hook] wait/poll tools must be exempt from the guard (HIGH-2).
    # Ref: redteam-step6.md HIGH-2.
    # =================================================================================
    {
        my $dir = mk_bp(); my %env = default_env($dir);
        my $payload = mkpayload(tool_name => 'BashOutput', tool_input => { bash_id => 'bash_1' });
        my @outs;
        for my $i (1 .. 10) {
            my ($rc, $out) = run_hook($payload, %env);
            is($rc, 0, "F2a: BashOutput identical poll $i of 10 -> exit 0 (exempt) [HIGH-2]");
            push @outs, $out;
        }
        unlike(join("\n", @outs), qr/REPEAT-GUARD/, 'F2a: BashOutput polling never emits a REPEAT-GUARD advisory [HIGH-2]');
    }
    {
        my %fixtures = (
            KillShell  => { shell_id => 'bash_1' },
            TaskOutput => { task_id  => 'task_1' },
            TaskGet    => { task_id  => 'task_1' },
            TaskList   => {},
            Monitor    => {},
        );
        for my $tool (sort keys %fixtures) {
            my $dir = mk_bp(); my %env = default_env($dir);
            my $payload = mkpayload(tool_name => $tool, tool_input => $fixtures{$tool});
            my $any_bad = 0;
            my @outs;
            for (1 .. 6) {
                my ($rc, $out) = run_hook($payload, %env);
                $any_bad = 1 if $rc != 0;
                push @outs, $out;
            }
            ok(!$any_bad, "F2b: $tool identical calls (6x, past default threshold) never exit nonzero (exempt) [HIGH-2]");
            unlike(join("\n", @outs), qr/REPEAT-GUARD/, "F2b: $tool never emits a REPEAT-GUARD advisory [HIGH-2]");
        }
    }
    {
        # exemption must not disable the guard generally -- a non-exempt tool still fires
        my $dir = mk_bp(); my %env = default_env($dir);
        my $payload = mkpayload(tool_name => 'Bash', tool_input => { command => 'f2c-non-exempt' });
        my ($r1) = run_hook($payload, %env); is($r1, 0, 'F2c: non-exempt Bash call 1 of 4 -> exit 0');
        my ($r2) = run_hook($payload, %env); is($r2, 0, 'F2c: non-exempt Bash call 2 of 4 -> exit 0');
        my ($r3) = run_hook($payload, %env); is($r3, 0, 'F2c: non-exempt Bash call 3 of 4 -> exit 0');
        my ($r4, $out4) = run_hook($payload, %env);
        is($r4, 2, 'F2c: non-exempt Bash still fires at the threshold (exemption is per-tool, not global) [HIGH-2]');
        like($out4, qr/REPEAT-GUARD/, 'F2c: non-exempt Bash fire stderr contains REPEAT-GUARD');
    }
    {
        # BP_REPEAT_EXEMPT_TOOLS override: widen the exemption to Bash
        my $dir = mk_bp(); my %env = default_env($dir, BP_REPEAT_EXEMPT_TOOLS => '^Bash$');
        my $payload = mkpayload(tool_name => 'Bash', tool_input => { command => 'f2d-bash-exempted' });
        my $any_bad = 0;
        for (1 .. 6) { my ($rc) = run_hook($payload, %env); $any_bad = 1 if $rc != 0; }
        ok(!$any_bad, 'F2d: BP_REPEAT_EXEMPT_TOOLS=^Bash$ makes Bash exempt [HIGH-2]');
    }
    {
        # BP_REPEAT_EXEMPT_TOOLS override: narrow the exemption so BashOutput is no longer exempt
        my $dir = mk_bp(); my %env = default_env($dir, BP_REPEAT_EXEMPT_TOOLS => '^NoSuchTool$');
        my $payload = mkpayload(tool_name => 'BashOutput', tool_input => { bash_id => 'bash_2' });
        my ($r1) = run_hook($payload, %env); is($r1, 0, 'F2d: BP_REPEAT_EXEMPT_TOOLS=^NoSuchTool$, BashOutput call 1 of 4 -> exit 0');
        my ($r2) = run_hook($payload, %env); is($r2, 0, 'F2d: BP_REPEAT_EXEMPT_TOOLS=^NoSuchTool$, BashOutput call 2 of 4 -> exit 0');
        my ($r3) = run_hook($payload, %env); is($r3, 0, 'F2d: BP_REPEAT_EXEMPT_TOOLS=^NoSuchTool$, BashOutput call 3 of 4 -> exit 0');
        my ($r4, $out4) = run_hook($payload, %env);
        is($r4, 2, 'F2d: BP_REPEAT_EXEMPT_TOOLS overridden away from BashOutput -> it fires again at threshold [HIGH-2]');
        like($out4, qr/REPEAT-GUARD/, 'F2d: BashOutput fire stderr (override case) contains REPEAT-GUARD');
    }
    {
        # empty/unset BP_REPEAT_EXEMPT_TOOLS -> built-in default exemption list still applies
        my $dir = mk_bp(); my %env = default_env($dir, BP_REPEAT_EXEMPT_TOOLS => '');
        my $payload = mkpayload(tool_name => 'BashOutput', tool_input => { bash_id => 'bash_3' });
        my $any_bad = 0;
        for (1 .. 6) { my ($rc) = run_hook($payload, %env); $any_bad = 1 if $rc != 0; }
        ok(!$any_bad, 'F2e: empty BP_REPEAT_EXEMPT_TOOLS falls back to the built-in default exemption list [HIGH-2]');
    }
    {
        # malformed ERE must fail open: never crash the hook, never anything but exit 0/2
        my $dir = mk_bp(); my %env = default_env($dir, BP_REPEAT_EXEMPT_TOOLS => '[', BP_REPEAT_THRESHOLD => 2);
        my $payload = mkpayload(tool_name => 'Bash', tool_input => { command => 'f2e-malformed-ere' });
        my @outs;
        for my $i (1 .. 3) {
            my ($rc, $out) = run_hook($payload, %env);
            ok(($rc == 0 || $rc == 2), "F2e: malformed BP_REPEAT_EXEMPT_TOOLS ERE, call $i -> exit 0 or 2, never a crash [HIGH-2]");
            push @outs, $out;
        }
        unlike(join("\n", @outs), qr/syntax error|unexpected EOF|command not found|unbound variable/i,
               'F2e: malformed ERE never produces a shell error on stderr (fails open)');
    }

    # =================================================================================
    # F3 [hook] the fired flag must survive the RETAIN trim -- fire exactly once per run
    # (MEDIUM-2). NOTE: this deliberately supersedes the un-fixed refire-every-RETAIN+1
    # behaviour; no pre-existing assertion in this file encoded that behaviour, so none
    # needed to change.
    # =================================================================================
    {
        my $dir = mk_bp(); my %env = default_env($dir, BP_REPEAT_THRESHOLD => 2, BP_REPEAT_WINDOW => 1);
        my $payload = mkpayload(tool_name => 'Bash', tool_input => { command => 'f3a-loop' });
        my $fires = 0;
        for (1 .. 12) {
            my ($rc) = run_hook($payload, %env);
            $fires++ if $rc == 2;
        }
        is($fires, 1, 'F3a: THRESHOLD=2/WINDOW=1 (RETAIN=2), 12 identical calls fire exactly once [MEDIUM-2]');
    }
    {
        my $dir = mk_bp(); my %env = default_env($dir);
        my $payload = mkpayload(tool_name => 'Bash', tool_input => { command => 'f3b-loop' });
        my $fires = 0;
        for (1 .. 70) {
            my ($rc) = run_hook($payload, %env);
            $fires++ if $rc == 2;
        }
        is($fires, 1, 'F3b: default THRESHOLD=4/WINDOW=64, 70 identical calls fire exactly once (current code fires at call 4 and 69) [MEDIUM-2]');
    }
    {
        my $dir = mk_bp(); my %env = default_env($dir, BP_REPEAT_THRESHOLD => 2, BP_REPEAT_WINDOW => 1);
        my $payloadA = mkpayload(tool_name => 'Bash', tool_input => { command => 'f3c-a' });
        my $payloadB = mkpayload(tool_name => 'Bash', tool_input => { command => 'f3c-b' });
        my ($r1) = run_hook($payloadA, %env); is($r1, 0, 'F3c: call 1 of run A -> exit 0');
        my ($r2) = run_hook($payloadA, %env); is($r2, 2, 'F3c: call 2 of run A reaches threshold -> exit 2 (first fire)');
        my ($r3) = run_hook($payloadB, %env); is($r3, 0, 'F3c: an intervening different call B breaks the trailing run (genuine reset)');
        my ($r4) = run_hook($payloadA, %env); is($r4, 0, 'F3c: after reset, call 1 of a fresh run A -> exit 0');
        my ($r5) = run_hook($payloadA, %env);
        is($r5, 2, 'F3c: after reset, call 2 of the fresh run A fires again -- the fired flag dies with the broken run, not permanently sticky [MEDIUM-2]');
    }

    # =================================================================================
    # F4 [hook] the state path must be type-checked BEFORE it is read (MEDIUM-3/LOW-4).
    # Both sub-tests are wrapped in `run_hook_bounded` (hard `timeout`), so a regression
    # here fails loudly instead of hanging this suite.
    # =================================================================================
    {
        my $dir = mk_bp(); my %env = default_env($dir);
        my $file = state_file_path($dir, 'p', 'nosid');
        mkfifo($file, 0600) or die "mkfifo $file: $!";
        my $payload = mkpayload(tool_name => 'Bash', tool_input => { command => 'f4-fifo' });
        my ($rc, $out) = run_hook_bounded($payload, 10, %env);
        isnt($rc, 124, 'F4a: FIFO pre-created at the state path -- hook does not hang past a 10s bound [MEDIUM-3/LOW-4]');
        is($rc, 0, 'F4a: FIFO pre-created at the state path -- hook returns exit 0 (type-checked before read)');
    }
    {
        my $dir = mk_bp(); my %env = default_env($dir);
        my $file = state_file_path($dir, 'p', 'nosid');
        symlink('/dev/zero', $file) or die "symlink $file: $!";
        my $payload = mkpayload(tool_name => 'Bash', tool_input => { command => 'f4-devzero' });
        my ($rc, $out) = run_hook_bounded($payload, 10, %env);
        isnt($rc, 124, 'F4b: symlink to /dev/zero at the state path -- hook does not hang past a 10s bound [MEDIUM-3/LOW-4]');
        is($rc, 0, 'F4b: symlink to /dev/zero at the state path -- hook returns exit 0');
    }

    # =================================================================================
    # F5 [hook] the advisory message must be action-aware and self-consistent (MEDIUM-5).
    # =================================================================================
    {
        my $dir = mk_bp(); my %env = default_env($dir);
        my $payload = mkpayload(tool_name => 'Bash', tool_input => { command => 'f5-nudge-msg' });
        run_hook($payload, %env) for 1 .. 3;
        my (undef, $out_nudge) = run_hook($payload, %env);
        like($out_nudge, qr/REPEAT-GUARD:/, 'F5a: nudge fired message contains "REPEAT-GUARD:"');
        like($out_nudge, qr/Bash/,          'F5a: nudge fired message names the tool');
        like($out_nudge, qr/\b4\b/,         'F5a: nudge fired message states the run length');

        my $has_do_not_retry  = ($out_nudge =~ /[Dd]o NOT retry/)   ? 1 : 0;
        my $has_retry_allowed = ($out_nudge =~ /retry is allowed/) ? 1 : 0;
        ok(!($has_do_not_retry && $has_retry_allowed),
           'F5b: message does not simultaneously say "do NOT retry" and "retry is allowed" (self-contradiction) [MEDIUM-5]');

        unlike($out_nudge, qr/BP_REPEAT_ACTION=off/,
               'F5d: message does not advertise BP_REPEAT_ACTION=off to the nudged agent [MEDIUM-5]');
        like($out_nudge, qr/wait|poll/i,
             'F5e: message mentions the waiting/polling carve-out so a wrongly-nudged waiter knows the advisory does not apply [MEDIUM-5]');
    }
    {
        my $dir = mk_bp(); my %env = default_env($dir, BP_REPEAT_ACTION => 'deny');
        my $payload = mkpayload(tool_name => 'Bash', tool_input => { command => 'f5-deny-msg' });
        run_hook($payload, %env) for 1 .. 3;
        my (undef, $out_deny) = run_hook($payload, %env);
        unlike($out_deny, qr/retry is allowed/i,
               'F5c: under BP_REPEAT_ACTION=deny the message does not claim a retry will be allowed [MEDIUM-5]');
    }

    # =================================================================================
    # F6 [hook] no stray stderr on the clean path (LOW-1).
    # =================================================================================
    {
        my $dir = mk_bp(); my %env = default_env($dir);
        my $payload = mkpayload(tool_name => 'Bash', tool_input => { command => 'f6-first-call' });
        my ($rc1, $out1) = run_hook($payload, %env);
        is($rc1, 0, 'F6a: first-ever call against a fresh empty runs/ -> exit 0');
        is($out1, '', 'F6a: first-ever call against a fresh empty runs/ produces completely empty stderr/stdout [LOW-1]');
        my ($rc2, $out2) = run_hook($payload, %env);
        is($rc2, 0, 'F6b: second (non-firing) call -> exit 0');
        is($out2, '', 'F6b: second (non-firing) call produces completely empty stderr [LOW-1]');
    }
}

done_testing();
