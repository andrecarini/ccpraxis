#!/usr/bin/env perl
# platform: any
# The guards parse a Bash-tool command as bash, but on macOS the Bash tool
# runs zsh. Two zsh spellings change what a command writes or runs, and both
# used to pass every guard (measured against the almanac guard and the git
# guard on a Mac):
#
#   * output redirections bash does not have -- ">!", ">>!", ">>|", "&>!",
#     "&>|", ">&!", ">&|", ">>&", "&>>!", ... Read as bash, "echo x >! f"
#     writes a file named "!" and f is just an argument; zsh writes f, even
#     under noclobber. BpHook::_segments now maps each to the bash operator
#     it means inside its own quote-aware walk, and normalize_redirects does
#     the same for already-stripped text;
#   * a command word "=name", which zsh replaces with the path of name, the
#     precommand modifiers noglob / nocorrect / "-" (which run the next word),
#     its cousins a command word that is a path to git ("/usr/bin/git") and,
#     on case-insensitive macOS and Windows, "GIT".
#
# Z1 the lexer, Z2 GuardBash::hyg_targets (what the almanac guard and the
# write-set guard judge), Z3/Z4 the git guard in-process and through its
# wrapper (the text prefilter), Z5 GuardBash's coordinator git rule, Z6 the
# continuity-state guard. The almanac guard's own end-to-end cases are in
# plugins/almanac/tests/t/almanac-bash-write-guard.t (Z-ALM).
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Test::More;
use File::Temp qw(tempdir);
use HostCaps qw(tempdir_args);
use GuardHarness;

BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }

my $SCRIPTS = "$Bin/../../scripts";
require "$SCRIPTS/BpHook/Guards/GuardBash.pm";

# Assembled so this file's own text never reads as a live git mutation to a
# guard scanning it.
my $ST = 'st' . 'ash';

# ===========================================================================
# Z1 -- the lexer.
# ===========================================================================
{
    my %CASES = (
        '>!'   => '> ',   '>|'   => '> ',
        '>>!'  => '>> ',  '>>|'  => '>> ',
        '&>!'  => '&> ',  '&>|'  => '&> ',  '>&!' => '&> ', '>&|' => '&> ',
        '>>&'  => '&>>',
        '&>>!' => '&>> ', '&>>|' => '&>> ', '>>&!' => '&>> ', '>>&|' => '&>> ',
    );
    for my $op (sort keys %CASES) {
        my $cmd = "echo x $op out.txt";
        my $norm = BpHook::normalize_redirects($cmd);
        is($norm, "echo x $CASES{$op} out.txt", "Z1: normalize_redirects maps $op to '$CASES{$op}'");
        is(length($norm), length($cmd), "Z1: ...keeping the length (offsets stay valid)");
        my @segs = grep { /\S/ } BpHook::_segments($cmd);
        is(scalar(@segs), 1, "Z1: _segments keeps 'echo x $op out.txt' one command (its | or & does not split it)");
        like($segs[0] // '', qr/\Q$CASES{$op}\E\s*out\.txt/, "Z1: ...and carries the bash spelling '$CASES{$op}'");
    }
    for my $bash (q{echo x > f}, q{echo x >> f}, q{echo x &> f}, q{echo x &>> f}, q{echo x 2>&1}, q{echo x >&2}, q{a | b}, q{a |& b}) {
        is(BpHook::normalize_redirects($bash), $bash, "Z1: bash's own spelling is left alone: $bash");
    }
    # Quoted text is data, never a redirect, in _segments' quote-aware walk.
    my @q = BpHook::_segments(q{echo "a >! b" 'c >>| d'});
    is(scalar(grep { /\S/ } @q), 1, 'Z1: a quoted ">!" / ">>|" is not lexed (one segment)');
    like($q[0], qr/"a >! b" 'c >>\| d'/, 'Z1: ...and keeps its text byte for byte');
    # An apostrophe in a comment must not desync the walk: the redirect on
    # the next line is still seen (one lexer pass, not a second quote mask).
    my @c = grep { /\S/ } BpHook::_segments("echo x # it's here\necho y >! f");
    ok((grep { /echo y >  f/ } @c), q{Z1: a "#" comment's apostrophe does not hide a later ">!"});
    # A command substitution inside double quotes is lexed afresh.
    my @s = grep { /\S/ } BpHook::_segments(q{echo "$(echo z >! f)"});
    ok((grep { /echo z >  f/ } @s), 'Z1: ">!" inside "$( )" is a real redirect');
}

# ===========================================================================
# Z2 -- GuardBash::hyg_targets: the write/delete targets the almanac guard
# and the write-set guard judge.
# ===========================================================================
sub targets_of {
    my ($cmd) = @_;
    my @t = BpHook::Guards::GuardBash::hyg_targets($cmd);
    return map {
        my $w = $_->{word};
        my $lit = (ref $w eq 'HASH') ? ($w->{literal} // $w->{raw} // '') : '';
        "$_->{kind}:$lit";
    } grep { ref $_ eq 'HASH' && ($_->{kind} // '') ne 'cd' } @t;
}
{
    for my $op ('>!', '>>!', '>>|', '&>!', '&>|', '>&!', '>&|', '>>&', '&>>!', '>>&!', '2>!', '>|') {
        my @t = targets_of("echo x $op /p/out.md");
        ok((grep { $_ eq 'write:/p/out.md' } @t), "Z2: 'echo x $op /p/out.md' writes /p/out.md")
            or diag(join(', ', @t));
        ok(!(grep { /:!/ } @t), "Z2: ...and not a file named '!'") or diag(join(', ', @t));
    }
    my @g = targets_of('echo x>!/p/out.md');
    ok((grep { $_ eq 'write:/p/out.md' } @g), 'Z2: a glued "x>!/p/out.md" writes /p/out.md') or diag(join(', ', @g));
    my @p = targets_of('echo x >>| /p/out.md && echo done');
    ok((grep { $_ eq 'write:/p/out.md' } @p), 'Z2: ">>|" followed by && still yields its target') or diag(join(', ', @p));

    my %WORD = (
        '=rm /p/a.md'           => 'delete:/p/a.md',
        '=rmdir /p/d'           => 'delete:/p/d',
        '=tee /p/a.md'          => 'write:/p/a.md',
        '=touch /p/a.md'        => 'write:/p/a.md',
        '=env =rm /p/a.md'      => 'delete:/p/a.md',
        'sudo =rm /p/a.md'      => 'delete:/p/a.md',
        '/bin/rm /p/a.md'       => 'delete:/p/a.md',
        # zsh precommand modifiers run the next word as the command.
        'noglob rm /p/a.md'     => 'delete:/p/a.md',
        'nocorrect rm /p/a.md'  => 'delete:/p/a.md',
        '- rm /p/a.md'          => 'delete:/p/a.md',
        'noglob =tee /p/a.md'   => 'write:/p/a.md',
    );
    for my $cmd (sort keys %WORD) {
        my @t = targets_of($cmd);
        ok((grep { $_ eq $WORD{$cmd} } @t), "Z2: '$cmd' -> $WORD{$cmd} (zsh runs =name as name)")
            or diag(join(', ', @t));
    }
    my @eq = targets_of('FOO=/bin/rm echo /p/a.md');
    ok(!(grep { /^delete:/ } @eq), 'Z2: an assignment "FOO=/bin/rm" is not a command word') or diag(join(', ', @eq));
}

# ===========================================================================
# Z3 -- the git guard, in-process.
# ===========================================================================
sub payload {
    my (%o) = @_;
    my $p = { tool_name => 'Bash', tool_input => { command => $o{cmd} } };
    $p->{agent_id} = $o{agent_id} if exists $o{agent_id};
    return $p;
}
sub ggm { return GuardHarness::run_module('Guards::GuardGitMutations', payload(@_)) }
{
    my @deny = (
        "=git $ST"                         => 'zsh "=git" (expands to the path of git)',
        "/usr/bin/git $ST"                 => 'an absolute path to git',
        "./bin/git $ST"                    => 'a relative path to git',
        "\\git $ST"                        => 'a backslash-quoted git',
        "git.exe $ST"                      => 'git.exe',
        "GIT $ST"                          => 'GIT (macOS and Windows resolve it to git)',
        "=git checkout main"               => '=git checkout',
        "/usr/bin/git reset --hard"        => '/usr/bin/git reset',
        "=bash -c \"git $ST\""             => 'a quoted mutation run by =bash -c',
        "/bin/bash -c \"git $ST\""         => 'a quoted mutation run by /bin/bash -c',
        "=bash <<'EOF'\ngit $ST\nEOF"      => 'a heredoc fed to =bash',
        "/bin/sh <<'EOF'\ngit $ST\nEOF"    => 'a heredoc fed to /bin/sh',
    );
    while (my ($cmd, $label) = splice(@deny, 0, 2)) {
        is(ggm(cmd => $cmd)->{rc}, 2, "Z3: deny -- $label") or diag("cmd: $cmd");
    }
    my @allow = (
        '=git status'                 => 'a read-only verb through =git',
        "/usr/bin/git $ST list"       => "/usr/bin/git $ST list (list/show stay allowed)",
        'FOO=/usr/bin/git status'     => 'an assignment that merely names git',
        'echo /usr/bin/git'           => 'an argument that is a path to git',
        "echo 'git $ST'"              => 'a quoted mention',
        "ls src/git/$ST"              => 'a path segment named git',
    );
    while (my ($cmd, $label) = splice(@allow, 0, 2)) {
        is(ggm(cmd => $cmd)->{rc}, 0, "Z3: allow -- $label") or diag("cmd: $cmd");
    }
    # A subagent may list branches into a file with zsh's ">!"; the file is
    # the redirect's target, not a branch name being created.
    is(ggm(cmd => 'git branch >! branches.txt', agent_id => 'a1')->{rc}, 0,
       'Z3: subagent "git branch >! branches.txt" is a listing, allowed');
    is(ggm(cmd => 'git branch &>| branches.txt', agent_id => 'a1')->{rc}, 0,
       'Z3: subagent "git branch &>| branches.txt" is a listing, allowed');
    is(ggm(cmd => 'git branch newname', agent_id => 'a1')->{rc}, 2,
       'Z3: subagent "git branch newname" still creates a branch, denied');
}

# ===========================================================================
# Z4 -- the git guard through its wrapper: the text prefilter runs before
# perl, so a case-sensitive "git" there let "GIT <verb>" through untouched.
# ===========================================================================
{
    my $wrapper = "$Bin/../../hooks/guard-git-mutations.sh";
    for my $cmd ("GIT $ST", "Git $ST", "gIT $ST", "=git $ST", "/usr/bin/git $ST") {
        my $r = GuardHarness::run_wrapper($wrapper, payload(cmd => $cmd));
        is($r->{rc}, 2, "Z4: through guard-git-mutations.sh, '$cmd' is denied") or diag("err: $r->{err}");
    }
    my $r = GuardHarness::run_wrapper($wrapper, payload(cmd => 'ls -la'));
    is($r->{rc}, 0, 'Z4: a command with no git in any case is allowed');
}

# ===========================================================================
# Z5 -- GuardBash's coordinator git rule (GB-a), same command-word reading.
# ===========================================================================
{
    my %COORD = (BP_LEDGER => '/x/ledger.md');
    for my $cmd ('=git checkout main', '/usr/bin/git reset --hard', "=git $ST", "GIT $ST") {
        my $r = GuardHarness::run_module('Guards::GuardBash', payload(cmd => $cmd), env => \%COORD);
        is($r->{rc}, 2, "Z5: coordinator '$cmd' is denied like its bare-git form");
    }
    my $r = GuardHarness::run_module('Guards::GuardBash', payload(cmd => '=git log -1'), env => \%COORD);
    is($r->{rc}, 0, 'Z5: coordinator "=git log -1" (read-only) is allowed');
}

# ===========================================================================
# Z6 -- the continuity-state guard (guidance, not a boundary): "=rm" is rm,
# and a zsh /dev/null redirect is still not a write.
# ===========================================================================
{
    my $T = tempdir(tempdir_args(), CLEANUP => 1);
    $T =~ s{\\}{/}g;
    my $BSD = "$T/state";
    my $SID = 'sess-zsh-1';
    my $run = sub {
        my ($cmd) = @_;
        my $p = { session_id => $SID, transcript_path => "$T/p/$SID.jsonl", cwd => "$T/p",
                  hook_event_name => 'PreToolUse', tool_name => 'Bash', tool_input => { command => $cmd } };
        return GuardHarness::run_module('Guards::GuardContinuityState', $p, env => { BUTLER_STATE_DIR => $BSD });
    };
    is($run->("=rm $BSD/continuity/armed/$SID")->{rc}, 2, 'Z6: "=rm <armed record>" is refused like rm');
    is($run->("=sed -i s/a/b/ $BSD/continuity/armed/$SID")->{rc}, 2, 'Z6: "=sed -i" on it is refused like sed -i');
    is($run->("cat $BSD/continuity/armed/$SID &>! /dev/null")->{rc}, 0, 'Z6: a read with "&>! /dev/null" is still only a read');
    is($run->("echo x >! $BSD/continuity/armed/$SID")->{rc}, 2, 'Z6: "echo x >! <armed record>" is refused');
    is($run->("noglob rm $BSD/continuity/armed/$SID")->{rc}, 2, 'Z6: "noglob rm <armed record>" is refused like rm');
}

done_testing();
