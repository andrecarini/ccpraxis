#!/usr/bin/env perl
# upstream-sync.pl -- the GitHub side of ccpraxis, for /steward:upstream-sync.
#
# The dev clone is the only checkout that talks to GitHub (DevClone.pm has
# the model); /steward:backup manages local state and never touches a
# remote. This script does the remote half, for the dev clone only:
#
#   1. locate the dev clone (the live install's origin, as promote.pl set it)
#      and require it to be on main with an origin remote;
#   2. fetch origin -- the user's fork, which may be private: git's own
#      credential helpers answer, and no prompt is ever opened;
#   3. integrate origin/main into main: a fast-forward when main has nothing
#      of its own, otherwise a merge commit. A conflict is aborted at once
#      (this run started that merge, so nothing of the developer's is lost)
#      and reported with the files; a merge or fast-forward git refuses
#      because it would overwrite the developer's uncommitted files stops
#      with nothing changed. Never a stash, never a reset;
#   4. scan what the push would send for secrets (sensitive-check.pl): every
#      file version the outgoing commits add or change, taken from git, so a
#      credential committed and removed again within them is still caught,
#      and the developer's untracked files (which a push never sends) never
#      block it;
#   5. push main to origin, but only after a push_confirmation answer that
#      named the exact commit it was shown (the choice id carries main's
#      sha, so a main that moved after the question is asked about again),
#      then confirm with ls-remote that the remote really has it;
#   6. report how far the dev clone's main is ahead of the live install, and
#      that promotion (/steward:backup, or promote.pl) brings it live.
#
# STATELESS: every invocation recomputes from git. A re-invocation with an
# answer refetches (a no-op when nothing moved), finds the integration
# already done, and pushes -- there is no run-state file to go stale.
#
# USAGE
#   perl upstream-sync.pl run [--json] [--answer <id>=<choice>] [--live-root DIR] [--clone DIR]
#   perl upstream-sync.pl --help
#
# Exactly one JSON object is written to stdout, as scripts/backup.pl does.
# Exit codes: 0 complete, 10 needs a decision, 20 stopped (something needs
# the operator; stop.reason and stop.fix say what), 2 usage, 4 answer
# refused, 1 internal error.
#
# Core modules only, plus the sibling DevClone.pm.
use strict;
use warnings;
use FindBin ();
use lib $FindBin::Bin;
use JSON::PP;
use Encode ();
use File::Temp ();
use DevClone ();

my $HELP = <<'TXT';
usage: upstream-sync.pl run [--json] [--answer <id>=<choice>] [--live-root DIR] [--clone DIR]
       upstream-sync.pl --help

  run                   fetch origin into the dev clone, integrate origin/main into main, and push main after confirmation
    --json                accepted for the wrapper's calling convention; output is always JSON
    --answer <id>=<choice>  answer the pending push_confirmation (the choice ids carry the sha that was shown)
    --live-root DIR       the live install (default ~/.claude/ccpraxis); its origin names the dev clone
    --clone DIR           use this dev clone instead of the live install's origin (still validated)

Exactly one JSON object is written to stdout per invocation.

Exit codes: 0 complete, 10 needs a decision, 20 stopped (needs the operator), 2 usage, 4 answer refused, 1 internal error.
TXT

use constant PUSH_ID => 'upstream.push_confirmation';

sub emit {
    my ($obj, $code) = @_;
    print JSON::PP->new->utf8->canonical->encode(_chars($obj)), "\n";
    exit $code;
}

# Paths and git output are raw UTF-8 bytes; the ->utf8 encoder wants
# characters. Numbers keep their type.
sub _chars {
    my ($x) = @_;
    if (ref $x eq 'HASH')  { return { map { $_ => _chars($x->{$_}) } keys %$x }; }
    if (ref $x eq 'ARRAY') { return [ map { _chars($_) } @$x ]; }
    return $x if ref $x || !defined $x || utf8::is_utf8($x);
    require B;
    my $fl = B::svref_2object(\$x)->FLAGS;
    return $x if ($fl & (B::SVf_IOK() | B::SVf_NOK())) && !($fl & B::SVf_POK());
    my $copy = $x;
    my $d = eval { Encode::decode('UTF-8', $copy, Encode::FB_CROAK()) };
    return defined $d ? $d : Encode::decode('cp1252', $x, Encode::FB_DEFAULT());
}

sub line { my ($s) = @_; $s //= ''; $s =~ s/\s+\z//; return $s; }
sub clamp { my ($s, $n) = @_; $n //= 4000; return $s if !defined $s || length($s) <= $n; my $t = substr($s, 0, $n); $t =~ s/[\x80-\xBF]+\z//; return $t; }
sub first_line { my ($s) = @_; $s = line($s); $s =~ s/\n.*//s; return $s; }

sub git { return DevClone::run_git(@_); }

sub count_of {
    my ($dir, $range) = @_;
    my ($rc, $out) = git($dir, 'rev-list', '--count', $range);
    my $n = line($out);
    return ($rc == 0 && $n =~ /^\d+\z/) ? $n + 0 : undef;
}

sub commits_in {
    my ($dir, $range) = @_;
    my ($rc, $out) = git($dir, 'log', '--format=%h %s', $range);
    return () unless $rc == 0;
    return grep { length } split /\r?\n/, $out;
}

sub main {
    my @argv = @ARGV;
    my $sub = shift @argv;
    if (!defined $sub || $sub eq '--help' || $sub eq '-h') {
        if (defined $sub) { print $HELP; exit 0; }
        print STDERR $HELP;
        emit({ status => 'error', error => { code => 'usage', message => 'no subcommand given (expected "run" or "--help")' } }, 2);
    }
    unless ($sub eq 'run') {
        print STDERR $HELP;
        emit({ status => 'error', error => { code => 'usage', message => "unknown subcommand '$sub'" } }, 2);
    }

    my (%answer, $live_root, $clone_opt);
    while (@argv) {
        my $a = shift @argv;
        if ($a eq '--json') { next; }
        elsif ($a eq '--answer') {
            my $v = shift @argv;
            emit({ status => 'error', error => { code => 'usage', message => "malformed --answer value (expected id=choice)" } }, 2)
                unless defined $v && $v =~ /^([^=]+)=(.+)\z/;
            $answer{$1} = $2;
        }
        elsif ($a eq '--live-root') { $live_root = shift @argv; }
        elsif ($a eq '--clone')     { $clone_opt = shift @argv; }
        else { emit({ status => 'error', error => { code => 'usage', message => "unrecognized option '$a'" } }, 2); }
    }
    for my $id (keys %answer) {
        emit({ status => 'error', error => { code => 'answer_unknown_id',
               message => "answer references unknown decision id '$id'; the only decision is " . PUSH_ID } }, 4)
            unless $id eq PUSH_ID;
    }

    $live_root //= DevClone::default_live_root();
    my %r = (status => undef, live_root => $live_root, dev_clone => undef, remote => undef,
             fetch => undef, integration => undef, scan => undef, push => { status => 'not_reached' },
             live => undef, notes => []);
    my $stop = sub {
        my ($reason, $fix) = @_;
        $r{status} = 'stopped';
        $r{stop} = { reason => $reason, fix => $fix };
        live_report(\%r);
        emit(\%r, 20);
    };

    # ---- 1. the dev clone ----
    my $loc = DevClone::locate(live_root => $live_root, override => $clone_opt);
    $stop->("no dev clone: $loc->{reason}", $loc->{fix}) unless defined $loc->{dev_clone};
    my $clone = $loc->{dev_clone};
    $r{dev_clone} = $clone;
    my ($brc, $bout) = git($clone, 'rev-parse', '--abbrev-ref', 'HEAD');
    my $branch = line($bout);
    $stop->("the dev clone is " . ($branch eq 'HEAD' ? 'on a detached HEAD' : "on branch '$branch'") . ', not main',
            "check out main in the dev clone ($clone), then run this again") unless $brc == 0 && $branch eq 'main';
    my ($orc, $oout) = git($clone, 'remote', 'get-url', 'origin');
    $stop->('the dev clone has no origin remote', "add your fork: git -C " . DevClone::git_path($clone) . ' remote add origin <url>')
        unless $orc == 0 && length line($oout);
    my $remote = DevClone::redact(line($oout));
    $r{remote} = $remote;
    my ($mrc) = git($clone, 'rev-parse', '-q', '--verify', 'MERGE_HEAD');
    $stop->('a merge is already in progress in the dev clone', 'finish it or abort it there, then run this again') if $mrc == 0;

    # ---- 2. fetch ----
    my ($frc, undef, $ferr) = git($clone, 'fetch', 'origin');
    $r{fetch} = { ok => ($frc == 0 ? 1 : 0), error => ($frc == 0 ? undef : DevClone::redact(clamp(line($ferr)))) };
    $stop->('fetching origin failed: ' . first_line($r{fetch}{error} // "git fetch exited $frc"),
            'check the network and the credentials git uses for your fork, then run this again') unless $frc == 0;

    # ---- 3. integrate origin/main ----
    my ($hrc, $hout) = git($clone, 'rev-parse', 'refs/heads/main');
    my $head_before = line($hout);
    my ($rmrc) = git($clone, 'rev-parse', '-q', '--verify', 'refs/remotes/origin/main');
    my $has_remote_main = $rmrc == 0;
    my $behind = $has_remote_main ? count_of($clone, 'main..origin/main') : 0;
    my $ahead  = $has_remote_main ? count_of($clone, 'origin/main..main') : count_of($clone, 'main');
    $stop->('cannot count the commits between main and origin/main', 'run git status in the dev clone and try again')
        unless defined $behind && defined $ahead;
    my %int = (action => 'none', behind => $behind, ahead_before => $ahead, commits => [ ],
               head_before => $head_before, head_after => $head_before, error => undef, conflicts => []);
    $r{integration} = \%int;
    if ($behind > 0) {
        $int{commits} = [ commits_in($clone, 'main..origin/main') ];
        if ($ahead == 0) {
            my ($rc, $out, $err) = git($clone, 'merge', '--ff-only', 'origin/main');
            if ($rc != 0) {
                $int{action} = 'stopped';
                $int{error}  = clamp(line("$err$out"));
                $stop->('git refused to fast-forward main to origin/main, nothing was changed: ' . first_line($int{error}),
                        'the incoming commits touch files you have uncommitted changes to: commit or set them aside yourself, then run this again');
            }
            $int{action} = 'fast_forward';
        }
        else {
            my ($rc, $out, $err) = git($clone, 'merge', '--no-edit', 'origin/main');
            if ($rc != 0) {
                my ($inprog) = git($clone, 'rev-parse', '-q', '--verify', 'MERGE_HEAD');
                $int{action} = 'stopped';
                $int{error}  = clamp(line("$err$out"));
                if ($inprog == 0) {
                    my (undef, $u) = git($clone, '-c', 'core.quotePath=false', 'diff', '--name-only', '--diff-filter=U');
                    $int{conflicts} = [ grep { length } split /\r?\n/, $u ];
                    # This run started the merge a moment ago, so aborting it
                    # restores exactly the state before it; the developer's
                    # unrelated uncommitted files are left as they were.
                    my ($arc, undef, $aerr) = git($clone, 'merge', '--abort');
                    $stop->('merging origin/main into main conflicted in: ' . join(', ', @{ $int{conflicts} })
                            . ($arc == 0 ? '; the merge was aborted, nothing changed' : '; aborting the merge FAILED: ' . first_line($aerr)),
                            'merge by hand in the dev clone: git -C ' . DevClone::git_path($clone) . ' merge origin/main');
                }
                $stop->('git refused to merge origin/main into main, nothing was changed: ' . first_line($int{error}),
                        'the merge would overwrite files you have uncommitted (or staged) changes to: commit or set them aside yourself, then run this again');
            }
            $int{action} = 'merge';
        }
        my (undef, $ha) = git($clone, 'rev-parse', 'refs/heads/main');
        $int{head_after} = line($ha);
    }

    # ---- 4/5. push ----
    my $main = $int{head_after};
    my @outgoing = $has_remote_main ? commits_in($clone, 'origin/main..main') : commits_in($clone, 'main');
    $r{push} = { status => 'nothing', commits => \@outgoing, main => $main, remote_sha => undef, warnings => [], error => undef };
    unless (@outgoing) {
        $r{status} = 'complete';
        live_report(\%r);
        emit(\%r, 0);
    }

    my ($src, $sout, $serr, $scanned) = scan_outgoing($clone, $has_remote_main);
    $r{scan} = { clean => ($src == 0 ? 1 : 0), exit => $src, findings => ($src == 1 ? clamp($sout) : undef),
                 commits_scanned => $scanned };
    if ($src != 0) {
        $r{push}{status} = 'not_reached';
        $stop->($src == 1 ? 'the secret scan found likely credentials in what the push would send; nothing was pushed'
                          : "the secret scan could not run (exit $src); nothing was pushed",
                $src == 1 ? 'remove them -- from the history too, since every outgoing commit is sent -- then run this again' : first_line($serr));
    }

    my $short = substr($main, 0, 12);
    my $choice = $answer{ PUSH_ID() };
    if (defined $choice && $choice eq 'abort') {
        $r{push}{status} = 'aborted';
        $r{status} = 'complete';
        live_report(\%r);
        emit(\%r, 0);
    }
    if (defined $choice && $choice ne "push_$short") {
        if ($choice =~ /^push_[0-9a-f]{12}\z/) {
            push @{ $r{notes} }, "main moved since the question was asked (it was " . substr($choice, 5) . ", it is now $short); asking again";
        }
        else {
            emit({ status => 'error', error => { code => 'answer_unknown_choice',
                   message => "decision '" . PUSH_ID . "': choice '$choice' is not valid; valid choices: push_$short, abort" } }, 4);
        }
        undef $choice;
    }
    unless (defined $choice) {
        $r{push}{status} = 'pending';
        $r{status} = 'needs_decision';
        my $n = scalar(@outgoing);
        $r{decisions} = [ {
            id      => PUSH_ID,
            kind    => 'push_confirmation',
            phase   => 'upstream',
            title   => "push $n commit(s) from the dev clone's main to origin?",
            subject => $clone,
            detail  => join("\n", "remote: $remote", "dev clone: $clone",
                            ($has_remote_main ? "commits origin/main does not have ($n):" : "origin has no main yet; all $n commit(s):"),
                            map { "  $_" } @outgoing),
            data    => { remote => $remote, commits => \@outgoing, count => scalar(@outgoing), main => $main },
            choices => [
                { id => "push_$short", label => "Push these $n commit(s) to $remote" },
                { id => 'abort',       label => 'Do not push' },
            ],
        } ];
        live_report(\%r);
        emit(\%r, 10);
    }

    my ($prc, $pout, $perr) = git($clone, 'push', 'origin', 'main');
    my $perr_r = DevClone::redact($perr // '');
    $r{push}{warnings} = [ grep { length } split /\r?\n/, $perr_r ];
    if ($prc != 0) {
        $r{push}{status} = 'rejected';
        $r{push}{error}  = clamp(line($perr_r));
        $stop->("git push was rejected (exit $prc): " . first_line($r{push}{error}),
                'read the remote\'s message above; if origin moved, run this again to integrate it first');
    }
    # A push client killed by a signal behind a wrapper can exit looking like
    # a clean 0 on Windows: ask the remote itself before reporting success.
    my ($lrc, $lout) = git($clone, 'ls-remote', 'origin', 'refs/heads/main');
    my ($remote_sha) = split /\s+/, ($lout // '');
    $r{push}{remote_sha} = $remote_sha;
    if ($lrc != 0 || !defined $remote_sha || $remote_sha ne $main) {
        $r{push}{status} = 'unverified';
        $stop->('git push reported success but origin does not show main at ' . substr($main, 0, 7)
                . ' -- treating it as not pushed', 'run this again; it pushes again if the remote still lacks it');
    }
    $r{push}{status} = 'pushed';
    $r{status} = 'complete';
    live_report(\%r);
    emit(\%r, 0);
}

# What a push sends, scanned: for each outgoing commit, the files it adds or
# changes (a merge: against its first parent), as git has them in that
# commit, extracted into a temporary tree that sensitive-check.pl walks.
# Returns ($exit, $stdout, $stderr, $commits_scanned); findings name
# <commit>/<path>. Past MAX_SCAN_COMMITS (a first push of a long history)
# the tip's whole tree is scanned instead.
use constant MAX_SCAN_COMMITS => 300;
sub scan_outgoing {
    my ($clone, $has_remote_main) = @_;
    my $range = $has_remote_main ? 'origin/main..main' : 'main';
    my ($rc, $out) = git($clone, 'rev-list', '--parents', $range);
    return (2, '', "cannot list the outgoing commits", 0) if $rc != 0;
    my @commits = map { [ split / / ] } grep { length } split /\r?\n/, $out;
    my $tmp = File::Temp::tempdir(CLEANUP => 1);
    my @plan;   # [ sha, [paths] ]
    if (@commits > MAX_SCAN_COMMITS) {
        @plan = ([ $commits[0][0], undef ]);
    }
    else {
        for my $c (@commits) {
            my ($sha, @parents) = @$c;
            my ($drc, $dout) = @parents > 1
                ? git($clone, '-c', 'core.quotePath=false', 'diff', '--name-only', '--diff-filter=AM', $parents[0], $sha)
                : git($clone, '-c', 'core.quotePath=false', 'diff-tree', '-r', '--root', '--no-commit-id',
                      '--name-only', '--diff-filter=AM', $sha);
            return (2, '', "cannot list the files of $sha", 0) if $drc != 0;
            my @paths = grep { length } split /\r?\n/, $dout;
            push @plan, [ $sha, \@paths ] if @paths;
        }
    }
    require Archive::Tar;
    for my $p (@plan) {
        my ($sha, $paths) = @$p;
        my ($arc, $tar, $aerr) = git($clone, 'archive', '--format=tar', $sha, ($paths ? ('--', @$paths) : ()));
        return (2, '', "git archive $sha failed: " . first_line($aerr), 0) if $arc != 0;
        my ($tfh, $tname) = File::Temp::tempfile(DIR => $tmp, UNLINK => 1);
        binmode $tfh;
        print {$tfh} $tar;
        close $tfh;
        my $dest = "$tmp/" . substr($sha, 0, 12);
        mkdir $dest;
        my $t = Archive::Tar->new;
        $t->read($tname) or return (2, '', "cannot read the archive of $sha", 0);
        $t->setcwd($dest);
        $t->extract or return (2, '', "cannot extract the archive of $sha", 0);
        unlink $tname;
    }
    return (0, "No sensitive data found.\n", '', 0) unless @plan;
    my ($src, $sout, $serr) = DevClone::run_capture($^X, "$FindBin::Bin/sensitive-check.pl", $tmp);
    $sout =~ s/\Q$tmp\E\///g;
    return ($src, $sout, $serr, scalar(@commits));
}

# How far the dev clone is ahead of the live install, and what brings it live.
sub live_report {
    my ($r) = @_;
    return unless defined $r->{dev_clone};
    my $rel = DevClone::relation(live_root => $r->{live_root}, dev_clone => $r->{dev_clone});
    my %l = (state => $rel->{state}, ahead_of_live => undef, hint => undef);
    if (defined $rel->{error}) {
        $l{hint} = $rel->{error};
    }
    elsif ($rel->{state} eq 'same') {
        $l{ahead_of_live} = 0;
        $l{hint} = "the live install is at the dev clone's main";
    }
    elsif ($rel->{state} eq 'ahead') {
        my $n = scalar(@{ $rel->{commits} });
        $l{ahead_of_live} = scalar(@{ $rel->{commits} });   # a number, not the interpolated copy
        $l{hint} = "the dev clone's main is $n commit(s) ahead of the live install; /steward:backup "
                 . '(or perl ' . DevClone::git_path($r->{dev_clone}) . '/scripts/promote.pl) brings them live';
    }
    else {
        $l{hint} = 'the live install has commits the dev clone does not; ' . $rel->{fix};
    }
    $r->{live} = \%l;
    return;
}

unless (caller) {
    my $ok = eval { main(); 1 };
    unless ($ok) {
        my $e = $@ // 'unknown error';
        $e =~ s/\s+\z//;
        print JSON::PP->new->utf8->canonical->encode({ status => 'error', error => { code => 'internal', message => "$e" } }), "\n";
        exit 1;
    }
}

1;
