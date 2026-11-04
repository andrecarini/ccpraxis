# BpHook::StopGate -- the one Stop gate (package 06 of blueprint
# hook-continuity-remake). Logic behind hooks/next/stop-gate.sh.
#
# Contract: .ccpraxis-local-data/blueprints/hook-continuity-remake/specs/
# 06-stop-gate-spec.md. Architecture: plugins/butler/docs/hook-architecture.md
# ("Stop gate denial text", "Holder protocol", "Command binding", "Guard
# message budgets"). Additive only (Decision 19): nothing here is
# registered; package 16 registers stop-gate.sh.
#
# run($p) never calls exit and uses only BpHook's documented API plus core
# perl. It never spawns a process, except that a break-glass `off` files one
# bug report through BpHook::file_stop_bug (a single almanac-bug.pl child,
# bounded at 10s). Any internal die/exception propagates to BpHook::main,
# which logs it and allows (fail open); a condition this module itself
# treats as an internal failure is reported with warn "stop-gate: ...\n"
# instead of a die, for the same reason.
package BpHook::StopGate;
use strict;
use warnings;
use JSON::PP ();
use File::Basename qw(dirname);
use Cwd ();
use Fcntl qw(:flock);

my $SELF_DIR;
{
    my $f = __FILE__;
    $f = Cwd::abs_path($f) // $f;
    $SELF_DIR = dirname($f);
}
require "$SELF_DIR/../BpHook.pm"
    unless grep { m{(?:^|/)BpHook\.pm$} } keys %INC;
# F4 (red-team M2, package 16 fix-batch): needed so G7 can ensure the
# continuity lease refresher is running for an armed session. A require
# failure here degrades to "no ensure" (G7 wraps the call in eval), never
# to a denial.
eval {
    require "$SELF_DIR/../BpContinuityLease.pm"
        unless grep { m{(?:^|/)BpContinuityLease\.pm$} } keys %INC;
};
# 06-far-pause-session-handoff: far_paused_fleets' only question to
# BpAwakeIntent. A load failure disables far-pause detection -- G11 falls
# back to the RUNNING text, never to a denial of its own.
eval { require "$SELF_DIR/../BpAwakeIntent.pm" unless defined &BpAwakeIntent::want_awake; };

# Break-glass constants (see the BREAK GLASS section below run()).
our $REFUSAL_CAP         = 5;    # consecutive refusals, nothing succeeding, before the gate yields
our $BREAK_GLASS_HINT_AT = 2;    # refusals in a row before the Write-tool escape is offered

# Addendum A (06-far-pause-session-handoff, step 7): the far-pause offer
# record's own constants, `our` so a test reads them instead of hard-coding.
our $FAR_OFFER_TTL          = 1800;          # seconds an offer record stays valid (A.2.1)
our $FAR_RELAUNCH_MAX_AHEAD = 366 * 86400;   # sanity cap on relaunch_at - now
our $FAR_REASON_MAX_BYTES   = 200;           # butler-continuity off's --reason cap

my %BREAK_GLASS_ACTION = (off => 1);
my %SHELL_TOOL         = (Bash => 1, PowerShell => 1);

# ---------------------------------------------------------------------------
# run($p, @args) -> 0 | 2. @args is ignored. Decision table (spec sec 2.3).
# ---------------------------------------------------------------------------
sub run {
    my ($p, @args) = @_;
    $p = {} unless ref $p eq 'HASH';

    # G1: not a Stop event, or a subagent's own Stop/SubagentStop -> allow,
    # no mint, no revoke.
    my $hen = $p->{hook_event_name};
    if (!defined $hen || $hen ne 'Stop' || defined BpHook::agent_id($p)) {
        return 0;
    }

    # G2: no usable session id -> allow.
    my $sid = BpHook::session_id($p);
    return 0 unless defined $sid;

    # G2b: the break-glass file is read BEFORE G3, because it names the token
    # G3 is about to revoke. Always consumed, valid or not, so a stale file can
    # never act on a later stop. Acted on only below, once the session is known
    # to be an armed interactive one.
    my ($bg, $bg_why) = eval { _take_break_glass($sid, $p) };

    # G3: always, once G1/G2 pass -- the previous turn's token dies here.
    BpHook::revoke_stop_token($sid);

    my $role = BpHook::role($p);

    # G4: coordinator branch (spec sec 2.4).
    return _coordinator($sid, $p) if $role eq 'coordinator';

    # G5: judge -> allow.
    return 0 if $role eq 'judge';

    # G6: not armed -> allow.
    unless (BpHook::is_armed($sid)) {
        eval { _clear_streak($sid) };
        return 0;
    }

    # G6b: a valid break-glass off request (see _take_break_glass) disarms
    # (filing a bug, as emergency-stop does) and lets this stop through.
    if ($bg) {
        eval { _clear_streak($sid) };
        my $bug = eval { BpHook::file_stop_bug(source => 'break-glass-off', session => $sid,
                             actor => 'agent', reason => $bg->{reason}, area => 'butler',
                             cwd => $p->{cwd}) };
        unless (ref $bug eq 'HASH') {    # belt and braces: file_stop_bug never dies
            (my $e = $@ || 'unknown error') =~ s/\r?\n.*\z//s;
            $bug = { id => undef, error => $e, note => "bug report: FAILED ($e)" };
        }
        warn "stop-gate: break-glass off: bug report NOT filed ($bug->{error}); disarming anyway\n"
            unless defined $bug->{id};
        my $text = "$bg->{reason}; $bug->{note}";
        BpHook::disarm($sid, actor => 'agent', reason => "break-glass: $text");
        eval { BpHook::log_reason($sid, 'agent', 'break-glass-off', $text, $p->{cwd}) };
        return 0;
    }

    # G7: armed -- refresh the wake-lock lease's activity marker, and make
    # sure the lease refresher is actually running (F4, red-team M2: the
    # old drive-loop gate's restart-on-Stop step has no successor since the
    # cutover, so nothing else restarts a dead refresher for an armed
    # session). Both are best-effort; neither changes the verdict.
    eval { _touch_armed($sid) };
    eval { _ensure_lease_daemon() };

    # G7b (spec 38 sec 2.3): the running-work snapshot describes only the
    # latest Stop; every armed interactive Stop drops the previous one
    # before deciding. A failed unlink leaves at worst a stale snapshot
    # (harmless: nothing reads it to decide a stop), never a
    # changed verdict.
    eval { BpHook::clear_running_snapshot($sid) };

    # Addendum A (06-far-pause-session-handoff, step 7): every armed
    # interactive Stop also sweeps this session's own far-pause offer record
    # (a new far branch below writes a fresh one after this point) and any
    # other session's expired one, immediately after the running-work
    # snapshot is cleared and before G8 decides the stop. Best-effort: never
    # changes the verdict.
    eval { _clear_far_offers($sid, $p, time()) };

    # G8: a live own holder allows.
    if (BpHook::holder_live($sid, $p)) {
        eval { _clear_streak($sid) };
        return 0;
    }

    # G8b: a holder still starting allows too (bug 20261027-201709-afa0). A
    # butler-hold launched in the background takes seconds to write the
    # record G8 reads, and a Stop inside that window used to list the holder
    # as running work and suggest holding it, which butler-hold refuses
    # ("a holder cannot hold itself"). The starting holder either becomes the
    # holder or exits, and its exit wakes the session, so nothing is left
    # unwatched by letting this stop through.
    my $launches = eval { BpHook::holder_launches($p) } || {};
    if (defined(my $starting = BpHook::starting_holder($p, $launches))) {
        eval { _clear_streak($sid) };
        eval { BpHook::log_reason($sid, 'gate', 'holder-starting', $starting, $p->{cwd}) };
        return 0;
    }

    # G9b: THE REFUSAL CAP (bug 20261021-202419-bf19). Every escape above is a
    # shell command; a session whose shell is broken (a PreToolUse hook that
    # errors on every call, say) cannot run any of them, and was refused more
    # than a hundred times in a row before a human noticed. So this stop would
    # be the Nth consecutive refusal with no tool call succeeding in between,
    # the gate stops refusing, and says why in the reasons log and
    # hook-errors.log. Inert without a readable transcript: then there is no
    # way to tell "stuck" from "busy", and the cap must not guess.
    #
    # The cap only yields when the session's most recent shell call failed
    # (operator ruling 2026-10-23, todo 20261023-082209-24290000). Counting
    # bare refusals also let a healthy agent stop for free by ending five
    # turns with text alone, the same effect the removed `silence` had. A
    # broken shell, the case the cap exists for, always leaves a failed call
    # as the last shell result, even when the model has since stopped trying.
    my ($streak, $shell_failed) = eval { _bump_streak($sid, $p) };
    $streak //= 0;
    my $cap_armed = ($streak >= $BREAK_GLASS_HINT_AT || $shell_failed)
        ? (eval { _last_shell_failed($p->{transcript_path}) } || 0) : 0;
    if ($streak >= $REFUSAL_CAP && $cap_armed) {
        eval { _clear_streak($sid) };
        my $why = "refusal cap: $streak consecutive refusals with no tool call succeeding in between";
        eval { BpHook::log_reason($sid, 'gate', 'refusal-cap', $why, $p->{cwd}) };
        warn "stop-gate: $why; letting the stop through (session $sid)\n";
        return 0;
    }

    # G10: token storage failure -> allow, logged via warn (-> hook-errors.log).
    my $t = BpHook::mint_stop_token($sid, $p);
    unless (defined $t) {
        warn "stop-gate: could not store a stop token\n";
        eval { _clear_streak($sid) };
        return 0;
    }

    # The break-glass lines are offered only once the shell paths have visibly
    # failed: a shell tool call errored since the last refusal, or this is not
    # the first refusal in a row with nothing succeeding. A healthy session
    # never sees them, so they cannot become the habitual way out.
    my @glass;
    if ($shell_failed || $streak >= $BREAK_GLASS_HINT_AT || defined $bg_why) {
        my ($path) = _break_glass_paths($sid, $p);
        push @glass, "The break-glass file was not used: $bg_why" if defined $bg_why;
        if (defined $path) {
            push @glass,
                "No shell command can run? Last resort: create this file with the Write tool:",
                "  " . _display_path($path),
                "  containing {\"token\":\"$t\",\"action\":\"off\",\"reason\":\"<what is done>\"}",
                "  (only when all work is done: it turns continuity off and files a bug report).";
            push @glass,
                "After $REFUSAL_CAP refusals in a row with no tool call succeeding, the gate lets the stop through by itself."
                if $cap_armed;
        }
    }

    # G11 (spec 38 sec 2.3, Decision 128): the text is built from the
    # session's running work. While work runs, the RUNNING text names the
    # work and offers hold, or off when it is no longer needed.
    # A butler-hold task is never offered for holding: the holder refuses it.
    my @work = BpHook::running_work($sid, $p, $launches);
    if (@work) {
        eval { BpHook::set_running_snapshot($sid, \@work) };
        my @ids  = map { $_->{id} } @work;
        my @shown = @ids > 8 ? @ids[0 .. 7] : @ids;
        my $more  = @ids > 8 ? ', and ' . (@ids - 8) . ' more' : '';

        # Decision 5/10/14: the session's only running work may be watching a
        # fleet paused beyond the fleet horizon -- then a hold is pointless
        # (it would just re-hold every 50 minutes for days), so offer the
        # off path instead. far_paused_fleets never dies and fails toward
        # today's RUNNING text (undef) rather than toward allowing the stop.
        #
        # Addendum A (step 7): the off is only ever offered once the gate has
        # left a trace of it -- a compact reason that fits butler-continuity
        # off's 200-byte cap, and an offer record under the project data dir
        # the judge can Read by the reason's own offer id (A.2.3). Either
        # step failing (reason too long, record write failing) falls back to
        # today's RUNNING text rather than offering an off the judge would
        # have nothing to check against.
        my $now = time();
        my $far = eval { far_paused_fleets($p, \@work, $now) };
        if (ref $far eq 'ARRAY' && @$far) {
            my $reason = far_pause_reason($t, $far);
            my $ok = defined $reason
                  && eval { _write_far_offer($sid, $p, $t, $reason, $far, $now) };
            if ($ok) {
                my $handoff = join(' ', map {
                    "fleet $_->{name} resumes at " . _fp_ts($_->{relaunch_at})
                        . "; come back with /butler:reporter $_->{name}."
                } @$far);
                my $log_text = join(' ', map { "$_->{name}=$_->{relaunch_at}" } @$far);
                eval { BpHook::log_reason($sid, 'gate', 'far-pause', $log_text, $p->{cwd}) };
                return BpHook::deny(
                    "Continuity is on for this session and its only running work watches a fleet paused beyond the fleet horizon: "
                        . join(', ', @shown) . "$more. Stop token: $t",
                    "Handoff: $handoff",
                    "Do not hold it. Hand off instead: turn continuity off (two steps: off mints an OTP, then off-confirm with it), as a Bash tool call:",
                    "  butler-continuity off --reason '$reason' --token $t",
                    "Once off-confirm succeeds, stop the watcher with the TaskStop tool ("
                        . join(', ', @shown) . "$more): left running, it keeps waking this session.",
                    "End your turn with the Handoff line above.",
                    @glass,
                );
            }
        }
        return BpHook::deny(
            "Continuity is on for this session and work is still running: " . join(', ', @shown) . "$more. Stop token: $t",
            "Hold it, as a background Bash tool call; the holder wakes this session when the work finishes:",
            "  butler-hold --token $t " . join(' ', @shown),
            "If that work is no longer needed and everything is done, turn continuity off, as a Bash tool call:",
            "  butler-continuity off --reason '<what is done>' --token $t",
            # No break-glass offer here. While work runs the way out is a
            # hold (Decision 128), and a session that cannot hold still
            # reaches the refusal cap, or the idle text once the work ends.
        );
    }
    return BpHook::deny(
        "Continuity is on for this session and no holder is running. Stop token: $t",
        "Waiting on a subagent or background task? Hold it, as a background Bash tool call:",
        "  butler-hold --token $t <id> [<id> ...]",
        "All work done? Turn continuity off (two steps: off mints an OTP, then off-confirm with it), as a Bash tool call:",
        "  butler-continuity off --reason '<what is done>' --token $t", "(Genuine ccpraxis/Claude-Code defect, not just finished work? butler-continuity emergency-stop --reason '<the actual defect>' instead -- not a normal option.)",
        @glass,
    );
}

# ---------------------------------------------------------------------------
# far_paused_fleets($p, \@work, $now) -- 06-far-pause-session-handoff,
# amended by Addendum A (step 7, A.2.2).
# -> arrayref of { name, runs, relaunch_at }, sorted by relaunch_at ascending
# then name, ONLY when every work item names a resolvable bp-wait-for-
# escalation watcher, every distinct runs dir among them IS THIS PROJECT'S
# OWN <data_dir>/blueprints/<name>/runs (never an arbitrary --runs/--bp-dir
# elsewhere, never a launch whose command carries its own CCPRAXIS_DATA_DIR=),
# every fleet's relaunch_at is a plain sane integer, and every one of them is
# paused beyond the fleet horizon (BpAwakeIntent::want_awake's handoff, never
# a horizon comparison of this module's own); else undef. Public so a test
# can call it with a fixed clock. Never dies: the whole body is wrapped in
# eval, which also makes a BpAwakeIntent load failure (want_awake undefined)
# degrade to undef -- the RUNNING text -- rather than to a denial of its own.
# ---------------------------------------------------------------------------
sub far_paused_fleets {
    my ($p, $work, $now) = @_;
    my $far = eval { _far_paused_fleets($p, $work, $now) };
    return $@ ? undef : $far;
}

sub _far_paused_fleets {
    my ($p, $work, $now) = @_;
    return undef unless ref $work eq 'ARRAY' && @$work;
    return undef unless defined &BpAwakeIntent::want_awake;
    return undef unless defined $now && !ref($now) && $now =~ /\A[0-9]+\z/;

    my $dd = eval { BpHook::data_dir($p) };
    return undef unless defined $dd && length $dd;
    my $dd_norm = _norm_dir($dd);
    return undef unless defined $dd_norm;

    my $W = _watcher_launches($p);
    return undef unless ref $W eq 'HASH' && %$W;

    my %by_runs;    # runs dir -> name (first watcher's name)
    for my $item (@$work) {
        return undef unless ref $item eq 'HASH' && defined $item->{id} && !ref($item->{id});
        my $info = $W->{ $item->{id} };
        return undef unless ref $info eq 'HASH' && defined $info->{runs} && defined $info->{name};
        # A.2.2 condition 3: the watcher's runs dir must be THIS project's
        # own <data_dir>/blueprints/<name>/runs -- any other --runs/--bp-dir
        # target (another project, a temp dir, a mismatched blueprint name)
        # is rejected rather than trusted.
        my $expect = _norm_dir("$dd_norm/blueprints/$info->{name}/runs");
        my $got    = _norm_dir($info->{runs});
        return undef unless defined $expect && defined $got && $expect eq $got;
        $by_runs{ $info->{runs} } = $info->{name} unless exists $by_runs{ $info->{runs} };
    }
    return undef unless %by_runs;

    my @entries;
    for my $runs (sort keys %by_runs) {
        my $pf = "$runs/.paused";
        return undef unless -f $pf;
        open(my $fh, '<:raw', $pf) or return undef;
        local $/;
        my $raw = <$fh>;
        close $fh;
        my $doc = eval { JSON::PP->new->utf8->decode($raw) };
        return undef unless ref $doc eq 'HASH';
        my $verdict = BpAwakeIntent::want_awake(
            { scope => 'fleet', paused => $doc, now => $now, horizon => BpAwakeConst::FLEET_PAUSE_HORIZON() });
        return undef unless ref $verdict eq 'HASH' && $verdict->{handoff};

        # A.2.2 condition 5: only a plain, sane integer relaunch_at counts --
        # want_awake's own regex also accepts a fractional number (telemetry
        # for pause-pending, not meant to reach handoff logic unvalidated),
        # and nothing here revisits the horizon itself.
        my $at_raw = $doc->{relaunch_at};
        return undef if ref $at_raw;
        return undef unless defined $at_raw;
        my $at_str = "$at_raw";
        return undef unless $at_str =~ /\A[1-9][0-9]{0,10}\z/;
        my $at = $at_str + 0;
        return undef if $at > $now + $FAR_RELAUNCH_MAX_AHEAD;

        push @entries, { name => $by_runs{$runs}, runs => $runs, relaunch_at => $at };
    }
    return undef unless @entries;

    @entries = sort { $a->{relaunch_at} <=> $b->{relaunch_at} || $a->{name} cmp $b->{name} } @entries;
    return \@entries;
}

# _norm_dir($d) -> normalised string | undef -- Addendum A (A.2.2), pure.
# Folds backslashes to '/', a leading posix drive form ('/c/x') and a bare
# drive-letter form ('c:/x') both to 'C:/x', collapses repeated slashes and
# a trailing one, and refuses a path carrying a '.' or '..' segment. Byte-
# wise comparison only -- no case folding beyond the drive letter.
sub _norm_dir {
    my ($d) = @_;
    return undef unless defined $d && !ref($d) && length $d;
    my $v = $d;
    $v =~ s{\\}{/}g;
    $v =~ s{^/([A-Za-z])(?=/|\z)}{uc($1) . ':'}e;
    $v =~ s{^([a-z]):}{uc($1) . ':'}e;
    $v =~ s{/{2,}}{/}g;
    $v =~ s{/+\z}{};
    for my $seg (split m{/}, $v) {
        return undef if $seg eq '.' || $seg eq '..';
    }
    return $v;
}

# far_pause_reason($t, \@far) -> string | undef -- Addendum A (A.2.4), pure.
# The compact --reason butler-continuity off/the offer record both carry:
# "far pause, offer <t>: <name>@<relaunch_at>, ...". undef for an empty
# fleet list or when the result would exceed $FAR_REASON_MAX_BYTES (every
# byte here is ASCII, so length() in characters is length() in bytes).
sub far_pause_reason {
    my ($t, $far) = @_;
    return undef unless ref $far eq 'ARRAY' && @$far;
    my $r = "far pause, offer $t: " . join(', ', map { "$_->{name}\@$_->{relaunch_at}" } @$far);
    return undef if length($r) > $FAR_REASON_MAX_BYTES;
    return $r;
}

# _fp_utc($epoch) -> 'YYYY-MM-DDTHH:MM:SSZ' -- Addendum A, pure.
sub _fp_utc {
    my ($epoch) = @_;
    my @t = gmtime($epoch);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

# _write_far_offer($sid, $p, $t, $reason, $far, $now) -> 1|0 -- Addendum A
# (A.2.3). Never dies (callers wrap it in eval anyway); writes
# DD/butler-far-pause/<t>.json atomically (temp+rename), DD from
# BpHook::data_dir($p). Returns 0 on any failure, leaving no partial file.
sub _write_far_offer {
    my ($sid, $p, $t, $reason, $far, $now) = @_;
    return 0 unless defined $t && $t =~ /\A[0-9a-f]{8}\z/;
    my $dd = eval { BpHook::data_dir($p) };
    return 0 unless defined $dd && length $dd;
    my $dir = "$dd/butler-far-pause";
    unless (-d $dir) {
        eval { require File::Path; File::Path::make_path($dir) };
    }
    return 0 unless -d $dir;

    my @fleets = map {
        { name => $_->{name}, relaunch_at => $_->{relaunch_at}, relaunch_at_utc => _fp_utc($_->{relaunch_at}) }
    } @$far;
    my $doc = {
        v => 1, session_id => $sid, offer => $t, reason => $reason,
        written_at => $now, written_at_utc => _fp_utc($now),
        valid_until_utc => _fp_utc($now + $FAR_OFFER_TTL),
        fleets => \@fleets,
    };
    my $json = eval { JSON::PP->new->utf8->canonical->encode($doc) };
    return 0 unless defined $json;

    my $path = "$dir/$t.json";
    my $tmp  = "$path.tmp.$$";
    my $ok   = 0;
    if (open(my $fh, '>:raw', $tmp)) {
        if (print({$fh} $json) && close($fh) && rename($tmp, $path)) {
            $ok = 1;
        }
    }
    unless ($ok) { unlink $tmp if -f $tmp; return 0; }
    return 1;
}

# _clear_far_offers($sid, $p, $now) -- Addendum A (A.2.3). Called on every
# armed, interactive, non-coordinator Stop (right after G7b's
# clear_running_snapshot, before G8), so at most one live record per session
# survives: the far branch above writes its own AFTER this runs. Removes an
# entry when it does not decode to a HASH, names this session, or is
# expired ($FAR_OFFER_TTL past its own written_at); a *.tmp.* file is never
# touched. No-op when DD is undefined or the dir does not exist. Never dies
# (callers wrap it in eval anyway).
sub _clear_far_offers {
    my ($sid, $p, $now) = @_;
    my $dd = eval { BpHook::data_dir($p) };
    return unless defined $dd && length $dd;
    my $dir = "$dd/butler-far-pause";
    return unless -d $dir;
    opendir(my $dh, $dir) or return;
    my @entries = readdir($dh);
    closedir $dh;
    for my $e (@entries) {
        next unless $e =~ /\A[0-9a-f]{8}\.json\z/;
        my $path = "$dir/$e";
        my $doc = eval {
            open(my $fh, '<:raw', $path) or return undef;
            local $/;
            my $raw = <$fh>;
            close $fh;
            JSON::PP->new->utf8->decode($raw);
        };
        my $remove = 0;
        if (ref $doc ne 'HASH') { $remove = 1 }
        elsif (defined $doc->{session_id} && !ref($doc->{session_id}) && $doc->{session_id} eq $sid) { $remove = 1 }
        elsif (!defined $doc->{written_at} || ref($doc->{written_at}) || $doc->{written_at} !~ /\A\d+\z/) { $remove = 1 }
        elsif ($doc->{written_at} + $FAR_OFFER_TTL < $now) { $remove = 1 }
        unlink $path if $remove;
    }
    return;
}

# _fp_ts($epoch) -> 'YYYY-MM-DD HH:MM UTC', zero-padded.
sub _fp_ts {
    my ($epoch) = @_;
    my @t = gmtime($epoch);
    return sprintf('%04d-%02d-%02d %02d:%02d UTC', $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1]);
}

# _watcher_launches($p) -> { task_id => { runs => <dir>, name => <blueprint> } },
# read from the transcript the same way BpHook::holder_launches reads
# butler-hold launches -- a StopGate.pm sub using only BpHook's public API
# (BpHook.pm is not in this package's write set).
my $WATCHER_SCAN_BYTES = 2 * 1024 * 1024;

sub _watcher_launches {
    my ($p) = @_;
    my %out;
    return \%out unless ref $p eq 'HASH';
    my $tp = $p->{transcript_path};
    return \%out unless defined $tp && !ref($tp) && length $tp;
    my $tpb = $tp;
    utf8::encode($tpb) if utf8::is_utf8($tpb);
    open(my $fh, '<:raw', $tpb) or return \%out;
    my $size = -s $fh;
    if ($size && $size > $WATCHER_SCAN_BYTES) {
        seek($fh, $size - $WATCHER_SCAN_BYTES, 0);
        <$fh>;    # drop the partial first line
    }
    my %watch_use;    # tool_use_id -> argv (arrayref of word hashrefs)
    while (my $line = <$fh>) {
        next unless $line =~ /"tool_(?:use|result)"/;
        next unless $line =~ /bp-wait-for-escalation|backgroundTaskId|background with ID/;
        my $rec = eval { JSON::PP->new->utf8->decode($line) };
        next unless ref $rec eq 'HASH' && ref $rec->{message} eq 'HASH';
        my $content = $rec->{message}{content};
        next unless ref $content eq 'ARRAY';
        for my $c (@$content) {
            next unless ref $c eq 'HASH' && defined $c->{type} && !ref($c->{type});
            if ($c->{type} eq 'tool_use') {
                next unless defined $c->{id} && !ref($c->{id})
                    && defined $c->{name} && !ref($c->{name}) && $c->{name} eq 'Bash';
                my $in = $c->{input};
                next unless ref $in eq 'HASH' && $in->{run_in_background}
                    && defined $in->{command} && !ref($in->{command});
                # Addendum A (A.2.2 condition 4): a launch that carries its
                # own CCPRAXIS_DATA_DIR= env-prefix reads a different data
                # dir than the gate resolves, so it is left out of W
                # entirely -- its task id then simply isn't a key, and
                # _far_paused_fleets' condition 2 of the base spec fails.
                next if $in->{command} =~ /(?<![A-Za-z0-9_])CCPRAXIS_DATA_DIR=/;
                my $argv = eval { BpHook::sole_invocation($in->{command}, 'bp-wait-for-escalation') };
                $watch_use{ $c->{id} } = $argv if ref $argv eq 'ARRAY';
            }
            elsif ($c->{type} eq 'tool_result') {
                next unless defined $c->{tool_use_id} && !ref($c->{tool_use_id})
                    && exists $watch_use{ $c->{tool_use_id} };
                my $argv = $watch_use{ $c->{tool_use_id} };
                my $task;
                my $tur = $rec->{toolUseResult};
                if (ref $tur eq 'HASH' && defined $tur->{backgroundTaskId} && !ref($tur->{backgroundTaskId})) {
                    $task = $tur->{backgroundTaskId};
                }
                else {
                    my $text = ref $c->{content} eq 'ARRAY'
                        ? join("\n", map { (ref $_ eq 'HASH' && defined $_->{text} && !ref($_->{text})) ? $_->{text} : () } @{ $c->{content} })
                        : ((defined $c->{content} && !ref($c->{content})) ? $c->{content} : '');
                    ($task) = $text =~ /background with ID: ([A-Za-z0-9_-]+)/;
                }
                next unless defined $task && $task =~ /\A[A-Za-z0-9_-]{1,64}\z/;
                my $resolved = _resolve_watcher($argv, $p);
                $out{$task} = $resolved if defined $resolved;
            }
        }
    }
    close $fh;
    return \%out;
}

# _resolve_watcher($argv, $p) -> { runs, name } | undef. $argv is the
# arrayref of plain-string literals (undef for an unpredictable word)
# sole_invocation returned (the words AFTER the matched
# bp-wait-for-escalation(.pl) command word).
my %WATCHER_CONSUMERS = map { $_ => 1 } qw(runs bp-dir seen timeout poll category);

sub _resolve_watcher {
    my ($argv, $p) = @_;
    return undef unless ref $argv eq 'ARRAY';

    my (%opt, @positional);
    my $n = scalar @$argv;
    my $i = 0;
    while ($i < $n) {
        my $lit = $argv->[$i];
        if (defined $lit && $lit =~ /^--(.+)\z/ && $WATCHER_CONSUMERS{$1}) {
            my $key  = $1;
            my $vlit = $argv->[ $i + 1 ];
            $opt{$key} = $vlit;    # may be undef: an unpredictable value is
                                    # caught by the resolution below, which
                                    # fails closed rather than guessing.
            $i += 2;
            next;
        }
        if (defined $lit && $lit =~ /^--/) { $i++; next }
        push @positional, $lit;
        $i++;
    }
    my $bp = $positional[0];

    my $cwd = (ref $p eq 'HASH' && defined $p->{cwd} && !ref($p->{cwd})) ? $p->{cwd} : undef;
    my $runs = _resolve_watcher_runs(\%opt, $bp, $cwd);
    return undef unless defined $runs && length $runs;

    my $name;
    if (defined $bp) {
        $name = $bp;
    }
    else {
        (my $parent = $runs) =~ s{/[^/]*/?\z}{};
        ($name) = $parent =~ m{([^/]+)\z};
    }
    return undef unless defined $name && $name =~ /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/;

    return { runs => $runs, name => $name };
}

# _resolve_watcher_runs(\%opt, $bp, $cwd) -> the runs dir, or undef when the
# value a chosen branch needs is missing/unpredictable. First branch that
# APPLIES (its flag was given) wins -- it is never allowed to fall through
# to a later branch just because its own value could not be resolved.
sub _resolve_watcher_runs {
    my ($opt, $bp, $cwd) = @_;
    if (exists $opt->{runs}) {
        my $v = $opt->{runs};
        return undef unless defined $v;
        $v =~ s{\\}{/}g;
        return _resolve_watcher_path($v, $cwd);
    }
    if (exists $opt->{'bp-dir'}) {
        my $v = $opt->{'bp-dir'};
        return undef unless defined $v;
        $v =~ s{\\}{/}g;
        my $base = _resolve_watcher_path($v, $cwd);
        return undef unless defined $base;
        return "$base/runs";
    }
    if (defined $bp) {
        my $dd = eval { BpHook::data_dir({ cwd => $cwd }) };
        return undef unless defined $dd && length $dd;
        return "$dd/blueprints/$bp/runs";
    }
    return undef;
}

# _resolve_watcher_path($v, $cwd) -> $v itself when absolute (posix '/' or a
# Windows drive 'C:/'), else $v resolved against $cwd when THAT is absolute,
# else undef.
sub _resolve_watcher_path {
    my ($v, $cwd) = @_;
    return $v if $v =~ m{^/} || $v =~ m{^[A-Za-z]:/};
    return undef unless defined $cwd && !ref($cwd) && length $cwd;
    (my $c = $cwd) =~ s{\\}{/}g;
    return undef unless $c =~ m{^/} || $c =~ m{^[A-Za-z]:/};
    $c =~ s{/+\z}{};
    return "$c/$v";
}

# ---------------------------------------------------------------------------
# BREAK GLASS (bug 20261021-202419-bf19, operator decision 2026-10-21): two
# last-resort ways past the gate for a session whose own tooling is broken.
#
#   1. The refusal cap (G9b): $REFUSAL_CAP consecutive refusals with no tool
#      call succeeding in between, and the gate lets the stop through. Needs
#      nothing from the stuck session.
#   2. The break-glass file (G2b/G6b): an off request written with the Write
#      tool, which keeps working when the shell does not. It must
#      carry the token the last refusal printed, so it is exactly as bound to
#      this session and this turn as the shell commands are.
# ---------------------------------------------------------------------------
# _break_glass_paths($sid, $p) -> the candidate file paths, preferred first.
# The project's .ccpraxis-local-data is preferred because the Write tool can
# reach it without touching ~/.claude, which Claude Code guards; the state dir
# is the fallback for a project that has none.
sub _break_glass_paths {
    my ($sid, $p) = @_;
    my @paths;
    my $dd = eval { BpHook::data_dir($p) };
    push @paths, "$dd/butler-break-glass/$sid.json" if defined $dd && length $dd;
    my $root = BpHook::state_dir();
    push @paths, "$root/break-glass/$sid.json" if defined $root && length $root;
    return @paths;
}

# _display_path($path) -> the path in the form the Write tool accepts. Under
# Git-for-Windows a HOME-derived path reads /c/Users/...; a native tool wants
# C:/Users/....
sub _display_path {
    my ($path) = @_;
    (my $d = $path) =~ s{\\}{/}g;
    $d =~ s{^/([A-Za-z])/}{uc($1) . ':/'}e if $^O =~ /^(?:msys|cygwin|MSWin32)$/;
    return $d;
}

# _take_break_glass($sid, $p) -> ({action, reason}, undef) for a valid request,
# (undef, $why) for a file that existed but was refused, () when there is none.
# Every candidate file found is unlinked, valid or not.
sub _take_break_glass {
    my ($sid, $p) = @_;
    my @found = grep { -f $_ } _break_glass_paths($sid, $p);
    return () unless @found;

    my $data;
    for my $f (@found) {
        $data //= _read_json_file($f);
        unlink $f;
    }

    my $root = BpHook::state_dir();
    my $current;
    if (defined $root && open(my $fh, '<:raw', "$root/stop-tokens/$sid.current")) {
        local $/;
        $current = <$fh>;
        close $fh;
        $current =~ s/\s+\z// if defined $current;
    }

    return (undef, 'it is not a JSON object') unless ref $data eq 'HASH';
    my ($tok, $act, $why) = @{$data}{qw(token action reason)};
    return (undef, 'no stop is pending for this session') unless defined $current && length $current;
    return (undef, 'its token is not the one the last refusal printed')
        unless defined $tok && !ref $tok && $tok eq $current;
    return (undef, 'its action "silence" is removed: an armed session does not end a turn to wait for the operator. '
            . 'File the question with almanac inbox file and keep working; if nothing can proceed, use "action":"off". '
            . 'See "If you have a question for the operator" in plugins/butler/skills/continuity/SKILL.md')
        if defined $act && !ref $act && $act eq 'silence';
    return (undef, 'its action must be "off"')
        unless defined $act && !ref $act && $BREAK_GLASS_ACTION{$act};
    return (undef, 'its reason must be at least two words')
        unless defined $why && !ref $why && scalar(split(' ', $why)) >= 2;
    $why = substr($why, 0, 200);
    $why =~ s/[\x00-\x1f\x7f]/ /g;
    return ({ action => $act, reason => $why }, undef);
}

# _read_json_file($path) -> the decoded JSON, or undef for a missing, unreadable
# or malformed file. Never dies.
sub _read_json_file {
    my ($path) = @_;
    open(my $fh, '<:raw', $path) or return undef;
    local $/;
    my $raw = <$fh>;
    close $fh;
    return undef unless defined $raw;
    return eval { JSON::PP->new->utf8->decode($raw) };
}

sub _streak_path {
    my ($sid) = @_;
    my $root = BpHook::state_dir();
    return undef unless defined $root;
    return "$root/stop-refusals/$sid";
}

sub _clear_streak {
    my ($sid) = @_;
    my $path = _streak_path($sid);
    unlink $path if defined $path;
    return;
}

# _bump_streak($sid, $p) -> ($count, $shell_failed). $count is how many
# refusals in a row this one would make with no tool call succeeding in
# between; $shell_failed is whether a Bash or PowerShell call errored during
# that run of refusals. (0, 0) when the transcript cannot be read, which keeps
# the cap and the break-glass hint inert rather than guessing.
#
# Only the transcript bytes appended since the previous refusal are read, so
# the cost is one turn's worth of JSONL, never the whole session.
sub _bump_streak {
    my ($sid, $p) = @_;
    my $tp = $p->{transcript_path};
    return (0, 0) unless defined $tp && !ref $tp && length $tp && -f $tp;
    my $size = -s $tp;
    return (0, 0) unless defined $size;
    my $path = _streak_path($sid);
    return (0, 0) unless defined $path;

    my $prev = _read_json_file($path);
    my ($count, $shell_failed) = (1, 0);
    # The offset is only meaningful in the file it was measured in: a record
    # from another transcript (a resumed or relocated session), or one whose
    # offset is past the end (a truncated transcript), starts a fresh streak
    # rather than scanning the wrong bytes. A record from before the
    # transcript was stored has no path and is still honoured.
    if (ref $prev eq 'HASH' && defined $prev->{offset} && $prev->{offset} =~ /^\d+$/
        && $prev->{offset} <= $size && defined $prev->{count} && $prev->{count} =~ /^\d+$/
        && (!defined $prev->{transcript} || $prev->{transcript} eq $tp))
    {
        my ($any_ok, $shell_err) = _scan_tool_results($tp, $prev->{offset});
        if ($any_ok) {
            $count = 1;
        }
        else {
            $count = $prev->{count} + 1;
            $shell_failed = ($prev->{shell_failed} || $shell_err) ? 1 : 0;
        }
        $shell_failed ||= $shell_err;
    }

    my $dir = $path;
    $dir =~ s{/[^/]*$}{};
    unless (-d $dir) { eval { require File::Path; File::Path::make_path($dir) } }
    if (open(my $fh, '>:raw', "$path.tmp.$$")) {
        # ->utf8 on both sides (_read_json_file decodes with ->utf8), so the
        # stored transcript path round-trips to the same string whether the
        # payload gave it as characters or as bytes (a non-ASCII user dir).
        print {$fh} JSON::PP->new->utf8->canonical->encode(
            { count => $count, offset => $size, shell_failed => $shell_failed ? 1 : 0,
              transcript => $tp }) . "\n";
        close $fh;
        rename("$path.tmp.$$", $path) or unlink "$path.tmp.$$";
    }
    return ($count, $shell_failed);
}

# _last_shell_failed($transcript) -> 1|0: whether the newest Bash or
# PowerShell tool_result in the transcript is an error. Reads at most the last
# 4 MiB, which holds far more than one turn; a shell call older than that, or
# none at all, reads as 0, so the refusal cap stays shut on a healthy session.
sub _last_shell_failed {
    my ($tp) = @_;
    return 0 unless defined $tp && !ref $tp && length $tp && -f $tp;
    my $size = -s $tp;
    return 0 unless $size;
    my $start = $size > 4 * 1024 * 1024 ? $size - 4 * 1024 * 1024 : 0;
    open(my $fh, '<:raw', $tp) or return 0;
    seek($fh, $start, 0);
    <$fh> if $start;    # drop the partial first line
    my (%name_of, $last);
    while (my $line = <$fh>) {
        next unless $line =~ /"tool_(?:use|result)"/;
        my $rec = eval { JSON::PP->new->utf8->decode($line) };
        next unless ref $rec eq 'HASH' && ref $rec->{message} eq 'HASH';
        my $content = $rec->{message}{content};
        next unless ref $content eq 'ARRAY';
        for my $c (@$content) {
            next unless ref $c eq 'HASH' && defined $c->{type};
            if ($c->{type} eq 'tool_use' && defined $c->{id}) {
                $name_of{$c->{id}} = $c->{name};
            }
            elsif ($c->{type} eq 'tool_result' && defined $c->{tool_use_id}) {
                my $n = $name_of{$c->{tool_use_id}};
                $last = $c->{is_error} ? 1 : 0 if defined $n && $SHELL_TOOL{$n};
            }
        }
    }
    close $fh;
    return $last ? 1 : 0;
}

# _scan_tool_results($transcript, $offset) -> ($any_ok, $shell_failed) over
# the JSONL lines from $offset to the end. A tool_result without is_error is a
# success; one with is_error whose tool_use was Bash or PowerShell is a failed
# shell call. Lines that do not decode are skipped.
sub _scan_tool_results {
    my ($tp, $offset) = @_;
    open(my $fh, '<:raw', $tp) or return (0, 0);
    seek($fh, $offset, 0);
    my (%name_of, $any_ok, $shell_failed);
    while (my $line = <$fh>) {
        next unless $line =~ /"tool_(?:use|result)"/;
        my $rec = eval { JSON::PP->new->utf8->decode($line) };
        next unless ref $rec eq 'HASH' && ref $rec->{message} eq 'HASH';
        my $content = $rec->{message}{content};
        next unless ref $content eq 'ARRAY';
        for my $c (@$content) {
            next unless ref $c eq 'HASH' && defined $c->{type};
            if ($c->{type} eq 'tool_use' && defined $c->{id}) {
                $name_of{$c->{id}} = $c->{name};
            }
            elsif ($c->{type} eq 'tool_result') {
                my $err = $c->{is_error} ? 1 : 0;
                if (!$err) { $any_ok = 1 }
                else {
                    my $n = defined $c->{tool_use_id} ? $name_of{$c->{tool_use_id}} : undef;
                    $shell_failed = 1 if defined $n && $SHELL_TOOL{$n};
                }
            }
        }
    }
    close $fh;
    return ($any_ok ? 1 : 0, $shell_failed ? 1 : 0);
}

# ---------------------------------------------------------------------------
# _touch_armed($sid) -- G7: utime undef, undef on armed/<sid>. state_dir()
# is a public BpHook accessor; failure (no state root, no file) is silently
# a no-op, which is the "failure ignored" the spec calls for.
# ---------------------------------------------------------------------------
sub _touch_armed {
    my ($sid) = @_;
    my $root = BpHook::state_dir();
    return unless defined $root && length $root;
    my $path = "$root/armed/$sid";
    return unless -e $path;
    utime(undef, undef, $path);
    return;
}

# ---------------------------------------------------------------------------
# _ensure_lease_daemon() -- F4 (red-team M2): converge() re-asserts the
# lease (cheap stat+utime) and, only if nothing is already refreshing it,
# spawns exactly one daemon (BpContinuityLease::ensure_daemon's own cheap
# pid-file-mtime check, gated on CCPRAXIS_NO_WAKELOCK). Never starts a
# process itself; delegates entirely to BpContinuityLease.
# ---------------------------------------------------------------------------
sub _ensure_lease_daemon {
    return unless defined &BpContinuityLease::legacy_dir;
    my $dir = BpContinuityLease::legacy_dir();
    return unless defined $dir;
    BpContinuityLease::converge($dir);
    return;
}

# ---------------------------------------------------------------------------
# _coordinator($sid, $p) -> 0 | 2 -- spec sec 2.4, steps 1-5, first match
# wins.
# ---------------------------------------------------------------------------
sub _coordinator {
    my ($sid, $p) = @_;

    my $bp_dir = $ENV{BP_DIR};
    my $bp_pkg = $ENV{BP_PACKAGE};
    my $ledger = $ENV{BP_LEDGER};

    my $have_dir = (defined $bp_dir && length $bp_dir) ? 1 : 0;
    my $have_pkg = (defined $bp_pkg && length $bp_pkg) ? 1 : 0;

    # Step 1: force-stop. A force-stop file for another package is ignored.
    if ($have_dir && $have_pkg && $bp_pkg !~ m{/}) {
        my $fs_path = "$bp_dir/runs/$bp_pkg.force-stop";
        if (-e $fs_path) {
            unlink $fs_path;
            return 0;
        }
    }

    my $paused_active = ($have_dir && -e "$bp_dir/runs/.paused" && !-e "$bp_dir/runs/.shutdown") ? 1 : 0;

    my $facts = _ledger_facts($ledger);

    if ($paused_active) {
        # Step 2: pause rules. No holder check on this path (spec sec 2.4).
        my $reason = _pause_reason($facts);
        unless (defined $reason) {
            _stamp_ledger($ledger);
            return 0;
        }
        return _deny_coordinator($sid, $p, $reason);
    }

    # Step 3: ledger rule.
    my $reason = _ledger_reason($facts);
    unless (defined $reason) {
        _registry_sync($bp_dir, $bp_pkg, $facts->{status}) if $have_dir && $have_pkg;
        _stamp_ledger($ledger);
        return 0;
    }

    # Step 4: holder rule.
    return 0 if BpHook::holder_live($sid, $p);

    # Step 5: deny, with the R6 override -- a hold exists (unexpired) but
    # counts for nothing, since holder_live above already said no.
    my $holder = BpHook::holder($sid);
    if (ref $holder eq 'HASH'
        && defined $holder->{deadline} && $holder->{deadline} =~ /^-?\d+$/ && $holder->{deadline} > time())
    {
        $reason = 'the held ids are not running background subagents';
    }
    return _deny_coordinator($sid, $p, $reason);
}

# ---------------------------------------------------------------------------
# _deny_coordinator($sid, $p, $reason) -> 2 -- the coordinator text (spec
# sec 2.5), with or without a token depending on whether one could be
# minted.
# ---------------------------------------------------------------------------
sub _deny_coordinator {
    my ($sid, $p, $reason) = @_;
    # R6-M1 (red-team MEDIUM-1): on the pause+terminal path (R5) the ledger
    # is ALREADY terminal -- that is exactly why R5 fired -- so the generic
    # "finish or park the ledger" line 4 is unfollowable, and the holder is
    # never consulted on this path either. This module's own pause guidance
    # (below) is what tells the agent what it can actually do:
    # move the status back off terminal. Swap line 4 for that exact text
    # only on this path; every other reason keeps the generic line.
    my $is_pause_terminal = ($reason =~ /^a fleet pause is active and status /) ? 1 : 0;
    my $line4 = $is_pause_terminal
        ? "Set status back to a non-terminal value (running/converging) with a concrete '## Next action', then stop."
        : "Otherwise finish or park the ledger: status done|blocked|parked, a concrete '## Next action' when blocked or parked, last_updated from iso_now.";
    my $t = BpHook::mint_stop_token($sid, $p);
    if (defined $t) {
        return BpHook::deny(
            "Coordinator stop refused: $reason. Stop token: $t",
            "Waiting on a background subagent? Hold it, as a background Bash tool call:",
            "  butler-hold --token $t <id> [<id> ...]",
            $line4,
        );
    }
    return BpHook::deny(
        "Coordinator stop refused: $reason.",
        "Waiting on a background subagent? Hold it, as a background Bash tool call:",
        "  butler-hold <id> [<id> ...]",
        $line4,
    );
}

# ---------------------------------------------------------------------------
# _fresh_min() -- BP_LEDGER_FRESH_MIN when it matches ^\d+$, else 15.
# ---------------------------------------------------------------------------
sub _fresh_min {
    my $f = $ENV{BP_LEDGER_FRESH_MIN};
    return 15 unless defined $f && $f =~ /^\d+$/;
    return $f + 0;
}

# ---------------------------------------------------------------------------
# _ledger_facts($ledger) -> \%facts -- one read of the ledger file (spec
# sec 2.4 "Ledger reads"). Always returns a well-shaped hashref, even for a
# missing/unreadable ledger.
# ---------------------------------------------------------------------------
sub _ledger_facts {
    my ($ledger) = @_;
    my %f = (exists => 0, status => undef, terminal => 0, next_concrete => 0,
              stale => 0, age => 0, fresh_min => _fresh_min());
    return \%f unless defined $ledger && length $ledger;
    return \%f unless -f $ledger;
    $f{exists} = 1;

    my $mtime = (stat($ledger))[9];
    my $age = defined $mtime ? int((time() - $mtime) / 60) : 0;
    $f{age} = $age;
    $f{stale} = ($age > $f{fresh_min}) ? 1 : 0;

    open(my $fh, '<:raw', $ledger) or return \%f;
    local $/;
    my $content = <$fh>;
    close $fh;
    return \%f unless defined $content;

    my @lines = split /\n/, $content;

    my ($d1, $d2);
    for my $i (0 .. $#lines) {
        (my $chk = $lines[$i]) =~ s/\r$//;
        if ($chk =~ /^---\s*$/) {
            if (!defined $d1) { $d1 = $i; next }
            $d2 = $i;
            last;
        }
    }
    if (defined $d1 && defined $d2) {
        for my $i ($d1 + 1 .. $d2 - 1) {
            (my $chk = $lines[$i]) =~ s/\r$//;
            if ($chk =~ /^status:\s*(.*)$/) {
                my $s = $1;
                $s =~ s/\s+$//;
                $f{status} = $s;
                last;
            }
        }
    }
    my $status = $f{status};
    $f{terminal} = (defined $status && $status =~ /^(?:done|blocked|parked|dropped)$/) ? 1 : 0;

    my $next_idx;
    for my $i (0 .. $#lines) {
        if ($lines[$i] =~ /^## Next action/) { $next_idx = $i; last }
    }
    my $next_val = '';
    if (defined $next_idx) {
        for my $i ($next_idx + 1 .. $#lines) {
            (my $chk = $lines[$i]) =~ s/\r$//;
            next if $chk =~ /^\s*$/;
            $next_val = $chk;
            last;
        }
    }
    $next_val = '' if $next_val =~ /^#/;
    my $is_placeholder = ($next_val =~ /^</) ? 1 : 0;
    $f{next_concrete} = (length($next_val) && !$is_placeholder) ? 1 : 0;

    return \%f;
}

# ---------------------------------------------------------------------------
# _pause_reason(\%f) -> reason string | undef -- step 2 order: missing,
# terminal (R5), Next action (R4), stale (R3).
# ---------------------------------------------------------------------------
sub _pause_reason {
    my ($f) = @_;
    return 'the ledger does not exist' unless $f->{exists};
    if ($f->{terminal}) {
        my $s = defined $f->{status} ? $f->{status} : 'unset';
        return "a fleet pause is active and status '$s' is terminal";
    }
    return "'## Next action' is empty or a placeholder" unless $f->{next_concrete};
    return "the ledger is $f->{age}m stale (limit $f->{fresh_min}m)" if $f->{stale};
    return undef;
}

# ---------------------------------------------------------------------------
# _ledger_reason(\%f) -> reason string | undef -- step 3 order: missing,
# non-terminal (R2), stale (R3), Next action unless done (R4).
# ---------------------------------------------------------------------------
sub _ledger_reason {
    my ($f) = @_;
    return 'the ledger does not exist' unless $f->{exists};
    unless ($f->{terminal}) {
        my $s = defined $f->{status} ? $f->{status} : 'unset';
        return "status '$s' is not terminal";
    }
    return "the ledger is $f->{age}m stale (limit $f->{fresh_min}m)" if $f->{stale};
    my $status = defined $f->{status} ? $f->{status} : '';
    if ($status ne 'done' && !$f->{next_concrete}) {
        return "'## Next action' is empty or a placeholder";
    }
    return undef;
}

# ---------------------------------------------------------------------------
# R6-M4 (red-team MEDIUM-4): a coordinator's allowed stop rewrites the
# ledger and (for the ledger-rule path) runs/registry.json with an unlocked
# read-modify-write, so two fleet coordinators stopping close together can
# clobber each other's update. _with_lock takes an exclusive flock on
# "<path>.lock" (the same convention bp-ledger.pl run_op uses for the
# ledger; a sibling registry.lock for the registry), bounded by a 10s alarm
# matching the holder's own lock pattern. On timeout the write is skipped
# and the caller still allows -- a lock failure never turns an allow into a
# denial.
# ---------------------------------------------------------------------------
sub _with_lock {
    my ($lockpath, $code) = @_;
    my $lkfh;
    return unless open($lkfh, '>>', $lockpath);
    my $got = 0;
    eval {
        local $SIG{ALRM} = sub { die "stop-gate-lock-timeout\n" };
        alarm(10);
        $got = flock($lkfh, LOCK_EX);
        alarm(0);
    };
    alarm(0);
    unless ($got) {
        close $lkfh;
        return;
    }
    eval { $code->() };
    my $err = $@;
    flock($lkfh, LOCK_UN);
    close $lkfh;
    warn "stop-gate: $err" if $err;
    return;
}

# ---------------------------------------------------------------------------
# _iso_now() -- UTC "YYYY-MM-DDTHH:MM:SSZ", local to this module (core perl
# only; BpHook's own helper is private).
# ---------------------------------------------------------------------------
sub _iso_now {
    my @t = gmtime(time());
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

# ---------------------------------------------------------------------------
# _stamp_ledger($ledger) -- spec sec 2.6 "Stamp". Replaces the first
# ^last_updated: line inside the frontmatter, preserving every other byte
# (including line endings). No such line, or any I/O failure: leaves the
# ledger byte-identical and prints nothing.
# ---------------------------------------------------------------------------
sub _stamp_ledger {
    my ($ledger) = @_;
    return unless defined $ledger && length $ledger;
    return unless -f $ledger;
    _with_lock("$ledger.lock", sub { _stamp_ledger_locked($ledger) });
    return;
}

sub _stamp_ledger_locked {
    my ($ledger) = @_;
    return unless -f $ledger;

    open(my $fh, '<:raw', $ledger) or return;
    local $/;
    my $content = <$fh>;
    close $fh;
    return unless defined $content;

    my @lines = split /(?<=\n)/, $content;

    my ($d1, $d2);
    for my $i (0 .. $#lines) {
        (my $chk = $lines[$i]) =~ s/\r?\n$//;
        if ($chk =~ /^---\s*$/) {
            if (!defined $d1) { $d1 = $i; next }
            $d2 = $i;
            last;
        }
    }
    return unless defined $d1 && defined $d2;

    my $found = 0;
    for my $i ($d1 + 1 .. $d2 - 1) {
        (my $chk = $lines[$i]) =~ s/\r?\n$//;
        if ($chk =~ /^last_updated:/) {
            my $eol = ($lines[$i] =~ /(\r?\n)\z/) ? $1 : '';
            $lines[$i] = 'last_updated: ' . _iso_now() . $eol;
            $found = 1;
            last;
        }
    }
    return unless $found;

    my $new_content = join('', @lines);
    my $dir = $ledger;
    $dir =~ s{[^/\\]*\z}{};
    $dir = '.' unless length $dir;
    my $tmp = "${dir}.stop-gate-stamp.tmp.$$";
    open(my $ofh, '>:raw', $tmp) or return;
    my $ok = print {$ofh} $new_content;
    $ok &&= close($ofh);
    unless ($ok) { unlink $tmp; return }
    unless (rename($tmp, $ledger)) { unlink $tmp; return }
    return;
}

# ---------------------------------------------------------------------------
# _registry_sync($bp_dir, $bp_pkg, $status) -- spec sec 2.6 "Registry sync".
# Any failure or bad JSON: file untouched.
# ---------------------------------------------------------------------------
sub _registry_sync {
    my ($bp_dir, $bp_pkg, $status) = @_;
    return unless defined $bp_dir && length $bp_dir && defined $bp_pkg && length $bp_pkg;
    _with_lock("$bp_dir/runs/registry.lock", sub { _registry_sync_locked($bp_dir, $bp_pkg, $status) });
    return;
}

sub _registry_sync_locked {
    my ($bp_dir, $bp_pkg, $status) = @_;
    my $path = "$bp_dir/runs/registry.json";
    return unless -f $path;
    my $size = (stat($path))[7];
    return unless defined $size && $size > 0;

    open(my $fh, '<:raw', $path) or return;
    local $/;
    my $raw = <$fh>;
    close $fh;
    return unless defined $raw && length $raw;

    my $data = eval { JSON::PP->new->utf8->decode($raw) };
    return unless ref $data eq 'HASH';

    if (exists $data->{packages} && ref $data->{packages} ne 'HASH') {
        return;
    }
    $data->{packages} = {} unless ref $data->{packages} eq 'HASH';
    $data->{packages}{$bp_pkg} = {} unless ref $data->{packages}{$bp_pkg} eq 'HASH';
    $data->{packages}{$bp_pkg}{status} = $status;

    my $json = eval { JSON::PP->new->utf8->canonical->encode($data) };
    return unless defined $json;

    my $tmp = "$bp_dir/runs/.registry.json.tmp.$$";
    open(my $ofh, '>:raw', $tmp) or return;
    my $ok = print {$ofh} $json;
    $ok &&= close($ofh);
    unless ($ok) { unlink $tmp; return }
    unless (rename($tmp, $path)) { unlink $tmp; return }
    return;
}

1;
