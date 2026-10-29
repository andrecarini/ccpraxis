#!/usr/bin/env perl
# bp-lifecycle.pl — reconcile a blueprint's recorded run-state with what is
# actually on disk, and archive it once it is done.
#
# WHAT THIS SCRIPT DOES NOW
#
# On every observation of a dead (non-live) blueprint it:
#
#   1. removes a stale `runs/.orchestrator` marker (one whose pid is no
#      longer alive, or holds no usable pid at all);
#   2. clears a TERMINAL package's leftover `pid` from its `runs/registry.json`
#      entry — this is the only place left that clears that pid
#      (bp-orchestrator.pl names this script "the only clearer" of it; a
#      reused pid would otherwise make `bp-status.sh` draw a dead run as
#      live);
#   3. writes a package's ledger `status: running` back to `pending` when the
#      registry cannot supply a pid for it (no row, or a row with no `pid`
#      key) AND no live process — fleet coordinator or solo driver — can be
#      attributed to it ("orphaned running"; 10-unreapable-running). Only the
#      ledger is written; `runs/registry.json` is never touched by this
#      repair;
#   4. withdraws (never deletes) a queued escalation of a nominated kind
#      whose premise has demonstrably evaporated, gaining `withdrawn_at` /
#      `withdrawn_reason` on the record (10-unreapable-running, criterion 7);
#   5. archives the blueprint (moves it into `blueprints/_archive/`) once its
#      lifecycle derives `done` (see `BpState::blueprint_lifecycle`), unless
#      `--no-archive` was given.
#
# It does NOT repair blueprint.md's package-status TABLE, and it does NOT
# reconcile a `runs/registry.json` entry's `status` field — both were retired
# by s05-retire-reconciler-drift-paths (2026-08-14): the table's writer
# (`bp-blueprint.pl`'s `set-status` verb) was hard-retired by s03, and no
# in-scope reader ever consults a registry entry's `status` key any more
# (only the ledgers are). This script previously also repaired those two
# copies of package status; see this blueprint's Harvest log for why that
# became impossible (the 2026-07-28 table-drift incident that motivated the
# original four-copies design is recorded there, not here).
#
# THE RULE THIS SCRIPT ENFORCES
#
#   The ledgers are the truth. Everything else observed here is derived, and
#   is repaired to match on every observation.
#
# SAFETY
#
# A LIVE run owns its own state. When `runs/.orchestrator` exists AND its pid is
# alive, this script reports what it sees and changes NOTHING — racing the
# orchestrator for registry.json would be a far worse bug than the staleness it
# is fixing. Only a dead run is reconciled.
#
# Usage:
#   bp-lifecycle.pl reconcile --blueprint <name|dir> [options]
#   bp-lifecycle.pl reconcile --all                  [options]
#
# Options:
#   --data-dir DIR   blueprints root's parent (default: $CCPRAXIS_DATA_DIR, else
#                    <project-root>/.ccpraxis-local-data)
#   --archive        move a blueprint that reaches `done` into blueprints/_archive/
#   --no-archive     never archive (default is --archive; see ARCHIVING below)
#   --dry-run        report what would change, change nothing
#   --json           machine-readable report on stdout
#   --quiet          suppress the human report (implied by --json)
#
# ARCHIVING is on by default and that is deliberate. The operator's standing
# instruction is that they should not have to ask for a finished blueprint to be
# closed out and filed. Archiving is a MOVE into `_archive/`, never a delete:
# nothing is lost, the blueprint stays readable, and `/blueprint:manage list`
# still names archived ones.
#
# Exit status: 0 on success, 2 on a usage error or if any blueprint could not
# be reconciled.

package BpLifecycle;

use strict;
use warnings;
use Getopt::Long qw(GetOptionsFromArray);
use File::Path qw(make_path remove_tree);
use File::Copy ();
use File::Spec;
use Fcntl qw(:flock);

my $SCRIPT_DIR = do {
    # __FILE__, not $0: this file is now requirable (package 05,
    # move-dir-safety), and under `require` from a test $0 is the TEST file,
    # so a sibling require anchored on $0 would resolve against the wrong
    # directory. __FILE__ is always this file's own path, in every mode.
    my $p = __FILE__;
    if ($p =~ m{[\\/]}) {
        $p =~ s{[\\/][^\\/]+\z}{};
        $p = '.' unless length $p;
    } elsif (-f $p) {
        # bare-name invocation (perl bp-lifecycle.pl ...): no separator means
        # perl resolved it against cwd, so cwd IS the script's directory --
        # but only when __FILE__ actually names a real file here. Reject the
        # alternative (red-team 03, L1/L2): fed through stdin or a string
        # eval, __FILE__ is a sentinel like '-' or '(eval N)' that is NOT a
        # file on disk, so falling through to '.' would load sibling modules
        # from an arbitrary, possibly attacker-controlled cwd. No ccpraxis
        # caller invokes this script that way today, but there's no reason to
        # leave the door open.
        $p = '.';
    } else {
        die "bp-lifecycle.pl: cannot determine script directory from __FILE__ ('$p'); refusing to guess a sibling-module search path.\n";
    }
    # ABSOLUTE, and that is load-bearing rather than tidy. `require` with a
    # RELATIVE path searches @INC instead of resolving against cwd, and modern
    # perl (5.26+) no longer carries '.' in @INC -- so the require below died
    # with "Can't locate plugins/butler/scripts/BpState.pm in @INC" whenever
    # this script was invoked by a relative path, i.e. the normal way a human
    # or a hook types it from the repo root. It worked only when invoked
    # absolutely, which is exactly how every oracle invokes it, which is why no
    # test caught it: t/lifecycle-reconcile.t, t/lifecycle-derived.t
    # and t/no-drift-to-repair.t all build $LIFECYCLE from abs_path.
    # Introduced by s04 (de81269) when BpState was wired in; found when the
    # driver ran the script by hand to archive a finished blueprint.
    File::Spec->rel2abs($p);
};
my $BP_BLUEPRINT = "$SCRIPT_DIR/bp-blueprint.pl";

require "$SCRIPT_DIR/BpState.pm";
require "$SCRIPT_DIR/bp-write-guard.pl";   # BpWrite::guarded_write
require "$SCRIPT_DIR/BpDataRoot.pm";       # the single, bounded data-root resolution chain (package 04)

# ---------------------------------------------------------------- statuses ---
# The six package statuses bp-blueprint.pl recognises. `dropped` is accepted as
# terminal-but-not-delivered because bp-drive-next.pl emits it.
my %TERMINAL   = map { $_ => 1 } qw(done dropped blocked parked);
my %DELIVERED  = map { $_ => 1 } qw(done dropped);

# ---------------------------------------------------- self-withdrawable ------
# EXPLICIT, CLOSED LIST. Adding a kind here is a decision about whether a
# machine may retract a question a human can already see. Getting it wrong in
# the permissive direction makes a real question vanish, which is strictly
# worse than the noise it removes (package ledger, done-criterion 7).
#
# M3 (redteam, 10-unreapable-running): this writer's `withdrawn_at` is INERT
# until two readers are wired that are OUTSIDE this file's write set --
# RunState::decision_live (plugins/sandbox/scripts/RunState.pm) must stop
# counting a withdrawn record as live, AND bp-orchestrator.pl's
# queue_needs_you dedupe (its persistent (package, kind) scan) must skip a
# withdrawn record so the SAME transient can be re-filed if it recurs.
# THESE TWO MUST LAND IN THE SAME CHANGE, NEVER ONE WITHOUT THE OTHER: wiring
# decision_live alone makes a withdrawn record disappear from the operator's
# count while queue_needs_you STILL treats it as filed, so the transient can
# never be re-escalated if it recurs -- a silent permanent hold, which is
# exactly the failure criterion 7 exists to close, reopened one level down.
# See this package's ledger for the deferral note this comment mirrors.
my %SELF_WITHDRAWABLE = (
    'awaiting-ledger' => {
        # premise: the package has no ledger, or its frontmatter status will
        # not parse. Mirrors bp-orchestrator.pl:2787's `ledger_missing` exactly.
        premise_holds => sub {
            my ($bpdir, $pkg) = @_;
            my $f = "$bpdir/packages/$pkg.md";
            return 1 unless -f $f;
            return 1 unless defined fm_get($f, 'status');
            return 0;
        },
        reason => 'the package ledger now exists and parses; the condition this decision '
                . 'reported no longer holds',
    },
);

sub die_usage {
    my ($msg) = @_;
    print STDERR "bp-lifecycle: $msg\n" if defined $msg;
    print STDERR <<'USAGE';
usage: bp-lifecycle.pl reconcile (--blueprint <name|dir> | --all)
                                 [--data-dir DIR] [--archive|--no-archive]
                                 [--dry-run] [--json] [--quiet]
USAGE
    exit 2;
}

# ------------------------------------------------------------------ roots ----
# BpDataRoot.pm (package 04) is the single, bounded resolution chain shared
# with bp-drive-next.pl. Its own walk-up is bounded at the OS temp dir and at
# the user's home dir (bug 0f1e) -- this file no longer carries its own copy.

sub project_root { BpDataRoot::project_root() }

sub data_dir {
    my ($override) = @_;
    return BpDataRoot::data_dir(data_dir => $override);
}

# ------------------------------------------------------------------- io ------

sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

# LOW L1 (redteam): a bounded read of at most $cap+1 bytes, so an oversized
# file under runs/escalations/ (or a bloated current.json/pid marker) is
# never pulled fully into memory just to be rejected a moment later on a
# length() check -- bp-status.sh runs this reconciler on every invocation,
# for every blueprint (spec edge case 7). Returns undef if unreadable;
# otherwise a scalar whose length may exceed $cap, which the caller rejects
# with its own existing length check (unchanged from before this fix).
sub slurp_capped {
    my ($path, $cap) = @_;
    open my $fh, '<:raw', $path or return undef;
    my $buf = '';
    my $n = read($fh, $buf, $cap + 1);
    close $fh;
    return undef unless defined $n;
    return $buf;
}

# Frontmatter `key:` lookup inside the FIRST `---` block. Mirrors fm_get in
# bp-lib.sh so the two surfaces cannot disagree about what a ledger says.
sub fm_get {
    my ($path, $key) = @_;
    my $c = slurp($path);
    return undef unless defined $c;
    my $in = 0;
    for my $ln (split /\n/, $c) {
        if ($ln =~ /^---\s*\z/) { $in++; last if $in == 2; next }
        next unless $in == 1;
        if ($ln =~ /^\Q$key\E:\s*(.*?)\s*\z/) { return $1 }
    }
    return undef;
}

# Strip decoration (glyphs, bold markers, trailing commentary) from a status
# cell and lowercase it. The table stores things like "✅ done"; the ledger
# stores a bare word. Comparing them raw manufactures drift that isn't there.
sub norm_status {
    my ($s) = @_;
    return '' unless defined $s;
    $s = lc $s;
    $s =~ s/[^a-z]+/ /g;
    $s =~ s/\A\s+|\s+\z//g;
    for my $w (split /\s+/, $s) {
        return $w if $w =~ /\A(?:done|pending|running|reviewing|blocked|parked|dropped)\z/;
    }
    return '';
}

# ----------------------------------------------------------- marker/pid ------

sub marker_pid {
    my ($path) = @_;
    return undef unless -e $path;
    my $c = slurp_capped($path, 4096);
    return undef unless defined $c;
    return undef if length($c) > 4096;      # a marker is a pid, not a document
    $c =~ s/\s+//g;
    return undef unless $c =~ /\A[0-9]+\z/ && $c > 0;
    return $c + 0;
}

sub pid_alive {
    my ($pid) = @_;
    return 0 unless defined $pid && $pid =~ /\A[0-9]+\z/ && $pid > 0;
    return kill(0, $pid) ? 1 : 0;
}

# Classifies a runs/.orchestrator marker without holding any lock on return:
# 'absent' (no file), 'free' (an LOCK_SH|LOCK_NB probe succeeded -- nobody
# holds it), 'held' (the probe lost to a conflicting lock), or 'error' (open
# or flock failed for any other reason; $err explains). Named so a test can
# call it directly (spec 12, 2.2) -- never inline this.
sub marker_probe {
    my ($path) = @_;
    my $fh;
    unless (open($fh, '<', $path)) {
        return ('absent', undef) if $!{ENOENT};
        return ('error', "open: $!");
    }
    if (flock($fh, LOCK_SH | LOCK_NB)) {
        flock($fh, LOCK_UN);
        close $fh;
        return ('free', undef);
    }
    my $held = $!{EWOULDBLOCK} || $!{EAGAIN} || $!{EACCES};
    my $err  = $!;
    close $fh;
    return ('held', undef) if $held;
    return ('error', "flock: $err");
}

# The only unlinker of a stale runs/.orchestrator marker. Holds LOCK_EX
# across the path-identity check and the unlink itself (spec 12, 2.3.1) so a
# starting orchestrator or a second concurrent reconciler cannot race it.
# Returns 1 if reconcile_one must return immediately afterward (no repairs
# 2-4: the removal collided with a starting orchestrator, or the marker was
# replaced mid-reconcile), 0 if normal flow should continue (removal
# succeeded or failed outright -- same as today's behaviour).
sub remove_stale_marker {
    my ($marker, $r, $why) = @_;
    my $fh;
    unless (open($fh, '<', $marker)) {
        return 0 if $!{ENOENT};
        push @{ $r->{errors} }, "could not remove stale marker $marker: $!";
        return 1;
    }
    unless (flock($fh, LOCK_EX | LOCK_NB)) {
        if ($!{EWOULDBLOCK} || $!{EAGAIN} || $!{EACCES}) {
            close $fh;
            $r->{live} = 1;
            $r->{marker_lock} = 'held';
            push @{ $r->{actions} }, { kind => 'skipped', detail => 'runs/.orchestrator was locked by a starting orchestrator; left in place' };
            return 1;
        }
        my $err = $!;
        close $fh;
        push @{ $r->{errors} }, "could not lock stale marker $marker: $err";
        return 1;
    }
    my @path_stat = stat($marker);
    my @fh_stat   = stat($fh);
    unless (@path_stat && @fh_stat
            && $path_stat[0] == $fh_stat[0] && $path_stat[1] == $fh_stat[1]) {
        flock($fh, LOCK_UN);
        close $fh;
        push @{ $r->{actions} }, { kind => 'skipped', detail => 'runs/.orchestrator was replaced during reconcile; left in place' };
        return 1;
    }
    if (unlink $marker) {
        push @{ $r->{actions} }, { kind => 'stale_marker', detail => "removed runs/.orchestrator ($why)", applied => 1 };
    } else {
        push @{ $r->{errors} }, "could not remove stale marker $marker: $!";
    }
    flock($fh, LOCK_UN);
    close $fh;
    return 0;
}

# The coordinator pid bp-launch.sh's watcher recorded for this package, or
# undef. Reuses marker_pid(), whose 4096-byte cap and digits-only rule already
# fit a pid file.
sub coordinator_pid {
    my ($runs, $pkg) = @_;
    return marker_pid("$runs/$pkg.pid");
}

# 1 if a solo driver's in-flight set names this (blueprint, package). Batch C
# (spec 16-cutover 2.8, 1.3 departure #9): re-pointed from current.json to
# inflight.json -- current.json is gone, and without this the reconciler's
# solo-driver protection would silently go off. $data_root is the
# reconciler's own resolved data dir.
sub solo_claimed {
    my ($data_root, $bp_name, $pkg) = @_;
    return 0 unless defined $data_root && length $data_root;
    my $path = "$data_root/.drive-solo/inflight.json";
    return 0 unless -f $path;
    my $c = slurp_capped($path, 65536);
    return 0 unless defined $c && length $c && length($c) <= 65536;
    require JSON::PP;
    my $rec = eval { JSON::PP->new->decode($c) };
    return 0 if $@ || ref $rec ne 'HASH';
    return 0 unless ref $rec->{packages} eq 'ARRAY';
    for my $e (@{ $rec->{packages} }) {
        next unless ref $e eq 'HASH';
        next unless defined $e->{package} && !ref($e->{package}) && $e->{package} eq $pkg;
        my $rec_bp = $e->{blueprint};
        return 1 if !defined $rec_bp || (!ref($rec_bp) && $rec_bp eq '');
        return 1 if !ref($rec_bp) && $rec_bp eq $bp_name;
    }
    return 0;
}

# A package key is "safe" for reading/writing as packages/<pkg>.md. Mirrors
# RunState::_safe_pkg_name (plugins/sandbox/scripts/RunState.pm:163-172)
# exactly: escalation records are attacker-adjacent input (spec §2.7 step 5),
# and that precedent additionally rejects ':' (NTFS Alternate Data Streams,
# e.g. "pkg:stream") and Windows reserved device names (CON/PRN/AUX/NUL/
# COM1-9/LPT1-9, with or without an extension -- "NUL.md" resolves to the
# device the same as bare "NUL"). review MUST-FIX 1: this sub previously
# omitted both, letting a record like {"package":"NUL"} reach -f/open on
# packages/<pkg>.md via premise_holds, on every bp-status.sh invocation.
sub safe_pkg_name {
    my ($pkg) = @_;
    return 0 unless defined $pkg && !ref($pkg) && length($pkg);
    return 0 if $pkg =~ /[\/\\\x00]/;
    return 0 if $pkg =~ /\.\./;
    return 0 if $pkg =~ /^\./;
    return 0 if length($pkg) > 128;
    return 0 if $pkg =~ /:/;
    return 0 if $pkg =~ /\A(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|\z)/i;
    return 1;
}

# --------------------------------------------------------------- packages ----

# Read every ledger's status. Returns [ { pkg, status, file }, ... ] sorted by
# package id. `*.md.lock` files are flock artefacts, not ledgers.
sub read_ledgers {
    my ($bpdir) = @_;
    my @out;
    opendir(my $dh, "$bpdir/packages") or return @out;
    for my $f (sort readdir $dh) {
        next unless $f =~ /\.md\z/;
        next if $f =~ /\.lock\z/;
        my $path = "$bpdir/packages/$f";
        next unless -f $path;
        (my $pkg = $f) =~ s/\.md\z//;
        my $st = norm_status(fm_get($path, 'status'));
        push @out, { pkg => $pkg, status => (length $st ? $st : 'pending'), file => $path };
    }
    closedir $dh;
    return @out;
}

# ------------------------------------------------------- blueprint.md API ----
# Every blueprint.md mutation goes through bp-blueprint.pl. It validates, writes
# atomically under flock, and is what the Edit-blocking guard hook points at.
# Reimplementing the splice here would recreate exactly the hand-editing this
# repo already decided to forbid.

# Returns (ok, captured_output). Output is captured rather than inherited:
# bp-blueprint.pl's own confirmations would interleave with our report, and this
# script's value is that its output says exactly what changed. On failure the
# captured text goes into the error so the failure stays diagnosable.
#
# Capture goes through a REAL temp file, never an in-memory scalar: reopening
# STDOUT onto a scalar fails on Git-for-Windows perl with "Bad file descriptor"
# and surfaces as a bare `Died at ... line N` (project CLAUDE.md).
sub bp_call_out {
    my (@args) = @_;
    require File::Temp;
    my ($tfh, $tmp) = File::Temp::tempfile();
    close $tfh;

    open(my $saved_out, '>&', \*STDOUT) or return (0, 'cannot dup STDOUT');
    open(my $saved_err, '>&', \*STDERR) or return (0, 'cannot dup STDERR');
    my $rc = -1;
    {
        if (open(STDOUT, '>', $tmp)) {
            open(STDERR, '>&', \*STDOUT);
            $rc = system($^X, $BP_BLUEPRINT, @args);
        }
    }
    open(STDOUT, '>&', $saved_out);
    open(STDERR, '>&', $saved_err);
    close $saved_out; close $saved_err;

    my $out = slurp($tmp);
    unlink $tmp;
    $out = '' unless defined $out;
    $out =~ s/\s+\z//;
    return ($rc == 0 ? 1 : 0, $out);
}

sub bp_call {
    my ($ok) = bp_call_out(@_);
    return $ok;
}

# ------------------------------------------------------------- registry ------

sub read_registry {
    my ($path) = @_;
    my $c = slurp($path);
    return undef unless defined $c && length $c;
    require JSON::PP;
    my $d = eval { JSON::PP->new->decode($c) };
    return undef if $@ || ref $d ne 'HASH';
    return $d;
}

sub write_registry {
    my ($path, $data) = @_;
    require JSON::PP;
    my $json = eval { JSON::PP->new->canonical->pretty->encode($data) };
    return 0 if $@ || !defined $json;
    my $tmp = "$path.tmp.$$";
    open my $fh, '>:raw', $tmp or return 0;
    print $fh $json or do { close $fh; unlink $tmp; return 0 };
    close $fh or do { unlink $tmp; return 0 };
    # rename() over an existing file is atomic on POSIX; on Windows it fails if
    # the destination exists, so unlink first. The tiny window is acceptable:
    # this only runs when no orchestrator is live.
    unlink $path if $^O =~ /^(MSWin32|cygwin|msys)$/ && -e $path;
    unless (rename $tmp, $path) { unlink $tmp; return 0 }
    return 1;
}

# ------------------------------------------------------------ archiving ------

# --- move_dir seams (package 05, bug 69f8) --------------------------------
# `our` package variables, defaulting to the real rename/copy, so production
# behaviour is byte-identical to before this package. Never read from the
# environment, a file, or the CLI (bp-write-guard.pl's own removed env kill
# switch is why not: an env seam production can reach is a hazard, not a
# convenience). Tests override with `local $BpLifecycle::RENAME_FN = sub {...}`.
our $RENAME_FN    = sub { my ($from, $to, $phase) = @_; return rename($from, $to) };
our $COPY_FILE_FN = sub { my ($from, $to) = @_;         return File::Copy::copy($from, $to) };

my $FINAL_ATTEMPTS = 5;

# Move $src to $dst. rename() is the fast path; when it fails we fall back to a
# pure-perl copy + remove, staged beside $dst rather than into it (bug 69f8):
# the old shape copied straight into $dst and, on a copy failure, removed
# $dst outright -- if another party had filed the SAME destination in the
# meantime (a concurrent reconcile, a manual run, an orchestrator), that
# cleanup deleted the OTHER party's data. This never touches $dst except to
# check it exists, and never removes anything but its own staging directory
# (created fresh, exclusively, in step 4 below) and $src (only after the
# staged copy has been placed).
#
# The fallback itself is not theoretical. Moving a real blueprint directory on
# this Windows host failed with EBUSY from MSYS `mv` on every attempt while a
# native move of the same directory succeeded immediately — a background
# handle (search indexer / AV) on one of ~500 files is enough. Losing an
# archive to that would be far worse than copying a few megabytes, so we
# degrade instead of failing.
sub move_dir {
    my ($src, $dst) = @_;

    # 1. Nothing touched, no seam called, if $dst already exists.
    return (0, "destination exists: $dst") if (-e $dst || -l $dst);

    # 2. The fast path.
    if ($RENAME_FN->($src, $dst, 'direct')) {
        return (1, 'rename');
    }
    my $rename_err = "$!";

    # 3. $dst may have appeared during step 2's attempt; nothing was copied.
    if (-e $dst || -l $dst) {
        return (0, "destination appeared: $dst (rename failed: $rename_err); "
                 . "nothing was copied and the source is untouched");
    }

    # 4. Stage the copy beside $dst, never inside it.
    my ($staging, $mkdir_err) = _make_staging($dst);
    unless (defined $staging) {
        return (0, "rename failed ($rename_err) and no staging directory could be "
                 . "created beside $dst ($mkdir_err)");
    }

    # 5. Copy into the staging directory. A false return OR a die from the
    #    seam both land here; either way the staging directory is dropped and
    #    $src/$dst are untouched.
    my $copy_ok = eval { _copy_tree($src, $staging); 1 };
    unless ($copy_ok) {
        my $copy_err = $@;
        $copy_err = '' unless defined $copy_err;
        $copy_err =~ s/\s+\z//;
        my $tail = _drop_staging($staging);
        return (0, "rename failed ($rename_err) and copy failed ($copy_err)" . $tail);
    }

    # 6. Final placement: rename the staging directory into place, checking
    #    for a party that beat us to $dst before EVERY attempt.
    my ($placed, $appeared, $final_err) = (0, 0, undef);
    for my $attempt (1 .. $FINAL_ATTEMPTS) {
        if (-e $dst || -l $dst) { $appeared = 1; last; }
        if ($RENAME_FN->($staging, $dst, 'final')) { $placed = 1; last; }
        $final_err = "$!";
        if (-e $dst || -l $dst) { $appeared = 1; last; }
        select(undef, undef, undef, 0.2) unless $attempt == $FINAL_ATTEMPTS;
    }
    unless ($placed) {
        my $tail = _drop_staging($staging);
        if ($appeared) {
            return (0, "destination appeared: $dst; the source $src was kept "
                     . "and the staged copy discarded" . $tail);
        }
        return (0, "rename failed ($rename_err) and moving the staged copy into "
                 . "place failed ($final_err); the source $src was kept and the "
                 . "staged copy discarded" . $tail);
    }

    # 7. The copy is safely in place; only now do we touch $src.
    my $removed = eval { remove_tree($src); 1 };
    if (!$removed || -d $src) {
        # The copy is good; the source lingers. Say so plainly rather than
        # reporting success — a duplicated blueprint would be listed twice.
        return (0, "copied to $dst but could not remove the original $src"
                 . " (rename had failed: $rename_err)");
    }
    return (1, 'copy+remove');
}

# Copies the CONTENTS of $src into the EXISTING directory $into. Never calls
# make_path on $into (the caller -- _make_staging -- already created it with a
# single exclusive mkdir) and never touches anything outside $into.
sub _copy_tree {
    my ($src, $into) = @_;
    opendir(my $dh, $src) or die "opendir $src: $!\n";
    my @entries = grep { $_ ne '.' && $_ ne '..' } readdir $dh;
    closedir $dh;
    for my $e (@entries) {
        my ($s, $d) = ("$src/$e", "$into/$e");
        if (-d $s && !-l $s) {
            mkdir($d) or die "mkdir $d: $!\n";
            _copy_tree($s, $d);
        } else {
            $COPY_FILE_FN->($s, $d) or die "copy $s -> $d: $!\n";
        }
    }
    return 1;
}

# _make_staging($dst) -> ($path) | (undef, $err). Creates a uniquely named
# directory beside $dst (never inside it) with a single exclusive `mkdir`,
# retrying on EEXIST up to 8 times total. Only a path THIS call's mkdir
# returned true for is ever handed to _drop_staging.
sub _make_staging {
    my ($dst) = @_;
    my $path = $dst;
    $path =~ s{[\\/]+\z}{};             # strip trailing separators first
    my ($parent, $base);
    if ($path =~ m{\A(.*)[\\/]([^\\/]+)\z}) {
        ($parent, $base) = ($1, $2);
        $parent = '.' unless length $parent;
    } else {
        ($parent, $base) = ('.', $path);
    }
    for (1 .. 8) {
        my $candidate = sprintf('%s/.%s.move-staging.%d.%08x',
            $parent, $base, $$, int(rand(0xFFFFFFFF)));
        return ($candidate) if mkdir($candidate);
        return (undef, "$!") unless $!{EEXIST};
    }
    return (undef, "$!");
}

# _drop_staging($staging) -> $tail. Removes the staging directory this call
# created; returns '' on success, else a tail naming the leftover path. Never
# touches anything but $staging.
sub _drop_staging {
    my ($staging) = @_;
    eval { remove_tree($staging, { error => \my $e }); 1 };
    return '' unless -e $staging;
    return "; the staging directory $staging could not be removed";
}

# --------------------------------------------------------------- reconcile ---

sub reconcile_one {
    my ($bpdir, $opt) = @_;
    my $name = $bpdir;
    # LOW L2 (redteam): strip trailing separators BEFORE taking the
    # basename. "…/foo/" without this yields '', which silently makes
    # solo_claimed's blueprint comparison unmatchable for the whole
    # invocation (P4 goes inert). bp-orchestrator.pl already passes a bare
    # directory (no trailing slash) at its own call site, so this is
    # defense-in-depth for any other caller, not a live bug today.
    $name =~ s{[\\/]+\z}{};
    $name =~ s{.*[\\/]}{};

    my %r = (blueprint => $name, dir => $bpdir, actions => [], errors => []);

    my $bpmd = "$bpdir/blueprint.md";
    unless (-f $bpmd) {
        push @{ $r{errors} }, 'no blueprint.md (not a blueprint directory)';
        return \%r;
    }

    my $bp_status = norm_bp_status(bp_meta_get($bpmd, 'status'));
    $r{status_before} = $bp_status;
    $r{status_after}  = $bp_status;

    my @ledgers = read_ledgers($bpdir);
    $r{packages} = scalar @ledgers;
    my %count;
    $count{ $_->{status} }++ for @ledgers;
    $r{counts} = \%count;

    # --- liveness. A live run owns its state; we only report. ---------------
    my $runs   = "$bpdir/runs";
    my $marker = "$runs/.orchestrator";
    my $pid    = marker_pid($marker);
    my ($lock, $lock_err) = marker_probe($marker);
    my $live   = ($lock eq 'held')                        ? 1
               : ($lock ne 'absent' && pid_alive($pid))    ? 1
               :                                             0;
    # H2/H1 (redteam): whether an orchestrator marker EVER existed here, not
    # merely whether it still does after block 1 below may remove it.
    my $marker_existed = -e $marker ? 1 : 0;
    $r{live} = $live;
    $r{orchestrator_pid} = $pid;
    $r{marker_lock} = $lock;

    my $lifecycle = BpState::blueprint_lifecycle($bpdir, \&pid_alive);
    $r{lifecycle} = $lifecycle;

    if ($live) {
        my $detail = ($lock eq 'held')
            ? "orchestrator marker lock is held (" . (defined $pid ? "pid $pid" : 'pid unknown') . "); state belongs to the run"
            : "orchestrator pid $pid is alive; state belongs to the run";
        push @{ $r{actions} }, { kind => 'skipped', detail => $detail };
        return \%r;
    }

    if ($lock eq 'error') {
        push @{ $r{actions} }, { kind => 'skipped', detail => "could not probe the runs/.orchestrator lock ($lock_err); refusing to judge the run live or dead, nothing reconciled" };
        push @{ $r{errors} }, "could not probe orchestrator marker lock: $lock_err";
        return \%r;
    }

    # --- 1. stale marker ----------------------------------------------------
    if ($lock eq 'free') {
        my $why = defined $pid ? "pid $pid is not alive" : 'marker holds no usable pid';
        if ($opt->{dry_run}) {
            push @{ $r{actions} }, { kind => 'stale_marker', detail => "would remove runs/.orchestrator ($why)", applied => 0 };
        } else {
            my $abort = remove_stale_marker($marker, \%r, $why);
            return \%r if $abort;
        }
    }

    # --- 2. registry pid hygiene (was step 3's second half; the
    #        status-reconciliation half is deleted outright -- s02 made
    #        runs/registry.json runtime-only and no in-scope reader ever
    #        consults an entry's status key again (bp-orchestrator.pl's
    #        ::_load_state reads only attempt/pid/session_id; bp-status.sh
    #        reads only pid/attempt). A terminal package's leftover pid is
    #        independently live: bp-orchestrator.pl names this script "the
    #        only clearer" of it, and bp-status.sh's PROC column consumes
    #        the same field -- so that half survives, renamed honestly. ----
    # review SHOULD-FIX 2: read/decode runs/registry.json exactly ONCE per
    # invocation and reuse the decode for both block 2 and block 3 below
    # (previously each block read and JSON-decoded it independently; spec
    # edge case 7 flags this script's cost sensitivity explicitly, since
    # bp-status.sh runs it on every invocation). Block 2 only ever mutates
    # a TERMINAL package's entry; block 3 only ever inspects a `running`
    # package's entry -- the two sets are disjoint (a ledger cannot be both
    # TERMINAL and `running`), so sharing the same in-memory hash between
    # them is safe.
    my $regpath = "$runs/registry.json";
    my ($reg_data, $reg_unknown) = (undef, 0);
    if (-f $regpath) {
        $reg_data = read_registry($regpath);
        $reg_unknown = 1 unless defined $reg_data;
    }

    if (-f $regpath) {
        if ($reg_unknown) {
            push @{ $r{errors} }, 'runs/registry.json is unreadable or not JSON; left untouched';
        } elsif (ref($reg_data->{packages}) eq 'HASH') {
            my @cleared;
            my %by_pkg = map { $_->{pkg} => $_->{status} } @ledgers;
            for my $pkg (sort keys %{ $reg_data->{packages} }) {
                my $entry = $reg_data->{packages}{$pkg};
                next unless ref $entry eq 'HASH';
                next unless exists $by_pkg{$pkg};
                my $ledger_status = $by_pkg{$pkg};

                # A terminal package holds no process -- independent of
                # whether its entry carries a status key at all (post-s02,
                # most do not). Leaving a pid behind makes `bp-status.sh`
                # draw a dead run as having live coordinators the moment
                # that pid is reused.
                if ($TERMINAL{$ledger_status} && exists $entry->{pid}) {
                    push @cleared, "$pkg (pid cleared)";
                    delete $entry->{pid} unless $opt->{dry_run};
                }
            }
            if (@cleared) {
                my $detail = scalar(@cleared) . ' package(s): ' . join(', ', @cleared);
                if ($opt->{dry_run}) {
                    push @{ $r{actions} }, { kind => 'stale_pid', detail => "would clear $detail", applied => 0 };
                } elsif (write_registry($regpath, $reg_data)) {
                    push @{ $r{actions} }, { kind => 'stale_pid', detail => "cleared $detail", applied => 1 };
                } else {
                    push @{ $r{errors} }, 'could not write runs/registry.json';
                }
            }
        }
    }

    # --- H2 (redteam): the pid-namespace gate for repairs 3 and 4 -----------
    #
    # Every pid artefact this blueprint can carry (runs/.orchestrator,
    # runs/<pkg>.pid, a registry row's `pid`) is written EXCLUSIVELY by
    # tooling that requires the sandbox (bp-launch.sh's bp_require_sandbox
    # gate; drive-solo is sandbox-only by the same convention -- see
    # skills/drive-solo/SKILL.md). `bp-status.sh` is deliberately
    # host-runnable and carries no such gate (its own comment records why:
    # a hard requirement made the whole status surface unusable on the
    # host). `pid_alive` is `kill(0,$pid)` against the CALLER's own pid
    # namespace -- on the host, that is never the namespace that wrote a
    # container pid (project CLAUDE.md: "Crossing them does not error — it
    # answers 'no such process'"). Before this package, that false negative
    # cost a deleted `.orchestrator` marker; after it, the SAME false
    # negative would flip every `running` ledger the new repair touches to
    # `pending`. Refuse repairs 3/4 entirely, rather than risk it, whenever
    # this blueprint carries a pid artefact we cannot trust ourselves to
    # judge: a run only exists in the sandbox, so this loses nothing real.
    #
    # Only relevant, and only reported, when there is actually something for
    # repairs 3/4 to consider -- a `running` package (repair 3's only input)
    # or an escalations directory (repair 4's only input). A blueprint with
    # neither has nothing this gate could ever protect, and reporting a
    # `skipped` action anyway would be pure noise indistinguishable from a
    # real refusal, breaking every existing exact-action-count assertion in
    # sibling test files (lifecycle-reconcile.t s05 AC-8) that fixture a
    # stale marker / registry pid alongside packages that are NOT `running`.
    my $has_running_pkg = (grep { $_->{status} eq 'running' } @ledgers) ? 1 : 0;
    my $has_escalations_dir = -d "$runs/escalations" ? 1 : 0;
    my $pid_artefacts_present = $marker_existed;
    unless ($pid_artefacts_present) {
        for my $l (@ledgers) {
            if (-e "$runs/$l->{pkg}.pid") { $pid_artefacts_present = 1; last }
        }
    }
    if (!$pid_artefacts_present && !$reg_unknown
            && ref($reg_data) eq 'HASH' && ref($reg_data->{packages}) eq 'HASH') {
        for my $row (values %{ $reg_data->{packages} }) {
            if (ref($row) eq 'HASH' && exists $row->{pid}) { $pid_artefacts_present = 1; last }
        }
    }
    my $skip_new_repairs = ($pid_artefacts_present && !$ENV{IS_SANDBOX}
                             && ($has_running_pkg || $has_escalations_dir)) ? 1 : 0;
    if ($skip_new_repairs) {
        push @{ $r{actions} }, {
            kind   => 'skipped',
            detail => 'pid artefacts present (marker/pidfile/registry pid) and IS_SANDBOX is unset; '
                    . 'a host-side reconcile cannot judge a container pid\'s liveness, so repairs 3 '
                    . 'and 4 are refused rather than risk reaping live work',
        };
    }

    # --- 3. orphaned `running` ------------------------------------------------
    #
    # A package whose ledger says `running` while the registry cannot supply a
    # pid for it, and no live process (fleet coordinator OR solo driver) can be
    # attributed to it, is invisible to both halves of the orchestrator tick.
    # The ledger word is written back to `pending` -- the exact word the launch
    # path checks -- so the package re-enters the launch path. The registry is
    # never touched by this repair. See spec §2.4/§2.5/§3.
    if (!$skip_new_repairs) {
        unless ($reg_unknown) {
            my $pkgs = (ref($reg_data) eq 'HASH' && ref($reg_data->{packages}) eq 'HASH') ? $reg_data->{packages} : {};
            my @orphans;
            for my $l (@ledgers) {
                next unless $l->{status} eq 'running';
                my $pkg = $l->{pkg};
                my $shape;
                my $reg_row_exists = exists $pkgs->{$pkg};
                if (!$reg_row_exists) {
                    $shape = 'no registry row';
                } elsif (ref $pkgs->{$pkg} eq 'HASH' && !exists $pkgs->{$pkg}{pid}) {
                    $shape = 'registry row has no pid';
                } else {
                    next;   # P2 fails: a checkable pid, or a non-HASH (corrupt) row
                }
                next if pid_alive(coordinator_pid($runs, $pkg));                 # P3
                next if solo_claimed($opt->{data_root}, $name, $pkg);            # P4: a positive claim
                # H1 (redteam), IN-WRITE-SET HALF ONLY: for the ZERO-FLEET-
                # ARTEFACT shape -- no registry.json file at all, no
                # coordinator pid file ever for this package, no
                # orchestrator marker ever for this blueprint -- P4's
                # "no pointer found" is not proof of absence, only proof we
                # looked at $opt->{data_root}. drive-solo's own pointer
                # write is documented never-fatal and can silently fail
                # (bp-drive-next.pl _write_current_pointer), and a caller
                # that resolved a DIFFERENT data root than the one a solo
                # driver is using would see the same "no pointer" shape.
                # Invert the default for exactly this shape: decline unless
                # we can even name a data root to have positively looked
                # in. This does NOT touch the reported bug's own shape
                # (a registry.json that exists but lacks a row for this
                # package, per AC3a) -- only the strictly narrower shape
                # where no registry.json exists at all. The fuller fix
                # (threading --data-dir through bp-status.sh and
                # bp-orchestrator.pl so this data root is never wrong) is
                # outside this package's write set; recorded as a
                # follow-up in the package ledger.
                if (!$reg_row_exists && !-f $regpath
                        && !defined(coordinator_pid($runs, $pkg))
                        && !$marker_existed
                        && !(defined $opt->{data_root} && length $opt->{data_root})) {
                    next;
                }
                push @orphans, [ $pkg, $shape ];
            }
            @orphans = sort { $a->[0] cmp $b->[0] } @orphans;

            if (@orphans && $opt->{dry_run}) {
                my @pkg_list  = map { $_->[0] } @orphans;
                my @rendered  = map { "$_->[0] ($_->[1])" } @orphans;
                my $detail = 'would repair ' . scalar(@pkg_list) . ' package(s): ' . join(', ', @rendered);
                push @{ $r{actions} }, { kind => 'orphan_running', detail => $detail, packages => \@pkg_list, applied => 0 };
            }
            elsif (@orphans) {
                my (@repaired_pkgs, @repaired_rendered);
                for my $o (@orphans) {
                    my ($pkg, $shape) = @$o;
                    my $f = "$bpdir/packages/$pkg.md";
                    my $res = BpWrite::guarded_write({
                        site  => 'reconcile_orphan_running',
                        path  => $f,
                        valid => sub {
                            my ($txt) = @_;
                            return 'ledger unreadable or missing frontmatter'
                                unless defined $txt && $txt =~ /\A---\s*\n(.*?)\n---/s;
                            my $fm = $1;
                            # M1 (redteam): THE RE-READ THAT CLOSES THE RACE
                            # must check the CAPTURED FRONTMATTER ONLY,
                            # mirroring `mutate` below -- not scan the whole
                            # file/body, where an unrelated "status: running"
                            # line (e.g. quoted in a Decisions log entry, or
                            # a fenced YAML example) would otherwise pass.
                            return 'status-moved' unless $fm =~ /^status:\s*running\s*$/m;
                            # M2 (redteam): re-validate P3/P4 UNDER THE LOCK.
                            # The pre-lock @orphans snapshot above can be
                            # stale by the time this runs -- a coordinator's
                            # pid file, or a solo driver's claim, appearing
                            # in that window is exactly the TOCTOU window
                            # H1 depends on. These are two small file reads;
                            # under the lock they actually mean something.
                            return 'coordinator now alive' if pid_alive(coordinator_pid($runs, $pkg));
                            return 'solo-claimed now'      if solo_claimed($opt->{data_root}, $name, $pkg);
                            return undef;
                        },
                        mutate => sub {
                            my ($txt) = @_;
                            return (undef, 'no frontmatter block to update')
                                unless $txt =~ /\A---\s*\n(.*?)\n---/s;
                            my $fm = $1;
                            my $newfm = $fm;
                            $newfm =~ s/^status:.*$/status: pending/m;
                            my $iso = iso_now();
                            if ($newfm =~ /^last_updated:.*$/m) { $newfm =~ s/^last_updated:.*$/last_updated: $iso/m; }
                            (my $new = $txt) =~ s/\A---\s*\n.*?\n---/---\n$newfm\n---/s;
                            return ($new, undef);
                        },
                    });
                    if ($res->{ok} && ($res->{outcome} eq 'written' || $res->{outcome} eq 'unchanged')) {
                        push @repaired_pkgs, $pkg;
                        push @repaired_rendered, "$pkg ($shape)";
                    }
                    elsif (!$res->{ok} && $res->{outcome} eq 'refused') {
                        # the world moved under us; skip silently, not an error.
                        next;
                    }
                    else {
                        push @{ $r{errors} },
                            "could not set packages/$pkg.md to pending: $res->{outcome}: $res->{reason}";
                    }
                }
                if (@repaired_pkgs) {
                    my $detail = 'repaired ' . scalar(@repaired_pkgs) . ' package(s): ' . join(', ', @repaired_rendered);
                    push @{ $r{actions} }, { kind => 'orphan_running', detail => $detail, packages => \@repaired_pkgs, applied => 1 };
                }
            }
        }
    }

    # --- 4. escalation self-withdrawal (criterion 7) --------------------------
    #
    # A queued escalation of a nominated kind whose condition is demonstrably
    # gone gains `withdrawn_at` + `withdrawn_reason`. The record is never
    # deleted. See spec §2.6/§2.7.
    #
    # M4 (redteam): the per-record rewrite goes through BpWrite::guarded_write
    # -- the same house primitive the ledger repair above already uses --
    # rather than an unlocked read-decode-mutate-rename. Without a lock,
    # `bp-answer-escalation.pl`/`bp-resolve.pl` archiving a record and unlinking
    # its queue file, interleaved with this sweep's decode-then-rename, could
    # RESURRECT an already-answered decision (its own header states a deleted
    # id with no archive entry IS the record that a human answered it -- a
    # queue file reappearing after that breaks the model outright). This also
    # closes H3 as a side effect: `guarded_write`'s commit is a bare `rename`
    # with NO pre-unlink of the destination (spec edge case 13; verified
    # against bp-write-guard.pl's own `$RENAME_FN`), so the destination is
    # never deleted before a successful rename -- a failed rename leaves the
    # ORIGINAL record intact rather than gone.
    if (!$skip_new_repairs) {
        my $esc_dir = "$runs/escalations";
        if (-d $esc_dir) {
            my @withdrawn;   # [ { f, kind, reason }, ... ]
            if (opendir(my $edh, $esc_dir)) {
                for my $f (sort readdir $edh) {
                    next unless $f =~ /\.json\z/;
                    my $path = "$esc_dir/$f";
                    next unless -f $path;
                    # LOW L1: bounded read (cap+1), never a full slurp of an
                    # oversized/hostile file just to reject it a moment later.
                    my $c = slurp_capped($path, 1_000_000);
                    next unless defined $c && length $c && length($c) <= 1_000_000;
                    require JSON::PP;
                    my $rec = eval { JSON::PP->new->decode($c) };
                    next if $@ || ref $rec ne 'HASH';
                    # LOW L4: align with the documented reader contract (spec
                    # §7's "known gap" note) -- withdrawn iff a non-empty,
                    # non-ref scalar, not merely `exists`. A record already
                    # carrying `"withdrawn_at": null` should not be
                    # permanently unwithdrawable while every reader still
                    # counts it live.
                    next if defined $rec->{withdrawn_at} && !ref($rec->{withdrawn_at}) && length($rec->{withdrawn_at});
                    my $kind = $rec->{kind};
                    my $spec = defined $kind ? $SELF_WITHDRAWABLE{$kind} : undef;
                    next unless $spec;
                    my $pkg = $rec->{package};
                    next unless safe_pkg_name($pkg);
                    # LOW L3: a record filed under a DIFFERENT blueprint than
                    # this one must not have its premise judged against this
                    # blueprint's packages/ tree. Not currently reachable (the
                    # orchestrator only ever files into its own runs/), but
                    # the record is declared attacker-adjacent input.
                    next if defined $rec->{blueprint} && !ref($rec->{blueprint}) && length($rec->{blueprint})
                            && $rec->{blueprint} ne $name;
                    next if $spec->{premise_holds}->($bpdir, $pkg);

                    if ($opt->{dry_run}) {
                        push @withdrawn, { f => $f, kind => $kind, reason => $spec->{reason} };
                        next;
                    }

                    my $reason = $spec->{reason};
                    my $res = BpWrite::guarded_write({
                        site  => 'reconcile_escalation_withdrawn',
                        path  => $path,
                        valid => sub {
                            my ($txt) = @_;
                            # M4: the re-read under the lock -- if the record
                            # is gone (archived + unlinked by an answer path
                            # that raced us), there is nothing to withdraw,
                            # and writing a fresh file back here would
                            # resurrect it. Refuse rather than recreate it.
                            return 'record gone' unless defined $txt;
                            my $cur = eval { JSON::PP->new->decode($txt) };
                            return 'record unreadable' if $@ || ref $cur ne 'HASH';
                            return 'already withdrawn'
                                if defined $cur->{withdrawn_at} && !ref($cur->{withdrawn_at}) && length($cur->{withdrawn_at});
                            return undef;
                        },
                        mutate => sub {
                            my ($txt) = @_;
                            my $cur = eval { JSON::PP->new->decode($txt) };
                            return (undef, 'record unreadable') if $@ || ref $cur ne 'HASH';
                            $cur->{withdrawn_at}     = iso_now();
                            $cur->{withdrawn_reason} = $reason;
                            my $json = eval { JSON::PP->new->canonical->pretty->encode($cur) };
                            return (undef, 'encode failed') if $@ || !defined $json;
                            return ($json, undef);
                        },
                    });
                    if ($res->{ok} && ($res->{outcome} eq 'written' || $res->{outcome} eq 'unchanged')) {
                        push @withdrawn, { f => $f, kind => $kind, reason => $reason };
                    }
                    elsif (!$res->{ok} && $res->{outcome} eq 'refused') {
                        # the world moved under us; skip silently, not an error.
                        next;
                    }
                    else {
                        push @{ $r{errors} },
                            "could not withdraw escalation $f: $res->{outcome}: $res->{reason}";
                    }
                }
                closedir $edh;
            }
            if (@withdrawn) {
                @withdrawn = sort { $a->{f} cmp $b->{f} } @withdrawn;
                my @basenames = map { $_->{f} } @withdrawn;
                # LOW L7 / review SHOULD-FIX 2: render each entry
                # "<file> (<kind>: <reason>)", matching spec §2.6's worked
                # example shape and the orphan_running block's own precedent
                # for rendering distinguishable shapes in `detail`.
                my @rendered = map { "$_->{f} ($_->{kind}: $_->{reason})" } @withdrawn;
                my $detail = ($opt->{dry_run} ? 'would withdraw ' : 'withdrew ')
                           . scalar(@basenames) . ' escalation(s): ' . join(', ', @rendered);
                push @{ $r{actions} }, {
                    kind    => 'escalation_withdrawn',
                    detail  => $detail,
                    records => \@basenames,
                    applied => $opt->{dry_run} ? 0 : 1,
                };
            }
        }
    }

    # --- lifecycle (report-only; nothing is ever written here) -------------
    my $all_delivered = (@ledgers > 0) && !grep { !$DELIVERED{ $_->{status} } } @ledgers;
    $r{all_delivered} = $all_delivered ? 1 : 0;

    # --- 2b. THE SILENT STUCK STATE -------------------------------------------
    #
    # t10-run-continuity-gaps, closing almanac report 20260819-145104-4651.
    #
    # A blueprint every one of whose packages is delivered, but whose authored
    # status never left `drafting`, can never be archived by the normal path --
    # and reconcile said NOTHING about it. It exited 0, reported
    # all_delivered:1, returned an EMPTY action list, and looked exactly like
    # success. That is the expensive half: a future reader sees a finished
    # initiative still listed as live and has no way to know why.
    #
    # `drafting` means "not yet audited". The audit gate belongs to the
    # authoring flow (/blueprint:create runs bp-auditor); a MANUAL drive drives
    # packages, ticks steps and commits, but nothing in that path records an
    # audit or advances this field. So a manually-driven initiative completes
    # perfectly and sits unarchivable forever.
    #
    # WHAT THIS DOES NOT DO, and it is the whole reason the fix is a diagnostic
    # rather than a state change: it does not write `audited`. Backdating an
    # audit that never happened is worse than the bug -- the gate exists
    # precisely so nobody can claim one. Done-criterion 3 forbids it outright.
    # It also does not quietly widen the archive condition, which would drop
    # the gate's meaning for every blueprint rather than just this one.
    #
    # It ends the silence, which is the part that actually costs a reader, and
    # leaves the policy question where it belongs -- with a human who can
    # answer it.
    if ($all_delivered && $lifecycle ne 'archived' && (defined $bp_status ? $bp_status : '') eq 'drafting') {
        push @{ $r{actions} }, {
            kind    => 'blocked',
            reason  => 'never-audited',
            applied => 0,
            detail  => "every package is delivered but blueprint.md still says status: drafting, "
                     . "so this can never be archived. `drafting` means NOT YET AUDITED, and a "
                     . "manual drive never advances that field. Nothing here will write `audited` "
                     . "for you: that would backdate an audit that did not happen. Either run the "
                     . "audit the authoring flow performs, or record explicitly how this "
                     . "initiative was actually driven.",
        };
        $r{blocked} = 'never-audited';
    }

    # --- 3. archive -----------------------------------------------------------
    if ($opt->{archive} && $lifecycle eq 'done' && !@{ $r{errors} }) {
        my $blueprints = $bpdir;
        $blueprints =~ s{[\\/][^\\/]+\z}{};
        my $dst = "$blueprints/_archive/$name";
        if (-e $dst) {
            push @{ $r{errors} }, "refusing to archive: $dst already exists";
        } elsif ($opt->{dry_run}) {
            push @{ $r{actions} }, { kind => 'archive', detail => "would archive to _archive/$name", applied => 0 };
        } else {
            make_path("$blueprints/_archive") unless -d "$blueprints/_archive";
            # Flip the recorded status BEFORE moving: a directory that lands in
            # _archive/ still saying the derived word is a blueprint whose own
            # file contradicts where it lives, and that is the class of drift
            # this whole script exists to remove.
            bp_call('set-meta', '--file', $bpmd, '--field', 'status', '--value', 'archived');
            bp_call('set-meta', '--file', $bpmd, '--field', 'last_updated', '--value', iso_now());
            my ($ok, $how) = move_dir($bpdir, $dst);
            if ($ok) {
                push @{ $r{actions} }, { kind => 'archive', detail => "archived to _archive/$name ($how)", applied => 1 };
                $r{status_after} = 'archived';
                $r{lifecycle}    = 'archived';
                $r{dir} = $dst;
            } else {
                # Roll back the write above -- but NEVER to a literal 'done'
                # (DC3 forbids it, and op_set_meta now REJECTS it outright).
                # The prior authored word that made blueprint_lifecycle derive
                # 'done' was one of 'audited', 'running' or 'done' itself
                # (BpState::blueprint_lifecycle's all-delivered advance gate,
                # fixed in the s04 fix-batch step 7, F1, to include all
                # three); 'running' and 'done' are both hard refusals for
                # set-meta now, so "restore exactly what was there" cannot be
                # satisfied for all of them. 'audited' is always legal and
                # always an honest description of "human-approved, not yet
                # filed away, still all-delivered" regardless of which prior
                # word it replaces (spec §5.1).
                bp_call('set-meta', '--file', $bpmd, '--field', 'status', '--value', 'audited');
                # This reconcile's own writes end here, at 'audited' -- not at
                # whatever $lifecycle/$authored were on entry (possibly
                # 'running' or 'done'). status_after must reflect the LITERAL
                # field on disk after this reconcile (spec §2.6), and the
                # line above is the last thing this reconcile wrote to it.
                # Found in the s04 fix-batch step 7 review (F3): without this
                # line status_after stayed at the pre-run authored word,
                # silently lying about what the failed rollback actually
                # wrote.
                $r{status_after} = 'audited';
                push @{ $r{errors} }, "archive failed: $how";
            }
        }
    }

    return \%r;
}

# blueprint.md's own metadata is NOT `---` frontmatter — it is the fenced ```
# block near the top, a different shape from a package ledger's. Reading it with
# fm_get silently returns undef, which would make every blueprint look like it
# had no lifecycle status at all and quietly disable the advance. Matched the
# same way bp-blueprint.pl's set-meta writes it, so reader and writer cannot
# disagree about which line is authoritative.
sub bp_meta_get {
    my ($file, $field) = @_;
    my $c = slurp($file);
    return undef unless defined $c;
    my $f = quotemeta $field;
    return undef unless $c =~ /^```\s*\n((?:.*\n)*?)^```\s*$/m;
    my $block = $1;
    return undef unless $block =~ /^$f:[ \t]*([^\n#]*)/m;
    my $v = $1;
    $v =~ s/\s+\z//;
    return $v;
}

# Blueprint lifecycle values are a different vocabulary from package statuses,
# so they get their own normaliser rather than sharing norm_status (which would
# happily turn "archived" into '').
sub norm_bp_status {
    my ($s) = @_;
    return '' unless defined $s;
    $s = lc $s;
    $s =~ s/#.*\z//;                       # the template keeps a trailing comment
    $s =~ s/[^a-z]+/ /g;
    for my $w (split /\s+/, $s) {
        return $w if $w =~ /\A(?:drafting|audited|parked|running|done|archived)\z/;
    }
    return '';
}

sub iso_now {
    my @t = gmtime(time);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ',
                   $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

# ------------------------------------------------------------------ report ---

sub print_report {
    my ($results) = @_;
    for my $r (@$results) {
        my @acts = @{ $r->{actions} || [] };
        my @errs = @{ $r->{errors}  || [] };
        next unless @acts || @errs;
        print "== $r->{blueprint}\n";
        for my $a (@acts) {
            printf "   %-15s %s\n", $a->{kind}, $a->{detail};
        }
        for my $e (@errs) {
            printf "   %-15s %s\n", 'ERROR', $e;
        }
    }
}

# -------------------------------------------------------------------- main ---

unless (caller) {
# Native Windows binaries (git.exe, and anything bp-blueprint.pl shells to) get
# argv path-mangled by MSYS otherwise; see the project CLAUDE.md. We hand back
# only already-native or already-relative paths, so opting out is safe here.
$ENV{MSYS2_ARG_CONV_EXCL} = '*' if $^O =~ /^(MSWin32|cygwin|msys)$/;

my @argv = @ARGV;
my $verb = shift @argv;
die_usage('missing subcommand; expected: reconcile') unless defined $verb;
die_usage("unknown subcommand '$verb'; expected: reconcile") unless $verb eq 'reconcile';

my %opt = (archive => 1);
my $ok;
my $getopt_warning;
{
    # no_auto_abbrev (Decision 7 / spec §2.6): only the exact defined long
    # names are accepted -- `--data`, `--blue`, `--dry` are now rejected
    # rather than silently matched as abbreviations of a longer option.
    Getopt::Long::Configure(qw(no_auto_abbrev));
    local $SIG{__WARN__} = sub { $getopt_warning = $_[0] unless defined $getopt_warning; };
    $ok = GetOptionsFromArray(\@argv, \%opt,
        'blueprint=s', 'all', 'data-dir=s', 'archive!', 'dry-run', 'json', 'quiet');
}
unless ($ok) {
    my $msg = defined $getopt_warning ? $getopt_warning : 'unrecognised option';
    $msg =~ s/\s+\z//;
    die_usage($msg);
}
die_usage('unexpected extra arguments: ' . join(' ', @argv)) if @argv;
die_usage('need exactly one of --blueprint or --all')
    if (defined $opt{blueprint} ? 1 : 0) + ($opt{all} ? 1 : 0) != 1;
$opt{dry_run} = delete $opt{'dry-run'};

my $DATA  = data_dir($opt{'data-dir'});
$opt{data_root} = $DATA;
my $ROOT  = "$DATA/blueprints";

my @dirs;
if ($opt{all}) {
    opendir(my $dh, $ROOT) or do {
        print STDERR "bp-lifecycle: cannot read $ROOT: $!\n";
        exit 2;
    };
    for my $e (sort readdir $dh) {
        next if $e eq '.' || $e eq '..' || $e eq '_archive';
        next unless -d "$ROOT/$e";
        next unless -f "$ROOT/$e/blueprint.md";      # strays are bp-status.sh's to report
        push @dirs, "$ROOT/$e";
    }
    closedir $dh;
}
else {
    my $b = $opt{blueprint};
    # Accept a name or a path, so callers that already hold a directory don't
    # have to reverse it into a name and re-resolve the data dir.
    my $dir = ($b =~ m{[\\/]} && -d $b) ? $b : "$ROOT/$b";
    unless (-d $dir) {
        print STDERR "bp-lifecycle: no blueprint '$b' under $ROOT\n";
        exit 2;
    }
    push @dirs, $dir;
}

my @results = map { reconcile_one($_, \%opt) } @dirs;

if ($opt{json}) {
    require JSON::PP;
    print JSON::PP->new->canonical->pretty->encode(\@results);
}
elsif (!$opt{quiet}) {
    print_report(\@results);
}

exit(( grep { @{ $_->{errors} || [] } } @results ) ? 2 : 0);
}

1;
