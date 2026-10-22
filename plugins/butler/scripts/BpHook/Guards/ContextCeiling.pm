# BpHook::Guards::ContextCeiling -- coordinator context-flush enforcement
# (PreToolUse) and guidance (PostToolUse) (package 14 of blueprint
# hook-continuity-remake), successor to the old separate context-ceiling
# flush and guidance hooks, now merged into hooks/context-ceiling.sh.
#
# Contract: .ccpraxis-local-data/blueprints/hook-continuity-remake/specs/
# 14-guards-remake-spec.md sec 3.8 (this successor's own contract).
# Architecture: plugins/butler/docs/hook-architecture.md
# ("context-ceiling" successor row).
#
# run($p, @args) never calls exit, never dies on purpose, never spawns a
# process (no system/exec/backtick/qx/pipe-open). Prints only through
# BpHook::deny(@lines) (budget: 2 lines, PreToolUse) or BpHook::context($text)
# (PostToolUse guidance only). Everything bp-orchestrator.pl would have done
# via `perl ...` is done in-process by requiring that file (its own
# `unless (caller)` CLI guard never fires under require) -- a require failure
# is caught and the whole rule is skipped (fail open).
package BpHook::Guards::ContextCeiling;
use strict;
use warnings;
use File::Basename qw(dirname);
use Cwd ();

my $SELF_DIR;
{
    my $f = __FILE__;
    $f = Cwd::abs_path($f) // $f;
    $SELF_DIR = dirname($f);
}
require "$SELF_DIR/../../BpHook.pm"
    unless grep { m{(?:^|/)BpHook\.pm$} } keys %INC;
require "$SELF_DIR/Common.pm"
    unless grep { m{(?:^|/)Guards/Common\.pm$} } keys %INC;

my $ORCH_OK;

sub _require_orch {
    return $ORCH_OK if defined $ORCH_OK;
    $ORCH_OK = eval { require "$SELF_DIR/../../bp-orchestrator.pl"; 1 } ? 1 : 0;
    return $ORCH_OK;
}

# ---------------------------------------------------------------------------
# small local helpers.
# ---------------------------------------------------------------------------
sub _read_bytes {
    my ($path) = @_;
    open(my $fh, '<:raw', $path) or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

sub _write_bytes {
    my ($path, $bytes) = @_;
    my $dir = $path;
    $dir =~ s{/[^/]*\z}{};
    unless (-d $dir) { eval { require File::Path; File::Path::make_path($dir) } }
    return 0 unless -d $dir;
    open(my $fh, '>:raw', $path) or return 0;
    my $ok = print {$fh} $bytes;
    $ok &&= close($fh);
    return $ok ? 1 : 0;
}

sub _iso_now {
    my @t = gmtime(time());
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

sub _rmdir_quiet {
    my ($path) = @_;
    return unless -d $path;
    eval { rmdir($path) };
    return;
}

sub _echo_cmd { return BpHook::Guards::Common::echo_cmd($_[0]) }

# ---------------------------------------------------------------------------
# _is_flush_work($cmd) -- sec 3.8's "allowed_bash" predicate.
# ---------------------------------------------------------------------------
sub _has_unquoted_redirect {
    my ($cmd) = @_;
    my $q = '';
    my $n = length($cmd);
    for (my $i = 0; $i < $n; $i++) {
        my $c = substr($cmd, $i, 1);
        if ($q) { $q = '' if $c eq $q; next }
        if ($c eq "'" || $c eq '"') { $q = $c; next }
        return 1 if $c eq '<' || $c eq '>';
    }
    return 0;
}

sub _flush_segments {
    my ($cmd) = @_;
    my @segs;
    my $buf = '';
    my $q = '';
    my $n = length($cmd);
    my $i = 0;
    while ($i < $n) {
        my $c = substr($cmd, $i, 1);
        if ($q) {
            $buf .= $c;
            $q = '' if $c eq $q;
            $i++;
            next;
        }
        if ($c eq "'" || $c eq '"') { $q = $c; $buf .= $c; $i++; next }
        if ($c eq "\n" || $c eq "\r") { push @segs, $buf; $buf = ''; $i++; next }
        if ($c eq ';') { push @segs, $buf; $buf = ''; $i++; next }
        if ($c eq '|') {
            if (substr($cmd, $i, 2) eq '||') { push @segs, $buf; $buf = ''; $i += 2; next }
            push @segs, $buf; $buf = ''; $i++; next;
        }
        if ($c eq '&') {
            if (substr($cmd, $i, 2) eq '&&') { push @segs, $buf; $buf = ''; $i += 2; next }
            push @segs, $buf; $buf = ''; $i++; next;
        }
        $buf .= $c;
        $i++;
    }
    push @segs, $buf;
    return @segs;
}

my $LEDGER_VERB_RE = qr{^\s*(?:perl\s+)?(?:[^\s]*/)?bp-ledger\.pl\s+(?:set-status|set-next-action|tick-step|append-attempt|add-output|set-escalation|validate)(?:\s|$)};
my $DISPATCH_VERB_RE = qr{^\s*(?:perl\s+)?(?:[^\s]*/)?bp-dispatch-log\.pl\s+outstanding(?:\s|$)};

sub _is_flush_work {
    my ($cmd) = @_;
    return 0 if $cmd =~ /\x60|\$\(|<\(|>\(/;
    return 0 if _has_unquoted_redirect($cmd);
    my @segs = _flush_segments($cmd);
    return 0 unless @segs;
    my $any = 0;
    for my $seg (@segs) {
        next if $seg =~ /^\s*\z/; # review M1: a blank segment (trailing ';'/
                                   # newline, or a blank line between verbs)
                                   # is not itself flush work; skip it rather
                                   # than denying the whole command over it.
        return 0 unless ($seg =~ $LEDGER_VERB_RE || $seg =~ $DISPATCH_VERB_RE);
        $any = 1;
    }
    return $any;
}

# ---------------------------------------------------------------------------
# _next_action_written($ledger_path) -- 'true'|'false'|'unknown'.
# ---------------------------------------------------------------------------
sub _next_action_written {
    my ($ledger) = @_;
    return 'unknown' unless defined $ledger && length $ledger;
    my $raw = _read_bytes($ledger);
    return 'unknown' unless defined $raw;
    my $text = $raw;
    $text =~ s/\r\n/\n/g;
    if ($text =~ /^##\s*Next action\s*\n(.*?)(?=^##|\z)/ms) {
        my $body = $1;
        $body =~ s/^\s+//;
        $body =~ s/\s+$//;
        return ($body eq '' || $body eq '<...>') ? 'false' : 'true';
    }
    return 'false';
}

# ---------------------------------------------------------------------------
# state paths.
# ---------------------------------------------------------------------------
sub _flush_state_path      { my ($bp, $pkg) = @_; return "$bp/runs/$pkg.ctx-flush" }
sub _overrun_log_path      { my ($bp, $pkg) = @_; return "$bp/runs/$pkg.ctx-flush-overrun.log" }
sub _overrun_once_dir_path { my ($bp, $pkg) = @_; return "$bp/runs/$pkg.ctx-flush-overrun.once" }
sub _guidance_state_path   { my ($bp, $pkg) = @_; return "$bp/runs/$pkg.ctx-guidance" }

# ---------------------------------------------------------------------------
# PreToolUse (flush) branch.
# ---------------------------------------------------------------------------
sub _run_pre {
    my ($p, $tool, $ti, $bpdir_fs, $pkg, $tier, $n, $hard) = @_;

    if ($tier eq 'soft' || $tier eq 'none') {
        unlink(_flush_state_path($bpdir_fs, $pkg));
        _rmdir_quiet(_overrun_once_dir_path($bpdir_fs, $pkg));
        return 0;
    }

    # tier eq 'hard'.
    my $flush_path = _flush_state_path($bpdir_fs, $pkg);
    my $prior = _read_bytes($flush_path);
    my $turns = 1;
    my $started = time();
    if (defined $prior) {
        if ($prior =~ /^turns:\s*([0-9]+)/m) { $turns = $1 + 1 }
        if ($prior =~ /^started_at:\s*(-?[0-9]+)/m) { $started = $1 }
    }
    _write_bytes($flush_path, "started_at: $started\nturns: $turns\n");

    if ($turns > 5) {
        my $once_dir = _overrun_once_dir_path($bpdir_fs, $pkg);
        if (mkdir($once_dir)) {
            my $njw = eval { _next_action_written($ENV{BP_LEDGER}) } // 'unknown';
            my $line = _iso_now() . " package=$pkg turns=$turns cap=5 context_tokens=$n next_action_written=$njw\n";
            eval {
                my $dir = $once_dir;
                $dir =~ s{/[^/]*\z}{};
                unless (-d $dir) { require File::Path; File::Path::make_path($dir) }
                open(my $fh, '>>:raw', _overrun_log_path($bpdir_fs, $pkg)) or die;
                print {$fh} $line;
                close $fh;
            };
        }
    }

    my $verdict_allow = 0;
    my $x;
    if ($tool eq 'Bash') {
        my $cmd = (ref $ti eq 'HASH' && defined $ti->{command} && !ref($ti->{command})) ? $ti->{command} : '';
        if ($cmd eq '') { return 0 }
        if (eval { _is_flush_work($cmd) }) { return 0 }
        $x = 'Command: ' . _echo_cmd($cmd);
    }
    else {
        $x = "Tool: $tool";
    }

    my $l1 = "BLOCKED: context flush (~$n tokens >= hard $hard). $x";
    my $l2 = ($turns <= 5)
        ? "Flush turn $turns of 5: only bp-ledger.pl set-status|set-next-action|tick-step|append-attempt|add-output|set-escalation|validate or bp-dispatch-log.pl outstanding."
        : "Flush turn $turns is past the permitted 5 and was logged to runs/<pkg>.ctx-flush-overrun.log; set status: blocked with a filled '## Escalation', then stop.";
    return BpHook::deny($l1, $l2);
}

# ---------------------------------------------------------------------------
# PostToolUse (guidance) branch.
# ---------------------------------------------------------------------------
sub _run_post {
    my ($p, $tier, $bpdir_fs, $pkg, $n, $soft, $hard) = @_;

    my $state_path = _guidance_state_path($bpdir_fs, $pkg);
    if ($tier eq 'none') {
        unlink($state_path);
        return 0;
    }

    my $interval = $ENV{BP_CTX_GUIDANCE_INTERVAL_SECS};
    $interval = (defined $interval && $interval =~ /^[0-9]+$/ && $interval > 0) ? $interval + 0 : 900;

    my $prior = _read_bytes($state_path);
    my $now = time();
    if (defined $prior && $prior =~ /^last_emit:\s*([0-9]+)/m) {
        my $last = $1 + 0;
        my $delta = $now - $last;
        if ($delta >= 0 && $delta < $interval) {
            return 0;
        }
    }

    my $l1 = ($tier eq 'hard')
        ? "[context-ceiling] About $n tokens, at or above the hard ceiling of $hard: a flush is in force; Task dispatch and non-flush Bash are denied."
        : "[context-ceiling] Your last recorded own-turn context is about $n tokens, at or above the soft ceiling of $soft (hard $hard); guidance, not a block.";
    my $l2 = "[context-ceiling] Record outstanding dispatches (bp-dispatch-log.pl outstanding), write a concrete '## Next action', leave status non-terminal, stop.";

    my $rc = BpHook::context($l1 . "\n" . $l2);
    _write_bytes($state_path, "last_emit: $now\n");
    return $rc;
}

# ---------------------------------------------------------------------------
# run($p, @args) -> 0 | 2.
# ---------------------------------------------------------------------------
sub run {
    my ($p, @args) = @_;
    $p = {} unless ref $p eq 'HASH';

    my $pkg = $ENV{BP_PACKAGE};
    $pkg = 'pkg' unless defined $pkg && length $pkg;
    return 0 if $pkg =~ m{/} || $pkg eq '.' || $pkg eq '..';

    my $bp_dir = $ENV{BP_DIR};
    return 0 unless defined $bp_dir && length $bp_dir;
    (my $bpdir_fs = $bp_dir) =~ tr{\\}{/};
    $bpdir_fs =~ s{/+\z}{};

    my $tool = $p->{tool_name};
    return 0 unless defined $tool && !ref($tool);
    return 0 unless $tool eq 'Task' || $tool eq 'Agent' || $tool eq 'Bash';

    return 0 unless _require_orch();

    my $usage = eval {
        BpOrch::last_coordinator_usage(BpOrch::_tail_jsonl_objs("$bpdir_fs/runs/$pkg.jsonl"));
    };
    return 0 unless defined $usage;

    my $n = eval { BpOrch::context_tokens_from_usage($usage) };
    return 0 unless defined $n;
    my $t = eval { BpOrch::_tunables_base() };
    return 0 unless ref $t eq 'HASH';
    my $tier = eval { BpOrch::context_ceiling_tier($usage, $t) };
    return 0 unless defined $tier;
    my $soft = $t->{ctx_ceiling_soft};
    my $hard = $t->{ctx_ceiling_hard};

    my $is_post = (defined $p->{hook_event_name} && !ref($p->{hook_event_name}) && $p->{hook_event_name} eq 'PostToolUse') ? 1 : 0;

    my $ti = (ref $p->{tool_input} eq 'HASH') ? $p->{tool_input} : {};

    if ($is_post) {
        return _run_post($p, $tier, $bpdir_fs, $pkg, $n, $soft, $hard);
    }
    return _run_pre($p, $tool, $ti, $bpdir_fs, $pkg, $tier, $n, $hard);
}

1;
