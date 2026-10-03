#!/usr/bin/env perl
# almanac-thread.pl -- threads per project: create, list, show, archive;
# ordered tasks with a status or a package link; a typed log. Blueprint
# where-things-go, package 02-thread-store. See specs/02-thread-store-spec.md
# section 2.7.
package Almanac::ThreadCLI;
use strict;
use warnings;
use JSON::PP ();
use Encode ();
use Cwd ();

# This file was never hit by bug 75fe's doubled-join defect -- it only
# unshifts $dir onto @INC and loads siblings via bareword `use Module ();`,
# which resolves through perl's own @INC search rather than a manual
# string-concatenated require path, so a relative $dir already worked.
# __FILE__ is still resolved through Cwd::abs_path here, defensively and
# for consistency with the scripts that did have the defect
# (almanac-doctor.pl, almanac-inbox.pl), not because this file needed the
# fix.
BEGIN {
    my $dir = Cwd::abs_path(__FILE__);
    $dir =~ s{\\}{/}g;
    $dir =~ s{/[^/]+\z}{};
    $dir = '.' unless length $dir;
    unshift @INC, $dir;
}
use Almanac::Store ();
use Almanac::Record ();
use Almanac::Thread ();
use Almanac::GlobalCounts ();
use Almanac::SessionLive ();

# @GATED_VERBS -- every write verb; mirrored in
# BpHook::ContinuityOffCheck::THREAD_GATED (parity-tested). list/show are the
# only ungated verbs (spec 2.7).
our @GATED_VERBS = qw(
    create archive archive-if-done add edit move reorder status add-packages event
    attach detach switch take-over
);

our $VERSION = '1.0';

sub _usage { die Almanac::Store::Error->new(kind => 'usage', detail => $_[0]) }

sub _decode_maybe {
    my ($s) = @_;
    return $s unless defined $s;
    return $s if utf8::is_utf8($s);
    my $d = eval { Encode::decode('UTF-8', $s, Encode::FB_CROAK()) };
    return defined $d ? $d : $s;
}

sub _valid_ref_id {
    my ($v) = @_;
    return 0 unless defined $v && length($v) <= 128;
    return 0 unless $v =~ /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/;
    return 0 if $v =~ /\.\./;
    return 1;
}

sub _resolve_session_and_actor {
    my ($o) = @_;
    my $sess = (exists $o->{session} && defined $o->{session} && length $o->{session})
        ? $o->{session} : $ENV{CLAUDE_CODE_SESSION_ID};
    if (defined $sess && length $sess) {
        _usage('bad_session') unless _valid_ref_id($sess);
        return ($sess, 'session');
    }
    return (undef, 'cli');
}

# ---------------------------------------------------------------------------
# output
# ---------------------------------------------------------------------------
sub _print_thread_result {
    my ($thread, $changed) = @_;
    print "thread: $thread->{name}\n";
    print "state: $thread->{state}\n";
    print "path: " . _decode_maybe($thread->{path}) . "\n";
    print "changed: $changed\n";
}

sub _print_attach_result {
    my ($thread, $changed) = @_;
    print "thread: $thread->{name}\n";
    print "state: $thread->{state}\n";
    print "owner: $thread->{owner_kind}:$thread->{owner_id}\n";
    print "path: " . _decode_maybe($thread->{path}) . "\n";
    print "changed: $changed\n";
}

sub _print_task_result {
    my ($task, $thread_name, $changed, $thread_state) = @_;
    print "thread: $thread_name\n";
    print "task: $task->{id}\n";
    print "path: " . _decode_maybe($task->{path}) . "\n";
    print "status: " . (defined $task->{status} ? $task->{status} : '-') . "\n";
    print "link: "   . (defined $task->{link}   ? $task->{link}   : '-') . "\n";
    print "rank: "   . (defined $task->{rank}   ? $task->{rank}   : '-') . "\n";
    print "rev: $task->{rev}\n";
    print "changed: $changed\n";
    print "thread_state: $thread_state\n";
}

sub _task_counts {
    my ($name, $o) = @_;
    my $tasks = Almanac::Thread::tasks($name, root => $o->{root}, home => $o->{home});
    my $done = 0;
    $done++ for grep { Almanac::Thread::is_done_task($_) } @$tasks;
    return ($done, scalar(@$tasks));
}

sub _print_list_default {
    my ($list, $o) = @_;
    for my $h (@$list) {
        my ($done, $total) = _task_counts($h->{name}, $o);
        print "thread: $h->{name}\n";
        print "  state: $h->{state}\n";
        print "  owner: $h->{owner_kind}:$h->{owner_id}\n";
        print "  tasks: $done/$total\n";
        print "  blueprints: " . (@{ $h->{blueprints} } ? join(',', @{ $h->{blueprints} }) : '-') . "\n";
    }
    print "total: " . scalar(@$list) . "\n";
}

sub _print_list_json {
    my ($list, $o) = @_;
    my @out;
    for my $h (@$list) {
        my ($done, $total) = _task_counts($h->{name}, $o);
        push @out, {
            name => $h->{name}, state => $h->{state}, owner_kind => $h->{owner_kind},
            owner_id => $h->{owner_id}, created => $h->{created},
            archived_at => $h->{archived_at}, blueprints => $h->{blueprints},
            tasks_total => $total, tasks_done => $done,
        };
    }
    print JSON::PP->new->canonical(1)->encode(\@out);
}

sub _print_show_default {
    my ($thread, $tasks, $log) = @_;
    my $done = 0; $done++ for grep { Almanac::Thread::is_done_task($_) } @$tasks;
    print "thread: $thread->{name}\n";
    print "state: $thread->{state}\n";
    print "owner: $thread->{owner_kind}:$thread->{owner_id}\n";
    print "created: $thread->{created}\n";
    print "blueprints: " . (@{ $thread->{blueprints} } ? join(',', @{ $thread->{blueprints} }) : '-') . "\n";
    print "archived_at: " . (defined $thread->{archived_at} ? $thread->{archived_at} : '-') . "\n";
    print "tasks: $done/" . scalar(@$tasks) . "\n";
    for my $t (@$tasks) {
        print "task: $t->{id}\n";
        print "  position: $t->{position}\n";
        print "  status: " . (defined $t->{status} ? $t->{status} : '-') . "\n";
        my $link_disp = '-';
        if ($t->{linked}) {
            my $loc = defined $t->{location} ? $t->{location} : 'missing';
            $link_disp = "$t->{link} ($loc)";
        }
        print "  link: $link_disp\n";
        print "  blocked_on: " . (defined $t->{blocked_on} ? $t->{blocked_on} : '-') . "\n";
        print "  title: " . (defined $t->{title} ? $t->{title} : '-') . "\n";
    }
    for my $e (@$log) {
        my $line = "log: $e->{at} $e->{event} actor=$e->{actor} session=$e->{session}";
        $line .= " task=$e->{task}"     if defined $e->{task};
        $line .= " from=$e->{from}"     if defined $e->{from};
        $line .= " to=$e->{to}"         if defined $e->{to};
        $line .= " reason=$e->{reason}" if defined $e->{reason};
        print "$line\n";
    }
}

sub _print_show_json {
    my ($thread, $tasks, $log) = @_;
    my %out_thread = (
        name => $thread->{name}, state => $thread->{state}, owner_kind => $thread->{owner_kind},
        owner_id => $thread->{owner_id}, created => $thread->{created},
        archived_at => $thread->{archived_at},
        blueprints => (@{ $thread->{blueprints} } ? join(',', @{ $thread->{blueprints} }) : undef),
    );
    my @out_tasks;
    for my $t (@$tasks) {
        push @out_tasks, {
            id => $t->{id}, position => $t->{position}, rank => $t->{rank}, title => $t->{title},
            linked => ($t->{linked} ? JSON::PP::true : JSON::PP::false),
            link => $t->{link}, status => $t->{status}, location => $t->{location},
            blocked_on => $t->{blocked_on}, from_todo => $t->{from_todo}, body => $t->{body},
        };
    }
    my @out_log;
    for my $e (@$log) {
        push @out_log, {
            id => $e->{id}, at => $e->{at}, session => $e->{session}, actor => $e->{actor},
            event => $e->{event}, task => $e->{task}, from => $e->{from}, to => $e->{to},
            reason => $e->{reason},
        };
    }
    print JSON::PP->new->canonical(1)->encode({ thread => \%out_thread, tasks => \@out_tasks, log => \@out_log });
}

# ---------------------------------------------------------------------------
# global-counts refresh (behaviour per 2.7, mirrors almanac-todo.pl)
# ---------------------------------------------------------------------------
sub _maybe_refresh_global_counts {
    my ($o) = @_;
    local $@;
    my $root = eval { Almanac::Thread::project_root(root => $o->{root}, home => $o->{home}) };
    my $res = eval { Almanac::GlobalCounts::refresh(home => $o->{home}, record_root => $root) };
    return if ref($res) eq 'HASH' && $res->{ok};
    my $reason = (ref($res) eq 'HASH' && defined $res->{reason}) ? $res->{reason} : 'unknown';
    return if $reason eq 'container';
    print STDERR "almanac: global counts snapshot not refreshed (reason: $reason)\n";
    print STDERR "almanac-warning:\n";
    print STDERR "  kind: global_counts_stale\n";
    print STDERR "  reason: $reason\n";
}

# ---------------------------------------------------------------------------
# CLI entry point.
# ---------------------------------------------------------------------------
unless (caller) {
    my @ARGV_RAW = @ARGV;
    binmode(STDOUT, ':encoding(UTF-8)');

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

    my $w0 = $Almanac::Thread::WRITES;
    my $ok = eval {
        _usage('missing_verb') unless defined $cmd && length $cmd;

        my %VERBS = map { $_ => 1 } qw(
            create list show archive archive-if-done add edit move reorder status add-packages event
            attach detach switch take-over
        );
        _usage('unknown_verb') unless $VERBS{$cmd};

        my %ALLOWED_FLAGS = (
            'create'          => [qw(root home session)],
            'list'            => [qw(archived json root home session)],
            'show'            => [qw(json root home session)],
            'archive'         => [qw(reason root home session)],
            'archive-if-done' => [qw(root home session)],
            'add'             => [qw(title body blocked-on link id root home session)],
            'edit'            => [qw(title body blocked-on clear-blocked-on root home session)],
            'move'            => [qw(first last before after root home session)],
            'reorder'         => [qw(root home session)],
            'status'          => [qw(root home session)],
            'add-packages'    => [qw(root home session)],
            'event'           => [qw(event reason root home session)],
            'attach'          => [qw(root home session)],
            'detach'          => [qw(reason root home session)],
            'switch'          => [qw(root home session)],
            'take-over'       => [qw(reason root home session)],
        );
        my %allowed = map { $_ => 1 } @{ $ALLOWED_FLAGS{$cmd} };
        for my $k (keys %o) {
            _usage('unknown_flag') unless $allowed{$k};
        }

        # Value-taking flags fail OPEN on a missing value -- 'title' is
        # special-cased per verb below (same convention as almanac-task.pl).
        for my $k (qw(root home session body id blocked-on link before after reason event)) {
            _usage('missing_flag_value') if $bool_default{$k};
        }

        # Spec 2.7 step 1: validate verb, flags and positional counts BEFORE
        # anything is written -- migrate_legacy (step 4) must never run for a
        # usage error, and the gate (step 3) must never consume a ticket for
        # a usage error either. This is a read-only dry run over a COPY of
        # @pos; it raises the same usage errors the real dispatch below
        # would, but must not consume @pos or call any Almanac::Thread::
        # write function.
        {
            my @p = @pos;
            if ($cmd eq 'create') {
                my $name = shift @p;
                _usage('missing_name') unless defined $name && length $name;
                _usage('extra_positional') if @p;
            }
            elsif ($cmd eq 'list') {
                _usage('extra_positional') if @p;
            }
            elsif ($cmd eq 'show' || $cmd eq 'archive' || $cmd eq 'archive-if-done') {
                my $name = shift @p;
                _usage('missing_name') unless defined $name && length $name;
                _usage('extra_positional') if @p;
            }
            elsif ($cmd eq 'add') {
                my $name = shift @p;
                _usage('missing_name') unless defined $name && length $name;
                _usage('extra_positional') if @p;
                my $has_link = exists $o{link};
                if ($has_link) {
                    _usage('missing_flag_value') if $bool_default{link};
                } else {
                    _usage('missing_title') if !exists($o{title}) || $bool_default{title};
                }
            }
            elsif ($cmd eq 'edit') {
                my $name = shift @p;
                _usage('missing_name') unless defined $name && length $name;
                my $id = shift @p;
                _usage('missing_task') unless defined $id && length $id;
                _usage('extra_positional') if @p;
                _usage('missing_flag_value') if exists $o{title} && $bool_default{title};
            }
            elsif ($cmd eq 'move') {
                my $name = shift @p;
                _usage('missing_name') unless defined $name && length $name;
                my $id = shift @p;
                _usage('missing_task') unless defined $id && length $id;
                _usage('extra_positional') if @p;
                my @chosen = grep { exists $o{$_} } qw(first last before after);
                _usage('bad_move') unless @chosen == 1;
                my $where = $chosen[0];
                if ($where eq 'before' || $where eq 'after') {
                    _usage('missing_flag_value') if $bool_default{$where};
                }
            }
            elsif ($cmd eq 'reorder') {
                my $name = shift @p;
                _usage('missing_name') unless defined $name && length $name;
                _usage('missing_task') unless @p;
            }
            elsif ($cmd eq 'status') {
                my $name = shift @p;
                _usage('missing_name') unless defined $name && length $name;
                my $id = shift @p;
                _usage('missing_task') unless defined $id && length $id;
                shift @p;   # status value itself -- validated by the library
                _usage('extra_positional') if @p;
            }
            elsif ($cmd eq 'add-packages') {
                my $name = shift @p;
                _usage('missing_name') unless defined $name && length $name;
                _usage('missing_blueprint') unless @p;
            }
            elsif ($cmd eq 'event') {
                my $name = shift @p;
                _usage('missing_name') unless defined $name && length $name;
                _usage('extra_positional') if @p;
                _usage('missing_event')
                    unless exists $o{event} && defined $o{event} && length($o{event}) && !$bool_default{event};
            }
            elsif ($cmd eq 'attach') {
                my $name = shift @p;
                _usage('missing_name') unless defined $name && length $name;
                _usage('extra_positional') if @p;
            }
            elsif ($cmd eq 'detach') {
                shift @p;   # thread name is OPTIONAL for detach
                _usage('extra_positional') if @p;
            }
            elsif ($cmd eq 'switch') {
                my $name = shift @p;
                _usage('missing_name') unless defined $name && length $name;
                _usage('extra_positional') if @p;
            }
            elsif ($cmd eq 'take-over') {
                my $name = shift @p;
                _usage('missing_name') unless defined $name && length $name;
                _usage('extra_positional') if @p;
            }
        }

        my %GATED_OK = map { $_ => 1 } @GATED_VERBS;
        my ($sess, $actor, $transcript);
        if ($GATED_OK{$cmd}) {
            my $g = eval { Almanac::Thread::cli_gate('almanac-thread', \@ARGV_RAW) };
            if (my $gerr = $@) {
                my $detail = (ref($gerr) eq 'Almanac::Store::Error' && defined $gerr->{detail}) ? $gerr->{detail} : 'error';
                print STDERR 'almanac thread: ' . Almanac::Thread::gate_message($detail) . "\n";
                die $gerr;
            }
            if ($g->{mode} eq 'ticket') {
                $sess = $g->{session};
                $actor = 'session';
                $transcript = $g->{transcript_path};
                if (exists $o{session} && defined $o{session} && length $o{session} && $o{session} ne $sess) {
                    my $mm_err = Almanac::Store::Error->new(kind => 'refused', detail => 'session_mismatch');
                    print STDERR 'almanac thread: ' . Almanac::Thread::gate_message('session_mismatch') . "\n";
                    die $mm_err;
                }
            } else {
                ($sess, $actor) = _resolve_session_and_actor(\%o);
                $transcript = (defined $sess && length $sess)
                    ? (Almanac::SessionLive::find_transcript($sess))[0] : undef;
            }
        } else {
            ($sess, $actor) = _resolve_session_and_actor(\%o);
        }

        Almanac::Thread::migrate_legacy(root => $o{root}, home => $o{home});

        if ($cmd eq 'create') {
            my $name = shift @pos;
            _usage('missing_name') unless defined $name && length $name;
            _usage('extra_positional') if @pos;
            my %owner = (defined $sess) ? (owner_kind => 'session', owner_id => $sess)
                                         : (owner_kind => 'none',    owner_id => '-');
            my $thread = Almanac::Thread::create_thread($name,
                root => $o{root}, home => $o{home}, session => $sess, actor => $actor, %owner,
                owner_transcript => $transcript);
            _print_thread_result($thread, 'yes');
        }
        elsif ($cmd eq 'list') {
            _usage('extra_positional') if @pos;
            my $all = Almanac::Thread::list_threads(root => $o{root}, home => $o{home}, archived => 1);
            for my $h (@$all) {
                next if $h->{state} eq 'archived';
                Almanac::Thread::archive_if_done($h->{name},
                    root => $o{root}, home => $o{home}, session => $sess, actor => $actor);
            }
            my $list = Almanac::Thread::list_threads(
                root => $o{root}, home => $o{home}, archived => ($o{archived} ? 1 : 0));
            if ($o{json}) { _print_list_json($list, \%o) } else { _print_list_default($list, \%o) }
        }
        elsif ($cmd eq 'show') {
            my $name = shift @pos;
            _usage('missing_name') unless defined $name && length $name;
            _usage('extra_positional') if @pos;
            Almanac::Thread::archive_if_done($name,
                root => $o{root}, home => $o{home}, session => $sess, actor => $actor);
            my $thread = Almanac::Thread::read_thread($name, root => $o{root}, home => $o{home});
            my $tasks  = Almanac::Thread::tasks($name, root => $o{root}, home => $o{home});
            my $log    = Almanac::Thread::log_entries($name, root => $o{root}, home => $o{home});
            if ($o{json}) { _print_show_json($thread, $tasks, $log) } else { _print_show_default($thread, $tasks, $log) }
        }
        elsif ($cmd eq 'archive') {
            my $name = shift @pos;
            _usage('missing_name') unless defined $name && length $name;
            _usage('extra_positional') if @pos;
            my ($thread, $changed) = Almanac::Thread::archive($name,
                root => $o{root}, home => $o{home}, session => $sess, actor => $actor, reason => $o{reason});
            _print_thread_result($thread, $changed ? 'yes' : 'no');
        }
        elsif ($cmd eq 'archive-if-done') {
            my $name = shift @pos;
            _usage('missing_name') unless defined $name && length $name;
            _usage('extra_positional') if @pos;
            my ($thread, $changed) = Almanac::Thread::archive_if_done($name,
                root => $o{root}, home => $o{home}, session => $sess, actor => $actor);
            _print_thread_result($thread, $changed ? 'yes' : 'no');
        }
        elsif ($cmd eq 'add') {
            my $name = shift @pos;
            _usage('missing_name') unless defined $name && length $name;
            _usage('extra_positional') if @pos;
            my %args = (root => $o{root}, home => $o{home}, session => $sess, actor => $actor);
            my $has_link = exists $o{link};
            if ($has_link) {
                _usage('missing_flag_value') if $bool_default{link};
                $args{link} = $o{link};
                $args{title} = $o{title} if exists $o{title} && !$bool_default{title};
            } else {
                _usage('missing_title') if !exists($o{title}) || $bool_default{title};
                $args{title} = $o{title};
            }
            $args{body}       = $o{body}          if exists $o{body};
            $args{blocked_on} = $o{'blocked-on'}  if exists $o{'blocked-on'};
            $args{id}         = $o{id}            if exists $o{id};
            my $task = Almanac::Thread::add_task($name, %args);
            my $thread = Almanac::Thread::read_thread($name, root => $o{root}, home => $o{home});
            _print_task_result($task, $name, 'yes', $thread->{state});
        }
        elsif ($cmd eq 'edit') {
            my $name = shift @pos;
            _usage('missing_name') unless defined $name && length $name;
            my $id = shift @pos;
            _usage('missing_task') unless defined $id && length $id;
            _usage('extra_positional') if @pos;
            my %args = (root => $o{root}, home => $o{home}, session => $sess, actor => $actor);
            if (exists $o{title}) {
                _usage('missing_flag_value') if $bool_default{title};
                $args{title} = $o{title};
            }
            $args{body}             = $o{body}         if exists $o{body};
            $args{blocked_on}       = $o{'blocked-on'} if exists $o{'blocked-on'};
            $args{clear_blocked_on} = 1                if exists $o{'clear-blocked-on'};
            my ($task, $changed) = Almanac::Thread::edit_task($name, $id, %args);
            my $thread = Almanac::Thread::read_thread($name, root => $o{root}, home => $o{home});
            _print_task_result($task, $name, $changed ? 'yes' : 'no', $thread->{state});
        }
        elsif ($cmd eq 'move') {
            my $name = shift @pos;
            _usage('missing_name') unless defined $name && length $name;
            my $id = shift @pos;
            _usage('missing_task') unless defined $id && length $id;
            _usage('extra_positional') if @pos;
            my @chosen = grep { exists $o{$_} } qw(first last before after);
            _usage('bad_move') unless @chosen == 1;
            my $where = $chosen[0];
            my %args = (root => $o{root}, home => $o{home}, session => $sess, actor => $actor, where => $where);
            if ($where eq 'before' || $where eq 'after') {
                _usage('missing_flag_value') if $bool_default{$where};
                $args{ref} = $o{$where};
            }
            my ($task, $changed) = Almanac::Thread::move_task($name, $id, %args);
            my $thread = Almanac::Thread::read_thread($name, root => $o{root}, home => $o{home});
            _print_task_result($task, $name, $changed ? 'yes' : 'no', $thread->{state});
        }
        elsif ($cmd eq 'reorder') {
            my $name = shift @pos;
            _usage('missing_name') unless defined $name && length $name;
            _usage('missing_task') unless @pos;
            my @ids = @pos;
            my $tasks = Almanac::Thread::reorder_tasks($name, \@ids,
                root => $o{root}, home => $o{home}, session => $sess, actor => $actor);
            for my $t (@$tasks) { print "task: $t->{id}\n" }
            print "total: " . scalar(@$tasks) . "\n";
            my $thread = Almanac::Thread::read_thread($name, root => $o{root}, home => $o{home});
            print "thread_state: $thread->{state}\n";
        }
        elsif ($cmd eq 'status') {
            my $name = shift @pos;
            _usage('missing_name') unless defined $name && length $name;
            my $id = shift @pos;
            _usage('missing_task') unless defined $id && length $id;
            my $status = shift @pos;
            _usage('extra_positional') if @pos;
            my ($task, $changed) = Almanac::Thread::set_task_status($name, $id, $status,
                root => $o{root}, home => $o{home}, session => $sess, actor => $actor);
            my $thread = Almanac::Thread::read_thread($name, root => $o{root}, home => $o{home});
            _print_task_result($task, $name, $changed ? 'yes' : 'no', $thread->{state});
        }
        elsif ($cmd eq 'add-packages') {
            my $name = shift @pos;
            _usage('missing_name') unless defined $name && length $name;
            _usage('missing_blueprint') unless @pos;
            my @bps = @pos;
            my $added = Almanac::Thread::add_packages($name, \@bps,
                root => $o{root}, home => $o{home}, session => $sess, actor => $actor);
            print "thread: $name\n";
            for my $t (@$added) { print "added: $t->{id} $t->{link}\n" }
            print "total_added: " . scalar(@$added) . "\n";
            my $thread = Almanac::Thread::read_thread($name, root => $o{root}, home => $o{home});
            print "thread_state: $thread->{state}\n";
        }
        elsif ($cmd eq 'event') {
            my $name = shift @pos;
            _usage('missing_name') unless defined $name && length $name;
            _usage('extra_positional') if @pos;
            _usage('missing_event')
                unless exists $o{event} && defined $o{event} && length($o{event}) && !$bool_default{event};
            # Decision 35 / S3: only a session-identified CLI caller gets
            # an ownership check; an orchestrator/migration/cli caller
            # (direct library use, $actor ne 'session') is unaffected, as
            # before.
            my $thread = Almanac::Thread::record_event($name, $o{event},
                root => $o{root}, home => $o{home}, session => $sess, actor => $actor, reason => $o{reason},
                (($actor eq 'session' && defined $sess && length $sess)
                    ? (require_owner_session => $sess) : ()));
            _print_thread_result($thread, 'yes');
        }
        elsif ($cmd eq 'attach') {
            my $name = shift @pos;
            _usage('missing_name') unless defined $name && length $name;
            _usage('extra_positional') if @pos;
            my ($thread, $changed) = Almanac::Thread::attach($name,
                root => $o{root}, home => $o{home}, session => $sess, actor => $actor, transcript => $transcript);
            _print_attach_result($thread, $changed ? 'yes' : 'no');
        }
        elsif ($cmd eq 'detach') {
            my $name = shift @pos;
            _usage('extra_positional') if @pos;
            my ($thread, $changed) = Almanac::Thread::detach($name,
                root => $o{root}, home => $o{home}, session => $sess, actor => $actor, reason => $o{reason});
            _print_attach_result($thread, $changed ? 'yes' : 'no');
        }
        elsif ($cmd eq 'switch') {
            my $name = shift @pos;
            _usage('missing_name') unless defined $name && length $name;
            _usage('extra_positional') if @pos;
            my ($thread, $changed, $left) = Almanac::Thread::switch_thread($name,
                root => $o{root}, home => $o{home}, session => $sess, actor => $actor, transcript => $transcript);
            _print_attach_result($thread, $changed ? 'yes' : 'no');
            print "left: " . (defined $left ? $left : '-') . "\n";
        }
        elsif ($cmd eq 'take-over') {
            my $name = shift @pos;
            _usage('missing_name') unless defined $name && length $name;
            _usage('extra_positional') if @pos;
            my ($thread, $changed) = Almanac::Thread::take_over($name,
                root => $o{root}, home => $o{home}, session => $sess, actor => $actor,
                reason => $o{reason}, transcript => $transcript);
            _print_attach_result($thread, $changed ? 'yes' : 'no');
        }
        1;
    };
    my $err = $@;

    if ($Almanac::Thread::WRITES > $w0) {
        _maybe_refresh_global_counts(\%o);
    }

    unless ($ok) {
        Almanac::Record::fatal($err);
    }
    exit 0;
}

1;
