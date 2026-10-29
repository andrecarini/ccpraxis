#!/usr/bin/env perl
# almanac-inbox.pl -- the project-only operator inbox store, over
# Almanac::Store (blueprint almanac-records, package 08, the original
# inbox store; renamed by blueprint where-things-go, package 01-inbox-rename).
# See the archived package-08 spec for the original contract and
# specs/01-inbox-rename-spec.md for the rename and the link/choices/
# structured-answer additions; this file implements both and adds nothing
# beyond them.
#
# Agent-authored (`file`), operator-answered (`answer`). This package owns
# the traversal item -> tasks whose blocked_on names it; it reads tasks
# only through Almanac::Task::list_tasks (loaded below as the sibling
# script), never owning or writing that field itself.
package Almanac::Inbox;
use strict;
use warnings;
use Fcntl qw(:flock);
use JSON::PP ();
use Encode ();
use Cwd ();

# Almanac/ and almanac-task.pl sit beside THIS FILE (not $0, and not any
# module that resolves the running program -- both are the invoking
# program, which a test's `do $INBOX_PL` makes the .t file, not this one).
# Bug 20261001-184636-75fe (a relative __FILE__ breaks this) is fixed by
# resolving __FILE__ through Cwd::abs_path first: a relative __FILE__ left
# $dir relative too, and @INC's own path-join logic doubled the directory
# onto $TASK_PL's require below ("Can't locate .../almanac-task.pl in
# @INC").
my $TASK_PL;
BEGIN {
    my $dir = do { (my $f = __FILE__) =~ s{\\}{/}g; Cwd::abs_path($f) // $f };
    $dir =~ s{\\}{/}g;
    $dir = ($dir =~ m{/}) ? ($dir =~ s{/[^/]+\z}{}r) : '.';
    unshift @INC, $dir;
    $TASK_PL = "$dir/almanac-task.pl";
}
use Almanac::Store ();
use Almanac::Record ();
use Almanac::Lock ();
use Almanac::LegacyQueue ();

# Loading this script brings Almanac::Task::* with it (spec S2.3): a
# `require` of the sibling script's absolute path, at compile time, so
# after loading almanac-inbox.pl alone, Almanac::Task::* is already
# defined. `require` (unlike `system`/`exec`) runs it with a caller frame,
# so almanac-task.pl's own `unless (caller)` CLI main never fires here.
require $TASK_PL;

our $VERSION = '1.0';

# The unmigrated legacy store's type name (blueprint where-things-go,
# package 01-inbox-rename). The ONE legacy-dir constant in this file.
my $LEGACY_TYPE = 'decision';

# ---------------------------------------------------------------------------
# small helpers.
# ---------------------------------------------------------------------------

sub _usage { die Almanac::Store::Error->new(kind => 'usage', detail => $_[0]) }

sub _refused {
    my (%a) = @_;
    die Almanac::Store::Error->new(kind => 'refused', path => $a{path},
        detail => $a{detail}, hint => $a{hint});
}

sub _trim {
    my ($s) = @_;
    return $s unless defined $s;
    $s =~ s/\A\s+//;
    $s =~ s/\s+\z//;
    return $s;
}

# _decode_maybe($s) -> decoded character string. See almanac-task.pl's
# comment of the same name.
sub _decode_maybe {
    my ($s) = @_;
    return $s unless defined $s;
    return $s if utf8::is_utf8($s);
    my $d = eval { Encode::decode('UTF-8', $s, Encode::FB_CROAK()) };
    return defined $d ? $d : $s;
}

sub _now_iso {
    my @t = gmtime(time);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ',
                   $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

sub _err_reason {
    my ($err) = @_;
    if (ref($err) eq 'Almanac::Store::Error' || ref($err) eq 'Almanac::Record::Error') {
        if (defined $err->{kind} && $err->{kind} eq 'scope_unavailable' && defined $err->{reason}) {
            return $err->{reason};
        }
        return defined $err->{kind} ? $err->{kind} : 'error';
    }
    return 'error';
}

# _validate_link($v) -> $trimmed | undef (undef means malformed). 1-3
# segments joined by a single '/', each matching the id-like grammar, at
# most 128 bytes, no "..". Purely syntactic (one-way link, Decision 4):
# nothing here resolves against disk.
sub _validate_link {
    my ($v) = @_;
    return undef unless defined $v;
    my $t = _trim($v);
    my @segs = split m{/}, $t, -1;
    return undef if @segs < 1 || @segs > 3;
    for my $s (@segs) {
        return undef unless $s =~ /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/;
        return undef if length($s) > 128;
        return undef if $s =~ /\.\./;
    }
    return $t;
}

# _validate_choices($v) -> "a,b,c" (trimmed, order preserved) | undef. 1-16
# distinct (case-sensitive) items, each matching the token grammar, at most
# 64 bytes.
sub _validate_choices {
    my ($v) = @_;
    return undef unless defined $v;
    my @items = split /,/, $v, -1;
    @items = map { _trim($_) } @items;
    return undef if @items < 1 || @items > 16;
    my %seen;
    for my $it (@items) {
        return undef unless $it =~ /\A[A-Za-z0-9][A-Za-z0-9_-]*\z/;
        return undef if length($it) > 64;
        return undef if $seen{$it}++;
    }
    return join(',', @items);
}

# ---------------------------------------------------------------------------
# legacy store migration (spec 2.2).
# ---------------------------------------------------------------------------

# migrate_legacy_store($store) -> \%report -- may die (Almanac::Store::Error,
# kind 'refused'). Every die path releases every lock it holds first.
sub migrate_legacy_store {
    my ($store) = @_;
    return { state => 'skipped', reason => 'not_writable' } unless $store->writable;

    my $legacy = $store->root . '/' . $LEGACY_TYPE;
    my $target = $store->dir;
    return { state => 'absent' } unless -e $legacy;

    my $mig_target = $store->root . '/.inbox-migration';
    my ($mlock, $mlock_err) = Almanac::Lock->acquire($mig_target, verb => 'migrate');
    unless ($mlock) {
        _refused(path => $legacy, detail => 'migration_failed',
            hint => "almanac inbox: could not rename $legacy to $target; nothing was moved, retry");
    }

    # re-check under the lock: another process may have already migrated.
    unless (-e $legacy) {
        $mlock->release;
        return { state => 'absent' };
    }
    unless (-d $legacy) {
        $mlock->release;
        _refused(path => $legacy, detail => 'legacy_not_directory',
            hint => "almanac inbox: $legacy is not a directory; move it aside by hand, then retry");
    }
    if (-e $target) {
        $mlock->release;
        _refused(path => $legacy, detail => 'half_migrated',
            hint => "almanac inbox: both $legacy and $target exist; merge or remove one by hand, then retry");
    }

    # Probe each record's lock with a raw, non-blocking flock on the SAME
    # sidecar Almanac::Lock itself locks (lock_path_for) -- deliberately NOT
    # Almanac::Lock->acquire: acquire() always (re)writes the `.lock.holder`
    # sidecar on success, which would mutate a record that already had one
    # from a previous writer and break AC13's byte-for-byte migration
    # guarantee. A probe that only asks "is anyone else holding this right
    # now" must leave every byte on disk exactly as it found it. Released
    # immediately, per record, well before the rename (timeout_ms 0: a
    # single non-blocking attempt, not any-lock-file-exists).
    my @record_files = Almanac::Store::record_files_in($legacy);
    for my $rp (@record_files) {
        my $lock_path = Almanac::Lock::lock_path_for($rp);
        my $fh;
        unless (open($fh, '>>', $lock_path)) {
            $mlock->release;
            _refused(path => $rp, detail => 'record_locked',
                hint => "almanac inbox: $rp is locked by a running writer; retry when it finishes");
        }
        my $got = flock($fh, LOCK_EX | LOCK_NB);
        if ($got) { flock($fh, LOCK_UN); }
        close $fh;
        unless ($got) {
            $mlock->release;
            _refused(path => $rp, detail => 'record_locked',
                hint => "almanac inbox: $rp is locked by a running writer; retry when it finishes");
        }
    }

    my ($ok, $rerr) = Almanac::Lock::rename_with_retry($legacy, $target);
    unless ($ok) {
        $mlock->release;
        _refused(path => $legacy, detail => 'migration_failed',
            hint => "almanac inbox: could not rename $legacy to $target; nothing was moved, retry");
    }

    my $n = scalar @record_files;
    $mlock->release;
    return { state => 'migrated', from => $legacy, to => $target, records => $n };
}

# ---------------------------------------------------------------------------
# module functions.
# ---------------------------------------------------------------------------

# open_inbox(%opt) -> Almanac::Store -- THE single accessor: every other
# function and CLI verb in this file reaches the inbox store only through
# this sub. It is the ONLY ->open( call in the whole file, the only
# absorb( call and the only migrate_legacy_store( call; migrate precedes
# absorb.
sub open_inbox {
    my (%opt) = @_;
    my $store = Almanac::Store->open(scope => 'project', type => 'inbox',
        root => $opt{root}, home => $opt{home}, cwd => $opt{cwd});
    migrate_legacy_store($store);             # may die
    Almanac::LegacyQueue::absorb($store);     # never dies
    return $store;
}

sub file {
    my (%opt) = @_;
    _usage('missing_title') unless exists($opt{title}) && defined($opt{title});
    my $title = _trim($opt{title});
    _usage('bad_title') if $title eq '' || $title =~ /[\r\n]/;

    my $link;
    if (exists $opt{link} && defined $opt{link}) {
        $link = _validate_link($opt{link});
        _usage('bad_link') unless defined $link;
    }
    my $choices;
    if (exists $opt{choices} && defined $opt{choices}) {
        $choices = _validate_choices($opt{choices});
        _usage('bad_choices') unless defined $choices;
    }

    my %fields = (title => $title, status => 'unanswered', created => _now_iso());
    my @order  = qw(title status created);
    if (defined $link)    { $fields{link}    = $link;    push @order, 'link'; }
    if (defined $choices) { $fields{choices} = $choices; push @order, 'choices'; }

    my %args = (fields => \%fields, order => \@order);
    $args{id}   = $opt{id}   if exists $opt{id};
    $args{body} = $opt{body} if exists $opt{body};

    return open_inbox(%opt)->create(%args);
}

sub list_items {
    my (%opt) = @_;
    return open_inbox(%opt)->list();
}

sub read_item {
    my ($id, %opt) = @_;
    return open_inbox(%opt)->read($id);
}

# answer($id, %opt) -> ($record, $changed) -- opt: answer*, choice, note,
# expect_rev. Structured path when `choice` or `note` is given (spec 2.4);
# legacy free-text path otherwise.
sub answer {
    my ($id, %opt) = @_;

    if (exists $opt{choice} || exists $opt{note}) {
        _usage('answer_with_choice') if exists $opt{answer};

        # Whether to report `missing_choice` (a choices item answered without
        # --choice) or `no_choices` (a plain item given --choice/--note at
        # all) depends on the record -- so the choice-missing usage error is
        # deferred until after the record is read (spec 2.4/B6). Format
        # checks that do NOT need the record (bad_choice/bad_note) still run
        # up front, on whatever was actually given.
        my $choice_given = exists($opt{choice}) && defined($opt{choice});
        my $choice;
        if ($choice_given) {
            $choice = _trim($opt{choice});
            _usage('bad_choice') if $choice eq '' || $choice =~ /[\r\n]/;
        }

        my $note;
        my $note_given = exists $opt{note};
        if ($note_given) {
            my $raw = defined $opt{note} ? $opt{note} : '';
            $note = _decode_maybe(_trim($raw));
            _usage('bad_note') if $note eq '' || $note =~ /[\r\n]/;
        }

        my $store = open_inbox(%opt);
        my $rec   = $store->read($id);
        _usage('no_choices') unless exists $rec->{fields}{choices};
        _usage('missing_choice') unless $choice_given;
        my @valid = split /,/, $rec->{fields}{choices};
        _usage('bad_choice') unless grep { $_ eq $choice } @valid;

        my $status = $rec->{fields}{status};
        if (defined($status) && $status eq 'unanswered') {
            my %expect = (rev => (exists $opt{expect_rev} ? $opt{expect_rev} : $rec->{rev}),
                          fields => $rec->{fields});
            my %set = (status => 'answered', choice => $choice, answered_at => _now_iso());
            $set{note} = $note if $note_given;
            my $new = $store->update($id, expect => \%expect, set => \%set);
            return ($new, 1);
        }
        elsif (defined($status) && $status eq 'answered') {
            my $cur_choice = $rec->{fields}{choice};
            my $match = defined($cur_choice) && $cur_choice eq $choice;
            if ($match) {
                if ($note_given) {
                    $match = (defined($rec->{fields}{note}) && $rec->{fields}{note} eq $note);
                } else {
                    $match = !exists $rec->{fields}{note};
                }
            }
            return ($rec, 0) if $match;
            _usage('already_answered');
        }
        else {
            _usage('bad_status');
        }
    }
    else {
        _usage('missing_answer') unless exists($opt{answer}) && defined($opt{answer});
        my $ans = _decode_maybe(_trim($opt{answer}));
        _usage('bad_answer') if $ans eq '' || $ans =~ /[\r\n]/;

        my $store = open_inbox(%opt);
        my $rec   = $store->read($id);
        _usage('missing_choice') if exists $rec->{fields}{choices};
        my $status = $rec->{fields}{status};

        if (defined($status) && $status eq 'unanswered') {
            my %expect = (rev => (exists $opt{expect_rev} ? $opt{expect_rev} : $rec->{rev}),
                          fields => $rec->{fields});
            my $new = $store->update($id, expect => \%expect,
                set => { status => 'answered', answer => $ans, answered_at => _now_iso() });
            return ($new, 1);
        }
        elsif (defined($status) && $status eq 'answered') {
            my $cur_answer = defined($rec->{fields}{answer}) ? $rec->{fields}{answer} : undef;
            if (defined($cur_answer) && $cur_answer eq $ans) {
                return ($rec, 0);
            }
            _usage('already_answered');
        }
        else {
            _usage('bad_status');
        }
    }
}

# blocked_tasks($id, %opt) -> \%report -- NEVER dies, prints, or writes task
# records except via Store's own crash recovery of the task store (Store::
# list() rolls back an abandoned reorder journal when the store is
# writable). Tasks are obtained via Almanac::Task::list_tasks (the flat
# tasklist, retained as a library for old readers -- spec 02-thread-store
# section 5) AND, since blueprint where-things-go package 02-thread-store
# (Decision 26: "its blocked_tasks is a REAL post-migration behavioral
# regression, not cosmetic"), via Almanac::Thread's tasks across every
# thread: once migrate_legacy has emptied the flat store, a thread task's
# blocked_on is the only place a real block can still be recorded, and
# this sub never checks that inbox item $id exists either way.
sub blocked_tasks {
    my ($id, %opt) = @_;
    my $report = { item => $id };

    # $ok, not `if (my $err = $@)`: an error object may stringify to ''
    # (Store::Error's `""` overload falls back on `{message}`, and a bare
    # error with no message is boolean-false even as a real reference), so
    # $@ truthiness alone can miss a real failure and fall through to
    # `@$list` on an undef $list -- reported wrongly as available => 1.
    my $list;
    my $ok = eval { $list = Almanac::Task::list_tasks(%opt); 1 };
    unless ($ok) {
        $report->{available} = 0;
        $report->{reason}    = _err_reason($@);
        return $report;
    }

    my @tasks;
    for my $t (@$list) {
        my $bo = $t->{fields}{blocked_on};
        next unless defined $bo && $bo eq $id;
        push @tasks, {
            task   => $t->{id},
            status => $t->{fields}{status},
            title  => $t->{fields}{title},
            ref    => ((defined($t->{fields}{status}) && $t->{fields}{status} eq 'obsoleted')
                       ? 'dangling' : 'live'),
        };
    }

    # Thread tasks: scanned the same way Almanac::Thread::check_refs does
    # for doctor (never opens a thread lock, never writes) -- a linked task
    # is skipped (its blocked_on is not a live field there, matching
    # check_refs); archived threads are included, since an archived
    # thread's task can still name a real blocked_on.
    my @unreadable;
    my $thread_ok = eval {
        require Almanac::Thread;
        my $threads = Almanac::Thread::list_threads(%opt, archived => 1);
        for my $trec (@$threads) {
            my $tname = $trec->{name};
            # Per-thread isolation (pkg02 review S5): one thread whose task
            # store cannot be read used to blank the whole report. Skip it,
            # and name it, rather than hide every other thread's blocks.
            my $ttasks = eval { Almanac::Thread::tasks($tname, %opt) };
            unless (ref $ttasks eq 'ARRAY') {
                push @unreadable, $tname;
                next;
            }
            for my $tk (@$ttasks) {
                next if defined $tk->{link};
                my $bo = $tk->{blocked_on};
                next unless defined $bo && $bo eq $id;
                push @tasks, {
                    task   => "$tname/$tk->{id}",
                    status => $tk->{status},
                    title  => $tk->{title},
                    ref    => ((defined($tk->{status}) && $tk->{status} eq 'obsoleted')
                               ? 'dangling' : 'live'),
                };
            }
        }
        1;
    };
    unless ($thread_ok) {
        $report->{available} = 0;
        $report->{reason}    = _err_reason($@);
        return $report;
    }

    my @dangling = grep { $_->{ref} eq 'dangling' } @tasks;

    $report->{available} = 1;
    $report->{reason}    = 'ok';
    $report->{tasks}      = \@tasks;
    $report->{dangling}   = \@dangling;
    $report->{unreadable_threads} = \@unreadable if @unreadable;
    return $report;
}

# count(%opt) -> \%counts -- NEVER dies, prints or writes. Shape mirrors
# Almanac::Todo::count; project key only (inbox items have no global scope).
sub count {
    my (%opt) = @_;
    my $report = { type => 'inbox' };

    my $list;
    my $ok = eval { $list = list_items(%opt); 1 };
    unless ($ok) {
        $report->{project} = { available => 0, reason => _err_reason($@) };
        return $report;
    }

    my ($un, $an) = (0, 0);
    for my $r (@$list) {
        my $s = $r->{fields}{status};
        if (defined($s) && $s eq 'unanswered') { $un++ }
        elsif (defined($s) && $s eq 'answered') { $an++ }
        else {
            $report->{project} = { available => 0, reason => 'bad_status' };
            return $report;
        }
    }
    $report->{project} = { available => 1, reason => 'ok', unanswered => $un, answered => $an, total => $un + $an };
    return $report;
}

# ---------------------------------------------------------------------------
# output formatting (CLI only).
# ---------------------------------------------------------------------------
sub _print_result {
    my ($rec, %a) = @_;
    print "id: $rec->{id}\n";
    print "path: " . _decode_maybe($rec->{path}) . "\n";
    print "status: $a{status}\n";
    print "rev: $rec->{rev}\n";
    print "changed: $a{changed}\n";
}

sub _print_traversal {
    my ($report) = @_;
    print "item: $report->{item}\n";
    print "tasks_available: " . ($report->{available} ? 'yes' : 'no') . "\n";
    print "tasks_reason: $report->{reason}\n";
    if ($report->{available}) {
        for my $t (@{ $report->{tasks} }) {
            print "blocked_task: $t->{task}\n";
            print "  status: " . (defined $t->{status} ? $t->{status} : '-') . "\n";
            print "  ref: $t->{ref}\n";
            print "  title: "  . (defined $t->{title}  ? $t->{title}  : '-') . "\n";
        }
        print "blocked_total: "  . scalar(@{ $report->{tasks} })    . "\n";
        print "dangling_total: " . scalar(@{ $report->{dangling} }) . "\n";
        print "unreadable_thread: $_\n" for @{ $report->{unreadable_threads} || [] };
    } else {
        print "blocked_total: 0\n";
        print "dangling_total: 0\n";
    }
}

sub _print_traversal_json {
    my ($report) = @_;
    my @blocked;
    if ($report->{available}) {
        for my $t (@{ $report->{tasks} }) {
            push @blocked, { id => $t->{task}, status => $t->{status}, title => $t->{title}, ref => $t->{ref} };
        }
    }
    my %out = (
        item            => $report->{item},
        tasks_available => ($report->{available} ? JSON::PP::true() : JSON::PP::false()),
        tasks_reason    => $report->{reason},
        blocked         => \@blocked,
    );
    $out{unreadable_threads} = $report->{unreadable_threads} if $report->{unreadable_threads};
    print JSON::PP->new->canonical(1)->encode(\%out);
}

sub _print_list_default {
    my ($list) = @_;
    my ($un, $an) = (0, 0);
    for my $rec (@$list) {
        my $f = $rec->{fields};
        print "item: $rec->{id}\n";
        print "  status: " . (defined $f->{status} ? $f->{status} : '-') . "\n";
        print "  title: "  . (defined $f->{title}  ? $f->{title}  : '-') . "\n";
        print "  answer: " . (defined $f->{answer} ? $f->{answer} : '-') . "\n";
        print "  link: $f->{link}\n"       if exists $f->{link};
        print "  choices: $f->{choices}\n" if exists $f->{choices};
        print "  choice: $f->{choice}\n"   if exists $f->{choice};
        print "  note: $f->{note}\n"       if exists $f->{note};
        if    (defined($f->{status}) && $f->{status} eq 'unanswered') { $un++ }
        elsif (defined($f->{status}) && $f->{status} eq 'answered')   { $an++ }
    }
    print "unanswered: $un\n";
    print "answered: $an\n";
    print "total: " . scalar(@$list) . "\n";
}

sub _print_list_json {
    my ($list) = @_;
    my @out;
    for my $rec (@$list) {
        my $f = $rec->{fields};
        my %item = (
            id          => $rec->{id},
            status      => $f->{status},
            title       => $f->{title},
            created     => $f->{created},
            answer      => (exists $f->{answer}      ? $f->{answer}      : undef),
            answered_at => (exists $f->{answered_at} ? $f->{answered_at} : undef),
        );
        $item{link}    = $f->{link}                      if exists $f->{link};
        $item{choices} = [ split /,/, $f->{choices}, -1 ] if exists $f->{choices};
        $item{choice}  = $f->{choice}                    if exists $f->{choice};
        $item{note}    = $f->{note}                      if exists $f->{note};
        push @out, \%item;
    }
    print JSON::PP->new->canonical(1)->encode(\@out);
}

sub _print_show_default {
    my ($rec) = @_;
    for my $k (@{ $rec->{order} }) {
        next unless exists $rec->{fields}{$k};
        print "$k: $rec->{fields}{$k}\n";
    }
    print "\n";
    print $rec->{body} if defined $rec->{body};
}

sub _print_show_json {
    my ($rec) = @_;
    my %out = (
        id     => $rec->{id},
        path   => _decode_maybe($rec->{path}),
        rev    => $rec->{rev},
        rank   => $rec->{rank},
        fields => $rec->{fields},
        body   => $rec->{body},
    );
    print JSON::PP->new->canonical(1)->encode(\%out);
}

# ---------------------------------------------------------------------------
# CLI verbs.
# ---------------------------------------------------------------------------
sub _cmd_file {
    my ($o, $bool_default) = @_;
    my $title_missing = !exists($o->{title}) || $bool_default->{title};
    _usage('missing_title') if $title_missing;

    my %opt;
    $opt{root}    = $o->{root} if exists $o->{root};
    $opt{title}   = $o->{title};
    $opt{body}    = $o->{body} if exists $o->{body};
    $opt{id}      = $o->{id}   if exists $o->{id};
    $opt{link}    = $o->{link}    if exists $o->{link};
    $opt{choices} = $o->{choices} if exists $o->{choices};

    my $rec = file(%opt);
    _print_result($rec, status => 'unanswered', changed => 'yes');
}

sub _cmd_list {
    my ($o) = @_;
    my $list = list_items(root => $o->{root});
    if ($o->{json}) { _print_list_json($list) }
    else            { _print_list_default($list) }
}

sub _cmd_show {
    my ($o, $id) = @_;
    my $rec = read_item($id, root => $o->{root});
    if ($o->{json}) { _print_show_json($rec) }
    else            { _print_show_default($rec) }
}

sub _cmd_answer {
    my ($o, $bool_default, $id) = @_;

    if (exists $o->{choice} || exists $o->{note}) {
        my %opt = (root => $o->{root});
        $opt{choice}     = $o->{choice}        if exists $o->{choice};
        $opt{note}       = $o->{note}          if exists $o->{note};
        $opt{answer}     = $o->{answer}        if exists $o->{answer};
        $opt{expect_rev} = $o->{'expect-rev'}  if exists $o->{'expect-rev'};

        my ($rec, $changed) = answer($id, %opt);
        _print_result($rec, status => $rec->{fields}{status}, changed => ($changed ? 'yes' : 'no'));

        my $report = blocked_tasks($id, root => $o->{root});
        _print_traversal($report);
        return;
    }

    my $answer_missing = !exists($o->{answer}) || $bool_default->{answer};
    _usage('missing_answer') if $answer_missing;

    my %opt = (root => $o->{root}, answer => $o->{answer});
    $opt{expect_rev} = $o->{'expect-rev'} if exists $o->{'expect-rev'};

    my ($rec, $changed) = answer($id, %opt);
    _print_result($rec, status => $rec->{fields}{status}, changed => ($changed ? 'yes' : 'no'));

    my $report = blocked_tasks($id, root => $o->{root});
    _print_traversal($report);
}

sub _cmd_blocks {
    my ($o, $id) = @_;
    read_item($id, root => $o->{root});   # existence check (not_found on a miss)

    my $report = blocked_tasks($id, root => $o->{root});
    if ($o->{json}) { _print_traversal_json($report) }
    else            { _print_traversal($report) }
}

# ---------------------------------------------------------------------------
# CLI entry point.
# ---------------------------------------------------------------------------
unless (caller) {
    binmode(STDOUT, ':encoding(UTF-8)');

    # Argv grammar: one pass over the WHOLE of @ARGV, same as almanac-
    # task.pl -- the verb is simply the first positional token once parsing
    # is done.
    my (%o, %bool_default, @pos);
    while (@ARGV) {
        my $a = shift @ARGV;
        if ($a =~ /^--([a-z0-9-]+)$/) {
            my $key = $1;
            my $has_val = (@ARGV && $ARGV[0] !~ /^--/);
            my $val = $has_val ? shift @ARGV : 1;
            $o{$key} = $val;
            if ($has_val) { delete $bool_default{$key} }
            else          { $bool_default{$key} = 1 }
        } else {
            push @pos, $a;
        }
    }
    my $cmd = shift @pos;

    my $ok = eval {
        _usage('missing_verb') unless defined $cmd && length $cmd;

        my %VERBS = map { $_ => 1 } qw(file list show answer blocks);
        _usage('unknown_verb') unless $VERBS{$cmd};

        my %ALLOWED_FLAGS = (
            'file'   => [qw(title body id root link choices)],
            'list'   => [qw(json root)],
            'show'   => [qw(json root)],
            'answer' => [qw(answer choice note expect-rev root)],
            'blocks' => [qw(json root)],
        );
        my %allowed = map { $_ => 1 } @{ $ALLOWED_FLAGS{$cmd} };
        for my $k (keys %o) {
            _usage('unknown_flag') unless $allowed{$k};
        }

        # Value-taking flags fail OPEN on a missing value (bare flag) --
        # `title`, `answer` and the boolean `json` are deliberately excluded
        # (bespoke / genuine booleans, same rule as almanac-task.pl).
        for my $k (qw(root body id expect-rev link choices choice note)) {
            _usage('missing_flag_value') if $bool_default{$k};
        }

        if ($cmd eq 'file') {
            _usage('extra_positional') if @pos;
            _cmd_file(\%o, \%bool_default);
        }
        elsif ($cmd eq 'list') {
            _usage('extra_positional') if @pos;
            _cmd_list(\%o);
        }
        elsif ($cmd eq 'show') {
            my $id = shift @pos;
            _usage('missing_id') unless defined $id && length $id;
            _usage('extra_positional') if @pos;
            _cmd_show(\%o, $id);
        }
        elsif ($cmd eq 'answer') {
            my $id = shift @pos;
            _usage('missing_id') unless defined $id && length $id;
            _usage('extra_positional') if @pos;
            _cmd_answer(\%o, \%bool_default, $id);
        }
        elsif ($cmd eq 'blocks') {
            my $id = shift @pos;
            _usage('missing_id') unless defined $id && length $id;
            _usage('extra_positional') if @pos;
            _cmd_blocks(\%o, $id);
        }
        1;
    };
    unless ($ok) {
        my $err = $@;
        if (ref($err) eq 'Almanac::Store::Error' && defined $err->{hint}) {
            print STDERR $err->{hint} . "\n";
        }
        Almanac::Record::fatal($err);
    }
    exit 0;
}

1;
