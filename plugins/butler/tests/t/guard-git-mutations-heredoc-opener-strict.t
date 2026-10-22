#!/usr/bin/env perl
# platform: any
# Heredoc opener strictness in GuardGitMutations' heredoc branch (todo
# 20261002-003205-fb7e0000).
#
# When a command holds a '<<' and neither a backslash nor a '#' sends it to the
# raw fallback first, _git_scan_target masks heredoc bodies with
# BpHook::Guards::Shell::strip_noise. strip_noise reads an opener more loosely
# than bash does, so a command could make the guard mask, as "heredoc body",
# lines that bash actually executes:
#
#   - a delimiter word with a suffix after the quote (<<'EOF'x, <<"EOF"x),
#     a quoted suffix (<<EOF"x") or a quote mid-word (<<E'OF'): bash's
#     delimiter is EOFx / EOF, strip_noise's is EOF / E;
#   - an empty delimiter (<<''): bash ends that body at the first empty line,
#     strip_noise does not see an opener at all;
#   - a '<<' that is not a redirection at all: arithmetic ((..)), $[..],
#     ${a[..]}, or a ${x:-..} word.
#
# The package-08 write-only path (_heredoc_write_only_outer) already refused
# these shapes, but a refusal there only falls back to the strip_noise branch,
# which let them through. Package 08's own P8-AC-29..35 pins all carry a
# backslash in the body, which sends them to the raw fallback before the
# heredoc branch is reached; every DENY fixture here is free of backslash, and
# all but one free of '#', so it exercises the heredoc branch itself.
#
# The ALLOW block pins that legitimate heredocs (commit messages, notes files)
# whose BODIES contain the same tricky text stay allowed: the stricter check
# looks only at text outside heredoc bodies and quotes.
#
# Mutation verbs are assembled at runtime so this file's own text never reads
# as a mutation to a live copy of the guard.
#
# Runs standalone: perl this file
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);

BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }

use lib dirname(__FILE__) . '/../lib';
use GuardHarness;

delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
$ENV{CCPRAXIS_NO_WAKELOCK} = 1;

my $ST = 'git ' . 'st' . 'ash';
my $RH = 'git ' . 're' . 'set --hard';

sub ggm {
    my ($cmd) = @_;
    return GuardHarness::run_module('Guards::GuardGitMutations',
        { tool_name => 'Bash', tool_input => { command => $cmd } });
}

# ---------------------------------------------------------------------------
# DENY: bash executes the mutation line; the guard must see it.
# ---------------------------------------------------------------------------
my @deny = (
    [qq{cat > f <<'EOF'x\nEOFx\n$ST\nEOF},             q{single-quoted delimiter with a bare suffix (<<'EOF'x)}],
    [qq{cat > f <<"EOF"x\nEOFx\n$ST\nEOF},             q{double-quoted delimiter with a bare suffix (<<"EOF"x)}],
    [qq{cat > f <<EOF"x"\nEOFx\n$ST\nEOF},             q{bare delimiter with a quoted suffix (<<EOF"x")}],
    [qq{cat > f <<EOF'x'\nEOFx\n$RH\nEOF},             q{bare delimiter with a single-quoted suffix (<<EOF'x')}],
    [qq{cat > f <<E'OF'\nEOF\n$ST\nE},                 q{quote mid-word (<<E'OF'): bash reads EOF}],
    [qq{cat > g <<''\ncat > h <<'END'\n\n$ST\nEND},    q{empty delimiter (<<'') ends at the first empty line}],
    [qq{cat > g <<""\ncat > h <<'END'\n\n$ST\nEND},    q{empty double-quoted delimiter (<<"")}],
    [qq{(( x = 1<<2 ))\n$ST\n2},                       q{arithmetic shift inside ((..)) is not an opener}],
    [qq{echo \$[1<<2 ]\n$ST\n2},                       q{arithmetic shift inside $[..] is not an opener}],
    [qq{echo \${a[1<<2 ]}\n$ST\n2},                    q{arithmetic shift inside ${a[..]} is not an opener}],
    [qq{echo \${x:- <<EOF }\n$ST\nEOF},                q{'<<' inside a ${x:-..} word is not an opener}],
    [qq{cat > "a#b" <<'EOF'x\nEOFx\n$ST\nEOF},         q{bare suffix with a quoted '#' elsewhere (hash path into the heredoc branch)}],
);
for my $c (@deny) {
    my ($cmd, $label) = @$c;
    unlike($cmd, qr/[\\]/, "fixture has no backslash: $label");
    my $res = ggm($cmd);
    is($res->{rc}, 2, "DENY: $label") or diag("cmd:\n$cmd\nout: $res->{err}");
}

# ---------------------------------------------------------------------------
# DENY, raw-fallback anchor: a '#' or a backslash forces the raw fallback,
# which skips the shellword check, so its anchor must accept a quote or a
# backtick before "git". Before the fix every one of these was allowed.
# ---------------------------------------------------------------------------
my $BS = chr(92);
my @deny_raw = (
    [qq{bash -c "$ST" # note},        q{bash -c "..." with a trailing comment}],
    [qq{eval '$RH' # note},           q{eval '...' with a trailing comment}],
    [qq{x=`$ST` # note},              q{backtick carrier with a trailing comment}],
    [qq{bash -c '$ST' a${BS}b},       q{bash -c '...' with a backslash elsewhere}],
    [qq{echo hi # c\n`$ST`},          q{backtick carrier on a later line after a comment}],
);
for my $c (@deny_raw) {
    my ($cmd, $label) = @$c;
    my $res = ggm($cmd);
    is($res->{rc}, 2, "DENY (raw anchor): $label") or diag("cmd:\n$cmd");
}

# ---------------------------------------------------------------------------
# ALLOW: legitimate heredocs whose bodies merely mention the verbs or carry
# the same tricky text must stay allowed.
# ---------------------------------------------------------------------------
my @allow = (
    [qq{git commit -F - <<'EOF'\nguard: explain why $ST is banned\n\nAlso $RH lost work.\nEOF},
        'commit message heredoc mentioning the verbs'],
    [qq{git commit -F - <<'EOF'\nnotes: (( x = 1<<2 )) and \${a[1<<2 ]} and <<'EOF'x\n$ST\nEOF},
        'commit message whose body holds the tricky opener text'],
    [qq{cat > notes.md <<EOF\nwhy $ST is forbidden\nEOF\nwc -l notes.md},
        'unquoted-delimiter notes file mentioning the verb'],
    [qq{cat > "\${DIR}/notes.md" <<'EOF'\n$RH destroyed a fix-batch\nEOF},
        'quoted ${..} in the redirect target'],
    [qq{cat <<-EOF > n.md\n\twhy $ST is banned\n\tEOF},
        '<<- opener with a tab-indented terminator'],
    [qq{cat > a.md <<'A' ; cat > b.md <<'B'\nx\nA\n$ST in b\nB},
        'two openers on one line, each body only written'],
);
for my $c (@allow) {
    my ($cmd, $label) = @$c;
    my $res = ggm($cmd);
    is($res->{rc}, 0, "ALLOW: $label") or diag("cmd:\n$cmd\nout: $res->{err}");
}

done_testing();
