#!/usr/bin/env perl
# platform: any
# Package 15-harness-tasks-and-reminder (blueprint almanac-records). Immutable
# oracle for the Tasks-tool guard: ACs G-1..G-6 plus AC-M, per
# specs/15-harness-tasks-and-reminder-spec.md section 4.
#
# guard-tasks-tool.sh and its hooks.json registration DO NOT EXIST YET at the
# time this file is written. Every assertion below is expected to fail for
# exactly that reason (a missing file / an unregistered hook / a script that
# is not yet the guard it should be) -- never a harness bug in this file.
#
# Registration strings are fired through a real "bash <tmp-script>" subprocess
# (functionally identical to "bash -c \"$cmd\"" -- writing the command to a
# file sidesteps re-quoting a string that already contains embedded double
# quotes). This is the house pattern from write-guard.t and GuardHarness.pm:
# every subprocess writes stdout/stderr to real File::Temp files, never an
# in-memory scalar reopen (the Windows "Bad file descriptor" landmine).
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir tempfile);
use File::Spec ();
use Cwd ();
use JSON::PP ();

(my $ALM  = "$Bin/../..") =~ s{\\}{/}g;                 # plugins/almanac
(my $H    = "$ALM/hooks") =~ s{\\}{/}g;
(my $REPO = Cwd::abs_path("$Bin/../../../..") // "$Bin/../../../..") =~ s{\\}{/}g;

my $GUARD_SH = "$H/guard-tasks-tool.sh";
my $HOOKS_JSON = "$H/hooks.json";

# =============================================================================
# G exact (spec 2.1) -- the registration string the implementer must produce
# byte for byte. Kept here as the one authoritative copy this file compares
# hooks.json against; nothing here is inferred from any implementation file.
# =============================================================================
my $G = q{unset BASH_ENV ; f="${CLAUDE_PLUGIN_ROOT}/hooks/guard-tasks-tool.sh" ; [ -f "$f" ] || exit 0 ; bash -n "$f" 2>/dev/null || exit 0 ; exec env -u SHELLOPTS bash "$f"};
my $MATCHER = 'TaskCreate|TaskUpdate|TaskList|TaskGet';

my %VERB = (
    TaskCreate => q{add --title '<task>'},
    TaskUpdate => 'status <id> pending|doing|blocked|done|obsoleted',
    TaskList   => 'list',
    TaskGet    => 'show <id>',
);

sub deny_text {
    my ($tool, $root) = @_;
    return "$tool is disabled here: session tasks vanish with the session. Use the almanac tasklist, which persists.\n"
         . "  perl $root/scripts/almanac-task.pl $VERB{$tool}\n"
         . "Focus it for this session once with: perl $root/scripts/almanac-task.pl focus\n";
}

# ---------------------------------------------------------------------------
# scaffolding
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

# run_registration($cmd, $stdin_raw, %env) -> { rc, out, err }
# Writes $cmd to a temp script and runs it with a real "bash", stdin/stdout/
# stderr all real File::Temp files. %env is overlaid onto %ENV for the call
# only (localized), matching the test contract's scrubbed-environment rule.
sub run_registration {
    my ($cmd, $stdin_raw, %env) = @_;
    my (undef, $script) = tempfile(SUFFIX => '.sh');
    open(my $sfh, '>', $script) or die "cannot write $script: $!";
    print {$sfh} "#!/usr/bin/env bash\n$cmd\n";
    close $sfh;

    my (undef, $in)  = tempfile();
    open(my $ifh, '>:raw', $in) or die "cannot write $in: $!";
    print {$ifh} (defined $stdin_raw ? $stdin_raw : '');
    close $ifh;

    my (undef, $out) = tempfile();
    my (undef, $err) = tempfile();

    local %ENV = %ENV;
    delete $ENV{$_} for grep { /^(?:BP_|CLAUDE_)/ } keys %ENV;
    $ENV{CCPRAXIS_NO_WAKELOCK} = 1;
    for my $k (keys %env) {
        if (defined $env{$k}) { $ENV{$k} = $env{$k} } else { delete $ENV{$k} }
    }

    system(qq{bash "$script" < "$in" > "$out" 2> "$err"});
    my $rc = $? >> 8;
    my $o  = slurp($out) // '';
    my $e  = slurp($err) // '';
    unlink $script, $in, $out, $err;
    return { rc => $rc, out => $o, err => $e };
}

sub fire {
    my ($payload_raw, %env) = @_;
    $env{CLAUDE_PLUGIN_ROOT} //= $ALM;
    return run_registration($G, $payload_raw, %env);
}

sub ev {
    my ($tool, %extra) = @_;
    my $raw = qq({"hook_event_name":"PreToolUse","tool_name":"$tool","tool_input":{}});
    if (%extra) {
        # Build a raw JSON string ourselves (never JSON::PP->canonical, which
        # sorts keys alphabetically and could reorder tool_name after an
        # embedded decoy -- see the Bash/embedded-string case below, which
        # relies on "tool_name" appearing FIRST in the raw bytes).
        my @pairs = (qq("hook_event_name":"PreToolUse"), qq("tool_name":"$tool"), qq("tool_input":{}));
        push @pairs, qq("agent_id":"$extra{agent_id}") if defined $extra{agent_id};
        $raw = '{' . join(',', @pairs) . '}';
    }
    return $raw;
}

# =============================================================================
# G-1 (DC1): hooks.json decodes, exactly one PreToolUse entry for the guard,
# matcher exact, command exact, and the matcher behaves as a Perl regex.
# =============================================================================
{
    ok(-f $HOOKS_JSON, 'hooks.json exists') or diag('cannot continue G-1 without the file');
    my $raw = slurp($HOOKS_JSON);
    my $cfg = defined($raw) ? eval { JSON::PP->new->decode($raw) } : undef;
    ok($cfg, 'hooks.json decodes as JSON') or diag($raw ? "decode failed: $@" : 'file unreadable');

    my @guard_entries;
    if (ref $cfg eq 'HASH') {
        for my $blk (@{ $cfg->{hooks}{PreToolUse} || [] }) {
            my @cmds = map { $_->{command} // '' } @{ $blk->{hooks} || [] };
            push @guard_entries, $blk if grep { /guard-tasks-tool\.sh/ } @cmds;
        }
    }
    is(scalar(@guard_entries), 1, 'G-1: exactly one PreToolUse entry runs guard-tasks-tool.sh');

    if (@guard_entries) {
        my $blk = $guard_entries[0];
        is($blk->{matcher}, $MATCHER, 'G-1: matcher is exactly TaskCreate|TaskUpdate|TaskList|TaskGet');
        is(scalar(@{ $blk->{hooks} || [] }), 1, 'G-1: exactly one hook object');
        is($blk->{hooks}[0]{command}, $G, 'G-1: command equals G byte for byte');
    }

    my $matcher = (@guard_entries) ? $guard_entries[0]{matcher} : $MATCHER;
    my $re_anchored   = qr/^(?:$matcher)$/;
    my $re_unanchored = qr/$matcher/;
    for my $name (qw(TaskCreate TaskUpdate TaskList TaskGet)) {
        ok($name =~ $re_anchored,   "G-1: matcher (anchored) matches $name");
        ok($name =~ $re_unanchored, "G-1: matcher (unanchored) matches $name");
    }
    for my $name (qw(TaskOutput TaskStop Task Agent Bash TodoWrite)) {
        ok($name !~ $re_anchored,   "G-1: matcher (anchored) does not match $name");
        ok($name !~ $re_unanchored, "G-1: matcher (unanchored) does not match $name");
    }
}

# =============================================================================
# G-2 (DC2): behaviour 1, through the registration string G, for each of the
# four tools -- exit 2, exact 3-line stderr, empty stdout. Same with agent_id.
# =============================================================================
for my $tool (qw(TaskCreate TaskUpdate TaskList TaskGet)) {
    my $r = fire(ev($tool));
    is($r->{rc}, 2, "G-2: $tool through G exits 2") or diag("stdout=[$r->{out}] stderr=[$r->{err}]");
    is($r->{err}, deny_text($tool, $ALM), "G-2: $tool denial text is exact");
    is($r->{out}, '', "G-2: $tool denial has empty stdout");
}
{
    my $r = fire(ev('TaskList', agent_id => 'agent-1'));
    is($r->{rc}, 2, 'G-2: TaskList with agent_id present still exits 2');
    is($r->{err}, deny_text('TaskList', $ALM), 'G-2: ...with the same exact denial text');
}

# =============================================================================
# G-3: behaviours 2, 3, 4 -- exit 0, no output.
# =============================================================================
for my $tool (qw(TaskOutput TaskStop Task Agent Bash TodoWrite)) {
    my $r = fire(ev($tool));
    is($r->{rc}, 0, "G-3: $tool through G exits 0") or diag("stderr=[$r->{err}]");
    is($r->{out}, '', "G-3: $tool -- stdout empty");
    is($r->{err}, '', "G-3: $tool -- stderr empty");
}
{
    # Behaviour 3: the outer tool_name is Bash and appears FIRST in the raw
    # bytes; the embedded "tool_name":"TaskCreate" inside tool_input.command
    # is JSON-string-escaped (\"tool_name\") and cannot be the first match.
    my $raw = q({"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo \"tool_name\":\"TaskCreate\""}});
    my $r = fire($raw);
    is($r->{rc}, 0, 'G-3: a Bash payload embedding "tool_name":"TaskCreate" in tool_input.command exits 0');
    is($r->{out}, '', 'G-3: ...stdout empty');
    is($r->{err}, '', 'G-3: ...stderr empty');
}
for my $case (
    ['', 'empty stdin'],
    ['{"tool_name":"Ta', 'truncated JSON'],
    ['not json at all', 'non-JSON'],
) {
    my ($raw, $label) = @$case;
    my $r = fire($raw);
    is($r->{rc}, 0, "G-3: $label exits 0");
    is($r->{out}, '', "G-3: $label -- stdout empty");
    is($r->{err}, '', "G-3: $label -- stderr empty");
}

# =============================================================================
# G-4 (checks: hook-selftest): bash -n, an absent script, empty stdin.
# =============================================================================
{
    my (undef, $err) = tempfile();
    my $rc = system(qq{bash -n "$GUARD_SH" > /dev/null 2> "$err"});
    is($rc >> 8, 0, 'G-4: bash -n passes on guard-tasks-tool.sh') or diag(slurp($err));
    unlink $err;
}
{
    my $empty_root = tempdir(CLEANUP => 1);
    (my $er = $empty_root) =~ s{\\}{/}g;
    my $r = fire(ev('TaskList'), CLAUDE_PLUGIN_ROOT => $er);
    is($r->{rc}, 0, 'G-4: G with CLAUDE_PLUGIN_ROOT pointing at an empty tempdir exits 0');
    is($r->{out}, '', 'G-4: ...no stdout');
    is($r->{err}, '', 'G-4: ...no stderr (fails open, not a deny)');
}
{
    my $r = fire('');
    is($r->{rc}, 0, 'G-4: G with empty stdin exits 0');
}

# =============================================================================
# G-5: a static scan of guard-tasks-tool.sh finds no perl, $(cat, read -d, jq.
# =============================================================================
{
    my $src = slurp($GUARD_SH);
    ok(defined $src, 'G-5: guard-tasks-tool.sh is readable for the static scan')
        or diag('cannot scan a file that does not exist yet');
    if (defined $src) {
        unlike($src, qr/perl/i, 'G-5: no "perl" anywhere in guard-tasks-tool.sh');
        ok(index($src, '$(cat') == -1, 'G-5: no $(cat');
        ok(index($src, 'read -d') == -1, 'G-5: no read -d');
        ok(index(lc($src), 'jq') == -1, 'G-5: no jq');
    }
}

# =============================================================================
# G-6: the pre-existing Edit|Write|MultiEdit|NotebookEdit entry is untouched,
# and every command this package ADDS starts with "unset BASH_ENV ; " with a
# first token that never ends in ".sh".
# =============================================================================
{
    my $raw = slurp($HOOKS_JSON);
    my $cfg = defined($raw) ? eval { JSON::PP->new->decode($raw) } : undef;
    SKIP: {
        skip 'hooks.json does not decode yet', 3 unless ref $cfg eq 'HASH';

        # Package 13 adds a THIRD PreToolUse entry (matcher "Bash") whose
        # command also names guard-almanac-write.sh, so a command-text grep
        # now matches two entries. Count by matcher instead -- the
        # Edit|Write|MultiEdit|NotebookEdit entry itself is still exactly
        # one and byte-identical (asserted below), which is what this
        # criterion is actually pinning.
        my @edit_entries;
        for my $blk (@{ $cfg->{hooks}{PreToolUse} || [] }) {
            push @edit_entries, $blk if ($blk->{matcher} // '') eq 'Edit|Write|MultiEdit|NotebookEdit';
        }
        is(scalar(@edit_entries), 1, 'G-6: exactly one entry has matcher Edit|Write|MultiEdit|NotebookEdit');
        if (@edit_entries) {
            is($edit_entries[0]{matcher}, 'Edit|Write|MultiEdit|NotebookEdit', 'G-6: its matcher is unchanged');
            is(scalar(@{ $edit_entries[0]{hooks} || [] }), 1, 'G-6: still exactly one hook object');
            is($edit_entries[0]{hooks}[0]{command}, '${CLAUDE_PLUGIN_ROOT}/hooks/guard-almanac-write.sh',
               'G-6: its command is unchanged (bare form)');
        }

        my @all_added_cmds;
        for my $event (qw(PreToolUse PostToolUse)) {
            for my $blk (@{ $cfg->{hooks}{$event} || [] }) {
                for my $h (@{ $blk->{hooks} || [] }) {
                    my $c = $h->{command} // '';
                    push @all_added_cmds, $c if $c =~ /guard-tasks-tool\.sh|reminder-chart-tasklist\.pl/;
                }
            }
        }
        ok(scalar(@all_added_cmds) >= 1, 'G-6: at least one added command found to check')
            or diag('no added commands present yet');
        for my $c (@all_added_cmds) {
            like($c, qr/^unset BASH_ENV ; /, "G-6: added command starts with 'unset BASH_ENV ; ': $c");
            my ($first_token) = $c =~ /^unset\s+BASH_ENV\s*;\s*(\S+)/;
            $first_token //= '';
            unlike($first_token, qr/\.sh$/, "G-6: added command's first token does not end in .sh: $first_token");
        }
    }
}

# =============================================================================
# AC-M (DC7): autoMemoryEnabled: false in exactly these two named files.
# =============================================================================
for my $rel (qw(global-config/settings.json plugins/sandbox/container/settings.json)) {
    my $path = "$REPO/$rel";
    ok(-f $path, "AC-M: $rel exists") or next;
    my $raw = slurp($path);
    my $cfg = eval { JSON::PP->new->decode($raw) };
    ok(ref($cfg) eq 'HASH', "AC-M: $rel decodes as JSON") or next;
    ok(exists $cfg->{autoMemoryEnabled}, "AC-M: $rel has a top-level autoMemoryEnabled key");
    my $v = $cfg->{autoMemoryEnabled};
    ok(defined($v) && JSON::PP::is_bool($v), "AC-M: $rel -- autoMemoryEnabled is a JSON boolean")
        or diag('got a non-boolean value: ' . (defined $v ? "$v" : 'undef'));
    ok((defined($v) && JSON::PP::is_bool($v) && !$v), "AC-M: $rel -- autoMemoryEnabled is false");
}

done_testing();
