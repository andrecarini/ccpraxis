# BpHook::Guards::Common -- shared line-fitting, path-resolution,
# writer-classification and subagent-binding helpers for every successor
# under BpHook::Guards:: (package 14 of blueprint hook-continuity-remake).
#
# Contract: .ccpraxis-local-data/blueprints/hook-continuity-remake/specs/
# 14-guards-remake-spec.md sec 2.3. Created in batch 1 (guard-bash);
# append-only afterwards -- later batches add functions here, never remove
# or change the ones batch 1 already shipped.
#
# Never calls exit, never spawns a process (no system/exec/backtick/qx/pipe
# open), never dies on purpose. Every sub here is a pure function of its
# arguments plus, where documented, the filesystem it is explicitly told to
# read -- no sub here reads %ENV or any butler state on its own.
package BpHook::Guards::Common;
use strict;
use warnings;
use JSON::PP ();
use Cwd ();

# ---------------------------------------------------------------------------
# fit($line) -> $line cut to 157 chars + '...' when longer than 160 chars;
# else unchanged.
# ---------------------------------------------------------------------------
sub fit {
    my ($line) = @_;
    return $line unless defined $line;
    return $line if length($line) <= 160;
    return substr($line, 0, 157) . '...';
}

# ---------------------------------------------------------------------------
# echo_cmd($cmd) -> \r \n \t each replaced by ' '; cut to 80 chars + '...'
# when longer than 80 chars.
# ---------------------------------------------------------------------------
sub echo_cmd {
    my ($cmd) = @_;
    return '' unless defined $cmd;
    my $v = $cmd;
    $v =~ tr/\r\n\t/   /;
    return $v if length($v) <= 80;
    return substr($v, 0, 80) . '...';
}

# ---------------------------------------------------------------------------
# path_echo($path) -> '...' + last 87 chars when longer than 90 chars; else
# unchanged.
# ---------------------------------------------------------------------------
sub path_echo {
    my ($path) = @_;
    return '' unless defined $path;
    return $path if length($path) <= 90;
    return '...' . substr($path, -87);
}

# ---------------------------------------------------------------------------
# is_writer($s) -> 'bp-implementer' | 'bp-test-writer' | 'bp-ui-prober'
# (first of these that is a substring of $s, in that order) | undef.
# ---------------------------------------------------------------------------
sub is_writer {
    my ($s) = @_;
    return undef unless defined $s;
    for my $role (qw(bp-implementer bp-test-writer bp-ui-prober)) {
        return $role if index($s, $role) >= 0;
    }
    return undef;
}

# ---------------------------------------------------------------------------
# resolve_path($fp, $cwd) -> absolute display path: '\' -> '/'; kept as
# given when it starts with '/' or /^[A-Za-z]:\//; else "$cwd/$fp" ($cwd =
# payload cwd, else Cwd::getcwd); '.' segments removed and 'x/..' collapsed
# lexically (never touches disk).
# ---------------------------------------------------------------------------
sub resolve_path {
    my ($fp, $cwd) = @_;
    return undef unless defined $fp && length $fp;
    (my $v = $fp) =~ tr{\\}{/};
    unless ($v =~ m{^/} || $v =~ m{^[A-Za-z]:/}) {
        my $base = (defined $cwd && length $cwd) ? $cwd : Cwd::getcwd();
        $base = '' unless defined $base;
        $base =~ tr{\\}{/};
        $base =~ s{/+$}{};
        $v = "$base/$v";
    }
    return _lexical_collapse($v);
}

sub _lexical_collapse {
    my ($v) = @_;
    my $prefix = '';
    if ($v =~ s{^([A-Za-z]:)/}{}) { $prefix = "$1/" }
    elsif ($v =~ s{^/}{}) { $prefix = '/' }
    my @in = split m{/}, $v;
    my @out;
    for my $seg (@in) {
        next if $seg eq '' || $seg eq '.';
        if ($seg eq '..') {
            if (@out && $out[-1] ne '..') { pop @out }
            else { push @out, $seg }
            next;
        }
        push @out, $seg;
    }
    return $prefix . join('/', @out);
}

# ---------------------------------------------------------------------------
# canon($abs) -> comparison form: /^\/([A-Za-z])\// and /^([A-Za-z]):\// both
# become lc(letter) . ':/'; trailing '/' removed. Used only to compare,
# never shown.
# ---------------------------------------------------------------------------
sub canon {
    my ($abs) = @_;
    return undef unless defined $abs;
    (my $v = $abs) =~ tr{\\}{/};
    if ($v =~ m{^/([A-Za-z])/(.*)$}) {
        $v = lc($1) . ':/' . $2;
    }
    elsif ($v =~ m{^([A-Za-z]):/(.*)$}) {
        $v = lc($1) . ':/' . $2;
    }
    $v =~ s{(?<!^[a-z]:)/+$}{};
    return $v;
}

# ---------------------------------------------------------------------------
# subagent_meta($p) -> the decoded hash of
# <dirname(transcript_path)>/<session_id>/subagents/agent-<agent_id>.meta.json
# (Claude Code writes agentType, toolUseId, spawnDepth there) when agent_id is
# defined and not '?' and the file parses; else undef.
# ---------------------------------------------------------------------------
sub subagent_meta {
    my ($p) = @_;
    return undef unless ref $p eq 'HASH';
    my $aid = BpHook::agent_id($p);
    return undef unless defined $aid && $aid ne '?';
    my $tp = $p->{transcript_path};
    return undef unless defined $tp && !ref($tp) && length $tp;
    my $sid = BpHook::session_id($p);
    return undef unless defined $sid;
    (my $tpn = $tp) =~ tr{\\}{/};
    my $dir = $tpn;
    $dir =~ s{/[^/]*$}{};
    my $path = "$dir/$sid/subagents/agent-$aid.meta.json";
    open(my $fh, '<:raw', $path) or return undef;
    local $/;
    my $raw = <$fh>;
    close $fh;
    return undef unless defined $raw;
    my $data = eval { JSON::PP->new->utf8->decode($raw) };
    return (ref $data eq 'HASH') ? $data : undef;
}

# ---------------------------------------------------------------------------
# subagent_tool_use_id($p) -> toolUseId from subagent_meta($p) when it
# matches ^[A-Za-z0-9_-]{1,128}$; else undef.
# ---------------------------------------------------------------------------
sub subagent_tool_use_id {
    my ($p) = @_;
    my $data = subagent_meta($p);
    return undef unless ref $data eq 'HASH';
    my $tuid = $data->{toolUseId};
    return undef unless defined $tuid && !ref($tuid) && length $tuid;
    return ($tuid =~ /^[A-Za-z0-9_-]{1,128}$/) ? $tuid : undef;
}

# ---------------------------------------------------------------------------
# SHELL_C_RE / EVAL_RE / is_shell_or_eval_invocation($cmd) -- true iff $cmd
# invokes a POSIX shell (sh/bash/zsh/ksh/dash) with -c, or `eval`, in command
# position: such a command re-interprets its own quoted argument at shell
# level, so a caller matching rule text against it must use the RAW command
# rather than any quote-stripped text (mirrors GuardBash's own "shellword"
# escape, spec sec 3.1, reused here for spec sec 3.7's R1).
# ---------------------------------------------------------------------------
# Redteam M2: a combined flag cluster ("-lc", "-ec") carries -c just as much
# as a standalone "-c" token does -- the flag-cluster group below now
# requires the LAST flag token to merely CONTAIN a "c", not equal "-c".
my $SHELL_C_RE = qr/(^|[;&|\s])(ba|z|k|da)?sh[[:space:]]+(-[a-zA-Z]*[[:space:]]+)*-[a-zA-Z]*c[a-zA-Z]*\b/;
my $EVAL_RE    = qr/(^|[;&|\s])eval\b/;
# Redteam M2 (heredoc half): "bash <<'EOF' ... EOF" feeds a heredoc body
# straight into a shell, and Shell::strip_noise deliberately blanks every
# heredoc line, so a caller must fall back to the RAW command here too.
my $HEREDOC_SHELL_RE = qr/(^|[;&|\s])(ba|z|k|da)?sh\b[^\n]*<</;

sub is_shell_or_eval_invocation {
    my ($cmd) = @_;
    return 0 unless defined $cmd;
    return 1 if line_match($SHELL_C_RE, $cmd);
    return 1 if line_match($EVAL_RE, $cmd);
    return 1 if line_match($HEREDOC_SHELL_RE, $cmd);
    return 0;
}

# ---------------------------------------------------------------------------
# git_opt_re() -> the flag-group pattern text (NOT a compiled qr//, so
# callers can interpolate it inside their own anchor-parameterised qr//)
# used between "git" and the verb by both GuardBash and GuardGitMutations
# (redteam H2). Unlike the old flags-only group, this also swallows the
# ARGUMENT of an option that takes one (-C <dir>, -c k=v, --git-dir=...,
# --work-tree <dir>, --namespace <ns>), so "git -C <dir> checkout" and
# "git -c k=v reset --hard" are seen exactly like their flagless form.
# ---------------------------------------------------------------------------
sub git_opt_re {
    return '(?:(?:-C|-c|--git-dir|--work-tree|--namespace)[[:space:]]+[^\s]+[[:space:]]+|-[^\s]+[[:space:]]+)*';
}

# ---------------------------------------------------------------------------
# line_match($re, $text) -> true iff some "\n"-separated line of $text
# matches $re (grep -E semantics: ^ and $ are line anchors, no match spans a
# newline). $re may be a Regexp ref (qr//) or a plain string pattern.
# ---------------------------------------------------------------------------
sub line_match {
    my ($re, $text) = @_;
    return 0 unless defined $re && defined $text;
    for my $line (split /\n/, $text) {
        my $ok = eval { $line =~ /$re/ ? 1 : 0 };
        return 1 if $ok;
    }
    return 0;
}

1;
