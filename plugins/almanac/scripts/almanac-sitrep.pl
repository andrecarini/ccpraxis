#!/usr/bin/env perl
# almanac-sitrep.pl -- /sitrep (one project in full, diff since the last
# sitrep, usage) and /pending (every registered project's pending work).
# Blueprint where-things-go, package 11-sitrep-commands. See
# specs/11-sitrep-commands-spec.md section 2 for the exact contract.
package AlmanacSitrep;
use strict;
use warnings;
use Cwd ();
use JSON::PP ();
use POSIX ();
use Time::Local ();
use File::Path ();
use Fcntl ();

BEGIN {
    my $self = __FILE__;
    $self =~ s{\\}{/}g;
    $self = Cwd::abs_path($self) // $self;
    $self =~ s{\\}{/}g;
    my $dir = $self;
    $dir =~ s{/[^/]+\z}{};
    $dir = '.' unless length $dir;
    unshift @INC, $dir unless grep { $_ eq $dir } @INC;
}

use Almanac::Gather ();
use Almanac::Thread ();
use Almanac::SessionLive ();

# ---------------------------------------------------------------------------
# small shared helpers
# ---------------------------------------------------------------------------
sub _fs_bytes {
    my ($s) = @_;
    return $s unless defined $s;
    utf8::encode($s) if utf8::is_utf8($s);
    return $s;
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

sub _errstr {
    my ($err) = @_;
    return 'unknown error' unless defined $err;
    my $s = Almanac::Gather::_decode_if_bytes("$err");
    $s =~ s/\s+\z//;
    $s =~ s/[\r\n]+/ /g;
    return length($s) ? $s : 'unknown error';
}

# _clean($s) -- F3: neutralise control/escape characters in free-text
# fields read from another project's stores (inbox question, parked
# reason, thread/task titles, todo titles, bug titles) before they are
# interpolated into the report. Replaces C0 controls, DEL and the 0x9b
# "single shift 3" byte (used as an alternate CSI introducer in some
# terminals) with a visible placeholder, so a hostile/hand-edited store
# cannot inject ANSI/OSC escapes or fake newline-delimited report rows.
sub _clean {
    my ($s) = @_;
    return $s unless defined $s;
    $s =~ s/[\x00-\x1f\x7f\x{9b}]/ /g;
    return $s;
}

sub _iso_of {
    my ($epoch) = @_;
    my @t = gmtime($epoch);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ',
        $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

sub _epoch_of_iso {
    my ($iso) = @_;
    return undef unless defined $iso
        && $iso =~ /\A(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z\z/;
    return Time::Local::timegm($6, $5, $4, $3, $2 - 1, $1);
}

sub snapshot_path {
    my ($root) = @_;
    return "$root/.ccpraxis-local-data/sitrep/last.json";
}

sub _read_snapshot {
    my ($root) = @_;
    my $path = _fs_bytes(snapshot_path($root));
    return (undef, 'absent') unless -f $path;
    open(my $fh, '<:raw', $path) or return (undef, 'unreadable');
    local $/;
    my $raw = <$fh>;
    close $fh;
    my $doc = eval { JSON::PP->new->utf8->decode($raw) };
    return (undef, 'unreadable') if $@ || ref($doc) ne 'HASH';
    return (undef, 'unreadable') unless defined $doc->{schema} && $doc->{schema} == 1;
    return (undef, 'unreadable')
        unless defined $doc->{generated_at} && $doc->{generated_at} =~ /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/;
    # F2: the regex above only checks shape, not calendar validity (month
    # 13, hour 99 match it); confirm it actually parses before trusting it.
    return (undef, 'unreadable') unless defined eval { _epoch_of_iso($doc->{generated_at}) };
    # F2: every later consumer dereferences packages/inbox/usage as HASHes
    # without checking -- a wrongly-typed but syntactically valid snapshot
    # must be treated as unreadable (and so overwritten) rather than
    # crashing every subsequent /sitrep run.
    return (undef, 'unreadable')
        if exists($doc->{packages}) && defined($doc->{packages}) && ref($doc->{packages}) ne 'HASH';
    if (ref($doc->{packages}) eq 'HASH') {
        for my $v (values %{ $doc->{packages} }) {
            return (undef, 'unreadable') if ref($v) ne 'HASH';
        }
    }
    return (undef, 'unreadable')
        if exists($doc->{inbox}) && defined($doc->{inbox}) && ref($doc->{inbox}) ne 'HASH';
    return (undef, 'unreadable')
        if exists($doc->{usage}) && defined($doc->{usage}) && ref($doc->{usage}) ne 'HASH';
    return ($doc, 'ok');
}

sub _write_snapshot {
    my ($root, $doc) = @_;
    my $dir = _fs_bytes("$root/.ccpraxis-local-data/sitrep");
    # F1: a hostile/hand-edited project tree can make the data dir (or the
    # sitrep dir itself) a symlink to steer our writes anywhere on disk.
    # Refuse rather than follow it.
    my $data_dir = _fs_bytes("$root/.ccpraxis-local-data");
    die "refusing to write: $data_dir is a symlink\n" if -l $data_dir;
    die "refusing to write: $dir is a symlink\n" if -l $dir;
    File::Path::make_path($dir, { error => \my $mkerr });
    if (@{ $mkerr // [] } || !-d $dir) {
        my @msgs = map { my %h = %$_; join(': ', values %h) } @{ $mkerr // [] };
        die "cannot create $dir: " . (@msgs ? _errstr(join('; ', @msgs)) : "$!") . "\n";
    }
    die "refusing to write: $dir is a symlink\n" if -l $dir;
    my $path = "$dir/last.json";
    my $tmp = "$path.tmp.$$";
    # F1: O_EXCL refuses to open through an existing symlink or regular
    # file planted at this predictable name (PIDs are a small, predictable
    # range), instead of truncating whatever it points at.
    my $fh;
    sysopen($fh, $tmp, Fcntl::O_WRONLY() | Fcntl::O_CREAT() | Fcntl::O_EXCL())
        or die "cannot write $tmp: $!\n";
    binmode($fh);
    my $ok = eval {
        print {$fh} JSON::PP->new->utf8->canonical->encode($doc);
        close($fh) or die "cannot write $tmp: $!\n";
        rename($tmp, $path) or die "cannot rename $tmp to $path: $!\n";
        1;
    };
    unless ($ok) {
        my $err = $@;
        unlink $tmp;
        die $err;
    }
    return 1;
}

sub _errors_has {
    my ($errors, $section) = @_;
    for my $e (@{ $errors // [] }) {
        return 1 if defined $e->{section} && $e->{section} eq $section;
    }
    return 0;
}

my $BUTLER_LOADED;
sub _load_butler {
    return $BUTLER_LOADED if defined $BUTLER_LOADED;
    my $path = "$Almanac::Gather::BUTLER_DIR/bp-spend.pl";
    $BUTLER_LOADED = eval { require $path; 1 } ? 1 : 0;
    return $BUTLER_LOADED;
}

sub _gate_reading {
    my ($gate_script, $butler_loaded) = @_;
    unless ($butler_loaded && defined $gate_script && -f $gate_script) {
        return { status => 'unknown', diagnostic => 'gate unavailable' };
    }
    my @cmd = ($^X, $gate_script);
    my $pid = open(my $fh, '-|');
    die "cannot fork: $!\n" unless defined $pid;
    if ($pid == 0) {
        open(STDIN, '<', '/dev/null') or close(STDIN);
        open(STDERR, '>&STDOUT') or close(STDERR);
        exec(@cmd) or POSIX::_exit(127);
    }
    local $/;
    my $out = <$fh>;
    close $fh;
    my $rc = ($? == -1) ? -1 : ($? >> 8);
    return BpSpend::claude_from_gate($out, $rc);
}

sub _fmt_wall {
    my ($secs) = @_;
    $secs = 0 unless defined $secs;
    $secs = int($secs);
    $secs = 0 if $secs < 0;
    if ($secs < 3600) {
        return sprintf('%dm%02ds', int($secs / 60), $secs % 60);
    }
    return sprintf('%dh%02dm', int($secs / 3600), int(($secs % 3600) / 60));
}

sub _usage_lines {
    my ($prev_usage, $reading) = @_;
    my @lines;
    if (defined($reading->{status}) && $reading->{status} eq 'ok') {
        for my $w ([qw(five_hour 5-hour)], [qw(seven_day 7-day)]) {
            my ($key, $label) = @$w;
            my $now_v = 0 + sprintf('%.1f', $reading->{$key}{utilization});
            if (defined $prev_usage && defined $prev_usage->{$key}) {
                my $prev_v = 0 + sprintf('%.1f', $prev_usage->{$key});
                my $delta  = 0 + sprintf('%.1f', $now_v - $prev_v);
                my $dstr   = ($delta >= 0 ? '+' : '') . $delta;
                push @lines, "  $label  $prev_v% -> $now_v%  ($dstr pts)";
            } else {
                push @lines, "  $label  $now_v%  (no baseline)";
            }
        }
    } else {
        push @lines, "  utilisation unavailable: " . (defined $reading->{diagnostic} ? $reading->{diagnostic} : 'unknown');
    }
    return @lines;
}

sub _build_usage_for_snapshot {
    my ($reading, $prev_usage, $generated_at) = @_;
    if (defined($reading->{status}) && $reading->{status} eq 'ok') {
        return {
            at        => $generated_at,
            five_hour => 0 + sprintf('%.1f', $reading->{five_hour}{utilization}),
            seven_day => 0 + sprintf('%.1f', $reading->{seven_day}{utilization}),
        };
    }
    return $prev_usage;
}

sub _spend_lines {
    my (%a) = @_;
    unless ($a{butler_loaded}) {
        return ();    # caller replaces the whole Usage section body instead
    }
    my $transcript = $a{transcript};
    if (!defined($transcript) || !length($transcript)) {
        if (defined $a{session_id}) {
            my ($t, $ok) = Almanac::SessionLive::find_transcript($a{session_id});
            $transcript = $t if defined $t;
        }
    }
    return ('  spend unavailable: no session transcript') unless defined $transcript && length $transcript;

    my %opts = (
        session   => $transcript,
        data_root => "$a{root}/.ccpraxis-local-data",
        by        => [qw(role blueprint package)],
        pricing   => BpPricing::offline(),
    );
    if (defined $a{since}) {
        $opts{window} = { since => _epoch_of_iso($a{since}), until => undef };
    }
    my $doc = eval { BpSpend::Derive::report_session(%opts) };
    if (my $err = $@) {
        my ($first) = split /\n/, Almanac::Gather::_decode_if_bytes("$err");
        return ("  spend unavailable: $first");
    }

    my $main_tokens = 0;
    my $sub_tokens  = 0;
    my %by_role;
    my %by_pkg;
    for my $row (@{ $doc->{rows} // [] }) {
        if (defined($row->{role}) && $row->{role} eq 'driver') {
            $main_tokens += $row->{tokens};
            next;
        }
        $sub_tokens += $row->{tokens};
        my $role = defined($row->{role}) ? $row->{role} : 'unknown';
        $by_role{$role} += $row->{tokens};
        # F5: bp-spend.pl is loaded at runtime via require, so the compiler
        # only ever sees this name once and warns "used only once" on every
        # run; it is not a typo. no warnings silences just this reference.
        my $key = do {
            no warnings 'once';
            (defined($row->{blueprint}) && $row->{blueprint} ne $BpSpend::Derive::UNATTRIBUTED_LABEL
                       && defined($row->{package}))
                ? "$row->{blueprint}/$row->{package}" : 'unattributed';
        };
        $by_pkg{$key}{tokens} = ($by_pkg{$key}{tokens} // 0) + $row->{tokens};
    }

    my $recs = eval { BpSpend::Derive::load_dispatch_records("$a{root}/.ccpraxis-local-data") } // [];
    my $since_epoch = defined($a{since}) ? _epoch_of_iso($a{since}) : undef;
    for my $r (@$recs) {
        next if defined($since_epoch) && $r->{started_at} < $since_epoch;
        next if $r->{started_at} > $a{now};
        my $key = (defined($r->{blueprint}) && defined($r->{package}))
            ? "$r->{blueprint}/$r->{package}" : 'unattributed';
        $by_pkg{$key}{tokens} //= 0;
        $by_pkg{$key}{dispatches} = ($by_pkg{$key}{dispatches} // 0) + 1;
        $by_pkg{$key}{running} = ($by_pkg{$key}{running} // 0) + 1 unless defined $r->{ended_at};
        $by_pkg{$key}{wall} = ($by_pkg{$key}{wall} // 0) + ($r->{ended_at} - $r->{started_at}) if defined $r->{ended_at};
    }

    my @lines;
    push @lines, "  Main session  $main_tokens";
    push @lines, "  Subagents  $sub_tokens";
    push @lines, '  By worker type:';
    for my $role (sort { ($by_role{$b} <=> $by_role{$a}) || ($a cmp $b) } keys %by_role) {
        push @lines, "    $role  $by_role{$role}";
    }
    push @lines, '  By package:';
    my @keys = sort {
        (($by_pkg{$b}{tokens} // 0) <=> ($by_pkg{$a}{tokens} // 0)) || ($a cmp $b)
    } grep { $_ ne 'unattributed' } keys %by_pkg;
    push @keys, 'unattributed' if exists $by_pkg{unattributed};
    for my $key (@keys) {
        my $e = $by_pkg{$key};
        my $tokens     = $e->{tokens} // 0;
        my $dispatches = $e->{dispatches} // 0;
        my $running    = $e->{running} // 0;
        my $wall       = $e->{wall} // 0;
        my $line = "    $key  $tokens  dispatches $dispatches  wall " . _fmt_wall($wall);
        $line .= "  running $running" if $running > 0;
        push @lines, $line;
    }
    return @lines;
}

# ---------------------------------------------------------------------------
# project mode rendering (3.1)
# ---------------------------------------------------------------------------
sub _packages_diff_rows {
    my ($prev, $r) = @_;
    my %cur;
    for my $b (@{ $r->{blueprints} // [] }) {
        my $statuses = $b->{packages}{status} // {};
        $cur{ $b->{name} }{$_} = $statuses->{$_} for keys %$statuses;
    }
    my %prevp = %{ $prev->{packages} // {} };
    my %keys;
    for my $bp (keys %cur) { $keys{"$bp\x1f$_"} = [$bp, $_] for keys %{ $cur{$bp} } }
    for my $bp (keys %prevp) { $keys{"$bp\x1f$_"} ||= [$bp, $_] for keys %{ $prevp{$bp} } }

    my @rows;
    for my $k (sort keys %keys) {
        my ($bp, $pkg) = @{ $keys{$k} };
        my $from = (exists $prevp{$bp} && exists $prevp{$bp}{$pkg}) ? $prevp{$bp}{$pkg} : '(new)';
        my $to   = (exists $cur{$bp}   && exists $cur{$bp}{$pkg})   ? $cur{$bp}{$pkg}   : '(gone)';
        next if $from eq $to;
        if ($to eq 'done') { push @rows, "    finished  $bp/$pkg  ($from -> done)" }
        else                { push @rows, "    moved  $bp/$pkg  $from -> $to" }
    }
    return @rows;
}

sub _render_blueprints_section {
    my ($bps) = @_;
    my @lines = ('== Blueprints ==');
    my $list = $bps // [];
    unless (@$list) { push @lines, '  (none)'; return @lines }
    for my $b (@$list) {
        my $p = $b->{packages} // { done => 0, total => 0, status => {} };
        my $line = "  $b->{name}  $b->{state}  $p->{done}/$p->{total}";
        $line .= '  parked: ' . _clean(defined($b->{parked_reason}) ? $b->{parked_reason} : '')
            if defined($b->{state}) && $b->{state} eq 'parked';
        push @lines, $line;
        my %by_status;
        my $statuses = $p->{status} // {};
        for my $pkg (sort keys %$statuses) { push @{ $by_status{ $statuses->{$pkg} } }, $pkg }
        my @order = (exists $by_status{done}) ? ('done', sort grep { $_ ne 'done' } keys %by_status)
                                                : (sort keys %by_status);
        for my $st (@order) {
            push @lines, "    $st: " . join(', ', sort @{ $by_status{$st} });
        }
    }
    return @lines;
}

sub _render_threads_section {
    my ($threads) = @_;
    my @lines = ('== Threads ==');
    my $items = ($threads // {})->{items} // [];
    unless (@$items) { push @lines, '  (none)'; return @lines }
    for my $th (@$items) {
        my $bar = $th->{bar} // { done => 0, total => 0 };
        my $line = "  $th->{name}  [$th->{state}, " . (defined($th->{liveness}) ? $th->{liveness} : '') . "]  $bar->{done}/$bar->{total}";
        if (@{ $th->{doing} // [] }) { $line .= '  doing: ' . join('; ', @{ $th->{doing} }) }
        if (defined($th->{next}) && length($th->{next})) { $line .= "  next: $th->{next}" }
        push @lines, $line;
        if (defined($th->{state}) && $th->{state} eq 'handed-off' && defined($th->{handoff}) && length($th->{handoff})) {
            push @lines, "    handoff: $th->{handoff}";
        }
        for my $task (@{ $th->{tasks} // [] }) {
            my $status = defined($task->{status}) ? $task->{status} : '-';
            my $base = "    " . ($task->{position} // '-') . ". [$status] " . _clean($task->{title} // '');
            if (defined($task->{link}) && length($task->{link})) {
                my $tag = (defined($task->{link_state}) && $task->{link_state} eq 'ok')
                    ? $task->{location} : $task->{link_state};
                $base .= " -> $task->{link} ($tag)";
            }
            push @lines, $base;
        }
    }
    my $archived = ($threads // {})->{archived_count} // 0;
    push @lines, "  ($archived archived)" if $archived > 0;
    return @lines;
}

sub _render_todos_section {
    my ($todos) = @_;
    my @lines = ('== Todos ==');
    my $list = $todos // [];
    unless (@$list) { push @lines, '  (none)'; return @lines }
    for my $t (@$list) {
        my $line = "  $t->{id}  " . _clean($t->{title} // '');
        $line .= "  [$t->{tags}]" if defined($t->{tags}) && length($t->{tags});
        push @lines, $line;
    }
    return @lines;
}

sub _render_inbox_section {
    my ($items) = @_;
    my @lines = ('== Inbox ==');
    my $list = $items // [];
    unless (@$list) { push @lines, '  (none)'; return @lines }
    for my $it (@$list) {
        push @lines, "  $it->{id}  " . _clean($it->{question} // '');
        if (defined($it->{body}) && length($it->{body})) {
            push @lines, "    $_" for split /\n/, $it->{body};
        }
        if (defined($it->{link}) && length($it->{link})) {
            my @segs = split m{/}, $it->{link}, -1;
            push @lines, "    fleet: $it->{link}" if @segs == 3;
        }
        if (defined($it->{rationale}) && length($it->{rationale})) {
            push @lines, "    rationale: $it->{rationale}";
        }
        if (defined $it->{choices}) {
            my $txt = (ref($it->{choices}) eq 'ARRAY') ? join(' | ', @{ $it->{choices} }) : $it->{choices};
            push @lines, "    actions: $txt" if defined($txt) && length($txt);
        }
        push @lines, "    answer: almanac inbox answer $it->{id}";
    }
    return @lines;
}

sub _render_fleets_section {
    my ($runs) = @_;
    my @lines = ('== Fleets ==');
    my $list = $runs // [];
    unless (@$list) { push @lines, '  (none)'; return @lines }
    for my $f (@$list) {
        my @esc = @{ $f->{escalations} // [] };
        my $n_resolver = scalar(grep { ($_->{where} // '') eq 'resolver' } @esc);
        my $n_inbox    = scalar(grep { ($_->{where} // '') eq 'inbox' } @esc);
        push @lines, "  $f->{blueprint}  $f->{state}  escalations: $n_resolver with resolver, $n_inbox in inbox";
        if (defined($f->{state}) && $f->{state} eq 'orphaned') {
            push @lines, "    orchestrator is dead -- resume: run /butler:dispatch-fleet $f->{blueprint} in this project's sandbox (it continues the run, never duplicates)";
        } elsif (defined($f->{state}) && $f->{state} eq 'paused') {
            push @lines, '    paused -- runs/.paused is set';
        }
        for my $e (@esc) {
            if (($e->{where} // '') eq 'inbox') {
                push @lines, "    inbox  $e->{id}  -> " . (defined($e->{inbox_id}) ? $e->{inbox_id} : '-');
            } else {
                my @f = map { defined($_) ? $_ : '-' } ($e->{id}, $e->{package}, $e->{category}, $e->{question});
                push @lines, '    resolver  ' . join('  ', @f);
            }
        }
    }
    return @lines;
}

my @BUG_ALL_STATES = qw(open triaging scheduled fixed dropped);
my @BUG_OPEN_STATES = qw(open triaging scheduled);

sub _render_bugs_section {
    my ($bugs, $prev) = @_;
    my @lines = ('== Bugs ==');
    my $bs = (ref($bugs) eq 'HASH' && ref($bugs->{by_state}) eq 'HASH') ? $bugs->{by_state} : {};
    push @lines, '  Open:';
    my @open_rows;
    for my $st (@BUG_OPEN_STATES) {
        for my $bug (@{ $bs->{$st} // [] }) {
            my $sev = (defined($bug->{severity}) && length($bug->{severity})) ? $bug->{severity} : '-';
            push @open_rows, "    $bug->{id}  $st  $sev  " . _clean($bug->{title} // '');
        }
    }
    push @lines, (@open_rows ? @open_rows : ('  (none)'));

    if (defined $prev) {
        push @lines, "  Opened since $prev->{generated_at}:";
        my @opened;
        for my $st (@BUG_ALL_STATES) {
            for my $bug (@{ $bs->{$st} // [] }) {
                next unless defined($bug->{filed}) && $bug->{filed} ge $prev->{generated_at};
                push @opened, "    $bug->{id}  $st  " . _clean($bug->{title} // '');
            }
        }
        push @lines, (@opened ? @opened : ('  (none)'));

        push @lines, "  Closed since $prev->{generated_at}:";
        my @closed;
        for my $st (qw(fixed dropped)) {
            for my $bug (@{ $bs->{$st} // [] }) {
                next unless defined($bug->{closed}) && $bug->{closed} ge $prev->{generated_at};
                push @closed, "    $bug->{id}  $st  " . _clean($bug->{title} // '');
            }
        }
        push @lines, (@closed ? @closed : ('  (none)'));
    } else {
        my $nfixed   = scalar(@{ $bs->{fixed}   // [] });
        my $ndropped = scalar(@{ $bs->{dropped} // [] });
        push @lines, "  Closed (all time): $nfixed fixed, $ndropped dropped";
    }

    my $tampered = (ref($bugs) eq 'HASH' && ref($bugs->{tampered}) eq 'ARRAY') ? $bugs->{tampered} : [];
    for my $t (@$tampered) { push @lines, "  Tampered: $t->{id} ($t->{note})" }

    return @lines;
}

# project_report(%opt) -- /sitrep, spec section 2.1. Options: root (skip
# resolution), cwd (passed through to Almanac::Thread::project_root() when
# root is not given -- the default root per spec 2.1 is
# project_root(cwd => cwd), so this is how a caller that is not actually
# running from the project directory still resolves correctly), now
# (epoch, for deterministic tests), refresh (default on), write_snapshot
# (default on), gate_script (path override), session_id, transcript.
sub project_report {
    my (%opt) = @_;
    my $root = (defined($opt{root}) && length($opt{root}))
        ? $opt{root}
        : Almanac::Thread::project_root(cwd => $opt{cwd});
    die "could not resolve project root\n" unless defined($root) && length($root);

    my $now         = defined($opt{now}) ? ($opt{now} + 0) : time();
    my $do_refresh  = exists($opt{refresh}) ? ($opt{refresh} ? 1 : 0) : 1;
    my $write_snap  = exists($opt{write_snapshot}) ? ($opt{write_snapshot} ? 1 : 0) : 1;
    my $gate_script = defined($opt{gate_script}) ? $opt{gate_script}
        : "$Almanac::Gather::BUTLER_DIR/bp-usage-gate.pl";

    my $session_id = $opt{session_id};
    $session_id = undef unless defined($session_id) && $session_id =~ /\A[A-Za-z0-9_-]{1,128}\z/;

    my ($prev, $snap_state) = _read_snapshot($root);
    my $since = defined($prev) ? $prev->{generated_at} : undef;

    my %gather_opt = (mode => 'project', root => $root, refresh => $do_refresh,
        sections => [qw(threads inbox todos bugs blueprints fleet_runs commits)]);
    $gather_opt{since} = $since if defined $since;
    my $r = Almanac::Gather::gather(%gather_opt);

    my @log_rows;
    my $log_err;
    if (defined $since) {
        my $log = eval { Almanac::Gather::thread_log_since(root => $root, since => $since) };
        if (my $err = $@) {
            $log_err = _errstr($err);
        } else {
            for my $e (@$log) {
                my $row = "    $e->{at}  $e->{thread}  " . (defined($e->{event}) ? $e->{event} : '');
                $row .= "  task $e->{task}" if defined($e->{task}) && length($e->{task});
                if (defined($e->{from}) || defined($e->{to})) {
                    $row .= '  ' . (defined($e->{from}) ? $e->{from} : '-') . ' -> ' . (defined($e->{to}) ? $e->{to} : '-');
                }
                $row .= "  -- $e->{reason}" if defined($e->{reason}) && length($e->{reason});
                push @log_rows, $row;
            }
        }
    }

    my $butler_loaded = _load_butler();
    my $reading = eval { _gate_reading($gate_script, $butler_loaded) }
        // { status => 'unknown', diagnostic => 'gate unavailable' };
    my @spend_lines = _spend_lines(
        root => $root, transcript => $opt{transcript}, session_id => $session_id,
        since => $since, now => $now, butler_loaded => $butler_loaded,
    );

    my $generated_at = _iso_of($now);
    my $base = _basename($r->{root});

    my @lines;
    push @lines, "Sitrep: $base  $generated_at";

    push @lines, '== Changes since last sitrep ==';
    if (!defined $prev) {
        if ($snap_state eq 'unreadable') {
            push @lines, '  Previous snapshot unreadable: this one is the new baseline.';
        } else {
            push @lines, '  No previous sitrep: this one is the baseline.';
        }
    } else {
        push @lines, "  since $prev->{generated_at}";
        push @lines, '  Packages:';
        # M1: a failed blueprints read means $r->{blueprints} is the empty
        # default, not "no packages" -- diffing against the previous
        # snapshot would fabricate "every package moved to (gone)". Say so
        # instead of diffing.
        if (_errors_has($r->{errors}, 'blueprints')) {
            push @lines, '    unavailable: blueprints could not be read';
        } else {
            my @pkg_rows = _packages_diff_rows($prev, $r);
            push @lines, (@pkg_rows ? @pkg_rows : ('  (none)'));
        }

        # M1: same reasoning for inbox -- a failed read must not render as
        # "every previous inbox id was just answered".
        if (_errors_has($r->{errors}, 'inbox')) {
            push @lines, '  Inbox added:';
            push @lines, '    unavailable: inbox could not be read';
            push @lines, '  Inbox answered:';
            push @lines, '    unavailable: inbox could not be read';
        } else {
            my %cur_inbox = map { $_->{id} => $_->{question} } @{ $r->{inbox} // [] };
            my %prev_inbox = %{ $prev->{inbox} // {} };
            push @lines, '  Inbox added:';
            my @added = map { "    $_  " . _clean($cur_inbox{$_} // '') } sort grep { !exists $prev_inbox{$_} } keys %cur_inbox;
            push @lines, (@added ? @added : ('  (none)'));
            push @lines, '  Inbox answered:';
            my @answered = map { "    $_  " . _clean($prev_inbox{$_} // '') } sort grep { !exists $cur_inbox{$_} } keys %prev_inbox;
            push @lines, (@answered ? @answered : ('  (none)'));
        }

        push @lines, '  Commits:';
        # M1: also guards the non-git-project case, where Gather dies "git
        # log failed" and the section used to print the misleading
        # "(none)" rather than naming the failure.
        if (_errors_has($r->{errors}, 'commits')) {
            push @lines, '    unavailable: commits could not be read';
        } else {
            my @commit_rows = map { '    ' . substr($_->{sha}, 0, 7) . "  $_->{subject}" } @{ $r->{commits} // [] };
            push @lines, (@commit_rows ? @commit_rows : ('  (none)'));
        }

        push @lines, '  Thread log:';
        if (defined $log_err) {
            push @lines, "    unavailable: $log_err";
        } else {
            push @lines, (@log_rows ? @log_rows : ('  (none)'));
        }
    }

    push @lines, _render_blueprints_section($r->{blueprints});
    push @lines, _render_threads_section($r->{threads});
    push @lines, _render_todos_section($r->{todos});
    push @lines, _render_inbox_section($r->{inbox});
    push @lines, _render_fleets_section($r->{fleet_runs});
    push @lines, _render_bugs_section($r->{bugs}, $prev);

    push @lines, '== Usage ==';
    unless ($butler_loaded) {
        push @lines, '  usage unavailable: butler scripts not found';
    } else {
        push @lines, (defined($prev) ? "  since $prev->{generated_at}" : '  since session start (first sitrep)');
        push @lines, _usage_lines(defined($prev) ? $prev->{usage} : undef, $reading);
        push @lines, @spend_lines;
    }

    {
        my @names;
        my %seen;
        for my $e (@{ $r->{errors} // [] }) {
            next unless defined($e->{section}) && length($e->{section});
            next if $seen{ $e->{section} }++;
            push @names, $e->{section};
        }
        push @lines, 'Incomplete: ' . join(', ', @names) if @names;
    }

    my $text = join("\n", @lines) . "\n";

    if ($write_snap) {
        my $usage_doc = _build_usage_for_snapshot($reading, defined($prev) ? $prev->{usage} : undef, $generated_at);
        my $packages_doc = _errors_has($r->{errors}, 'blueprints')
            ? (defined($prev) ? ($prev->{packages} // {}) : {})
            : { map { $_->{name} => $_->{packages}{status} } @{ $r->{blueprints} // [] } };
        my $inbox_doc = _errors_has($r->{errors}, 'inbox')
            ? (defined($prev) ? ($prev->{inbox} // {}) : {})
            : { map { $_->{id} => $_->{question} } @{ $r->{inbox} // [] } };
        my $doc = {
            schema       => 1,
            generated_at => $generated_at,
            root         => $r->{root},
            session_id   => (defined($session_id) ? $session_id : JSON::PP::null),
            packages     => $packages_doc,
            inbox        => $inbox_doc,
            usage        => (defined($usage_doc) ? $usage_doc : JSON::PP::null),
        };
        # F4: Gather's own redteam-H1 guard skipped the mutating refresh
        # because the resolved root did not match CLAUDE_PROJECT_DIR (a
        # misresolved cwd that stepped up into a parent project). Writing
        # our snapshot there anyway would be exactly the cross-project
        # local-state write that guard exists to prevent.
        if (_errors_has($r->{errors}, 'refresh')) {
            $text .= 'Snapshot not written: root does not match CLAUDE_PROJECT_DIR' . "\n";
        } else {
            my $ok = eval { _write_snapshot($root, $doc); 1 };
            unless ($ok) {
                $text .= 'Snapshot not written: ' . _errstr($@) . "\n";
            }
        }
    }

    utf8::encode($text) if utf8::is_utf8($text);
    return $text;
}

# ---------------------------------------------------------------------------
# pending mode rendering (3.2)
# ---------------------------------------------------------------------------
sub _project_view {
    my ($p) = @_;
    my @inbox = @{ $p->{inbox} // [] };

    my @bps;
    for my $b (@{ $p->{blueprints} // [] }) {
        next if defined($b->{state}) && ($b->{state} eq 'archived' || $b->{state} eq 'done');
        my $statuses = $b->{packages}{status} // {};
        my @nondone = sort grep { ($statuses->{$_} // '') ne 'done' && ($statuses->{$_} // '') ne 'dropped' } keys %$statuses;
        next unless @nondone;
        push @bps, { b => $b, nondone => \@nondone, statuses => $statuses };
    }

    my @threads;
    for my $th (@{ ($p->{threads} // {})->{items} // [] }) {
        my @open_tasks = grep {
            my $s = $_->{status};
            !(defined($s) && ($s eq 'done' || $s eq 'obsoleted' || $s eq 'dropped'));
        } @{ $th->{tasks} // [] };
        next unless @open_tasks;
        push @threads, { th => $th, open_tasks => \@open_tasks };
    }

    my @todos = @{ $p->{todos} // [] };

    my @bugs;
    my $bs = (ref($p->{bugs}) eq 'HASH' && ref($p->{bugs}{by_state}) eq 'HASH') ? $p->{bugs}{by_state} : {};
    for my $st (@BUG_OPEN_STATES) {
        for my $bug (@{ $bs->{$st} // [] }) {
            push @bugs, { state => $st, bug => $bug };
        }
    }

    # B2: a project whose inbox/blueprints/threads/todos/bugs section
    # failed to read (store corrupt, almanac-bug.pl/BpState unloadable,
    # blueprint dir unreadable) carries that failure on the PROJECT's own
    # errors[] (Gather's _gather_project), separate from _gather_all's
    # top-level registry-only errors[]. Carry it through so the caller can
    # tell "read failed" from "genuinely nothing pending" instead of
    # defaulting both to an empty section.
    return {
        root => $p->{root}, inbox => \@inbox, bps => \@bps, threads => \@threads,
        todos => \@todos, bugs => \@bugs, errors => $p->{errors} // [],
    };
}

sub pending_report {
    my (%opt) = @_;
    my $now = time();
    my $all = Almanac::Gather::gather(mode => 'all', sections => [qw(threads inbox todos bugs blueprints)]);
    my $g   = Almanac::Gather::global_todos(surface => $opt{surface}, home => $opt{home});

    my $projects = $all->{projects} // [];
    my %basename_count;
    $basename_count{ _basename($_->{root}) }++ for @$projects;
    my @views;
    for my $p (@$projects) {
        my $v = _project_view($p);
        my $base = _basename($p->{root});
        $v->{name} = ($basename_count{$base} > 1) ? "$base ($p->{root})" : $base;
        push @views, $v;
    }

    my $generated_at = _iso_of($now);
    my $n = scalar(@$projects);
    my @lines;
    push @lines, "Pending across $n registered projects  $generated_at";
    push @lines, '  No registered projects.' if $n == 0;

    # == Inbox ==
    push @lines, '== Inbox ==';
    my @inbox_block;
    for my $v (@views) {
        next unless @{ $v->{inbox} };
        push @inbox_block, "  $v->{name}:";
        push @inbox_block, map { "    $_->{id}  " . _clean($_->{question} // '') } @{ $v->{inbox} };
    }
    push @lines, (@inbox_block ? @inbox_block : ('  (none)'));

    # == Blueprints ==
    push @lines, '== Blueprints ==';
    my @bp_block;
    for my $v (@views) {
        next unless @{ $v->{bps} };
        push @bp_block, "  $v->{name}:";
        for my $entry (@{ $v->{bps} }) {
            my $b = $entry->{b};
            my $p = $b->{packages} // { done => 0, total => 0 };
            my $line = "    $b->{name}  $b->{state}  $p->{done}/$p->{total}";
            $line .= '  parked: ' . _clean(defined($b->{parked_reason}) ? $b->{parked_reason} : '')
                if defined($b->{state}) && $b->{state} eq 'parked';
            push @bp_block, $line;
            my %by_status;
            for my $pkg (@{ $entry->{nondone} }) { push @{ $by_status{ $entry->{statuses}{$pkg} } }, $pkg }
            for my $st (sort keys %by_status) {
                push @bp_block, "      $st: " . join(', ', sort @{ $by_status{$st} });
            }
        }
    }
    push @lines, (@bp_block ? @bp_block : ('  (none)'));

    # == Threads ==
    push @lines, '== Threads ==';
    my @th_block;
    for my $v (@views) {
        next unless @{ $v->{threads} };
        push @th_block, "  $v->{name}:";
        for my $entry (@{ $v->{threads} }) {
            my $th  = $entry->{th};
            my $bar = $th->{bar} // { done => 0, total => 0 };
            push @th_block, "    $th->{name}  [$th->{state}]  $bar->{done}/$bar->{total}";
            for my $task (@{ $entry->{open_tasks} }) {
                my $status = defined($task->{status}) ? $task->{status} : '-';
                push @th_block, "      " . ($task->{position} // '-') . ". [$status] " . _clean($task->{title} // '');
            }
        }
    }
    push @lines, (@th_block ? @th_block : ('  (none)'));

    # == Todos ==
    push @lines, '== Todos ==';
    for my $v (@views) {
        next unless @{ $v->{todos} };
        push @lines, "  $v->{name}:";
        for my $t (@{ $v->{todos} }) {
            my $line = "    $t->{id}  " . _clean($t->{title} // '');
            $line .= "  [$t->{tags}]" if defined($t->{tags}) && length($t->{tags});
            push @lines, $line;
        }
    }
    if (!$g->{available}) {
        push @lines, '  global: unavailable here (' . (defined($g->{reason}) ? _errstr($g->{reason}) : 'unknown') . ')';
    } elsif (!@{ $g->{items} // [] }) {
        push @lines, '  global: (none)';
    } else {
        push @lines, '  global:';
        push @lines, map { "    $_->{id}  " . _clean($_->{title} // '') } @{ $g->{items} };
    }

    # == Open bugs ==
    push @lines, '== Open bugs ==';
    my @bug_rows;
    for my $v (@views) {
        for my $entry (@{ $v->{bugs} }) {
            my $bug = $entry->{bug};
            my $sev = (defined($bug->{severity}) && length($bug->{severity})) ? $bug->{severity} : '-';
            push @bug_rows, "  $v->{name}  $bug->{id}  $sev  " . _clean($bug->{title} // '');
        }
    }
    push @lines, (@bug_rows ? @bug_rows : ('  (none)'));

    # == Clear ==
    # B2: a project whose inbox/blueprints/threads/todos/bugs section
    # failed to read looks identical, here, to one that genuinely has
    # nothing pending -- both leave every $v->{...} array empty. Q8 is a
    # positive claim ("nothing pending"); making that claim from a read
    # that failed is wrong, so such a project is reported as unknown
    # rather than clear.
    push @lines, '== Clear ==';
    my @clear;
    my @per_project_errors;
    for my $v (@views) {
        next if @{ $v->{inbox} } || @{ $v->{bps} } || @{ $v->{threads} } || @{ $v->{todos} } || @{ $v->{bugs} };
        my @bad_sections = sort grep {
            my $s = $_;
            grep { $_ eq $s } qw(inbox blueprints threads todos bugs)
        } map { $_->{section} } @{ $v->{errors} // [] };
        if (@bad_sections) {
            push @clear, "  $v->{name}  unknown -- could not read: " . join(', ', @bad_sections);
            for my $e (@{ $v->{errors} // [] }) {
                next unless grep { $_ eq $e->{section} } @bad_sections;
                push @per_project_errors, "$v->{name}: $e->{section} (" . _errstr($e->{error}) . ')';
            }
        } else {
            push @clear, "  $v->{name}  clear -- nothing pending";
        }
    }
    push @lines, (@clear ? @clear : ('  (none)'));

    {
        my @msgs = map { $_->{error} } grep { defined($_->{error}) && length($_->{error}) } @{ $all->{errors} // [] };
        push @msgs, @per_project_errors;
        push @lines, 'Incomplete: ' . join('; ', @msgs) if @msgs;
    }

    my $text = join("\n", @lines) . "\n";
    utf8::encode($text) if utf8::is_utf8($text);
    return $text;
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
sub _usage_text {
    return "usage: almanac-sitrep.pl project [--root DIR] [--session-id SID] [--transcript PATH] "
         . "[--no-refresh] [--no-snapshot] [--gate-script PATH] [--now EPOCH]\n"
         . "       almanac-sitrep.pl pending\n";
}

sub run {
    my (@argv) = @_;
    my $mode = shift @argv;
    unless (defined($mode) && ($mode eq 'project' || $mode eq 'pending')) {
        print STDERR _usage_text();
        return 2;
    }

    if ($mode eq 'pending') {
        if (@argv) { print STDERR _usage_text(); return 2 }
        my $bytes = eval { pending_report() };
        if (my $err = $@) {
            print STDERR 'almanac-sitrep: ' . _errstr($err) . "\n";
            return 1;
        }
        binmode(STDOUT);
        print STDOUT $bytes;
        return 0;
    }

    my %opt;
    while (@argv) {
        my $a = shift @argv;
        if    ($a eq '--root')        { my $v = shift @argv; return _bad() unless defined $v; $opt{root} = $v }
        elsif ($a eq '--session-id')  { my $v = shift @argv; return _bad() unless defined $v; $opt{session_id} = $v }
        elsif ($a eq '--transcript')  { my $v = shift @argv; return _bad() unless defined $v; $opt{transcript} = $v }
        elsif ($a eq '--no-refresh')  { $opt{refresh} = 0 }
        elsif ($a eq '--no-snapshot') { $opt{write_snapshot} = 0 }
        elsif ($a eq '--gate-script') { my $v = shift @argv; return _bad() unless defined $v; $opt{gate_script} = $v }
        elsif ($a eq '--now')         {
            my $v = shift @argv;
            return _bad() unless defined($v) && $v =~ /\A\d+\z/;
            $opt{now} = $v + 0;
        }
        else { return _bad() }
    }

    my $bytes = eval { project_report(%opt) };
    if (my $err = $@) {
        print STDERR 'almanac-sitrep: ' . _errstr($err) . "\n";
        return 1;
    }
    binmode(STDOUT);
    print STDOUT $bytes;
    return 0;
}

sub _bad {
    print STDERR _usage_text();
    return 2;
}

unless (caller) {
    exit run(@ARGV);
}

1;
