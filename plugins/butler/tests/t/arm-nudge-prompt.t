#!/usr/bin/env perl
# platform: any
# ORACLE for never-halt package 11-arming-nudges, N3 and the shared epoch
# marker (DC1, DC2), per
# .ccpraxis-local-data/blueprints/never-halt/specs/11-arming-nudges-spec.md
# sections 2.2-2.4, 3 (B1-B11, B17) and 4 (AC-1..AC-17).
#
# arm-nudge-prompt.sh, its hooks.json UserPromptSubmit registration, and
# BpHook::prompt_marker/last_prompt_epoch/operator_off DO NOT EXIST YET at
# the time this file is written. Every assertion below is expected to fail
# for exactly that reason -- never a harness bug in this file. Calls to the
# three new BpHook subs are routed through safe wrappers (PM/LPE/OPOFF)
# below so an "Undefined subroutine" from the not-yet-written subs turns
# into a plain undef (matched against -f/-defined, i.e. a clean failing
# assertion) instead of crashing this whole file.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use JSON::PP ();
use Cwd ();

use lib "$Bin/../lib";
use GuardHarness ();

(my $BUTLER  = "$Bin/../..") =~ s{\\}{/}g;
(my $HOOKS   = "$BUTLER/hooks") =~ s{\\}{/}g;
my $HOOKS_JSON = "$HOOKS/hooks.json";
my $SHIM_FILE  = "$HOOKS/arm-nudge-prompt.sh";
my $SCRIPTS    = "$BUTLER/scripts";

require "$SCRIPTS/BpHook.pm";

# package 04-continuity-threads (spec 2.8): the nudge now tells the session
# to arm AND ATTACH A THREAD, naming both the --new-thread and --thread forms.
# 04-docs-and-wiring (spec addendum 0, the shell-quoting correction of spec
# 2.10): names --goal, UNQUOTED around the placeholder (no single quotes) --
# a backslash-escaped single quote inside this bash single-quoted string
# would terminate the string early, so the placeholder is left bare, matching
# the existing unquoted-placeholder style of --new-thread <name>.
my $N3_TEXT = 'This prompt suggests unattended work. If this session should keep working '
            . 'without the operator, arm and attach a thread first: butler-continuity on '
            . '--new-thread <name> --goal <what this is for> (or --thread <name>, same --goal, to resume one)';

# ---------------------------------------------------------------------------
# small IO / scaffolding
# ---------------------------------------------------------------------------
sub slurp {
    my ($p) = @_;
    return undef unless defined $p && -f $p;
    open my $fh, '<:raw', $p or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

my $sid_n = 0;
sub fresh_sid { return sprintf('an-%04d-%d', ++$sid_n, time()) }

# PM/LPE/OPOFF -- safe wrappers around the not-yet-written BpHook subs. Each
# returns undef (never dies) when the sub does not exist or itself dies.
sub PM    { my ($sid) = @_; my $r; my $ok = eval { $r = BpHook::prompt_marker($sid); 1 };    return $ok ? $r : undef }
sub LPE   { my ($sid) = @_; my $r; my $ok = eval { $r = BpHook::last_prompt_epoch($sid); 1 }; return $ok ? $r : undef }
sub OPOFF { my ($sid) = @_; my $r; my $ok = eval { $r = BpHook::operator_off($sid); 1 };      return $ok ? $r : undef }

# marker_path($state_base, $sid) -- the spec's own formula
# (<state_dir()>/prompted/<sid>), built directly from the fresh_state() base
# rather than through BpHook::state_dir()/prompt_marker, so this helper
# stays usable even before those exist. $state_base is what
# GuardHarness::fresh_state() (or an equivalent "<tmp>/state" value) returns;
# BpHook::state_dir() appends "/continuity" to it.
sub marker_path { my ($state_base, $sid) = @_; return "$state_base/continuity/prompted/$sid" }

sub armed_dir { my ($state_base) = @_; return "$state_base/continuity/armed" }
sub touch_armed {
    my ($state_base, $sid) = @_;
    my $dir = armed_dir($state_base);
    make_path($dir);
    open(my $fh, '>', "$dir/$sid") or die "cannot touch armed marker: $!";
    close $fh;
}

# ---------------------------------------------------------------------------
# hooks.json: the live UserPromptSubmit command for arm-nudge-prompt.sh (or
# '' when hooks.json carries none -- the correct red state before
# implementation).
# ---------------------------------------------------------------------------
sub current_U {
    my $raw = slurp($HOOKS_JSON);
    my $cfg = defined($raw) ? eval { JSON::PP->new->decode($raw) } : undef;
    return '' unless ref $cfg eq 'HASH';
    for my $blk (@{ $cfg->{hooks}{UserPromptSubmit} || [] }) {
        for my $hk (@{ $blk->{hooks} || [] }) {
            my $c = $hk->{command} // '';
            return $c if $c =~ /arm-nudge-prompt\.sh/;
        }
    }
    return '';
}

sub hooksjson_template {
    my ($file, $args) = @_;
    $args //= '';
    return qq{unset BASH_ENV ; f="\${CLAUDE_PLUGIN_ROOT}/hooks/$file" ; w="\${CLAUDE_PLUGIN_ROOT}/hooks/run-hook.sh" ; [ -f "\$f" ] && [ -f "\$w" ] || exit 0 ; bash -n "\$f" 2>/dev/null && bash -n "\$w" 2>/dev/null || exit 0 ; exec env -u SHELLOPTS bash "\$f"$args};
}

# ---------------------------------------------------------------------------
# payload builders.
# ---------------------------------------------------------------------------
sub encode_payload {
    my ($h) = @_;
    return $h unless ref $h eq 'HASH';
    return JSON::PP->new->utf8->encode($h);
}

sub mkpayload {
    my (%kv) = @_;
    my %p;
    $p{hook_event_name} = $kv{hook_event_name} // 'UserPromptSubmit';
    $p{session_id}      = $kv{sid} if defined $kv{sid};
    $p{transcript_path} = $kv{transcript_path} // '/tmp/transcript.jsonl';
    $p{cwd}             = $kv{cwd} // '/proj';
    $p{permission_mode} = $kv{permission_mode} // 'default';
    $p{prompt}          = $kv{prompt} if exists $kv{prompt};
    $p{agent_id}        = $kv{agent_id} if exists $kv{agent_id};
    return \%p;
}

# ---------------------------------------------------------------------------
# fire_hook($payload, %env) -- runs the live hooks.json UserPromptSubmit
# command (or %env{__cmd} if given) through a real bash subprocess, exactly
# the CR/fire_reminder technique. Returns { rc, out, err }.
# ---------------------------------------------------------------------------
sub fire_hook {
    my ($payload, %env) = @_;
    my $cmd  = delete $env{__cmd} // current_U();
    my $root = $env{CLAUDE_PLUGIN_ROOT} // $BUTLER;

    my (undef, $script) = tempfile(SUFFIX => '.sh');
    open(my $sfh, '>', $script) or die "cannot write $script: $!";
    print {$sfh} "#!/usr/bin/env bash\n$cmd\n";
    close $sfh;

    my (undef, $in) = tempfile();
    open(my $ifh, '>:raw', $in) or die "cannot write $in: $!";
    print {$ifh} encode_payload($payload);
    close $ifh;

    my (undef, $out) = tempfile();
    my (undef, $err) = tempfile();

    local %ENV = %ENV;
    delete $ENV{$_} for grep { /^(?:BP_|CLAUDE_)/ } keys %ENV;
    $ENV{CCPRAXIS_NO_WAKELOCK} = 1;
    $ENV{CLAUDE_PLUGIN_ROOT} = $root;
    for my $k (keys %env) {
        next if $k eq 'CLAUDE_PLUGIN_ROOT';
        if (defined $env{$k}) { $ENV{$k} = $env{$k} } else { delete $ENV{$k} }
    }

    system(qq{bash "$script" < "$in" > "$out" 2> "$err"});
    my $rc = $? >> 8;
    my $o  = slurp($out) // '';
    my $e  = slurp($err) // '';
    unlink $script, $in, $out, $err;
    return { rc => $rc, out => $o, err => $e };
}

# fresh_state_base() -- like GuardHarness::fresh_state(), but returns the
# base path ("<tmp>/state") WITHOUT mutating the live %ENV; callers decide
# whether/how to export it. BUTLER_STATE_DIR's own value is this base path
# (BpHook::state_dir() appends "/continuity").
sub fresh_state_base {
    my $t = tempdir(CLEANUP => 1);
    (my $base = "$t/state") =~ s{\\}{/}g;
    return $base;
}

sub decode_one_line {
    my ($out) = @_;
    return undef unless defined $out && length $out;
    my @lines = grep { length } split /\n/, $out;
    return undef unless @lines == 1;
    return eval { JSON::PP->new->decode($lines[0]) };
}

# assert_nudge_line($out, $label) -- the AC-3 oracle: exactly one stdout
# line decoding to {hookSpecificOutput:{hookEventName:"UserPromptSubmit",
# additionalContext:N3_TEXT}}, top-level key exactly hookSpecificOutput.
sub assert_nudge_line {
    my ($out, $label) = @_;
    my $d = decode_one_line($out);
    ok(ref($d) eq 'HASH', "$label: stdout is exactly one decodable JSON line")
        or diag("stdout=[$out]");
    if (ref($d) eq 'HASH') {
        is_deeply([sort keys %$d], ['hookSpecificOutput'], "$label: the only top-level key is hookSpecificOutput");
        is($d->{hookSpecificOutput}{hookEventName}, 'UserPromptSubmit', "$label: hookEventName is UserPromptSubmit");
        is($d->{hookSpecificOutput}{additionalContext}, $N3_TEXT, "$label: additionalContext is N3_TEXT, byte-exact");
    }
}

# ===========================================================================
# AC-1: hooks.json registration shape.
# ===========================================================================
{
    my $raw = slurp($HOOKS_JSON);
    my $cfg = defined($raw) ? eval { JSON::PP->new->decode($raw) } : undef;
    ok(ref($cfg) eq 'HASH', 'AC-1: hooks.json decodes as an object') or diag($@ // 'unreadable');

    my @hits;
    if (ref $cfg eq 'HASH') {
        for my $blk (@{ $cfg->{hooks}{UserPromptSubmit} || [] }) {
            for my $hk (@{ $blk->{hooks} || [] }) {
                my $c = $hk->{command} // '';
                push @hits, { blk => $blk, hk => $hk } if $c =~ m{/hooks/arm-nudge-prompt\.sh};
            }
        }
    }
    is(scalar(@hits), 1, 'AC-1: exactly one hooks.json command contains /hooks/arm-nudge-prompt.sh');
    SKIP: {
        skip 'AC-1: no matching command to inspect', 3 unless @hits;
        ok(!exists $hits[0]{blk}{matcher}, 'AC-1: its group carries no matcher key');
        is($hits[0]{hk}{command}, hooksjson_template('arm-nudge-prompt.sh', ''),
            'AC-1: its command equals the sec 2.2 template for arm-nudge-prompt.sh with no args');
        is($hits[0]{hk}{timeout}, 15, 'AC-1: its timeout is 15');
    }
}

# ===========================================================================
# AC-2: arm-nudge-prompt.sh is pure bash -- bash -n, and no non-comment line
# names perl or run-hook.sh.
# ===========================================================================
{
    my $rc = system('bash', '-n', $SHIM_FILE) if -f $SHIM_FILE;
    ok(-f $SHIM_FILE, 'AC-2: arm-nudge-prompt.sh exists on disk')
        or diag("missing: $SHIM_FILE (expected until implemented)");
    SKIP: {
        skip 'AC-2: file missing, cannot syntax-check', 1 unless -f $SHIM_FILE;
        $rc = system('bash', '-n', $SHIM_FILE);
        is(($rc == -1 ? -1 : $rc >> 8), 0, 'AC-2: bash -n passes');
    }
    my $src = slurp($SHIM_FILE);
    SKIP: {
        skip 'AC-2: file missing, cannot source-scan', 2 unless defined $src;
        my @bad_perl = grep { !/^\s*#/ && /\bperl\b/ } split /\n/, $src;
        my @bad_rh   = grep { !/^\s*#/ && /run-hook\.sh/ } split /\n/, $src;
        is(scalar(@bad_perl), 0, 'AC-2: no non-comment line matches /\bperl\b/');
        is(scalar(@bad_rh),   0, 'AC-2: no non-comment line matches /run-hook\.sh/');
    }
}

# ===========================================================================
# AC-3 (B1): unarmed, matching operator prompt -> nudge, marker written.
# ===========================================================================
{
    my $sid = fresh_sid();
    my $state = fresh_state_base();
    my $r = fire_hook(mkpayload(sid => $sid, prompt => q{please keep going while I'm away}),
        BUTLER_STATE_DIR => $state);
    is($r->{rc}, 0, 'AC-3: rc 0');
    is($r->{err}, '', 'AC-3: stderr empty');
    assert_nudge_line($r->{out}, 'AC-3');
    ok(-f marker_path($state, $sid), 'AC-3: the marker was written');
}

# ===========================================================================
# AC-4 (B1): every listed phrase, unarmed, gives the AC-3 output.
# ===========================================================================
{
    my @prompts = (
        'Keep going',
        'KEEP WORKING on it',
        'carry on',
        'while im out',
        'while I am asleep',
        q{I'll be back at 6},
        'I will be back',
        'brb, be right back',
        'run it Overnight',
        'this can run unattended',
        q{stay on it until it's done},
        'until you are finished',
    );
    for my $prompt (@prompts) {
        my $sid = fresh_sid();
        my $state = fresh_state_base();
        my $r = fire_hook(mkpayload(sid => $sid, prompt => $prompt), BUTLER_STATE_DIR => $state);
        is($r->{rc}, 0, "AC-4 [$prompt]: rc 0");
        assert_nudge_line($r->{out}, "AC-4 [$prompt]");
    }

    # raw UTF-8 curly apostrophe (E2 80 99)
    {
        my $sid = fresh_sid();
        my $state = fresh_state_base();
        my $prompt_bytes = "I\xe2\x80\x99ll be back";
        my $json = qq({"hook_event_name":"UserPromptSubmit","session_id":"$sid","transcript_path":"/tmp/t.jsonl","cwd":"/proj","permission_mode":"default","prompt":"$prompt_bytes"});
        my $r = fire_hook($json, BUTLER_STATE_DIR => $state);
        is($r->{rc}, 0, 'AC-4 [raw UTF-8 curly apostrophe]: rc 0');
        assert_nudge_line($r->{out}, 'AC-4 [raw UTF-8 curly apostrophe]');
    }

    # JSON-escaped ’
    {
        my $sid = fresh_sid();
        my $state = fresh_state_base();
        my $json = qq({"hook_event_name":"UserPromptSubmit","session_id":"$sid","transcript_path":"/tmp/t.jsonl","cwd":"/proj","permission_mode":"default","prompt":"I\\u2019ll be back"});
        my $r = fire_hook($json, BUTLER_STATE_DIR => $state);
        is($r->{rc}, 0, 'AC-4 [’-escaped]: rc 0');
        assert_nudge_line($r->{out}, 'AC-4 [’-escaped]');
    }

    # JSON \n escape embedded in the prompt
    {
        my $sid = fresh_sid();
        my $state = fresh_state_base();
        my $json = qq({"hook_event_name":"UserPromptSubmit","session_id":"$sid","transcript_path":"/tmp/t.jsonl","cwd":"/proj","permission_mode":"default","prompt":"first line\\nkeep going"});
        my $r = fire_hook($json, BUTLER_STATE_DIR => $state);
        is($r->{rc}, 0, 'AC-4 [embedded \n escape]: rc 0');
        assert_nudge_line($r->{out}, 'AC-4 [embedded \n escape]');
    }
}

# ===========================================================================
# AC-5 (B4/DC1,DC2): non-matching prompts print nothing and still write the
# marker.
# ===========================================================================
{
    my @prompts = (
        'fix the typo',
        'pack my carry-on luggage',
        'two overnights',
        'keeping going',
        'they will still be back',
    );
    for my $prompt (@prompts) {
        my $sid = fresh_sid();
        my $state = fresh_state_base();
        my $r = fire_hook(mkpayload(sid => $sid, prompt => $prompt), BUTLER_STATE_DIR => $state);
        is($r->{rc}, 0, "AC-5 [$prompt]: rc 0");
        is($r->{out}, '', "AC-5 [$prompt]: no stdout");
        ok(-f marker_path($state, $sid), "AC-5 [$prompt]: marker was written");
    }
}

# ===========================================================================
# AC-6 (B2): armed + an AC-3-matching prompt -> no stdout; marker still
# written.
# ===========================================================================
{
    my $sid = fresh_sid();
    my $state = fresh_state_base();
    {
        local %ENV = %ENV;
        $ENV{BUTLER_STATE_DIR} = $state;
        GuardHarness::arm($sid, 'manual');
    }
    my $r = fire_hook(mkpayload(sid => $sid, prompt => q{please keep going while I'm away}),
        BUTLER_STATE_DIR => $state);
    is($r->{rc}, 0, 'AC-6: rc 0');
    is($r->{out}, '', 'AC-6: no stdout when armed');
    ok(-f marker_path($state, $sid), 'AC-6: the marker still exists');
}

# ===========================================================================
# AC-7 (B3): /butler:drive-solo / /drive-solo (with leading whitespace) ->
# no stdout, marker written. A near-miss command name still nudges.
# ===========================================================================
{
    for my $prompt ('/butler:drive-solo never-halt keep going', '  /drive-solo x overnight') {
        my $sid = fresh_sid();
        my $state = fresh_state_base();
        my $r = fire_hook(mkpayload(sid => $sid, prompt => $prompt), BUTLER_STATE_DIR => $state);
        is($r->{rc}, 0, "AC-7 [$prompt]: rc 0");
        is($r->{out}, '', "AC-7 [$prompt]: no stdout (drive-solo arms itself)");
        ok(-f marker_path($state, $sid), "AC-7 [$prompt]: marker was written");
    }
    {
        my $sid = fresh_sid();
        my $state = fresh_state_base();
        my $r = fire_hook(mkpayload(sid => $sid, prompt => '/butler:drive-solos keep going'),
            BUTLER_STATE_DIR => $state);
        is($r->{rc}, 0, 'AC-7 [not the command]: rc 0');
        assert_nudge_line($r->{out}, 'AC-7 [not the command]');
    }
}

# ===========================================================================
# AC-8 (B5): a task-notification prompt (even one containing a phrase) ->
# no stdout, marker untouched (absent stays absent; a pre-existing marker
# stays exactly as it was).
# ===========================================================================
{
    my $sid = fresh_sid();
    my $state = fresh_state_base();
    my $prompt = "<task-notification>\n<task-id>a1</task-id>\n<status>completed</status>\nkeep going\n</task-notification>";
    my $r = fire_hook(mkpayload(sid => $sid, prompt => $prompt), BUTLER_STATE_DIR => $state);
    is($r->{rc}, 0, 'AC-8: rc 0');
    is($r->{out}, '', 'AC-8: no stdout');
    ok(!-f marker_path($state, $sid), 'AC-8: no marker was created');

    my $sid2 = fresh_sid();
    my $state2 = fresh_state_base();
    make_path("$state2/continuity/prompted");
    open(my $fh, '>', marker_path($state2, $sid2)) or die $!;
    print {$fh} "123\n";
    close $fh;
    my $r2 = fire_hook(mkpayload(sid => $sid2, prompt => $prompt), BUTLER_STATE_DIR => $state2);
    is($r2->{out}, '', 'AC-8: a pre-existing marker -- still no stdout');
    is(slurp(marker_path($state2, $sid2)), "123\n", 'AC-8: the pre-existing marker is unchanged');
}

# ===========================================================================
# AC-9 (B6): a payload with agent_id -> no stdout, marker absent.
# ===========================================================================
{
    my $sid = fresh_sid();
    my $state = fresh_state_base();
    my $r = fire_hook(mkpayload(sid => $sid, prompt => 'keep going', agent_id => 'ag1'),
        BUTLER_STATE_DIR => $state);
    is($r->{rc}, 0, 'AC-9: rc 0');
    is($r->{out}, '', 'AC-9: no stdout for a subagent payload');
    ok(!-f marker_path($state, $sid), 'AC-9: no marker was written');
}

# ===========================================================================
# AC-10 (B7): BP_LEDGER set -> no stdout, marker absent.
# ===========================================================================
{
    my $sid = fresh_sid();
    my $state = fresh_state_base();
    my $r = fire_hook(mkpayload(sid => $sid, prompt => 'keep going'),
        BUTLER_STATE_DIR => $state, BP_LEDGER => '/x/ledger.md');
    is($r->{rc}, 0, 'AC-10: rc 0');
    is($r->{out}, '', 'AC-10: no stdout under BP_LEDGER');
    ok(!-f marker_path($state, $sid), 'AC-10: no marker was written');
}

# ===========================================================================
# AC-11 (B8): malformed payloads -> rc 0, empty stdout/stderr, no
# prompted/ file for any sid.
# ===========================================================================
{
    my $sid = fresh_sid();
    my $state = fresh_state_base();

    my @cases = (
        [ 'empty stdin'             => '' ],
        [ 'not json'                => 'not json' ],
        [ 'wrong hook_event_name'   => mkpayload(sid => $sid, prompt => 'keep going', hook_event_name => 'PostToolUse') ],
        [ 'missing session_id'      => mkpayload(prompt => 'keep going') ],
        [ 'invalid session_id'      => mkpayload(sid => 'bad id!', prompt => 'keep going') ],
        [ 'prompt past 4096 chars'  =>
            qq({"hook_event_name":"UserPromptSubmit","session_id":"$sid","transcript_path":")
            . ('x' x 5000)
            . qq(","cwd":"/proj","permission_mode":"default","prompt":"keep going"}) ],
    );
    for my $c (@cases) {
        my ($label, $payload) = @$c;
        my $r = fire_hook($payload, BUTLER_STATE_DIR => $state);
        is($r->{rc}, 0, "AC-11 [$label]: rc 0");
        is($r->{out}, '', "AC-11 [$label]: empty stdout");
        is($r->{err}, '', "AC-11 [$label]: empty stderr");
    }
    ok(!-d "$state/continuity/prompted" || do {
        opendir(my $dh, "$state/continuity/prompted");
        my @f = grep { $_ ne '.' && $_ ne '..' } readdir($dh);
        closedir $dh;
        scalar(@f) == 0;
    }, 'AC-11: no prompted/ file for any sid across every malformed case');
}

# ===========================================================================
# AC-12 (B9): an unresolvable root (relative BUTLER_STATE_DIR) -> rc 0, no
# stdout, and no "prompted" directory anywhere under the temp root.
# ===========================================================================
{
    my $sid = fresh_sid();
    my $root = tempdir(CLEANUP => 1);
    (my $root_n = $root) =~ s{\\}{/}g;
    my $decoy_home = "$root_n/home";
    make_path($decoy_home);

    my $r = fire_hook(mkpayload(sid => $sid, prompt => 'keep going'),
        BUTLER_STATE_DIR => 'relative/dir', HOME => $decoy_home, USERPROFILE => $decoy_home);
    is($r->{rc}, 0, 'AC-12: rc 0 with a relative BUTLER_STATE_DIR');
    is($r->{out}, '', 'AC-12: no stdout');

    my @found;
    my @stack = ($root_n);
    while (my $d = pop @stack) {
        opendir(my $dh, $d) or next;
        for my $e (readdir($dh)) {
            next if $e eq '.' || $e eq '..';
            my $full = "$d/$e";
            if (-d $full) { push @stack, $full; push @found, $full if $e eq 'prompted' }
        }
        closedir $dh;
    }
    is(scalar(@found), 0, 'AC-12: no "prompted" directory exists anywhere under the temp root');
}

# ===========================================================================
# AC-13 (B11): the marker holds the current epoch bracketed by t0/t1, and is
# overwritten (within a fresh bracket) by a later operator prompt.
# ===========================================================================
{
    my $sid = fresh_sid();
    my $state = fresh_state_base();
    my $t0 = time();
    my $r = fire_hook(mkpayload(sid => $sid, prompt => 'nothing special here'), BUTLER_STATE_DIR => $state);
    my $t1 = time();
    my $content = slurp(marker_path($state, $sid));
    like($content, qr/\A\d+\n\z/, 'AC-13: the marker content matches /\A\d+\n\z/')
        or diag(defined $content ? "content=[$content]" : 'marker missing');
    if (defined $content && $content =~ /\A(\d+)\n\z/) {
        my $val = $1;
        ok($val >= $t0 && $val <= $t1, "AC-13: the marker epoch ($val) is within [$t0, $t1]");
    }
    {
        local %ENV = %ENV;
        $ENV{BUTLER_STATE_DIR} = $state;
        is(LPE($sid), (defined $content && $content =~ /\A(\d+)\n\z/ ? $1 : undef),
            'AC-13: BpHook::last_prompt_epoch($sid) returns the same value');
    }

    make_path("$state/continuity/prompted");
    open(my $fh, '>', marker_path($state, $sid)) or die $!;
    print {$fh} "1\n";
    close $fh;
    my $t0b = time();
    fire_hook(mkpayload(sid => $sid, prompt => 'Keep going'), BUTLER_STATE_DIR => $state);
    my $t1b = time();
    my $content2 = slurp(marker_path($state, $sid));
    like($content2, qr/\A\d+\n\z/, 'AC-13: re-running overwrites the marker with a valid epoch');
    if (defined $content2 && $content2 =~ /\A(\d+)\n\z/) {
        my $val2 = $1;
        ok($val2 >= $t0b && $val2 <= $t1b, "AC-13: the overwritten epoch ($val2) is within [$t0b, $t1b]");
    }
}

# ===========================================================================
# AC-14 (B11/DC2): path agreement between the bash shim and
# BpHook::prompt_marker($sid), across all three root sources.
# ===========================================================================
{
    my @scenarios;
    {
        my $root = tempdir(CLEANUP => 1);
        (my $root_n = $root) =~ s{\\}{/}g;
        push @scenarios, {
            label => '(a) BUTLER_STATE_DIR absolute',
            root  => $root_n,
            env   => { BUTLER_STATE_DIR => "$root_n/state" },
        };
    }
    {
        my $root = tempdir(CLEANUP => 1);
        (my $root_n = $root) =~ s{\\}{/}g;
        push @scenarios, {
            label => '(b) BUTLER_STATE_DIR unset, HOME absolute',
            root  => $root_n,
            env   => { BUTLER_STATE_DIR => undef, HOME => "$root_n/home", USERPROFILE => undef },
        };
    }
    {
        my $root = tempdir(CLEANUP => 1);
        (my $root_n = $root) =~ s{\\}{/}g;
        push @scenarios, {
            label => '(c) BUTLER_STATE_DIR unset, HOME relative, USERPROFILE absolute',
            root  => $root_n,
            env   => { BUTLER_STATE_DIR => undef, HOME => 'rel/home', USERPROFILE => "$root_n/userprofile" },
        };
    }

    for my $sc (@scenarios) {
        my $sid = fresh_sid();
        my $r = fire_hook(mkpayload(sid => $sid, prompt => 'fix the typo'), %{ $sc->{env} });
        is($r->{rc}, 0, "AC-14 $sc->{label}: rc 0");

        my $expected;
        {
            local %ENV = %ENV;
            for my $k (keys %{ $sc->{env} }) {
                if (defined $sc->{env}{$k}) { $ENV{$k} = $sc->{env}{$k} } else { delete $ENV{$k} }
            }
            $expected = PM($sid);
        }

        my @found;
        my @stack = ($sc->{root});
        while (my $d = pop @stack) {
            opendir(my $dh, $d) or next;
            for my $e (readdir($dh)) {
                next if $e eq '.' || $e eq '..';
                my $full = "$d/$e";
                if (-d $full) { push @stack, $full }
                elsif ($full =~ m{/prompted/[^/]+\z}) { push @found, $full }
            }
            closedir $dh;
        }
        is(scalar(@found), 1, "AC-14 $sc->{label}: exactly one prompted/<sid> file under the temp root")
            or diag('found: ' . join(', ', @found));
        if (@found == 1 && defined $expected) {
            is($found[0], $expected, "AC-14 $sc->{label}: it is at exactly BpHook::prompt_marker(\$sid)");
        }
    }
}

# ===========================================================================
# AC-15 (DC2): BpHook::prompt_marker / last_prompt_epoch, pure unit checks.
# ===========================================================================
{
    local %ENV = %ENV;
    my $state = fresh_state_base();
    $ENV{BUTLER_STATE_DIR} = $state;

    is(PM('bad id!'), undef, 'AC-15: prompt_marker is undef for an invalid session id');

    {
        local %ENV = %ENV;
        $ENV{BUTLER_STATE_DIR} = 'relative/x';
        is(PM('okid'), undef, 'AC-15: prompt_marker is undef with a relative BUTLER_STATE_DIR');
    }

    is(LPE('missing-sid-xyz'), undef, 'AC-15: last_prompt_epoch is undef for a missing marker');

    for my $case (['', 'empty'], ["abc\n", 'non-numeric'], ["12 34\n", 'embedded space'],
                  ["1234567890123\n", '13 digits (over the 12-digit cap)']) {
        my ($content, $label) = @$case;
        my $sid = fresh_sid();
        make_path("$state/continuity/prompted");
        open(my $fh, '>', marker_path($state, $sid)) or die $!;
        print {$fh} $content;
        close $fh;
        is(LPE($sid), undef, "AC-15: last_prompt_epoch is undef for marker content '$label'");
    }

    for my $case (["1700000000\n", "\\n"], ["1700000000\r\n", "\\r\\n"]) {
        my ($content, $label) = @$case;
        my $sid = fresh_sid();
        make_path("$state/continuity/prompted");
        open(my $fh, '>', marker_path($state, $sid)) or die $!;
        print {$fh} $content;
        close $fh;
        is(LPE($sid), 1700000000, "AC-15: last_prompt_epoch returns 1700000000 for a marker ending in $label");
    }
}

# ===========================================================================
# AC-16 (DC3 precursor): BpHook::operator_off.
# ===========================================================================
{
    local %ENV = %ENV;
    my $state = fresh_state_base();
    $ENV{BUTLER_STATE_DIR} = $state;

    my $sid = fresh_sid();
    is(OPOFF($sid), 0, 'AC-16: operator_off is 0 with no off file');

    BpHook::disarm($sid, actor => 'operator', reason => 'x y');
    is(OPOFF($sid), 1, 'AC-16: operator_off is 1 after disarm(actor=>operator)');

    my $sid2 = fresh_sid();
    BpHook::disarm($sid2, actor => 'agent', reason => 'x y');
    is(OPOFF($sid2), 0, 'AC-16: operator_off is 0 after disarm(actor=>agent)');

    my $sid3 = fresh_sid();
    make_path("$state/continuity/off");
    open(my $fh, '>', "$state/continuity/off/$sid3") or die $!;
    print {$fh} 'not json';
    close $fh;
    is(OPOFF($sid3), 0, 'AC-16: operator_off is 0 for an off file holding non-JSON garbage');
}

# ===========================================================================
# AC-17 (B10): zero perl launches, through GuardHarness::run_shim, for a
# nudging run, an armed run, and a task-notification run. The nudging run's
# stdout is the AC-3 line.
# ===========================================================================
{
    local %ENV = %ENV;
    my $state = GuardHarness::fresh_state();

    my $sid1 = fresh_sid();
    my $res1 = GuardHarness::run_shim('arm-nudge-prompt',
        mkpayload(sid => $sid1, prompt => q{please keep going while I'm away}));
    is($res1->{rc}, 0, 'AC-17 [nudging]: rc 0');
    is(GuardHarness::count_lines($res1->{shim_log}, 'perl'), 0, 'AC-17 [nudging]: zero perl launches');
    assert_nudge_line($res1->{out}, 'AC-17 [nudging]');

    my $sid2 = fresh_sid();
    GuardHarness::arm($sid2, 'manual');
    my $res2 = GuardHarness::run_shim('arm-nudge-prompt',
        mkpayload(sid => $sid2, prompt => q{please keep going while I'm away}));
    is($res2->{rc}, 0, 'AC-17 [armed]: rc 0');
    is(GuardHarness::count_lines($res2->{shim_log}, 'perl'), 0, 'AC-17 [armed]: zero perl launches');

    my $sid3 = fresh_sid();
    my $res3 = GuardHarness::run_shim('arm-nudge-prompt',
        mkpayload(sid => $sid3, prompt => "<task-notification>\nkeep going\n</task-notification>"));
    is($res3->{rc}, 0, 'AC-17 [task-notification]: rc 0');
    is(GuardHarness::count_lines($res3->{shim_log}, 'perl'), 0, 'AC-17 [task-notification]: zero perl launches');
}

done_testing();
