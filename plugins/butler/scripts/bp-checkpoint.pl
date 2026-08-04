#!/usr/bin/env perl
# bp-checkpoint.pl — durable WIP checkpoint commits (b02, Decisions #2/#17).
#
# One job: stage ONLY a package's declared write-set pathspecs and make a single
# inline WIP commit on the current branch, so a coordinator that dies mid-step
# has its in-flight work recoverable. Never a run-branch, never a push, never a
# squash — those stay a human's call (Decision #2).
#
# Two shapes, one file (the bp-deps-check.pl / bp-orchestrator.pl convention):
#   • module — `require "<dir>/bp-checkpoint.pl"; BpCheckpoint::checkpoint({...})`.
#     The orchestrator calls it IN-PROCESS: no subprocess, no exit-code scraping.
#     `require` has NO top-level side effects (four test files load the
#     orchestrator, which loads this).
#   • CLI    — `perl bp-checkpoint.pl --pkg <p> --write-set <colon-string> ...`,
#     guarded by `unless (caller)`; exit 0/1/2/3 (see the CLI block at the end).
#
# INVARIANTS (each one is an AC in t/21-durable-checkpoint-commits.t and
# t/22-checkpoint-hardening.t):
#   • NEVER dies. Every failure — no repo, no git binary, a locked index, a
#     rejecting hook, a hung or signal-killed child — is a structured hashref
#     with a closed `reason` enum.
#   • NEVER stages the whole tree. A write-set entry must begin with a LITERAL
#     path segment; every spelling of "everything" (`*`, `**/*`, `./.`, `?*`,
#     `[a-z]*`, ...) is DROPPED, because such a pathspec stages the entire
#     repository — that is the whole point of the exercise.
#   • NEVER a shell. Every git call is fork + exec of the list
#     ('git', '-C', <root>, ...); the working directory is never changed and no
#     command string is ever interpolated.
#   • NEVER executes repo-local config. `core.fsmonitor` / `core.hooksPath` are
#     pinned per invocation, so a worktree-writable config value can never turn
#     a checkpoint into an arbitrary program run as the orchestrator.
#   • NEVER blocks forever. Every child is read under a deadline and killed on
#     expiry: the orchestrator's watch loop is single-threaded.
#   • NEVER commits off a branch. A detached HEAD or an in-progress rebase /
#     merge / cherry-pick / bisect is a clean no-op, not a commit.
#   • NEVER an AI-authorship trailer on a commit message (house rule).
#
# See also: specs/03-durable-checkpoint-commits-spec.md §2.

package BpCheckpoint;
use strict;
use warnings;
use JSON::PP;
use Cwd ();
use POSIX ();
use File::Basename qw(dirname);
# This file is legitimately loaded twice in one interpreter: the orchestrator
# `require`s it by abs_path while a test may `require` the same file by a
# relative path — two %INC keys, one file, so every sub is compiled twice.
# Re-defining a sub with an identical body is not a bug here, and the warning
# would otherwise spray a dozen lines over every suite run. Scoped to this
# package only: `package main` at the bottom turns full warnings back on.
no warnings 'redefine';

our $DETAIL_MAX = 200;                 # `detail` is one trimmed line, at most this long
our $PKG_MAX    = 120;                 # a package id is a slug; a subject line is not a ledger cell
our $GIT_TIMEOUT = 30;                 # seconds a single git child may take before it is killed
our $OUT_MAX    = 1 << 20;             # captured git output we are willing to hold in memory

# ===========================================================================
# PURE
# ===========================================================================

# ISO-8601 UTC, the bp-log.pl:20-23 formatting (kept local: requiring bp-log.pl
# would pull a logger — and its die-on-unwritable-path behaviour — in here).
sub _iso_utc {
    my @t = gmtime(defined $_[0] ? $_[0] : time);
    return sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ",
                   $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0];
}

# --- write_set (the raw ledger frontmatter string) -> git pathspecs.
#
# Deliberately NOT BpOrch::_ws_prefixes: that one cuts each entry at its first
# glob to get a directory PREFIX for overlap detection, so a bare '*' collapses
# to '' — and '' as a git pathspec matches the entire repository. Overlap
# detection wants that lossy widening; staging must never have it.
#
# Returns ($pathspecs, $dropped) — $dropped holds the raw entries rejected by
# the unsafe rules (6-8), for the caller's report. Total: never dies.
sub _parse_write_set {
    my ($ws) = @_;
    my (@out, @dropped, %seen);
    return (\@out, \@dropped) unless defined $ws && !ref $ws && length $ws;
    for my $raw (split /:/, $ws, -1) {
        my $e = $raw;
        $e =~ s/\A\s+//;                       # rule 1: trim
        $e =~ s/\s+\z//;
        next unless length $e;                 # rule 2: empty after trim -> gone (not "dropped")
        if ($e =~ /[\0\n]/) { push @dropped, $e; next }              # rule 8: NUL / newline
        # rule 7: anything that can escape the repository root.
        if ($e =~ m{\A/} || $e =~ m{\A~} || grep { $_ eq '..' } split(m{/}, $e, -1)) {
            push @dropped, $e;
            next;
        }
        my $p = $e;
        $p =~ s{/+\z}{};                       # rule 3: strip trailing slash(es)
        # rule 6 — the whole-tree pathspecs, stated as a REQUIREMENT rather than
        # a denylist. "Everything" has far too many spellings to enumerate ('',
        # '*', '**', '***', '?*', '*?', '[a-z]*', '.', './.', '**/*' all stage
        # the entire repository), so instead the entry must START with a literal
        # path segment: its first '/'-separated component must be non-empty, must
        # not be '.' or '..', and must contain no glob metacharacter (* ? [).
        # Globs stay legal BELOW that literal root — 'plugins/*.pl' and
        # 'lib/**/*.dart' are kept, '*/x' is dropped — which is what confines a
        # checkpoint to its own package's subtree (done-criterion (f)).
        # Rules 4 (globs) and 5 (plain paths) are the fall-through: everything
        # else passes VERBATIM, so git's own wildmatch does the expansion —
        # never Perl, never a shell.
        my ($first) = split m{/}, $p, 2;
        $first = '' unless defined $first;
        if (!length $p || !length $first || $first eq '.' || $first eq '..' || $first =~ /[*?\[]/) {
            push @dropped, $e;
            next;
        }
        next if $seen{$p}++;                   # duplicates: first wins, input order kept
        push @out, $p;
    }
    return (\@out, \@dropped);
}

# The public, single-value form (an arrayref of pathspecs, never dies).
sub parse_write_set {
    my ($ps) = _parse_write_set($_[0]);
    return $ps;
}

# --- is_checkpoint_subject($subject) -> 0|1 (b40, spec section 3.1).
#
# Recognises a commit subject as one of THIS module's own `wip(<pkg>): ...`
# checkpoint commits (see commit_message above), so a caller (bp-baseline.pl)
# never has to re-derive the message format itself. undef input -> 0, never dies.
sub is_checkpoint_subject {
    my ($subject) = @_;
    return 0 unless defined $subject && !ref $subject;
    return $subject =~ /\A\s*wip\(/ ? 1 : 0;
}

# --- a package id, as it is allowed to reach a commit subject.
#
# `pkg` is ledger content: a `blueprint.md` table cell (LLM-authored) or a bare
# `--pkg` on the CLI. Unsanitised it is a message-injection vector — a newline
# turns the one-line subject into a subject + body, and that body's first line
# is a trailer git will parse and a reviewer will believe (an AI-authorship
# trailer is exactly what done-criterion (d) forbids).
#
# So a package id is treated as what it actually is — a slug — and only the
# LEADING run of slug characters survives. Truncating (rather than substituting)
# at the first foreign byte is what makes injection impossible: everything after
# the newline, CR, control byte, quote or colon is gone, not merely reshaped.
# Bounded too, so a 100 KB ledger cell cannot produce a 100 KB subject.
sub _clean_pkg {
    my ($raw) = @_;
    return '' unless defined $raw && !ref $raw;
    my $pkg = $raw;
    $pkg =~ s/\A\s+//;
    my ($head) = $pkg =~ m{\A([A-Za-z0-9._/-]+)};
    return '' unless defined $head;
    return length($head) > $PKG_MAX ? substr($head, 0, $PKG_MAX) : $head;
}

# --- the commit message: `wip(<pkg>): <status> @ <step-or-ts>`.
# One line, no body, no trailers of ANY kind — in particular no trailer naming
# an AI author (house rule, done-criterion (d)). Total: never dies.
sub commit_message {
    my ($a) = @_;
    $a = {} unless ref $a eq 'HASH';
    my $pkg = _clean_pkg($a->{pkg});
    my $st  = $a->{status};
    # an absent/empty/multi-line status would break the one-line contract
    $st = 'unknown' unless defined $st && !ref $st && length $st && $st !~ /[\r\n]/;
    my $step = $a->{step};
    my $where;
    if (defined $step && !ref $step && $step =~ /\A\s*\d+\s*\z/ && $step + 0 >= 1) {
        # the ticked-pipeline-checkbox count: the human-meaningful location in
        # the pipeline, and what makes a squash range obvious.
        $where = 'step ' . ($step + 0);
    } else {
        # before step 1 there IS no such location, so fall back to a timestamp
        # that still keeps consecutive messages distinguishable.
        my $now = $a->{now};
        $where = _iso_utc((defined $now && !ref $now && $now =~ /\A-?\d+\z/) ? $now + 0 : time);
    }
    return "wip($pkg): $st \@ $where";
}

# --- first non-blank line of some git output, trimmed, de-pathed and bounded.
#
# `detail` is copied verbatim into runs/orchestrator.log, which is a shared,
# long-lived, human-readable artifact. git's own messages quote absolute paths,
# and on this deployment those carry the host account name (`fatal: not a git
# repository: /project/C:/Users/<name>/...`) — BpLog::redact only scrubs
# api-key-shaped strings and secret-named keys, so it would not touch that.
# Paths inside $root are therefore made root-relative and any remaining absolute
# path (POSIX or Windows) is replaced by a placeholder: the classification a
# reader needs is in the message, never in the path.
sub _detail {
    my ($txt, $root) = @_;
    return undef unless defined $txt && !ref $txt;
    my ($line) = grep { /\S/ } split /\n/, $txt;
    return undef unless defined $line;
    $line =~ s/\A\s+//;
    $line =~ s/\s+\z//;
    if (defined $root && !ref $root && length $root) {
        my $r = $root;
        $r =~ s{/+\z}{};
        $line =~ s{\Q$r\E/+}{}g if length $r;
    }
    # only ABSOLUTE paths: the lookbehind keeps 'src/x.pl' (a pathspec a reader
    # needs) intact while '/home/…' and 'C:/Users/…' become '<path>'.
    $line =~ s{(?<![\w.\-])(?:[A-Za-z]:)?[\\/][^\s'"`]{2,}}{<path>}g;
    $line = substr($line, 0, $DETAIL_MAX) if length($line) > $DETAIL_MAX;
    return length($line) ? $line : undef;
}

# ===========================================================================
# THE ONE INVOCATION PRIMITIVE
# ===========================================================================

# _git($root, @args) -> ($merged_output, $exit)
#
# fork + exec of a LIST (bp-deps-check.pl:403-423's shape). Load-bearing
# properties, in order of how badly their absence bites:
#
#   • the child's STDERR is MERGED into the captured stream — "fatal: not a git
#     repository" is an EXPECTED outcome here, not something to spray on the
#     orchestrator's console — and that captured text is what `detail` reports.
#   • `core.fsmonitor` and `core.hooksPath` are pinned OFF/back to the in-repo
#     default on every invocation. Both are ordinary repo-local config values
#     naming a program git will execute, and this process runs as the
#     orchestrator, outside the guard-bash policy boundary that gates every
#     coordinator and worker. Pinning them keeps the deliberate "no
#     --no-verify, the repo's own hooks are the human's contract" decision
#     (§2.4) while removing the redirect a worktree-writable config could use.
#   • the child's STDIN is /dev/null. A `pre-commit` hook that reads, or git
#     prompting for a credential or a gpg passphrase, would otherwise inherit
#     the orchestrator's stdin and block on it forever.
#   • the read is bounded by $GIT_TIMEOUT. The watch loop is single-threaded:
#     while it waits here it launches nothing, watches nothing and refreshes no
#     token. The deadline is enforced with a 4-arg select() and NOT with
#     alarm(), so this can never disturb an outstanding alarm or the
#     $SIG{TERM}/$SIG{INT} handling run() installs.
#
# Exit sentinels, never shifted: -1 fork/exec failed · -2 killed by a signal
# (`$? >> 8` would read a SIGKILL as a clean 0 and report a commit that never
# happened) · -3 timed out · 127 git binary missing.
sub _git {
    my ($root, @args) = @_;
    my $pid = open(my $fh, '-|');
    return (undef, -1) unless defined $pid;                # fork failed
    unless ($pid) {                                        # child
        open(STDERR, '>&', \*STDOUT) or close(STDERR);
        open(STDIN, '<', '/dev/null') or close(STDIN);
        # `or _exit` (not a following statement): exec failure leaves this child
        # holding the PARENT's END blocks and destructors, and a plain exit()
        # would run them in a process that is only half a copy of the caller.
        exec('git', '-c', 'core.fsmonitor=', '-c', "core.hooksPath=$root/.git/hooks",
             '-C', $root, @args) or POSIX::_exit(127);    # git binary missing
    }

    my ($out, $timed_out, $errs) = ('', 0, 0);
    my $deadline = time + $GIT_TIMEOUT;
    my $rbits = '';
    vec($rbits, fileno($fh), 1) = 1;
    while (1) {
        my $left = $deadline - time;
        if ($left <= 0) { $timed_out = 1; last }
        my $ready = $rbits;
        my $n = select($ready, undef, undef, $left);
        if (!defined $n || $n < 0) { last if ++$errs > 100; next }   # EINTR etc.
        next unless $n;                                             # nothing yet
        my $chunk;
        my $got = sysread($fh, $chunk, 65536);
        if (!defined $got) { last if ++$errs > 100; next }
        last unless $got;                                           # EOF: child is done
        # keep reading after the cap so the child never dies of SIGPIPE (that
        # would masquerade as a signal-killed git), just stop accumulating.
        $out .= $chunk if length($out) < $OUT_MAX;
    }
    if ($timed_out) {
        kill 'KILL', $pid;
        waitpid($pid, 0);
        close $fh;
        return ("git timed out after ${GIT_TIMEOUT}s: git " . join(' ', @args), -3);
    }
    close $fh;                                             # reaps the child, sets $?
    my $st = $?;
    return ($out, $st == -1 ? -1 : ($st & 127) ? -2 : ($st >> 8));
}

# Is this exit code a "git itself did not run to completion" sentinel? Such a
# code carries no information about the repository, so it must never be read as
# 'not a repo' / 'this pathspec matched nothing' / 'the commit succeeded'.
sub _git_broke {
    my ($rc) = @_;
    return 1 unless defined $rc;
    return ($rc == -1 || $rc == -2 || $rc == -3 || $rc == 127) ? 1 : 0;
}
sub _broke_reason {
    my ($rc) = @_;
    return 'git-timeout' if defined $rc && $rc == -3;
    return 'git-killed'  if defined $rc && $rc == -2;
    return 'git-unavailable';
}

# ===========================================================================
# ROOT RESOLUTION
# ===========================================================================

# resolve_root($hint) -> the directory every `git -C` points at.
#
# The order is the in-house canon (bp-drive-next.pl:702-726, itself mirroring
# bp-lib.sh:15-26) with the injectable hint on top. It is DUPLICATED here rather
# than reused: bp-drive-next.pl is an 800-line director with no business inside
# the orchestrator's blast radius, and this is twenty lines.
#
# A wrong answer is not fatal — it degrades to `not-a-repo`, one logged
# checkpoint_failed per package per interval.
sub resolve_root {
    my ($hint) = @_;
    return $hint if defined $hint && !ref $hint && length $hint;
    return $ENV{BP_PROJECT_ROOT}
        if defined $ENV{BP_PROJECT_ROOT} && length $ENV{BP_PROJECT_ROOT};

    # git toplevel — trust only a clean exit naming a real directory. '-C .' so
    # the primitive stays the only way this file ever invokes git.
    my ($top, $rc) = _git('.', 'rev-parse', '--show-toplevel');
    if (defined $top && defined $rc && $rc == 0) {
        $top =~ s/\s+\z//;
        return $top if length $top && -d $top;
    }

    # walk up for the first ancestor already holding .ccpraxis-local-data
    my $d = Cwd::getcwd();
    if (defined $d && length $d) {
        my %seen;
        while (!$seen{$d}++) {
            return $d if -d "$d/.ccpraxis-local-data";
            my $parent = dirname($d);
            last if $parent eq $d;                     # filesystem / drive root
            $d = $parent;
        }
    }
    return Cwd::getcwd() // '.';
}

# ===========================================================================
# checkpoint()
# ===========================================================================

sub _blank_result {
    return { ok => 0, status => 'error', committed => 0, sha => undef, message => undef,
             reason => undef, detail => undef, pathspecs => [], staged => [],
             unmatched => [], dropped => [], exit => 3 };
}
sub _fail {
    my ($r, $reason, $detail, $code) = @_;
    $r->{ok} = 0; $r->{status} = 'error'; $r->{committed} = 0;
    $r->{reason} = $reason; $r->{detail} = $detail;
    $r->{exit} = defined $code ? $code : 3;
    return $r;
}
sub _noop {
    my ($r, $reason) = @_;
    # A no-op is a SUCCESS: nothing needed committing (done-criterion (b)).
    $r->{ok} = 1; $r->{status} = 'clean'; $r->{committed} = 0;
    $r->{reason} = $reason; $r->{exit} = 1;
    return $r;
}

# checkpoint({ root, pkg, write_set, status, step, now }) -> §2.5 result hashref.
# Never dies; every outcome is a structured return.
sub checkpoint {
    my ($a) = @_;
    $a = {} unless ref $a eq 'HASH';
    my $r = _blank_result();

    # 1. root
    my $root = (defined $a->{root} && !ref $a->{root} && length $a->{root})
             ? $a->{root} : resolve_root(undef);
    return _fail($r, 'no-root', undef, 3) unless defined $root && length $root && -d $root;

    # 2. required arguments
    my $pkg = (defined $a->{pkg} && !ref $a->{pkg}) ? $a->{pkg} : '';
    my $ws  = (defined $a->{write_set} && !ref $a->{write_set}) ? $a->{write_set} : undef;
    return _fail($r, 'usage', undef, 2) unless length $pkg && defined $ws;

    # 3. is this a git repository at all? (/project is NOT: its .git is a gitfile
    #    pointing at a host path, so this arm is a live, expected code path.)
    my $gitdir;
    {
        my ($out, $rc) = _git($root, 'rev-parse', '--git-dir');
        return _fail($r, _broke_reason($rc), _detail($out, $root), 3) if _git_broke($rc);
        return _fail($r, 'not-a-repo',       _detail($out, $root), 3) if $rc != 0;
        ($gitdir) = grep { /\S/ } split /\n/, (defined $out ? $out : '');
        $gitdir = '.git' unless defined $gitdir;
        $gitdir =~ s/\A\s+//; $gitdir =~ s/\s+\z//;
        # `git -C $root` resolves a relative --git-dir against $root.
        $gitdir = "$root/$gitdir" unless $gitdir =~ m{\A(?:/|[A-Za-z]:[\\/])};
    }

    # 3b. HEAD-state gate — a checkpoint is only ever an inline WIP commit ON A
    #     BRANCH (Decision #2). Two states make that impossible, and in both the
    #     honest answer is to do nothing:
    #       • detached HEAD — the commit would land on no branch at all, be
    #         unreachable and GC-eligible, while the log advertised it as the
    #         package's recovery point;
    #       • an operation in progress — a rebase (which SKILL.md itself tells
    #         the human to run to squash these commits), a conflicted merge, a
    #         cherry-pick or a bisect. Committing into the middle of one rewrites
    #         or breaks history that the human is holding in their hands.
    #     Both are clean no-ops, not errors: nothing failed, there was simply no
    #     safe place to put a commit, and the next tick re-checks.
    {
        my ($ref, $rrc) = _git($root, 'symbolic-ref', '-q', 'HEAD');
        return _fail($r, _broke_reason($rrc), _detail($ref, $root), 3) if _git_broke($rrc);
        return _noop($r, 'detached-head')
            unless $rrc == 0 && defined $ref && $ref =~ /\S/;
        for my $marker (qw(rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD BISECT_LOG)) {
            return _noop($r, 'operation-in-progress') if -e "$gitdir/$marker";
        }
    }

    # 4. stage — ONLY the write set, one pathspec at a time so a single entry
    #    that matches nothing cannot cost the others their commit.
    my ($ps, $dropped) = _parse_write_set($ws);
    $r->{pathspecs} = $ps;
    $r->{dropped}   = $dropped;
    return _noop($r, 'no-safe-pathspec') unless @$ps;

    my (@staged, @unmatched);
    for my $p (@$ps) {
        my ($out, $rc) = _git($root, 'add', '-A', '--', $p);
        if (defined $rc && $rc == 0) { push @staged, $p; next }
        $r->{staged} = \@staged; $r->{unmatched} = \@unmatched;
        return _fail($r, _broke_reason($rc), _detail($out, $root), 3) if _git_broke($rc);
        my $txt = defined $out ? $out : '';
        # A REAL git failure stops the whole attempt; "pathspec did not match"
        # does not — a write-set entry naming a not-yet-created file is normal.
        if ($txt =~ /not a git repository/i)                { return _fail($r, 'not-a-repo',  _detail($txt, $root), 3) }
        if ($txt =~ /index\.lock|Unable to create/i)        { return _fail($r, 'index-locked', _detail($txt, $root), 3) }
        push @unmatched, $p;
    }
    $r->{staged}    = \@staged;
    $r->{unmatched} = \@unmatched;
    return _noop($r, 'all-pathspecs-unmatched') unless @staged;

    # 5. clean-tree gate. Count ONLY real porcelain status lines, so a stray
    #    `warning:` / `hint:` line can never be mistaken for a change.
    {
        my ($out, undef) = _git($root, 'status', '--porcelain', '--', @staged);
        my $changes = 0;
        for my $ln (split /\n/, (defined $out ? $out : '')) {
            $changes++ if $ln =~ /^[ MADRCU?!]{2} /;
        }
        return _noop($r, 'clean-tree') unless $changes;
    }

    # 6. commit. WITH the pathspecs (git's implied --only), not the bare index:
    #    that records the working-tree content of the write-set paths and
    #    DISREGARDS anything else already staged — the cross-blueprint bleed a
    #    second orchestrator sharing this working tree would otherwise cause.
    #    Identity is pinned per invocation (a bare container has no user.name,
    #    and `butler` makes the WIP commits obvious in `git log`); never a
    #    `git config` write, never GIT_AUTHOR_* env leaking into children.
    #    No --no-verify: a hook that rejects this IS the failure path
    #    done-criterion (c) wants, and the repo's hooks are the human's contract.
    my $msg = commit_message({ pkg => $pkg, status => $a->{status},
                               step => $a->{step}, now => $a->{now} });
    my ($cout, $crc) = _git($root, '-c', 'user.email=butler@localhost', '-c', 'user.name=butler',
                            'commit', '-q', '-m', $msg, '--', @staged);
    # A child that never ran to completion is NOT a commit: `$? >> 8` reads a
    # signal-killed git as 0, which would report `committed` (with the previous
    # HEAD as its sha) for a commit that does not exist.
    return _fail($r, _broke_reason($crc), _detail($cout, $root), 3) if _git_broke($crc);
    return _fail($r, 'commit-failed', _detail($cout, $root), 3) unless $crc == 0;

    my ($hout, $hrc) = _git($root, 'rev-parse', 'HEAD');
    my $sha = defined $hout ? $hout : '';
    $sha =~ s/\s+//g;
    $r->{ok}        = 1;
    $r->{status}    = 'committed';
    $r->{committed} = 1;
    # 40 hex (sha1) OR 64 (a repo created with objectformat=sha256) — pinning
    # only the sha1 width would log `sha: null` on a perfectly good commit,
    # losing the operator's recovery pointer exactly when everything worked.
    $r->{sha}       = (defined $hrc && $hrc == 0 && $sha =~ /\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/)
                    ? $sha : undef;
    $r->{message}   = $msg;
    $r->{reason}    = undef;
    $r->{detail}    = undef;
    $r->{exit}      = 0;
    return $r;
}

package main;
use strict;
use warnings;

# ===========================================================================
# CLI  (skipped entirely under `require` — see the header)
# ===========================================================================
unless (caller) {
    my $USAGE = "usage: bp-checkpoint.pl --pkg <name> --write-set <colon-string>\n"
              . "                        [--root <dir>] [--status <s>] [--step <n>]\n"
              . "                        [--now <epoch>] [--quiet]\n";
    my %takes = map { $_ => 1 } qw(pkg write-set root status step now);
    my (%o, $bad);
    my @argv = @ARGV;
    while (@argv) {
        my $arg = shift @argv;
        if ($arg eq '--quiet') { $o{quiet} = 1; next }
        # both --key=value and --key value, for every option
        if ($arg =~ /\A--([a-z][a-z0-9-]*)=(.*)\z/s && $takes{$1}) { $o{$1} = $2; next }
        # `--key value`, but a value that is itself a flag is a MISSING value:
        # `--write-set --quiet` must be a usage error, not a checkpoint whose
        # write set is the literal string '--quiet'. (`--key=--v` still works.)
        if ($arg =~ /\A--([a-z][a-z0-9-]*)\z/ && $takes{$1} && @argv && $argv[0] !~ /\A--/) {
            $o{$1} = shift @argv;
            next;
        }
        $bad = $arg;
        last;
    }
    if (defined $bad) {
        print STDERR "bp-checkpoint.pl: unknown or malformed option '$bad'\n$USAGE";
        exit 2;
    }
    unless (defined $o{pkg} && length $o{pkg} && defined $o{'write-set'} && length $o{'write-set'}) {
        print STDERR "bp-checkpoint.pl: --pkg and --write-set are required\n$USAGE";
        exit 2;
    }

    my $res = BpCheckpoint::checkpoint({
        root => $o{root}, pkg => $o{pkg}, write_set => $o{'write-set'},
        status => $o{status}, step => $o{step}, now => $o{now},
    });
    # exactly one canonical JSON line on STDOUT, nothing else anywhere
    print JSON::PP->new->canonical->utf8->encode($res), "\n" unless $o{quiet};
    exit(defined $res->{exit} ? $res->{exit} : 3);
}

1;
