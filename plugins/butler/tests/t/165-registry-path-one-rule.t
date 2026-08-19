#!/usr/bin/env perl
# 165-registry-path-one-rule.t — d04-registry-path-one-rule: the DRIVE-SOLO and
# REPORTER registries stop guessing $PWD.
#
# Spec: specs/d04-registry-path-one-rule-spec.md. Written BLIND to any edit of
# lib.sh/mark-wakeup.sh/gate-drive-loop.sh beyond what the spec itself quotes
# verbatim (bp_registry_root's pseudocode, the two exact stderr diagnostic
# lines) -- every other expectation below is derived from the spec's numbered
# observable behaviors (S3) and acceptance criteria (S4), not from reading the
# current implementation beyond what the scout/spec already cite.
#
# RULING 0 (spec, read first): "loud" for a write-site failure means ONE
# greppable stderr line naming the registry and session id -- NEVER a
# non-zero exit code. Both hooks keep "exit 0 on every path" unconditionally.
# Read sites get silent fail-safe. Every assertion below that checks a write
# site's failure checks BOTH stderr content AND exit code 0 in the same test,
# per the spec's own warning that checking only one would miss the regression
# that matters (a hook that starts blocking).
#
# THE CENTRAL HAZARD (AC10): a session whose cwd changes between the ARM
# hook (mark-wakeup.sh, PreToolUse) and the Stop hook (gate-drive-loop.sh) is
# exercised by literally chdir()-ing this test process between the two
# subprocess invocations -- never by varying the JSON payload's own `cwd`
# field, which these functions do not read for registry-path resolution.
#
# NEVER writes into real $HOME/.claude/ccpraxis/* registries: every fixture
# either overrides via CCPRAXIS_*_ACTIVE_DIR, or -- for the unresolved-path
# fixtures, which must NOT use the override, by design -- chdir()s into a
# disposable File::Temp scratch directory first and asserts nothing was
# created there, mirroring 149-continuity-toggle.t section O's own technique.
#
# Runs standalone: perl plugins/butler/tests/t/165-registry-path-one-rule.t
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use JSON::PP;
use Cwd ();

my $HOOKS = "$Bin/../../hooks";
my $LIB   = "$HOOKS/lib.sh";
my $MARK  = "$HOOKS/mark-wakeup.sh";
my $GATE  = "$HOOKS/gate-drive-loop.sh";

ok(-f $LIB,  'A1: lib.sh exists')             or BAIL_OUT('lib.sh missing');
ok(-f $MARK, 'A2: mark-wakeup.sh exists')     or BAIL_OUT('hook missing');
ok(-f $GATE, 'A3: gate-drive-loop.sh exists') or BAIL_OUT('hook missing');

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

sub shq { my $s = shift; $s =~ s/'/'\\''/g; return "'$s'"; }

# probe_lib(FN, \@ARGS, %opt) -> (STDOUT, RC)
#   %opt: env => { VAR => value|undef }  (undef = truly unset, not '')
#         cwd => path to chdir() the CHILD process into before calling FN
# Sources lib.sh fresh in a throwaway bash script and calls FN directly --
# never through a hook -- so bp_registry_root/bp_drive_active_dir/
# bp_reporter_active_dir/bp_drive_marker can be probed in isolation from the
# hooks' own gating logic.
sub probe_lib {
    my ($fn, $args, %opt) = @_;
    $args //= [];
    my %env_extra = %{ $opt{env} // {} };
    my $cwd = $opt{cwd};

    my ($fh, $file) = tempfile(SUFFIX => '.sh', UNLINK => 1);
    my $argstr = join(' ', map { shq($_) } @$args);
    print {$fh} "#!/usr/bin/env bash\n";
    print {$fh} "source \"$LIB\" 2>/dev/null\n";
    print {$fh} "OUT=\$($fn $argstr 2>/dev/null)\n";
    print {$fh} "RC=\$?\n";
    print {$fh} "printf '%s\\x1e%d' \"\$OUT\" \"\$RC\"\n";
    close $fh;

    local %ENV = %ENV;
    for my $k (sort keys %env_extra) {
        my $v = $env_extra{$k};
        if (!defined $v) { delete $ENV{$k} }
        else              { $ENV{$k} = $v }
    }

    my $orig_cwd;
    if (defined $cwd) {
        $orig_cwd = Cwd::getcwd();
        chdir($cwd) or die "chdir $cwd: $!";
    }
    my $raw = `bash "$file"`;
    if (defined $cwd) {
        chdir($orig_cwd) or die "chdir back to $orig_cwd: $!";
    }
    my ($out, $rc) = split(/\x1e/, (defined $raw ? $raw : ''), 2);
    return ($out // '', 0 + ($rc // -1));
}

# run_hook(SCRIPT, PAYLOAD, %opt) -> (RC, COMBINED_OUTPUT)
#   %opt: env => { VAR => value|undef }, cwd => path to chdir() the CHILD into
sub run_hook {
    my ($script, $payload, %opt) = @_;
    my %env_extra = %{ $opt{env} // {} };
    my $cwd = $opt{cwd};

    local %ENV = %ENV;
    for my $k (sort keys %env_extra) {
        my $v = $env_extra{$k};
        if (!defined $v) { delete $ENV{$k} }
        else              { $ENV{$k} = $v }
    }

    my $orig_cwd;
    if (defined $cwd) {
        $orig_cwd = Cwd::getcwd();
        chdir($cwd) or die "chdir $cwd: $!";
    }
    my $out = `bash "$script" <<'PAYLOAD_EOF' 2>&1
$payload
PAYLOAD_EOF`;
    my $rc = $? >> 8;
    if (defined $cwd) {
        chdir($orig_cwd) or die "chdir back to $orig_cwd: $!";
    }
    return ($rc, defined($out) ? $out : '');
}

sub new_project {
    my (%opt) = @_;
    my $root = tempdir(CLEANUP => 1);
    make_path("$root/.ccpraxis-local-data");
    make_path("$root/.ccpraxis-local-data/.drive-solo") if $opt{drive_solo};
    return $root;
}

sub driver_arm_payload {
    my ($cwd, $sid) = @_;
    my $cmd = q{perl "${CLAUDE_PLUGIN_ROOT}"/scripts/bp-drive-next.pl next};
    return JSON::PP->new->canonical->encode({
        session_id => $sid, cwd => $cwd, tool_name => 'Bash',
        tool_input => { command => $cmd },
    });
}

sub reporter_arm_payload {
    my ($cwd, $sid) = @_;
    my $cmd = q{perl "${CLAUDE_PLUGIN_ROOT}"/scripts/bp-watch.pl --arm --blueprint bp-x }
            . q{--pid-file bp-x/runs/.orchestrator --max-seconds 1800};
    return JSON::PP->new->canonical->encode({
        session_id => $sid, cwd => $cwd, tool_name => 'Bash',
        tool_input => { command => $cmd },
    });
}

sub stop_payload { my ($cwd, $sid) = @_; return qq({"session_id":"$sid","cwd":"$cwd"}); }

sub extract_fn_body {
    my ($src, $name) = @_;
    if ($src =~ /^\Q$name\E\(\)\s*\{\r?\n(.*?)^\}/ms) {
        return $1;
    }
    return undef;
}

sub slurp {
    my ($f) = @_;
    open my $fh, '<', $f or die "read $f: $!";
    local $/;
    return <$fh>;
}

# ===========================================================================
# B. AC1 -- bp_registry_root exists, is the ONLY place the fallback chain is
#    spelled out, and every registry-resolver function calls it (never
#    restates it).
# ===========================================================================
{
    my $src = slurp($LIB);

    my $chain_count = () = ($src =~ /local base="\$\{HOME:-\}"/g);
    is($chain_count, 1,
       'B1 CANONICAL (-> AC1): the literal override->HOME fallback opener '
     . '(local base="${HOME:-}") appears EXACTLY ONCE in lib.sh -- today it '
     . 'appears once already, inline inside bp_continuity_active_dir, which '
     . 'is the wrong place per this criterion: it must live in bp_registry_root '
     . 'and nowhere else');

    my $root_body = extract_fn_body($src, 'bp_registry_root');
    ok(defined($root_body), 'B2 CANONICAL (-> AC1): bp_registry_root() is defined in lib.sh')
        or diag('bp_registry_root not found -- the shared resolver does not exist yet');
    if (defined $root_body) {
        like($root_body, qr/local base="\$\{HOME:-\}"/,
           'B3: bp_registry_root contains the fallback chain literal itself');
        like($root_body, qr/USERPROFILE/,
           'B4: bp_registry_root also consults USERPROFILE');
        unlike($root_body, qr/\$PWD/,
           'B5 CANONICAL (-> AC observable 3): bp_registry_root never reads $PWD');
    }

    for my $fn (qw(bp_continuity_active_dir bp_drive_active_dir bp_reporter_active_dir)) {
        my $body = extract_fn_body($src, $fn);
        ok(defined($body), "B6 setup: $fn is defined in lib.sh");
        next unless defined $body;
        unlike($body, qr/local base="\$\{HOME:-\}"/,
           "B7 CANONICAL (-> AC1): $fn does not restate the fallback chain literal itself");
        like($body, qr/bp_registry_root/,
           "B8 CANONICAL (-> AC1): $fn calls bp_registry_root rather than inventing its own order");
    }
}

# ===========================================================================
# C. AC2 -- bp_reporter_active_dir is a NEW function; mark-wakeup.sh Site B
#    and gate-drive-loop.sh Sites C/D all call it; no literal reporter-path
#    ${HOME:-...} expression remains outside lib.sh.
# ===========================================================================
{
    my $lib_src  = slurp($LIB);
    my $mark_src = slurp($MARK);
    my $gate_src = slurp($GATE);

    my $reporter_body = extract_fn_body($lib_src, 'bp_reporter_active_dir');
    ok(defined($reporter_body), 'C1 CANONICAL (-> AC2): bp_reporter_active_dir is defined in lib.sh')
        or diag('bp_reporter_active_dir missing -- the reporter registry still has no shared resolver');
    if (defined $reporter_body) {
        like($reporter_body, qr/CCPRAXIS_REPORTER_ACTIVE_DIR/,
           'C2: bp_reporter_active_dir honours its own override var');
        like($reporter_body, qr/\.reporter-active/,
           'C3: bp_reporter_active_dir resolves the .reporter-active leaf');
    }

    like($mark_src, qr/bp_reporter_active_dir/,
       'C4 CANONICAL (-> AC2): mark-wakeup.sh Site B calls bp_reporter_active_dir');
    my $gate_calls = () = ($gate_src =~ /bp_reporter_active_dir/g);
    ok($gate_calls >= 2,
       "C5 CANONICAL (-> AC2): gate-drive-loop.sh calls bp_reporter_active_dir at least twice "
     . "(sites C and D) -- found $gate_calls");

    unlike($mark_src, qr/\$\{HOME:-\$PWD\}\/\.claude\/ccpraxis\/\.reporter-active/,
       'C6 CANONICAL (-> AC2): no literal ${HOME:-$PWD}/.claude/ccpraxis/.reporter-active '
     . 'expression remains in mark-wakeup.sh');
    unlike($gate_src, qr/\$\{HOME:-\$PWD\}\/\.claude\/ccpraxis\/\.reporter-active/,
       'C7 CANONICAL (-> AC2): no literal ${HOME:-$PWD}/.claude/ccpraxis/.reporter-active '
     . 'expression remains in gate-drive-loop.sh');
}

# ===========================================================================
# D. AC3 -- grep for the literal substring HOME:-$PWD across all three files
#    returns zero (spec says it currently returns four).
# ===========================================================================
{
    my $total = 0;
    my %per_file;
    for my $f ($LIB, $MARK, $GATE) {
        my $src = slurp($f);
        my $n = () = ($src =~ /HOME:-\$PWD/g);
        $per_file{$f} = $n;
        $total += $n;
    }
    is($total, 0,
       "D1 CANONICAL (-> AC3): zero occurrences of the literal 'HOME:-\$PWD' across "
     . "lib.sh/mark-wakeup.sh/gate-drive-loop.sh -- found $total "
     . "(lib.sh=$per_file{$LIB}, mark-wakeup.sh=$per_file{$MARK}, gate-drive-loop.sh=$per_file{$GATE})");
}

# ===========================================================================
# E. bp_registry_root itself, direct probes (observable behaviors 1-3).
# ===========================================================================
{
    my $home = tempdir(CLEANUP => 1);
    my ($out, $rc) = probe_lib('bp_registry_root', [], env => { HOME => $home, USERPROFILE => undef });
    is($rc, 0, 'E1 (-> behavior 1): bp_registry_root rc 0 when $HOME is set');
    is($out, $home, 'E2 CANONICAL (-> behavior 1): bp_registry_root prints $HOME verbatim');
}
{
    my $home = tempdir(CLEANUP => 1);
    my $up   = tempdir(CLEANUP => 1);
    my ($out, $rc) = probe_lib('bp_registry_root', [], env => { HOME => $home, USERPROFILE => $up });
    is($out, $home,
       'E3 CANONICAL (-> behavior 1): with BOTH $HOME and $USERPROFILE set, $USERPROFILE is '
     . 'NOT consulted -- $HOME wins outright');
}
{
    my $up = tempdir(CLEANUP => 1);
    my ($out, $rc) = probe_lib('bp_registry_root', [], env => { HOME => undef, USERPROFILE => $up });
    is($rc, 0, 'E4 (-> behavior 2): bp_registry_root rc 0 with $HOME unset, $USERPROFILE set');
    is($out, $up, 'E5 CANONICAL (-> behavior 2): bp_registry_root prints $USERPROFILE verbatim');
}
{
    my $scratch = tempdir(CLEANUP => 1);
    my ($out, $rc) = probe_lib('bp_registry_root', [],
        env => { HOME => undef, USERPROFILE => undef }, cwd => $scratch);
    is($rc, 1, 'E6 CANONICAL (-> behavior 3): bp_registry_root rc 1 with both unset');
    is($out, '', 'E7 CANONICAL (-> behavior 3): bp_registry_root prints NOTHING with both unset '
                . '-- specifically NOT the scratch cwd it was invoked from');
}

# ===========================================================================
# F. bp_drive_active_dir / bp_reporter_active_dir, direct probes (observable
#    behaviors 4-7).
# ===========================================================================
for my $spec (
    { fn => 'bp_drive_active_dir',    leaf => '.drive-solo-active', override => 'CCPRAXIS_DRIVE_ACTIVE_DIR' },
    { fn => 'bp_reporter_active_dir', leaf => '.reporter-active',   override => 'CCPRAXIS_REPORTER_ACTIVE_DIR' },
) {
    my ($fn, $leaf, $ovar) = @{$spec}{qw(fn leaf override)};

    # behavior 4: override wins outright, regardless of HOME/USERPROFILE/cwd.
    {
        my $scratch = tempdir(CLEANUP => 1);
        my ($out, $rc) = probe_lib($fn, [],
            env => { $ovar => 'C:/nonexistent-override-value', HOME => undef, USERPROFILE => undef },
            cwd => $scratch);
        is($rc, 0, "F1 ($fn): override present -> rc 0");
        is($out, 'C:/nonexistent-override-value',
           "F2 CANONICAL (-> behavior 4, $fn): override value printed verbatim, unaffected by "
         . "HOME/USERPROFILE both being unset");
    }

    # behavior 5: override unset, $HOME set -> $HOME/.claude/ccpraxis/<leaf>.
    {
        my $home = tempdir(CLEANUP => 1);
        my ($out, $rc) = probe_lib($fn, [], env => { $ovar => undef, HOME => $home, USERPROFILE => undef });
        is($rc, 0, "F3 ($fn): \$HOME set -> rc 0");
        is($out, "$home/.claude/ccpraxis/$leaf",
           "F4 CANONICAL (-> behavior 5, $fn): resolves under \$HOME/.claude/ccpraxis/$leaf");
    }

    # behavior 6: $HOME unset, $USERPROFILE set -> resolves under $USERPROFILE.
    {
        my $up = tempdir(CLEANUP => 1);
        my ($out, $rc) = probe_lib($fn, [], env => { $ovar => undef, HOME => undef, USERPROFILE => $up });
        is($rc, 0, "F5 ($fn): \$USERPROFILE set, \$HOME unset -> rc 0");
        is($out, "$up/.claude/ccpraxis/$leaf",
           "F6 CANONICAL (-> behavior 6, $fn): resolves under \$USERPROFILE/.claude/ccpraxis/$leaf");
    }

    # behavior 7: all three unset -> nothing, rc 1. Run from a scratch cwd
    # that must NOT leak into the result.
    {
        my $scratch = tempdir(CLEANUP => 1);
        my ($out, $rc) = probe_lib($fn, [],
            env => { $ovar => undef, HOME => undef, USERPROFILE => undef }, cwd => $scratch);
        is($rc, 1, "F7 CANONICAL (-> behavior 7, $fn): all three unset -> rc 1");
        is($out, '', "F8 CANONICAL (-> behavior 7, $fn): all three unset -> empty stdout, "
                    . "specifically not the scratch cwd \$out would equal under the old \${HOME:-\$PWD} bug");
    }
}

# ===========================================================================
# G. AC11/AC12 -- explicit container-ruling and USERPROFILE-order coverage,
#    both functions, in the same test so the "no special-casing" claim (DC4)
#    is checked directly rather than incidentally.
# ===========================================================================
{
    my $home = tempdir(CLEANUP => 1);
    for my $spec (
        ['bp_drive_active_dir',    '.drive-solo-active'],
        ['bp_reporter_active_dir', '.reporter-active'],
    ) {
        my ($fn, $leaf) = @$spec;
        my ($out, $rc) = probe_lib($fn, [], env => { HOME => $home, USERPROFILE => undef });
        is($rc, 0, "G1 (-> AC11, $fn): \$HOME set, \$USERPROFILE unset -> rc 0");
        is($out, "$home/.claude/ccpraxis/$leaf",
           "G2 CANONICAL (-> AC11, $fn): resolves under the fixture \$HOME with no "
         . "container-specific branch -- same code path as a container's HOME=/root");
    }
}
{
    my $up      = tempdir(CLEANUP => 1);
    my $scratch = tempdir(CLEANUP => 1);   # deliberately NOT $up -- so a $PWD-fallback
                                            # regression resolves somewhere OTHER than $up
                                            # and G4 catches it, rather than accidentally
                                            # matching because the harness happened to run
                                            # from a directory equal to $up.
    for my $spec (
        ['bp_drive_active_dir',    '.drive-solo-active'],
        ['bp_reporter_active_dir', '.reporter-active'],
    ) {
        my ($fn, $leaf) = @$spec;
        my ($out, $rc) = probe_lib($fn, [], env => { HOME => undef, USERPROFILE => $up }, cwd => $scratch);
        is($rc, 0, "G3 (-> AC12, $fn): \$HOME unset, \$USERPROFILE set -> rc 0");
        is($out, "$up/.claude/ccpraxis/$leaf",
           "G4 CANONICAL (-> AC12, $fn): resolves under \$USERPROFILE, mirroring "
         . "bp_continuity_active_dir's own pinned fallback (t/149 section P)");
    }
}

# ===========================================================================
# H. AC13 -- bp_drive_marker regression: unresolved registry -> rc 1, EMPTY
#    stdout. NOT the pre-fix bogus "/sid" (filesystem-root-relative path).
# ===========================================================================
{
    my $scratch = tempdir(CLEANUP => 1);
    my ($out, $rc) = probe_lib('bp_drive_marker', ['sess-ac13'],
        env => { CCPRAXIS_DRIVE_ACTIVE_DIR => undef, HOME => undef, USERPROFILE => undef },
        cwd => $scratch);
    is($rc, 1, 'H1 CANONICAL (-> AC13): bp_drive_marker with a valid sid, registry unresolvable, '
             . 'returns rc 1');
    is($out, '', 'H2 CANONICAL (-> AC13): bp_drive_marker prints NOTHING -- not the pre-fix '
                . 'bogus "/sess-ac13" (dir="" . "/" . sid), which on this platform resolves '
                . 'against the current drive root, the same drive-root-stray class CLAUDE.md '
                . 'documents from the 2026-06-12 576-entry incident');
    unlike($out, qr{^/}, 'H3 CANONICAL (-> AC13): output never begins with a bare "/" '
                        . '(the drive-root-stray signature)');
}
# Bad sid, independent of registry resolution -- must stay rc 1 regardless
# (spec S5, unchanged ordering; also guards t/96 sections C5/C6's premise).
{
    my $home = tempdir(CLEANUP => 1);
    for my $bad ('', 'a/b', '.', '..', 'ab*', 'a..b') {
        my ($out, $rc) = probe_lib('bp_drive_marker', [$bad], env => { HOME => $home, USERPROFILE => undef });
        is($rc, 1, "H4 (sid validation unaffected, sid='$bad'): rc 1 even with a resolvable registry");
    }
}

# ===========================================================================
# I. AC6 -- mark-wakeup.sh drive-solo ARM, registry unresolvable: hook exits
#    0; stderr carries the Site-A diagnostic naming the session id; NO
#    .claude directory is created anywhere reachable from the scratch cwd.
# ===========================================================================
{
    my $root    = new_project(drive_solo => 1);
    my $scratch = tempdir(CLEANUP => 1);
    my $sid     = 'sess-ac6-armfail';

    my ($rc, $out) = run_hook($MARK, driver_arm_payload($root, $sid),
        env => { CCPRAXIS_DRIVE_ACTIVE_DIR => undef, HOME => undef, USERPROFILE => undef },
        cwd => $scratch);

    is($rc, 0, 'I1 CANONICAL (-> AC6, Ruling 0): mark-wakeup.sh ARM still exits 0 when the '
             . 'registry is unresolvable -- the hook NEVER blocks');
    like($out, qr/registry path unresolved/,
       'I2 CANONICAL (-> AC6): stderr matches /registry path unresolved/');
    like($out, qr/HOME and USERPROFILE both unset/,
       'I3 CANONICAL (-> AC6): stderr matches /HOME and USERPROFILE both unset/');
    like($out, qr/\Q$sid\E/,
       'I4 CANONICAL (-> AC6): stderr contains the literal session id from the fixture');
    ok(!-e "$scratch/.claude",
       'I5 CANONICAL (-> AC6, regression guard against a reintroduced $PWD fallback, mirrors '
     . 't/149 section O4): no .claude directory was created anywhere under the scratch cwd the '
     . 'hook process actually ran in');
}

# ===========================================================================
# J. AC7 -- mark-wakeup.sh reporter registration, same unresolved condition.
# ===========================================================================
{
    my $root    = new_project();
    my $scratch = tempdir(CLEANUP => 1);
    my $sid     = 'sess-ac7-regfail';

    my ($rc, $out) = run_hook($MARK, reporter_arm_payload($root, $sid),
        env => { CCPRAXIS_REPORTER_ACTIVE_DIR => undef, HOME => undef, USERPROFILE => undef },
        cwd => $scratch);

    is($rc, 0, 'J1 CANONICAL (-> AC7, Ruling 0): mark-wakeup.sh reporter registration still '
             . 'exits 0 when the registry is unresolvable');
    like($out, qr/registry path unresolved/,
       'J2 CANONICAL (-> AC7): stderr matches /registry path unresolved/');
    like($out, qr/HOME and USERPROFILE both unset/,
       'J3 CANONICAL (-> AC7): stderr matches /HOME and USERPROFILE both unset/');
    like($out, qr/\Q$sid\E/,
       'J4 CANONICAL (-> AC7): stderr contains the literal session id from the fixture');
    ok(!-e "$scratch/.claude",
       'J5 CANONICAL (-> AC7): no .claude directory was created anywhere under the scratch cwd');
}

# ===========================================================================
# K. AC8/AC9 -- gate-drive-loop.sh Stop check, both registries unresolvable:
#    hook exits 0 (allows the stop), SILENTLY -- no stderr diagnostic at all.
# ===========================================================================
{
    my $root    = new_project();
    my $scratch = tempdir(CLEANUP => 1);
    my $sid     = 'sess-ac89-stopfail';

    my ($rc, $out) = run_hook($GATE, stop_payload($root, $sid),
        env => { CCPRAXIS_DRIVE_ACTIVE_DIR => undef, CCPRAXIS_REPORTER_ACTIVE_DIR => undef,
                 HOME => undef, USERPROFILE => undef },
        cwd => $scratch);

    is($rc, 0, 'K1 CANONICAL (-> AC8/AC9): gate-drive-loop.sh Stop check exits 0 (allows the '
             . 'stop) when both registries are unresolvable');
    is($out, '', 'K2 CANONICAL (-> AC8/AC9): stderr is completely EMPTY on the read side -- no '
               . 'diagnostic, matching bp_continuity_marker/bp_continuity_any_active\'s silent '
               . 'fail-safe exactly');
}

# ===========================================================================
# L. AC10 -- THE CENTRAL HAZARD, first-class. cwd changes between ARM and
#    Stop AND the registry is unresolvable both times: ARM fails loudly and
#    writes NOTHING; the Stop check, from its own DIFFERENT cwd, independently
#    exits 0 silently. Both halves asserted in the SAME test, for both
#    registries, so "they must not silently disagree" is the actual property
#    checked.
# ===========================================================================
for my $case (
    { label => 'drive-solo', payload_fn => \&driver_arm_payload, drive_solo => 1,
      env_key => 'CCPRAXIS_DRIVE_ACTIVE_DIR' },
    { label => 'reporter',   payload_fn => \&reporter_arm_payload, drive_solo => 0,
      env_key => 'CCPRAXIS_REPORTER_ACTIVE_DIR' },
) {
    my $root      = new_project(drive_solo => $case->{drive_solo});
    my $scratch_a = tempdir(CLEANUP => 1);   # ARM's process cwd
    my $scratch_b = tempdir(CLEANUP => 1);   # Stop's process cwd -- DIFFERENT
    my $sid       = "sess-ac10-$case->{label}";

    my %unresolved_env = (
        $case->{env_key} => undef, HOME => undef, USERPROFILE => undef,
    );

    my ($arm_rc, $arm_out) = run_hook($MARK, $case->{payload_fn}->($root, $sid),
        env => \%unresolved_env, cwd => $scratch_a);

    is($arm_rc, 0, "L1 ($case->{label}, -> AC10): ARM exits 0 from cwd A");
    like($arm_out, qr/registry path unresolved/,
       "L2 ($case->{label}, -> AC10): ARM's stderr carries the loud diagnostic");
    ok(!-e "$scratch_a/.claude",
       "L3 CANONICAL ($case->{label}, -> AC10): ARM wrote NOTHING under its own scratch cwd A "
     . "-- the pre-fix bug wrote a marker HERE, exactly where cwd A's own \$PWD-fallback "
     . "resolves, which is why the old design silently disagreed with the Stop check below "
     . "instead of visibly failing");

    my ($stop_rc, $stop_out) = run_hook($GATE, stop_payload($root, $sid),
        env => \%unresolved_env, cwd => $scratch_b);

    is($stop_rc, 0, "L4 ($case->{label}, -> AC10): Stop, from a DIFFERENT cwd B, exits 0");
    is($stop_out, '', "L5 CANONICAL ($case->{label}, -> AC10): Stop's stderr is empty -- fails "
                     . "safe silently, and the two halves never silently disagree because "
                     . "neither one ever had a marker to disagree about");
    ok(!-e "$scratch_b/.claude",
       "L6 ($case->{label}, -> AC10): Stop also created no .claude directory under cwd B");
}

# ===========================================================================
# M. AC4/AC5 -- with the registry RESOLVABLE ($HOME set, stable across the
#    session), a cwd change between ARM and Stop must NOT break the pairing:
#    both invocations resolve to the identical registry root regardless of
#    cwd, and a marker written during ARM IS found during Stop.
# ===========================================================================
for my $case (
    { label => 'drive-solo', payload_fn => \&driver_arm_payload, drive_solo => 1 },
    { label => 'reporter',   payload_fn => \&reporter_arm_payload, drive_solo => 0 },
) {
    my $root      = new_project(drive_solo => $case->{drive_solo});
    my $home      = tempdir(CLEANUP => 1);
    my $scratch_a = tempdir(CLEANUP => 1);
    my $scratch_b = tempdir(CLEANUP => 1);
    my $sid       = "sess-ac45-$case->{label}";

    my %resolvable_env = (HOME => $home, USERPROFILE => undef);

    my ($arm_rc, $arm_out) = run_hook($MARK, $case->{payload_fn}->($root, $sid),
        env => \%resolvable_env, cwd => $scratch_a);
    is($arm_rc, 0, "M1 ($case->{label}, -> AC4/AC5): ARM exits 0 from cwd A with \$HOME resolvable");

    my ($stop_rc, $stop_out) = run_hook($GATE, stop_payload($root, $sid),
        env => \%resolvable_env, cwd => $scratch_b);
    # Expected rc differs by registry, and BOTH values are evidence the marker
    # was actually FOUND (not evidence of an unrelated exit-0 fallthrough):
    #   drive-solo -- new_project() creates .drive-solo/ but writes no
    #     order.json, so gate-drive-loop.sh's own `[ -f "$DS/order.json" ] ||
    #     exit 0` (unrelated to this package) exits 0 immediately AFTER
    #     finding the marker (t/94's own fixture shape).
    #   reporter -- a marker WAS found, so the reporter branch proceeds to ask
    #     bp-runstate.pl whether a pause/finish was ever declared for this
    #     session (it was not, in this fixture) and BLOCKS, exit 2 -- this is
    #     t/143 section B's own pinned behavior for "registered, nothing
    #     declared". A registry MISMATCH (the bug this package fixes) would
    #     instead have found NO marker and exited 0 silently, exactly as
    #     section L's unresolvable-registry case does -- so rc==2 here is
    #     itself the proof the marker was found across the cwd change, not
    #     an unrelated fact about the reporter surface.
    my $expect_rc = $case->{label} eq 'drive-solo' ? 0 : 2;
    is($stop_rc, $expect_rc,
       "M2 ($case->{label}, -> AC4/AC5): Stop, from a DIFFERENT cwd B, engages the "
     . "$case->{label} branch's own marker-found logic (rc $expect_rc) -- proving the marker "
     . "ARM wrote under cwd A was actually located from cwd B, rather than silently missed "
     . "the way an unresolved/mismatched registry would cause (see section L, where the same "
     . "Stop call instead exits 0 with empty stderr because no marker exists)");

    if ($case->{label} eq 'drive-solo') {
        ok(-f "$home/.claude/ccpraxis/.drive-solo-active/$sid",
           'M3 CANONICAL (-> AC4): the marker ARM wrote under $HOME is exactly where the Stop '
         . 'check (via the same bp_drive_active_dir) would look, regardless of either '
         . 'invocation\'s own cwd');
    } else {
        ok(-f "$home/.claude/ccpraxis/.reporter-active/$sid",
           'M4 CANONICAL (-> AC5): the reporter registration ARM wrote under $HOME is exactly '
         . 'where the Stop check (via the same bp_reporter_active_dir) would look, regardless '
         . 'of either invocation\'s own cwd');
    }
}

done_testing();
