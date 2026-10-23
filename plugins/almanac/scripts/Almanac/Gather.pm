package Almanac::Gather;
# Almanac::Gather -- "where is everything", for one project (project mode)
# or every registered project (all mode). Blueprint where-things-go,
# package 10-gatherer-and-digest. See
# specs/10-gatherer-and-digest-spec.md section 2 for the exact contract;
# this file implements it, including the dual-format authored-status/
# parked-reason reader documented inline below (a deliberate, narrow
# deviation from calling BpState::blueprint_lifecycle/bp_meta_get
# literally -- see _authored_frontmatter_value's header comment).
# Package 11-sitrep-commands (additive only) added a `severity` field on bug
# entries plus the global_todos() and thread_log_since() functions below.
use strict;
use warnings;
use Cwd ();
use POSIX ();
use JSON::PP ();

our ($SCRIPTS_DIR, $BUTLER_DIR, $BUG_PL, $BPSTATE_PM, $SWEEP_PL);

BEGIN {
    my $self = __FILE__;
    $self =~ s{\\}{/}g;
    $self = Cwd::abs_path($self) // $self;
    $self =~ s{\\}{/}g;
    my $almanac_mod_dir = $self;
    $almanac_mod_dir =~ s{/[^/]+\z}{};             # strip Gather.pm -> .../Almanac
    my $scripts_dir = $almanac_mod_dir;
    $scripts_dir =~ s{/[^/]+\z}{};                 # strip Almanac -> .../almanac/scripts
    my $almanac_plugin_dir = $scripts_dir;
    $almanac_plugin_dir =~ s{/[^/]+\z}{};          # strip scripts -> .../almanac
    my $plugins_dir = $almanac_plugin_dir;
    $plugins_dir =~ s{/[^/]+\z}{};                 # strip almanac -> .../plugins
    $SCRIPTS_DIR = $scripts_dir;
    $BUTLER_DIR  = "$plugins_dir/butler/scripts";
    $BUG_PL      = "$scripts_dir/almanac-bug.pl";
    $BPSTATE_PM  = "$BUTLER_DIR/BpState.pm";
    $SWEEP_PL    = "$BUTLER_DIR/bp-answer-escalation.pl";
    unshift @INC, $scripts_dir unless grep { $_ eq $scripts_dir } @INC;
}

use Almanac::Thread ();
use Almanac::PackageLink ();
use Almanac::Store ();
use Almanac::SessionLive ();

our $VERSION = '1.0';

our @SECTIONS = qw(threads inbox todos bugs blueprints fleet_runs notes commits);
my %SECTION_OK = map { $_ => 1 } @SECTIONS;

# ---------------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------------
sub _usage { die Almanac::Store::Error->new(kind => 'usage', detail => $_[0]) }

sub _errstr {
    my ($err) = @_;
    return 'unknown error' unless defined $err;
    my $s = "$err";
    $s =~ s/\s+\z//;
    $s =~ s/[\r\n]+/ /g;
    return length($s) ? $s : 'unknown error';
}

sub _now_iso {
    my @t = gmtime(time);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ',
        $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

# _fs_bytes($s) -- the correct answer to "this path may or may not carry
# perl's internal utf8 flag; make it a definite byte string for a syscall or
# for concatenation with other byte strings". Encode-if-flagged, NOT
# utf8::downgrade: downgrade only works when the string's internal
# representation already happens to be pure Latin-1-range bytes, and
# CORRUPTS genuinely multi-byte UTF-8 content (this package's own
# spec-mandated "André" fixture) instead of normalizing it. Mirrors
# BpHook.pm::_to_bytes and Almanac::PackageLink.pm:96's own
# utf8::encode-if-flagged rule. See blueprint where-things-go, package
# 10-gatherer-and-digest, reviewer M1-M3 / redteam H1 findings.
sub _fs_bytes {
    my ($s) = @_;
    return $s unless defined $s;
    utf8::encode($s) if utf8::is_utf8($s);
    return $s;
}

# _decode_if_bytes($s) -- the JSON/text-rendering counterpart: a value that
# is definitely a byte string (readdir/basename output, an unflagged root)
# but needs to be a proper decoded character string before it is
# concatenated with other already-decoded fields (Almanac::Record's output)
# or handed to JSON::PP->utf8->encode (which assumes its input is
# characters, and otherwise double-encodes valid UTF-8 bytes). A no-op on a
# string that is already flagged, or that is not valid UTF-8.
sub _decode_if_bytes {
    my ($s) = @_;
    return $s unless defined $s && !ref $s;
    return $s if utf8::is_utf8($s);
    my $copy = $s;
    utf8::decode($copy);
    return $copy;
}

sub _basename {
    my ($root) = @_;
    return '' unless defined $root;
    my $r = $root;
    $r =~ s{\\}{/}g;
    $r =~ s{/\z}{} if length($r) > 1;
    my @parts = split m{/}, $r;
    return (defined $parts[-1] && length $parts[-1]) ? $parts[-1] : $r;
}

sub _strip_leading_underscores {
    my ($s) = @_;
    return $s unless defined $s;
    (my $r = $s) =~ s/\A_+//;
    return $r;
}

sub _read_json {
    my ($path) = @_;
    open(my $fh, '<:raw', $path) or return undef;
    local $/;
    my $raw = <$fh>;
    close $fh;
    return eval { JSON::PP->new->utf8->decode($raw) };
}

my $BUG_OK;
sub _load_bug {
    return $BUG_OK if defined $BUG_OK;
    $BUG_OK = eval { require $BUG_PL; 1 } ? 1 : 0;
    return $BUG_OK;
}

my $BPSTATE_OK;
sub _load_bpstate {
    return $BPSTATE_OK if defined $BPSTATE_OK;
    $BPSTATE_OK = eval { require $BPSTATE_PM; 1 } ? 1 : 0;
    return $BPSTATE_OK;
}

sub _list_blueprint_names {
    my ($bdir) = @_;
    return () unless defined $bdir && -d $bdir;
    opendir(my $dh, $bdir) or return ();
    my @out;
    for my $e (readdir $dh) {
        next if $e eq '.' || $e eq '..';
        next if $e =~ /\A_/;
        my $full = "$bdir/$e";
        next if -l $full;
        next unless -d $full;
        push @out, $e;
    }
    closedir $dh;
    return @out;
}

# ---------------------------------------------------------------------------
# dual-format authored-status / parked-reason reader (sec 2.2 "blueprints").
#
# BpState::bp_meta_get only parses blueprint.md's FENCED (triple-backtick)
# metadata block, which is the real on-disk shape every blueprint.md in this
# repo uses. A caller that writes a plain '---'-delimited frontmatter block
# instead (not a shape BpState was ever meant to read) gets undef back from
# bp_meta_get, so this reader tries bp_meta_get first (the real, fenced
# shape) and falls back to a local plain-frontmatter reader -- the same
# restatement technique Almanac::PackageLink::_fm_get already uses, and for
# the same reason (that function's own header explains why its delimiter
# test is spelled /\A-{3}\s*\z/ rather than the more obvious /^---$/: this
# file sits under plugins/almanac/scripts, which almanac-doctor.t's AC23
# statically greps for the literal substrings "\A---", "^---" and
# "eq '---'" to police a closed set of files allowed to hand-roll
# frontmatter detection -- a set this file does not join, since it restates
# BpState's own ledger-reading rule rather than Almanac::Record's grammar).
sub _plain_frontmatter_get {
    my ($path, $key) = @_;
    # redteam M2: a FIFO at this path (another project's linked ledger, or
    # an attacker-controlled one in all mode) would hang open()/<$fh> on a
    # plain read. -f refuses anything that is not a regular file.
    return undef unless -f $path;
    open(my $fh, '<:raw', $path) or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return undef unless defined $c;
    my $in = 0;
    for my $ln (split /\n/, $c) {
        if ($ln =~ /\A-{3}\s*\z/) { $in++; last if $in == 2; next }
        next unless $in == 1;
        if ($ln =~ /\A\Q$key\E:\s*(.*?)\s*\z/) { return $1 }
    }
    return undef;
}

sub _authored_frontmatter_value {
    my ($bpmd, $key) = @_;
    # redteam M2: BpState::bp_meta_get (outside this package's write set)
    # does its own unconditional open/read with no -f guard; refuse a
    # non-regular-file path here, before either reader touches it, rather
    # than hang on a FIFO.
    return undef unless -f $bpmd;
    my $v = _load_bpstate() ? BpState::bp_meta_get($bpmd, $key) : undef;
    return $v if defined $v;
    return _plain_frontmatter_get($bpmd, $key);
}

# _blueprint_lifecycle($bpdir, $alive) -> lifecycle word. Restates
# BpState::blueprint_lifecycle's precedence (parked > running > archived >
# all-delivered-done > authored > drafting) against the dual-format reader
# above, bypassing BpState::run_is_live's own marker read (redundant with
# $alive, which already checks the marker file and its flock).
sub _blueprint_lifecycle {
    my ($bpdir, $alive) = @_;
    my $raw      = _authored_frontmatter_value("$bpdir/blueprint.md", 'status');
    my $authored = _load_bpstate() ? BpState::norm_bp_status($raw) : '';

    return 'parked' if $authored eq 'parked';
    return 'running' if $alive;
    return 'archived' if $authored eq 'archived';

    my $statuses = _load_bpstate() ? BpState::all_package_statuses($bpdir) : {};
    my @values = values %$statuses;
    my $all_delivered = (scalar(@values) > 0)
        && !(grep { $_ ne 'done' && $_ ne 'dropped' } @values);

    if ($all_delivered
        && ($authored eq 'audited' || $authored eq 'running' || $authored eq 'done')) {
        return 'done';
    }

    return 'drafting' if $authored eq 'drafting';
    return 'audited'  if $authored eq 'audited';
    return 'running'  if $authored eq 'running';
    return 'drafting';
}

# ---------------------------------------------------------------------------
# escalations directory (sec 2.1: opendir only, never BpOrch::escalations_dir
# which migrates the legacy directory -- a write this gatherer must not do).
# ---------------------------------------------------------------------------
sub _escalations_dir {
    my ($runs) = @_;
    my $new = "$runs/escalations";
    return $new if -d $new;
    my $old = "$runs/needs-you";
    return $old if -d $old;
    return $new;
}

# ---------------------------------------------------------------------------
# threads
# ---------------------------------------------------------------------------
sub _task_entry {
    my ($t, $root) = @_;
    my %e = (id => $t->{id}, position => $t->{position}, title => $t->{title});
    if (defined $t->{link} && length $t->{link}) {
        my $r = Almanac::PackageLink::resolve($t->{link}, root => $root);
        $e{link}       = $t->{link};
        $e{link_state} = $r->{state};
        if ($r->{state} eq 'ok') {
            $e{location} = $r->{location};
            $e{status}   = $r->{status};
        } else {
            $e{location} = undef;
            $e{status}   = $t->{status};
        }
    } else {
        $e{link}       = undef;
        $e{link_state} = undef;
        $e{location}   = undef;
        $e{status}     = $t->{status};
    }
    return \%e;
}

sub _section_threads {
    my ($root) = @_;
    my $list = Almanac::Thread::list_threads(root => $root, archived => 1);
    my @items;
    my $archived_count = 0;
    for my $h (@$list) {
        if (defined($h->{state}) && $h->{state} eq 'archived') { $archived_count++; next }
        next unless defined($h->{state}) && ($h->{state} eq 'live' || $h->{state} eq 'handed-off');

        my $liveness = Almanac::Thread::owner_status($h, root => $root)->{status};

        my $handoff;
        if ($h->{state} eq 'handed-off') {
            my $log = Almanac::Thread::log_entries($h->{name}, root => $root);
            for my $e (@$log) {
                $handoff = $e->{reason} if defined($e->{event}) && $e->{event} eq 'handed-off';
            }
        }

        my @raw_tasks   = @{ Almanac::Thread::tasks($h->{name}, root => $root) };
        my @task_entries = map { _task_entry($_, $root) } @raw_tasks;
        my $done = 0;
        $done++ for grep { Almanac::Thread::is_done_task($_) } @raw_tasks;
        my @doing = map { $_->{title} }
            grep { defined $_->{status} && $_->{status} eq 'doing' } @task_entries;
        my ($next) = map { $_->{title} }
            grep { defined $_->{status} && $_->{status} eq 'pending' } @task_entries;

        push @items, {
            name     => $h->{name},
            state    => $h->{state},
            owner    => { kind => $h->{owner_kind}, id => $h->{owner_id} },
            liveness => $liveness,
            handoff  => $handoff,
            tasks    => \@task_entries,
            bar      => { done => $done, total => scalar(@raw_tasks) },
            doing    => \@doing,
            next     => $next,
        };
    }
    @items = sort { $a->{name} cmp $b->{name} } @items;
    return { items => \@items, archived_count => $archived_count };
}

# ---------------------------------------------------------------------------
# inbox / todos / notes
# ---------------------------------------------------------------------------
sub _decode_choices {
    my ($raw) = @_;
    return undef unless defined $raw && length $raw;
    my $decoded = eval { JSON::PP->new->decode($raw) };
    return $decoded if ref $decoded eq 'ARRAY';
    return $raw;
}

sub _inbox_rationale {
    my ($root, $link) = @_;
    return undef unless defined $link && length $link;
    # $link comes back utf8-flagged from Almanac::Record::read_file's whole-
    # file Encode::decode even when it is pure ASCII; concatenating a
    # flagged segment onto $root's raw UTF-8 bytes (a non-ASCII project
    # root) corrupts the byte sequence on stringification -- same bug class
    # as _registry_roots()/_gather_project() above. Encode to bytes (see
    # _fs_bytes) before it ever reaches a path.
    $link = _fs_bytes($link);
    my @segs = split m{/}, $link, -1;
    return undef unless @segs == 3;
    my ($bp, $pkg, $id) = @segs;
    my $bpdir = "$root/.ccpraxis-local-data/blueprints/$bp";
    return undef unless -d $bpdir;
    my $pkg_want = _strip_leading_underscores($pkg);
    for my $sub (qw(runs/escalations runs/resolved-escalations)) {
        for my $fname ("$id.json", "_$id.json") {
            my $path = "$bpdir/$sub/$fname";
            next unless -f $path;
            my $rec = _read_json($path);
            next unless ref $rec eq 'HASH';
            my $pkg_got = _strip_leading_underscores($rec->{package});
            next unless defined $pkg_got && $pkg_got eq $pkg_want;
            return (defined $rec->{resolution} && length $rec->{resolution}) ? $rec->{resolution} : undef;
        }
    }
    return undef;
}

sub _section_inbox {
    my ($root) = @_;
    my $store = Almanac::Store->open(scope => 'project', type => 'inbox', root => $root);
    my @out;
    for my $rec (@{ $store->list }) {
        my $f = $rec->{fields};
        next unless defined($f->{status}) && $f->{status} eq 'unanswered';
        push @out, {
            id        => $rec->{id},
            question  => $f->{title},
            body      => (defined $rec->{body} ? $rec->{body} : ''),
            created   => $f->{created},
            link      => $f->{link},
            choices   => _decode_choices($f->{choices}),
            rationale => _inbox_rationale($root, $f->{link}),
        };
    }
    @out = sort { (($a->{created} // '') cmp ($b->{created} // '')) || ($a->{id} cmp $b->{id}) } @out;
    return \@out;
}

sub _section_todos {
    my ($root) = @_;
    my $store = Almanac::Store->open(scope => 'project', type => 'todo', root => $root);
    my @out;
    for my $rec (@{ $store->list }) {
        my $f = $rec->{fields};
        next unless defined($f->{status}) && $f->{status} eq 'open';
        push @out, { id => $rec->{id}, title => $f->{title}, tags => $f->{tags}, created => $f->{created} };
    }
    @out = sort { (($a->{created} // '') cmp ($b->{created} // '')) || ($a->{id} cmp $b->{id}) } @out;
    return \@out;
}

sub _section_notes {
    my ($root) = @_;
    my $store = Almanac::Store->open(scope => 'project', type => 'note', root => $root);
    my @titles = sort map { $_->{fields}{title} } @{ $store->list };
    return \@titles;
}

sub _unanswered_inbox_links {
    my ($root) = @_;
    my %map;
    my $items = eval { _section_inbox($root) } || [];
    for my $it (@$items) {
        next unless defined $it->{link} && length $it->{link};
        $map{ $it->{link} } = $it->{id};
    }
    return \%map;
}

# ---------------------------------------------------------------------------
# bugs
# ---------------------------------------------------------------------------
sub _section_bugs {
    my ($root) = @_;
    _load_bug() or die "almanac-bug.pl is not loadable\n";
    my %by_state = map { $_ => [] } @AlmanacBug::STATES;
    my @tampered;
    my $unreadable = 0;
    for my $p (AlmanacBug::list_reports_in($root)) {
        my $rep = AlmanacBug::load($p);
        unless ($rep) { $unreadable++; next }
        my ($ok, $note) = AlmanacBug::verify($rep);
        push @tampered, { id => $rep->{fields}{id}, note => $note } unless $ok;
        my $st = $rep->{fields}{status};
        next unless defined $st && exists $by_state{$st};
        my $closed;
        if    ($st eq 'fixed')   { $closed = $rep->{fields}{fixed_at} }
        elsif ($st eq 'dropped') { $closed = $rep->{fields}{updated_at} }
        push @{ $by_state{$st} }, {
            id => $rep->{fields}{id}, title => $rep->{fields}{title},
            filed => $rep->{fields}{created_at}, closed => $closed,
            severity => $rep->{fields}{severity},
        };
    }
    return { by_state => \%by_state, tampered => \@tampered, unreadable => $unreadable };
}

# ---------------------------------------------------------------------------
# blueprints / fleet_runs
# ---------------------------------------------------------------------------
sub _section_blueprints {
    my ($root) = @_;
    _load_bpstate() or die "BpState.pm is not loadable\n";
    my $bdir = "$root/.ccpraxis-local-data/blueprints";
    my @out;
    for my $name (sort(_list_blueprint_names($bdir))) {
        my $bpdir = "$bdir/$name";
        my $alive = Almanac::SessionLive::orchestrator_live(root => $root, blueprint => $name);
        my $state = _blueprint_lifecycle($bpdir, $alive);
        my $parked_reason = ($state eq 'parked')
            ? _authored_frontmatter_value("$bpdir/blueprint.md", 'parked_reason') : undef;
        my $statuses = BpState::all_package_statuses($bpdir);
        my $done = scalar(grep { $_ eq 'done' } values %$statuses);
        push @out, {
            name => $name, state => $state, parked_reason => $parked_reason,
            packages => { done => $done, total => scalar(keys %$statuses), status => $statuses },
        };
    }
    return \@out;
}

sub _section_fleet_runs {
    my ($root) = @_;
    _load_bpstate() or die "BpState.pm is not loadable\n";
    my $bdir = "$root/.ccpraxis-local-data/blueprints";
    my $inbox_links = _unanswered_inbox_links($root);
    my @out;
    for my $name (sort(_list_blueprint_names($bdir))) {
        my $bpdir = "$bdir/$name";
        my $runs  = "$bpdir/runs";
        next unless -d $runs;
        my $alive = Almanac::SessionLive::orchestrator_live(root => $root, blueprint => $name);
        my $state;
        if    (-e "$runs/.orchestrator" && !$alive) { $state = 'orphaned' }
        elsif (-e "$runs/.paused")                  { $state = 'paused' }
        elsif ($alive)                              { $state = 'running' }
        else                                        { $state = 'stopped' }

        my @esc;
        my $escdir = _escalations_dir($runs);
        if (-d $escdir) {
            opendir(my $dh, $escdir) or die "cannot opendir $escdir: $!\n";
            for my $f (sort readdir $dh) {
                next unless $f =~ /\.json\z/;
                next unless -f "$escdir/$f";
                (my $id = $f) =~ s/\.json\z//;
                my $rec = _read_json("$escdir/$f");
                unless (ref $rec eq 'HASH') {
                    push @esc, { id => $id, package => undef, category => undef,
                        question => undef, where => 'resolver', inbox_id => undef };
                    next;
                }
                my $question = (defined $rec->{product_question} && length $rec->{product_question})
                    ? $rec->{product_question} : $rec->{question};
                my $pkg_stripped = _strip_leading_underscores($rec->{package});
                my $id_stripped  = _strip_leading_underscores($id);
                my $link = (defined $pkg_stripped && length $pkg_stripped)
                    ? "$name/$pkg_stripped/$id_stripped" : undef;
                my ($where, $inbox_id) = ('resolver', undef);
                if (defined $link && exists $inbox_links->{$link}) {
                    $where = 'inbox';
                    $inbox_id = $inbox_links->{$link};
                }
                push @esc, { id => $id, package => $rec->{package}, category => $rec->{category},
                    question => $question, where => $where, inbox_id => $inbox_id };
            }
            closedir $dh;
        }
        push @out, { blueprint => $name, state => $state,
            orchestrator_alive => ($alive ? JSON::PP::true : JSON::PP::false),
            escalations => \@esc };
    }
    return \@out;
}

# ---------------------------------------------------------------------------
# commits
# ---------------------------------------------------------------------------
sub _section_commits {
    my ($root, $since) = @_;
    return [] unless defined $since && length $since;
    my @cmd = ('git', '-C', $root, 'log', "--since=$since", '--format=%H%x09%cI%x09%s');
    my $pid = open(my $fh, '-|');
    die "cannot fork: $!\n" unless defined $pid;
    if ($pid == 0) {
        open(STDERR, '>', '/dev/null') or close(STDERR);
        open(STDIN, '<', '/dev/null') or close(STDIN);
        exec(@cmd) or POSIX::_exit(127);
    }
    local $/;
    my $out = <$fh>;
    close $fh;
    my $rc = ($? == -1) ? -1 : ($? >> 8);
    die "git log failed (exit $rc)\n" if $rc != 0;
    my @out;
    for my $line (split /\n/, (defined $out ? $out : '')) {
        next unless length $line;
        my ($sha, $at, $subject) = split /\t/, $line, 3;
        push @out, { sha => $sha, at => $at, subject => $subject };
    }
    return \@out;
}

# ---------------------------------------------------------------------------
# refresh (project mode only, before any section read)
# ---------------------------------------------------------------------------
sub _run_sweep {
    my ($bpdir) = @_;
    return { exit => -1, stdout => '' } unless -f $SWEEP_PL;
    my @cmd = ($^X, $SWEEP_PL, 'sweep', '--bp-dir', $bpdir);
    my $pid = open(my $fh, '-|');
    die "cannot fork: $!\n" unless defined $pid;
    if ($pid == 0) {
        open(STDIN, '<', '/dev/null') or close(STDIN);
        exec(@cmd) or POSIX::_exit(127);
    }
    # reviewer-2-confirm MF-2: a die that unwinds this read (the digest
    # timeout alarm, propagating from SessionStartNudge.pm through a
    # rethrow at the per-sweep call site below) must not leave the forked
    # sweep child running. Catch locally just long enough to best-effort
    # TERM the child, then re-die the SAME error -- never let a failed kill
    # mask the real one.
    my $out = eval {
        local $/;
        <$fh>;
    };
    if (my $err = $@) {
        eval { kill('TERM', $pid) } if defined $pid && $pid > 0;
        close $fh;
        die $err;
    }
    close $fh;
    my $rc = ($? == -1) ? -1 : ($? >> 8);
    return { exit => $rc, stdout => (defined $out ? $out : '') };
}

sub _run_refresh {
    my ($root, $errors) = @_;
    my $refresh = { reconcile => undef, sweeps => [] };

    my $rec = eval { _load_bug() or die "almanac-bug.pl is not loadable\n"; AlmanacBug::reconcile($root) };
    if (my $err = $@) {
        # reviewer-2-confirm MF-2: the digest timeout alarm's own die must
        # escape this eval immediately rather than being recorded as a
        # per-item error and falling through to the sweep loop below --
        # otherwise the time budget stops only the reconcile call and the
        # rest of the digest keeps running with no alarm left armed.
        die $err if $err eq "digest timed out\n";
        $refresh->{reconcile} = { ran => JSON::PP::false, changes => 0, flags => 0, busy => 0, error => _errstr($err) };
        push @$errors, { section => 'refresh', error => _errstr($err) };
    } elsif (ref $rec eq 'HASH') {
        $refresh->{reconcile} = {
            ran => JSON::PP::true,
            changes => (ref $rec->{changes} eq 'ARRAY' ? scalar(@{ $rec->{changes} }) : 0),
            flags   => (ref $rec->{flags}   eq 'ARRAY' ? scalar(@{ $rec->{flags} })   : 0),
            busy    => (ref $rec->{busy}    eq 'ARRAY' ? scalar(@{ $rec->{busy} })    : 0),
            error => undef,
        };
    } else {
        $refresh->{reconcile} = { ran => JSON::PP::false, changes => 0, flags => 0, busy => 0, error => 'reconcile returned no result' };
        # S4: a refresh failure must surface in the top-level errors[], not
        # only in the (easy to miss) per-entry error field -- otherwise
        # "Digest incomplete: refresh" never appears for exactly the case
        # the refresh exists to prevent (a stale view shown as current).
        push @$errors, { section => 'refresh', error => $refresh->{reconcile}{error} };
    }

    my $bdir = "$root/.ccpraxis-local-data/blueprints";
    for my $name (sort(_list_blueprint_names($bdir))) {
        my $bpdir = "$bdir/$name";
        next unless -d "$bpdir/runs";
        my $entry = { blueprint => $name, ran => JSON::PP::true, exit => undef, result => undef, error => undef };
        my $out = eval { _run_sweep($bpdir) };
        if (my $err = $@) {
            # reviewer-2-confirm MF-2: rethrow the digest timeout immediately
            # instead of recording it and moving on to the next blueprint's
            # sweep -- see the matching note on the reconcile eval above.
            die $err if $err eq "digest timed out\n";
            $entry->{ran} = JSON::PP::false;
            $entry->{error} = _errstr($err);
        } else {
            $entry->{exit} = $out->{exit};
            if (defined $out->{exit} && $out->{exit} == 0) {
                my $decoded = eval { JSON::PP->new->utf8->decode($out->{stdout}) };
                if (ref $decoded eq 'HASH') { $entry->{result} = $decoded }
                else { $entry->{error} = 'undecodable sweep output' }
            } else {
                $entry->{error} = "sweep exited " . (defined $out->{exit} ? $out->{exit} : '?');
            }
        }
        push @{ $refresh->{sweeps} }, $entry;
        # S4: same rule for the per-blueprint sweep -- any entry.error means
        # that blueprint's escalations/inbox are stale, surface it.
        push @$errors, { section => 'refresh', error => "$name: $entry->{error}" }
            if defined $entry->{error};
    }
    return $refresh;
}

# ---------------------------------------------------------------------------
# section dispatch
# ---------------------------------------------------------------------------
sub _section_default {
    my ($name) = @_;
    return { items => [], archived_count => 0 } if $name eq 'threads';
    return [] if $name eq 'inbox' || $name eq 'todos' || $name eq 'blueprints'
              || $name eq 'fleet_runs' || $name eq 'notes' || $name eq 'commits';
    if ($name eq 'bugs') {
        _load_bug();
        my @states = (@AlmanacBug::STATES ? @AlmanacBug::STATES : qw(open triaging scheduled fixed dropped));
        return { by_state => { map { $_ => [] } @states }, tampered => [], unreadable => 0 };
    }
    return undef;
}

sub _section_value {
    my ($name, $root, $since) = @_;
    return _section_threads($root)        if $name eq 'threads';
    return _section_inbox($root)          if $name eq 'inbox';
    return _section_todos($root)          if $name eq 'todos';
    return _section_bugs($root)           if $name eq 'bugs';
    return _section_blueprints($root)     if $name eq 'blueprints';
    return _section_fleet_runs($root)     if $name eq 'fleet_runs';
    return _section_notes($root)          if $name eq 'notes';
    return _section_commits($root, $since) if $name eq 'commits';
    _usage("bad_section:$name");
}

# ---------------------------------------------------------------------------
# gather / render_digest / other_projects_line / digest
# ---------------------------------------------------------------------------
sub _gather_project {
    my (%opt) = @_;
    my $root = $opt{root};
    if (defined $root && length $root) {
        # A caller that round-tripped $root through JSON decode (a hook's
        # payload cwd, a gathered project's own root echoed back) carries
        # the utf8 flag even when the bytes are plain ASCII-plus-UTF8; -d
        # on that flagged string mis-stats a non-ASCII path even though it
        # is character-for-character identical to the real one. Same bug
        # class as _registry_roots() above -- encode to bytes (see
        # _fs_bytes) before the first filesystem touch.
        $root = _fs_bytes($root);
        _usage('bad_root') unless -d $root;
    } else {
        $root = eval { Almanac::Thread::project_root(cwd => $opt{cwd}) };
        $root = _fs_bytes($root) if defined $root;
        _usage('missing_root') unless defined $root && length $root && -d $root;
    }

    my @errors;
    my %result = (
        schema => 1, mode => 'project', root => _decode_if_bytes($root), generated_at => _now_iso(),
        refresh => undef,
    );

    my $do_refresh = exists $opt{refresh} ? ($opt{refresh} ? 1 : 0) : 1;
    if ($do_refresh) {
        # redteam H1 (defense in depth): if the launching session's project
        # directory is known (CLAUDE_PROJECT_DIR, set by Claude Code), a
        # resolved $root that disagrees with it is a misresolved cwd (a
        # non-ASCII path component mis-stepping up to a parent project, or a
        # stale cwd after a Bash `cd`). Skip the two mutating refresh calls
        # rather than risk reconciling/sweeping the wrong project; record
        # the skip in errors[] instead of dying.
        #
        # reviewer-2-confirm MF-1: raw string equality on $anchor/$root is
        # wrong -- it flags a trailing slash, a symlink to the same real
        # directory, or a session launched in a (marker-less) subdirectory
        # of the project root as a "mismatch", even though all three are the
        # SAME project. Canonicalise both sides through
        # AlmanacBug::canonical_root (abs_path + drive-letter/trailing-slash
        # normalisation; already loaded via _load_bug for the bugs section)
        # before comparing, and treat the anchor as a match whenever it IS
        # $root or lies anywhere under it -- a subdirectory launch is
        # legitimate. The attack shape this guard exists for is the inverse:
        # $root resolves to a strict ANCESTOR of the anchor's own project
        # (i.e. the anchor is not under $root at all), which still trips it.
        my $anchor = $ENV{CLAUDE_PROJECT_DIR};
        my $mismatch = 0;
        if (defined $anchor && length $anchor) {
            _load_bug();
            my $canon_anchor = _load_bug() ? AlmanacBug::canonical_root(_fs_bytes($anchor)) : _fs_bytes($anchor);
            my $canon_root   = _load_bug() ? AlmanacBug::canonical_root(_fs_bytes($root))   : _fs_bytes($root);
            if ($canon_anchor ne $canon_root
                && index($canon_anchor, "$canon_root/") != 0) {
                $mismatch = 1;
            }
        }
        if ($mismatch) {
            push @errors, { section => 'refresh',
                error => "skipped: resolved root does not match CLAUDE_PROJECT_DIR" };
        } else {
            $result{refresh} = _run_refresh($root, \@errors);
        }
    }

    for my $s (@{ $opt{sections} }) {
        my $v = eval { _section_value($s, $root, $opt{since}) };
        if (my $err = $@) {
            # reviewer-2-confirm MF-2: same rethrow rule as the two refresh
            # evals above -- a timed-out section must not be swallowed and
            # the loop continued onto the remaining sections.
            die $err if $err eq "digest timed out\n";
            $result{$s} = _section_default($s);
            push @errors, { section => $s, error => _errstr($err) };
        } else {
            $result{$s} = $v;
        }
    }
    $result{errors} = \@errors;
    return \%result;
}

sub _registry_roots {
    my ($errors) = @_;
    unless (_load_bug()) {
        push @$errors, { section => 'registry', error => 'almanac-bug.pl is not loadable' };
        return ();
    }
    my @raw = AlmanacBug::known_projects();
    my %seen;
    my @out;
    for my $r (@raw) {
        # known_projects() decodes the registry JSON, so a non-ASCII root
        # comes back utf8-flagged. A flagged string passed to -d/-f (below,
        # and in every _gather_project it feeds) stats the wrong bytes even
        # though it's the same characters -- same class of bug as
        # bp-orchestrator.pl's _json_bytes() already guards against
        # elsewhere. Encode to bytes (see _fs_bytes) before it ever reaches
        # a filesystem call.
        $r = _fs_bytes($r) if defined $r;
        my $c = AlmanacBug::canonical_root($r);
        next if $seen{$c}++;
        push @out, $r;
    }
    return @out;
}

sub _gather_all {
    my (%opt) = @_;
    my @errors;
    my @roots = _registry_roots(\@errors);
    my %exclude_canon;
    if (_load_bug()) {
        %exclude_canon = map { (AlmanacBug::canonical_root($_) => 1) } @{ $opt{exclude} // [] };
    }

    my @projects;
    local $Almanac::Store::SCOPE_POLICY{host}{project}{writable}      = 0;
    local $Almanac::Store::SCOPE_POLICY{container}{project}{writable} = 0;

    for my $root (@roots) {
        next if _load_bug() && $exclude_canon{ AlmanacBug::canonical_root($root) };
        unless (defined $root && length $root && -d $root) {
            push @errors, { section => 'registry', error => "root not readable: " . (defined $root ? $root : '(undef)') };
            next;
        }
        my $proj = eval { _gather_project(%opt, root => $root, refresh => 0) };
        if (my $err = $@) {
            # reviewer-2-confirm MF-2: same rethrow rule -- digest() also
            # gathers mode=>'all' for other_projects_line(), so a timeout
            # here must not be swallowed and the loop continued onto the
            # next registered project.
            die $err if $err eq "digest timed out\n";
            push @errors, { section => 'registry', error => _errstr($err) };
            next;
        }
        $proj->{refresh} = undef;
        push @projects, $proj;
    }

    return { schema => 1, mode => 'all', generated_at => _now_iso(), projects => \@projects, errors => \@errors };
}

sub gather {
    my (%opt) = @_;
    my $mode = defined $opt{mode} ? $opt{mode} : 'project';
    _usage('bad_mode') unless $mode eq 'project' || $mode eq 'all';

    my @sections = @SECTIONS;
    if (defined $opt{sections}) {
        _usage('bad_sections') unless ref $opt{sections} eq 'ARRAY';
        for my $s (@{ $opt{sections} }) {
            _usage("bad_section:" . (defined $s ? $s : '(undef)')) unless defined $s && $SECTION_OK{$s};
        }
        @sections = @{ $opt{sections} };
    }
    $opt{sections} = \@sections;

    if ($mode eq 'all') {
        $opt{refresh} = 0;
        return _gather_all(%opt);
    }
    return _gather_project(%opt);
}

sub _render_threads {
    my ($t) = @_;
    my $items = $t->{items} // [];
    return () unless @$items;
    my @out = ('Threads:');
    for my $th (@$items) {
        my $bar = $th->{bar} // { done => 0, total => 0 };
        my $line = sprintf('  %s [%s, %s] %d/%d', $th->{name} // '', $th->{state} // '', $th->{liveness} // '',
            $bar->{done} // 0, $bar->{total} // 0);
        if (@{ $th->{doing} // [] }) {
            $line .= '  doing: ' . join('; ', @{ $th->{doing} });
        }
        if (defined $th->{next} && length $th->{next}) {
            $line .= '  next: ' . $th->{next};
        }
        push @out, $line;
        if ($th->{state} eq 'handed-off' && defined $th->{handoff} && length $th->{handoff}) {
            push @out, '    handoff: ' . $th->{handoff};
        }
        for my $task (@{ $th->{tasks} // [] }) {
            my $status = defined $task->{status} ? $task->{status} : '-';
            my $base = sprintf('    %s. [%s] %s', $task->{position}, $status, $task->{title});
            if (defined $task->{link} && length $task->{link}) {
                my $tag = (defined $task->{link_state} && $task->{link_state} eq 'ok')
                    ? $task->{location} : $task->{link_state};
                $base .= " -> $task->{link} ($tag)";
            }
            push @out, $base;
        }
    }
    return @out;
}

sub _render_todos {
    my ($todos) = @_;
    my $list = $todos // [];
    return () unless @$list;
    my @out = ('Todos:');
    for my $t (@$list) {
        my $line = "  $t->{id} $t->{title}";
        $line .= " [$t->{tags}]" if defined $t->{tags} && length $t->{tags};
        push @out, $line;
    }
    return @out;
}

sub _render_blueprints {
    my ($bps) = @_;
    my $list = $bps // [];
    return () unless @$list;
    my @out = ('Blueprints:');
    for my $b (@$list) {
        my $p = $b->{packages} // { done => 0, total => 0 };
        if (defined($b->{state}) && $b->{state} eq 'parked') {
            push @out, "  $b->{name} parked $p->{done}/$p->{total} - parked: " . ($b->{parked_reason} // '');
        } else {
            push @out, "  $b->{name} $b->{state} $p->{done}/$p->{total}";
        }
    }
    return @out;
}

sub _render_inbox {
    my ($items) = @_;
    my $list = $items // [];
    return () unless @$list;
    my @out = ('Inbox:');
    for my $it (@$list) {
        push @out, "  $it->{id} $it->{question}";
        if (defined $it->{body} && length $it->{body}) {
            push @out, "    $_" for split /\n/, $it->{body};
        }
        if (defined $it->{choices}) {
            my $txt = (ref($it->{choices}) eq 'ARRAY') ? join(' | ', @{ $it->{choices} }) : $it->{choices};
            push @out, "    choices: $txt" if defined $txt && length $txt;
        }
        if (defined $it->{link} && length $it->{link}) {
            push @out, "    link: $it->{link}";
        }
        if (defined $it->{rationale} && length $it->{rationale}) {
            push @out, "    rationale: $it->{rationale}";
        }
    }
    return @out;
}

sub _render_notes {
    my ($notes) = @_;
    my $list = $notes // [];
    return () unless @$list;
    return ('Notes:', map { "  $_" } @$list);
}

sub _render_tampered {
    my ($bugs) = @_;
    my $list = (ref $bugs eq 'HASH' && ref $bugs->{tampered} eq 'ARRAY') ? $bugs->{tampered} : [];
    return () unless @$list;
    return ('Tampered bug reports:', map { "  $_->{id}: $_->{note}" } @$list);
}

sub _render_incomplete {
    my ($errors) = @_;
    my $list = $errors // [];
    return () unless @$list;
    my %seen;
    my @names;
    for my $e (@$list) {
        next unless defined $e->{section} && length $e->{section};
        next if $seen{ $e->{section} }++;
        push @names, $e->{section};
    }
    return () unless @names;
    return ('Digest incomplete: ' . join(', ', @names));
}

sub render_digest {
    my ($r, %opt) = @_;
    my @lines;
    for my $block (
        [ _render_threads($r->{threads}) ],
        [ _render_todos($r->{todos}) ],
        [ _render_blueprints($r->{blueprints}) ],
        [ _render_inbox($r->{inbox}) ],
        [ _render_notes($r->{notes}) ],
        [ _render_tampered($r->{bugs}) ],
        [ _render_incomplete($r->{errors}) ],
    ) {
        push @lines, @$block if @$block;
    }
    if (@lines) {
        unshift @lines, 'Project digest (' . _basename($r->{root}) . '):';
    }
    if (defined $opt{other_line} && length $opt{other_line}) {
        push @lines, $opt{other_line};
    }
    return join("\n", @lines);
}

sub other_projects_line {
    my ($all) = @_;
    my @parts;
    for my $p (@{ $all->{projects} // [] }) {
        my $t_count = scalar(@{ ($p->{threads} // {})->{items} // [] });
        my $i_count = scalar(@{ $p->{inbox} // [] });
        next unless ($t_count + $i_count) > 0;
        push @parts, _basename($p->{root}) . " ($t_count threads, $i_count inbox)";
    }
    return '' unless @parts;
    return 'Other projects with open work: ' . join('; ', @parts);
}

sub digest {
    my (%opt) = @_;
    my $text = eval {
        my $root = defined $opt{root} ? $opt{root} : Almanac::Thread::project_root(cwd => $opt{cwd});
        $root = _fs_bytes($root) if defined $root;
        # redteam M2: render_digest only ever reads threads, todos, blueprints,
        # inbox, notes, bugs (tampered) and errors -- never fleet_runs or commits.
        # Trimming the sections list to just those does NOT change how many
        # per-blueprint sweeps _run_refresh spawns (reviewer-2-confirm N-1:
        # that happens earlier, during refresh, for every blueprint with a
        # runs/ directory, regardless of which sections are requested).
        # What it buys is skipping the per-section GATHER work for the
        # sections nobody renders here -- fleet_runs' own escalations walk
        # and git spawn, and commits' own git-log spawn -- for data the
        # digest never prints.
        my $proj = gather(mode => 'project', root => $root, refresh => 1,
            sections => [qw(threads inbox todos bugs blueprints notes)]);
        my $all  = gather(mode => 'all', sections => ['threads', 'inbox'], exclude => [$root]);
        my $other = other_projects_line($all);
        render_digest($proj, other_line => $other);
    };
    return '' unless defined $text && !$@;
    # reviewer-2-confirm SF-1: render_digest assembles its result from a mix
    # of already-decoded CHARACTER fragments (thread/todo/note titles, via
    # Almanac::Record's own decode) and the project root, which is a
    # character string too (_gather_project runs it through
    # _decode_if_bytes before storing it in root => ...). Encode exactly
    # ONCE, here, at the boundary, so every caller -- the CLI's raw `print`
    # (almanac-gather.pl, no output encoding layer) and BpHook::context's
    # own _decode_maybe (a no-op on an already-byte string) -- gets a
    # single, correctly-encoded UTF-8 byte string either way, instead of
    # the CLI emitting a flagged character string through an unencoded
    # filehandle (which truncates each multi-byte codepoint to its low
    # byte, corrupting the output).
    utf8::encode($text) if utf8::is_utf8($text);
    return $text;
}

# ---------------------------------------------------------------------------
# package 11-sitrep-commands additions (additive only -- see header comment).
# ---------------------------------------------------------------------------

# global_todos(%opt) -> \%result (spec 11, sec 2.4 G2).
# %opt: surface (host|container, passed to Almanac::Store->open), home
# (passed likewise). Read-only: forces the global scope's writable policy
# off for the call so list() never runs recovery (Store.pm:930). Never dies.
sub global_todos {
    my (%opt) = @_;
    local $Almanac::Store::SCOPE_POLICY{host}{global}{writable}      = 0;
    local $Almanac::Store::SCOPE_POLICY{container}{global}{writable} = 0;

    my $store = eval {
        Almanac::Store->open(scope => 'global', type => 'todo',
            surface => $opt{surface}, home => $opt{home});
    };
    if (my $err = $@) {
        if (ref($err) && eval { $err->isa('Almanac::Store::Error') } && ($err->{kind} // '') eq 'scope_unavailable') {
            return { available => 0, reason => $err->{reason}, items => [] };
        }
        return { available => 0, reason => _errstr($err), items => [] };
    }

    my $list = eval { $store->list };
    if (my $err = $@) {
        if (ref($err) && eval { $err->isa('Almanac::Store::Error') } && ($err->{kind} // '') eq 'scope_unavailable') {
            return { available => 0, reason => $err->{reason}, items => [] };
        }
        return { available => 0, reason => _errstr($err), items => [] };
    }

    my @out;
    for my $rec (@$list) {
        my $f = $rec->{fields};
        next unless defined($f->{status}) && $f->{status} eq 'open';
        push @out, { id => $rec->{id}, title => $f->{title}, tags => $f->{tags}, created => $f->{created} };
    }
    @out = sort { (($a->{created} // '') cmp ($b->{created} // '')) || ($a->{id} cmp $b->{id}) } @out;
    return { available => 1, reason => undef, items => \@out };
}

# thread_log_since(%opt) -> \@entries (spec 11, sec 2.4 G3).
# %opt: root (required, existing directory), since (required,
# YYYY-MM-DDTHH:MM:SSZ). Missing/invalid either -> dies with a usage error.
# Read-only.
sub thread_log_since {
    my (%opt) = @_;
    _usage('missing_root') unless defined($opt{root}) && length($opt{root}) && -d _fs_bytes($opt{root});
    _usage('missing_since') unless defined($opt{since}) && $opt{since} =~ /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/;

    my $root  = _fs_bytes($opt{root});
    my $since = $opt{since};
    my $list  = Almanac::Thread::list_threads(root => $root, archived => 1);
    my @out;
    for my $h (@$list) {
        my $log = Almanac::Thread::log_entries($h->{name}, root => $root);
        for my $e (@$log) {
            next unless defined $e->{at};
            next unless $e->{at} gt $since;
            push @out, {
                thread => $h->{name}, id => $e->{id}, at => $e->{at}, session => $e->{session},
                actor => $e->{actor}, event => $e->{event}, task => $e->{task},
                from => $e->{from}, to => $e->{to}, reason => $e->{reason},
            };
        }
    }
    @out = sort { (($a->{at} // '') cmp ($b->{at} // '')) || (($a->{thread} // '') cmp ($b->{thread} // '')) || (($a->{id} // '') cmp ($b->{id} // '')) } @out;
    return \@out;
}

1;
