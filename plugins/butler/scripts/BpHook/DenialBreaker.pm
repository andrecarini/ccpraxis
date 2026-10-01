# BpHook::DenialBreaker -- deny-only circuit breaker for never-halt package
# 07 (specs/07-denial-circuit-breaker-spec.md, Decisions 14, 15). One shim
# (denial-breaker.sh) registered on PreToolUse, PostToolUse and
# PostToolUseFailure, no matcher; run() dispatches on hook_event_name.
#
# Counts are never stored: every PreToolUse recomputes consecutive/total
# fresh from package 06's denials.jsonl via
# BpHook::PromptWatch::agent_denial_counts(). The only persisted state per
# agent is a reset-point byte offset into denials.jsonl
# (.drive-solo/denial-breaker/<sid>/<aid>.json, {"reset_offset":N}), plus a
# per-call pending snapshot (.../pending/<tool_use_id>) holding the
# denials.jsonl size at PreToolUse-allow time. PostToolUse/PostToolUseFailure
# advance the reset point to max(current, snapshot) -- never regress it, and
# never erase a denial recorded for a different, parallel tool_use_id.
#
# run($p, @ignored) -> 0 | 2. The whole body runs under eval (fails open on
# any die). Never prints to STDOUT. STDERR is written only on the deny path,
# through one final BpHook::deny(@lines) call. Never emits a permission
# decision of any kind.
package BpHook::DenialBreaker;
use strict;
use warnings;
use JSON::PP ();
use File::Basename qw(dirname);
use Cwd ();

my $SELF_DIR;
{
    my $f = __FILE__;
    $f = Cwd::abs_path($f) // $f;
    $SELF_DIR = dirname($f);
}
require "$SELF_DIR/../BpHook.pm"
    unless grep { m{(?:^|/)BpHook\.pm$} } keys %INC;
require "$SELF_DIR/PromptWatch.pm"
    unless grep { m{(?:^|/)BpHook/PromptWatch\.pm$} } keys %INC;

# ---------------------------------------------------------------------------
# Named constants (sec 2.3) -- the coordination contract for package 08 and
# later packages. Readable as $BpHook::DenialBreaker::NAME after require.
# ---------------------------------------------------------------------------
our $MAX_CONSECUTIVE           = 2;    # trip when consecutive >= this
our $MAX_TOTAL                 = 17;   # trip when total >= this (per session, never resets)
our $AUTO_MODE_MAX_CONSECUTIVE = 3;    # claude.exe fF.maxConsecutive (claude-internals.json auto-mode-denial-limits)
our $AUTO_MODE_MAX_TOTAL       = 20;   # claude.exe fF.maxTotal       (same entry)

# sec 2.7 -- exact, case-sensitive, compared with eq against tool_name.
our @CLASSIFIER_EXEMPT_TOOLS = qw(
    Read Grep Glob
    LSP ToolSearch
    ListMcpResourcesTool ReadMcpResourceTool ReadMcpResourceDirTool RefreshMcpTools WaitForMcpServers
    TodoWrite TaskCreate TaskGet TaskUpdate TaskList GetTask TaskStop
    EnterPlanMode ExitPlanMode ReportFindings ConnectGitHub ShowOnboardingRolePicker
    SubagentHandback
    SendMessage
);
my %EXEMPT = map { ($_ => 1) } @CLASSIFIER_EXEMPT_TOOLS;

my $TUID_RE = qr/\A[A-Za-z0-9_-]{1,128}\z/;

# ---------------------------------------------------------------------------
# small local helpers.
# ---------------------------------------------------------------------------
sub _is_plain_string {
    my ($v) = @_;
    return defined($v) && !ref($v);
}

sub _is_abs {
    my ($p) = @_;
    return 0 unless defined $p && length $p;
    (my $n = $p) =~ s{\\}{/}g;
    return 1 if $n =~ m{^/};
    return 1 if $n =~ m{^[A-Za-z]:/};
    return 0;
}

sub _read_bytes {
    my ($path) = @_;
    open(my $fh, '<:raw', $path) or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

# ---------------------------------------------------------------------------
# state paths (sec 2.5). Directories are created with make_path only when a
# write needs them, never on a read.
# ---------------------------------------------------------------------------
sub _agent_dir    { my ($ds, $sid)        = @_; return "$ds/denial-breaker/$sid" }
sub _mirror_path  { my ($ds, $sid, $aid)  = @_; return _agent_dir($ds, $sid) . "/$aid.json" }
sub _pending_path { my ($ds, $sid, $tid)  = @_; return _agent_dir($ds, $sid) . "/pending/$tid" }
sub _pending_agent_path { my ($ds, $sid, $tid) = @_; return _pending_path($ds, $sid, $tid) . '.aid' }
sub _total_since_path { my ($ds, $sid, $aid) = @_; return _agent_dir($ds, $sid) . "/$aid.total-since.json" }

# _read_mirror($path) -> ($reset_offset, $ok). $ok=1 and offset=0 when the
# file is absent, OR when something other than a regular file exists at the
# path (a directory, say) -- FIX-4 (red-team M4): a directory can never
# self-heal via the Post rename (it always fails), so treating it the same
# as "unreadable" made the abstain PERMANENT for that agent. Folding it into
# the same branch as "missing" instead keeps it in the safe over-count
# direction. $ok=0 (offset undef) only for a shape that genuinely cannot be
# interpreted: unreadable bytes, not a JSON object, or no non-negative-
# integer reset_offset -- those still abstain outright (AC-12).
sub _read_mirror {
    my ($path) = @_;
    return (0, 1) unless -e $path;
    return (0, 1) unless -f $path;
    my $raw = _read_bytes($path);
    return (undef, 0) unless defined $raw;
    my $obj = eval { JSON::PP->new->utf8->decode($raw) };
    return (undef, 0) if $@ || ref $obj ne 'HASH';
    my $ro = $obj->{reset_offset};
    return (undef, 0) unless defined $ro && !ref($ro) && "$ro" =~ /\A\d+\z/;
    return ($ro + 0, 1);
}

sub _write_mirror {
    my ($path, $offset) = @_;
    return eval { BpHook::_write_json_atomic($path, { reset_offset => $offset }) } ? 1 : 0;
}

# _read_total_since($path) -> $offset. Always fails open to 0 (no prior
# SessionStart marker, or an unreadable/corrupt one, both mean "count from
# the start of the file" -- the safe over-count direction, same spirit as
# _read_mirror's missing/directory case). There is no abstain path here: a
# bad total_since marker must never make the breaker stop evaluating.
sub _read_total_since {
    my ($path) = @_;
    return 0 unless -e $path && -f $path;
    my $raw = _read_bytes($path);
    return 0 unless defined $raw;
    my $obj = eval { JSON::PP->new->utf8->decode($raw) };
    return 0 if $@ || ref $obj ne 'HASH';
    my $v = $obj->{total_since};
    return 0 unless defined $v && !ref($v) && "$v" =~ /\A\d+\z/;
    return $v + 0;
}

sub _write_total_since {
    my ($path, $offset) = @_;
    return eval { BpHook::_write_json_atomic($path, { total_since => $offset }) } ? 1 : 0;
}

# _write_pending($ds, $sid, $tid, $snap, $aid) -- FIX-6 (red-team INFO
# hardening): a sibling "<tid>.aid" file records which agent_id the
# snapshot was taken for, so a Post event claiming a DIFFERENT agent_id for
# the same tool_use_id can be told apart from the real Pre that wrote it.
# The main pending file's own content stays exactly "<snap>\n" (AC-1 pins
# its literal shape), so the agent_id lives in the sibling file instead of
# being folded into it.
sub _write_pending {
    my ($ds, $sid, $tid, $snap, $aid) = @_;
    my $path = _pending_path($ds, $sid, $tid);
    my $dir = $path;
    $dir =~ s{/[^/]*\z}{};
    unless (-d $dir) {
        eval { require File::Path; File::Path::make_path($dir) };
    }
    return unless -d $dir;
    open(my $fh, '>:raw', $path) or return;
    print {$fh} "$snap\n";
    close $fh;
    if (defined $aid) {
        if (open(my $afh, '>:raw', _pending_agent_path($ds, $sid, $tid))) {
            print {$afh} "$aid\n";
            close $afh;
        }
    }
    return;
}

# ---------------------------------------------------------------------------
# sec 2.8 -- allow_listed($p): Bash command vs permissions.allow/ask rules.
# ---------------------------------------------------------------------------
sub _read_settings_json {
    my ($path) = @_;
    return undef unless defined $path && -f $path;
    my $raw = _read_bytes($path);
    return undef unless defined $raw;
    return eval { JSON::PP->new->utf8->decode($raw) };
}

sub _rule_files {
    my ($p) = @_;
    my @files;

    my $user;
    my $ccd = $ENV{CLAUDE_CONFIG_DIR};
    if (defined $ccd && length $ccd && _is_abs($ccd)) {
        $user = "$ccd/settings.json";
    }
    else {
        for my $v ($ENV{HOME}, $ENV{USERPROFILE}) {
            next unless defined $v && length $v && _is_abs($v);
            $user = "$v/.claude/settings.json";
            last;
        }
    }
    push @files, $user if defined $user;

    # FIX-5 (red-team L7): CLAUDE_PROJECT_DIR is the only source the real
    # harness ever uses to resolve project-scoped settings for a hook. A
    # payload-controlled cwd must never be trusted as a substitute -- that
    # would let a cwd-controlling agent steer the breaker into honouring a
    # .claude/settings.json the harness itself would never consult.
    my $proj;
    my $cpd = $ENV{CLAUDE_PROJECT_DIR};
    if (defined $cpd && length $cpd && _is_abs($cpd) && -d $cpd) {
        $proj = $cpd;
    }
    if (defined $proj) {
        push @files, "$proj/.claude/settings.json";
        push @files, "$proj/.claude/settings.local.json";
    }
    return @files;
}

sub _collect_rules {
    my ($p) = @_;
    my (@allow, @ask);
    for my $f (_rule_files($p)) {
        my $doc = _read_settings_json($f);
        next unless ref $doc eq 'HASH' && ref $doc->{permissions} eq 'HASH';
        my $a = $doc->{permissions}{allow};
        my $k = $doc->{permissions}{ask};
        push @allow, grep { _is_plain_string($_) } @$a if ref $a eq 'ARRAY';
        push @ask,   grep { _is_plain_string($_) } @$k if ref $k eq 'ARRAY';
    }
    return (\@allow, \@ask);
}

# _has_unescaped_star($body) -> 1 if $body has a '*' preceded by an even
# (including zero) number of backslashes.
sub _has_unescaped_star {
    my ($s) = @_;
    my $i = 0;
    my $n = length($s);
    while ($i < $n) {
        my $c = substr($s, $i, 1);
        if ($c eq '\\') { $i += 2; next }
        return 1 if $c eq '*';
        $i++;
    }
    return 0;
}

# _wildcard_regex($body) -> compiled regex | undef, per F4's order (sec 2.8).
sub _wildcard_regex {
    my ($body) = @_;
    my @tokens;
    my $star_count = 0;
    my $i = 0;
    my $n = length($body);
    while ($i < $n) {
        my $c = substr($body, $i, 1);
        if ($c eq '\\' && $i + 1 < $n) {
            my $nc = substr($body, $i + 1, 1);
            if ($nc eq '*' || $nc eq '\\') {
                push @tokens, ['lit', $nc];
                $i += 2;
                next;
            }
            push @tokens, ['lit', $c];
            $i++;
            next;
        }
        if ($c eq '*') {
            push @tokens, ['star'];
            $star_count++;
            $i++;
            next;
        }
        push @tokens, ['lit', $c];
        $i++;
    }
    return undef unless @tokens;

    my $tail_optional = 0;
    if ($star_count == 1 && @tokens >= 2
        && $tokens[-1][0] eq 'star'
        && $tokens[-2][0] eq 'lit' && $tokens[-2][1] eq ' ')
    {
        $tail_optional = 1;
    }

    my $pat = '';
    my $last = $#tokens;
    my $i2 = 0;
    while ($i2 <= $last) {
        if ($tail_optional && $i2 == $last - 1) {
            $pat .= '(?: .*)?';
            $i2 += 2;
            next;
        }
        my $t = $tokens[$i2];
        if ($t->[0] eq 'lit') { $pat .= quotemeta($t->[1]) }
        else                  { $pat .= '.*' }
        $i2++;
    }
    return eval { qr/\A$pat\z/s };
}

sub _bash_rule_matches {
    my ($rule, $cmd) = @_;
    return 0 unless _is_plain_string($rule);
    return 1 if $rule eq 'Bash' || $rule eq 'Bash(*)';
    return 0 unless $rule =~ /\ABash\((.*)\)\z/s;
    my $body = $1;
    return 0 unless length $body;

    if ($body =~ /\A(.+):\*\z/s) {
        my $prefix = $1;
        return 1 if $cmd eq $prefix;
        return 1 if index($cmd, "$prefix ") == 0;
        return 0;
    }

    if (_has_unescaped_star($body)) {
        my $re = _wildcard_regex($body);
        return (defined $re && $cmd =~ $re) ? 1 : 0;
    }

    return ($cmd eq $body) ? 1 : 0;
}

sub allow_listed {
    my ($p) = @_;
    my $ti = (ref $p eq 'HASH') ? $p->{tool_input} : undef;
    my $cmd = (ref $ti eq 'HASH') ? $ti->{command} : undef;
    return 0 unless _is_plain_string($cmd);
    $cmd =~ s/\A[ \t]+//;
    $cmd =~ s/[ \t]+\z//;
    return 0 if $cmd eq '';
    return 0 if $cmd =~ /[\n\r;&|<>\$()`]/;

    # FIX-1a (reviewer M1 + red-team L5/L6): claude.exe collapses [ \t]+ to
    # one space on BOTH sides before matching an allow/ask rule, but it does
    # NOT normalize the command text when checking an exact (non-wildcard)
    # rule -- so normalizing here and then matching would allow-list a
    # command the harness itself would still send to the classifier. Refuse
    # to match outright instead: any internal whitespace run beyond a
    # single space (a tab, 2+ consecutive spaces, or \x0b/\x0c anywhere)
    # means "not allow-listed", never "match after folding".
    return 0 if $cmd =~ /\t|\x0b|\x0c| {2,}/;

    # FIX-1b: the harness treats a command it cannot parse/tokenize cleanly
    # (an unterminated quote, an escape) as "ask" (sent to the classifier),
    # never silently allow-listed. A quote or a backslash anywhere means the
    # same here.
    return 0 if $cmd =~ /['"\\]/;

    my ($allow, $ask) = _collect_rules($p);

    # FIX-1c: when the effective settings configure ANY ask rule, the
    # harness checks that ask rule against an env-stripped/wrapper-stripped
    # form of the command -- a form this module never computes. Rather than
    # reimplement that stripping (and risk disagreeing with it), refuse to
    # allow-list a command whose first word is a NAME=value env assignment
    # or a known wrapper command: an unstripped match here would be a false
    # allow-list the harness itself would never grant.
    if (@$ask) {
        return 0 if $cmd =~ /\A[A-Za-z_][A-Za-z0-9_]*=/;
        return 0 if $cmd =~ /\A(?:timeout|env)(?:[ \t]|\z)/;
    }

    my $allow_match = 0;
    for my $r (@$allow) {
        if (_bash_rule_matches($r, $cmd)) { $allow_match = 1; last }
    }
    return 0 unless $allow_match;
    for my $r (@$ask) {
        return 0 if _bash_rule_matches($r, $cmd);
    }
    return 1;
}

# ---------------------------------------------------------------------------
# sec 2.9 -- deny messages.
# ---------------------------------------------------------------------------
sub _deny_lines {
    my ($aid, $consec, $total) = @_;
    if ($aid ne 'main') {
        return (
            "denial-breaker: your auto-mode denial budget is nearly exhausted ($consec consecutive, $total total; auto mode stops at $AUTO_MODE_MAX_CONSECUTIVE consecutive or $AUTO_MODE_MAX_TOTAL total).",
            "Stop now and report to the driver what you were doing and what was denied; do not retry this call.",
            "Read, Grep, Glob and allow-listed commands still run. Details: bp-denials summary (bp-denials.pl).",
        );
    }
    my $l2 = ($total < $MAX_TOTAL)
        ? "An allow-listed command (one matching permissions.allow), or a Read, Grep or Glob call, resets the consecutive count; this call was refused before reaching the classifier."
        : "The total never resets in this session: only Read, Grep, Glob and allow-listed commands will run from now on.";
    return (
        "denial-breaker: the next auto-mode classifier block would halt this session behind a permission prompt ($consec consecutive, $total total; the prompt comes at $AUTO_MODE_MAX_CONSECUTIVE consecutive or $AUTO_MODE_MAX_TOTAL total).",
        $l2,
        "Details: bp-denials summary (bp-denials.pl).",
    );
}

# ---------------------------------------------------------------------------
# sec 2.4 -- PreToolUse / PostToolUse / PostToolUseFailure.
# ---------------------------------------------------------------------------
sub _run_pre {
    my ($p, $ds, $sid, $aid, $tid) = @_;
    my $denials_path = "$ds/denials.jsonl";
    my $snap = -s $denials_path;
    $snap = 0 unless defined $snap;

    my $tool = _is_plain_string($p->{tool_name}) ? $p->{tool_name} : undef;
    my $mode = _is_plain_string($p->{permission_mode}) ? $p->{permission_mode} : undef;

    my $total = 0;
    my $consec = 0;
    my $tripped = 0;
    my ($reset_offset, $mirror_ok) = _read_mirror(_mirror_path($ds, $sid, $aid));
    if ($mirror_ok) {
        (undef, $consec) = BpHook::PromptWatch::agent_denial_counts($denials_path, $sid, $aid, $reset_offset);
        # FIX-3 (red-team M2): total is computed relative to a per-(sid,
        # aid) total_since offset, set by SessionStart on a resumed
        # session, exactly the way consec is already computed relative to
        # reset_offset -- never from byte 0 of denials.jsonl unconditionally.
        # No prior SessionStart marker (the common case) means total_since
        # is 0, so this reproduces the old "from byte 0" total unchanged.
        my $total_since = _read_total_since(_total_since_path($ds, $sid, $aid));
        (undef, $total) = BpHook::PromptWatch::agent_denial_counts($denials_path, $sid, $aid, $total_since);
        $tripped = ($consec >= $MAX_CONSECUTIVE || $total >= $MAX_TOTAL) ? 1 : 0;
    }

    if ($tripped) {
        if (defined $tool && $EXEMPT{$tool}) {
            $tripped = 0;
        }
        elsif (defined $tool && $tool eq 'Bash' && allow_listed($p)) {
            $tripped = 0;
        }
    }

    unless ($tripped) {
        # FIX-2 (red-team M1): only a Pre/Post pair taken while
        # permission_mode eq 'auto' may advance the reset point -- the
        # harness's own auto-mode consecutive counter only resets on an
        # allow while actually in auto mode, so recording a pending
        # snapshot in any other mode would let this breaker reset relative
        # to a point the harness itself never resets to.
        _write_pending($ds, $sid, $tid, $snap, $aid)
            if defined $tid && defined $mode && $mode eq 'auto';
        return 0;
    }

    return BpHook::deny(_deny_lines($aid, $consec, $total));
}

sub _run_post {
    my ($ds, $sid, $aid, $tid) = @_;
    return 0 unless defined $tid;
    my $pending_path = _pending_path($ds, $sid, $tid);
    return 0 unless -f $pending_path;

    my $raw = _read_bytes($pending_path);
    unless (defined $raw && $raw =~ /\A(\d+)\n?\z/) {
        unlink $pending_path;
        unlink _pending_agent_path($ds, $sid, $tid);
        return 0;
    }
    my $pending_val = $1 + 0;

    # FIX-6 (red-team INFO hardening): the pending snapshot's own agent_id
    # (written by the Pre that created it) must match THIS Post's agent_id
    # before the reset is applied -- a Post claiming a different agent_id
    # for the same tool_use_id must not consume another agent's snapshot.
    my $agent_path = _pending_agent_path($ds, $sid, $tid);
    my $recorded_aid;
    if (defined(my $araw = _read_bytes($agent_path))) {
        ($recorded_aid) = $araw =~ /\A(.*?)[\r\n]*\z/s;
    }
    unlink $pending_path;
    unlink $agent_path;
    return 0 unless defined $recorded_aid && length($recorded_aid) && $recorded_aid eq $aid;

    my $mirror_path = _mirror_path($ds, $sid, $aid);
    my ($current, $ok) = _read_mirror($mirror_path);
    $current = 0 unless $ok;
    my $new = ($pending_val > $current) ? $pending_val : $current;
    _write_mirror($mirror_path, $new);
    return 0;
}

# _run_session_start($p, $ds, $sid, $aid) -- FIX-3: on a resumed (or freshly
# started) session, record the CURRENT denials.jsonl size as this (sid,
# aid)'s baseline for BOTH counters the harness itself keeps only in
# memory -- consecutive (reset_offset, the same mirror a Pre/Post pair
# already advances) and total (total_since). A fresh process has both
# counters at 0, so denials.jsonl records written before this resume must
# not immediately trip either one. Each write takes the max with whatever
# is already recorded, the same never-regress discipline _run_post already
# uses, so a SessionStart firing late (after real Pre/Post activity) can
# never move a reset point backward. Restricted to source eq
# 'startup'/'resume' per the fix-batch's own scope (harness-facts.md D-1:
# those are the two sources that mean "the harness's own in-memory counters
# are fresh"; 'compact' keeps the same process, and 'clear' already gets a
# brand new session_id with nothing recorded against it yet).
sub _run_session_start {
    my ($p, $ds, $sid, $aid) = @_;
    my $source = _is_plain_string($p->{source}) ? $p->{source} : '';
    return 0 unless $source eq 'startup' || $source eq 'resume';
    my $denials_path = "$ds/denials.jsonl";
    my $snap = -s $denials_path;
    $snap = 0 unless defined $snap;

    my $mirror_path = _mirror_path($ds, $sid, $aid);
    my ($cur_reset, $mirror_ok) = _read_mirror($mirror_path);
    $cur_reset = 0 unless $mirror_ok;
    my $new_reset = ($snap > $cur_reset) ? $snap : $cur_reset;
    _write_mirror($mirror_path, $new_reset);

    my $ts_path = _total_since_path($ds, $sid, $aid);
    my $cur_ts = _read_total_since($ts_path);
    my $new_ts = ($snap > $cur_ts) ? $snap : $cur_ts;
    _write_total_since($ts_path, $new_ts);

    return 0;
}

sub _run_inner {
    my ($p) = @_;
    return 0 unless ref $p eq 'HASH';

    my $ev = $p->{hook_event_name};
    return 0 unless _is_plain_string($ev)
        && ($ev eq 'PreToolUse' || $ev eq 'PostToolUse' || $ev eq 'PostToolUseFailure' || $ev eq 'SessionStart');

    my $mode = $p->{permission_mode};
    return 0 if _is_plain_string($mode) && ($mode eq 'bypassPermissions' || $mode eq 'dontAsk');

    my $ledger = $ENV{BP_LEDGER};
    my $ctx = (defined $ledger && length $ledger) ? 1 : 0;
    $ctx = 1 if !$ctx && defined &BpHook::role && BpHook::role($p) eq 'driver';
    return 0 unless $ctx;

    my $sid = BpHook::session_id($p);
    return 0 unless defined $sid;

    my $aid = BpHook::PromptWatch::agent_key($p);
    return 0 if $aid eq '?';

    my $ds = BpHook::PromptWatch::drive_solo_dir($p);
    return 0 unless defined $ds;

    if ($ev eq 'SessionStart') {
        return _run_session_start($p, $ds, $sid, $aid);
    }

    my $tid = $p->{tool_use_id};
    $tid = undef unless _is_plain_string($tid) && $tid =~ $TUID_RE;

    if ($ev eq 'PreToolUse') {
        return _run_pre($p, $ds, $sid, $aid, $tid);
    }
    return _run_post($ds, $sid, $aid, $tid);
}

sub run {
    my ($p, @ignored) = @_;
    my $ret = eval { _run_inner($p) };
    return (defined $ret && "$ret" eq '2') ? 2 : 0;
}

1;
