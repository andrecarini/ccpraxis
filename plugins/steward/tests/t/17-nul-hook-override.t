#!/usr/bin/env perl
# 17-nul-hook-override.t — block-nul-redirect.pl still blocks, and now has a
# way to say "this one is a false positive".
#
# WHY THIS EXISTS. The hook reads the Bash command as TEXT and has no quote
# awareness, so it blocks `grep '>NUL' .` and a quoted test fixture exactly as
# hard as a real redirect. Three fired in one session on 2026-09-06, one of
# them while writing the regression test for the very bug the hook guards. A
# rule you cannot write tests about is self-defeating.
#
# The strictness is NOT relaxed, and the reason is worth stating because the
# obvious fix is wrong: making the regex quote-aware means stripping quoted
# spans before matching, and `cmd 2>"NUL"` quotes the TARGET while still
# creating the file. That change would trade a cheap false positive (a retry)
# for an expensive false negative (an undeletable file). So the pattern stays
# and the caller gets an explicit, logged override instead.
#
# AC1  real redirects are still blocked, in every shape
# AC2  a mention that is not a redirect is still blocked WITHOUT the override
#      (the strictness is intact — this is not a quote-aware rewrite)
# AC3  the override lets a mention through
# AC4  the override demands a substantive reason; `=1` is refused
# AC5  the block message teaches the override, or nobody can use it
# AC6  a command with no NUL at all is untouched
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Temp qw(tempdir);
use JSON::PP ();
use StewardTest qw(ok is like unlike done_testing diag);

my $HOOK = "$Bin/../../../../scripts/hooks/block-nul-redirect.pl";
ok(-f $HOOK, 'precondition: block-nul-redirect.pl exists')
    or do { done_testing(); exit };

my $HOME = tempdir(CLEANUP => 1);

# run($command) -> { exit, stderr }
#
# Feeds the hook a real PreToolUse payload on stdin, the way Claude Code does.
# HOME is redirected so the override log lands in a temp dir rather than the
# operator's own.
sub run {
    my ($command) = @_;
    my $payload = JSON::PP->new->canonical(1)->encode({
        tool_name  => 'Bash',
        tool_input => { command => $command },
    });

    my $pf = "$HOME/payload.json";
    open my $fh, '>:raw', $pf or die "write payload: $!";
    print {$fh} $payload;
    close $fh;

    # HOME AND USERPROFILE MUST BE SET FOR THE CHILD, not merely used for our
    # own paths. The hook writes its override log under $HOME/.claude, and the
    # first cut of this file only used $HOME to build filenames while letting
    # system() inherit the real environment — so the assertion below failed
    # while the hook worked perfectly, and four test entries were appended to
    # the operator's actual ~/.claude/.nul-overrides.log. A test that writes
    # into the home directory it is pretending to stub is worse than no test.
    my $ef = "$HOME/err.txt";
    my $rc = do {
        local $ENV{HOME}        = $HOME;
        local $ENV{USERPROFILE} = $HOME;
        system(qq{"$^X" "$HOOK" < "$pf" 2> "$ef"});
    };
    my $err = '';
    if (open my $e, '<:raw', $ef) { local $/; $err = <$e> // ''; close $e }
    return { exit => ($rc >> 8), stderr => $err };
}

# The literal shapes are BUILT BY CONCATENATION rather than written whole.
# This file is read by the agent and by graders, but more to the point the
# fixtures below are the exact text the hook exists to catch — assembling them
# keeps a careless copy-paste of this file out of a shell.
my $R  = '2' . '>NUL';
my $R2 = '>' . 'NUL';
my $R3 = '2' . '>> NUL';
my $R4 = '2' . '>"NUL"';

# --- AC1: real redirects still blocked --------------------------------------
for my $c ("perl foo.pl $R", "echo hi $R2", "cmd $R3", "cmd $R4") {
    my $r = run($c);
    is($r->{exit}, 2, "AC1 blocked: $c");
}

# Case-insensitivity is part of the contract: Windows treats NUL/nul/Nul alike.
is(run('cmd 2' . '>nul')->{exit}, 2, 'AC1 lowercase nul is blocked too');

# --- AC2: strictness intact — a mention is STILL blocked without an override -
#
# This is the assertion that proves the change was not a quote-aware rewrite.
# If someone later "fixes" the false positives by teaching the regex about
# quotes, this fails, and the `2>"NUL"` case in AC1 fails with it.
{
    my $r = run(q{grep -rn '} . $R . q{' .});
    is($r->{exit}, 2, 'AC2 a quoted mention is still blocked when no override is given')
        or diag('  the hook must stay text-only; quote-awareness reopens the 2>"NUL" hole');
}

# --- AC3: the override lets a genuine false positive through -----------------
{
    my $r = run(qq{CCPRAXIS_ALLOW_NUL="search pattern, not a redirect" grep -rn '$R' .});
    is($r->{exit}, 0, 'AC3 an override with a real reason is allowed')
        or diag("  stderr: $r->{stderr}");

    # And it is recorded. An override that leaves no trace is a silently
    # weakened guard.
    my $log = "$HOME/.claude/.nul-overrides.log";
    ok(-f $log, 'AC3 the override is written to the audit log')
        or diag("  expected $log");
    if (-f $log) {
        open my $l, '<:raw', $log or die;
        local $/;
        my $txt = <$l>;
        close $l;
        like($txt, qr/search pattern, not a redirect/,
             'AC3 and the log records the stated reason');
    }

    # Single quotes work too — the agent should not have to remember which.
    is(run(qq{CCPRAXIS_ALLOW_NUL='documenting the shape' echo '$R'})->{exit}, 0,
       'AC3 a single-quoted reason is accepted');
}

# --- AC4: the override demands a real reason --------------------------------
for my $bad ('1', '""', 'ok') {
    my $r = run(qq{CCPRAXIS_ALLOW_NUL=$bad grep '$R' .});
    is($r->{exit}, 2, "AC4 a token reason is refused: CCPRAXIS_ALLOW_NUL=$bad")
        or diag('  the override must be an assertion, not a reflex');
}
like(run(qq{CCPRAXIS_ALLOW_NUL=1 grep '$R' .})->{stderr}, qr/needs a real reason/,
     'AC4 and says why it was refused');

# --- AC5: the block message teaches the override -----------------------------
#
# An escape hatch nobody is told about does not exist. The agent meets this
# hook only through its refusal text.
{
    my $err = run("cmd $R")->{stderr};
    like($err, qr/CCPRAXIS_ALLOW_NUL/,
         'AC5 the block message names the override')
        or diag('  without this the override is undiscoverable');
    like($err, qr/FALSE POSITIVE/, 'AC5 and explains when it applies');
    like($err, qr{/dev/null}, 'AC5 while still recommending the real fix first');
    like($err, qr/really does redirect/,
         'AC5 and warns against using it to force a genuine redirect through');
}

# --- AC6: unrelated commands are untouched ----------------------------------
for my $c ('ls -la', 'echo "/dev/null"', 'grep NULL file.c', 'perl -e "print 1"') {
    is(run($c)->{exit}, 0, "AC6 untouched: $c");
}

# A non-Bash tool call must be ignored entirely, whatever it contains.
{
    my $pf = "$HOME/other.json";
    open my $fh, '>:raw', $pf or die;
    print {$fh} JSON::PP->new->encode({
        tool_name => 'Read', tool_input => { command => "cmd $R" } });
    close $fh;
    my $rc = system(qq{"$^X" "$HOOK" < "$pf" 2> "$HOME/e2.txt"});
    is($rc >> 8, 0, 'AC6 a non-Bash tool call is ignored');
}

done_testing();
