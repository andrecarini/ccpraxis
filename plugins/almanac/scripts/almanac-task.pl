#!/usr/bin/env perl
# almanac-task.pl -- the one project tasklist, over Almanac::Store (blueprint
# almanac-records, package 07-tasklist). See specs/07-tasklist-spec.md for
# the full contract; this file implements it and adds nothing beyond it.
#
# Store types: 'task' (project scope, the tasklist itself) and 'task-focus'
# (project scope, record id = the live session id). No integer position is
# ever stored -- ordering verbs resolve onto Store's rank primitives
# (insert_first/insert_last/insert_before/insert_after/reorder/rank_between/
# rank_jitter), and 'move-first'/'move-last' mint a rank directly via
# rank_between + rank_jitter followed by Store::update's rank argument (Store
# itself has no move/position verb -- Decision 10).
package Almanac::Task;
use strict;
use warnings;
use JSON::PP ();
use Encode ();
use Cwd ();

# Almanac/ sits beside THIS FILE (not $0, not FindBin -- both are the
# invoking program, which a test's `do $TASK_PL` makes the .t file, not this
# one). This file was never hit by bug 75fe's doubled-join defect -- it
# only unshifts $dir onto @INC and loads siblings via bareword
# `use Module ();`, which resolves through perl's own @INC search rather
# than a manual string-concatenated require path, so a relative $dir
# already worked. __FILE__ is still resolved through Cwd::abs_path here,
# defensively and for consistency with the scripts that did have the
# defect (almanac-doctor.pl, almanac-inbox.pl), not because this file
# needed the fix.
BEGIN {
    my $dir = Cwd::abs_path(__FILE__);
    $dir =~ s{\\}{/}g;
    $dir =~ s{/[^/]+\z}{};
    $dir = '.' unless length $dir;
    unshift @INC, $dir;
}
use Almanac::Store ();
use Almanac::Record ();

our $VERSION = '1.0';

# ---------------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------------

sub _usage { die Almanac::Store::Error->new(kind => 'usage', detail => $_[0]) }

sub _trim {
    my ($s) = @_;
    return $s unless defined $s;
    $s =~ s/\A\s+//;
    $s =~ s/\s+\z//;
    return $s;
}

# _decode_maybe($s) -> decoded character string. See almanac-todo.pl's
# comment of the same name for the reasoning (Cwd::abs_path returns raw
# UTF-8 bytes without the internal utf8 flag; decode once here so STDOUT's
# one encode is the only one).
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

# _valid_ref_id($v) -> 1 | 0 -- the Store id grammar, restated (S2.2 of the
# spec): \A[A-Za-z0-9][A-Za-z0-9._-]*\z, <= 128 chars, no '..'. Used for both
# blocked_on and the session id (S1.3/S3.6).
sub _valid_ref_id {
    my ($v) = @_;
    return 0 unless defined $v && length($v) <= 128;
    return 0 unless $v =~ /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/;
    return 0 if $v =~ /\.\./;
    return 1;
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

# ---------------------------------------------------------------------------
# 2.4 -- module functions.
# ---------------------------------------------------------------------------

sub STATUSES { return ('pending', 'doing', 'blocked', 'done', 'obsoleted') }

sub open_tasklist {
    my (%opt) = @_;
    return Almanac::Store->open(scope => 'project', type => 'task',
        root => $opt{root}, home => $opt{home}, cwd => $opt{cwd});
}

sub list_tasks {
    my (%opt) = @_;
    return open_tasklist(%opt)->list();
}

# _task_create_args(%opt) -> %args   -- opt: title*, body, blocked_on, id.
# Shared by add/insert_at/insert_before/insert_after (S2.2: caller field
# order title, status, created, blocked_on; new tasks are pending).
sub _task_create_args {
    my (%opt) = @_;
    _usage('missing_title') unless exists($opt{title}) && defined($opt{title});
    my $title = _trim($opt{title});
    _usage('bad_title') if $title eq '' || $title =~ /[\r\n]/;

    my %fields = (title => $title, status => 'pending', created => _now_iso());
    if (exists $opt{blocked_on} && defined $opt{blocked_on}) {
        _usage('bad_blocked_on') unless _valid_ref_id($opt{blocked_on});
        $fields{blocked_on} = $opt{blocked_on};
    }
    my @order = grep { exists $fields{$_} } qw(title status created blocked_on);

    my %args = (fields => \%fields, order => \@order);
    $args{id}   = $opt{id}   if exists $opt{id};
    $args{body} = $opt{body} if exists $opt{body};
    return %args;
}

sub add {
    my (%opt) = @_;
    my %args  = _task_create_args(%opt);
    return open_tasklist(%opt)->insert_last(%args);
}

sub insert_at {
    my ($pos, %opt) = @_;
    my $store = open_tasklist(%opt);
    _usage('bad_position') unless defined($pos) && $pos =~ /\A\d+\z/;
    my $n    = $pos + 0;
    my $list = $store->list();
    my $len  = scalar(@$list);
    _usage('bad_position') if $n < 1 || $n > $len + 1;

    my %args = _task_create_args(%opt);
    if    ($n == $len + 1) { return $store->insert_last(%args) }
    elsif ($n == 1)        { return $store->insert_first(%args) }
    else                    { return $store->insert_after($list->[$n - 2]{id}, %args) }
}

sub insert_before {
    my ($ref_id, %opt) = @_;
    my %args = _task_create_args(%opt);
    return open_tasklist(%opt)->insert_before($ref_id, %args);
}

sub insert_after {
    my ($ref_id, %opt) = @_;
    my %args = _task_create_args(%opt);
    return open_tasklist(%opt)->insert_after($ref_id, %args);
}

sub move_first {
    my ($id, %opt) = @_;
    my $store = open_tasklist(%opt);
    my $list  = $store->list();
    my ($cur) = grep { $_->{id} eq $id } @$list;
    $store->read($id) unless $cur;   # raises not_found / bad_id, whichever applies
    return ($cur, 0) if @$list && $list->[0]{id} eq $id;

    my $new_rank = Almanac::Store::rank_between(undef, $list->[0]{rank}) . Almanac::Store::rank_jitter();
    my %expect   = (rev => $cur->{rev}, fields => $cur->{fields});
    my $new      = $store->update($id, expect => \%expect, rank => $new_rank);
    return ($new, 1);
}

sub move_last {
    my ($id, %opt) = @_;
    my $store = open_tasklist(%opt);
    my $list  = $store->list();
    my ($cur) = grep { $_->{id} eq $id } @$list;
    $store->read($id) unless $cur;   # raises not_found / bad_id, whichever applies
    return ($cur, 0) if @$list && $list->[-1]{id} eq $id;

    my @ranked   = grep { defined $_->{rank} } @$list;
    my $last     = @ranked ? $ranked[-1]{rank} : undef;
    my $new_rank = Almanac::Store::rank_between($last, undef) . Almanac::Store::rank_jitter();
    my %expect   = (rev => $cur->{rev}, fields => $cur->{fields});
    my $new      = $store->update($id, expect => \%expect, rank => $new_rank);
    return ($new, 1);
}

sub reorder {
    my ($ids, %opt) = @_;
    return open_tasklist(%opt)->reorder($ids);
}

sub set_status {
    my ($id, $status, %opt) = @_;
    _usage('bad_status') unless defined($status) && grep { $_ eq $status } STATUSES();

    my $store = open_tasklist(%opt);
    my $rec   = $store->read($id);
    if (defined($rec->{fields}{status}) && $rec->{fields}{status} eq $status) {
        return ($rec, 0);
    }
    my %expect = (rev => $rec->{rev}, fields => $rec->{fields});
    $expect{rev} = $opt{'expect-rev'} if exists $opt{'expect-rev'};
    my $new = $store->update($id, expect => \%expect, set => { status => $status });
    return ($new, 1);
}

# check_refs(%opt) -> \%report -- NEVER dies, NEVER prints, NEVER writes
# (S2.4). Shaped like Almanac::Note::check_pointers(): the SAME hashrefs
# populate both `refs` and `dangling`.
sub check_refs {
    my (%opt) = @_;
    my $report = { type => 'task' };

    my $store = eval { open_tasklist(%opt) };
    if (my $err = $@) {
        $report->{project} = { available => 0, reason => _err_reason($err) };
        return $report;
    }
    my $list = eval { $store->list() };
    if (my $err = $@) {
        $report->{project} = { available => 0, reason => _err_reason($err) };
        return $report;
    }

    # blocked_on names an inbox item (blueprint where-things-go, package
    # 01-inbox-rename, spec 2.7): read A/inbox/ when it exists, else the
    # unmigrated legacy dir A/<LEGACY_INBOX_TYPE>/ when THAT exists, else
    # nothing (every ref dangling). Never migrates, writes or loads
    # Almanac::Inbox -- this stays a read-only existence probe.
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
    for my $rec (@$list) {
        my $target = $rec->{fields}{blocked_on};
        next unless defined $target && length $target;
        my $exists = $dstore ? eval { $dstore->exists($target) } : 0;
        push @refs, {
            task   => $rec->{id},
            field  => 'blocked_on',
            target => $target,
            status => ($exists ? 'ok' : 'dangling'),
        };
    }
    my @dangling = grep { $_->{status} eq 'dangling' } @refs;
    $report->{project} = { available => 1, reason => 'ok', refs => \@refs, dangling => \@dangling };
    return $report;
}

# resolve_session(%opt) -> $session_id   -- opt: session ; else env ; else
# dies (S1.3). No placeholder fallback of any kind.
sub resolve_session {
    my (%opt) = @_;
    my $sess = (exists $opt{session} && defined $opt{session} && length $opt{session})
        ? $opt{session} : $ENV{CLAUDE_CODE_SESSION_ID};
    _usage('no_session')  unless defined $sess && length $sess;
    _usage('bad_session') unless _valid_ref_id($sess);
    return $sess;
}

# _canonical_project_root(%opt) -> $root -- S2.3: the canonical project root
# for %opt's root/cwd, via a task-store open with the trailing almanac
# segment removed.
sub _canonical_project_root {
    my (%opt) = @_;
    my $r = open_tasklist(%opt)->root;
    $r =~ s{/\.ccpraxis-local-data/almanac\z}{};
    return $r;
}

sub focus {
    my (%opt) = @_;
    my $sess = resolve_session(session => $opt{session});

    my $target_root;
    if (exists $opt{tasklist} && defined $opt{tasklist}) {
        my $tl = $opt{tasklist};
        _usage('bad_tasklist') unless -d $tl;
        $target_root = _canonical_project_root(root => $tl, home => $opt{home});
    } else {
        $target_root = _canonical_project_root(root => $opt{root}, home => $opt{home}, cwd => $opt{cwd});
    }
    $target_root = _decode_maybe($target_root);

    my $fstore = Almanac::Store->open(scope => 'project', type => 'task-focus',
        root => $opt{root}, home => $opt{home}, cwd => $opt{cwd});
    my $now = _now_iso();

    if ($fstore->exists($sess)) {
        my $rec     = $fstore->read($sess);
        my $cur_tl  = defined($rec->{fields}{tasklist}) ? _decode_maybe($rec->{fields}{tasklist}) : undef;
        if (defined($cur_tl) && $cur_tl eq $target_root) {
            return ($rec, 0);
        }
        my %expect = (rev => $rec->{rev}, fields => $rec->{fields});
        my $new = $fstore->update($sess, expect => \%expect,
            set => { tasklist => $target_root, focused_at => $now });
        return ($new, 1);
    }

    my $rec = $fstore->create(id => $sess,
        fields => { tasklist => $target_root, focused_at => $now },
        order  => ['tasklist', 'focused_at']);
    return ($rec, 1);
}

sub focused {
    my (%opt) = @_;
    my $sess   = resolve_session(session => $opt{session});
    my $fstore = Almanac::Store->open(scope => 'project', type => 'task-focus',
        root => $opt{root}, home => $opt{home}, cwd => $opt{cwd});
    return undef unless $fstore->exists($sess);
    my $rec = $fstore->read($sess);
    return defined($rec->{fields}{tasklist}) ? _decode_maybe($rec->{fields}{tasklist}) : undef;
}

sub unfocus {
    my (%opt) = @_;
    my $sess   = resolve_session(session => $opt{session});
    my $fstore = Almanac::Store->open(scope => 'project', type => 'task-focus',
        root => $opt{root}, home => $opt{home}, cwd => $opt{cwd});
    return 0 unless $fstore->exists($sess);
    my $rec = $fstore->read($sess);
    my %expect = (rev => $rec->{rev}, fields => $rec->{fields});
    $fstore->delete($sess, expect => \%expect);
    return 1;
}

# ---------------------------------------------------------------------------
# output formatting (CLI only).
# ---------------------------------------------------------------------------
sub _print_task_result {
    my ($rec, %a) = @_;
    print "id: $rec->{id}\n";
    print "path: " . _decode_maybe($rec->{path}) . "\n";
    print "status: " . (defined $rec->{fields}{status} ? $rec->{fields}{status} : '-') . "\n";
    print "rank: "   . (defined $rec->{rank}            ? $rec->{rank}            : '-') . "\n";
    print "rev: $rec->{rev}\n";
    print "changed: $a{changed}\n";
}

sub _print_list_default {
    my ($list) = @_;
    my $n = 0;
    for my $rec (@$list) {
        $n++;
        my $f = $rec->{fields};
        print "task: $rec->{id}\n";
        print "  position: $n\n";
        print "  status: "     . (defined $f->{status}     ? $f->{status}     : '-') . "\n";
        print "  blocked_on: " . (defined $f->{blocked_on}  ? $f->{blocked_on} : '-') . "\n";
        print "  title: "      . (defined $f->{title}       ? $f->{title}      : '-') . "\n";
    }
    print "total: " . scalar(@$list) . "\n";
}

sub _print_list_json {
    my ($list) = @_;
    my @out;
    my $n = 0;
    for my $rec (@$list) {
        $n++;
        my $f = $rec->{fields};
        push @out, {
            id         => $rec->{id},
            position   => $n,
            rank       => $rec->{rank},
            status     => $f->{status},
            title      => $f->{title},
            blocked_on => (defined $f->{blocked_on} ? $f->{blocked_on} : undef),
        };
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

# _cli_add_opt($o, $bool_default) -> %opt -- shared by add/insert-at/
# insert-before/insert-after (same flag set: title, body, blocked-on, id).
sub _cli_add_opt {
    my ($o, $bool_default) = @_;
    my $title_missing = !exists($o->{title})
        || ($bool_default->{title} && !ref($o->{title}) && $o->{title} eq '1');
    _usage('missing_title') if $title_missing;

    my %opt;
    $opt{root}       = $o->{root}         if exists $o->{root};
    $opt{title}      = $o->{title};
    $opt{body}       = $o->{body}         if exists $o->{body};
    $opt{blocked_on} = $o->{'blocked-on'} if exists $o->{'blocked-on'};
    $opt{id}         = $o->{id}           if exists $o->{id};
    return %opt;
}

sub _cmd_add {
    my ($o, $bool_default) = @_;
    my %opt = _cli_add_opt($o, $bool_default);
    my $rec = add(%opt);
    _print_task_result($rec, changed => 'yes');
}

sub _cmd_insert_at {
    my ($o, $bool_default, $pos) = @_;
    my %opt = _cli_add_opt($o, $bool_default);
    my $rec = insert_at($pos, %opt);
    _print_task_result($rec, changed => 'yes');
}

sub _cmd_insert_before {
    my ($o, $bool_default, $ref_id) = @_;
    my %opt = _cli_add_opt($o, $bool_default);
    my $rec = insert_before($ref_id, %opt);
    _print_task_result($rec, changed => 'yes');
}

sub _cmd_insert_after {
    my ($o, $bool_default, $ref_id) = @_;
    my %opt = _cli_add_opt($o, $bool_default);
    my $rec = insert_after($ref_id, %opt);
    _print_task_result($rec, changed => 'yes');
}

sub _cmd_move_first {
    my ($o, $id) = @_;
    my ($rec, $changed) = move_first($id, root => $o->{root});
    _print_task_result($rec, changed => ($changed ? 'yes' : 'no'));
}

sub _cmd_move_last {
    my ($o, $id) = @_;
    my ($rec, $changed) = move_last($id, root => $o->{root});
    _print_task_result($rec, changed => ($changed ? 'yes' : 'no'));
}

sub _cmd_reorder {
    my ($o, $ids) = @_;
    my $records = reorder($ids, root => $o->{root});
    for my $rec (@$records) { print "id: $rec->{id}\n" }
    print "total: " . scalar(@$records) . "\n";
}

sub _cmd_status {
    my ($o, $pos) = @_;
    my ($id, $status) = @$pos;
    my %extra;
    $extra{'expect-rev'} = $o->{'expect-rev'} if exists $o->{'expect-rev'};
    my ($rec, $changed) = set_status($id, $status, root => $o->{root}, %extra);
    _print_task_result($rec, changed => ($changed ? 'yes' : 'no'));
}

sub _cmd_edit {
    my ($o, $bool_default, $id) = @_;
    my $title_given   = exists $o->{title};
    _usage('missing_flag_value') if $title_given && $bool_default->{title};
    my $body_given    = exists $o->{body};
    my $blocked_given = exists $o->{'blocked-on'};
    my $clear_given   = exists $o->{'clear-blocked-on'};

    _usage('blocked_on_conflict')
        if $blocked_given && $clear_given;
    _usage('nothing_to_change')
        unless $title_given || $body_given || $blocked_given || $clear_given;

    my %set;
    if ($title_given) {
        my $t = _trim($o->{title});
        _usage('bad_title') if $t eq '' || $t =~ /[\r\n]/;
        $set{title} = $t;
    }
    if ($blocked_given) {
        my $v = $o->{'blocked-on'};
        _usage('bad_blocked_on') unless _valid_ref_id($v);
        $set{blocked_on} = $v;
    }

    my $store = open_tasklist(root => $o->{root});
    my $rec   = $store->read($id);

    my @unset;
    push @unset, 'blocked_on' if $clear_given && exists $rec->{fields}{blocked_on};

    my $any_change = $title_given || $body_given || $blocked_given || @unset;
    unless ($any_change) {
        _print_task_result($rec, changed => 'no');
        return;
    }

    my %expect = (rev => $rec->{rev}, fields => $rec->{fields});
    $expect{rev} = $o->{'expect-rev'} if exists $o->{'expect-rev'};

    my %update_args = (expect => \%expect, set => \%set, unset => \@unset);
    $update_args{body} = $o->{body} if $body_given;

    my $new = $store->update($id, %update_args);
    _print_task_result($new, changed => 'yes');
}

sub _cmd_list {
    my ($o) = @_;
    my $list = open_tasklist(root => $o->{root})->list();
    if ($o->{json}) { _print_list_json($list) }
    else            { _print_list_default($list) }
}

sub _cmd_show {
    my ($o, $id) = @_;
    my $rec = open_tasklist(root => $o->{root})->read($id);
    if ($o->{json}) { _print_show_json($rec) }
    else            { _print_show_default($rec) }
}

sub _cmd_focus {
    my ($o) = @_;
    my ($rec, $changed) = focus(session => $o->{session}, tasklist => $o->{tasklist}, root => $o->{root});
    print "session: $rec->{id}\n";
    print "tasklist: " . _decode_maybe($rec->{fields}{tasklist}) . "\n";
    print "changed: " . ($changed ? 'yes' : 'no') . "\n";
}

sub _cmd_focused {
    my ($o) = @_;
    my $sess     = resolve_session(session => $o->{session});
    my $tasklist = focused(session => $sess, root => $o->{root});
    if ($o->{json}) {
        print JSON::PP->new->canonical(1)->encode({ session => $sess, tasklist => $tasklist });
    } else {
        print "session: $sess\n";
        print "tasklist: " . (defined $tasklist ? _decode_maybe($tasklist) : '-') . "\n";
    }
}

sub _cmd_unfocus {
    my ($o) = @_;
    my $sess    = resolve_session(session => $o->{session});
    my $changed = unfocus(session => $sess, root => $o->{root});
    print "session: $sess\n";
    print "changed: " . ($changed ? 'yes' : 'no') . "\n";
}

# ---------------------------------------------------------------------------
# CLI entry point.
# ---------------------------------------------------------------------------
unless (caller) {
    # Retired CLI (blueprint where-things-go, package 02-thread-store,
    # Decision 3): threads replace the flat tasklist and per-session focus.
    # Every argv -- every old verb, no verb at all -- prints exactly this
    # pointer to STDERR and exits 2, before anything else runs. The library
    # half above (lines 1-575ish) is unchanged: requiring this file still
    # defines Almanac::Task::* and prints nothing.
    print STDERR "almanac: 'almanac task' is retired; use 'almanac thread' instead\n";
    exit 2;
}

1;
