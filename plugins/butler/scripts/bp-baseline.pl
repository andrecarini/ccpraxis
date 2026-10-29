#!/usr/bin/env perl
# bp-baseline.pl — green-baseline materialization (b40-green-baseline-isolation).
#
# Implements plugins/butler/tests/../specs/b40-green-baseline-isolation-spec.md.
# One job: let a package validate against a KNOWN-GOOD tree — a persistent git
# ref (refs/butler/baseline/<blueprint>) advanced only past done+harvest-passed
# work, overlaid with the CURRENT package's own live (including uncommitted and
# untracked) state — so a coordinator never has to read a sibling's mid-step,
# deliberately-red WIP (the SYN-11 hazard). See spec section 4.3.
#
# Two shapes, one file (the bp-checkpoint.pl / bp-deps-check.pl convention):
#   • module — `require "<dir>/bp-baseline.pl"; BpBaseline::harvest_passed({...})`.
#     `require` has NO top-level side effects.
#   • CLI    — `perl bp-baseline.pl advance|materialize|teardown|gate|status ...`,
#     guarded by `unless (caller)`.
#
# CLI contract (spec section 0.1 — PINNED, do not diverge):
#   bp-baseline.pl advance     --blueprint B [--root R]
#   bp-baseline.pl materialize --package P --dest D --blueprint B [--strict-deps] [--dep-status JSON]
#   bp-baseline.pl teardown    --package P --dest D --blueprint B
#   bp-baseline.pl gate        [--known-red FILE]
#   bp-baseline.pl status      --blueprint B
# Exit codes: 0 success/gate pass · 1 gate fail or nothing eligible · 2 usage ·
# 3 precondition not met · 4 I/O error.
#
# Core Perl only — no CPAN, no other runtime (project CLAUDE.md).

package BpBaseline;
use strict;
use warnings;
use JSON::PP ();
use File::Path ();
use File::Basename qw(dirname);
use File::Spec ();
use POSIX qw(WNOHANG);
use Digest::SHA ();

# Requiring by the SAME literal path an oracle/caller would construct from its
# own $Bin (dirname(__FILE__) reproduces that string exactly, even when it
# still contains unresolved '..' segments) means a caller that already
# required these files first pays no double-compile, and one that hasn't gets
# them for the first time here. LAZY on purpose (not just "no top-level side
# effects" -- spec section 1): a CLI verb that never touches BpCheckpoint or
# BpJudge (e.g. `gate`'s classify-only path) never pays to compile them, and
# `materialize` -- whose only use of BpCheckpoint is the OVERLAY half, well
# after the destination directory already exists -- doesn't front-load that
# cost onto the window before its SIGTERM handler has anything to guard.
# NORMALISE SEPARATORS BEFORE dirname(). Invoked from PowerShell as
#   perl C:\Users\X\.claude\ccpraxis\plugins\butler\scripts\bp-baseline.pl
# __FILE__ is a BACKSLASH path, which File::Basename::dirname cannot split: it
# returns '.', and rel2abs then turns that into the CALLER'S CWD. Every sibling
# require and every relative lookup silently resolves against the wrong tree.
# (Observed for real in bp-turn-caps.pl, whose config lookup became
# "<cwd>/../turn-caps.json" and reported a missing file rather than the path bug
# it actually was.) On Unix this substitution is a no-op -- a backslash is an
# ordinary filename character there -- so the Unix path is byte-identical.
my $_SELF = __FILE__;
$_SELF =~ s{\\}{/}g;
my $SELF_DIR = dirname($_SELF);
# ...but `require` treats a RELATIVE path as an @INC search key, not a filename.
# Invoked as `perl plugins/butler/scripts/bp-baseline.pl` (the ordinary CLI case)
# dirname(__FILE__) is relative, so every require above died with
# "Can't locate plugins/butler/scripts/bp-checkpoint.pl in @INC" — taking BOTH
# `materialize` and the criterion-9 `gate` with it. The oracle never caught this:
# it requires this file through an ABSOLUTE $Bin-derived path, so $SELF_DIR was
# already absolute there and the bug was invisible to a 95/95 green run. Caught by
# executing the CLI, not by the suite.
#
# Absolutise ONLY when relative: an already-absolute $SELF_DIR (including one
# still carrying unresolved '..' segments, which is exactly what a $Bin-derived
# caller passes) is left byte-identical, so the no-double-compile property the
# lazy requires above depend on is preserved. NOT abs_path, for that same
# reason: normalising away the '..' would make this file's require key differ
# from the caller's and compile the sibling twice.
#
# The drive-letter test is not redundant: under Git-Bash/msys perl,
# File::Spec's Unix flavour does NOT consider `C:/Users/...` absolute, so
# rel2abs would paste the CWD in front of an already-absolute Windows path.
$SELF_DIR = File::Spec->rel2abs($SELF_DIR)
    unless File::Spec->file_name_is_absolute($SELF_DIR) || $SELF_DIR =~ m{^[A-Za-z]:/};
my ($_HAVE_CHECKPOINT, $_HAVE_JUDGE) = (0, 0);
sub _require_checkpoint { return if $_HAVE_CHECKPOINT; require "$SELF_DIR/bp-checkpoint.pl"; $_HAVE_CHECKPOINT = 1; }
sub _require_judge      { return if $_HAVE_JUDGE;      require "$SELF_DIR/bp-judge.pl";      $_HAVE_JUDGE = 1; }

# ===========================================================================
# PURE FUNCTIONS (spec section 0 — exact names/signatures, do not diverge)
# ===========================================================================

# enabled({ ledger_value, blueprint_value, env_value }) -> 0|1
# Precedence env -> ledger -> blueprint -> default OFF (spec section 7).
sub _truthy {
    my ($v) = @_;
    return 0 unless defined $v && !ref $v;
    my $lc = lc($v);
    return ($lc eq '1' || $lc eq 'true' || $lc eq 'yes' || $lc eq 'on') ? 1 : 0;
}
sub enabled {
    my ($a) = @_;
    $a = {} unless ref $a eq 'HASH';
    for my $key (qw(env_value ledger_value blueprint_value)) {
        my $v = $a->{$key};
        next unless defined $v && !ref $v && length $v;
        return _truthy($v);
    }
    return 0;
}

# unwrap_archive($decoded_envelope_hashref) -> inner hashref | undef
# A malformed envelope is NEVER a pass (spec section 2.1).
sub unwrap_archive {
    my ($e) = @_;
    return undef unless ref $e eq 'HASH';
    return undef if $e->{malformed};
    return (ref $e->{verdict} eq 'HASH') ? $e->{verdict} : undef;
}

# harvest_passed({ registry_entry, live, archives }) -> 0|1, fail-closed
# (spec section 2.2). archives is newest-first.
sub harvest_passed {
    my ($a) = @_;
    $a = {} unless ref $a eq 'HASH';
    _require_judge();

    my $reg = $a->{registry_entry};
    if (ref $reg eq 'HASH' && exists $reg->{harvest}) {
        my $h = $reg->{harvest};
        if (defined $h && !ref $h && length $h) {
            return $h eq 'pass' ? 1 : 0;
        }
        # absent key, undef, or empty string: not definitive -- fall through.
    }

    my $live = $a->{live};
    if (ref $live eq 'HASH') {
        return BpJudge::normalize_harvest($live) eq 'pass' ? 1 : 0;
    }

    my $archives = $a->{archives};
    if (ref $archives eq 'ARRAY') {
        for my $env (@$archives) {
            my $v = unwrap_archive($env);
            next unless defined $v;
            return BpJudge::normalize_harvest($v) eq 'pass' ? 1 : 0;
        }
    }

    return 0;   # nothing definitive anywhere -- fail-closed (the whole safety property)
}

# eligible_packages({ status, harvest }) -> { pkg => 1 }
# `status` is a hashref pkg => ledger status string; `harvest` is a hashref
# pkg => 0|1 (already-resolved harvest_passed outcomes -- injected, never
# re-derived here, per spec section 2.3's "inject, don't read from a fixed path").
sub eligible_packages {
    my ($a) = @_;
    $a = {} unless ref $a eq 'HASH';
    my $status  = (ref $a->{status}  eq 'HASH') ? $a->{status}  : {};
    my $harvest = (ref $a->{harvest} eq 'HASH') ? $a->{harvest} : {};
    my %out;
    for my $pkg (keys %$status) {
        next unless defined $status->{$pkg} && $status->{$pkg} eq 'done';
        next unless $harvest->{$pkg};
        $out{$pkg} = 1;
    }
    return \%out;
}

# parse_commit_packages($subject, $known) -> list of pkg ids (spec section 3.2)
sub parse_commit_packages {
    my ($subject, $known) = @_;
    $known = {} unless ref $known eq 'HASH';
    return [] unless defined $subject && !ref $subject;
    return [] unless $subject =~ /\(([^)]*)\)/;
    my $scope = $1;
    my (%seen, @out);
    for my $tok (split /[,\s]+/, $scope) {
        next unless length $tok;
        next unless exists $known->{$tok};
        next if $seen{$tok}++;
        push @out, $tok;
    }
    return \@out;
}

# commit_eligible($subject, $eligible, $known) -> 0|1 (spec section 3.3)
sub commit_eligible {
    my ($subject, $eligible, $known) = @_;
    $eligible = {} unless ref $eligible eq 'HASH';
    $known    = {} unless ref $known eq 'HASH';
    _require_checkpoint();
    return 0 if BpCheckpoint::is_checkpoint_subject($subject);   # criterion 2
    my $pkgs = parse_commit_packages($subject, $known);
    return 1 unless @$pkgs;                                      # infra commit
    for my $p (@$pkgs) {
        return 0 unless $eligible->{$p};                         # criterion 1
    }
    return 1;
}

# select_baseline({ commits, eligible, known }) -> sha | undef (spec section 3.4)
# `commits` is oldest-first.
sub select_baseline {
    my ($a) = @_;
    $a = {} unless ref $a eq 'HASH';
    my $commits = (ref $a->{commits} eq 'ARRAY') ? $a->{commits} : [];
    my $eligible = $a->{eligible};
    my $known    = $a->{known};
    my $last;
    for my $c (@$commits) {
        my ($sha, $subj) = (ref $c eq 'HASH') ? ($c->{sha}, $c->{subject}) : (undef, undef);
        last unless commit_eligible($subj, $eligible, $known);
        $last = $sha;
    }
    return $last;
}

# gate_classify({ results, known_red }) -> { ok, new_red, fixed, known } (spec section 5.2)
sub gate_classify {
    my ($a) = @_;
    $a = {} unless ref $a eq 'HASH';
    my $results   = (ref $a->{results}   eq 'ARRAY') ? $a->{results}   : [];
    my $known_red = (ref $a->{known_red} eq 'HASH')  ? $a->{known_red} : {};
    my (@new_red, @fixed, @known);
    for my $r (@$results) {
        next unless ref $r eq 'HASH';
        my $file   = $r->{file};
        my $exit   = defined $r->{exit}   ? $r->{exit}   : 0;
        my $not_ok = defined $r->{not_ok} ? $r->{not_ok} : 0;
        my $is_red = ($exit != 0 || $not_ok > 0) ? 1 : 0;
        my $decl   = (defined $file && ref $known_red->{$file} eq 'HASH') ? $known_red->{$file} : undef;
        if ($is_red) {
            if ($decl) {
                my $worse = ($exit != $decl->{exit}) || ($not_ok > $decl->{not_ok});
                if ($worse) { push @new_red, $file } else { push @known, $file }
            } else {
                push @new_red, $file;
            }
        } else {
            push @fixed, $file if $decl;
        }
    }
    return { ok => (@new_red ? 0 : 1), new_red => \@new_red, fixed => \@fixed, known => \@known };
}

# ===========================================================================
# gate() -- the runnable whole-tree gate's CLI-adjacent surface (spec section 5).
# Injectable runner; the real 90-file suite is never run inside a test of this
# file (spec section 5.4). Loud, machine-readable failure report on stdout.
# ===========================================================================
sub _default_gate_runner {
    _require_checkpoint();
    my $root = BpCheckpoint::resolve_root(undef);
    my @files;
    for my $rel (qw(plugins/butler/tests/t plugins/sandbox/tests/t)) {
        my $dir = "$root/$rel";
        next unless -d $dir;
        opendir(my $dh, $dir) or next;
        # Carry BOTH forms: the absolute path is what we execute, the
        # REPO-RELATIVE path is what we report and key `--known-red` on.
        push @files, map { { abs => "$dir/$_", rel => "$rel/$_" } }
                     sort grep { /\.t\z/ } readdir $dh;
        closedir $dh;
    }
    my @results;
    for my $f (@files) {
        my $out = `timeout 120 perl "$f->{abs}" 2>&1`;
        my $rc  = $? >> 8;
        my $not_ok = () = ($out =~ /^not ok/mg);
        my $skips  = () = ($out =~ /^ok \d+ # skip/mg);
        # `file` is the repo-relative path on purpose. Reporting the ABSOLUTE
        # path made every `--known-red` entry unmatchable unless it embedded this
        # checkout's location ('/project/...'), so a perfectly correct baseline
        # file silently declared nothing and all 8 known-red sandbox files came
        # back as "NEW RED". Caught by running the gate for real, not by the
        # suite: the oracle exercises gate_classify with bare fixture filenames,
        # where absolute-vs-relative cannot show up.
        push @results, { file => $f->{rel}, exit => $rc, not_ok => $not_ok, skips => $skips };
    }
    return \@results;
}
sub gate {
    my ($a) = @_;
    $a = {} unless ref $a eq 'HASH';
    my $runner    = (ref $a->{runner} eq 'CODE') ? $a->{runner} : \&_default_gate_runner;
    my $known_red = (ref $a->{known_red} eq 'HASH') ? $a->{known_red} : {};
    my $results   = $runner->();
    $results = [] unless ref $results eq 'ARRAY';
    my $class = gate_classify({ results => $results, known_red => $known_red });
    if (!$class->{ok}) {
        my %by_file = map { (ref $_ eq 'HASH' && defined $_->{file}) ? ($_->{file} => $_) : () } @$results;
        for my $file (@{ $class->{new_red} }) {
            my $r = $by_file{$file} || {};
            my $exit   = defined $r->{exit}   ? $r->{exit}   : 0;
            my $not_ok = defined $r->{not_ok} ? $r->{not_ok} : 0;
            print "NEW RED: $file exit=$exit not_ok=$not_ok\n";
        }
        print STDERR "bp-baseline gate: " . scalar(@{ $class->{new_red} }) . " newly-red file(s)\n";
    }
    return $class;
}

# ===========================================================================
# small generic helpers (subprocess/IO), used only by CLI verbs below
# ===========================================================================
sub _shquote { my $s = shift; $s = '' unless defined $s; $s =~ s/'/'\\''/g; return "'$s'"; }

sub _run_capture {
    my (@cmd) = @_;
    my $pid = open(my $fh, '-|');
    return (undef, -1) unless defined $pid;
    if ($pid == 0) {
        open(STDERR, '>&', \*STDOUT) or close(STDERR);
        open(STDIN, '<', '/dev/null') or close(STDIN);
        exec(@cmd) or POSIX::_exit(127);
    }
    local $/;
    my $out = <$fh>;
    close $fh;
    my $rc = ($? == -1) ? -1 : ($? >> 8);
    return (defined $out ? $out : '', $rc);
}

sub _read_all_bytes {
    my ($path) = @_;
    open my $fh, '<', $path or return undef;
    binmode $fh;
    local $/;
    my $c = <$fh>;
    close $fh;
    return defined $c ? $c : '';
}
sub _write_all_bytes {
    my ($path, $bytes) = @_;
    my $dir = $path;
    $dir =~ s{/[^/]+\z}{};
    File::Path::make_path($dir) if length($dir) && !-d $dir;
    open my $fh, '>', $path or return 0;
    binmode $fh;
    print $fh (defined $bytes ? $bytes : '');
    close $fh;
    return 1;
}

# stat -f -c %T of the nearest EXISTING ancestor of $path (the path itself may
# not exist yet -- spec section 4.1).
sub _fstype_of {
    my ($path) = @_;
    return undef unless defined $path && length $path;
    my $p = $path;
    $p =~ s{/+\z}{} if length($p) > 1;
    while (length($p) && !-e $p) {
        my $parent = $p;
        $parent =~ s{/[^/]*\z}{};
        $parent = '/' if $parent eq '';
        last if $parent eq $p;
        $p = $parent;
    }
    $p = '/' unless length $p;
    my $out = `stat -f -c %T @{[_shquote($p)]} 2>/dev/null`;
    return undef unless defined $out;
    $out =~ s/\s+\z//;
    return length($out) ? $out : undef;
}

# ===========================================================================
# CLI exit helpers (mirror bp-jail.pl's usage_exit/precondition_exit/io_exit)
# ===========================================================================
sub _usage_exit {
    print STDERR "usage: bp-baseline.pl advance|materialize|teardown|gate|status ...\n";
    print STDERR "bp-baseline: $_[0]\n" if defined $_[0];
    exit 2;
}
sub _precondition_exit { print STDERR "bp-baseline: precondition not met: $_[0]\n"; exit 3; }
sub _io_exit            { print STDERR "bp-baseline: I/O error: $_[0]\n"; exit 4; }

# ===========================================================================
# SIGTERM-safe teardown during `materialize` (spec section 4.5, mirrors
# bp-jail.pl's _signal_teardown_and_exit / $SIGNAL_JAIL_ROOT pattern). Globals
# are touched ONLY from inside cli_materialize -- never at module-require time.
# ===========================================================================
our $BASELINE_CHILD_PID;
our $BASELINE_SIGNAL_DEST;
sub _signal_teardown_and_exit {
    my ($name) = @_;
    if (defined $BASELINE_CHILD_PID) {
        # Signal the process GROUP, not just the child. cli_materialize makes
        # the child a group leader precisely so this reaches git and tar too;
        # a surviving tar re-creates the tree after we remove it. Fall back to
        # the bare pid if the group signal finds nothing (setpgid lost a race).
        kill('TERM', -$BASELINE_CHILD_PID) or kill('TERM', $BASELINE_CHILD_PID);
        my $waited = 0;
        while ($waited < 5) {
            my $r = waitpid($BASELINE_CHILD_PID, WNOHANG);
            last if $r == $BASELINE_CHILD_PID;
            select(undef, undef, undef, 0.1);
            $waited += 0.1;
        }
        if ((waitpid($BASELINE_CHILD_PID, WNOHANG) // 0) != $BASELINE_CHILD_PID) {
            kill('KILL', -$BASELINE_CHILD_PID) or kill('KILL', $BASELINE_CHILD_PID);
            waitpid($BASELINE_CHILD_PID, 0);
        }
    }
    if (defined $BASELINE_SIGNAL_DEST && -e $BASELINE_SIGNAL_DEST) {
        eval { File::Path::remove_tree($BASELINE_SIGNAL_DEST, { safe => 0 }) };
    }
    my %signum = (TERM => 15, INT => 2, HUP => 1);
    exit(128 + ($signum{$name} // 15));
}

# ===========================================================================
# CLI verb: materialize (spec section 4)
# ===========================================================================
sub cli_materialize {
    my ($opt) = @_;
    local $SIG{TERM} = sub { _signal_teardown_and_exit('TERM') };
    local $SIG{INT}  = sub { _signal_teardown_and_exit('INT') };
    local $SIG{HUP}  = sub { _signal_teardown_and_exit('HUP') };

    _usage_exit("--package is required")   unless defined $opt->{package}   && length $opt->{package};
    _usage_exit("--dest is required")      unless defined $opt->{dest}      && length $opt->{dest};
    _usage_exit("--blueprint is required") unless defined $opt->{blueprint} && length $opt->{blueprint};

    my $project_root = $ENV{BP_PROJECT_ROOT};
    my $write_set    = $ENV{BP_WRITE_SET};
    _usage_exit("BP_PROJECT_ROOT is required") unless defined $project_root && length $project_root;
    _usage_exit("BP_WRITE_SET is required")    unless defined $write_set;
    _precondition_exit("BP_PROJECT_ROOT '$project_root' does not exist") unless -d $project_root;

    my $dest = $opt->{dest};

    # Location -- criterion 7. MUST be checked, and MUST refuse, before anything
    # is created under $dest.
    my $fstype = _fstype_of($dest);
    _precondition_exit("materialized dest '$dest' resolves onto v9fs -- materialized "
                      . "trees must never live under /project (spec section 4.1)")
        if defined $fstype && $fstype eq 'v9fs';

    # The persistent baseline ref -- written directly by `advance`, or (in tests)
    # by fixture setup with `git update-ref`.
    my ($rev_out, $rev_rc) = _run_capture('git', '-C', $project_root, 'rev-parse',
                                           '--verify', '--quiet', "refs/butler/baseline/$opt->{blueprint}");
    _precondition_exit("no baseline ref refs/butler/baseline/$opt->{blueprint} in $project_root")
        unless defined $rev_rc && $rev_rc == 0;
    (my $sha = defined $rev_out ? $rev_out : '') =~ s/\s+//g;
    _precondition_exit("baseline ref refs/butler/baseline/$opt->{blueprint} resolved to nothing")
        unless length $sha;

    # Dependency handling -- criterion 6. The injection seam: with no --dep-status,
    # materialize resolves no blocked dependency (the empty case).
    my %dep_status;
    if (defined $opt->{dep_status} && length $opt->{dep_status}) {
        my $parsed = eval { JSON::PP::decode_json($opt->{dep_status}) };
        _usage_exit("--dep-status is not valid JSON") unless ref $parsed eq 'HASH';
        %dep_status = %$parsed;
    }
    my @blocked = sort grep { defined $dep_status{$_} && !ref $dep_status{$_} && $dep_status{$_} eq 'blocked' }
                       keys %dep_status;

    if ($opt->{strict_deps} && @blocked) {
        print STDERR "bp-baseline: blocked dependencies under --strict-deps: " . join(',', @blocked) . "\n";
        exit 3;
    }

    # Create dest (idempotent: a stale prior tree is replaced wholesale).
    #
    # ARM THE GUARD BEFORE THE DIRECTORY CAN EXIST. Assigning after make_path
    # leaves a window in which the tree is on disk but the handler has nothing
    # to remove -- SIGTERM landing there leaks a stray partial destination.
    # That window is small but REAL: reproduced 1-in-8 by t/84's C8 probe, which
    # polls for the destination and kills the instant it appears. The handler
    # guards on `-e`, so arming early is harmless when make_path never runs.
    $BASELINE_SIGNAL_DEST = $dest;
    File::Path::remove_tree($dest, { safe => 0 }) if -e $dest;
    File::Path::make_path($dest) or _io_exit("mkdir $dest: $!");

    # Baseline half (spec 4.2.1): extract the baseline commit's full tree.
    #
    # Block the teardown signals across fork(). The same class of window sits
    # between fork() returning and $BASELINE_CHILD_PID being recorded: a signal
    # there leaves the parent tearing the tree down while an unrecorded child
    # keeps extracting INTO it -- re-creating the very stray directory the
    # handler exists to prevent. The mask is inherited across fork, so the child
    # must clear it before exec.
    my $sigset = POSIX::SigSet->new(POSIX::SIGTERM(), POSIX::SIGINT(), POSIX::SIGHUP());
    POSIX::sigprocmask(POSIX::SIG_BLOCK(), $sigset);
    my $pid = fork();
    unless (defined $pid) {
        POSIX::sigprocmask(POSIX::SIG_UNBLOCK(), $sigset);
        _io_exit("fork: $!");
    }
    if ($pid == 0) {
        # Become a process-group leader so the handler can signal the WHOLE
        # pipeline. The child is `/bin/sh -c 'git archive | tar -x -C dest'`;
        # signalling only sh leaves git and tar alive, and tar goes on
        # extracting into $dest AFTER the handler removed it -- which puts the
        # stray directory straight back. Set in BOTH processes (the standard
        # double-setpgid idiom) so neither side races the other.
        POSIX::setpgid(0, 0);
        POSIX::sigprocmask(POSIX::SIG_UNBLOCK(), $sigset);
        open(STDIN, '<', '/dev/null');
        exec('/bin/sh', '-c',
             'git -C ' . _shquote($project_root) . ' archive ' . _shquote($sha)
             . ' | tar -x -C ' . _shquote($dest))
            or POSIX::_exit(127);
        POSIX::_exit(126);
    }
    $BASELINE_CHILD_PID = $pid;
    POSIX::setpgid($pid, $pid);   # harmless if the child won the race
    POSIX::sigprocmask(POSIX::SIG_UNBLOCK(), $sigset);
    waitpid($pid, 0);
    my $rc = $?;
    $BASELINE_CHILD_PID = undef;
    if ($rc == -1)          { $BASELINE_SIGNAL_DEST = undef; _io_exit("git archive|tar spawn failed"); }
    if (($rc & 127) != 0)   { $BASELINE_SIGNAL_DEST = undef; _io_exit("git archive|tar killed by signal"); }
    if (($rc >> 8) != 0)    { $BASELINE_SIGNAL_DEST = undef; _io_exit("git archive|tar exited " . ($rc >> 8)); }

    # Overlay half (spec 4.2.2): live content (uncommitted + untracked) over the
    # top for every write-set pathspec; a write-set path deleted live is removed.
    # (BpCheckpoint is only required NOW -- see the lazy-require note near the
    # top of this file: everything before this point in `materialize` never
    # touches it, so the destination has existed, SIGTERM-guarded, since well
    # before this compile happens.)
    _require_checkpoint();
    my $pathspecs = BpCheckpoint::parse_write_set($write_set);
    my %rels;
    for my $ps (@$pathspecs) {
        my ($out, $lrc) = _run_capture('git', '-C', $project_root, 'ls-files', '-z',
                                        '--cached', '--others', '--exclude-standard', '--', $ps);
        next unless defined $out;
        for my $rel (split /\0/, $out) {
            next unless length $rel;
            $rels{$rel} = 1;
        }
    }
    for my $rel (sort keys %rels) {
        my $src = "$project_root/$rel";
        my $dst = "$dest/$rel";
        if (-e $src && !-d $src) {
            my $bytes = _read_all_bytes($src);
            _write_all_bytes($dst, defined $bytes ? $bytes : '');
            my $mode = (stat($src))[2];
            chmod($mode & 07777, $dst) if defined $mode;
        } elsif (!-e $src) {
            unlink($dst) if -e $dst;   # write-set path deleted live -> absent (criterion 4)
        }
    }

    # Metadata (spec 4.4).
    my $meta = {
        blueprint    => $opt->{blueprint},
        package      => $opt->{package},
        baseline_sha => $sha,
        blocked_deps => \@blocked,
    };
    _write_all_bytes("$dest/.bp-baseline-meta.json", JSON::PP->new->canonical->encode($meta));

    $BASELINE_SIGNAL_DEST = undef;

    if (@blocked) {
        print STDERR "bp-baseline: blocked dependencies (materialized WITHOUT their work): "
                    . join(',', @blocked) . "\n";
    }
    print "materialized $dest\n";
    exit 0;
}

# ===========================================================================
# CLI verb: teardown -- removes ONLY the materialized destination directory,
# never the persistent baseline ref (that is advance's job alone -- spec 4.5).
# ===========================================================================
sub cli_teardown {
    my ($opt) = @_;
    _usage_exit("--package is required")   unless defined $opt->{package}   && length $opt->{package};
    _usage_exit("--dest is required")      unless defined $opt->{dest}      && length $opt->{dest};
    _usage_exit("--blueprint is required") unless defined $opt->{blueprint} && length $opt->{blueprint};
    my $dest = $opt->{dest};
    if (-e $dest) {
        eval { File::Path::remove_tree($dest, { safe => 0 }) };
        if ($@ || -e $dest) { _io_exit("failed to remove $dest: $@"); }
    }
    exit 0;
}

# ===========================================================================
# CLI verb: gate
# ===========================================================================
sub cli_gate {
    my ($opt) = @_;
    my %known_red;
    if (defined $opt->{known_red} && length $opt->{known_red}) {
        my $bytes = _read_all_bytes($opt->{known_red});
        _io_exit("cannot read --known-red file $opt->{known_red}") unless defined $bytes;
        my $parsed = eval { JSON::PP::decode_json($bytes) };
        _usage_exit("--known-red file is not valid JSON") unless ref $parsed eq 'HASH';
        %known_red = %$parsed;
    }
    my $class = gate({ known_red => \%known_red });
    if (!$class->{ok}) {
        print STDERR "bp-baseline gate: FAIL -- " . scalar(@{ $class->{new_red} }) . " new red file(s)\n";
        exit 1;
    }
    print STDERR "bp-baseline gate: PASS\n";
    exit 0;
}

# ===========================================================================
# CLI verb: status -- reports the persistent baseline ref for a blueprint.
# ===========================================================================
sub cli_status {
    my ($opt) = @_;
    _usage_exit("--blueprint is required") unless defined $opt->{blueprint} && length $opt->{blueprint};
    _require_checkpoint();
    my $root = (defined $opt->{root} && length $opt->{root}) ? $opt->{root} : BpCheckpoint::resolve_root(undef);
    my ($out, $rc) = _run_capture('git', '-C', $root, 'rev-parse', '--verify', '--quiet',
                                   "refs/butler/baseline/$opt->{blueprint}");
    if (defined $rc && $rc == 0) {
        (my $sha = defined $out ? $out : '') =~ s/\s+//g;
        print JSON::PP->new->canonical->encode({ blueprint => $opt->{blueprint}, sha => $sha }), "\n";
        exit 0;
    }
    print JSON::PP->new->canonical->encode({ blueprint => $opt->{blueprint}, sha => undef }), "\n";
    exit 1;
}

# ===========================================================================
# CLI verb: advance (spec section 3.5). Not exercised end-to-end by t/84 (its
# own note: the pure decision functions above are what is pinned); best-effort
# ledger/registry integration, mirroring bp-orchestrator.pl's read_registry
# shape (grep `sub read_registry`) without requiring that file (out of scope).
# ===========================================================================
sub _read_json_file {
    my ($path) = @_;
    return undef unless -e $path;
    my $bytes = _read_all_bytes($path);
    return undef unless defined $bytes && length $bytes;
    return eval { JSON::PP::decode_json($bytes) };
}
sub _read_registry_packages {
    my ($runs) = @_;
    my $d = _read_json_file("$runs/registry.json");
    return (ref $d eq 'HASH' && ref $d->{packages} eq 'HASH') ? $d->{packages} : {};
}
sub _read_archives_newest_first {
    my ($dir, $pkg) = @_;
    return () unless defined $dir && -d $dir;
    opendir(my $dh, $dir) or return ();
    my @files = grep { /\A\Q$pkg\E-.*\.verdict\.json\z/ } readdir $dh;
    closedir $dh;
    @files = sort { $b cmp $a } @files;   # timestamp-in-filename -> lexicographic == chronological
    my @out;
    for my $f (@files) {
        my $d = _read_json_file("$dir/$f");
        push @out, $d if ref $d eq 'HASH';
    }
    return @out;
}
sub cli_advance {
    my ($opt) = @_;
    _usage_exit("--blueprint is required") unless defined $opt->{blueprint} && length $opt->{blueprint};
    _require_checkpoint();
    my $root = (defined $opt->{root} && length $opt->{root}) ? $opt->{root} : BpCheckpoint::resolve_root(undef);
    my $blueprint = $opt->{blueprint};

    my $bpdir = "$root/.ccpraxis-local-data/blueprints/$blueprint";
    my $runs  = "$bpdir/runs";
    my $registry = _read_registry_packages($runs);

    my (%status, %known);
    if (opendir(my $dh, "$bpdir/packages")) {
        for my $f (readdir $dh) {
            next unless $f =~ /\A(.+)\.md\z/;
            my $pkg = $1;
            $known{$pkg} = 1;
            my $txt = _read_all_bytes("$bpdir/packages/$f");
            $status{$pkg} = $1 if defined $txt && $txt =~ /^status:\s*(\S+)/m;
        }
        closedir $dh;
    }

    my %harvest;
    for my $pkg (keys %known) {
        my $reg  = $registry->{$pkg} || {};
        my $live = _read_json_file("$runs/harvest/$pkg.verdict.json");
        my @archives = _read_archives_newest_first("$runs/harvest/archive", $pkg);
        $harvest{$pkg} = harvest_passed({ registry_entry => $reg, live => (ref $live eq 'HASH' ? $live : undef),
                                          archives => \@archives });
    }
    my $eligible = eligible_packages({ status => \%status, harvest => \%harvest });

    my ($log_out, $log_rc) = _run_capture('git', '-C', $root, 'log', '--first-parent', '--reverse',
                                           '--format=%H%x00%s');
    my @commits;
    if (defined $log_rc && $log_rc == 0 && defined $log_out) {
        for my $line (split /\n/, $log_out) {
            my ($sha, $subj) = split /\0/, $line, 2;
            next unless defined $sha && length $sha;
            push @commits, { sha => $sha, subject => defined $subj ? $subj : '' };
        }
    }

    my $sel = select_baseline({ commits => \@commits, eligible => $eligible, known => \%known });
    if (defined $sel) {
        my (undef, $urc) = _run_capture('git', '-C', $root, 'update-ref', "refs/butler/baseline/$blueprint", $sel);
        if (defined $urc && $urc == 0) {
            print "advanced refs/butler/baseline/$blueprint to $sel\n";
            exit 0;
        }
        print STDERR "bp-baseline: failed to update refs/butler/baseline/$blueprint\n";
        exit 4;
    }
    _run_capture('git', '-C', $root, 'update-ref', '-d', "refs/butler/baseline/$blueprint");
    print STDERR "bp-baseline: no eligible baseline for '$blueprint' -- ref deleted (empty baseline)\n";
    exit 1;
}

package main;
use strict;
use warnings;

# ===========================================================================
# CLI  (skipped entirely under `require` -- see the header)
# ===========================================================================
unless (caller) {
    my $action = shift @ARGV;
    BpBaseline::_usage_exit("missing action") unless defined $action && length $action;

    my %opt;
    while (@ARGV) {
        my $a = shift @ARGV;
        if ($a eq '--strict-deps') { $opt{strict_deps} = 1; next; }
        if ($a =~ /\A--([a-z][a-z0-9-]*)\z/) {
            my $k = $1;
            BpBaseline::_usage_exit("missing value for --$1") unless @ARGV;
            $k =~ s/-/_/g;
            $opt{$k} = shift @ARGV;
            next;
        }
        BpBaseline::_usage_exit("unknown argument '$a'");
    }

    if    ($action eq 'materialize') { BpBaseline::cli_materialize(\%opt); }
    elsif ($action eq 'teardown')    { BpBaseline::cli_teardown(\%opt); }
    elsif ($action eq 'gate')        { BpBaseline::cli_gate(\%opt); }
    elsif ($action eq 'status')      { BpBaseline::cli_status(\%opt); }
    elsif ($action eq 'advance')     { BpBaseline::cli_advance(\%opt); }
    else  { BpBaseline::_usage_exit("unknown action '$action'"); }
}

1;
