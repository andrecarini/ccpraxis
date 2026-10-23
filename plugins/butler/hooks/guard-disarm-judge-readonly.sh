#!/usr/bin/env bash
# guard-disarm-judge-readonly.sh -- PreToolUse Bash gate for the disarm
# judge's own headless claude process (blueprint judged-continuity-disarm,
# package 03). A no-op for every other process: it exits before stdin is
# read unless CCPRAXIS_DISARM_JUDGE is exactly 1, the marker
# plugins/butler/scripts/bp-judge-disarm.sh sets only on the judge's own
# dispatch. When it IS the judge, it allows exactly the fixed Decision-7
# read-only commands (git status, git log, almanac-bug.pl list,
# almanac-todo.pl list) and denies everything else, including chaining,
# redirection and output/write flags on an otherwise-allowlisted command.
# Does not go through run-hook.sh: no env clause there matches this marker.
[ "${CCPRAXIS_DISARM_JUDGE-}" = 1 ] || exit 0
d=${BASH_SOURCE[0]%/*}
IFS= read -r -d '' src <<'PERL' || true
use strict;
use warnings;
use JSON::PP ();

my $scripts_dir = $ARGV[0];

my $raw = do { local $/; <STDIN> };
$raw = '' unless defined $raw;

my $PREFIX = 'disarm judge: ';
my $TAIL   = 'Allowed: git status, git log, almanac-bug.pl list, almanac-todo.pl list; one command, no chaining, pipes or redirection.';

sub emit_and_exit {
    my ($decision, $why) = @_;
    my $reason = ($decision eq 'deny')
        ? ($PREFIX . $why . '. ' . $TAIL)
        : ($PREFIX . $why);
    my %doc = (
        hookSpecificOutput => {
            hookEventName             => 'PreToolUse',
            permissionDecision        => $decision,
            permissionDecisionReason  => $reason,
        },
    );
    my $out = JSON::PP->new->utf8->encode(\%doc);
    print $out . "\n";
    exit 0;
}

my $payload = eval { JSON::PP->new->utf8->decode($raw) };
if (!defined $payload || ref $payload ne 'HASH') {
    emit_and_exit('deny', 'unreadable payload');
}

my $tool_name = $payload->{tool_name};
if (defined $tool_name && $tool_name ne 'Bash') {
    exit 0;
}

my $cmd = (ref $payload->{tool_input} eq 'HASH') ? $payload->{tool_input}{command} : undef;
if (!defined $cmd || ref $cmd || !length $cmd) {
    emit_and_exit('deny', 'unreadable payload');
}

(my $CMD = $cmd) =~ s/^\s+|\s+$//g;

# -------- Step A: chaining/metacharacter scan, on strip_noise's output -----
unshift @INC, $scripts_dir;
my $loaded = eval { require BpHook::Guards::Shell; 1 };
if (!$loaded) {
    emit_and_exit('deny', 'guard load failure');
}
my $S = BpHook::Guards::Shell::strip_noise($CMD);
if ($S =~ /[;&|`\$<>()\x0a\x0d]/) {
    emit_and_exit('deny', 'chaining or redirect');
}

# -------- Step B: the guard's own tokenizer, on the RAW command ------------
my @tokens;
{
    my @words = split /[ \t]+/, $CMD;
    @words = grep { length } @words;
    if (!@words) {
        emit_and_exit('deny', 'unsupported syntax');
    }
    for my $w (@words) {
        my $tok = '';
        my $i = 0;
        my $n = length $w;
        my $ok = 1;
        my $first = 1;
        while ($i < $n) {
            my $c = substr($w, $i, 1);
            if ($c eq "'") {
                my $j = index($w, "'", $i + 1);
                if ($j < 0) { $ok = 0; last }
                $tok .= substr($w, $i + 1, $j - $i - 1);
                $i = $j + 1;
                $first = 0;
                next;
            }
            if ($c eq '"') {
                my $j = index($w, '"', $i + 1);
                if ($j < 0) { $ok = 0; last }
                my $inner = substr($w, $i + 1, $j - $i - 1);
                if ($inner =~ /[\$`\\!"]/) { $ok = 0; last }
                $tok .= $inner;
                $i = $j + 1;
                $first = 0;
                next;
            }
            if ($c =~ /^[\p{L}\p{N}_.\/:@%+=,^~-]$/) {
                if ($c eq '~' && $first) { $ok = 0; last }
                $tok .= $c;
                $i++;
                $first = 0;
                next;
            }
            $ok = 0;
            last;
        }
        if (!$ok || !length $tok) {
            emit_and_exit('deny', 'unsupported syntax');
        }
        push @tokens, $tok;
    }
}

# -------- Step C: the fixed Decision-7 allowlist ----------------------------
my @args;
my ($t0, $t1) = @tokens[0, 1];
if (defined $t0 && $t0 eq 'git' && defined $t1 && ($t1 eq 'status' || $t1 eq 'log')) {
    @args = @tokens[2 .. $#tokens];
}
else {
    my ($script, $verb, @rest);
    if (defined $t0 && $t0 eq 'perl') {
        $script = $tokens[1];
        $verb   = $tokens[2];
        @rest   = @tokens[3 .. $#tokens];
    }
    else {
        $script = $tokens[0];
        $verb   = $tokens[1];
        @rest   = @tokens[2 .. $#tokens];
    }
    my $ok = 0;
    if (defined $script && $script !~ /^-/) {
        my ($base) = $script =~ m{([^/\\]*)$};
        $base = '' unless defined $base;
        my $name_ok = ($base eq 'almanac-bug.pl' || $base eq 'almanac-todo.pl');
        if ($name_ok && defined $verb && $verb eq 'list') {
            # The script argument's basename alone is not an identity check --
            # any path ending in the right filename used to pass (the
            # red-team finding this closes: "perl /tmp/x/almanac-bug.pl list"
            # used to allow). bp-judge-disarm.sh now exports the real,
            # resolved almanac scripts dir as CCPRAXIS_DISARM_JUDGE_ALMANAC_ABS
            # on every dispatch vector (REAL and every STUB branch), so a
            # genuine judge invocation always has it set. When it IS set,
            # pin the match to that exact directory -- the script argument
            # must equal "<almanac_abs>/<base>" verbatim, never merely share
            # a filename, so a staged lookalike anywhere else is denied.
            #
            # When the env var is unset/empty, there is nothing to pin
            # against; this guard is also called directly (no dispatcher,
            # no env var) by this file's own acceptance-table tests, which
            # intentionally probe the tokenizer/allowlist shape in isolation
            # from path identity. Fall back to the pre-existing basename-only
            # match for that case, preserving those tests' behavior exactly.
            my $almanac_abs = $ENV{CCPRAXIS_DISARM_JUDGE_ALMANAC_ABS};
            if (defined $almanac_abs && length $almanac_abs) {
                $ok = 1 if $script eq "$almanac_abs/$base";
            }
            else {
                $ok = 1;
            }
        }
    }
    if (!$ok) {
        emit_and_exit('deny', 'not allowlisted');
    }
    @args = @rest;
}

# -------- Step D: output-shaped flags on args -------------------------------
for my $a (@args) {
    next unless defined $a;
    if ($a =~ /^-o/) {
        emit_and_exit('deny', 'write/output flag');
    }
    if ($a =~ /^--([^=]*)/) {
        my $name = $1;
        if (length $name
            && (index('output', $name) == 0 || index($name, 'output') == 0)) {
            emit_and_exit('deny', 'write/output flag');
        }
    }
}

emit_and_exit('allow', 'allowlisted read-only command');
PERL
exec perl -e "$src" -- "$d/../scripts"
