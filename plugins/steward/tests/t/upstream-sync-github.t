#!/usr/bin/env perl
# platform: host
# /steward:upstream-sync (plugins/steward/scripts/upstream-sync.pl): the
# GitHub side of ccpraxis, for the dev clone only. Fetch origin, integrate
# origin/main into main (fast-forward or a merge commit; a conflict or a
# merge that would overwrite the developer's uncommitted files stops with
# nothing changed), scan, and push main only after a push_confirmation that
# names the exact commit shown; then report how far the dev clone is ahead
# of the live install. The live install is never touched.
#
# Fixtures: a throwaway HOME, a bare "GitHub" repo, a dev clone whose origin
# it is, a second clone standing in for another machine, and the live install
# cloned from the dev clone (promote.pl's first-run shape). No network.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use lib "$Bin/../../scripts";
use File::Path qw(make_path);
use File::Temp qw(tempfile);
use JSON::PP;
use Test::More;
use StewardTest qw(temproot make_machine init_remote write_text read_text);
use DevClone ();

my $SCRIPT = "$Bin/../../scripts/upstream-sync.pl";

sub _native_path { my ($p) = @_; (my $q = $p) =~ s{\\}{/}g; $q =~ s{^/([A-Za-z])/}{\u$1:/}; return $q; }

my $HOME;
sub genv {
    return (HOME => $HOME, USERPROFILE => $HOME, GIT_CONFIG_GLOBAL => "$HOME/.gitconfig",
            GIT_CONFIG_SYSTEM => '/dev/null', GIT_TERMINAL_PROMPT => '0');
}

sub git {
    my ($dir, @args) = @_;
    my %e = genv();
    local @ENV{ keys %e } = values %e;
    open(my $saved, '>&', \*STDOUT) or die;
    open(STDOUT, '>', File::Spec->devnull) or die;
    my $rc = system('git', '-C', _native_path($dir), map { (defined $_ && m{^/}) ? _native_path($_) : $_ } @args);
    open(STDOUT, '>&', $saved);
    die "git -C $dir @args failed\n" if $rc != 0;
}

sub git_out {
    my ($dir, @args) = @_;
    my %e = genv();
    local @ENV{ keys %e } = values %e;
    open my $fh, '-|', 'git', '-C', _native_path($dir), @args or die;
    local $/;
    my $o = <$fh> // '';
    close $fh;
    $o =~ s/\s+\z//;
    return $o;
}

sub commit {
    my ($dir, $file, $content, $msg) = @_;
    write_text("$dir/$file", $content);
    git($dir, 'add', '--', $file);
    git($dir, 'commit', '-q', '-m', $msg);
}

sub fixture {
    my $scratch = temproot();
    $HOME = make_machine($scratch, 'host');
    my $gh    = init_remote($scratch);
    my $clone = "$scratch/devclone";
    my $other = "$scratch/other-machine";
    my $live  = "$HOME/.claude/ccpraxis";
    make_path($clone, "$HOME/.claude");
    git($clone, 'init', '-q');
    commit($clone, 'README.md', "# fork\n", 'initial');
    git($clone, 'remote', 'add', 'origin', $gh);
    git($clone, 'push', '-q', '-u', 'origin', 'main');
    {
        my %e = genv();
        local @ENV{ keys %e } = values %e;
        system('git', 'clone', '-q', _native_path($clone), _native_path($live)) == 0 or die;
        system('git', 'clone', '-q', _native_path($gh), _native_path($other)) == 0 or die;
    }
    return { scratch => $scratch, gh => $gh, clone => $clone, other => $other, live => $live };
}

sub run_sync {
    my (@args) = @_;
    my %e = genv();
    local @ENV{ keys %e } = values %e;
    my ($efh, $ename) = tempfile(UNLINK => 1);
    close $efh;
    open(my $saved, '>&', \*STDERR) or die;
    open(STDERR, '>', $ename) or die;
    my $out = '';
    if (open(my $fh, '-|', $^X, $SCRIPT, 'run', '--json', @args)) { local $/; $out = <$fh> // ''; close $fh; }
    my $exit = $? >> 8;
    open(STDERR, '>&', $saved);
    return { exit => $exit, out => $out, err => read_text($ename) // '', json => (eval { decode_json($out) } // {}) };
}

sub push_choice {
    my ($resp) = @_;
    my ($d) = @{ $resp->{json}{decisions} // [] };
    my ($c) = grep { $_->{id} =~ /^push_/ } @{ ($d // {})->{choices} // [] };
    return $c ? $c->{id} : 'push_none';
}

# ---------------------------------------------------------------------------
# Nothing to do.
# ---------------------------------------------------------------------------
{
    my $f = fixture();
    my $r = run_sync();
    is($r->{exit}, 0, 'nothing: exit 0') or diag($r->{out} . $r->{err});
    is($r->{json}{status}, 'complete', 'nothing: complete');
    is($r->{json}{integration}{action}, 'none', 'nothing: no integration');
    is($r->{json}{push}{status}, 'nothing', 'nothing: nothing to push');
    is($r->{json}{live}{state}, 'same', 'nothing: the live install is at the dev clone\'s main');
    ok(DevClone::same_dir($r->{json}{dev_clone} // '', $f->{clone}), 'nothing: the dev clone is the live install\'s origin');
}

# ---------------------------------------------------------------------------
# Fast-forward: another machine pushed; the dev clone has nothing of its own.
# ---------------------------------------------------------------------------
{
    my $f = fixture();
    commit($f->{other}, 'other.txt', "from the other machine\n", 'other machine work');
    git($f->{other}, 'push', '-q', 'origin', 'main');
    my $live_head = git_out($f->{live}, 'rev-parse', 'HEAD');
    my $r = run_sync();
    is($r->{exit}, 0, 'ff: exit 0') or diag($r->{out} . $r->{err});
    is($r->{json}{integration}{action}, 'fast_forward', 'ff: a fast-forward');
    is(git_out($f->{clone}, 'rev-parse', 'main'), git_out($f->{gh}, 'rev-parse', 'main'), 'ff: main is origin/main');
    is(git_out($f->{clone}, 'rev-list', '--count', '--merges', 'main'), 0, 'ff: no merge commit');
    is($r->{json}{push}{status}, 'nothing', 'ff: nothing to push');
    is($r->{json}{live}{ahead_of_live}, 1, 'ff: the dev clone is one commit ahead of the live install');
    like($r->{json}{live}{hint} // '', qr{/steward:backup .*promote\.pl}, 'ff: the report says promotion brings it live');
    is(git_out($f->{live}, 'rev-parse', 'HEAD'), $live_head, 'ff: the live install is untouched');
}

# ---------------------------------------------------------------------------
# Merge, then push after a confirmation that lists every outgoing commit.
# ---------------------------------------------------------------------------
{
    my $f = fixture();
    commit($f->{other}, 'other.txt', "from the other machine\n", 'other machine work');
    git($f->{other}, 'push', '-q', 'origin', 'main');
    commit($f->{clone}, 'mine.txt', "local work\n", 'local work');
    my $live_head = git_out($f->{live}, 'rev-parse', 'HEAD');

    my $r = run_sync();
    is($r->{exit}, 10, 'merge: the push needs a decision (exit 10)') or diag($r->{out} . $r->{err});
    is($r->{json}{integration}{action}, 'merge', 'merge: origin/main was merged with a merge commit');
    is(git_out($f->{clone}, 'rev-list', '--count', '--merges', 'main'), 1, 'merge: one merge commit on main');
    my ($d) = @{ $r->{json}{decisions} // [] };
    is(($d // {})->{kind}, 'push_confirmation', 'merge: a push_confirmation decision');
    is(($d // {})->{id}, 'upstream.push_confirmation', 'merge: ...with the upstream id');
    like(($d // {})->{detail} // '', qr/local work/, 'merge: the detail lists the local commit');
    like(($d // {})->{detail} // '', qr/Merge/, 'merge: ...and the merge commit');
    like(($d // {})->{detail} // '', qr/\Q$f->{gh}\E/, 'merge: ...and the remote');
    is(($d // {})->{data}{count}, 2, 'merge: data.count is every outgoing commit');
    my $main = git_out($f->{clone}, 'rev-parse', 'main');
    is(push_choice($r), 'push_' . substr($main, 0, 12), 'merge: the push choice names the exact commit shown');
    isnt(git_out($f->{gh}, 'rev-parse', 'main'), $main, 'merge: nothing was pushed before the answer');

    my $r2 = run_sync('--answer', 'upstream.push_confirmation=' . push_choice($r));
    is($r2->{exit}, 0, 'merge: answering push completes') or diag($r2->{out} . $r2->{err});
    is($r2->{json}{push}{status}, 'pushed', 'merge: pushed');
    is($r2->{json}{push}{remote_sha}, $main, 'merge: ls-remote confirms the remote has main');
    is(git_out($f->{gh}, 'rev-parse', 'main'), $main, 'merge: the bare remote has the dev clone\'s main');
    is(git_out($f->{live}, 'rev-parse', 'HEAD'), $live_head, 'merge: the live install is untouched');

    my $r3 = run_sync();
    is($r3->{json}{push}{status}, 'nothing', 'merge: a second run has nothing to push');
}

# ---------------------------------------------------------------------------
# A main that moved after the question is asked about again; abort pushes
# nothing.
# ---------------------------------------------------------------------------
{
    my $f = fixture();
    commit($f->{clone}, 'a.txt', "a\n", 'first local');
    my $r = run_sync();
    my $stale = push_choice($r);
    commit($f->{clone}, 'b.txt', "b\n", 'second local');
    my $r2 = run_sync('--answer', "upstream.push_confirmation=$stale");
    is($r2->{exit}, 10, 'moved: a stale answer is asked about again, not pushed') or diag($r2->{out} . $r2->{err});
    like(join(' ', @{ $r2->{json}{notes} // [] }), qr/main moved since the question/, 'moved: ...and says why');
    like(((($r2->{json}{decisions} // [])->[0]) // {})->{detail} // '', qr/second local/, 'moved: the new question lists the new commit');
    isnt(git_out($f->{gh}, 'rev-parse', 'main'), git_out($f->{clone}, 'rev-parse', 'main'), 'moved: nothing was pushed');
    my $r3 = run_sync('--answer', 'upstream.push_confirmation=abort');
    is($r3->{exit}, 0, 'abort: exit 0');
    is($r3->{json}{push}{status}, 'aborted', 'abort: push.status == aborted');
    isnt(git_out($f->{gh}, 'rev-parse', 'main'), git_out($f->{clone}, 'rev-parse', 'main'), 'abort: nothing was pushed');
    my $r4 = run_sync('--answer', 'upstream.push_confirmation=push_nothex');
    is($r4->{exit}, 4, 'refused: a malformed choice is refused (exit 4)');
    my $r5 = run_sync('--answer', 'upstream.other=push');
    is($r5->{exit}, 4, 'refused: an unknown decision id is refused (exit 4)');
}

# ---------------------------------------------------------------------------
# Conflict: stopped, the merge aborted, nothing changed.
# ---------------------------------------------------------------------------
{
    my $f = fixture();
    commit($f->{other}, 'README.md', "# from the other machine\n", 'other README');
    git($f->{other}, 'push', '-q', 'origin', 'main');
    commit($f->{clone}, 'README.md', "# from this machine\n", 'local README');
    my $head = git_out($f->{clone}, 'rev-parse', 'main');
    my $r = run_sync();
    is($r->{exit}, 20, 'conflict: stopped (exit 20)') or diag($r->{out} . $r->{err});
    is($r->{json}{integration}{action}, 'stopped', 'conflict: integration stopped');
    is(join(',', @{ $r->{json}{integration}{conflicts} // [] }), 'README.md', 'conflict: the conflicting file is named');
    like($r->{json}{stop}{reason} // '', qr/conflicted .*aborted, nothing changed/, 'conflict: the reason says it was aborted');
    like($r->{json}{stop}{fix} // '', qr/merge origin\/main/, 'conflict: the fix is the manual merge');
    is(git_out($f->{clone}, 'rev-parse', 'main'), $head, 'conflict: main is unchanged');
    ok(!-f "$f->{clone}/.git/MERGE_HEAD", 'conflict: no merge left in progress');
    is(read_text("$f->{clone}/README.md"), "# from this machine\n", 'conflict: the working tree is as it was');
    is($r->{json}{push}{status}, 'not_reached', 'conflict: nothing was pushed');
}

# ---------------------------------------------------------------------------
# Dirty overlap: the incoming commit touches a file the developer has
# uncommitted changes to. git refuses; nothing changes; never a stash.
# ---------------------------------------------------------------------------
{
    my $f = fixture();
    commit($f->{other}, 'README.md', "# changed upstream\n", 'upstream README');
    git($f->{other}, 'push', '-q', 'origin', 'main');
    write_text("$f->{clone}/README.md", "# developer's uncommitted edit\n");
    my $head = git_out($f->{clone}, 'rev-parse', 'main');
    my $r = run_sync();
    is($r->{exit}, 20, 'dirty: stopped (exit 20)') or diag($r->{out} . $r->{err});
    like($r->{json}{stop}{reason} // '', qr/git refused to fast-forward main to origin\/main, nothing was changed/, 'dirty: the reason says git refused');
    is(git_out($f->{clone}, 'rev-parse', 'main'), $head, 'dirty: main is unchanged');
    is(read_text("$f->{clone}/README.md"), "# developer's uncommitted edit\n", 'dirty: the developer\'s edit is untouched');
    is(git_out($f->{clone}, 'stash', 'list'), '', 'dirty: nothing was stashed');

    # The same with a merge commit due (main has a commit of its own).
    commit($f->{clone}, 'mine.txt', "mine\n", 'local work');
    my $head2 = git_out($f->{clone}, 'rev-parse', 'main');
    my $r2 = run_sync();
    is($r2->{exit}, 20, 'dirty: a refused merge also stops') or diag($r2->{out} . $r2->{err});
    like($r2->{json}{stop}{reason} // '', qr/git refused to merge origin\/main into main, nothing was changed/, 'dirty: ...saying so');
    is(git_out($f->{clone}, 'rev-parse', 'main'), $head2, 'dirty: main is unchanged');
    ok(!-f "$f->{clone}/.git/MERGE_HEAD", 'dirty: no merge left in progress');
}

# ---------------------------------------------------------------------------
# Secrets are never pushed; a rejected push is reported.
# ---------------------------------------------------------------------------
{
    my $f = fixture();
    commit($f->{clone}, 'leak.json', qq({"key":"sk-ant-api03-not-really-a-key"}\n), 'oops');
    my $r = run_sync();
    is($r->{exit}, 20, 'scan: a finding stops the run (exit 20)') or diag($r->{out} . $r->{err});
    is($r->{json}{scan}{clean}, 0, 'scan: scan.clean == 0');
    like($r->{json}{scan}{findings} // '', qr/^\s+[0-9a-f]{12}\/leak\.json:1:/m, 'scan: the finding names the commit and the file');
    ok(!@{ $r->{json}{decisions} // [] }, 'scan: no push is offered');
    isnt(git_out($f->{gh}, 'rev-parse', 'main'), git_out($f->{clone}, 'rev-parse', 'main'), 'scan: nothing was pushed');
}
{
    # What a push sends is every outgoing commit: a credential committed and
    # removed again in a later outgoing commit is still caught.
    my $f = fixture();
    commit($f->{clone}, 'config.json', qq({"key":"sk-ant-api03-briefly-committed"}\n), 'add a key');
    commit($f->{clone}, 'config.json', qq({"key":"from the environment"}\n), 'remove the key again');
    my $r = run_sync();
    is($r->{exit}, 20, 'scan: a credential in an intermediate outgoing commit stops the push') or diag($r->{out} . $r->{err});
    like($r->{json}{scan}{findings} // '', qr/config\.json/, 'scan: ...naming the file');
    is($r->{json}{scan}{commits_scanned}, 2, 'scan: both outgoing commits were scanned');
}
{
    # A push never sends untracked files, so the developer's work in progress
    # (credential-shaped text and all) does not block it.
    my $f = fixture();
    commit($f->{clone}, 'clean.json', qq({"ok":true}\n), 'clean work');
    write_text("$f->{clone}/scratch.json", qq({"token":"sk-ant-api03-untracked-wip"}\n));
    my $r = run_sync();
    is($r->{exit}, 10, 'scan: an untracked file with a credential does not block the push question') or diag($r->{out} . $r->{err});
    is($r->{json}{scan}{clean}, 1, 'scan: the outgoing commits scan clean');
}
{
    my $f = fixture();
    commit($f->{clone}, 'mine.txt', "mine\n", 'local work');
    write_text("$f->{gh}/hooks/pre-receive", "#!/bin/sh\ncat >/dev/null\necho 'TEST-REJECTION-7c1: declined' 1>&2\nexit 1\n");
    chmod 0755, "$f->{gh}/hooks/pre-receive";
    my $r = run_sync();
    my $r2 = run_sync('--answer', 'upstream.push_confirmation=' . push_choice($r));
    is($r2->{exit}, 20, 'rejected: a rejected push stops (exit 20)') or diag($r2->{out} . $r2->{err});
    is($r2->{json}{push}{status}, 'rejected', 'rejected: push.status == rejected');
    like($r2->{json}{push}{error} // '', qr/TEST-REJECTION-7c1/, 'rejected: the remote\'s message is kept');
}

# ---------------------------------------------------------------------------
# Not runnable: no dev clone (a GitHub origin on the live install), off main.
# ---------------------------------------------------------------------------
{
    my $f = fixture();
    git($f->{live}, 'remote', 'set-url', 'origin', 'https://github.com/someone/ccpraxis.git');
    my $r = run_sync();
    is($r->{exit}, 20, 'located: no dev clone stops (exit 20)');
    like($r->{json}{stop}{reason} // '', qr/no dev clone/, 'located: ...saying so');
    like($r->{json}{stop}{fix} // '', qr/promote\.pl/, 'located: ...with the fix');
    my $r2 = run_sync('--clone', $f->{clone});
    is($r2->{exit}, 0, 'located: --clone names the dev clone explicitly') or diag($r2->{out} . $r2->{err});
}
{
    my $f = fixture();
    git($f->{clone}, 'checkout', '-q', '-b', 'feature');
    my $r = run_sync();
    is($r->{exit}, 20, 'branch: off main stops (exit 20)');
    like($r->{json}{stop}{reason} // '', qr/on branch 'feature', not main/, 'branch: ...saying so');
}

# Credentials in a remote URL never reach the output.
is(DevClone::redact('https://user:ghp_SECRET@github.com/o/r.git'), 'https://<redacted>@github.com/o/r.git',
    'redact: userinfo is removed from a URL');

done_testing();
