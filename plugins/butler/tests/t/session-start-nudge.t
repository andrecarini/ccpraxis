#!/usr/bin/env perl
# platform: any
# NEW oracle for never-halt package 12-session-start-nudge
# (specs/12-session-start-nudge-spec.md sec 4, AC-1..AC-18, AC-23). Implements
# Decision 43's N6 (compact) and N1-now (resume): a SessionStart hook that,
# in an armed session, injects one additionalContext line on source=compact
# ("re-read your tasklist") or source=resume ("continue the held work, or
# turn continuity off"). Quiet otherwise; never blocks.
#
# WRITTEN BLIND to any implementation: plugins/butler/hooks/session-start-nudge.sh
# and plugins/butler/scripts/BpHook/SessionStartNudge.pm DO NOT EXIST YET at
# the time this file is written. Every AC below is expected to fail red for
# that reason -- a missing module/file/registration/doc edit -- never for a
# harness crash or a bad assumption of this file's own making.
#
# Expected strings here are written out literally from spec sec 2.2. They
# are never read from the module's own $COMPACT_TEXT/$RESUME_FORMAT
# variables, so a module that encodes the wrong text is caught, not echoed.
#
# AC-25 (done criterion 3, SessionStart additionalContext reaching the model)
# is a citation against the 2.1.282 binary (spec sec 2.1, anchors F1-F8), not
# a runtime test; AC-1 below is the testable half (the exact
# hookEventName:"SessionStart" shape F1/F2 require).
#
# Runs standalone: perl this file
use strict;
use warnings;
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }
use Test::More;
use FindBin qw($Bin);
use Cwd qw(abs_path);
use File::Temp qw(tempdir tempfile);
use JSON::PP ();

use lib "$Bin/../lib";
use GuardHarness;

my $REPO_ROOT = abs_path("$Bin/../../../..");
BAIL_OUT("cannot resolve repo root from $Bin/../../../..") unless defined $REPO_ROOT;

(my $BUTLER_DIR  = "$REPO_ROOT/plugins/butler")        =~ s{\\}{/}g;
(my $SCRIPTS_DIR = "$BUTLER_DIR/scripts")               =~ s{\\}{/}g;
(my $HOOKS_DIR   = "$BUTLER_DIR/hooks")                 =~ s{\\}{/}g;
my $HOOKS_JSON = "$HOOKS_DIR/hooks.json";
my $SHIM_SH    = "$HOOKS_DIR/session-start-nudge.sh";
my $SN_PM      = "$SCRIPTS_DIR/BpHook/SessionStartNudge.pm";
my $DOC        = "$BUTLER_DIR/docs/hook-architecture.md";

my $REAL_BASH_ABS = do { my $p = `bash -c "command -v bash"`; chomp $p; $p };
BAIL_OUT('cannot resolve a real bash on PATH') unless length $REAL_BASH_ABS;
my $REAL_TIMEOUT_ABS = do { my $p = `bash -c "command -v timeout"`; chomp $p; $p };
BAIL_OUT('cannot resolve a real timeout utility on PATH') unless length $REAL_TIMEOUT_ABS;

# ---------------------------------------------------------------------------
# sec 2.2 pinned text, written out literally -- never read from the module.
# ---------------------------------------------------------------------------
my $COMPACT_TEXT = 'Compacted while continuity is armed: re-read your task list, and the ledger of any package you are driving, before the next step.';
my $RESUME_RE = qr/\AResumed at (\d\d):(\d\d) \((\d\d):(\d\d)Z\) while continuity is armed: continue the held work, or turn continuity off with a reason: butler-continuity off --reason '<why>'\z/;

sub resume_text_literal {
    my ($hhmm) = @_; # e.g. "23:59 (23:59Z)"
    return "Resumed at $hhmm while continuity is armed: continue the held work, or turn continuity off with a reason: butler-continuity off --reason '<why>'";
}

# Direct access to BpHook::SessionStartNudge::lines() (AC-2's second half) --
# attempted once, globally; $SN_LOADED stays false (never dies) until the
# module exists.
my $SN_LOADED = eval { require $SN_PM; 1 } ? 1 : 0;

# ---------------------------------------------------------------------------
# payload builder -- spec sec 3's P(src):
# {"hook_event_name":"SessionStart","session_id":"<sid>","source":"<src>","cwd":"<tmp>"}
# ---------------------------------------------------------------------------
sub mk_payload {
    my (%o) = @_;
    return {
        hook_event_name => 'SessionStart',
        session_id      => 'sid-default-0000',
        source          => 'compact',
        cwd             => '/tmp/proj',
        %o,
    };
}

sub sm {
    my ($p, %env) = @_;
    return GuardHarness::run_module('SessionStartNudge', $p, env => \%env);
}

sub decoded_context {
    my ($out) = @_;
    my $d = eval { JSON::PP->new->utf8->decode($out) };
    return undef unless ref $d eq 'HASH' && ref $d->{hookSpecificOutput} eq 'HASH';
    return $d->{hookSpecificOutput};
}

sub hooksjson_template {
    my ($file, $args) = @_;
    $args //= '';
    return qq{unset BASH_ENV ; f="\${CLAUDE_PLUGIN_ROOT}/hooks/$file" ; w="\${CLAUDE_PLUGIN_ROOT}/hooks/run-hook.sh" ; [ -f "\$f" ] && [ -f "\$w" ] || exit 0 ; bash -n "\$f" 2>/dev/null && bash -n "\$w" 2>/dev/null || exit 0 ; exec env -u SHELLOPTS bash "\$f"$args};
}

# ---------------------------------------------------------------------------
# snapshot_dir($root) -- path => "mtime:size" for every regular file under
# $root (AC-13's own, local copy of GuardHarness's internal technique).
# ---------------------------------------------------------------------------
sub snapshot_dir {
    my ($root) = @_;
    my %seen;
    return \%seen unless -d $root;
    my @stack = ($root);
    while (my $d = pop @stack) {
        opendir(my $dh, $d) or next;
        for my $e (readdir $dh) {
            next if $e eq '.' || $e eq '..';
            my $full = "$d/$e";
            if (-d $full) { push @stack, $full; next }
            my @st = stat $full;
            (my $rel = $full) =~ s{\\}{/}g;
            $seen{$rel} = ($st[9] // 0) . ':' . ($st[7] // 0);
        }
        closedir $dh;
    }
    return \%seen;
}

# ---------------------------------------------------------------------------
# run_cmd_stdin($cmd, $payload_json, %env) -- AC-16's subprocess helper: a
# real `bash -c "<cmd>"` with the given stdin bytes, bounded by the real
# "timeout" utility, %env applied over an otherwise-empty env (caller sets
# BUTLER_STATE_DIR/CCPRAXIS_DATA_DIR/HOME/CLAUDE_PLUGIN_ROOT explicitly).
# ---------------------------------------------------------------------------
sub run_cmd_stdin {
    my ($cmd, $payload_json, %env) = @_;
    local %ENV = %ENV;
    delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
    $ENV{CCPRAXIS_NO_WAKELOCK} = 1;
    for my $k (keys %env) {
        if (defined $env{$k}) { $ENV{$k} = $env{$k} } else { delete $ENV{$k} }
    }
    my (undef, $stdin_path) = tempfile();
    open(my $sfh, '>:raw', $stdin_path) or die "write $stdin_path: $!";
    print {$sfh} $payload_json;
    close $sfh;
    my (undef, $out_path) = tempfile();
    my (undef, $err_path) = tempfile();

    open(local *OLDIN,  '<&', \*STDIN)  or die "dup STDIN: $!";
    open(local *OLDOUT, '>&', \*STDOUT) or die "dup STDOUT: $!";
    open(local *OLDERR, '>&', \*STDERR) or die "dup STDERR: $!";
    open(STDIN,  '<:raw', $stdin_path) or die "redirect STDIN: $!";
    open(STDOUT, '>:raw', $out_path)   or die "redirect STDOUT: $!";
    open(STDERR, '>:raw', $err_path)   or die "redirect STDERR: $!";

    system($REAL_TIMEOUT_ABS, 15, $REAL_BASH_ABS, '-c', $cmd);
    my $rc = ($? == -1) ? -1 : ($? >> 8);

    open(STDIN,  '<&', \*OLDIN)  or die "restore STDIN: $!";
    open(STDOUT, '>&', \*OLDOUT) or die "restore STDOUT: $!";
    open(STDERR, '>&', \*OLDERR) or die "restore STDERR: $!";

    my $out = GuardHarness::read_bytes($out_path);
    my $err = GuardHarness::read_bytes($err_path);
    unlink $stdin_path, $out_path, $err_path;
    return { rc => $rc, out => $out, err => $err };
}

sub find_session_start_commands {
    my ($doc) = @_;
    my @out;
    return @out unless ref $doc eq 'HASH' && ref $doc->{hooks} eq 'HASH';
    for my $group (@{ $doc->{hooks}{SessionStart} // [] }) {
        next unless ref $group eq 'HASH';
        for my $h (@{ $group->{hooks} // [] }) {
            next unless ref $h eq 'HASH' && defined $h->{command};
            push @out, $h->{command};
        }
    }
    return @out;
}

# ===========================================================================
# AC-1: B1. Armed, P(compact) -> rc 0, stderr empty, stdout exactly one
# line, exact decoded structure, additionalContext byte-equal to
# COMPACT_TEXT.
# ===========================================================================
{
    local %ENV = %ENV;
    GuardHarness::fresh_state();
    my $sid = 'sidac0001aaaa';
    GuardHarness::arm($sid, 'driver');
    my $p = mk_payload(session_id => $sid, source => 'compact');
    my $res = sm($p);
    is($res->{rc}, 0, 'AC-1: armed P(compact) -> rc 0');
    is($res->{err}, '', 'AC-1: stderr empty');
    my $nl_count = () = ($res->{out} =~ /\n/g);
    is($nl_count, 1, 'AC-1: stdout is exactly one line terminated by \n');
    my $decoded = eval { JSON::PP->new->utf8->decode($res->{out}) };
    is(ref $decoded, 'HASH', 'AC-1: stdout decodes as a JSON object') or diag("stdout: [$res->{out}]");
    SKIP: {
        skip 'AC-1: stdout did not decode', 5 unless ref $decoded eq 'HASH';
        is_deeply([ sort keys %$decoded ], ['hookSpecificOutput'],
            'AC-1: top-level keys are exactly hookSpecificOutput');
        my $hso = $decoded->{hookSpecificOutput};
        is(ref $hso, 'HASH', 'AC-1: hookSpecificOutput is an object');
        SKIP: {
            skip 'AC-1: hookSpecificOutput is not an object', 3 unless ref $hso eq 'HASH';
            is_deeply([ sort keys %$hso ], ['additionalContext', 'hookEventName'],
                'AC-1: inner keys are exactly hookEventName, additionalContext');
            is($hso->{hookEventName}, 'SessionStart', 'AC-1: hookEventName is SessionStart');
            is($hso->{additionalContext}, $COMPACT_TEXT,
                'AC-1: additionalContext is byte-equal to COMPACT_TEXT');
        }
    }
}

# ===========================================================================
# AC-2: B2. Armed, P(resume) -> the resume regex matches, its UTC HH:MM
# equals gmtime of an epoch taken just before or just after the call. Also
# lines($p, 1790212345) equals the literal resume text built with
# BpHook::local_utc_hhmm(1790212345).
# ===========================================================================
{
    local %ENV = %ENV;
    GuardHarness::fresh_state();
    my $sid = 'sidac0002aaaa';
    GuardHarness::arm($sid, 'manual');
    my $p = mk_payload(session_id => $sid, source => 'resume');
    my $before = time();
    my $res = sm($p);
    my $after = time();
    is($res->{rc}, 0, 'AC-2: armed P(resume) -> rc 0');
    my $hso = decoded_context($res->{out});
    my $ctx = ref $hso eq 'HASH' ? $hso->{additionalContext} : undef;
    like(defined $ctx ? $ctx : '', $RESUME_RE, 'AC-2: additionalContext matches the sec 2.2 resume regex')
        or diag("stdout: [$res->{out}]");
    SKIP: {
        skip 'AC-2: resume regex did not match, cannot cross-check the UTC time', 1
            unless defined $ctx && $ctx =~ $RESUME_RE;
        my ($uh, $um) = ($3, $4);
        my @gb = gmtime($before);
        my @ga = gmtime($after);
        my $wants_before = sprintf('%02d:%02d', $gb[2], $gb[1]);
        my $wants_after   = sprintf('%02d:%02d', $ga[2], $ga[1]);
        my $got = "$uh:$um";
        ok($got eq $wants_before || $got eq $wants_after,
            "AC-2: resume UTC HH:MM ($got) equals gmtime just before ($wants_before) or just after ($wants_after) the call");
    }

    SKIP: {
        skip 'AC-2: BpHook::SessionStartNudge is not requirable -- direct lines() check cannot run', 1
            unless $SN_LOADED;
        my @l = eval { BpHook::SessionStartNudge::lines($p, 1790212345) };
        my $expected = resume_text_literal(BpHook::local_utc_hhmm(1790212345));
        is_deeply(\@l, [$expected],
            'AC-2: lines($p, 1790212345) equals the literal resume text built with BpHook::local_utc_hhmm(1790212345)')
            or diag("got: " . JSON::PP->new->canonical->encode(\@l));
    }
}

# ===========================================================================
# AC-3: B3. AC-1/AC-2 pass for roles manual, driver, reporter, with
# seconds_since_last_response/model present too.
# ===========================================================================
for my $role (qw(manual driver reporter)) {
    local %ENV = %ENV;
    GuardHarness::fresh_state();
    my $sid = "sidac0003$role";
    GuardHarness::arm($sid, $role);
    for my $src (qw(compact resume)) {
        my $p = mk_payload(session_id => $sid, source => $src,
            seconds_since_last_response => 42, model => 'claude-x', agent_type => 'main');
        my $res = sm($p);
        is($res->{rc}, 0, "AC-3: role=$role src=$src -> rc 0");
        my $hso = decoded_context($res->{out});
        my $ctx = ref $hso eq 'HASH' ? $hso->{additionalContext} : undef;
        if ($src eq 'compact') {
            is($ctx, $COMPACT_TEXT, "AC-3: role=$role compact additionalContext exact");
        } else {
            like(defined $ctx ? $ctx : '', $RESUME_RE, "AC-3: role=$role resume additionalContext matches regex");
        }
    }
}

# ===========================================================================
# AC-4: every rendered line (COMPACT_TEXT, and a resume line) is ASCII and
# <= 160 characters. Pure string check -- no module call needed.
# ===========================================================================
{
    is(length($COMPACT_TEXT), 129, 'AC-4: COMPACT_TEXT is 129 characters (spec sec 2.2)');
    ok(length($COMPACT_TEXT) <= 160, 'AC-4: COMPACT_TEXT <= 160 characters');
    unlike($COMPACT_TEXT, qr/[^\x00-\x7F]/, 'AC-4: COMPACT_TEXT is ASCII');

    my $resume_rendered = resume_text_literal('23:59 (23:59Z)');
    is(length($resume_rendered), 153, 'AC-4: a rendered resume line is 153 characters (spec sec 2.2)');
    ok(length($resume_rendered) <= 160, 'AC-4: a rendered resume line <= 160 characters');
    unlike($resume_rendered, qr/[^\x00-\x7F]/, 'AC-4: a rendered resume line is ASCII');
}

# ===========================================================================
# AC-5: B4. Unarmed (and other-sid-armed) P(compact)/P(resume) -> quiet.
# ===========================================================================
{
    local %ENV = %ENV;
    GuardHarness::fresh_state();
    for my $src (qw(compact resume)) {
        my $p = mk_payload(session_id => 'sidac0005unarmed', source => $src);
        my $res = sm($p);
        is($res->{rc}, 0, "AC-5: nothing armed, src=$src -> rc 0");
        is($res->{out}, '', "AC-5: nothing armed, src=$src -> empty stdout");
        is($res->{err}, '', "AC-5: nothing armed, src=$src -> empty stderr");
    }
    GuardHarness::arm('sidac0005-other-sid', 'driver');
    for my $src (qw(compact resume)) {
        my $p = mk_payload(session_id => 'sidac0005-not-the-armed-one', source => $src);
        my $res = sm($p);
        is($res->{rc}, 0, "AC-5: a different sid is armed, src=$src -> rc 0");
        is($res->{out}, '', "AC-5: a different sid is armed, src=$src -> empty stdout");
    }
}

# ===========================================================================
# AC-6: B5. Armed, each listed `source` value -> quiet.
# ===========================================================================
{
    local %ENV = %ENV;
    GuardHarness::fresh_state();
    my $sid = 'sidac0006aaaa';
    GuardHarness::arm($sid, 'driver');
    my @bad_sources = (
        ['startup'              => 'startup'],
        ['clear'                => 'clear'],
        ['fork'                 => 'fork'],
        ['empty string'         => ''],
        ['wrong case Compact'   => 'Compact'],
        ['wrong case RESUME'    => 'RESUME'],
        ['a number'             => 5],
        ['an object'            => { x => 1 }],
        ['JSON null'            => undef],
    );
    for my $c (@bad_sources) {
        my ($label, $val) = @$c;
        my $p = mk_payload(session_id => $sid, source => $val);
        my $res = sm($p);
        is($res->{rc}, 0, "AC-6: source is $label -> rc 0");
        is($res->{out}, '', "AC-6: source is $label -> empty stdout");
    }
    my $p_missing = mk_payload(session_id => $sid);
    delete $p_missing->{source};
    my $res_missing = sm($p_missing);
    is($res_missing->{rc}, 0, 'AC-6: source key missing -> rc 0');
    is($res_missing->{out}, '', 'AC-6: source key missing -> empty stdout');
}

# ===========================================================================
# AC-7: B6. Subagent payloads (valid and invalid agent_id) -> quiet.
# ===========================================================================
{
    local %ENV = %ENV;
    GuardHarness::fresh_state();
    my $sid = 'sidac0007aaaa';
    GuardHarness::arm($sid, 'driver');
    for my $c ([ valid => 'a1b2c3' ], [ invalid => '../x' ]) {
        my ($label, $aid) = @$c;
        my $p = mk_payload(session_id => $sid, source => 'compact', agent_id => $aid);
        my $res = sm($p);
        is($res->{rc}, 0, "AC-7: agent_id $label -> rc 0");
        is($res->{out}, '', "AC-7: agent_id $label -> empty stdout");
    }
}

# ===========================================================================
# AC-8: B7. Malformed input -> quiet, rc 0 (in-process by raw string, plus
# the empty-stdin case through the shim).
# ===========================================================================
{
    local %ENV = %ENV;
    GuardHarness::fresh_state();
    my $sid = 'sidac0008aaaa';
    GuardHarness::arm($sid, 'driver');
    my @raw_cases = (
        ['not JSON'       => 'not json at all'],
        ['truncated JSON' => '{"hook_event_name":"SessionStart","session'],
        ['a JSON array'   => '["a","b"]'],
        ['JSON null'      => 'null'],
        ['empty stdin (in-process)' => ''],
    );
    for my $c (@raw_cases) {
        my ($label, $raw) = @$c;
        my $res = GuardHarness::run_module('SessionStartNudge', $raw);
        is($res->{rc}, 0, "AC-8: $label -> rc 0");
        is($res->{out}, '', "AC-8: $label -> empty stdout");
    }
    my $p = mk_payload(session_id => $sid, source => 'compact');
    my $res2 = sm($p, BP_PAYLOAD_TRUNCATED => 1);
    is($res2->{rc}, 0, 'AC-8: a valid armed P(compact) with BP_PAYLOAD_TRUNCATED=1 -> rc 0');
    is($res2->{out}, '', 'AC-8: ...-> empty stdout');

    my $wres = GuardHarness::run_wrapper('session-start-nudge', '');
    is($wres->{rc}, 0, 'AC-8: empty stdin through the real shim -> rc 0');
    is($wres->{out}, '', 'AC-8: ...-> empty stdout');
}

# ===========================================================================
# AC-9: B8. Armed P(compact) with hook_event_name missing, or set to
# UserPromptSubmit -> quiet.
# ===========================================================================
{
    local %ENV = %ENV;
    GuardHarness::fresh_state();
    my $sid = 'sidac0009aaaa';
    GuardHarness::arm($sid, 'driver');
    my $p1 = mk_payload(session_id => $sid, source => 'compact');
    delete $p1->{hook_event_name};
    my $res1 = sm($p1);
    is($res1->{rc}, 0, 'AC-9: hook_event_name missing -> rc 0');
    is($res1->{out}, '', 'AC-9: hook_event_name missing -> empty stdout');

    my $p2 = mk_payload(session_id => $sid, source => 'compact', hook_event_name => 'UserPromptSubmit');
    my $res2 = sm($p2);
    is($res2->{rc}, 0, 'AC-9: hook_event_name is UserPromptSubmit -> rc 0');
    is($res2->{out}, '', 'AC-9: hook_event_name is UserPromptSubmit -> empty stdout');
}

# ===========================================================================
# AC-10: B9. BP_LEDGER set (with or without BP_ROLE=harvest-judge) -> quiet.
# ===========================================================================
{
    local %ENV = %ENV;
    GuardHarness::fresh_state();
    my $sid = 'sidac0010aaaa';
    GuardHarness::arm($sid, 'driver');
    my $p = mk_payload(session_id => $sid, source => 'compact');
    for my $role_variant (undef, 'harvest-judge') {
        my %env = (BP_LEDGER => '/tmp/some/ledger.md');
        $env{BP_ROLE} = $role_variant if defined $role_variant;
        my $res = sm($p, %env);
        my $label = defined $role_variant ? "BP_ROLE=$role_variant" : 'no BP_ROLE';
        is($res->{rc}, 0, "AC-10: BP_LEDGER set, $label -> rc 0");
        is($res->{out}, '', "AC-10: BP_LEDGER set, $label -> empty stdout");
    }
}

# ===========================================================================
# AC-11: B10. session_id missing, empty, or failing the sid regex -> quiet.
# ===========================================================================
{
    local %ENV = %ENV;
    GuardHarness::fresh_state();
    for my $c (
        [ missing          => undef ],
        [ 'empty string'   => '' ],
        [ 'too long (129)' => ('a' x 129) ],
        [ 'bad char /'     => 'abc/def' ],
        [ 'bad char space' => 'abc def' ],
    ) {
        my ($label, $sid) = @$c;
        my $p = mk_payload(source => 'compact');
        if (defined $sid) { $p->{session_id} = $sid } else { delete $p->{session_id} }
        my $res = sm($p);
        is($res->{rc}, 0, "AC-11: session_id $label -> rc 0");
        is($res->{out}, '', "AC-11: session_id $label -> empty stdout");
    }
}

# ===========================================================================
# AC-12: B11. is_armed dying -> rc 0, quiet. Relative BUTLER_STATE_DIR ->
# rc 0, quiet.
# ===========================================================================
{
    local %ENV = %ENV;
    GuardHarness::fresh_state();
    my $sid = 'sidac0012aaaa';
    GuardHarness::arm($sid, 'driver');
    my $p = mk_payload(session_id => $sid, source => 'compact');
    {
        no strict 'refs';
        no warnings 'redefine';
        local *BpHook::is_armed = sub { die "AC-12 deliberate die from is_armed\n" };
        my $res = sm($p);
        is($res->{rc}, 0, 'AC-12: BpHook::is_armed dying -> rc 0');
        is($res->{out}, '', 'AC-12: BpHook::is_armed dying -> empty stdout');
        is($res->{err}, '', 'AC-12: BpHook::is_armed dying -> empty stderr');
    }
    my $res2 = sm($p, BUTLER_STATE_DIR => 'relative/not/absolute/path');
    is($res2->{rc}, 0, 'AC-12: relative BUTLER_STATE_DIR -> rc 0');
    is($res2->{out}, '', 'AC-12: relative BUTLER_STATE_DIR -> empty stdout');
}

# ===========================================================================
# AC-13: B12. State-root snapshot byte-identical before/after armed compact
# and resume runs. parse_delta is 0 on every in-process run.
# ===========================================================================
{
    local %ENV = %ENV;
    my $state_root = GuardHarness::fresh_state();
    my $sid = 'sidac0013aaaa';
    GuardHarness::arm($sid, 'driver');

    my $p_compact = mk_payload(session_id => $sid, source => 'compact');
    my $before1 = snapshot_dir($state_root);
    my $res1 = sm($p_compact);
    my $after1 = snapshot_dir($state_root);
    is_deeply($after1, $before1, 'AC-13: state-root snapshot unchanged after an armed compact run');
    is($res1->{parse_delta}, 0, 'AC-13: parse_delta is 0 for the compact run');

    my $p_resume = mk_payload(session_id => $sid, source => 'resume');
    my $before2 = snapshot_dir($state_root);
    my $res2 = sm($p_resume);
    my $after2 = snapshot_dir($state_root);
    is_deeply($after2, $before2, 'AC-13: state-root snapshot unchanged after an armed resume run');
    is($res2->{parse_delta}, 0, 'AC-13: parse_delta is 0 for the resume run');
}

# ===========================================================================
# AC-14: B13. Through the real shim: armed P(compact) -> AC-1's line.
# Unarmed -> quiet. Empty stdin -> rc 0, stdout empty.
# ===========================================================================
{
    local %ENV = %ENV;
    GuardHarness::fresh_state();
    my $sid = 'sidac0014aaaa';
    GuardHarness::arm($sid, 'driver');
    my $p = mk_payload(session_id => $sid, source => 'compact');
    my $wres = GuardHarness::run_wrapper('session-start-nudge', $p);
    is($wres->{rc}, 0, 'AC-14: armed P(compact) through the shim -> rc 0');
    my $hso = decoded_context($wres->{out});
    is(ref $hso eq 'HASH' ? $hso->{additionalContext} : undef, $COMPACT_TEXT,
        'AC-14: shim stdout additionalContext equals COMPACT_TEXT')
        or diag("stdout: [$wres->{out}]");

    my $p2 = mk_payload(session_id => 'sidac0014-unarmed', source => 'compact');
    my $wres2 = GuardHarness::run_wrapper('session-start-nudge', $p2);
    is($wres2->{rc}, 0, 'AC-14: unarmed through the shim -> rc 0');
    is($wres2->{out}, '', 'AC-14: unarmed through the shim -> empty stdout');

    my $wres3 = GuardHarness::run_wrapper('session-start-nudge', '');
    is($wres3->{rc}, 0, 'AC-14: empty stdin through the shim -> rc 0');
    is($wres3->{out}, '', 'AC-14: empty stdin through the shim -> empty stdout');
}

# ===========================================================================
# AC-15: B14. PATH-shim process budget: 0 perl unarmed, 1 perl armed.
# ===========================================================================
{
    local %ENV = %ENV;
    GuardHarness::fresh_state();
    my $p_unarmed = mk_payload(session_id => 'sidac0015-unarmed', source => 'compact');
    my $sres1 = GuardHarness::run_shim('session-start-nudge', $p_unarmed);
    is($sres1->{rc}, 0, 'AC-15: unarmed P(compact) through the shim -> rc 0');
    is(GuardHarness::count_lines($sres1->{shim_log}, 'perl'), 0,
        'AC-15: unarmed P(compact) launches 0 perl');

    my $sid = 'sidac0015-armed';
    GuardHarness::arm($sid, 'driver');
    my $p_armed = mk_payload(session_id => $sid, source => 'compact');
    my $sres2 = GuardHarness::run_shim('session-start-nudge', $p_armed);
    is($sres2->{rc}, 0, 'AC-15: armed P(compact) through the shim -> rc 0');
    is(GuardHarness::count_lines($sres2->{shim_log}, 'perl'), 1,
        'AC-15: armed P(compact) launches exactly 1 perl');
}

# ===========================================================================
# AC-16: B15. Coexistence -- run both registered SessionStart commands from
# the real hooks.json together, with CLAUDE_PLUGIN_ROOT set to the real
# plugin dir, an armed-driver P(compact) payload, and temp
# BUTLER_STATE_DIR/CCPRAXIS_DATA_DIR/HOME. Both exit 0. Combined stdout is
# exactly one line, AC-1's, coming from the session-start-nudge.sh command;
# denial-breaker.sh's stdout is empty.
# ===========================================================================
{
    my $tmp = tempdir(CLEANUP => 1);
    (my $ttmp = $tmp) =~ s{\\}{/}g;
    my $state_dir = "$ttmp/state";
    my $data_dir  = "$ttmp/data";
    my $home_dir  = "$ttmp/home";
    mkdir $home_dir;

    my %base_env = (
        BUTLER_STATE_DIR  => $state_dir,
        CCPRAXIS_DATA_DIR => $data_dir,
        HOME              => $home_dir,
        USERPROFILE       => $home_dir,
        CLAUDE_PLUGIN_ROOT => $BUTLER_DIR,
    );

    {
        local %ENV = %ENV;
        $ENV{$_} = $base_env{$_} for keys %base_env;
        BpHook::arm('sidac0016aaaa', role => 'driver', by => 'arm-on-entry');
    }
    my $sid = 'sidac0016aaaa';

    my $payload_json = JSON::PP->new->utf8->canonical->encode(mk_payload(session_id => $sid, source => 'compact'));

    my $hooks_raw = GuardHarness::read_bytes($HOOKS_JSON);
    my $hooks_doc = eval { JSON::PP->new->utf8->decode($hooks_raw) };
    ok(ref $hooks_doc eq 'HASH', 'AC-16 precondition: hooks.json decodes') or diag($@);
    my @cmds = find_session_start_commands($hooks_doc);

    my (@outs, @errs, @rcs);
    for my $cmd (@cmds) {
        my $res = run_cmd_stdin($cmd, $payload_json, %base_env);
        push @outs, $res->{out};
        push @errs, $res->{err};
        push @rcs, $res->{rc};
    }
    ok((!grep { $_ != 0 } @rcs), 'AC-16: every registered SessionStart command exits 0')
        or diag('rcs: ' . join(',', @rcs));
    my $combined = join('', @outs);
    my $nl_count = () = ($combined =~ /\n/g);
    is($nl_count, 1, 'AC-16: combined stdout across both SessionStart commands is exactly one line')
        or diag('combined: [' . $combined . ']');

    my $nudge_idx;
    for my $i (0 .. $#cmds) {
        $nudge_idx = $i if index($cmds[$i], 'session-start-nudge.sh') >= 0;
    }
    SKIP: {
        skip 'AC-16: no session-start-nudge.sh command is registered in hooks.json yet', 2
            unless defined $nudge_idx;
        my $hso = decoded_context($outs[$nudge_idx]);
        is(ref $hso eq 'HASH' ? $hso->{additionalContext} : undef, $COMPACT_TEXT,
            "AC-16: the session-start-nudge.sh command's own stdout is AC-1's line");
        my @other_outs = @outs[ grep { $_ != $nudge_idx } 0 .. $#outs ];
        ok((!grep { length $_ } @other_outs), "AC-16: every other registered SessionStart command's stdout is empty (denial-breaker.sh)");
    }
}

# ===========================================================================
# AC-17: session-start-nudge.sh passes bash -n. Its last non-empty line
# equals the sec 2.3 pinned line exactly.
# ===========================================================================
{
    ok(-f $SHIM_SH, 'AC-17: plugins/butler/hooks/session-start-nudge.sh exists');
    SKIP: {
        skip 'AC-17: session-start-nudge.sh does not exist yet -- cannot check its syntax or content', 2
            unless -f $SHIM_SH;
        system($REAL_BASH_ABS, '-n', $SHIM_SH);
        my $rc = ($? == -1) ? -1 : ($? >> 8);
        is($rc, 0, 'AC-17: bash -n on session-start-nudge.sh passes');
        my @lines = grep { length } split /\n/, GuardHarness::read_bytes($SHIM_SH);
        my $last = @lines ? $lines[-1] : '';
        is($last, q{exec bash "$d/run-hook.sh" SessionStartNudge --pre armed -- "$@"},
            'AC-17: its last non-empty line equals the sec 2.3 pinned line exactly');
    }
}

# ===========================================================================
# AC-18: hooks.json SessionStart holds exactly two commands: denial-breaker
# then session-start-nudge, each in its own matcher-less group, each the 2.2
# template, timeout 15, type command.
# ===========================================================================
{
    my $hooks_raw = GuardHarness::read_bytes($HOOKS_JSON);
    my $hooks_doc = eval { JSON::PP->new->utf8->decode($hooks_raw) };
    ok(ref $hooks_doc eq 'HASH', 'AC-18 precondition: hooks.json decodes') or diag($@);
    my @groups = (ref $hooks_doc eq 'HASH' && ref $hooks_doc->{hooks} eq 'HASH')
        ? @{ $hooks_doc->{hooks}{SessionStart} // [] } : ();
    is(scalar(@groups), 2, 'AC-18: hooks.json SessionStart array has exactly two groups')
        or diag('found ' . scalar(@groups) . ' groups');

    for my $i (0 .. $#groups) {
        my $g = $groups[$i];
        next unless ref $g eq 'HASH';
        ok(!defined($g->{matcher}) || $g->{matcher} eq '',
            "AC-18: SessionStart group $i has no matcher (matcher-less)");
    }

    my @files = map {
        my $c = (ref $_ eq 'HASH' && ref $_->{hooks} eq 'ARRAY' && @{ $_->{hooks} })
            ? ($_->{hooks}[0]{command} // '') : '';
        my ($f) = $c =~ m{([A-Za-z0-9_.-]+\.sh)};
        $f // '';
    } @groups;
    is_deeply(\@files, ['denial-breaker.sh', 'session-start-nudge.sh'],
        'AC-18: the two groups, in order, name denial-breaker.sh then session-start-nudge.sh')
        or diag('found: ' . join(',', @files));

    for my $g (@groups) {
        next unless ref $g eq 'HASH' && ref $g->{hooks} eq 'ARRAY' && @{ $g->{hooks} };
        my $h = $g->{hooks}[0];
        next unless ref $h eq 'HASH';
        my ($f) = ($h->{command} // '') =~ m{([A-Za-z0-9_.-]+\.sh)};
        next unless defined $f;
        is($h->{timeout}, 15, "AC-18: $f timeout is 15");
        is($h->{type}, 'command', "AC-18: $f type is command");
        is($h->{command}, hooksjson_template($f), "AC-18: $f command equals the sec 2.2 template byte-for-byte");
    }
}

# ===========================================================================
# AC-23: hook-architecture.md no longer contains the stale "No SessionStart
# or SessionEnd hook is registered." sentence; it contains the sec 2.6(6)
# replacement sentence, and "This is 26 hooks.json commands".
# ===========================================================================
{
    ok(-f $DOC, 'AC-23 precondition: hook-architecture.md exists') or BAIL_OUT('hook-architecture.md missing');
    my $text = GuardHarness::read_bytes($DOC);
    unlike($text, qr/No SessionStart or SessionEnd hook is registered\./,
        'AC-23: the stale "No SessionStart or SessionEnd hook is registered." sentence is gone');
    my $replacement = 'Two SessionStart hooks are registered, and neither carries state across a new id: denial-breaker.sh (never-halt 07) moves its own per-agent counting offset, and session-start-nudge.sh (never-halt 12) speaks only on source compact or resume of an armed session, both of which keep the id. No SessionEnd hook is registered.';
    ok((index($text, $replacement) >= 0), 'AC-23: the sec 2.6(6) replacement sentence is present verbatim')
        or diag('doc does not contain the replacement sentence');
    ok((index($text, 'This is 26 hooks.json commands') >= 0),
        'AC-23: the doc\'s count sentence says "This is 26 hooks.json commands"');
}

done_testing();
