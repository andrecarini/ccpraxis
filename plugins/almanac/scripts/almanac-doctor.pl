#!/usr/bin/env perl
# almanac-doctor.pl -- a read-only diagnostic across every almanac store
# (blueprint almanac-records, package 17-doctor-and-cli). See
# specs/17-doctor-and-cli-spec.md section 2.2.
#
# THE READ-ONLY GUARANTEE (S2.2.1): for the whole of scan(), the store's own
# scope-writability table is localized so every cell reports not-writable.
# Almanac::Store::list() skips its own recovery step whenever a store is not
# writable, so nothing this file requires (Almanac::Note::check_pointers,
# Almanac::Task::check_refs) can write a record, a journal or a store lock.
# The only files this script may create or modify are the lock sidecars its
# own non-blocking probe touches, exactly as almanac-bug.pl's own verify does.
#
# THIS FILE NEVER LOADS OR CALLS Almanac::Inbox, AND NEVER MIGRATES AN
# UNMIGRATED LEGACY STORE: every inbox read path in that module absorbs the
# legacy question queue and renames an old unmigrated store directory as a
# side effect, either of which would turn a diagnostic into a write. A
# legacy queue is reported (finding class LEGACY-QUEUE) but never read,
# renamed or absorbed here -- its path comes from
# Almanac::LegacyQueue::legacy_path, so this file never spells the file name
# itself.
package Almanac::Doctor;
use strict;
use warnings;
use Fcntl qw(LOCK_EX LOCK_NB LOCK_UN);
use Errno ();
use Encode ();
use Sys::Hostname ();
use Cwd ();

my ($DIR, $NOTE_PL, $BUG_PL);
# __FILE__ is resolved through Cwd::abs_path first -- a relative __FILE__
# (true of any relative CLI invocation) would otherwise leave $DIR relative
# too, and @INC's own path-join logic then doubles the directory onto the
# require paths below (bug 20261001-184636-75fe): "Can't locate
# plugins/almanac/scripts/almanac-note.pl in @INC".
BEGIN {
    $DIR = do { (my $f = __FILE__) =~ s{\\}{/}g; Cwd::abs_path($f) // $f };
    $DIR =~ s{\\}{/}g;
    # A bare filename (no '/' at all) has nothing for s{/[^/]+\z}{} to match,
    # which would otherwise leave $DIR equal to the script's own name.
    $DIR = ($DIR =~ m{/}) ? ($DIR =~ s{/[^/]+\z}{}r) : '.';
    $NOTE_PL = "$DIR/almanac-note.pl";
    $BUG_PL  = "$DIR/almanac-bug.pl";
    unshift @INC, $DIR;
}

# `require` of an absolute sibling path, at compile time, so each script's
# own `unless (caller)` CLI main never fires here (require always runs with
# a caller frame) -- the same idiom almanac-inbox.pl uses for
# almanac-note.pl. OVERRIDDEN by blueprint where-things-go, package
# 02-thread-store (specs/02-thread-store-spec.md section 2.8): the flat
# almanac-task.pl require is gone; Almanac::Thread (by module name) replaces
# Almanac::Task::check_refs and adds check_health.
require $NOTE_PL;
require $BUG_PL;

use Almanac::Store ();
use Almanac::Record ();
use Almanac::Lock ();
use Almanac::LegacyQueue ();
use Almanac::Thread ();
use Almanac::SessionLive ();

our $VERSION = '1.0';

# _decode_maybe($s) -> decoded characters, once. The same idiom
# almanac-note.pl/almanac-task.pl already use for a path built from Cwd
# bytes: decode-once so a path is never re-encoded on its way to a
# ':encoding(UTF-8)' STDOUT.
sub _decode_maybe {
    my ($s) = @_;
    return $s unless defined $s;
    return $s if utf8::is_utf8($s);
    my $d = eval { Encode::decode('UTF-8', $s, Encode::FB_CROAK()) };
    return defined $d ? $d : $s;
}

# _holder_full($holder) -> "pid P on host H (script S, recorded AT)", or "an
# unknown holder" when read_holder returned undef.
sub _holder_full {
    my ($h) = @_;
    return 'an unknown holder' unless ref $h eq 'HASH';
    my $pid    = defined $h->{pid}         ? $h->{pid}         : '?';
    my $host   = defined $h->{host}        ? _decode_maybe($h->{host})   : '?';
    my $script = defined $h->{script}      ? _decode_maybe($h->{script}) : '?';
    my $at     = defined $h->{acquired_at} ? $h->{acquired_at} : '?';
    return "pid $pid on host $host (script $script, recorded $at)";
}

# _scope_unavailable_reasons() -> a set of every reason value the store's own
# capability table names for a not-readable cell, plus the code fallback
# 'unknown_policy' scope_capability uses when a surface has no policy row at
# all. A finding whose reason lands in this set is a designed skip (a vault
# not mounted here), never a real check failure -- see F7's table entry.
sub _scope_unavailable_reasons {
    my %out;
    for my $surf (keys %Almanac::Store::SCOPE_POLICY) {
        for my $sc (keys %{ $Almanac::Store::SCOPE_POLICY{$surf} }) {
            my $pol = $Almanac::Store::SCOPE_POLICY{$surf}{$sc};
            $out{ $pol->{reason} } = 1 if !$pol->{readable} && defined $pol->{reason};
        }
    }
    $out{unknown_policy} = 1;
    return \%out;
}

sub _is_scope_unavailable_reason {
    my ($reason) = @_;
    return 0 unless defined $reason;
    my $set = _scope_unavailable_reasons();
    return $set->{$reason} ? 1 : 0;
}

# _listable_repair($type, $scope, $root) -> the F6 repair text: a listing
# verb for the record types that have one in that scope, else the
# manual-step text (Decision 37(1)). todo/note list in either scope; inbox
# and thread are project-only stores, so a global inbox/thread type dir
# (found only by shape) gets the manual step too -- `almanac inbox list
# --global` is not a flag that verb accepts. OVERRIDDEN by blueprint
# where-things-go, package 02-thread-store (specs/02-thread-store-spec.md
# section 2.8 item 5): `task` (the retired flat tasklist) no longer has a
# listing verb; `thread` lists in project scope; a type matching
# thread-(?:tasks|log)-<name> repairs with `almanac thread show <name>`.
sub _listable_repair {
    my ($type, $scope, $root) = @_;
    if ($type =~ /\Athread-(?:tasks|log)-(.+)\z/) {
        my $name = $1;
        return "no almanac verb lists store type '$type'" unless $scope eq 'project';
        return qq(almanac thread show $name --root "@{[ _decode_maybe($root) ]}");
    }
    my %listable_either  = (todo => 1, note => 1);
    my %listable_project = (inbox => 1, thread => 1);
    my $listable = $listable_either{$type}
                || ($listable_project{$type} && $scope eq 'project');
    return "no almanac verb lists store type '$type'" unless $listable;
    my $flag = ($scope eq 'global') ? '--global' : qq(--root "@{[ _decode_maybe($root) ]}");
    return "almanac $type list $flag";
}

# _store_dir_for($type, $scope, $root) -> the type's on-disk directory under
# that scope's almanac root, for F7's path field.
sub _store_dir_for {
    my ($type, $scope, $root) = @_;
    if ($scope eq 'global') {
        my $cap = Almanac::Store::scope_capability('global');
        return $cap->{readable} ? "$cap->{root}/$type" : '';
    }
    my $cap = Almanac::Store::scope_capability('project', root => $root);
    return "$cap->{root}/$type";
}

# _scan_type_dir($scope, $type, $dir, $root, \@findings, \@stderr_lines) --
# parse, seal and reorder-journal checks over one store's type directory
# (F1, F2, F3, F6). Every finding field pushed here is DECODED CHARACTERS,
# never raw bytes -- $path/$dir/$sealpath/$root all arrive as raw bytes from
# Cwd/readdir, and are run through _decode_maybe (idempotent on an
# already-decoded string) at the point they are interpolated, so two
# already-decoded pieces are never concatenated with a raw one (that
# concatenation is what upgrades the raw bytes as Latin-1 and produces
# mojibake -- see the M1 fix-batch item).
sub _scan_type_dir {
    my ($scope, $type, $dir, $root, $findings, $stderr_lines) = @_;

    for my $path (Almanac::Store::record_files_in($dir)) {
        my ($id) = $path =~ m{([^/]+)\.md\z};
        $id = defined $id ? $id : '-';
        my $path_c = _decode_maybe($path);

        my $problems = Almanac::Record::check_file($path);
        if (@$problems) {
            for my $prob (@$problems) {
                push @$findings, {
                    class  => 'UNPARSEABLE', num => 1, scope => $scope, type => $type, id => $id,
                    path   => $path_c, line => $prob->{line},
                    detail => "line $prob->{line}: $prob->{kind}",
                    repair => 'restore it from the vault history; no almanac verb writes a record that does not parse',
                };
            }
            next;
        }

        my $seal  = Almanac::Store::check_seal($path);
        my $state = $seal->{state};

        if ($state eq 'tampered' || $state eq 'unreadable') {
            my ($lock, $err) = Almanac::Lock->acquire($path, verb => 'doctor', timeout_ms => 2000);
            if ($lock) {
                $seal  = Almanac::Store::check_seal($path);
                $state = $seal->{state};
                $lock->release;
            } elsif (ref $err eq 'HASH' && $err->{kind} eq 'timeout') {
                my $holder = $err->{holder};
                my $waited = $err->{waited_ms} // 0;
                push @$findings, {
                    class  => 'UNVERIFIED', num => 3, scope => $scope, type => $type, id => $id,
                    path   => $path_c, line => undef,
                    detail => 'record lock held by ' . _holder_full($holder) . "; waited ${waited}ms",
                    repair => 're-run almanac doctor when the holder has finished',
                };
                next;
            } else {
                # A non-timeout lock failure (e.g. a read-only mounted vault,
                # Decision 7's amendment path): S3 -- never claim "held by an
                # unknown holder" for this, since the repair "wait for the
                # holder" could never succeed. Keep the unlocked check_seal
                # state already in $seal/$state and fall through to it below.
                my $errno = (ref $err eq 'HASH' && defined $err->{errno}) ? $err->{errno} : 'unknown error';
                push @$stderr_lines, "almanac doctor: note: could not lock $path for re-check: $errno";
            }
            # A record still unreadable after the locked re-check (or after a
            # non-timeout lock failure): gone means a concurrent, sanctioned
            # delete (skip, uncounted); present means the earlier check_file
            # already found no problem, so nothing further is emitted here.
            next if $state eq 'unreadable';
        }

        if ($state eq 'tampered') {
            push @$findings, {
                class  => 'TAMPERED', num => 2, scope => $scope, type => $type, id => $id,
                path   => $path_c, line => undef,
                detail => "digest $seal->{digest} matches no sealed digest",
                repair => 'restore it from the vault history, or accept it by re-saving through its own almanac verb',
            };
        } elsif ($state eq 'bad_seal') {
            my $sealpath = _decode_maybe(Almanac::Store::seal_path_for($path));
            push @$findings, {
                class  => 'TAMPERED', num => 2, scope => $scope, type => $type, id => $id,
                path   => $path_c, line => undef,
                detail => "seal $sealpath is not one or two sha256 lines",
                repair => 'restore it from the vault history, or accept it by re-saving through its own almanac verb',
            };
        }
    }

    # S2: the journal file name is Store's own private knowledge, not
    # re-spelled here -- a rename of _journal_path breaks doctor loudly at
    # load time (spec S5.1(3)) instead of leaving F6 silently stale. Calling
    # the private accessor is the sanctioned choice the spec review names.
    my $journal_store = eval {
        ($scope eq 'global')
            ? Almanac::Store->open(scope => 'global', type => $type)
            : Almanac::Store->open(scope => 'project', type => $type, root => $root);
    };
    my $journal_path = $journal_store ? $journal_store->_journal_path : "$dir/.reorder-journal.json";
    if (-e $journal_path) {
        push @$findings, {
            class  => 'INTERRUPTED-REORDER', num => 6, scope => $scope, type => $type, id => '-',
            path   => _decode_maybe($journal_path), line => undef,
            detail => 'an abandoned reorder journal is present',
            repair => _listable_repair($type, $scope, $root),
        };
    }
}

# _scan_locks_in_dir($dir, $scope, $type, \@findings, \@stderr_lines) -- the
# whole of S2.2.5's probe: never waits, never writes bytes (the lock file is
# opened '>>', never truncating). A held lock whose recorded holder names
# this host and a now-dead pid is F8; any other held lock is a stderr note
# only, never a finding (S5's "held by a live holder is normal operation").
sub _scan_locks_in_dir {
    my ($dir, $scope, $type, $findings, $stderr_lines) = @_;
    return unless -d $dir;
    opendir(my $dh, $dir) or return;
    my @entries = sort readdir($dh);
    closedir $dh;

    my $this_host = Sys::Hostname::hostname();

    for my $e (@entries) {
        next unless $e =~ /\.lock\z/;
        my $lockpath = "$dir/$e";
        next unless -f $lockpath;

        my $fh;
        unless (open($fh, '>>', $lockpath)) {
            push @$stderr_lines, "almanac doctor: note: could not probe $lockpath: $!";
            next;
        }
        if (flock($fh, LOCK_EX | LOCK_NB)) {
            flock($fh, LOCK_UN);
            close($fh);
            next;
        }
        close($fh);

        (my $target = $lockpath) =~ s/\.lock\z//;
        my $holder = Almanac::Lock::read_holder($target);

        my $id;
        if ($e =~ /\.md\.lock\z/) { ($id = $e) =~ s/\.md\.lock\z//; }
        else                      { ($id = $e) =~ s/\.lock\z//; }

        my $gone = 0;
        if (ref $holder eq 'HASH' && defined $holder->{host} && $holder->{host} eq $this_host
            && defined $holder->{pid} && $holder->{pid} =~ /\A\d+\z/) {
            local $! = 0;
            my $alive = kill(0, $holder->{pid});
            $gone = 1 if !$alive && $! == Errno::ESRCH();
        }

        if ($gone) {
            my $lockpath_c = _decode_maybe($lockpath);
            my $script_c   = _decode_maybe($holder->{script});
            push @$findings, {
                class  => 'LOCK-HOLDER-GONE', num => 8, scope => $scope, type => $type, id => $id,
                path   => $lockpath_c, line => undef,
                detail => "lock held but its recorded holder pid $holder->{pid} "
                        . "(script $script_c, recorded $holder->{acquired_at}) is gone",
                repair => "end the process holding $lockpath_c open; never delete a lock file",
            };
        } else {
            push @$stderr_lines,
                "almanac doctor: note: LOCK-HELD $scope $type/$id: held by " . _holder_full($holder) . " -- $lockpath";
        }
    }
}

# _process_check_entry(...) -- shared by the note-pointer and task-ref
# checks: emits DANGLING-POINTER/DANGLING-REF per dangling entry when the
# underlying check is available, else CHECK-FAILED unless the reason is
# 'malformed' (F1 already names that file) or a designed scope-unavailable
# skip.
sub _process_check_entry {
    my ($findings, $type, $scope, $root, $entry, $funcname, $class, $num) = @_;
    return unless ref $entry eq 'HASH';

    my $root_c = _decode_maybe($root);

    if ($entry->{available}) {
        for my $d (@{ $entry->{dangling} || [] }) {
            if ($type eq 'note') {
                my $t = defined $d->{target} ? $d->{target} : '-';
                my $repair = ($scope eq 'global')
                    ? "almanac note delete $d->{id} --global, or recreate the target file"
                    : qq(almanac note delete $d->{id} --root "$root_c", or recreate the target file);
                push @$findings, {
                    class  => $class, num => $num, scope => $scope, type => 'note', id => $d->{id},
                    path   => $d->{record}, line => undef,
                    detail => "target $t resolves to no file", repair => $repair,
                };
            } else {
                # OVERRIDDEN by blueprint where-things-go, package
                # 02-thread-store (specs/02-thread-store-spec.md section
                # 2.8): the flat `task` store is retired; this branch now
                # reports Almanac::Thread::check_refs entries, type
                # 'thread', id "<thread>/<task>" (already combined by
                # check_refs), repaired via `almanac thread edit`.
                (my $bare_task = $d->{task}) =~ s{\A\Q$d->{thread}\E/}{};
                push @$findings, {
                    class  => $class, num => $num, scope => $scope, type => 'thread', id => $d->{task},
                    path   => $root_c, line => undef,
                    detail => "blocked_on $d->{target} names no inbox item",
                    repair => qq(almanac thread edit $d->{thread} $bare_task --clear-blocked-on --root "$root_c"),
                };
            }
        }
        return;
    }

    my $reason = $entry->{reason};
    return unless defined $reason;
    return if $reason eq 'malformed' || _is_scope_unavailable_reason($reason);

    my $dir  = _decode_maybe(_store_dir_for($type, $scope, $root));
    my $flag = ($scope eq 'global') ? '--global' : qq(--root "$root_c");
    push @$findings, {
        class  => 'CHECK-FAILED', num => 7, scope => $scope, type => $type, id => '-',
        path   => $dir, line => undef,
        detail => "$funcname unavailable (reason $reason)",
        repair => "almanac $type list $flag shows the full error",
    };
}

# scan(%opt) -> { findings => [\%f, ...], stderr => [$line, ...] }   opt: root
sub scan {
    my (%opt) = @_;

    # THE READ-ONLY GUARANTEE (S2.2.1): every cell reports not-writable for
    # the whole of this call, restored automatically on return or die.
    local %Almanac::Store::SCOPE_POLICY = map {
        my $surf = $_;
        my %scopes = map {
            my $sc = $_;
            ($sc => { %{ $Almanac::Store::SCOPE_POLICY{$surf}{$sc} }, writable => 0 });
        } keys %{ $Almanac::Store::SCOPE_POLICY{$surf} };
        ($surf => \%scopes);
    } keys %Almanac::Store::SCOPE_POLICY;

    my @findings;
    my @stderr_lines;

    # Package 03-thread-sessions, spec 2.12: warn, once, when butler is not
    # installed beside almanac -- never a finding (exit code unaffected).
    unless (Almanac::SessionLive::butler_present()) {
        my $path = _decode_maybe(Almanac::SessionLive::butler_bphook_path());
        push @stderr_lines,
            "almanac doctor: warning: butler is not installed beside almanac ($path not found); "
          . "thread writes are not gated against subagents";
    }

    my $cur_root = (defined $opt{root} && length $opt{root})
        ? $opt{root} : Almanac::Store::resolve_project_root();

    my @registered = AlmanacBug::known_projects();
    my (@project_roots, %seen_canon);
    {
        my $c = AlmanacBug::canonical_root($cur_root);
        push @project_roots, $cur_root unless $seen_canon{$c}++;
    }
    for my $r (@registered) {
        unless (-d $r) {
            push @stderr_lines, "almanac doctor: note: registered project '$r' is not a directory here -- skipped";
            next;
        }
        my $c = AlmanacBug::canonical_root($r);
        next if $seen_canon{$c}++;
        push @project_roots, $r;
    }

    my $global_cap  = Almanac::Store::scope_capability('global');
    my $global_root = $global_cap->{readable} ? $global_cap->{root} : undef;

    for my $P (@project_roots) {
        my $proj_cap = Almanac::Store::scope_capability('project', root => $P);
        next unless $proj_cap->{readable};
        my $almanac_root = $proj_cap->{root};

        for my $dir (AlmanacBug::_almanac_type_dirs($almanac_root)) {
            (my $type = $dir) =~ s{.*/}{};
            _scan_type_dir('project', $type, $dir, $P, \@findings, \@stderr_lines);
            _scan_locks_in_dir($dir, 'project', $type, \@findings, \@stderr_lines);
        }

        my $reports_dir = AlmanacBug::reports_dir($P);
        _scan_locks_in_dir($reports_dir, 'project', 'bug', \@findings, \@stderr_lines);

        for my $rp (AlmanacBug::list_reports_in($P)) {
            my $rep = AlmanacBug::load($rp);
            next unless ref $rep eq 'HASH' && defined $rep->{fields}{id};
            my $rp_c = _decode_maybe($rp);

            if (defined $rep->{duplicate_key}) {
                push @findings, {
                    class  => 'UNPARSEABLE', num => 1, scope => 'project', type => 'bug', id => $rep->{fields}{id},
                    path   => $rp_c, line => 0,
                    detail => 'line 0: duplicate_key',
                    repair => 'restore it from the vault history; no almanac verb writes a record that does not parse',
                };
                next;
            }

            my ($ok, $note) = AlmanacBug::verify($rep);
            unless ($ok) {
                (my $detail = $note) =~ s/\A TAMPERED: \s*//x;
                push @findings, {
                    class  => 'TAMPERED', num => 2, scope => 'project', type => 'bug', id => $rep->{fields}{id},
                    path   => $rp_c, line => undef,
                    detail => $detail,
                    repair => 'restore it from the vault history, or accept it by re-saving through its own almanac verb',
                };
            }

            # STALE-CLAIM (package 12, 12-bug-claimant-and-triaging, spec sec
            # 2.9): a triaging claim stale by the shared liveness rule
            # (Almanac::SessionLive, blueprint where-things-go package
            # 03-thread-sessions, spec 2.11) -- never dies.
            my $cstate = AlmanacBug::claim_state($rep->{fields}, time);
            if (defined $cstate && $cstate->{stale}) {
                my $root_c = _decode_maybe($P);
                push @findings, {
                    class  => 'STALE-CLAIM', num => 10, scope => 'project', type => 'bug', id => $rep->{fields}{id},
                    path   => $rp_c, line => undef,
                    detail => $cstate->{reason},
                    repair => qq(almanac bug takeover $rep->{fields}{id} --project "$root_c"),
                };
            }

            # BAD-LINK/bug (blueprint where-things-go, package 07-bug-lifecycle,
            # spec sec 2.11, num 12 -- reuses the thread BAD-LINK class with
            # type 'bug'). Read-only: AlmanacBug::package_verdict never writes,
            # never dies, and already treats an archived-location link exactly
            # like a live one -- but THIS finding, like the existing thread one
            # above it, never flags a package resolving only under
            # blueprints/_archive/ (Decision 18 F1, "doctor does not flag an
            # archived package"), regardless of its status.
            my $v = AlmanacBug::package_verdict($rep->{fields}, $rp);
            if (defined $v
                && (grep { $v->{verdict} eq $_ } qw(missing parked dropped invalid))
                && !(defined $v->{location} && $v->{location} eq 'archived')) {
                my $root_c = _decode_maybe($P);
                my $link   = defined $v->{link} ? $v->{link} : '';
                my ($detail, $repair);
                if ($v->{verdict} eq 'missing') {
                    $detail = "link $link is missing";
                    $repair = qq(restore the ledger, or almanac bug set-status $rep->{fields}{id} --to dropped --note "<why>" --project "$root_c");
                }
                elsif ($v->{verdict} eq 'parked') {
                    $detail = "link $link package is parked";
                    $repair = qq(unpark the package, or almanac bug set-status $rep->{fields}{id} --to dropped --note "<why>" --project "$root_c");
                }
                elsif ($v->{verdict} eq 'dropped') {
                    $detail = "link $link package is dropped";
                    $repair = qq(almanac bug set-status $rep->{fields}{id} --to dropped --note "<why>" --project "$root_c");
                }
                else { # invalid
                    my $field = defined $rep->{fields}{package} ? $rep->{fields}{package} : '';
                    $detail = "package link '$field' is invalid";
                    $repair = qq(almanac bug set-status $rep->{fields}{id} --to dropped --note "<why>" --project "$root_c");
                }
                push @findings, {
                    class  => 'BAD-LINK', num => 12, scope => 'project', type => 'bug', id => $rep->{fields}{id},
                    path   => $rp_c, line => undef,
                    detail => $detail, repair => $repair,
                };
            }

            # UNMIGRATED-BUG (same package, spec sec 2.11, num 14): a `taken`
            # report whose resolution note names no resolvable package. Doctor
            # never writes and never migrates it away -- the next
            # almanac-bug.pl call does, via reconcile.
            if (($rep->{fields}{status} // '') eq 'taken') {
                my (undef, $reason) = AlmanacBug::migration_link($rep->{fields}, $P);
                if (defined $reason) {
                    my $root_c = _decode_maybe($P);
                    push @findings, {
                        class  => 'UNMIGRATED-BUG', num => 14, scope => 'project', type => 'bug', id => $rep->{fields}{id},
                        path   => $rp_c, line => undef,
                        detail => "status 'taken' predates 'scheduled', and $reason",
                        repair => qq(almanac bug set-status $rep->{fields}{id} --to scheduled --package <blueprint>/<package> --repair --project "$root_c"),
                    };
                }
            }
        }
    }

    if (defined $global_root) {
        for my $dir (AlmanacBug::_almanac_type_dirs($global_root)) {
            (my $type = $dir) =~ s{.*/}{};
            _scan_type_dir('global', $type, $dir, undef, \@findings, \@stderr_lines);
            _scan_locks_in_dir($dir, 'global', $type, \@findings, \@stderr_lines);
        }
    }

    # S4: check_pointers/check_refs each wrap their own scope in an eval and
    # report {available=>0, reason=>...} rather than dying, so a die reaching
    # here would be a genuine internal failure -- it is deliberately NOT
    # caught: it propagates to main's `eval { scan(...) }`, which reports it
    # as "internal error" and exits 2, per spec S2.2.7 ("a failed diagnostic
    # is never reported as clean").
    my $global_note_done = 0;
    for my $P (@project_roots) {
        my $res = Almanac::Note::check_pointers(root => $P);
        _process_check_entry(\@findings, 'note', 'project', $P, $res->{project}, 'check_pointers', 'DANGLING-POINTER', 4);
        unless ($global_note_done) {
            $global_note_done = 1;
            _process_check_entry(\@findings, 'note', 'global', undef, $res->{global}, 'check_pointers', 'DANGLING-POINTER', 4);
        }
    }

    for my $P (@project_roots) {
        my $res = Almanac::Thread::check_refs(root => $P);
        _process_check_entry(\@findings, 'thread', 'project', $P, $res->{project}, 'check_refs', 'DANGLING-REF', 5);

        my $health = Almanac::Thread::check_health(root => $P);
        if ($health->{available}) {
            my $root_c = _decode_maybe($P);
            for my $f (@{ $health->{findings} }) {
                my $id = "$f->{thread}/$f->{task}";
                if ($f->{kind} eq 'archived_open_task') {
                    push @findings, {
                        class  => 'ARCHIVED-OPEN-TASK', num => 11, scope => 'project', type => 'thread', id => $id,
                        path   => _decode_maybe($f->{path}), line => undef,
                        detail => "task $f->{task} is $f->{status} in archived thread $f->{thread}",
                        repair => qq(almanac thread status $f->{thread} $f->{task} done --root "$root_c"),
                    };
                }
                elsif ($f->{kind} eq 'link_missing') {
                    push @findings, {
                        class  => 'BAD-LINK', num => 12, scope => 'project', type => 'thread', id => $id,
                        path   => _decode_maybe($f->{path}), line => undef,
                        detail => "link $f->{link} is missing",
                        repair => qq(restore the ledger, or almanac thread archive $f->{thread} --root "$root_c"),
                    };
                }
                elsif ($f->{kind} eq 'link_invalid') {
                    push @findings, {
                        class  => 'BAD-LINK', num => 12, scope => 'project', type => 'thread', id => $id,
                        path   => _decode_maybe($f->{path}), line => undef,
                        detail => "link $f->{link} is not a valid <blueprint>/<package> link",
                        repair => qq(almanac thread archive $f->{thread} --root "$root_c"),
                    };
                }
                elsif ($f->{kind} eq 'link_parked') {
                    push @findings, {
                        class  => 'BAD-LINK', num => 12, scope => 'project', type => 'thread', id => $id,
                        path   => _decode_maybe($f->{path}), line => undef,
                        detail => "link $f->{link} package is parked",
                        repair => 'read the package ledger and unpark it or archive the thread',
                    };
                }
                elsif ($f->{kind} eq 'link_dropped') {
                    push @findings, {
                        class  => 'BAD-LINK', num => 12, scope => 'project', type => 'thread', id => $id,
                        path   => _decode_maybe($f->{path}), line => undef,
                        detail => "link $f->{link} package is dropped",
                        repair => qq(almanac thread archive-if-done $f->{thread} --root "$root_c"),
                    };
                }
            }
        }

        my $tstore = eval { Almanac::Store->open(scope => 'project', type => 'task', root => $P) };
        if ($tstore) {
            my $n = eval { scalar(@{ $tstore->ids }) };
            if (defined $n && $n >= 1) {
                my $root_c = _decode_maybe($P);
                push @findings, {
                    class  => 'UNMIGRATED-TASKLIST', num => 13, scope => 'project', type => 'task', id => '-',
                    path   => _decode_maybe($tstore->dir), line => undef,
                    detail => "the flat tasklist holds $n record(s) not yet migrated to threads",
                    repair => qq(almanac thread list --root "$root_c"),
                };
            }
        }
    }

    my $home = $ENV{ALMANAC_HOME};
    $home = $ENV{HOME}        unless defined $home && length $home;
    $home = $ENV{USERPROFILE} unless defined $home && length $home;
    $home = '.'                unless defined $home && length $home;
    $home =~ s{\\}{/}g;
    $home =~ s{/+\z}{} if length($home) > 1;

    my @legacy_candidates = (@project_roots, $home, "$home/.claude/ccpraxis");
    my %legacy_seen;
    my %is_project_root = map { AlmanacBug::canonical_root($_) => 1 } @project_roots;

    for my $D (@legacy_candidates) {
        next unless -d $D;
        my $c = AlmanacBug::canonical_root($D);
        next if $legacy_seen{$c}++;

        # S1: a real Almanac::Store->open, per spec S2.2.3 -- $D is already
        # confirmed a directory above, and open() creates nothing. The
        # printed path is therefore Store-canonical, exactly like every
        # other finding class (record-level paths already go through Store).
        my $dstore = eval { Almanac::Store->open(scope => 'project', type => 'inbox', root => $D) };
        next unless $dstore;
        my $legacy = Almanac::LegacyQueue::legacy_path($dstore);
        next unless -e $legacy;

        my $repair_root = $dstore->root;
        $repair_root =~ s{/\.ccpraxis-local-data/almanac\z}{};

        my $label = $is_project_root{$c} ? 'project' : 'orphan';
        push @findings, {
            class  => 'LEGACY-QUEUE', num => 9, scope => $label, type => 'inbox', id => '-',
            path   => _decode_maybe($legacy), line => undef,
            detail => 'unabsorbed legacy question queue',
            repair => qq(almanac inbox list --root "@{[ _decode_maybe($repair_root) ]}"),
        };
    }

    my @sorted = sort {
        $a->{num} <=> $b->{num}
            || $a->{path} cmp $b->{path}
            || (($a->{line} // 0) <=> ($b->{line} // 0))
    } @findings;

    return { findings => \@sorted, stderr => \@stderr_lines };
}

# format_finding(\%f) -> $line -- no trailing newline. Every field pushed
# into a finding hash by scan() is ALREADY decoded characters (M1 fix-batch:
# each raw byte component -- $path, $root, $lockpath, $D, ... -- is run
# through _decode_maybe at the point it is interpolated, never after the
# fact). Decoding the whole assembled line here a second time is exactly
# the bug: once any one field carries the utf8 flag, concatenating a
# still-raw byte string into it silently upgrades those bytes as Latin-1
# (the "AndrÃ©" mojibake) instead of decoding them, and the flag already
# being set then makes a final _decode_maybe a no-op that never catches it.
# So this function only joins -- it decodes nothing.
sub format_finding {
    my ($f) = @_;
    return "$f->{class}: $f->{scope} $f->{type}/$f->{id}: $f->{detail} -- $f->{path} -- repair: $f->{repair}";
}

# _parse_args(@argv) -> (1, $root|undef) | (0, undef)
sub _parse_args {
    my (@argv) = @_;
    return (1, undef) unless @argv;
    if (@argv == 2 && $argv[0] eq '--root' && defined $argv[1] && length $argv[1]) {
        return (1, $argv[1]);
    }
    return (0, undef);
}

sub main {
    my (@argv) = @_;
    my ($ok, $root_opt) = _parse_args(@argv);
    unless ($ok) {
        print STDERR "almanac doctor: usage: almanac doctor [--root DIR]\n";
        return 2;
    }

    binmode(STDOUT, ':encoding(UTF-8)');

    my $result = eval { scan(root => $root_opt) };
    if (my $err = $@) {
        (my $msg = "$err") =~ s/\s+\z//;
        print STDERR "almanac doctor: internal error: $msg\n";
        return 2;
    }

    for my $line (@{ $result->{stderr} }) {
        print STDERR "$line\n";
    }

    my @findings = @{ $result->{findings} };
    for my $f (@findings) {
        print format_finding($f), "\n";
    }

    if (@findings) {
        print 'almanac doctor: ' . scalar(@findings) . " finding(s); nothing was changed\n";
        return 1;
    }
    return 0;
}

unless (caller) {
    exit main(@ARGV);
}

1;
