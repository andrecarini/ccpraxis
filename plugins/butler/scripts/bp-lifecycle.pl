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
#   3. archives the blueprint (moves it into `blueprints/_archive/`) once its
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
# Exit status: 0 on success (including "nothing to do"), 1 on a usage error,
# 2 if any blueprint could not be reconciled.

use strict;
use warnings;
use Getopt::Long qw(GetOptionsFromArray);
use File::Path qw(make_path remove_tree);
use File::Copy qw(copy);
use File::Spec;

# Native Windows binaries (git.exe, and anything bp-blueprint.pl shells to) get
# argv path-mangled by MSYS otherwise; see the project CLAUDE.md. We hand back
# only already-native or already-relative paths, so opting out is safe here.
$ENV{MSYS2_ARG_CONV_EXCL} = '*' if $^O =~ /^(MSWin32|cygwin|msys)$/;

my $SCRIPT_DIR = do {
    my $p = $0;
    $p =~ s{[\\/][^\\/]+\z}{};
    $p = '.' unless length $p;
    # ABSOLUTE, and that is load-bearing rather than tidy. `require` with a
    # RELATIVE path searches @INC instead of resolving against cwd, and modern
    # perl (5.26+) no longer carries '.' in @INC -- so the require below died
    # with "Can't locate plugins/butler/scripts/BpState.pm in @INC" whenever
    # this script was invoked by a relative path, i.e. the normal way a human
    # or a hook types it from the repo root. It worked only when invoked
    # absolutely, which is exactly how every oracle invokes it, which is why no
    # test caught it: t/97-lifecycle-reconcile.t, t/161-lifecycle-derived.t
    # and t/153-no-drift-to-repair.t all build $LIFECYCLE from abs_path.
    # Introduced by s04 (de81269) when BpState was wired in; found when the
    # driver ran the script by hand to archive a finished blueprint.
    File::Spec->rel2abs($p);
};
my $BP_BLUEPRINT = "$SCRIPT_DIR/bp-blueprint.pl";

require "$SCRIPT_DIR/BpState.pm";

# ---------------------------------------------------------------- statuses ---
# The six package statuses bp-blueprint.pl recognises. `dropped` is accepted as
# terminal-but-not-delivered because bp-drive-next.pl emits it.
my %TERMINAL   = map { $_ => 1 } qw(done dropped blocked parked);
my %DELIVERED  = map { $_ => 1 } qw(done dropped);

sub die_usage {
    my ($msg) = @_;
    print STDERR "bp-lifecycle: $msg\n" if defined $msg;
    print STDERR <<'USAGE';
usage: bp-lifecycle.pl reconcile (--blueprint <name|dir> | --all)
                                 [--data-dir DIR] [--archive|--no-archive]
                                 [--dry-run] [--json] [--quiet]
USAGE
    exit 1;
}

# ------------------------------------------------------------------ roots ----

sub project_root {
    return $ENV{BP_PROJECT_ROOT} if defined $ENV{BP_PROJECT_ROOT} && length $ENV{BP_PROJECT_ROOT};
    my $top = `git rev-parse --show-toplevel 2>/dev/null`;
    if (defined $top) { chomp $top; return $top if length $top && -d $top; }
    # Walk up looking for the data dir, mirroring bp_project_root in bp-lib.sh.
    require Cwd;
    my $d = Cwd::getcwd();
    while (defined $d && length $d) {
        return $d if -d "$d/.ccpraxis-local-data";
        my $up = File::Spec->catdir($d, File::Spec->updir());
        $up = Cwd::abs_path($up) // '';
        last if !length $up || $up eq $d;
        $d = $up;
    }
    return Cwd::getcwd();
}

sub data_dir {
    my ($override) = @_;
    return $override if defined $override && length $override;
    return $ENV{CCPRAXIS_DATA_DIR} if defined $ENV{CCPRAXIS_DATA_DIR} && length $ENV{CCPRAXIS_DATA_DIR};
    return project_root() . '/.ccpraxis-local-data';
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
    my $c = slurp($path);
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

# Move $src to $dst. rename() is the fast path; when it fails we fall back to a
# pure-perl copy + remove.
#
# The fallback is not theoretical. Moving a real blueprint directory on this
# Windows host failed with EBUSY from MSYS `mv` on every attempt while a native
# move of the same directory succeeded immediately — a background handle (search
# indexer / AV) on one of ~500 files is enough. Losing an archive to that would
# be far worse than copying a few megabytes, so we degrade instead of failing,
# and we only remove the source once the copy is verified to exist.
sub move_dir {
    my ($src, $dst) = @_;
    return (1, 'rename') if rename $src, $dst;
    my $rename_err = "$!";

    # Copy the tree, then drop the source.
    my $copied = eval { _copy_tree($src, $dst); 1 };
    if (!$copied) {
        remove_tree($dst) if -d $dst;      # never leave a half-copy behind
        return (0, "rename failed ($rename_err) and copy failed ($@)");
    }
    unless (-d $dst) {
        return (0, "rename failed ($rename_err) and the copy produced no destination");
    }
    my $removed = eval { remove_tree($src); 1 };
    if (!$removed || -d $src) {
        # The copy is good; the source lingers. Say so plainly rather than
        # reporting success — a duplicated blueprint would be listed twice.
        return (0, "copied to $dst but could not remove the original $src"
                 . " (rename had failed: $rename_err)");
    }
    return (1, 'copy+remove');
}

sub _copy_tree {
    my ($src, $dst) = @_;
    make_path($dst) unless -d $dst;
    opendir(my $dh, $src) or die "opendir $src: $!\n";
    my @entries = grep { $_ ne '.' && $_ ne '..' } readdir $dh;
    closedir $dh;
    for my $e (@entries) {
        my ($s, $d) = ("$src/$e", "$dst/$e");
        if (-d $s && !-l $s) { _copy_tree($s, $d) }
        else { copy($s, $d) or die "copy $s -> $d: $!\n" }
    }
    return 1;
}

# --------------------------------------------------------------- reconcile ---

sub reconcile_one {
    my ($bpdir, $opt) = @_;
    my $name = $bpdir;
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
    my $live   = (-e $marker && pid_alive($pid)) ? 1 : 0;
    $r{live} = $live;
    $r{orchestrator_pid} = $pid;

    my $lifecycle = BpState::blueprint_lifecycle($bpdir, \&pid_alive);
    $r{lifecycle} = $lifecycle;

    if ($live) {
        push @{ $r{actions} }, { kind => 'skipped', detail => "orchestrator pid $pid is alive; state belongs to the run" };
        return \%r;
    }

    # --- 1. stale marker ----------------------------------------------------
    if (-e $marker) {
        my $why = defined $pid ? "pid $pid is not alive" : 'marker holds no usable pid';
        if ($opt->{dry_run}) {
            push @{ $r{actions} }, { kind => 'stale_marker', detail => "would remove runs/.orchestrator ($why)", applied => 0 };
        } elsif (unlink $marker) {
            push @{ $r{actions} }, { kind => 'stale_marker', detail => "removed runs/.orchestrator ($why)", applied => 1 };
        } else {
            push @{ $r{errors} }, "could not remove stale marker $marker: $!";
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
    my $regpath = "$runs/registry.json";
    if (-f $regpath) {
        my $reg = read_registry($regpath);
        if (!defined $reg) {
            push @{ $r{errors} }, 'runs/registry.json is unreadable or not JSON; left untouched';
        } elsif (ref($reg->{packages}) eq 'HASH') {
            my @cleared;
            my %by_pkg = map { $_->{pkg} => $_->{status} } @ledgers;
            for my $pkg (sort keys %{ $reg->{packages} }) {
                my $entry = $reg->{packages}{$pkg};
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
                } elsif (write_registry($regpath, $reg)) {
                    push @{ $r{actions} }, { kind => 'stale_pid', detail => "cleared $detail", applied => 1 };
                } else {
                    push @{ $r{errors} }, 'could not write runs/registry.json';
                }
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
        return $w if $w =~ /\A(?:drafting|audited|running|done|archived)\z/;
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

my @argv = @ARGV;
my $verb = shift @argv;
die_usage('missing subcommand; expected: reconcile') unless defined $verb;
die_usage("unknown subcommand '$verb'; expected: reconcile") unless $verb eq 'reconcile';

my %opt = (archive => 1);
my $ok;
{
    local $SIG{__WARN__} = sub { };
    $ok = GetOptionsFromArray(\@argv, \%opt,
        'blueprint=s', 'all', 'data-dir=s', 'archive!', 'dry-run', 'json', 'quiet');
}
die_usage('unrecognised option') unless $ok;
die_usage('unexpected extra arguments: ' . join(' ', @argv)) if @argv;
die_usage('need exactly one of --blueprint or --all')
    if (defined $opt{blueprint} ? 1 : 0) + ($opt{all} ? 1 : 0) != 1;
$opt{dry_run} = delete $opt{'dry-run'};

my $DATA  = data_dir($opt{'data-dir'});
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
