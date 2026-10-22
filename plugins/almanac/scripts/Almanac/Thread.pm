package Almanac::Thread;
# Almanac::Thread -- threads replace the flat tasklist: metadata, a typed log
# and one ordered task list per thread. Blueprint where-things-go, package
# 02-thread-store. See specs/02-thread-store-spec.md section 2.4.
use strict;
use warnings;
use File::Path ();
use Encode ();

BEGIN {
    # Almanac/ sits beside THIS FILE; add the PARENT (scripts/) to @INC so
    # `use Almanac::Store` resolves to the %INC key 'Almanac/Store.pm'
    # whoever loads this file (spec 2.4).
    my $dir = __FILE__;
    $dir =~ s{\\}{/}g;
    $dir =~ s{/[^/]+\z}{};   # strip Thread.pm -> .../Almanac
    $dir =~ s{/[^/]+\z}{};   # strip Almanac -> .../scripts
    $dir = '.' unless length $dir;
    unshift @INC, $dir;
}
use Almanac::Store ();
use Almanac::Record ();
use Almanac::Lock ();
use Almanac::PackageLink ();
use Almanac::SessionLive ();

our $VERSION = '1.0';

# Incremented once per successful Store mutation (create/update/delete/
# reorder) so a caller can tell whether anything was written.
our $WRITES = 0;

our @EVENTS = qw(created attached detached handed-off taken-over paused resumed archived
                 task-status launched escalation-sent answer-applied finished);

# Decision 35 / M2: reattach()'s predecessor-adjacency window (seconds).
our $REATTACH_PROXIMITY_SECONDS = 120;

# Decision 35 / S3: events that change owner-relevant state. record_event's
# cli_gate caller (almanac-thread.pl's `event` verb) requires the caller to
# own the thread (or act as orchestrator) for exactly these; informational
# events (task-status, launched, escalation-sent, answer-applied, finished,
# created, attached, detached -- attached/detached already go through
# attach()/detach()'s own ownership checks, not the bare `event` verb) are
# unaffected.
our @OWNER_GATED_EVENTS = qw(handed-off taken-over paused resumed archived);
our @TASK_STATUSES = qw(pending doing blocked done obsoleted);
our @STATES        = qw(live handed-off archived);
our @ACTORS        = qw(session orchestrator migration cli);
our %REASON_REQUIRED = map { $_ => 1 } qw(handed-off paused);

my %EVENT_OK           = map { $_ => 1 } @EVENTS;
my %STATUS_OK          = map { $_ => 1 } @TASK_STATUSES;
my %ACTOR_OK            = map { $_ => 1 } @ACTORS;
my %SIDE_EFFECT_ONLY    = map { $_ => 1 } qw(created archived task-status);
my %ARCHIVED_ALLOWED_EVENTS = map { $_ => 1 } qw(launched escalation-sent answer-applied finished);
my %OWNER_GATED_EVENT_OK = map { $_ => 1 } @OWNER_GATED_EVENTS;

# ---------------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------------
sub _usage   { die Almanac::Store::Error->new(kind => 'usage',   detail => $_[0]) }
sub _refused {
    my ($detail, $path, $cause) = @_;
    die Almanac::Store::Error->new(kind => 'refused', detail => $detail, path => $path,
        (defined $cause ? (cause => $cause) : ()));
}

sub _trim {
    my ($s) = @_;
    return $s unless defined $s;
    $s =~ s/\A\s+//;
    $s =~ s/\s+\z//;
    return $s;
}

sub _valid_ref_id {
    my ($v) = @_;
    return 0 unless defined $v && length($v) <= 128;
    return 0 unless $v =~ /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/;
    return 0 if $v =~ /\.\./;
    return 1;
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

sub _check_actor {
    my (%opt) = @_;
    _usage('bad_actor') if defined $opt{actor} && !$ACTOR_OK{$opt{actor}};
}

sub valid_name {
    my ($name) = @_;
    return 0 unless defined $name;
    return 0 unless $name =~ /\A[a-z0-9][a-z0-9-]{0,63}\z/;
    return 0 if $name =~ /\A(?:con|prn|aux|nul|com[1-9]|lpt[1-9])\z/i;
    return 1;
}

sub tasks_type { return "thread-tasks-$_[0]" }
sub log_type   { return "thread-log-$_[0]" }

# check_reason($reason) -> decoded reason | undef (if $reason undef)
# dies usage bad_reason|reason_too_long otherwise.
sub check_reason {
    my ($reason) = @_;
    return undef unless defined $reason;
    my $decoded = $reason;
    if (!utf8::is_utf8($decoded)) {
        my $d = eval { Encode::decode('UTF-8', $decoded, Encode::FB_CROAK()) };
        _usage('bad_reason') unless defined $d;
        $decoded = $d;
    }
    _usage('bad_reason') if $decoded eq '';
    _usage('bad_reason') if $decoded =~ /[\r\n]/;
    _usage('bad_reason') if $decoded =~ /[\x00-\x1f\x7f]/;
    my $bytes = Encode::encode('UTF-8', $decoded);
    _usage('reason_too_long') if length($bytes) > 200;
    return $decoded;
}

# ---------------------------------------------------------------------------
# store handles
# ---------------------------------------------------------------------------
sub _thread_store {
    my (%opt) = @_;
    return Almanac::Store->open(scope => 'project', type => 'thread',
        root => $opt{root}, home => $opt{home}, cwd => $opt{cwd});
}
sub _tasks_store {
    my ($name, %opt) = @_;
    return Almanac::Store->open(scope => 'project', type => tasks_type($name),
        root => $opt{root}, home => $opt{home}, cwd => $opt{cwd});
}
sub _log_store {
    my ($name, %opt) = @_;
    return Almanac::Store->open(scope => 'project', type => log_type($name),
        root => $opt{root}, home => $opt{home}, cwd => $opt{cwd});
}

sub project_root {
    my (%opt) = @_;
    my $r = _thread_store(%opt)->root;
    $r =~ s{/\.ccpraxis-local-data/almanac\z}{};
    return $r;
}

sub _valid_session {
    return _valid_ref_id($_[0]);
}

sub _require_session {
    my (%opt) = @_;
    my $s = $opt{session};
    _usage('no_session') unless defined $s && length $s;
    _usage('bad_session') unless _valid_session($s);
    return $s;
}

sub _acquire_session_lock {
    my ($session, %opt) = @_;
    my $almanac = _thread_store(%opt)->root;
    my $dir = "$almanac/thread";
    File::Path::make_path($dir) unless -d $dir;
    my $target = "$dir/.session-$session";
    my ($lock, $err) = Almanac::Lock->acquire($target, verb => 'thread-session');
    unless ($lock) {
        my $kind = (ref $err eq 'HASH') ? $err->{kind} : '';
        if ($kind eq 'timeout') {
            die Almanac::Store::Error->new(kind => 'lock_timeout', id => $session, path => $target,
                waited_ms => $err->{waited_ms}, timeout_ms => $err->{timeout_ms},
                holder_pid => undef, holder_host => undef);
        }
        die Almanac::Store::Error->new(kind => 'io', path => $target, errno => "lock_$kind");
    }
    return $lock;
}

sub _epoch_of {
    my ($iso) = @_;
    return undef unless defined $iso && $iso =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z$/;
    return eval { require Time::Local; Time::Local::timegm($6, $5, $4, $3, $2 - 1, $1) };
}

sub _fold_bytes {
    my ($s) = @_;
    return undef unless defined $s;
    my $v = "$s";
    if (utf8::is_utf8($v)) { $v = Encode::encode('UTF-8', $v) }
    $v =~ tr{\\}{/};
    return $v;
}

sub _doing_unlinked_tasks {
    my ($name, %opt) = @_;
    my $t = tasks($name, %opt);
    my @ids;
    for my $task (@$t) {
        next if $task->{linked};
        push @ids, $task->{id} if defined($task->{status}) && $task->{status} eq 'doing';
    }
    return \@ids;
}

sub _acquire_thread_lock {
    my ($name, %opt) = @_;
    _usage('bad_name') unless valid_name($name);
    my $almanac = _thread_store(%opt)->root;
    my $dir = "$almanac/thread";
    File::Path::make_path($dir) unless -d $dir;
    my $target = "$dir/$name.thread";
    my ($lock, $err) = Almanac::Lock->acquire($target, verb => 'thread');
    unless ($lock) {
        my $kind = (ref $err eq 'HASH') ? $err->{kind} : '';
        if ($kind eq 'timeout') {
            die Almanac::Store::Error->new(kind => 'lock_timeout', id => $name, path => $target,
                waited_ms => $err->{waited_ms}, timeout_ms => $err->{timeout_ms},
                holder_pid => undef, holder_host => undef);
        }
        die Almanac::Store::Error->new(kind => 'io', path => $target, errno => "lock_$kind");
    }
    return $lock;
}

# ---------------------------------------------------------------------------
# shaping
# ---------------------------------------------------------------------------
sub _thread_hash {
    my ($rec) = @_;
    my $f = $rec->{fields};
    my @bp = (defined $f->{blueprints} && length $f->{blueprints}) ? split(/,/, $f->{blueprints}) : ();
    return {
        name => $rec->{id}, state => $f->{state}, owner_kind => $f->{owner_kind},
        owner_id => $f->{owner_id}, created => $f->{created},
        blueprints => \@bp, archived_at => $f->{archived_at},
        owner_transcript => $f->{owner_transcript}, attached_at => $f->{attached_at},
        path => $rec->{path}, rev => $rec->{rev},
    };
}

sub _task_hash {
    my ($rec, %opt) = @_;
    my $f = $rec->{fields};
    my $linked = defined $f->{link} ? 1 : 0;
    my ($status, $location);
    if ($linked) {
        my $root = $opt{_proot};
        $root = project_root(%opt) unless defined $root;
        my $r = Almanac::PackageLink::resolve($f->{link}, root => $root);
        if ($r->{state} eq 'ok') { $status = $r->{status}; $location = $r->{location}; }
        else                     { $status = 'missing';    $location = undef; }
    } else {
        $status   = $f->{status};
        $location = undef;
    }
    return {
        id => $rec->{id}, thread => $opt{_thread_name}, position => undef,
        rank => $rec->{rank}, title => $f->{title}, body => $rec->{body},
        linked => $linked, link => $f->{link}, status => $status, location => $location,
        blocked_on => $f->{blocked_on}, from_todo => $f->{from_todo},
        path => $rec->{path}, rev => $rec->{rev},
    };
}

# ---------------------------------------------------------------------------
# reads
# ---------------------------------------------------------------------------
sub read_thread {
    my ($name, %opt) = @_;
    _usage('missing_name') unless defined $name && length $name;
    my $store = _thread_store(%opt);
    my $rec = $store->read($name);
    return _thread_hash($rec);
}

sub list_threads {
    my (%opt) = @_;
    my $archived = $opt{archived} ? 1 : 0;
    my $store = _thread_store(%opt);
    my $list = $store->list();
    my @out;
    for my $rec (@$list) {
        my $h = _thread_hash($rec);
        next if !$archived && $h->{state} eq 'archived';
        push @out, $h;
    }
    @out = sort { $a->{name} cmp $b->{name} } @out;
    return \@out;
}

sub tasks {
    my ($name, %opt) = @_;
    my $store = _tasks_store($name, %opt);
    my $list = $store->list();
    my $proot = project_root(%opt);
    my @out;
    my $pos = 0;
    for my $rec (@$list) {
        $pos++;
        my $t = _task_hash($rec, %opt, _thread_name => $name, _proot => $proot);
        $t->{position} = $pos;
        push @out, $t;
    }
    return \@out;
}

sub log_entries {
    my ($name, %opt) = @_;
    my $store = _log_store($name, %opt);
    my $list = $store->list();
    my @out;
    for my $rec (@$list) {
        my $f = $rec->{fields};
        push @out, {
            id => $rec->{id}, at => $f->{at}, session => $f->{session}, actor => $f->{actor},
            event => $f->{event}, task => $f->{task}, from => $f->{from}, to => $f->{to},
            reason => $f->{reason},
        };
    }
    return \@out;
}

sub is_done_task {
    my ($task) = @_;
    return 0 unless ref $task eq 'HASH';
    if ($task->{linked}) {
        return 0 if !defined $task->{status} || $task->{status} eq 'missing';
        return Almanac::PackageLink::is_delivered($task->{status});
    } else {
        my $s = $task->{status};
        return (defined $s && ($s eq 'done' || $s eq 'obsoleted')) ? 1 : 0;
    }
}

sub thread_is_done {
    my ($name, %opt) = @_;
    my $t = tasks($name, %opt);
    return 0 unless @$t;
    for my $task (@$t) {
        return 0 unless is_done_task($task);
    }
    return 1;
}

sub owned_by_session {
    my (%opt) = @_;
    my @out;
    my $ok = eval {
        my $session = $opt{session};
        die "no session\n" unless defined $session && length $session;
        my $list = list_threads(%opt, archived => 0);
        for my $h (@$list) {
            next unless defined($h->{owner_kind}) && $h->{owner_kind} eq 'session'
                     && defined($h->{owner_id}) && $h->{owner_id} eq $session;
            push @out, $h->{name};
        }
        1;
    };
    return $ok ? @out : ();
}

# attached_thread(session => $S, root|cwd, home) -> $name | undef
#
# Names of threads with state eq 'live', owner_kind eq 'session', owner_id eq
# $S, sorted by name; returns the first or undef. Wrapped in eval: any error
# -> undef. NEVER dies.
sub attached_thread {
    my (%opt) = @_;
    my $result = eval {
        my $session = $opt{session};
        return undef unless defined $session && length $session;
        my $list = list_threads(%opt, archived => 0);
        my @names;
        for my $h (@$list) {
            next unless defined($h->{state}) && $h->{state} eq 'live'
                     && defined($h->{owner_kind}) && $h->{owner_kind} eq 'session'
                     && defined($h->{owner_id}) && $h->{owner_id} eq $session;
            push @names, $h->{name};
        }
        return undef unless @names;
        @names = sort @names;
        return $names[0];
    };
    return $@ ? undef : $result;
}

# owner_status(\%thread, %opt) -> { status, kind, id, verdict }. NEVER dies,
# never writes.
sub owner_status {
    my ($thread, %opt) = @_;
    my $result = eval {
        if (defined($thread->{state}) && $thread->{state} eq 'archived') {
            return { status => 'archived', kind => $thread->{owner_kind}, id => $thread->{owner_id}, verdict => undef };
        }
        if (defined($thread->{state}) && $thread->{state} eq 'handed-off') {
            return { status => 'unowned', kind => $thread->{owner_kind}, id => $thread->{owner_id}, verdict => undef };
        }
        my $kind = $thread->{owner_kind};
        my $id   = $thread->{owner_id};
        if (!defined($kind) || $kind eq 'none') {
            return { status => 'unowned', kind => $kind, id => $id, verdict => undef };
        }
        if ($kind eq 'orchestrator') {
            my $root = project_root(%opt);
            my $live = Almanac::SessionLive::orchestrator_live(root => $root, blueprint => $id);
            return { status => ($live ? 'live' : 'dead'), kind => $kind, id => $id, verdict => undef };
        }
        if ($kind eq 'session') {
            my $since = _epoch_of($thread->{attached_at});
            $since = _epoch_of($thread->{created}) unless defined $since;
            my $v = Almanac::SessionLive::judge(session => $id,
                transcript_path => $thread->{owner_transcript}, since => $since);
            my $status = ($v->{state} eq 'dead') ? 'dead' : 'live';
            return { status => $status, kind => $kind, id => $id, verdict => $v };
        }
        return { status => 'live', kind => $kind, id => $id, verdict => undef };
    };
    if ($@) {
        return { status => 'live', kind => $thread->{owner_kind}, id => $thread->{owner_id}, verdict => undef };
    }
    return $result;
}

# attach($name, session => S, transcript => P, root|cwd, home, actor) ->
# (\%thread, $changed)
sub attach {
    my ($name, %opt) = @_;
    _usage('missing_name') unless defined $name && length $name;
    my $session = _require_session(%opt);
    my $actor = defined $opt{actor} ? $opt{actor} : 'session';
    _check_actor(%opt, actor => $actor);

    my $slock = _acquire_session_lock($session, %opt);
    my ($thread, $changed);
    my $ok = eval {
        my $tlock = _acquire_thread_lock($name, %opt);
        my $ok2 = eval {
            my $tstore = _thread_store(%opt);
            my $trec = $tstore->read($name);
            _refused('thread_archived', $trec->{path}) if $trec->{fields}{state} eq 'archived';

            my $mine = attached_thread(session => $session, %opt);
            if (defined $mine && $mine eq $name) {
                $thread = _thread_hash($trec); $changed = 0; return 1;
            }
            if (defined $mine) {
                _refused('already_attached', $trec->{path}, $mine);
            }

            my $th = _thread_hash($trec);
            my $os = owner_status($th, %opt);
            if ($os->{status} eq 'live') {
                _refused('owner_live', $trec->{path}, "$os->{kind}:$os->{id}");
            }
            if ($os->{status} eq 'dead') {
                _refused('owner_dead', $trec->{path}, "$os->{kind}:$os->{id}");
            }

            my %set = (owner_kind => 'session', owner_id => $session, attached_at => _now_iso(),
                state => 'live');
            $set{owner_transcript} = _fold_bytes($opt{transcript}) if defined $opt{transcript} && length $opt{transcript};
            my %expect = (rev => $trec->{rev}, fields => $trec->{fields});
            $tstore->update($name, expect => \%expect, set => \%set);
            $Almanac::Thread::WRITES++;
            _append_log($name, 'attached', %opt, session => $session, actor => $actor);
            _archive_check($name, %opt);
            $thread = _thread_hash($tstore->read($name));
            $changed = 1;
            1;
        };
        my $e2 = $@;
        $tlock->release;
        die $e2 unless $ok2;
        1;
    };
    my $err = $@;
    $slock->release;
    die $err unless $ok;
    return ($thread, $changed);
}

# detach($name|undef, session => S, reason => r, ...) -> (\%thread, $changed)
sub detach {
    my ($name, %opt) = @_;
    my $session = _require_session(%opt);
    my $actor = defined $opt{actor} ? $opt{actor} : 'session';
    _check_actor(%opt, actor => $actor);
    my $reason = check_reason($opt{reason});

    unless (defined $name && length $name) {
        $name = attached_thread(session => $session, %opt);
        unless (defined $name) {
            my $almanac = _thread_store(%opt)->root;
            _refused('not_attached', "$almanac/thread");
        }
    }

    my $slock = _acquire_session_lock($session, %opt);
    my ($thread, $changed);
    my $ok = eval {
        my $tlock = _acquire_thread_lock($name, %opt);
        my $ok2 = eval {
            my $tstore = _thread_store(%opt);
            my $trec = $tstore->read($name);
            _refused('thread_archived', $trec->{path}) if $trec->{fields}{state} eq 'archived';

            my $owned = ($trec->{fields}{state} eq 'live'
                      && defined($trec->{fields}{owner_kind}) && $trec->{fields}{owner_kind} eq 'session'
                      && defined($trec->{fields}{owner_id}) && $trec->{fields}{owner_id} eq $session);
            unless ($owned) {
                my $k = defined $trec->{fields}{owner_kind} ? $trec->{fields}{owner_kind} : 'none';
                my $i = defined $trec->{fields}{owner_id}   ? $trec->{fields}{owner_id}   : '-';
                _refused('not_owner', $trec->{path}, "$k:$i");
            }

            my $doing = _doing_unlinked_tasks($name, %opt);
            _refused('task_doing', $trec->{path}, join(',', @$doing)) if @$doing;

            my %set = (owner_kind => 'none', owner_id => '-');
            my @unset = qw(owner_transcript attached_at);
            my %expect = (rev => $trec->{rev}, fields => $trec->{fields});
            $tstore->update($name, expect => \%expect, set => \%set, unset => \@unset);
            $Almanac::Thread::WRITES++;
            my %logopt = %opt;
            if (defined $reason) { $logopt{reason} = $reason } else { delete $logopt{reason} }
            _append_log($name, 'detached', %logopt, session => $session, actor => $actor);
            _archive_check($name, %opt);
            $thread = _thread_hash($tstore->read($name));
            $changed = 1;
            1;
        };
        my $e2 = $@;
        $tlock->release;
        die $e2 unless $ok2;
        1;
    };
    my $err = $@;
    $slock->release;
    die $err unless $ok;
    return ($thread, $changed);
}

# switch_thread($name, session => S, transcript => P, ...) -> (\%thread, $changed, $left)
sub switch_thread {
    my ($name, %opt) = @_;
    _usage('missing_name') unless defined $name && length $name;
    my $session = _require_session(%opt);
    my $actor = defined $opt{actor} ? $opt{actor} : 'session';
    _check_actor(%opt, actor => $actor);

    my $current = attached_thread(session => $session, %opt);
    unless (defined $current) {
        my ($thread, $changed) = attach($name, %opt);
        return ($thread, $changed, undef);
    }
    if ($current eq $name) {
        my $trec = _thread_store(%opt)->read($name);
        return (_thread_hash($trec), 0, undef);
    }

    my @ordered = sort ($current, $name);
    my $slock = _acquire_session_lock($session, %opt);
    my ($thread, $changed, $left);
    my $ok = eval {
        my %locks;
        my $ok_locks = eval {
            for my $n (@ordered) { $locks{$n} = _acquire_thread_lock($n, %opt) }
            1;
        };
        unless ($ok_locks) {
            my $le = $@;
            $locks{$_}->release for grep { defined $locks{$_} } keys %locks;
            die $le;
        }
        my $ok2 = eval {
            my $tstore = _thread_store(%opt);
            my $xrec = $tstore->read($current);
            _refused('thread_archived', $xrec->{path}) if $xrec->{fields}{state} eq 'archived';
            my $owned = ($xrec->{fields}{state} eq 'live'
                      && defined($xrec->{fields}{owner_kind}) && $xrec->{fields}{owner_kind} eq 'session'
                      && defined($xrec->{fields}{owner_id}) && $xrec->{fields}{owner_id} eq $session);
            unless ($owned) {
                my $k = defined $xrec->{fields}{owner_kind} ? $xrec->{fields}{owner_kind} : 'none';
                my $i = defined $xrec->{fields}{owner_id}   ? $xrec->{fields}{owner_id}   : '-';
                _refused('not_owner', $xrec->{path}, "$k:$i");
            }
            my $doing = _doing_unlinked_tasks($current, %opt);
            _refused('task_doing', $xrec->{path}, join(',', @$doing)) if @$doing;

            my $yrec = $tstore->read($name);
            _refused('thread_archived', $yrec->{path}) if $yrec->{fields}{state} eq 'archived';
            my $yh = _thread_hash($yrec);
            my $os = owner_status($yh, %opt);
            if ($os->{status} eq 'live') { _refused('owner_live', $yrec->{path}, "$os->{kind}:$os->{id}") }
            if ($os->{status} eq 'dead') { _refused('owner_dead', $yrec->{path}, "$os->{kind}:$os->{id}") }

            my %xexpect = (rev => $xrec->{rev}, fields => $xrec->{fields});
            $tstore->update($current, expect => \%xexpect, set => { owner_kind => 'none', owner_id => '-' },
                unset => [qw(owner_transcript attached_at)]);
            $Almanac::Thread::WRITES++;
            _append_log($current, 'detached', %opt, session => $session, actor => $actor);
            _archive_check($current, %opt);

            my %set = (owner_kind => 'session', owner_id => $session, attached_at => _now_iso(),
                state => 'live');
            $set{owner_transcript} = _fold_bytes($opt{transcript}) if defined $opt{transcript} && length $opt{transcript};
            my %yexpect = (rev => $yrec->{rev}, fields => $yrec->{fields});
            $tstore->update($name, expect => \%yexpect, set => \%set);
            $Almanac::Thread::WRITES++;
            _append_log($name, 'attached', %opt, session => $session, actor => $actor);
            _archive_check($name, %opt);

            $thread = _thread_hash($tstore->read($name));
            $changed = 1;
            $left = $current;
            1;
        };
        my $e2 = $@;
        $locks{$_}->release for keys %locks;
        die $e2 unless $ok2;
        1;
    };
    my $err = $@;
    $slock->release;
    die $err unless $ok;
    return ($thread, $changed, $left);
}

# take_over($name, session => S, reason => r, transcript => P, ...) -> (\%thread, $changed)
sub take_over {
    my ($name, %opt) = @_;
    _usage('missing_name') unless defined $name && length $name;
    my $session = _require_session(%opt);
    my $actor = defined $opt{actor} ? $opt{actor} : 'session';
    _check_actor(%opt, actor => $actor);
    my $reason = check_reason($opt{reason});

    my $slock = _acquire_session_lock($session, %opt);
    my ($thread, $changed);
    my $ok = eval {
        my $tlock = _acquire_thread_lock($name, %opt);
        my $ok2 = eval {
            my $tstore = _thread_store(%opt);
            my $trec = $tstore->read($name);
            _refused('thread_archived', $trec->{path}) if $trec->{fields}{state} eq 'archived';

            my $owned_by_me = ($trec->{fields}{state} eq 'live'
                      && defined($trec->{fields}{owner_kind}) && $trec->{fields}{owner_kind} eq 'session'
                      && defined($trec->{fields}{owner_id}) && $trec->{fields}{owner_id} eq $session);
            if ($owned_by_me) {
                $thread = _thread_hash($trec); $changed = 0; return 1;
            }

            my $mine = attached_thread(session => $session, %opt);
            if (defined $mine) {
                _refused('already_attached', $trec->{path}, $mine);
            }

            my $th = _thread_hash($trec);
            my $os = owner_status($th, %opt);
            if ($os->{status} eq 'unowned') {
                _refused('not_owned', $trec->{path}, '-');
            }
            if ($os->{status} eq 'live') {
                _refused('owner_live', $trec->{path}, "$os->{kind}:$os->{id}");
            }

            my $from = "$os->{kind}:$os->{id}";
            my %set = (owner_kind => 'session', owner_id => $session, attached_at => _now_iso());
            $set{owner_transcript} = _fold_bytes($opt{transcript}) if defined $opt{transcript} && length $opt{transcript};
            my %expect = (rev => $trec->{rev}, fields => $trec->{fields});
            $tstore->update($name, expect => \%expect, set => \%set);
            $Almanac::Thread::WRITES++;
            my %logopt = %opt;
            if (defined $reason) { $logopt{reason} = $reason } else { delete $logopt{reason} }
            _append_log($name, 'taken-over', %logopt, session => $session, actor => $actor,
                from => $from, to => "session:$session");
            _archive_check($name, %opt);
            $thread = _thread_hash($tstore->read($name));
            $changed = 1;
            1;
        };
        my $e2 = $@;
        $tlock->release;
        die $e2 unless $ok2;
        1;
    };
    my $err = $@;
    $slock->release;
    die $err unless $ok;
    return ($thread, $changed);
}

# reattach(session => N, transcript => T_N, source => $src, root|cwd, home)
# -> \%r. NEVER dies: any error inside -> { result => 'error', error => <kind> }.
sub reattach {
    my (%opt) = @_;
    my $final;
    my $outer_ok = eval {
        my $n = $opt{session};
        unless (defined $n && _valid_ref_id($n)) {
            $final = { result => 'skipped', reason => 'bad_session' };
            return 1;
        }
        my %accepted = map { $_ => 1 } qw(clear compact resume arm-on-entry);
        my $src_raw = $opt{source};
        my $src = (defined $src_raw && $accepted{$src_raw}) ? $src_raw : 'startup';
        if ($src eq 'startup') {
            $final = { result => 'skipped', reason => 'startup' };
            return 1;
        }

        my $tstore_root = _thread_store(%opt)->root;
        my $tdir = "$tstore_root/thread";
        unless (-d $tdir) { $final = { result => 'none' }; return 1; }

        my $already = attached_thread(session => $n, %opt);
        if (defined $already) { $final = { result => 'already', thread => $already }; return 1; }

        my $tn = $opt{transcript};
        unless (defined $tn && length $tn) { $final = { result => 'none' }; return 1; }
        (my $tn_bytes = $tn) =~ s{\\}{/}g;
        (my $dir = $tn_bytes) =~ s{/[^/]+\z}{};
        unless (length($dir) && -d $dir) { $final = { result => 'none' }; return 1; }
        (my $tn_base = $tn_bytes) =~ s{.*/}{};

        opendir(my $dh, $dir) or do { $final = { result => 'none' }; return 1; };
        my @files = grep { $_ ne '.' && $_ ne '..' && /\.jsonl\z/ && -f "$dir/$_" } readdir($dh);
        closedir $dh;
        @files = grep { $_ ne $tn_base } @files;
        unless (@files) { $final = { result => 'none' }; return 1; }
        my @sorted = sort {
            (stat("$dir/$b"))[9] <=> (stat("$dir/$a"))[9]
                || $b cmp $a
        } @files;
        my $pred_file = $sorted[0];
        (my $p = $pred_file) =~ s/\.jsonl\z//;

        # Decision 35 / M2: a bare "newest other transcript in the project
        # dir" is not evidence that $pred_file is actually N's predecessor
        # -- it is just as likely to be an unrelated idle session (reviewer
        # M2 repro) or, for arm-on-entry, ANY other dead session in the
        # project, re-adopted on every director call. Require proximity:
        # P's transcript file and N's transcript file must have been
        # CREATED within REATTACH_PROXIMITY_SECONDS of each other. A real
        # clear/compact/resume creates N's transcript immediately after P's
        # (same moment, by construction), so their creation times (stat
        # index 10 -- on this host's Windows/NTFS perl this is the file's
        # creation time, NOT an inode change time, and survives utime()
        # unlike mtime) are always close. An unrelated idle session's
        # transcript was created whenever THAT session started, which is
        # not close to when N's transcript was created. mtime is
        # deliberately not used here: mtime reflects LAST write, which for
        # a legitimately dead (hard-killed, discovered hours later)
        # predecessor is expected to be far in the past -- that is what
        # makes it dead, and penalizing it on this axis would make the
        # a-predecessor-can-be-dead-for-hours case (DC4) unreachable.
        my $pred_ctime = (stat("$dir/$pred_file"))[10];
        my $n_ctime = (stat($tn))[10];
        unless (defined $pred_ctime && defined $n_ctime
            && abs($pred_ctime - $n_ctime) <= $REATTACH_PROXIMITY_SECONDS) {
            $final = { result => 'none' };
            return 1;
        }

        my $list = list_threads(%opt, archived => 0);
        my @candidates = grep {
            defined($_->{state}) && $_->{state} eq 'live'
                && defined($_->{owner_kind}) && $_->{owner_kind} eq 'session'
                && defined($_->{owner_id}) && $_->{owner_id} eq $p
        } @$list;
        unless (@candidates) { $final = { result => 'none' }; return 1; }
        if (@candidates > 1) { $final = { result => 'ambiguous' }; return 1; }
        my $x_name = $candidates[0]{name};

        my $x_full = read_thread($x_name, %opt);

        # Decision 35 / M2 (b): when the thread already records an
        # owner_transcript (the normal case for a real session that
        # attached through a ticket carrying a real transcript_path), it
        # must literally equal P's transcript path. A thread with no
        # recorded owner_transcript (never set, e.g. a ticket-mode caller
        # that supplied none) cannot be cross-checked this way -- proximity
        # above is the only signal available for it, so this check is
        # skipped rather than treated as a mismatch.
        if (defined($x_full->{owner_transcript}) && length($x_full->{owner_transcript})) {
            my $expect = _fold_bytes("$dir/$pred_file");
            unless ($x_full->{owner_transcript} eq $expect) {
                $final = { result => 'none' };
                return 1;
            }
        }

        my $os = owner_status($x_full, %opt);
        if ($os->{status} eq 'live') {
            $final = { result => 'owner_live', thread => $x_name, owner => $p };
            return 1;
        }

        my $slock = _acquire_session_lock($n, %opt);
        my $lock_ok = eval {
            my $tlock = _acquire_thread_lock($x_name, %opt);
            my $ok2 = eval {
                my $already2 = attached_thread(session => $n, %opt);
                if (defined $already2) { $final = { result => 'already', thread => $already2 }; return 1; }

                my $tstore = _thread_store(%opt);
                my $trec = $tstore->read($x_name);
                if (!defined($trec->{fields}{state}) || $trec->{fields}{state} ne 'live'
                    || !defined($trec->{fields}{owner_kind}) || $trec->{fields}{owner_kind} ne 'session'
                    || !defined($trec->{fields}{owner_id}) || $trec->{fields}{owner_id} ne $p) {
                    $final = { result => 'none' }; return 1;
                }
                my $th2 = _thread_hash($trec);
                my $os2 = owner_status($th2, %opt);
                if ($os2->{status} eq 'live') {
                    $final = { result => 'owner_live', thread => $x_name, owner => $p };
                    return 1;
                }
                my %set = (owner_kind => 'session', owner_id => $n, attached_at => _now_iso());
                $set{owner_transcript} = _fold_bytes($tn) if defined $tn && length $tn;
                my %expect = (rev => $trec->{rev}, fields => $trec->{fields});
                # Write-ahead (pkg03 redteam S5): reattach runs inside a
                # time-boxed hook that can be killed. Logging AFTER the owner
                # update left a window where ownership changed with no audit
                # entry at all. Logged first, a kill in between leaves an
                # entry whose change did not land -- visible (owner_id still
                # disagrees with the log) and self-healing, since the next
                # reattach finds the same dead owner and redoes it.
                _append_log($x_name, 'taken-over', root => $opt{root}, home => $opt{home}, cwd => $opt{cwd},
                    session => $n, actor => 'session', from => "session:$p", to => "session:$n",
                    reason => "re-attached after $src");
                $tstore->update($x_name, expect => \%expect, set => \%set);
                $Almanac::Thread::WRITES++;
                _archive_check($x_name, root => $opt{root}, home => $opt{home}, cwd => $opt{cwd});
                $final = { result => 'attached', thread => $x_name, from => $p };
                1;
            };
            my $e2 = $@;
            $tlock->release;
            die $e2 unless $ok2;
            1;
        };
        my $lerr = $@;
        $slock->release;
        die $lerr unless $lock_ok;
        1;
    };
    unless ($outer_ok) {
        my $err = $@;
        my $kind = (ref($err) eq 'Almanac::Store::Error' || ref($err) eq 'Almanac::Record::Error')
            ? (defined $err->{kind} ? $err->{kind} : 'error') : 'error';
        return { result => 'error', error => $kind };
    }
    return $final;
}

# ---------------------------------------------------------------------------
# the CLI gate (spec 2.6)
# ---------------------------------------------------------------------------
my %GATE_MESSAGES = (
    subagent_writer   => 'refused -- a subagent may not write a thread; only the main session does. Nothing was written.',
    no_ticket         => "refused -- no hook ticket for this exact command. Thread writes need the calling session's identity, which only butler's PreToolUse hook supplies: run it from a Claude Code session's main thread with butler enabled, every argument written literally (no \$variables). Nothing was written.",
    ambiguous_ticket  => 'refused -- two callers issued this exact command at once, so the caller cannot be identified. Retry. Nothing was written.',
    bad_ticket        => 'refused -- the hook ticket for this command names no valid session. Nothing was written.',
    butler_unloadable => 'refused -- butler is installed but its BpHook.pm could not be loaded. Nothing was written.',
    session_mismatch  => 'refused -- --session names a different session than the one running this command. Nothing was written.',
    fleet_worker_writer => 'refused -- a fleet worker (coordinator or judge) may not write a thread; the orchestrator owns the fleet thread. Nothing was written.',
    reporter_writer   => 'refused -- a reporter-role session is read-only and may not write a thread. Nothing was written.',
);

sub gate_message {
    my ($detail) = @_;
    return defined($detail) && exists $GATE_MESSAGES{$detail} ? $GATE_MESSAGES{$detail} : "refused -- $detail";
}

# cli_gate($ticket_name, \@argv_raw) -> \%g. Dies Almanac::Store::Error (kind
# refused) on every refusal.
sub cli_gate {
    my ($ticket_name, $argv_raw) = @_;

    unless (Almanac::SessionLive::butler_present()) {
        return { mode => 'butler_absent' };
    }

    unless (grep { m{(?:^|/)BpHook\.pm$} } keys %INC) {
        my $bphook_path = Almanac::SessionLive::butler_bphook_path();
        my $ok = eval { require $bphook_path; 1 };
        _refused('butler_unloadable', undef) unless $ok;
    }

    my $t = eval { BpHook::take_ticket($ticket_name, $argv_raw) };
    if (!ref($t) && defined $t && $t eq 'ambiguous') {
        _refused('ambiguous_ticket', undef);
    }
    if (ref($t) ne 'HASH') {
        _refused('no_ticket', undef);
    }

    my $sid = $t->{session_id};
    unless (defined $sid && !ref($sid) && $sid =~ /\A[A-Za-z0-9_-]{1,128}\z/) {
        _refused('bad_ticket', undef);
    }

    my $aid = $t->{agent_id};
    if (defined $aid && !ref($aid) && $aid ne '') {
        _refused('subagent_writer', undef, $aid);
    }

    # Role (todos 20261002-113836-620a0000, 20261002-093433-aa780000). A
    # headless fleet worker (BP_LEDGER in its environment, which this
    # process inherits from the worker's Bash tool) has no agent_id, so it
    # passed the check above as a main session; the orchestrator writes the
    # fleet thread through Almanac::Thread directly, never through this CLI,
    # so no worker needs it. A reporter-role session is read-only by its
    # skill's own contract ("never attaches to or writes" a thread), and
    # --role reporter is what skips the attach requirement on arming.
    my $role = eval { BpHook::role({ session_id => $sid }) };
    if (defined $role && ($role eq 'coordinator' || $role eq 'judge')) {
        _refused('fleet_worker_writer', undef, $role);
    }
    if (defined $role && $role eq 'reporter') {
        _refused('reporter_writer', undef);
    }

    return { mode => 'ticket', session => $sid, transcript_path => _fold_bytes($t->{transcript_path}) };
}

sub check_refs {
    my (%opt) = @_;
    my $report = { type => 'thread' };

    my $tstore = eval { _thread_store(%opt) };
    if (my $err = $@) { $report->{project} = { available => 0, reason => _err_reason($err) }; return $report; }
    my $threads = eval { $tstore->list() };
    if (my $err = $@) { $report->{project} = { available => 0, reason => _err_reason($err) }; return $report; }

    my $LEGACY_INBOX_TYPE = 'decision';
    my $dstore = eval {
        my $si = Almanac::Store->open(scope => 'project', type => 'inbox',
            root => $opt{root}, home => $opt{home}, cwd => $opt{cwd});
        return $si if -d $si->dir;
        my $sl = Almanac::Store->open(scope => 'project', type => $LEGACY_INBOX_TYPE,
            root => $opt{root}, home => $opt{home}, cwd => $opt{cwd});
        return $sl if -d $sl->dir;
        return undef;
    };

    my @refs;
    for my $trec (@$threads) {
        my $name = $trec->{id};
        my $tlist = eval { _tasks_store($name, %opt)->list() };
        next if $@;
        for my $rec (@$tlist) {
            next if defined $rec->{fields}{link};
            my $target = $rec->{fields}{blocked_on};
            next unless defined $target && length $target;
            my $exists = $dstore ? eval { $dstore->exists($target) } : 0;
            push @refs, {
                task => "$name/$rec->{id}", thread => $name, field => 'blocked_on',
                target => $target, status => ($exists ? 'ok' : 'dangling'),
            };
        }
    }
    my @dangling = grep { $_->{status} eq 'dangling' } @refs;
    $report->{project} = { available => 1, reason => 'ok', refs => \@refs, dangling => \@dangling };
    return $report;
}

sub check_health {
    my (%opt) = @_;
    my $tstore = eval { _thread_store(%opt) };
    if (my $err = $@) { return { available => 0, reason => _err_reason($err) }; }
    my $threads = eval { $tstore->list() };
    if (my $err = $@) { return { available => 0, reason => _err_reason($err) }; }

    my $root = eval { project_root(%opt) };
    my @findings;
    for my $trec (@$threads) {
        my $name  = $trec->{id};
        my $state = $trec->{fields}{state};
        my $tlist = eval { _tasks_store($name, %opt)->list() };
        next if $@;
        for my $rec (@$tlist) {
            my $f = $rec->{fields};
            if (defined $f->{link}) {
                next if $state eq 'archived';
                my $r = Almanac::PackageLink::resolve($f->{link}, root => $root);
                if ($r->{state} eq 'missing') {
                    push @findings, { kind => 'link_missing', thread => $name, task => $rec->{id},
                        link => $f->{link}, status => 'missing', path => $rec->{path} };
                } elsif ($r->{state} eq 'invalid') {
                    # A link the grammar rejects can never resolve, so it blocks
                    # auto-archive forever; it used to be reported nowhere
                    # (pkg02 review S6).
                    push @findings, { kind => 'link_invalid', thread => $name, task => $rec->{id},
                        link => $f->{link}, status => 'invalid', path => $rec->{path} };
                } elsif ($r->{state} eq 'ok' && $r->{location} eq 'live' && $r->{status} eq 'parked') {
                    push @findings, { kind => 'link_parked', thread => $name, task => $rec->{id},
                        link => $f->{link}, status => 'parked', path => $rec->{path} };
                } elsif ($r->{state} eq 'ok' && $r->{location} eq 'live' && $r->{status} eq 'dropped') {
                    push @findings, { kind => 'link_dropped', thread => $name, task => $rec->{id},
                        link => $f->{link}, status => 'dropped', path => $rec->{path} };
                }
            } else {
                next unless $state eq 'archived';
                my $st = $f->{status};
                next if defined($st) && ($st eq 'done' || $st eq 'obsoleted');
                push @findings, { kind => 'archived_open_task', thread => $name, task => $rec->{id},
                    link => undef, status => (defined $st ? $st : '-'), path => $rec->{path} };
            }
        }
    }
    return { available => 1, reason => 'ok', findings => \@findings };
}

# ---------------------------------------------------------------------------
# log append (caller already holds the thread lock)
# ---------------------------------------------------------------------------
sub _next_log_id {
    my ($name, %opt) = @_;
    my $store = _log_store($name, %opt);
    my $ids = $store->ids;
    my $max = 0;
    for my $id (@$ids) {
        my $n = $id + 0;
        $max = $n if $n > $max;
    }
    return sprintf('%08d', $max + 1);
}

sub _append_log {
    my ($name, $event, %opt) = @_;
    my $session = (defined $opt{session} && length $opt{session}) ? $opt{session} : '-';
    my $actor   = defined $opt{actor} ? $opt{actor} : 'cli';
    my $store   = _log_store($name, %opt);
    my $id      = _next_log_id($name, %opt);
    my %fields  = (at => _now_iso(), session => $session, actor => $actor, event => $event);
    my @order   = qw(at session actor event);
    for my $k (qw(task from to reason)) {
        if (defined $opt{$k}) { $fields{$k} = $opt{$k}; push @order, $k; }
    }
    $store->create(id => $id, fields => \%fields, order => \@order);
    $Almanac::Thread::WRITES++;
}

sub _archive_check {
    my ($name, %opt) = @_;
    my $tstore = _thread_store(%opt);
    my $trec = eval { $tstore->read($name) };
    return if $@;
    return if $trec->{fields}{state} eq 'archived';
    return unless thread_is_done($name, %opt);
    my %expect = (rev => $trec->{rev}, fields => $trec->{fields});
    my $archived = eval {
        $tstore->update($name, expect => \%expect, set => { state => 'archived', archived_at => _now_iso() });
        $Almanac::Thread::WRITES++;
        1;
    };
    return unless $archived;   # lost a race or the store refused: nothing changed, nothing to log
    # The log append is its own step (redteam N1): the archive above has
    # already happened, so a failed append must not be swallowed together
    # with it -- that would leave an archived thread whose log never says so,
    # with no trace anywhere. Report it; the archive itself stands.
    unless (eval { _append_log($name, 'archived', %opt); 1 }) {
        my $why = _err_reason($@);
        warn "almanac thread: $name archived, but its 'archived' log entry could not be written ($why)\n";
    }
}

# ---------------------------------------------------------------------------
# writes
# ---------------------------------------------------------------------------
sub create_thread {
    my ($name, %opt) = @_;
    _usage('missing_name') unless defined $name && length $name;
    _check_actor(%opt);
    _usage('bad_name') unless valid_name($name);
    _usage('reserved_name') if $name =~ /\Alegacy-tasklist-/ && !$opt{_allow_reserved};

    my $owner_kind = defined $opt{owner_kind} ? $opt{owner_kind} : 'none';
    my $owner_id   = defined $opt{owner_id}   ? $opt{owner_id}   : '-';

    # Spec 2.5 "create_thread change": a session owner takes the session
    # lock first and, under it, defers to wherever that session is already
    # attached -- a session already attached elsewhere creates an UNOWNED
    # thread and stays where it is.
    my $slock;
    if ($owner_kind eq 'session' && defined $owner_id && length $owner_id && $owner_id ne '-') {
        $slock = _acquire_session_lock($owner_id, %opt);
        my $mine = eval { attached_thread(session => $owner_id, %opt) };
        if (defined $mine) {
            $owner_kind = 'none';
            $owner_id   = '-';
        }
    }

    my $lock = eval { _acquire_thread_lock($name, %opt) };
    unless ($lock) {
        my $lerr = $@;
        $slock->release if $slock;
        die $lerr;
    }
    my $thread;
    my $ok = eval {
        my $store = _thread_store(%opt);
        if ($store->exists($name)) {
            die Almanac::Store::Error->new(kind => 'exists', id => $name, path => $store->dir . "/$name.md");
        }
        my %fields = (created => _now_iso(), state => 'live', owner_kind => $owner_kind, owner_id => $owner_id);
        my @order  = qw(created state owner_kind owner_id);
        if ($owner_kind eq 'session') {
            $fields{attached_at} = _now_iso();
            push @order, 'attached_at';
            if (defined $opt{owner_transcript} && length $opt{owner_transcript}) {
                $fields{owner_transcript} = _fold_bytes($opt{owner_transcript});
                push @order, 'owner_transcript';
            }
        }
        my $rec = $store->create(id => $name, fields => \%fields, order => \@order);
        $Almanac::Thread::WRITES++;
        _append_log($name, 'created', %opt);
        $thread = _thread_hash($rec);
        1;
    };
    my $err = $@;
    $lock->release;
    $slock->release if $slock;
    die $err unless $ok;
    return $thread;
}

sub add_task {
    my ($name, %opt) = @_;
    _usage('missing_name') unless defined $name && length $name;
    _check_actor(%opt);

    my $lock = _acquire_thread_lock($name, %opt);
    my $task;
    my $ok = eval {
        my $tstore = _thread_store(%opt);
        my $trec = $tstore->read($name);
        _refused('thread_archived', $trec->{path}) if $trec->{fields}{state} eq 'archived';

        my $has_link = exists $opt{link} && defined $opt{link} && length $opt{link};
        my $store = _tasks_store($name, %opt);
        my (%fields, @order, $title);

        if ($has_link) {
            my ($bp, $pkg) = Almanac::PackageLink::parse($opt{link});
            _usage('bad_link') unless defined $bp;
            my $root = project_root(%opt);
            my $r = Almanac::PackageLink::resolve($opt{link}, root => $root);
            _refused('link_missing', $trec->{path}) unless $r->{state} eq 'ok';
            my $existing = $store->list();
            my $want = Almanac::PackageLink::link_key($opt{link});
            for my $e (@$existing) {
                if (defined $e->{fields}{link} && Almanac::PackageLink::link_key($e->{fields}{link}) eq $want) {
                    _refused('link_exists', $trec->{path});
                }
            }
            _refused('linked_task_no_blocked_on', $trec->{path})
                if exists $opt{blocked_on} && defined $opt{blocked_on};
            $title = (exists $opt{title} && defined $opt{title} && length(_trim($opt{title})))
                   ? _trim($opt{title}) : $opt{link};
            _usage('bad_title') if $title =~ /[\r\n]/;
            %fields = (title => $title, created => _now_iso(), link => $opt{link});
            @order  = qw(title created link);
        } else {
            _usage('missing_title') unless exists $opt{title} && defined $opt{title};
            $title = _trim($opt{title});
            _usage('bad_title') if $title eq '' || $title =~ /[\r\n]/;
            %fields = (title => $title, created => _now_iso(), status => 'pending');
            @order  = qw(title created status);
            if (exists $opt{blocked_on} && defined $opt{blocked_on}) {
                _usage('bad_blocked_on') unless _valid_ref_id($opt{blocked_on});
                $fields{blocked_on} = $opt{blocked_on};
                push @order, 'blocked_on';
            }
        }
        if (exists $opt{from_todo} && defined $opt{from_todo}) {
            $fields{from_todo} = $opt{from_todo};
            push @order, 'from_todo';
        }

        my %args = (fields => \%fields, order => \@order);
        $args{id}   = $opt{id}   if exists $opt{id};
        $args{body} = $opt{body} if exists $opt{body};

        my $rec = $store->insert_last(%args);
        $Almanac::Thread::WRITES++;
        $task = _task_hash($rec, %opt, _thread_name => $name);
        _archive_check($name, %opt);
        1;
    };
    my $err = $@;
    $lock->release;
    die $err unless $ok;
    return $task;
}

sub edit_task {
    my ($name, $id, %opt) = @_;
    _check_actor(%opt);
    my $lock = _acquire_thread_lock($name, %opt);
    my ($task, $changed);
    my $ok = eval {
        my $tstore = _thread_store(%opt);
        my $trec = $tstore->read($name);
        _refused('thread_archived', $trec->{path}) if $trec->{fields}{state} eq 'archived';

        my $title_given   = exists $opt{title} && defined $opt{title};
        my $body_given    = exists $opt{body};
        my $blocked_given = exists $opt{blocked_on} && defined $opt{blocked_on};
        my $clear_given   = $opt{clear_blocked_on} ? 1 : 0;

        _usage('blocked_on_conflict') if $blocked_given && $clear_given;
        _usage('nothing_to_change') unless $title_given || $body_given || $blocked_given || $clear_given;

        my $store = _tasks_store($name, %opt);
        my $rec = $store->read($id);
        my $is_linked = defined $rec->{fields}{link};
        _refused('linked_task_no_blocked_on', $rec->{path}) if $is_linked && ($blocked_given || $clear_given);

        my %set;
        my @unset;
        if ($title_given) {
            my $t = _trim($opt{title});
            _usage('bad_title') if $t eq '' || $t =~ /[\r\n]/;
            $set{title} = $t unless defined($rec->{fields}{title}) && $rec->{fields}{title} eq $t;
        }
        if ($blocked_given) {
            _usage('bad_blocked_on') unless _valid_ref_id($opt{blocked_on});
            my $cur = $rec->{fields}{blocked_on};
            $set{blocked_on} = $opt{blocked_on} unless defined($cur) && $cur eq $opt{blocked_on};
        }
        if ($clear_given && exists $rec->{fields}{blocked_on}) {
            push @unset, 'blocked_on';
        }
        my $body_changed = 0;
        if ($body_given) {
            my $cur_body = defined $rec->{body} ? $rec->{body} : '';
            my $new_body = defined $opt{body}   ? $opt{body}   : '';
            $body_changed = ($cur_body ne $new_body) ? 1 : 0;
        }

        unless (%set || @unset || $body_changed) {
            $task = _task_hash($rec, %opt, _thread_name => $name);
            $changed = 0;
            return 1;
        }

        my %expect = (rev => $rec->{rev}, fields => $rec->{fields});
        my %args = (expect => \%expect, set => \%set, unset => \@unset);
        $args{body} = $opt{body} if $body_given;
        my $new = $store->update($id, %args);
        $Almanac::Thread::WRITES++;
        $changed = 1;
        $task = _task_hash($new, %opt, _thread_name => $name);
        _archive_check($name, %opt);
        1;
    };
    my $err = $@;
    $lock->release;
    die $err unless $ok;
    return ($task, $changed);
}

sub move_task {
    my ($name, $id, %opt) = @_;
    _check_actor(%opt);
    my $lock = _acquire_thread_lock($name, %opt);
    my ($task, $changed);
    my $ok = eval {
        my $tstore = _thread_store(%opt);
        my $trec = $tstore->read($name);
        _refused('thread_archived', $trec->{path}) if $trec->{fields}{state} eq 'archived';

        my $store = _tasks_store($name, %opt);
        my $list = $store->list();
        my ($cur) = grep { $_->{id} eq $id } @$list;
        $store->read($id) unless $cur;   # raises not_found

        my $where = defined $opt{where} ? $opt{where} : '';
        if ($where eq 'first') {
            if (@$list && $list->[0]{id} eq $id) {
                $task = _task_hash($cur, %opt, _thread_name => $name); $changed = 0; return 1;
            }
            my $first = $list->[0]{rank};
            my $new_rank = Almanac::Store::rank_between(undef, $first) . Almanac::Store::rank_jitter();
            my %expect = (rev => $cur->{rev}, fields => $cur->{fields});
            my $new = $store->update($id, expect => \%expect, rank => $new_rank);
            $Almanac::Thread::WRITES++; $changed = 1;
            $task = _task_hash($new, %opt, _thread_name => $name);
        }
        elsif ($where eq 'last') {
            if (@$list && $list->[-1]{id} eq $id) {
                $task = _task_hash($cur, %opt, _thread_name => $name); $changed = 0; return 1;
            }
            my @ranked = grep { defined $_->{rank} } @$list;
            my $last = @ranked ? $ranked[-1]{rank} : undef;
            my $new_rank = Almanac::Store::rank_between($last, undef) . Almanac::Store::rank_jitter();
            my %expect = (rev => $cur->{rev}, fields => $cur->{fields});
            my $new = $store->update($id, expect => \%expect, rank => $new_rank);
            $Almanac::Thread::WRITES++; $changed = 1;
            $task = _task_hash($new, %opt, _thread_name => $name);
        }
        elsif ($where eq 'before' || $where eq 'after') {
            my $ref_id = $opt{ref};
            _usage('bad_reference') if defined $ref_id && defined $id && $ref_id eq $id;
            my ($ref_pos) = grep { $list->[$_]{id} eq $ref_id } 0 .. $#$list;
            unless (defined $ref_pos) {
                die Almanac::Store::Error->new(kind => 'not_found', id => $ref_id,
                    path => $store->dir . "/" . (defined $ref_id ? $ref_id : '') . ".md");
            }
            my ($id_pos) = grep { $list->[$_]{id} eq $id } 0 .. $#$list;
            my $already = ($where eq 'before') ? (defined $id_pos && $id_pos == $ref_pos - 1)
                                                : (defined $id_pos && $id_pos == $ref_pos + 1);
            if ($already) {
                $task = _task_hash($cur, %opt, _thread_name => $name); $changed = 0; return 1;
            }
            my @others = grep { $_->{id} ne $id } @$list;
            my ($oidx) = grep { $others[$_]{id} eq $ref_id } 0 .. $#others;
            my ($lo, $hi);
            if ($where eq 'before') {
                $hi = $others[$oidx]{rank};
                $lo = $oidx > 0 ? $others[$oidx - 1]{rank} : undef;
            } else {
                $lo = $others[$oidx]{rank};
                $hi = ($oidx < $#others) ? $others[$oidx + 1]{rank} : undef;
            }
            my $new_rank = Almanac::Store::rank_between($lo, $hi) . Almanac::Store::rank_jitter();
            my %expect = (rev => $cur->{rev}, fields => $cur->{fields});
            my $new = $store->update($id, expect => \%expect, rank => $new_rank);
            $Almanac::Thread::WRITES++; $changed = 1;
            $task = _task_hash($new, %opt, _thread_name => $name);
        }
        else {
            _usage('bad_move');
        }
        _archive_check($name, %opt);
        1;
    };
    my $err = $@;
    $lock->release;
    die $err unless $ok;
    return ($task, $changed);
}

sub reorder_tasks {
    my ($name, $ids, %opt) = @_;
    _check_actor(%opt);
    my $lock = _acquire_thread_lock($name, %opt);
    my $result;
    my $ok = eval {
        my $tstore = _thread_store(%opt);
        my $trec = $tstore->read($name);
        _refused('thread_archived', $trec->{path}) if $trec->{fields}{state} eq 'archived';
        my $store = _tasks_store($name, %opt);
        my $records = $store->reorder($ids);
        $Almanac::Thread::WRITES++;
        $result = [ map { _task_hash($_, %opt, _thread_name => $name) } @$records ];
        my $pos = 0;
        $_->{position} = ++$pos for @$result;
        _archive_check($name, %opt);
        1;
    };
    my $err = $@;
    $lock->release;
    die $err unless $ok;
    return $result;
}

sub set_task_status {
    my ($name, $id, $status, %opt) = @_;
    _check_actor(%opt);
    _usage('bad_status') unless defined $status && $STATUS_OK{$status};
    my $lock = _acquire_thread_lock($name, %opt);
    my ($task, $changed);
    my $ok = eval {
        my $tstore = _thread_store(%opt);
        my $trec = $tstore->read($name);   # status IS allowed on an archived thread
        my $store = _tasks_store($name, %opt);
        my $rec = $store->read($id);
        _refused('linked_task_has_no_status', $rec->{path}) if defined $rec->{fields}{link};
        my $cur_status = $rec->{fields}{status};
        if (defined $cur_status && $cur_status eq $status) {
            $task = _task_hash($rec, %opt, _thread_name => $name); $changed = 0; return 1;
        }
        my %expect = (rev => $rec->{rev}, fields => $rec->{fields});
        my $new = $store->update($id, expect => \%expect, set => { status => $status });
        $Almanac::Thread::WRITES++;
        $task = _task_hash($new, %opt, _thread_name => $name);
        $changed = 1;
        _append_log($name, 'task-status', %opt, task => $id, from => $cur_status, to => $status);
        _archive_check($name, %opt);
        1;
    };
    my $err = $@;
    $lock->release;
    die $err unless $ok;
    return ($task, $changed);
}

sub add_packages {
    my ($name, $blueprints, %opt) = @_;
    _check_actor(%opt);
    my $lock = _acquire_thread_lock($name, %opt);
    my $added;
    my $ok = eval {
        my $tstore = _thread_store(%opt);
        my $trec = $tstore->read($name);
        _refused('thread_archived', $trec->{path}) if $trec->{fields}{state} eq 'archived';

        my (@bps, %seen);
        for my $bp (@$blueprints) {
            next if $seen{$bp}++;
            push @bps, $bp;
        }
        my $root = project_root(%opt);
        my %pkg_cache;
        for my $bp (@bps) {
            _usage('bad_blueprint')
                unless defined($bp) && length($bp) <= 128 && $bp =~ /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/ && $bp !~ /\.\./;
            my $pinfo = Almanac::PackageLink::package_ids($bp, root => $root);
            _refused('blueprint_not_found', $trec->{path}) unless defined $pinfo->{location};
            $pkg_cache{$bp} = $pinfo;
        }

        my $store = _tasks_store($name, %opt);
        my $existing = $store->list();
        my %have_links = map { (defined $_->{fields}{link} ? (Almanac::PackageLink::link_key($_->{fields}{link}) => 1) : ()) } @$existing;

        my @added_tasks;
        for my $bp (@bps) {
            for my $pkg (@{ $pkg_cache{$bp}{ids} }) {
                my $link = "$bp/$pkg";
                next if $have_links{ Almanac::PackageLink::link_key($link) };
                my $rec = $store->insert_last(fields => { title => $link, created => _now_iso(), link => $link },
                    order => [qw(title created link)]);
                $Almanac::Thread::WRITES++;
                $have_links{ Almanac::PackageLink::link_key($link) } = 1;
                push @added_tasks, _task_hash($rec, %opt, _thread_name => $name);
            }
        }

        my $cur_bp_field = $trec->{fields}{blueprints};
        my @cur_bps = (defined $cur_bp_field && length $cur_bp_field) ? split(/,/, $cur_bp_field) : ();
        my %bpset = map { $_ => 1 } @cur_bps;
        my $bp_changed = 0;
        for my $bp (@bps) {
            unless ($bpset{$bp}) { push @cur_bps, $bp; $bpset{$bp} = 1; $bp_changed = 1; }
        }
        if ($bp_changed) {
            my %expect = (rev => $trec->{rev}, fields => $trec->{fields});
            $tstore->update($name, expect => \%expect, set => { blueprints => join(',', @cur_bps) });
            $Almanac::Thread::WRITES++;
        }
        $added = \@added_tasks;
        # Per spec 2.4/behaviour 14/AC8: every write verb except create_thread/
        # archive/migrate_legacy runs the archive check, including
        # add-packages -- a package already done at add-packages time
        # archives the thread immediately as part of this same call.
        _archive_check($name, %opt);
        1;
    };
    my $err = $@;
    $lock->release;
    die $err unless $ok;
    return $added;
}

sub record_event {
    my ($name, $event, %opt) = @_;
    _check_actor(%opt);
    _usage('bad_event') unless defined $event && $EVENT_OK{$event};
    _usage('event_not_recordable') if $SIDE_EFFECT_ONLY{$event};
    my $reason = check_reason($opt{reason});
    _usage('reason_required') if $REASON_REQUIRED{$event} && !defined $reason;

    my $lock = _acquire_thread_lock($name, %opt);
    my $thread;
    my $ok = eval {
        my $tstore = _thread_store(%opt);
        my $trec = $tstore->read($name);
        my $is_archived = ($trec->{fields}{state} eq 'archived');
        _refused('thread_archived', $trec->{path}) if $is_archived && !$ARCHIVED_ALLOWED_EVENTS{$event};

        # Decision 35 / S3: the CLI 'event' path (almanac-thread.pl) passes
        # require_owner_session for a session-identified caller so that an
        # owner-relevant event (handed-off, taken-over, paused, resumed --
        # the ones that change who/what owns the thread, or whether it is
        # takeable) can only be recorded by the thread's current owner.
        # Without this, any main session could flip a live-owned thread to
        # handed-off, then attach it, routing around owner_live's refusal
        # and the take-over audit trail entirely. Library/orchestrator
        # callers never pass this opt, so they are unaffected (unchanged
        # from before this fix).
        if ($OWNER_GATED_EVENT_OK{$event} && defined $opt{require_owner_session}
            && length $opt{require_owner_session}) {
            my $caller = $opt{require_owner_session};
            my $owns = (defined($trec->{fields}{owner_kind}) && $trec->{fields}{owner_kind} eq 'session'
                     && defined($trec->{fields}{owner_id}) && $trec->{fields}{owner_id} eq $caller);
            unless ($owns) {
                my $k = defined $trec->{fields}{owner_kind} ? $trec->{fields}{owner_kind} : 'none';
                my $i = defined $trec->{fields}{owner_id}   ? $trec->{fields}{owner_id}   : '-';
                _refused('not_owner', $trec->{path}, "$k:$i");
            }
        }

        # require_no_doing (pkg04 review S3): the same gate detach applies,
        # taken here UNDER the thread lock. butler-continuity.pl's `off`
        # checked for a doing task with no lock before calling this, so a
        # task set doing in between was handed off mid-work. Opt-in, like
        # require_owner_session: existing callers are unaffected.
        if ($opt{require_no_doing}) {
            my $doing = _doing_unlinked_tasks($name, %opt);
            _refused('task_doing', $trec->{path}, join(',', @$doing)) if @$doing;
        }

        my %set;
        if ($event eq 'handed-off') { $set{state} = 'handed-off'; }
        elsif ($event eq 'taken-over' || $event eq 'attached' || $event eq 'resumed') { $set{state} = 'live'; }

        if (%set) {
            my %expect = (rev => $trec->{rev}, fields => $trec->{fields});
            $tstore->update($name, expect => \%expect, set => \%set);
            $Almanac::Thread::WRITES++;
        }
        my %logopt = %opt;
        if (defined $reason) { $logopt{reason} = $reason } else { delete $logopt{reason} }
        _append_log($name, $event, %logopt);
        _archive_check($name, %opt);
        $thread = _thread_hash($tstore->read($name));
        1;
    };
    my $err = $@;
    $lock->release;
    die $err unless $ok;
    return $thread;
}

sub archive {
    my ($name, %opt) = @_;
    _check_actor(%opt);
    my $reason = check_reason($opt{reason});
    my $lock = _acquire_thread_lock($name, %opt);
    my ($thread, $changed);
    my $ok = eval {
        my $tstore = _thread_store(%opt);
        my $trec = $tstore->read($name);
        if ($trec->{fields}{state} eq 'archived') {
            $thread = _thread_hash($trec); $changed = 0; return 1;
        }
        my %expect = (rev => $trec->{rev}, fields => $trec->{fields});
        my $new = $tstore->update($name, expect => \%expect, set => { state => 'archived', archived_at => _now_iso() });
        $Almanac::Thread::WRITES++;
        my %logopt = %opt;
        if (defined $reason) { $logopt{reason} = $reason } else { delete $logopt{reason} }
        _append_log($name, 'archived', %logopt);
        $thread = _thread_hash($new); $changed = 1;
        1;
    };
    my $err = $@;
    $lock->release;
    die $err unless $ok;
    return ($thread, $changed);
}

sub archive_if_done {
    my ($name, %opt) = @_;
    _check_actor(%opt);

    # Unlocked pre-check: the overwhelmingly common call (every almanac-
    # thread.pl verb runs this on every non-archived thread) is a genuine
    # no-op, and Almanac::Lock::acquire rewrites the .lock.holder sidecar on
    # every successful acquire even when nothing else changes -- which would
    # otherwise make an unrelated thread's lock churn on every single CLI
    # call (AC10 depends on a true no-op leaving <almanac> byte-identical).
    # Acquire the lock only when a transition looks possible; re-check under
    # it before writing, so a race is still resolved correctly.
    my $tstore0 = _thread_store(%opt);
    my $trec0 = $tstore0->read($name);
    return (_thread_hash($trec0), 0) if $trec0->{fields}{state} eq 'archived';
    return (_thread_hash($trec0), 0) unless thread_is_done($name, %opt);

    my $lock = _acquire_thread_lock($name, %opt);
    my ($thread, $changed);
    my $ok = eval {
        my $tstore = _thread_store(%opt);
        my $trec = $tstore->read($name);
        if ($trec->{fields}{state} eq 'archived') {
            $thread = _thread_hash($trec); $changed = 0; return 1;
        }
        if (thread_is_done($name, %opt)) {
            my %expect = (rev => $trec->{rev}, fields => $trec->{fields});
            my $new = $tstore->update($name, expect => \%expect, set => { state => 'archived', archived_at => _now_iso() });
            $Almanac::Thread::WRITES++;
            _append_log($name, 'archived', %opt);
            $thread = _thread_hash($new); $changed = 1;
        } else {
            $thread = _thread_hash($trec); $changed = 0;
        }
        1;
    };
    my $err = $@;
    $lock->release;
    die $err unless $ok;
    return ($thread, $changed);
}

# ---------------------------------------------------------------------------
# migration
# ---------------------------------------------------------------------------
sub _migrate_partition {
    my ($name, $list, %opt) = @_;
    my $tstore = _thread_store(%opt);
    unless ($tstore->exists($name)) {
        create_thread($name, %opt, owner_kind => 'none', owner_id => '-', actor => 'migration', _allow_reserved => 1);
    }
    my $lock = _acquire_thread_lock($name, %opt);
    my $ok = eval {
        my $store = _tasks_store($name, %opt);
        for my $rec (@$list) {
            if ($store->exists($rec->{id})) {
                # An earlier run copied this record and then failed to delete
                # the source (e.g. the CAS delete lost to a concurrent edit).
                # The source is authoritative: every thread verb is refused
                # (read-only ones only warn) while migration keeps failing,
                # so the copy cannot have been edited since, while the source
                # can. Bring the copy up to date before the delete below
                # removes the source, rather than silently dropping the edit
                # (pkg02 redteam N2).
                my $cur = $store->read($rec->{id});
                my (%set, @unset);
                for my $k (qw(title created status blocked_on)) {
                    my ($want, $have) = ($rec->{fields}{$k}, $cur->{fields}{$k});
                    if (defined $want) {
                        $set{$k} = $want unless defined $have && $have eq $want;
                    } elsif (defined $have) {
                        push @unset, $k;
                    }
                }
                my $want_body = defined $rec->{body} ? $rec->{body} : '';
                my $have_body = defined $cur->{body} ? $cur->{body} : '';
                my $body_diff = ($want_body ne $have_body) ? 1 : 0;
                if (%set || @unset || $body_diff) {
                    my %expect = (rev => $cur->{rev}, fields => $cur->{fields});
                    $store->update($rec->{id}, expect => \%expect, set => \%set, unset => \@unset,
                        ($body_diff ? (body => $want_body) : ()));
                    $Almanac::Thread::WRITES++;
                }
                next;
            }
            my %fields = (title => $rec->{fields}{title}, created => $rec->{fields}{created},
                          status => $rec->{fields}{status});
            my @order = qw(title created status);
            if (defined $rec->{fields}{blocked_on}) {
                $fields{blocked_on} = $rec->{fields}{blocked_on};
                push @order, 'blocked_on';
            }
            my %args = (id => $rec->{id}, fields => \%fields, order => \@order);
            $args{body} = $rec->{body} if defined $rec->{body};
            $store->insert_last(%args);
            $Almanac::Thread::WRITES++;
        }
        1;
    };
    my $err = $@;
    $lock->release;
    die $err unless $ok;
}

sub migrate_legacy {
    my (%opt) = @_;
    my $task_store  = Almanac::Store->open(scope => 'project', type => 'task',
        root => $opt{root}, home => $opt{home}, cwd => $opt{cwd});
    my $focus_store = Almanac::Store->open(scope => 'project', type => 'task-focus',
        root => $opt{root}, home => $opt{home}, cwd => $opt{cwd});
    my $task_ids  = $task_store->ids;
    my $focus_ids = $focus_store->ids;
    return { migrated => 0, done => 0, open => 0 } if !@$task_ids && !@$focus_ids;

    my $almanac = $task_store->root;
    my $thread_dir = "$almanac/thread";
    File::Path::make_path($thread_dir) unless -d $thread_dir;
    my $migrate_target = "$thread_dir/.migrate";
    my ($mlock, $mlock_err) = Almanac::Lock->acquire($migrate_target, verb => 'migrate');
    unless ($mlock) {
        my $kind = (ref $mlock_err eq 'HASH') ? $mlock_err->{kind} : '';
        if ($kind eq 'timeout') {
            die Almanac::Store::Error->new(kind => 'lock_timeout', id => undef, path => $migrate_target,
                waited_ms => $mlock_err->{waited_ms}, timeout_ms => $mlock_err->{timeout_ms});
        }
        die Almanac::Store::Error->new(kind => 'io', path => $migrate_target, errno => "lock_$kind");
    }

    my $result;
    my $ok = eval {
        $task_ids  = $task_store->ids;
        $focus_ids = $focus_store->ids;
        if (!@$task_ids && !@$focus_ids) {
            $result = { migrated => 0, done => 0, open => 0 };
            return 1;
        }

        my $list = $task_store->list();
        my (@closed, @open);
        for my $rec (@$list) {
            my $st = $rec->{fields}{status};
            if (defined $st && ($st eq 'done' || $st eq 'obsoleted')) { push @closed, $rec; }
            else { push @open, $rec; }
        }
        my $done_count = scalar @closed;
        my $open_count = scalar @open;

        _migrate_partition('legacy-tasklist-done', \@closed, %opt) if @closed;
        _migrate_partition('legacy-tasklist-open', \@open, %opt)   if @open;

        if (@closed) {
            my $tstore = _thread_store(%opt);
            my $trec = $tstore->read('legacy-tasklist-done');
            if ($trec->{fields}{state} ne 'archived') {
                my $lock2 = _acquire_thread_lock('legacy-tasklist-done', %opt);
                my $ok2 = eval {
                    my $trec2 = $tstore->read('legacy-tasklist-done');
                    unless ($trec2->{fields}{state} eq 'archived') {
                        my %expect = (rev => $trec2->{rev}, fields => $trec2->{fields});
                        $tstore->update('legacy-tasklist-done', expect => \%expect,
                            set => { state => 'archived', archived_at => _now_iso() });
                        $Almanac::Thread::WRITES++;
                        _append_log('legacy-tasklist-done', 'archived',
                            root => $opt{root}, home => $opt{home}, cwd => $opt{cwd},
                            actor => 'migration', reason => 'migrated from the flat tasklist');
                    }
                    1;
                };
                my $e2 = $@; $lock2->release; die $e2 unless $ok2;
            }
        }
        if (@open) {
            my $tstore = _thread_store(%opt);
            my $trec = $tstore->read('legacy-tasklist-open');
            if ($trec->{fields}{state} eq 'live' && $trec->{fields}{owner_kind} eq 'none') {
                my $lock2 = _acquire_thread_lock('legacy-tasklist-open', %opt);
                my $ok2 = eval {
                    my $trec2 = $tstore->read('legacy-tasklist-open');
                    if ($trec2->{fields}{state} eq 'live' && $trec2->{fields}{owner_kind} eq 'none') {
                        my %expect = (rev => $trec2->{rev}, fields => $trec2->{fields});
                        $tstore->update('legacy-tasklist-open', expect => \%expect, set => { state => 'handed-off' });
                        $Almanac::Thread::WRITES++;
                        _append_log('legacy-tasklist-open', 'handed-off',
                            root => $opt{root}, home => $opt{home}, cwd => $opt{cwd},
                            actor => 'migration', reason => 'migrated from the flat tasklist');
                    }
                    1;
                };
                my $e2 = $@; $lock2->release; die $e2 unless $ok2;
            }
            elsif ($trec->{fields}{state} eq 'archived') {
                # Open tasks written to the flat tasklist AFTER an earlier
                # migration (by a writer still on the flat-store library)
                # were just copied into an archived thread, where no agent
                # looks (pkg02 redteam N2). Hand the thread back out so they
                # are seen; the archive check re-archives it once they close.
                my $lock2 = _acquire_thread_lock('legacy-tasklist-open', %opt);
                my $ok2 = eval {
                    my $trec2 = $tstore->read('legacy-tasklist-open');
                    if ($trec2->{fields}{state} eq 'archived') {
                        my %expect = (rev => $trec2->{rev}, fields => $trec2->{fields});
                        $tstore->update('legacy-tasklist-open', expect => \%expect,
                            set => { state => 'handed-off' }, unset => ['archived_at']);
                        $Almanac::Thread::WRITES++;
                        _append_log('legacy-tasklist-open', 'handed-off',
                            root => $opt{root}, home => $opt{home}, cwd => $opt{cwd},
                            actor => 'migration', reason => 'late flat-tasklist tasks migrated into an archived thread');
                    }
                    1;
                };
                my $e2 = $@; $lock2->release; die $e2 unless $ok2;
            }
        }

        # Spec 2.5 step 5: a delete failure here is a die inside steps 2-5,
        # re-raised below as the refusal (with its cause surfaced, review
        # S4) -- NOT silently swallowed. A crash/failure here still resumes
        # correctly next run: the copy in step 3 is skipped by id, so no
        # task is duplicated, and an undeleted source record is simply
        # retried.
        for my $rec (@$list) {
            my %expect = (rev => $rec->{rev}, fields => $rec->{fields});
            $task_store->delete($rec->{id}, expect => \%expect);
            $Almanac::Thread::WRITES++;
        }
        for my $fid (@{ $focus_store->ids }) {
            my $frec = $focus_store->read($fid);
            my %expect = (rev => $frec->{rev}, fields => $frec->{fields});
            $focus_store->delete($fid, expect => \%expect);
            $Almanac::Thread::WRITES++;
        }

        $result = { migrated => 1, done => $done_count, open => $open_count };
        1;
    };
    my $err = $@;
    $mlock->release;
    unless ($ok) {
        # Surface the underlying error's kind/id/path as `cause`, rather than
        # discarding it (review S4): a malformed source record or a failed
        # post-copy delete otherwise leaves no hint where to look.
        my $cause;
        if (ref($err) eq 'Almanac::Store::Error' || ref($err) eq 'Almanac::Record::Error') {
            my @bits;
            push @bits, "kind=$err->{kind}" if defined $err->{kind};
            push @bits, "id=$err->{id}"     if defined $err->{id};
            push @bits, "path=$err->{path}" if defined $err->{path};
            $cause = join(',', @bits) if @bits;
        } elsif (defined $err && length("$err")) {
            $cause = "$err";
        }
        die Almanac::Store::Error->new(kind => 'refused', detail => 'tasklist_migration_failed',
            path => "$almanac/task", cause => $cause);
    }
    return $result;
}

1;
