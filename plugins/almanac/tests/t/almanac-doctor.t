#!/usr/bin/env perl
# platform: any
# ORACLE for almanac-records package 17-doctor-and-cli, almanac-doctor.pl's
# diagnostic half. Derived ONLY from
# .ccpraxis-local-data/blueprints/almanac-records/specs/17-doctor-and-cli-spec.md
# sections 2.2, 3 and 4 (AC6-AC26, AC28) plus the package ledger's done
# criteria -- NOT from reading almanac-doctor.pl, which this package's write
# set has not written yet. Every module this file's fixtures build through
# (Almanac::Store, Almanac::Record, Almanac::Lock, Almanac::LegacyQueue,
# Almanac::Note, Almanac::Task, AlmanacBug) is named explicitly by the spec as
# shared machinery this package sits on top of, and is already implemented.
#
# HARD ISOLATION RULES (house convention + this blueprint's own hard rules):
#   - every project-scope call passes an explicit root/home, never a bare cwd
#     walk; a doctor subprocess's HOME/ALMANAC_HOME/USERPROFILE are always
#     this file's OWN temp dirs, never the real ones, and CLAUDE_PROJECT_DIR
#     is always unset for it.
#   - the real repo's .ccpraxis-local-data/almanac and bug-reports trees are
#     snapshotted before anything runs and compared again at the end.
#   - no test file here is ever run by another (Decision 11) -- this file
#     spawns only almanac-doctor.pl and small throwaway holder scripts it
#     writes into its own tempdir, never another *.t.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use File::Spec;
use Cwd qw(abs_path);
use Digest::SHA qw(sha256_hex);
use JSON::PP ();
use Sys::Hostname ();
use Time::HiRes ();
use POSIX qw(WNOHANG);

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
use lib "$Bin/../../scripts";

my $DOCTOR_PL    = "$S/almanac-doctor.pl";
my $DOCTOR_ABOUT = "$S/almanac-doctor.pl.about";
my $NOTE_PL      = "$S/almanac-note.pl";
my $TASK_PL      = "$S/almanac-task.pl";
my $DECISION_PL  = "$S/almanac-decision.pl";
my $BUG_PL       = "$S/almanac-bug.pl";

for my $f ($NOTE_PL, $TASK_PL, $DECISION_PL, $BUG_PL) {
    ok(-f $f, "precondition: $f exists (earlier package, already implemented)")
        or BAIL_OUT("missing $f -- fixtures cannot be built at all");
}

require Almanac::Store;
require Almanac::Record;
require Almanac::Lock;
require Almanac::LegacyQueue;
{
    local $@;
    do $NOTE_PL;     diag("almanac-note.pl load: $@")     if $@;
    do $TASK_PL;      diag("almanac-task.pl load: $@")      if $@;
    do $DECISION_PL;  diag("almanac-decision.pl load: $@")  if $@;
    do $BUG_PL;       diag("almanac-bug.pl load: $@")       if $@;
}

# =============================================================================
# Isolation guard: the REAL repo's own almanac + bug-reports trees, snapshot
# before/after this whole file.
# =============================================================================
(my $REPO_ROOT = "$Bin/../../../..") =~ s{\\}{/}g;
sub list_tree {
    my ($dir) = @_;
    return [] unless -d $dir;
    my @out;
    my @stack = ($dir);
    while (my $d = pop @stack) {
        opendir(my $dh, $d) or next;
        for my $e (readdir $dh) {
            next if $e eq '.' || $e eq '..';
            my $full = "$d/$e";
            if (-d $full) { push @stack, $full }
            else { (my $rel = $full) =~ s{\\}{/}g; push @out, $rel }
        }
        closedir $dh;
    }
    return [ sort @out ];
}
my $REAL_BEFORE = {
    almanac      => list_tree("$REPO_ROOT/.ccpraxis-local-data/almanac"),
    bug_reports  => list_tree("$REPO_ROOT/.ccpraxis-local-data/bug-reports"),
};

# =============================================================================
# Generic scaffolding
# =============================================================================
sub mk_root { my $t = tempdir(CLEANUP => 1); (my $n = $t) =~ s{\\}{/}g; return $n; }

# norm_root($p) -- mirrors Almanac::Store's OWN _canonical_path exactly
# (Cwd::abs_path, forward slashes, uppercase drive letter): the canonical
# LONG form every Store-produced path converges on, so a raw fixture
# spelling (tempdir's 8.3 short form, or a /tmp-style mount spelling) can be
# compared equal to whatever spelling doctor actually prints, regardless of
# which side happens to already be canonical (review finding S1).
sub norm_root {
    my ($p) = @_;
    return $p unless defined $p;
    my $abs = Cwd::abs_path($p);
    if (!defined $abs) {
        $abs = $p;
        $abs =~ s{\\}{/}g;
        $abs =~ s{^/([a-zA-Z])(?=/|\z)}{uc($1) . ':'}e;
    }
    $abs =~ s{\\}{/}g;
    $abs =~ s{/\z}{} if length($abs) > 1;
    $abs =~ s{^([a-zA-Z]):}{uc($1) . ':'}e;
    return $abs;
}

sub slurp_raw {
    my ($p) = @_;
    open(my $fh, '<:raw', $p) or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}
sub write_raw {
    my ($p, $bytes) = @_;
    open(my $fh, '>:raw', $p) or die "fixture: cannot write $p: $!";
    print {$fh} $bytes;
    close $fh;
}

sub write_registry {
    my ($home, %slug_path) = @_;
    my $dir = "$home/.claude/claude-code-vault";
    make_path($dir) unless -d $dir;
    my %projects = map { $_ => { path => $slug_path{$_} } } keys %slug_path;
    my $bytes = JSON::PP->new->canonical->utf8->encode({ version => 1, projects => \%projects });
    write_raw("$dir/.registry-local.json", $bytes);
}

# reseal($path) -- overwrite <path>.seal with a fresh one-line sha256 of the
# record's CURRENT bytes (an "accept the change" reseal, exactly what a
# record type's own verb does on a legitimate write).
sub reseal {
    my ($path) = @_;
    my $bytes = slurp_raw($path);
    write_raw("$path.seal", sha256_hex($bytes // '') . "\n");
}

# corrupt_line($path, $lineno_1based, $new_line_text_including_trailing_nl)
# Replaces exactly one physical line (split on /(?<=\n)/, so every chunk but
# possibly the last keeps its own \n), leaving every other byte untouched.
# The record's .seal file is NOT touched -- check_file() finds the problem
# before check_seal() would ever run for this record (spec 2.2.4/edge cases).
sub corrupt_line {
    my ($path, $lineno, $new_text) = @_;
    my $raw = slurp_raw($path);
    my @chunks = split /(?<=\n)/, $raw;
    die "fixture: line $lineno does not exist in $path (only " . scalar(@chunks) . " lines)"
        if $lineno < 1 || $lineno > @chunks;
    $chunks[$lineno - 1] = $new_text;
    write_raw($path, join('', @chunks));
}

# tamper_bytes($path) -- flips one character in the LAST field line's value,
# leaving frontmatter structurally valid (check_file finds no problem) but
# the digest no longer matching the (untouched) seal -- so check_seal reports
# tampered/bad_seal depending on what the caller does to the seal separately.
sub tamper_bytes {
    my ($path) = @_;
    my $raw = slurp_raw($path);
    my @chunks = split /(?<=\n)/, $raw;
    for my $i (reverse 0 .. $#chunks) {
        if ($chunks[$i] =~ /\A([A-Za-z0-9_]+): (.*)\n\z/) {
            my ($k, $v) = ($1, $2);
            $chunks[$i] = "$k: " . ($v eq '' ? 'x' : "${v}x") . "\n";
            write_raw($path, join('', @chunks));
            return;
        }
    }
    die "fixture: tamper_bytes found no field line to tamper in $path";
}

# ---------------------------------------------------------------------------
# run_child(\@cmd, %opt) -> { rc, stdout, stderr }
# fork()+exec(); each stream to its OWN File::Temp file in the CHILD only
# (never reopening THIS process's STDOUT/STDERR onto an in-memory scalar).
# opt: env => {...} (applied ON TOP of a scrubbed environment), stdin => $text
# ---------------------------------------------------------------------------
sub run_child {
    my ($cmd, %opt) = @_;
    my (undef, $outfile) = tempfile();
    my (undef, $errfile) = tempfile();
    my $stdinfile;
    if (defined $opt{stdin}) {
        (undef, $stdinfile) = tempfile();
        write_raw($stdinfile, $opt{stdin});
    }
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        delete $ENV{CLAUDE_PROJECT_DIR};
        delete $ENV{CCPRAXIS_DATA_DIR};
        delete $ENV{BP_PROJECT_ROOT};
        delete $ENV{BP_LEDGER};
        delete $ENV{ALMANAC_SURFACE};
        delete $ENV{ALMANAC_LOCK_TIMEOUT_MS};
        if ($opt{env}) {
            for my $k (keys %{ $opt{env} }) {
                if (defined $opt{env}{$k}) { $ENV{$k} = $opt{env}{$k} } else { delete $ENV{$k} }
            }
        }
        open(STDOUT, '>', $outfile) or exit(126);
        open(STDERR, '>', $errfile) or exit(126);
        if (defined $stdinfile) { open(STDIN, '<', $stdinfile) or exit(126) }
        else { open(STDIN, '<', File::Spec->devnull) or exit(126) }
        exec(@$cmd) or exit(127);
    }
    waitpid($pid, 0);
    my $rc = $? >> 8;
    return { rc => $rc, stdout => (slurp_raw($outfile) // ''), stderr => (slurp_raw($errfile) // '') };
}

sub run_doctor {
    my (%opt) = @_;
    my $home = $opt{home} // mk_root();
    my @args = @{ $opt{args} // [] };
    my %env = (ALMANAC_HOME => $home, HOME => $home, USERPROFILE => $home);
    $env{ALMANAC_SURFACE} = $opt{surface} if defined $opt{surface};
    return run_child([ $^X, $DOCTOR_PL, @args ], env => \%env, ($opt{stdin} ? (stdin => $opt{stdin}) : ()));
}

# ---------------------------------------------------------------------------
# Store fixtures -- created directly via Almanac::Store (sealed automatically
# by create(), per almanac-records package 09, already landed).
# ---------------------------------------------------------------------------
sub mk_store {
    my (%o) = @_; # scope, type, root|home
    return Almanac::Store->open(scope => $o{scope}, type => $o{type}, root => $o{root}, home => $o{home});
}
sub mk_record {
    my (%o) = @_; # scope, type, root|home, fields, order, id
    my $store = mk_store(%o);
    my $rec = $store->create(defined($o{id}) ? (id => $o{id}) : (), fields => $o{fields} || {}, order => $o{order} || []);
    return ($store, $rec);
}

# ---------------------------------------------------------------------------
# HOLDER.pl -- a real, separate perl process that takes a real flock, writes
# an accurate JSON holder-identity sidecar (unless with_identity is false),
# signals readiness, holds for $hold_s seconds, then exits (releasing the
# flock via fd close on exit, same as any process death).
# ---------------------------------------------------------------------------
my $HOLDER_WORK = tempdir(CLEANUP => 1);
$HOLDER_WORK =~ s{\\}{/}g;
my $HOLDER_PL = "$HOLDER_WORK/raw-holder.pl";
{
    open(my $fh, '>', $HOLDER_PL) or die "fixture: cannot write $HOLDER_PL: $!";
    print {$fh} <<'HOLDER';
#!/usr/bin/env perl
use strict;
use warnings;
use Fcntl qw(:flock);
use Time::HiRes ();
use JSON::PP ();
use Sys::Hostname ();
$| = 1;
my ($lockpath, $holderpath, $hold_s, $readypath, $verb) = @ARGV;
open(my $fh, '>', $lockpath) or do {
    open(my $rf, '>', $readypath); print {$rf} "OPEN-FAIL $!"; close $rf; exit 1;
};
flock($fh, LOCK_EX) or do {
    open(my $rf, '>', $readypath); print {$rf} "FLOCK-FAIL $!"; close $rf; exit 1;
};
if (defined $holderpath && $holderpath ne '-') {
    my $now = time;
    my @t = gmtime($now);
    my $iso = sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ',
                       $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
    my %rec = (
        pid => $$, host => Sys::Hostname::hostname(), script => $0,
        verb => (defined $verb && length $verb ? $verb : undef),
        target => $lockpath, acquired_at => $iso, acquired_at_epoch => $now,
    );
    open(my $hf, '>', $holderpath) or do {
        open(my $rf, '>', $readypath); print {$rf} "HOLDERWRITE-FAIL $!"; close $rf; exit 1;
    };
    print {$hf} JSON::PP->new->canonical->encode(\%rec);
    close $hf;
}
open(my $rf, '>', $readypath) or exit 1;
print {$rf} $$;
close $rf;
Time::HiRes::sleep($hold_s || 0);
close $fh;
exit 0;
HOLDER
    close $fh;
}
sub bounded_wait_for_file {
    my ($path, $deadline_s) = @_;
    my $t0 = Time::HiRes::time();
    my $deadline = $t0 + $deadline_s;
    while (!-e $path) {
        return 0 if Time::HiRes::time() >= $deadline;
        Time::HiRes::sleep(0.02);
    }
    return 1;
}
my $holder_n = 0;
# spawn_holder(target=>$record_path, hold_s=>N, with_identity=>0|1, verb=>'') -> ($pid, $lockpath, $holderpath)
sub spawn_holder {
    my (%o) = @_;
    my $target = $o{target} or die 'spawn_holder: target required';
    my $n = ++$holder_n;
    my $lockpath   = "$target.lock";
    my $holderpath = $o{with_identity} ? "$target.lock.holder" : '-';
    my $readypath  = "$HOLDER_WORK/ready-$n";
    system(qq{"$^X" "$HOLDER_PL" "$lockpath" "$holderpath" "$o{hold_s}" "$readypath" "@{[$o{verb}//'']}" &});
    my $up = bounded_wait_for_file($readypath, 10);
    return (undef, $lockpath, $holderpath) unless $up;
    open(my $rf, '<', $readypath); local $/; my $body = <$rf>; close $rf;
    my $pid = ($body =~ /^(\d+)$/) ? $1 : undef;
    return ($pid, $lockpath, "$target.lock.holder");
}

# a genuinely dead pid: fork a child that exits immediately, reap it, and
# hand back its (now-exited) pid. Per this batch's hard rule.
sub dead_pid {
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) { exit 0 }
    waitpid($pid, 0);
    return $pid;
}

sub write_holder_json {
    my ($holderpath, %rec) = @_;
    write_raw($holderpath, JSON::PP->new->canonical->encode(\%rec));
}
sub iso_now {
    my @t = gmtime(time);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

# alt_spelling($path) -- a second, equally-valid spelling of an existing
# directory (drive-letter form -> lowercase POSIX form), so a registry entry
# can be dedup-tested against a --root of the OTHER spelling (AC6, AC26).
sub alt_spelling {
    my ($p) = @_;
    if ($p =~ m{^([A-Za-z]):(/.*)$}) { return '/' . lc($1) . $2 }
    return $p;
}

# The finding-line oracle, pinned verbatim from spec section 4. Classes
# ARCHIVED-OPEN-TASK (11), BAD-LINK (12) and UNMIGRATED-TASKLIST (13) added
# by specs/02-thread-store-spec.md section 2.8. UNMIGRATED-BUG (14) added by
# blueprint where-things-go, package 07-bug-lifecycle, specs/
# 07-bug-lifecycle-spec.md section 2.11 (a BAD-LINK bug finding reuses the
# existing BAD-LINK class, num 12, with type 'bug' -- no regex change needed
# for that one).
# NOTE (specs/02-thread-store-spec.md section 2.8): a thread finding's id is
# itself `<thread>/<task>` (contains its own internal '/'), so the
# type/id split below is made NON-GREEDY on the type side ((\S+?)) -- it
# splits at the FIRST '/' rather than the last, which is identical to the
# old (greedy) behaviour whenever id has no '/' of its own (every pre-
# existing finding kind) and is now also correct for `thread`.
my $FINDING_RE = qr/^(UNPARSEABLE|TAMPERED|UNVERIFIED|DANGLING-POINTER|DANGLING-REF|INTERRUPTED-REORDER|CHECK-FAILED|LOCK-HOLDER-GONE|LEGACY-QUEUE|ARCHIVED-OPEN-TASK|BAD-LINK|UNMIGRATED-TASKLIST|UNMIGRATED-BUG): (\S+) (\S+?)\/(\S+): (.*) -- (.+) -- repair: (.+)$/;
sub parse_findings {
    my ($stdout) = @_;
    my @lines = split /\n/, $stdout;
    my @parsed;
    for my $l (@lines) {
        if ($l =~ $FINDING_RE) {
            push @parsed, { class => $1, scope => $2, type => $3, id => $4, detail => $5, path => $6, repair => $7, raw => $l };
        }
    }
    return @parsed;
}

# =============================================================================
# AC6 (DC10, DC3, DC8) -- a clean fixture across current + registered project,
# both scopes, task-focus, a frozen bug report, lock sidecars naming exited
# pids, and an already-migrated legacy file: no output, exit 0.
# =============================================================================
{
    my $H6 = mk_root();
    my $P1 = mk_root();
    my $P2 = mk_root();
    write_registry($H6, p2 => $P2, p1 => alt_spelling($P1));

    for my $P ($P1, $P2) {
        my ($ts) = mk_record(scope => 'project', type => 'todo', root => $P,
            fields => { title => 'clean todo', status => 'open' }, order => [qw(title status)]);
        my ($ns) = mk_record(scope => 'project', type => 'note', root => $P,
            fields => { title => 'clean note', audience => 'internal', target => 'clean-target.md' },
            order => [qw(title audience target)]);
        write_raw("$P/clean-target.md", "target exists\n");
        my ($dstore, $drec) = mk_record(scope => 'project', type => 'inbox', root => $P,
            fields => { title => 'clean inbox item', status => 'unanswered' }, order => [qw(title status)]);
        mk_record(scope => 'project', type => 'task', root => $P,
            fields => { title => 'clean task', status => 'pending', blocked_on => $drec->{id} },
            order => [qw(title status blocked_on)]);
        mk_record(scope => 'project', type => 'task-focus', root => $P,
            fields => { session => 'sess1', task => 'x' }, order => [qw(session task)]);
    }
    mk_record(scope => 'global', type => 'todo', home => $H6,
        fields => { title => 'clean global todo', status => 'open' }, order => [qw(title status)]);
    mk_record(scope => 'global', type => 'note', home => $H6,
        fields => { title => 'clean global note', audience => 'internal', target => 'g-target.md' },
        order => [qw(title audience target)]);
    write_raw("$H6/.claude/claude-code-vault/g-target.md", "global target exists\n");

    my $bug_res = run_child([ $^X, $BUG_PL, 'file', '--project', $P1, '--title', 'clean bug',
        '--severity', 'low', '--area', 'sandbox', '--body', 'a clean bug' ], env => { ALMANAC_HOME => $H6, HOME => $H6, USERPROFILE => $H6 });
    is($bug_res->{rc}, 0, 'AC6 fixture: bug report filed') or diag($bug_res->{stderr});
    chomp(my $bug_path = $bug_res->{stdout});
    my ($bug_id) = $bug_path =~ m{/([^/]+)\.md$};
    my $freeze_res = run_child([ $^X, $BUG_PL, 'set-status', $bug_id, '--project', $P1, '--to', 'dropped',
        '--note', 'dropped for fixture' ],
        env => { ALMANAC_HOME => $H6, HOME => $H6, USERPROFILE => $H6 });
    is($freeze_res->{rc}, 0, 'AC6 fixture: bug report frozen') or diag($freeze_res->{stderr});

    make_path("$P1/.ccpraxis-local-data/.subagent-guard");
    write_raw("$P1/.ccpraxis-local-data/.subagent-guard/questions.md.migrated", "- already migrated?\n");

    my $res = run_doctor(home => $H6, args => [ '--root', $P1 ]);
    # where-things-go package 02-thread-store (specs/02-thread-store-spec.md
    # 2.8, finding 13): this fixture deliberately seeds >=1 record straight
    # into the flat `task` Store for both P1 and P2 (line ~397 above), which
    # now unconditionally fires one UNMIGRATED-TASKLIST finding per project
    # -- so "clean" here means clean of every OTHER finding kind, not
    # entirely silent. stderr/exit-code semantics for "N finding(s) present"
    # are unchanged.
    is($res->{stderr}, '', 'AC6: clean fixture -- stderr is empty') or diag('stderr: ' . $res->{stderr});
    is($res->{rc}, 1, 'AC6: clean fixture -- exit 1 (UNMIGRATED-TASKLIST only)') or diag('stdout: ' . $res->{stdout});
    my @ac6_findings = parse_findings($res->{stdout});
    is(scalar(@ac6_findings), 2, 'AC6: clean fixture -- exactly 2 findings total') or diag($res->{stdout});
    my @ac6_um = grep { $_->{class} eq 'UNMIGRATED-TASKLIST' } @ac6_findings;
    is(scalar(@ac6_um), 2, 'AC6: clean fixture -- both findings are UNMIGRATED-TASKLIST (one per project)');
    for my $f (@ac6_um) {
        is($f->{scope}, 'project', 'AC6: UNMIGRATED-TASKLIST scope is project');
        is($f->{type}, 'task', 'AC6: UNMIGRATED-TASKLIST type is task');
        is($f->{id}, '-', 'AC6: UNMIGRATED-TASKLIST id is -');
        like($f->{detail}, qr/the flat tasklist holds 1 record\(s\) not yet migrated to threads/,
            'AC6: UNMIGRATED-TASKLIST detail names the count');
    }
    my %ac6_roots = map { (($_->{repair} =~ /--root "([^"]+)"/) ? (norm_root($1) => 1) : ()) } @ac6_um;
    is_deeply([ sort keys %ac6_roots ], [ sort (norm_root($P1), norm_root($P2)) ],
        'AC6: the two UNMIGRATED-TASKLIST findings cover exactly P1 and P2 (nothing else, nothing missing)');
}

# =============================================================================
# AC7 (DC4, DC3, DC11) -- UNPARSEABLE with file+line, both scopes; a record
# with two problems yields two ascending lines.
# =============================================================================
{
    my $H7 = mk_root();
    my $P2 = mk_root();
    write_registry($H7, p2 => $P2);

    my ($tstore, $trec) = mk_record(scope => 'project', type => 'todo', root => $P2,
        fields => { title => 'x' }, order => [qw(title)]);
    corrupt_line($trec->{path}, 3, "not a field\n");

    my ($nstore, $nrec) = mk_record(scope => 'global', type => 'note', home => $H7,
        fields => { title => 'y', audience => 'internal', target => 'z.md' }, order => [qw(title audience target)]);
    corrupt_line($nrec->{path}, 2, "id: " . $nrec->{id} . "\r\n");

    my $res = run_doctor(home => $H7, args => [ '--root', $P2 ]);
    my @findings = parse_findings($res->{stdout});
    my @unparse = grep { $_->{class} eq 'UNPARSEABLE' } @findings;
    is(scalar(@unparse), 2, 'AC7: exactly 2 UNPARSEABLE lines') or diag($res->{stdout});
    my ($todo_f) = grep { $_->{path} eq $trec->{path} } @unparse;
    my ($note_f) = grep { $_->{path} eq $nrec->{path} } @unparse;
    ok(defined $todo_f, 'AC7: the corrupted project todo produced a finding');
    ok(defined $note_f, 'AC7: the corrupted global note produced a finding');
    if ($todo_f) {
        is($todo_f->{detail}, 'line 3: bad_field_line', 'AC7: todo detail is "line 3: bad_field_line"');
        is($todo_f->{scope}, 'project', 'AC7: todo scope is project');
        is($todo_f->{type}, 'todo', 'AC7: todo type is todo');
    }
    if ($note_f) {
        is($note_f->{detail}, 'line 2: carriage_return', 'AC7: note detail is "line 2: carriage_return"');
        is($note_f->{scope}, 'global', 'AC7: note scope is global');
        is($note_f->{type}, 'note', 'AC7: note type is note');
    }
    is($res->{rc}, 1, 'AC7: exit 1 with findings present');

    # the two-problems-in-one-record case, isolated so its own line count is
    # unambiguous.
    my $H7b = mk_root();
    my $P7b = mk_root();
    my ($ts2, $trec2) = mk_record(scope => 'project', type => 'todo', root => $P7b,
        fields => { title => 'x', aa => '1', bb => '2', cc => '3' }, order => [qw(title aa bb cc)]);
    corrupt_line($trec2->{path}, 3, "not a field\n");
    my $raw2 = slurp_raw($trec2->{path});
    my @chunks2 = split /(?<=\n)/, $raw2;
    my $last_field_line = scalar(@chunks2) - 1; # last line is closing '---'
    corrupt_line($trec2->{path}, $last_field_line, ($chunks2[$last_field_line - 1] =~ s/\n\z/\r\n/r));

    my $res2 = run_doctor(home => $H7b, args => [ '--root', $P7b ]);
    my @findings2 = parse_findings($res2->{stdout});
    my @unparse2 = grep { $_->{class} eq 'UNPARSEABLE' && $_->{path} eq $trec2->{path} } @findings2;
    is(scalar(@unparse2), 2, 'AC7: a record with two problems yields two UNPARSEABLE lines') or diag($res2->{stdout});
    if (@unparse2 == 2) {
        my @line_nos = map { $_->{detail} =~ /^line (\d+):/ ? $1 : -1 } @unparse2;
        ok($line_nos[0] < $line_nos[1], "AC7: the two lines are in ASCENDING line order ($line_nos[0] < $line_nos[1])");
    }
}

# =============================================================================
# AC8 (DC4) -- a bug report with a duplicated frontmatter key.
# =============================================================================
{
    my $H8 = mk_root();
    my $P8 = mk_root();
    my $res_f = run_child([ $^X, $BUG_PL, 'file', '--project', $P8, '--title', 'dup key bug',
        '--severity', 'low', '--area', 'sandbox', '--body', 'body text' ],
        env => { ALMANAC_HOME => $H8, HOME => $H8, USERPROFILE => $H8 });
    is($res_f->{rc}, 0, 'AC8 fixture: bug report filed') or diag($res_f->{stderr});
    chomp(my $bpath = $res_f->{stdout});
    my $raw = slurp_raw($bpath);
    $raw =~ s/^(area: sandbox\n)/${1}area: sandbox\n/m;
    write_raw($bpath, $raw);

    my $res = run_doctor(home => $H8, args => [ '--root', $P8 ]);
    my @findings = grep { $_->{class} eq 'UNPARSEABLE' } parse_findings($res->{stdout});
    my ($dup) = grep { $_->{path} eq $bpath } @findings;
    ok(defined $dup, 'AC8: the duplicate-key bug report produced an UNPARSEABLE finding') or diag($res->{stdout});
    if ($dup) {
        is($dup->{scope}, 'project', 'AC8: scope is project');
        is($dup->{type}, 'bug', 'AC8: type is bug');
        is($dup->{detail}, 'line 0: duplicate_key', 'AC8: detail is "line 0: duplicate_key"');
    }
}

# =============================================================================
# AC9 (DC5, DC3) -- dangling note pointers, project + global; an in_flight
# note (promote_to set, destination present) is NOT reported.
# =============================================================================
{
    my $H9 = mk_root();
    my $P9 = mk_root();
    my (undef, $prec) = mk_record(scope => 'project', type => 'note', root => $P9,
        fields => { title => 'dangling project note', audience => 'internal', target => 'gone.md' },
        order => [qw(title audience target)]);
    my (undef, $grec) = mk_record(scope => 'global', type => 'note', home => $H9,
        fields => { title => 'dangling global note', audience => 'internal', target => 'gone-too.md' },
        order => [qw(title audience target)]);
    # the in_flight note: promote_to points at a file that DOES exist.
    my (undef, $inflight) = mk_record(scope => 'project', type => 'note', root => $P9,
        fields => { title => 'in flight', audience => 'internal', promote_to => 'promoted.md' },
        order => [qw(title audience promote_to)]);
    write_raw("$P9/promoted.md", "promoted destination exists\n");

    my $res = run_doctor(home => $H9, args => [ '--root', $P9 ]);
    my @findings = parse_findings($res->{stdout});
    my @dangling = grep { $_->{class} eq 'DANGLING-POINTER' } @findings;
    is(scalar(@dangling), 2, 'AC9: exactly 2 DANGLING-POINTER lines') or diag($res->{stdout});
    my ($pf) = grep { $_->{path} eq $prec->{path} } @dangling;
    my ($gf) = grep { $_->{path} eq $grec->{path} } @dangling;
    ok(defined $pf, 'AC9: the project note is reported');
    ok(defined $gf, 'AC9: the global note is reported');
    if ($pf) {
        is($pf->{scope}, 'project', 'AC9: project note scope is project');
        like($pf->{repair}, qr/almanac note delete \Q$prec->{id}\E --root "\Q$P9\E", or recreate the target file/,
            'AC9: project note repair names delete + --root + the id, or recreate');
    }
    if ($gf) {
        is($gf->{scope}, 'global', 'AC9: global note scope is global');
        like($gf->{repair}, qr/almanac note delete \Q$grec->{id}\E --global, or recreate the target file/,
            'AC9: global note repair names delete + --global + the id, or recreate');
    }
    ok(!(grep { $_->{path} eq $inflight->{path} } @findings),
        'AC9: the in_flight note (promote_to set, destination present) is NOT reported');
    is($res->{rc}, 1, 'AC9: exit 1');
}

# =============================================================================
# AC10/AC13 (specs/02-thread-store-spec.md section 2.8) -- OVERRIDDEN: doctor
# no longer scans the flat `task` store at all (Almanac::Task::check_refs is
# removed; Almanac::Thread::check_refs restates it over every thread's
# UNLINKED tasks). A thread task blocked_on a nonexistent inbox item is
# reported with type `thread`, id `<thread>/<task>`, and the thread-specific
# repair command; a task blocked on an existing inbox item is not reported.
# Fixtures build the thread/thread-tasks-<name> stores directly (mirroring
# exactly what Almanac::Thread::add_task would write), since Thread.pm does
# not exist yet to do it through the library.
# =============================================================================
{
    my $H10 = mk_root();
    my $P10 = mk_root();
    my (undef, $drec) = mk_record(scope => 'project', type => 'inbox', root => $P10,
        fields => { title => 'real inbox item', status => 'unanswered' }, order => [qw(title status)]);
    mk_record(scope => 'project', type => 'thread', root => $P10, id => 'ac10-thread',
        fields => { created => '2026-01-01T00:00:00Z', state => 'live', owner_kind => 'none', owner_id => '-' },
        order => [qw(created state owner_kind owner_id)]);
    my (undef, $bad_task) = mk_record(scope => 'project', type => 'thread-tasks-ac10-thread', root => $P10,
        fields => { title => 'blocked on nothing', created => '2026-01-01T00:00:00Z', status => 'pending', blocked_on => 'nosuch-decision' },
        order => [qw(title created status blocked_on)]);
    my (undef, $ok_task) = mk_record(scope => 'project', type => 'thread-tasks-ac10-thread', root => $P10,
        fields => { title => 'blocked on real', created => '2026-01-01T00:00:00Z', status => 'pending', blocked_on => $drec->{id} },
        order => [qw(title created status blocked_on)]);

    my $res = run_doctor(home => $H10, args => [ '--root', $P10 ]);
    my @findings = parse_findings($res->{stdout});
    my @dref = grep { $_->{class} eq 'DANGLING-REF' } @findings;
    is(scalar(@dref), 1, 'AC10: exactly 1 DANGLING-REF line') or diag($res->{stdout});
    if (@dref) {
        my $f = $dref[0];
        is($f->{type}, 'thread', 'AC10 (spec 2.8): type is thread (never task -- the flat store is not scanned)');
        is($f->{id}, "ac10-thread/$bad_task->{id}", 'AC10 (spec 2.8): id is <thread>/<task>');
        is($f->{detail}, 'blocked_on nosuch-decision names no inbox item', 'spec 2.7/2.8: detail names the target, "names no inbox item"');
        like($f->{repair}, qr/almanac thread edit ac10-thread \Q$bad_task->{id}\E --clear-blocked-on --root "\Q$P10\E"/,
            'AC10 (spec 2.8): repair is the exact thread edit --clear-blocked-on command');
    }
    ok(!(grep { $_->{id} =~ /\Q$ok_task->{id}\E\z/ } @dref), 'AC10: the task blocked on a REAL inbox item is not reported');
}

# =============================================================================
# AC13 (specs/02-thread-store-spec.md section 2.8) -- a record left in the
# FLAT `task` store (never scanned for DANGLING-REF any more) produces NO
# DANGLING-REF finding at all -- confirms the Almanac::Task::check_refs loop
# is gone, not merely redirected.
# =============================================================================
{
    my $H10b = mk_root();
    my $P10b = mk_root();
    mk_record(scope => 'project', type => 'task', root => $P10b,
        fields => { title => 'flat, blocked on nothing', status => 'pending', blocked_on => 'nosuch-decision' },
        order => [qw(title status blocked_on)]);
    my $res = run_doctor(home => $H10b, args => [ '--root', $P10b ]);
    my @findings = parse_findings($res->{stdout});
    my @dref = grep { $_->{class} eq 'DANGLING-REF' } @findings;
    is(scalar(@dref), 0, 'AC13 (spec 2.8): a dangling blocked_on left in the flat task store produces no DANGLING-REF (not scanned)')
        or diag($res->{stdout});
}

# =============================================================================
# B18 (re-expressed for threads) -- an unmigrated A/decision/ (no A/inbox/):
# Almanac::Thread::check_refs's blocked_on check falls back to the legacy
# dir and reports no DANGLING-REF for a thread task blocked on a record that
# genuinely exists there; one naming nothing still reports "names no inbox
# item"; doctor never migrates (both dirs byte-unchanged).
# =============================================================================
{
    my $H18 = mk_root();
    my $P18 = mk_root();
    my (undef, $drec18) = mk_record(scope => 'project', type => 'decision', root => $P18,
        fields => { title => 'legacy real item', status => 'unanswered' }, order => [qw(title status)]);
    mk_record(scope => 'project', type => 'thread', root => $P18, id => 'b18-thread',
        fields => { created => '2026-01-01T00:00:00Z', state => 'live', owner_kind => 'none', owner_id => '-' },
        order => [qw(created state owner_kind owner_id)]);
    my (undef, $bad_task18) = mk_record(scope => 'project', type => 'thread-tasks-b18-thread', root => $P18,
        fields => { title => 'blocked on nothing', created => '2026-01-01T00:00:00Z', status => 'pending', blocked_on => 'nosuch-decision' },
        order => [qw(title created status blocked_on)]);
    my (undef, $ok_task18) = mk_record(scope => 'project', type => 'thread-tasks-b18-thread', root => $P18,
        fields => { title => 'blocked on legacy real', created => '2026-01-01T00:00:00Z', status => 'pending', blocked_on => $drec18->{id} },
        order => [qw(title created status blocked_on)]);

    my $res18 = run_doctor(home => $H18, args => [ '--root', $P18 ]);
    my @findings18 = parse_findings($res18->{stdout});
    my @dref18 = grep { $_->{class} eq 'DANGLING-REF' } @findings18;
    is(scalar(@dref18), 1, 'B18: exactly 1 DANGLING-REF line on an unmigrated A/decision/ project') or diag($res18->{stdout});
    ok(!(grep { $_->{id} =~ /\Q$ok_task18->{id}\E\z/ } @dref18),
        'B18: the task blocked on a REAL legacy A/decision/ record is not reported (fallback read succeeds)');
    if (@dref18) {
        is($dref18[0]->{detail}, 'blocked_on nosuch-decision names no inbox item',
            'B18: the dangling one still reports "names no inbox item" via the fallback');
    }
    ok(-d "$P18/.ccpraxis-local-data/almanac/decision", 'B18: A/decision still exists after doctor runs (never migrated)');
    ok(!-d "$P18/.ccpraxis-local-data/almanac/inbox", 'B18: A/inbox was never created by doctor');
}

# ---------------------------------------------------------------------------
# write_pkg_ledger($root, $bp, $pkg, $status, archived=>0|1) -- the minimal
# frontmatter PackageLink::resolve reads.
# ---------------------------------------------------------------------------
sub write_pkg_ledger {
    my ($root, $bp, $pkg, $status, %opt) = @_;
    my $base = $opt{archived}
        ? norm_root($root) . "/.ccpraxis-local-data/blueprints/_archive/$bp/packages"
        : norm_root($root) . "/.ccpraxis-local-data/blueprints/$bp/packages";
    make_path($base);
    open(my $fh, '>:raw', "$base/$pkg.md") or die "fixture: cannot write $base/$pkg.md: $!";
    print {$fh} "---\nstatus: $status\n---\n";
    close $fh;
}

# =============================================================================
# AC13 (specs/02-thread-store-spec.md section 2.8) -- ARCHIVED-OPEN-TASK: an
# unlinked task whose status is not done/obsoleted in an ARCHIVED thread.
# =============================================================================
{
    my $Harc = mk_root();
    my $Parc = mk_root();
    mk_record(scope => 'project', type => 'thread', root => $Parc, id => 'arc-thread',
        fields => { created => '2026-01-01T00:00:00Z', state => 'archived', owner_kind => 'none', owner_id => '-', archived_at => '2026-01-02T00:00:00Z' },
        order => [qw(created state owner_kind owner_id archived_at)]);
    my (undef, $open_task) = mk_record(scope => 'project', type => 'thread-tasks-arc-thread', root => $Parc,
        fields => { title => 'still open', created => '2026-01-01T00:00:00Z', status => 'doing' },
        order => [qw(title created status)]);
    mk_record(scope => 'project', type => 'thread-tasks-arc-thread', root => $Parc,
        fields => { title => 'actually done', created => '2026-01-01T00:00:00Z', status => 'done' },
        order => [qw(title created status)]);

    my $res = run_doctor(home => $Harc, args => [ '--root', $Parc ]);
    my @findings = parse_findings($res->{stdout});
    my @aot = grep { $_->{class} eq 'ARCHIVED-OPEN-TASK' } @findings;
    is(scalar(@aot), 1, 'AC13: exactly one ARCHIVED-OPEN-TASK finding (the done task is not flagged)') or diag($res->{stdout});
    if (@aot) {
        is($aot[0]{type}, 'thread', 'AC13: ARCHIVED-OPEN-TASK type is thread');
        is($aot[0]{id}, "arc-thread/$open_task->{id}", 'AC13: ARCHIVED-OPEN-TASK id is <thread>/<task>');
        like($aot[0]{detail}, qr/task \Q$open_task->{id}\E is doing in archived thread arc-thread/,
            'AC13: detail names the task, status and thread');
        like($aot[0]{repair}, qr/almanac thread status arc-thread \Q$open_task->{id}\E done --root "\Q$Parc\E"/,
            'AC13: repair is the exact thread status ... done command');
    }
}

# =============================================================================
# AC13 -- BAD-LINK: missing / parked / dropped, and NEVER for an archived-
# thread's linked task or a link resolving under blueprints/_archive.
# =============================================================================
{
    my $Hbl = mk_root();
    my $Pbl = mk_root();
    mk_record(scope => 'project', type => 'thread', root => $Pbl, id => 'bl-thread',
        fields => { created => '2026-01-01T00:00:00Z', state => 'live', owner_kind => 'none', owner_id => '-' },
        order => [qw(created state owner_kind owner_id)]);
    write_pkg_ledger($Pbl, 'bpm', '01-m', 'parked');
    write_pkg_ledger($Pbl, 'bpd', '01-d', 'dropped');
    my (undef, $missing_task) = mk_record(scope => 'project', type => 'thread-tasks-bl-thread', root => $Pbl,
        fields => { title => 'bpmissing/01-x', created => '2026-01-01T00:00:00Z', link => 'bpmissing/01-x' },
        order => [qw(title created link)]);
    my (undef, $parked_task) = mk_record(scope => 'project', type => 'thread-tasks-bl-thread', root => $Pbl,
        fields => { title => 'bpm/01-m', created => '2026-01-01T00:00:00Z', link => 'bpm/01-m' },
        order => [qw(title created link)]);
    my (undef, $dropped_task) = mk_record(scope => 'project', type => 'thread-tasks-bl-thread', root => $Pbl,
        fields => { title => 'bpd/01-d', created => '2026-01-01T00:00:00Z', link => 'bpd/01-d' },
        order => [qw(title created link)]);
    # archived-only blueprint: never flagged, whatever its status.
    write_pkg_ledger($Pbl, 'bpa', '01-a', 'parked', archived => 1);
    my (undef, $archived_link_task) = mk_record(scope => 'project', type => 'thread-tasks-bl-thread', root => $Pbl,
        fields => { title => 'bpa/01-a', created => '2026-01-01T00:00:00Z', link => 'bpa/01-a' },
        order => [qw(title created link)]);

    my $res = run_doctor(home => $Hbl, args => [ '--root', $Pbl ]);
    my @findings = parse_findings($res->{stdout});
    my @bl = grep { $_->{class} eq 'BAD-LINK' } @findings;
    is(scalar(@bl), 3, 'AC13: exactly three BAD-LINK findings (missing, parked, dropped; archived-location link never flagged)')
        or diag($res->{stdout});
    my %by_id = map { $_->{id} => $_ } @bl;
    if (exists $by_id{"bl-thread/$missing_task->{id}"}) {
        like($by_id{"bl-thread/$missing_task->{id}"}{detail}, qr/link bpmissing\/01-x is missing/, 'AC13: BAD-LINK missing detail');
        like($by_id{"bl-thread/$missing_task->{id}"}{repair}, qr/restore the ledger, or almanac thread archive bl-thread --root "\Q$Pbl\E"/,
            'AC13: BAD-LINK missing repair');
    } else { fail('AC13: BAD-LINK missing finding present') }
    if (exists $by_id{"bl-thread/$parked_task->{id}"}) {
        like($by_id{"bl-thread/$parked_task->{id}"}{detail}, qr/link bpm\/01-m package is parked/, 'AC13: BAD-LINK parked detail');
        like($by_id{"bl-thread/$parked_task->{id}"}{repair}, qr/read the package ledger and unpark it or archive the thread/,
            'AC13: BAD-LINK parked repair');
    } else { fail('AC13: BAD-LINK parked finding present') }
    if (exists $by_id{"bl-thread/$dropped_task->{id}"}) {
        like($by_id{"bl-thread/$dropped_task->{id}"}{detail}, qr/link bpd\/01-d package is dropped/, 'AC13: BAD-LINK dropped detail');
        like($by_id{"bl-thread/$dropped_task->{id}"}{repair}, qr/almanac thread archive-if-done bl-thread --root "\Q$Pbl\E"/,
            'AC13: BAD-LINK dropped repair');
    } else { fail('AC13: BAD-LINK dropped finding present') }
    ok(!exists $by_id{"bl-thread/$archived_link_task->{id}"},
        'AC13: a link resolving under blueprints/_archive is never flagged (Decision 18 F1), regardless of status');
}

# =============================================================================
# DC2 (specs/07-bug-lifecycle-spec.md section 2.11, AC16 there) -- BAD-LINK
# findings for a `scheduled` BUG report (type 'bug', reusing the BAD-LINK
# class and num 12): missing, parked, dropped and syntactically invalid
# links are each flagged; a link resolving only under blueprints/_archive,
# and a package still active (not done/parked/dropped), are never flagged.
#
# Written directly to disk (bypassing the CLI): almanac-bug.pl does not yet
# support `--to scheduled` at all (write_set, not yet implemented) -- this is
# the oracle for the behavior that implementation must produce.
# =============================================================================
{
    my $Hbg = mk_root();
    my $Pbg = mk_root();
    my $bg_seq = 0;

    write_pkg_ledger($Pbg, 'bgpm',  '01-m',  'parked');
    write_pkg_ledger($Pbg, 'bgpd',  '01-d',  'dropped');
    write_pkg_ledger($Pbg, 'bgpa',  '01-a',  'parked', archived => 1);
    write_pkg_ledger($Pbg, 'bgpok', '01-ok', 'running');

    my $mk_scheduled_bug = sub {
        my (%o) = @_;
        my $id   = AlmanacBug::new_id() . sprintf('-bg%02d', ++$bg_seq);
        my $now  = AlmanacBug::_iso(time);
        my $body = 'body text';
        my $dir  = AlmanacBug::reports_dir($Pbg);
        make_path($dir) unless -d $dir;
        my $path = "$dir/$id.md";
        my %f = (
            id => $id, title => ($o{title} // 'scheduled bug'), status => 'scheduled',
            severity => 'unknown', area => 'unknown', project => $Pbg,
            created_at => $now, updated_at => $now, frozen_at => $now,
            content_sha256 => AlmanacBug::body_digest($body),
            package => $o{package}, package_root => $Pbg, scheduled_at => $now,
        );
        my @order = qw(id title status severity area project created_at updated_at
                       frozen_at content_sha256 package package_root scheduled_at);
        open my $fh, '>:raw', $path or die "fixture: cannot write $path: $!";
        print {$fh} "---\n" . join("\n", map { "$_: $f{$_}" } @order) . "\n---\n$body";
        close $fh;
        return ($path, $id);
    };

    my (undef, $missing_id)  = $mk_scheduled_bug->(title => 'bg missing',  package => 'bgpmissing/01-x');
    my (undef, $parked_id)   = $mk_scheduled_bug->(title => 'bg parked',   package => 'bgpm/01-m');
    my (undef, $dropped_id)  = $mk_scheduled_bug->(title => 'bg dropped',  package => 'bgpd/01-d');
    my (undef, $invalid_id)  = $mk_scheduled_bug->(title => 'bg invalid',  package => 'not-a-link');
    my (undef, $archived_id) = $mk_scheduled_bug->(title => 'bg archived', package => 'bgpa/01-a');
    my (undef, $active_id)   = $mk_scheduled_bug->(title => 'bg active',   package => 'bgpok/01-ok');

    my $res = run_doctor(home => $Hbg, args => [ '--root', $Pbg ]);
    my @findings = parse_findings($res->{stdout});
    my @bl = grep { $_->{class} eq 'BAD-LINK' && $_->{type} eq 'bug' } @findings;
    is(scalar(@bl), 4, 'DC2: exactly 4 BAD-LINK/bug findings (missing, parked, dropped, invalid)')
        or diag($res->{stdout});
    my %by_id = map { $_->{id} => $_ } @bl;
    if (exists $by_id{$missing_id}) {
        like($by_id{$missing_id}{detail}, qr/link bgpmissing\/01-x is missing/, 'DC2: BAD-LINK/bug missing detail');
        like($by_id{$missing_id}{repair},
            qr/restore the ledger, or almanac bug set-status \Q$missing_id\E --to dropped --note "<why>" --project "\Q$Pbg\E"/,
            'DC2: BAD-LINK/bug missing repair');
    } else { fail('DC2: BAD-LINK/bug missing finding present') }
    if (exists $by_id{$parked_id}) {
        like($by_id{$parked_id}{detail}, qr/link bgpm\/01-m package is parked/, 'DC2: BAD-LINK/bug parked detail');
        like($by_id{$parked_id}{repair},
            qr/unpark the package, or almanac bug set-status \Q$parked_id\E --to dropped --note "<why>" --project "\Q$Pbg\E"/,
            'DC2: BAD-LINK/bug parked repair');
    } else { fail('DC2: BAD-LINK/bug parked finding present') }
    if (exists $by_id{$dropped_id}) {
        like($by_id{$dropped_id}{detail}, qr/link bgpd\/01-d package is dropped/, 'DC2: BAD-LINK/bug dropped detail');
        like($by_id{$dropped_id}{repair},
            qr/almanac bug set-status \Q$dropped_id\E --to dropped --note "<why>" --project "\Q$Pbg\E"/,
            'DC2: BAD-LINK/bug dropped repair');
    } else { fail('DC2: BAD-LINK/bug dropped finding present') }
    if (exists $by_id{$invalid_id}) {
        like($by_id{$invalid_id}{detail}, qr/package link 'not-a-link' is invalid/, 'DC2: BAD-LINK/bug invalid detail');
        like($by_id{$invalid_id}{repair},
            qr/almanac bug set-status \Q$invalid_id\E --to dropped --note "<why>" --project "\Q$Pbg\E"/,
            'DC2: BAD-LINK/bug invalid repair');
    } else { fail('DC2: BAD-LINK/bug invalid finding present') }
    ok(!exists $by_id{$archived_id},
        'DC2: a link resolving under blueprints/_archive is never flagged, regardless of status (Decision 18 F1)');
    ok(!exists $by_id{$active_id},
        'DC2: a package that is merely active (not done/parked/dropped) produces no BAD-LINK/bug finding');
}

# =============================================================================
# DC4 (specs/07-bug-lifecycle-spec.md section 2.11) -- UNMIGRATED-BUG (14):
# a 'taken' bug report whose resolution note names no resolvable package is
# flagged; one whose note DOES resolve gets no such finding (it migrates on
# the next almanac-bug.pl call instead -- doctor itself never writes).
# =============================================================================
{
    my $Hum2 = mk_root();
    my $Pum2 = mk_root();
    my $now  = AlmanacBug::_iso(time);
    my $body = 'body';
    my $dir  = AlmanacBug::reports_dir($Pum2);
    make_path($dir) unless -d $dir;

    my @order = qw(id title status severity area project created_at updated_at
                   frozen_at content_sha256 taken_at resolution);
    my $write_taken = sub {
        my (%o) = @_;
        my $id = $o{id};
        my $path = "$dir/$id.md";
        my %f = (
            id => $id, title => ($o{title} // 'stuck taken'), status => 'taken',
            severity => 'unknown', area => 'unknown', project => $Pum2,
            created_at => $now, updated_at => $now, frozen_at => $now,
            content_sha256 => AlmanacBug::body_digest($body),
            taken_at => $now, resolution => $o{resolution},
        );
        open my $fh, '>:raw', $path or die "fixture: cannot write $path: $!";
        print {$fh} "---\n" . join("\n", map { defined $f{$_} ? "$_: $f{$_}" : () } @order) . "\n---\n$body";
        close $fh;
    };

    my $id1 = AlmanacBug::new_id() . '-umbg1';
    $write_taken->(id => $id1, resolution => 'investigating still');

    my $res = run_doctor(home => $Hum2, args => [ '--root', $Pum2 ]);
    my @findings = parse_findings($res->{stdout});
    my @um = grep { $_->{class} eq 'UNMIGRATED-BUG' } @findings;
    is(scalar(@um), 1, 'DC4: exactly one UNMIGRATED-BUG finding (the resolution names no package)')
        or diag($res->{stdout});
    if (@um) {
        is($um[0]{type}, 'bug', 'DC4: UNMIGRATED-BUG type is bug');
        is($um[0]{id}, $id1, 'DC4: UNMIGRATED-BUG id is the report id');
        like($um[0]{detail}, qr/status 'taken' predates 'scheduled', and its note names no package/,
            'DC4: UNMIGRATED-BUG detail names the reason from spec sec 2.7');
        like($um[0]{repair},
            qr/almanac bug set-status \Q$id1\E --to scheduled --package <blueprint>\/<package> --repair --project "\Q$Pum2\E"/,
            'DC4: UNMIGRATED-BUG repair');
    }

    # A resolvable note: no UNMIGRATED-BUG finding (doctor never writes; the
    # next almanac-bug.pl call migrates it instead).
    write_pkg_ledger($Pum2, 'umbp', '01-um', 'running');
    my $id2 = AlmanacBug::new_id() . '-umbg2';
    $write_taken->(id => $id2, resolution => 'Scheduled as umbp 01-um');

    my $res2 = run_doctor(home => $Hum2, args => [ '--root', $Pum2 ]);
    my @findings2 = parse_findings($res2->{stdout});
    ok(!(grep { $_->{class} eq 'UNMIGRATED-BUG' && $_->{id} eq $id2 } @findings2),
        'DC4: a taken report whose note resolves gets no UNMIGRATED-BUG finding');
    ok((grep { $_->{class} eq 'UNMIGRATED-BUG' && $_->{id} eq $id1 } @findings2),
        'DC4: the unresolvable one is still flagged on this second run (doctor never migrates it away)');
}

# =============================================================================
# AC13 -- UNMIGRATED-TASKLIST: >=1 record in the flat `task` store.
# =============================================================================
{
    my $Hum = mk_root();
    my $Pum = mk_root();
    mk_record(scope => 'project', type => 'task', root => $Pum,
        fields => { title => 'still flat', status => 'pending' }, order => [qw(title status)]);
    mk_record(scope => 'project', type => 'task', root => $Pum,
        fields => { title => 'also flat', status => 'doing' }, order => [qw(title status)]);

    my $res = run_doctor(home => $Hum, args => [ '--root', $Pum ]);
    my @findings = parse_findings($res->{stdout});
    my @um = grep { $_->{class} eq 'UNMIGRATED-TASKLIST' } @findings;
    is(scalar(@um), 1, 'AC13: exactly one UNMIGRATED-TASKLIST finding') or diag($res->{stdout});
    if (@um) {
        is($um[0]{type}, 'task', 'AC13: UNMIGRATED-TASKLIST type is task');
        is($um[0]{id}, '-', 'AC13: UNMIGRATED-TASKLIST id is -');
        like($um[0]{detail}, qr/the flat tasklist holds 2 record\(s\) not yet migrated to threads/, 'AC13: UNMIGRATED-TASKLIST detail names the count');
        like($um[0]{repair}, qr/almanac thread list --root "\Q$Pum\E"/, 'AC13: UNMIGRATED-TASKLIST repair');
    }

    # doctor never migrates: the flat store is untouched by the run.
    require Almanac::Store;
    my $after_store = Almanac::Store->open(scope => 'project', type => 'task', root => $Pum);
    is(scalar(@{ $after_store->ids }), 2, 'AC13: doctor never migrates -- the flat task store still holds both records');
}

# =============================================================================
# AC11 (DC7) -- tamper detection across project todo, global note, a garbage
# seal, and a frozen bug report; an unsealed record is not reported.
# =============================================================================
{
    my $H11 = mk_root();
    my $P11 = mk_root();

    my (undef, $trec) = mk_record(scope => 'project', type => 'todo', root => $P11,
        fields => { title => 'tampered todo', status => 'open' }, order => [qw(title status)]);
    tamper_bytes($trec->{path});
    my $expect_digest_t = sha256_hex(slurp_raw($trec->{path}));

    my (undef, $nrec) = mk_record(scope => 'global', type => 'note', home => $H11,
        fields => { title => 'tampered note', audience => 'internal', target => 'x.md' },
        order => [qw(title audience target)]);
    tamper_bytes($nrec->{path});
    my $expect_digest_n = sha256_hex(slurp_raw($nrec->{path}));

    my (undef, $grec) = mk_record(scope => 'project', type => 'task', root => $P11,
        fields => { title => 'garbage seal', status => 'pending' }, order => [qw(title status)]);
    write_raw("$grec->{path}.seal", "garbage\n");

    # an unsealed record: create it, then remove its .seal.
    my (undef, $urec) = mk_record(scope => 'project', type => 'todo', root => $P11,
        fields => { title => 'unsealed', status => 'open' }, order => [qw(title status)]);
    unlink "$urec->{path}.seal";

    my $res_bf = run_child([ $^X, $BUG_PL, 'file', '--project', $P11, '--title', 'tampered bug',
        '--severity', 'low', '--area', 'sandbox', '--body', 'original body' ],
        env => { ALMANAC_HOME => $H11, HOME => $H11, USERPROFILE => $H11 });
    chomp(my $bug_path = $res_bf->{stdout});
    my ($bug_id) = $bug_path =~ m{/([^/]+)\.md$};
    run_child([ $^X, $BUG_PL, 'set-status', $bug_id, '--project', $P11, '--to', 'dropped',
        '--note', 'dropped for fixture' ],
        env => { ALMANAC_HOME => $H11, HOME => $H11, USERPROFILE => $H11 });
    {
        my $raw = slurp_raw($bug_path);
        $raw =~ s/original body/tampered body/;
        write_raw($bug_path, $raw);
    }

    my $res = run_doctor(home => $H11, args => [ '--root', $P11 ]);
    my @findings = parse_findings($res->{stdout});
    my @tampered = grep { $_->{class} eq 'TAMPERED' } @findings;

    my ($tf) = grep { $_->{path} eq $trec->{path} } @tampered;
    ok(defined $tf, 'AC11: the tampered project todo is reported');
    is($tf->{detail}, "digest $expect_digest_t matches no sealed digest", 'AC11: todo detail names the current digest')
        if $tf;

    my ($nf) = grep { $_->{path} eq $nrec->{path} } @tampered;
    ok(defined $nf, 'AC11: the tampered global note is reported');
    is($nf->{detail}, "digest $expect_digest_n matches no sealed digest", 'AC11: note detail names the current digest')
        if $nf;

    my ($gf) = grep { $_->{path} eq $grec->{path} } @tampered;
    ok(defined $gf, 'AC11: the garbage-seal record is reported');
    is($gf->{detail}, "seal $grec->{path}.seal is not one or two sha256 lines", 'AC11: garbage-seal detail')
        if $gf;

    my ($bf) = grep { $_->{path} eq $bug_path } @tampered;
    ok(defined $bf, 'AC11: the tampered frozen bug report is reported');
    like($bf->{detail}, qr/^body digest [0-9a-f]{64} != recorded [0-9a-f]{64}$/,
        'AC11: bug detail is verify()\'s note minus the leading "TAMPERED: "') if $bf;

    ok(!(grep { $_->{path} eq $urec->{path} } @findings), 'AC11: the unsealed record is NOT reported');
    is($res->{rc}, 1, 'AC11: exit 1');
}

# =============================================================================
# AC12 (DC8) -- a lock held by a LIVE process whose .lock.holder names this
# host and a pid of an already-EXITED process (a REAL spawned-and-reaped
# child, per this batch's hard rule) -> LOCK-HOLDER-GONE; the lock file
# still exists afterwards.
# =============================================================================
{
    my $H12 = mk_root();
    my $P12 = mk_root();
    my (undef, $rec) = mk_record(scope => 'project', type => 'todo', root => $P12,
        fields => { title => 'lock target', status => 'open' }, order => [qw(title status)]);

    my $exited_pid = dead_pid();

    my ($lock, $lock_err) = Almanac::Lock->acquire($rec->{path}, verb => 'test-hold');
    ok(defined $lock, 'AC12 fixture: this process holds the real flock on the record')
        or diag('lock acquire failed: ' . (ref $lock_err eq 'HASH' ? ($lock_err->{kind} // '?') : '?'));

    write_holder_json("$rec->{path}.lock.holder",
        pid => $exited_pid, host => Sys::Hostname::hostname(), script => 'almanac-note.pl',
        verb => 'update', target => $rec->{path}, acquired_at => iso_now(), acquired_at_epoch => time());

    my $res = run_doctor(home => $H12, args => [ '--root', $P12 ]);
    $lock->release if defined $lock;

    my @findings = parse_findings($res->{stdout});
    my @gone = grep { $_->{class} eq 'LOCK-HOLDER-GONE' } @findings;
    is(scalar(@gone), 1, 'AC12: exactly 1 LOCK-HOLDER-GONE line') or diag($res->{stdout});
    if (@gone) {
        my $f = $gone[0];
        like($f->{detail}, qr/^lock held but its recorded holder pid \Q$exited_pid\E \(script almanac-note\.pl, recorded /,
            'AC12: detail names the exited pid and the recorded script');
        is($f->{path}, "$rec->{path}.lock", 'AC12: path is the .lock file');
        like($f->{repair}, qr/^end the process holding \Q$rec->{path}.lock\E open; never delete a lock file$/,
            'AC12: repair says end the process, never delete the lock file');
    }
    ok(-f "$rec->{path}.lock", 'AC12: the lock file still exists on disk afterwards');
    is($res->{rc}, 1, 'AC12: exit 1');
}

# =============================================================================
# AC13 (DC15) -- a REAL child holds a record's lock for 30s with a holder
# record naming ITSELF (still alive); the record is intact. Doctor finishes
# promptly (well under 5s wall), stdout '', stderr names the holder pid.
# =============================================================================
{
    my $H13 = mk_root();
    my $P13 = mk_root();
    my (undef, $rec) = mk_record(scope => 'project', type => 'todo', root => $P13,
        fields => { title => 'live holder', status => 'open' }, order => [qw(title status)]);

    my ($pid, $lockpath, $holderpath) = spawn_holder(target => $rec->{path}, hold_s => 30, with_identity => 1, verb => 'update');
    ok(defined $pid, 'AC13 fixture: the live holder child reported readiness');

    my $t0 = Time::HiRes::time();
    my $res = run_doctor(home => $H13, args => [ '--root', $P13 ]);
    my $elapsed = Time::HiRes::time() - $t0;

    is($res->{stdout}, '', 'AC13: stdout is empty (a live, correctly-identified holder is not a finding)')
        or diag($res->{stdout});
    is($res->{rc}, 0, 'AC13: exit 0');
    ok($elapsed < 5, sprintf('AC13: doctor finishes promptly (%.2fs < 5s) despite the 30s hold', $elapsed));
    like($res->{stderr}, qr/note: LOCK-HELD/, 'AC13: stderr contains "note: LOCK-HELD"');
    like($res->{stderr}, qr/\bpid \Q$pid\E\b/, 'AC13: stderr names the holder\'s real pid');
}

# =============================================================================
# AC14 (DC15, DC7) -- as AC13, but the record was tampered FIRST: exits 1
# under 10s wall, one UNVERIFIED line naming the holder pid and a waited_ms
# in [1500, 5000].
# =============================================================================
{
    my $H14 = mk_root();
    my $P14 = mk_root();
    my (undef, $rec) = mk_record(scope => 'project', type => 'todo', root => $P14,
        fields => { title => 'live holder tampered', status => 'open' }, order => [qw(title status)]);
    tamper_bytes($rec->{path});

    my ($pid, $lockpath, $holderpath) = spawn_holder(target => $rec->{path}, hold_s => 30, with_identity => 1, verb => 'update');
    ok(defined $pid, 'AC14 fixture: the live holder child reported readiness');

    my $t0 = Time::HiRes::time();
    my $res = run_doctor(home => $H14, args => [ '--root', $P14 ]);
    my $elapsed = Time::HiRes::time() - $t0;

    ok($elapsed < 10, sprintf('AC14: doctor finishes under 10s wall (%.2fs)', $elapsed));
    is($res->{rc}, 1, 'AC14: exit 1');
    my @findings = parse_findings($res->{stdout});
    my @unv = grep { $_->{class} eq 'UNVERIFIED' } @findings;
    is(scalar(@unv), 1, 'AC14: exactly one UNVERIFIED line') or diag($res->{stdout});
    if (@unv) {
        my $f = $unv[0];
        like($f->{detail}, qr/\bpid \Q$pid\E\b/, 'AC14: detail names the holder pid');
        like($f->{detail}, qr/waited (\d+)ms/, 'AC14: detail names waited <N>ms');
        my ($w) = $f->{detail} =~ /waited (\d+)ms/;
        ok(defined $w && $w >= 1500 && $w <= 5000, "AC14: waited_ms ($w) is in [1500,5000]");
    }
}

# =============================================================================
# AC15/AC15b/AC15c (DC9, DC13, DC12) -- legacy queues at a registered project
# root, at $HOME and at $HOME/.claude/ccpraxis (the live install), all under
# a FRESH isolated H (never the real ~/.claude/ccpraxis).
# =============================================================================
my ($H15, $P15b_2, $legacy_p2, $legacy_home, $legacy_live);
{
    $H15 = mk_root();
    my $P2 = mk_root();
    write_registry($H15, p2 => $P2);
    $P15b_2 = $P2;

    make_path("$P2/.ccpraxis-local-data/.subagent-guard");
    make_path("$H15/.ccpraxis-local-data/.subagent-guard");
    make_path("$H15/.claude/ccpraxis/.ccpraxis-local-data/.subagent-guard");
    $legacy_p2   = "$P2/.ccpraxis-local-data/.subagent-guard/questions.md";
    $legacy_home = "$H15/.ccpraxis-local-data/.subagent-guard/questions.md";
    $legacy_live = "$H15/.claude/ccpraxis/.ccpraxis-local-data/.subagent-guard/questions.md";
    for my $p ($legacy_p2, $legacy_home, $legacy_live) {
        write_raw($p, "- question one?\n- question two?\n");
    }

    my $res = run_doctor(home => $H15, args => [ '--root', $P2 ]);
    my @findings = parse_findings($res->{stdout});
    my @lq = grep { $_->{class} eq 'LEGACY-QUEUE' } @findings;
    is(scalar(@lq), 3, 'AC15: exactly 3 LEGACY-QUEUE lines') or diag($res->{stdout});

    # Compared in canonical LONG form on both sides (review S1): once doctor
    # goes through Almanac::Store->open (as spec sec 2.2.3 names), its own
    # printed path is Store-canonical (abs_path expands an 8.3 short name
    # and, on this host, tempdir's /tmp-style spelling), which need not be
    # byte-identical to the raw spelling this fixture used to WRITE the file.
    my ($f_p2)   = grep { norm_root($_->{path}) eq norm_root($legacy_p2) } @lq;
    my ($f_home) = grep { norm_root($_->{path}) eq norm_root($legacy_home) } @lq;
    my ($f_live) = grep { norm_root($_->{path}) eq norm_root($legacy_live) } @lq;
    ok(defined $f_p2,   'AC15: the registered project P2 queue is present');
    ok(defined $f_home, 'AC15: the $HOME queue is present');
    ok(defined $f_live, 'AC15: the live-install queue is present');
    is($f_p2->{scope},   'project', 'AC15: P2 is labelled project (it is a scanned project root)') if $f_p2;
    is($f_home->{scope}, 'orphan',  'AC15: $HOME is labelled orphan (H is NOT registered here)') if $f_home;
    is($f_live->{scope}, 'orphan',  'AC15: the live install is labelled orphan') if $f_live;
    for my $f (@lq) {
        my ($dir) = $f->{path} =~ m{^(.*)/\.ccpraxis-local-data/\.subagent-guard/questions\.md$};
        like($f->{repair}, qr/^almanac inbox list --root "\Q$dir\E"$/, "spec 2.7: repair is 'almanac inbox list', names D=$dir exactly");
        is($f->{type}, 'inbox', 'spec 2.7: the LEGACY-QUEUE probe reports type => inbox');
    }

    for my $p ($legacy_p2, $legacy_home, $legacy_live) {
        ok(-f $p, 'AC15: the legacy file is untouched afterwards (still present, still not absorbed)');
        my $body = slurp_raw($p);
        is($body, "- question one?\n- question two?\n", 'AC15: ...and byte-identical to the seed');
        my ($dir) = $p =~ m{^(.*)/\.ccpraxis-local-data/\.subagent-guard/questions\.md$};
        ok(!-d "$dir/.ccpraxis-local-data/almanac/inbox", 'spec 2.7: no inbox store dir was created under this D (the probe never absorbs)');
    }
}
{
    # AC15b: H added to the registry -> H's line is labelled project, exactly once.
    write_registry($H15, p2 => $P15b_2, home => $H15);
    my $res = run_doctor(home => $H15, args => [ '--root', $P15b_2 ]);
    my @findings = parse_findings($res->{stdout});
    my @lq = grep { $_->{class} eq 'LEGACY-QUEUE' } @findings;
    my @home_lines = grep { norm_root($_->{path}) eq norm_root($legacy_home) } @lq;
    is(scalar(@home_lines), 1, 'AC15b: $HOME\'s legacy-queue line appears exactly once');
    is($home_lines[0]{scope}, 'project', 'AC15b: ...and is now labelled project (H is registered)') if @home_lines;
}
{
    # AC15c: running each printed repair through almanac.pl absorbs each
    # queue. Needs the CLI dispatcher, so this half is expected to fail
    # until almanac.pl exists too.
    my $ALMANAC_PL = "$S/almanac.pl";
    my $res0 = run_doctor(home => $H15, args => [ '--root', $P15b_2 ]);
    my @lq0 = grep { $_->{class} eq 'LEGACY-QUEUE' } parse_findings($res0->{stdout});
    is(scalar(@lq0), 3, 'AC15c fixture: 3 LEGACY-QUEUE lines present before repair') or diag($res0->{stdout});

    for my $f (@lq0) {
        my ($dir) = $f->{path} =~ m{^(.*)/\.ccpraxis-local-data/\.subagent-guard/questions\.md$};
        my $res = run_child([ $^X, $ALMANAC_PL, 'inbox', 'list', '--root', $dir ],
            env => { ALMANAC_HOME => $H15, HOME => $H15, USERPROFILE => $H15 });
        is($res->{rc}, 0, "AC15c: running the printed repair for $dir exits 0") or diag($res->{stderr});
        ok(-f "$dir/.ccpraxis-local-data/.subagent-guard/questions.md.migrated",
            "AC15c: ...and questions.md.migrated now exists under $dir");
        my $dstore = eval { Almanac::Store->open(scope => 'project', type => 'inbox', root => $dir) };
        my $list = eval { $dstore->list() } if $dstore;
        is(scalar(@{ (ref $list eq 'ARRAY') ? $list : [] }), 2,
            "AC15c: ...and the inbox store at $dir now holds 2 legacy-* records") if $dstore;
    }
    my $res_after = run_doctor(home => $H15, args => [ '--root', $P15b_2 ]);
    my @lq_after = grep { $_->{class} eq 'LEGACY-QUEUE' } parse_findings($res_after->{stdout});
    is(scalar(@lq_after), 0, 'AC15c: a second doctor run reports no LEGACY-QUEUE line at all') or diag($res_after->{stdout});
}

# =============================================================================
# AC16/AC17 (DC12, DC13) -- the all-findings fixture: every stdout line but
# the last matches the finding regex with the exact repair text; the last
# line is the summary; a byte-for-byte snapshot before/after is identical
# except lock sidecars.
# =============================================================================
my (%ALL_EXPECT, $ALL_HOME, $ALL_P1, $ALL_LOCK_PID);
{
    $ALL_HOME = mk_root();
    $ALL_P1   = mk_root();
    write_registry($ALL_HOME, p1alt => alt_spelling($ALL_P1));

    # F1 x2 (AC7/AC8-flavoured)
    my (undef, $bad_todo) = mk_record(scope => 'project', type => 'todo', root => $ALL_P1,
        fields => { title => 'bad todo' }, order => [qw(title)]);
    corrupt_line($bad_todo->{path}, 3, "not a field\n");
    $ALL_EXPECT{"UNPARSEABLE\x1F" . norm_root($bad_todo->{path})} = {
        detail => 'line 3: bad_field_line',
        repair => 'restore it from the vault history; no almanac verb writes a record that does not parse',
    };

    # F2 (AC11-flavoured): tampered project todo
    my (undef, $tampered_todo) = mk_record(scope => 'project', type => 'todo', root => $ALL_P1,
        fields => { title => 'tampered todo' }, order => [qw(title)]);
    tamper_bytes($tampered_todo->{path});
    my $tt_digest = sha256_hex(slurp_raw($tampered_todo->{path}));
    $ALL_EXPECT{"TAMPERED\x1F" . norm_root($tampered_todo->{path})} = {
        detail => "digest $tt_digest matches no sealed digest",
        repair => 'restore it from the vault history, or accept it by re-saving through its own almanac verb',
    };

    # F4 (AC9-flavoured): dangling project note
    my (undef, $dangling_note) = mk_record(scope => 'project', type => 'note', root => $ALL_P1,
        fields => { title => 'dangling', audience => 'internal', target => 'gone.md' }, order => [qw(title audience target)]);
    $ALL_EXPECT{"DANGLING-POINTER\x1F" . norm_root($dangling_note->{path})} = {
        detail => 'target gone.md resolves to no file',
        repair => qq(almanac note delete $dangling_note->{id} --root "$ALL_P1", or recreate the target file),
    };

    # F5 (AC10-flavoured, OVERRIDDEN by specs/02-thread-store-spec.md section
    # 2.8): dangling THREAD task ref (the flat task store is no longer
    # scanned for DANGLING-REF at all).
    mk_record(scope => 'project', type => 'thread', root => $ALL_P1, id => 'all-thread',
        fields => { created => '2026-01-01T00:00:00Z', state => 'live', owner_kind => 'none', owner_id => '-' },
        order => [qw(created state owner_kind owner_id)]);
    my (undef, $bad_task) = mk_record(scope => 'project', type => 'thread-tasks-all-thread', root => $ALL_P1,
        fields => { title => 'blocked', created => '2026-01-01T00:00:00Z', status => 'pending', blocked_on => 'nosuch-decision' },
        order => [qw(title created status blocked_on)]);
    $ALL_EXPECT{"DANGLING-REF\x1F" . norm_root($ALL_P1)} = {
        detail => 'blocked_on nosuch-decision names no inbox item',
        repair => qq(almanac thread edit all-thread $bad_task->{id} --clear-blocked-on --root "$ALL_P1"),
    };

    # F6 (AC18-flavoured): interrupted reorder journal, still on the flat
    # `task` store (the journal mechanism is generic to Store and is
    # unrelated to migration state). Per spec 2.8 item 5, `task` no longer
    # has a listing verb, so the exact repair text this fixture used to pin
    # ("almanac task list --root ...") can no longer be right; the spec does
    # not state its replacement, so only the negative is asserted here (see
    # the AC18 block below, same reasoning).
    my $tstore = Almanac::Store->open(scope => 'project', type => 'task', root => $ALL_P1);
    make_path($tstore->dir) unless -d $tstore->dir;
    my $journal_path = "@{[$tstore->dir]}/.reorder-journal.json";
    write_raw($journal_path, JSON::PP->new->canonical->encode({
        version => 1, writer => 'fixture', started_at => time(),
        entries => { 'some-task-id' => { prev_rank => undef, next_rank => undef } },
    }));
    $ALL_EXPECT{"INTERRUPTED-REORDER\x1F" . norm_root($journal_path)} = {
        detail => 'an abandoned reorder journal is present',
        repair_not => qq(almanac task list --root "$ALL_P1"),
    };

    # F7 (AC19-flavoured): note id_mismatch. Deliberately in the GLOBAL note
    # store, never the project one -- the project note store already holds
    # the F4 dangling-pointer note above, and check_pointers()'s list() dies
    # on the first malformed record it meets (Decision 4), which would make
    # that whole scope's pointer check unavailable and swallow the F4 finding
    # too (spec section 5's own documented edge case: "records that fail
    # parse make check_pointers/check_refs report reason malformed ...
    # incomplete until the record is restored"). A different scope keeps
    # both findings independently reachable.
    my (undef, $mismatch) = mk_record(scope => 'global', type => 'note', home => $ALL_HOME,
        fields => { title => 'mismatched', audience => 'internal', target => 'z.md' }, order => [qw(title audience target)]);
    {
        my $raw = slurp_raw($mismatch->{path});
        $raw =~ s/^id: \Q$mismatch->{id}\E$/id: some-other-id/m;
        write_raw($mismatch->{path}, $raw);
        reseal($mismatch->{path});
    }
    my $notestore_dir = Almanac::Store->open(scope => 'global', type => 'note', home => $ALL_HOME)->dir;
    $ALL_EXPECT{"CHECK-FAILED\x1F" . norm_root($notestore_dir)} = {
        detail => 'check_pointers unavailable (reason id_mismatch)',
        repair => 'almanac note list --global shows the full error',
    };

    # F8 (AC12-flavoured): lock-holder-gone
    my (undef, $locktarget) = mk_record(scope => 'project', type => 'todo', root => $ALL_P1,
        fields => { title => 'all-lock target' }, order => [qw(title)]);
    my $exited_pid = dead_pid();
    my ($alllock, $alllock_err) = Almanac::Lock->acquire($locktarget->{path}, verb => 'test-hold');
    ok(defined $alllock, 'AC16 fixture: this process holds the flock on the all-findings lock target');
    write_holder_json("$locktarget->{path}.lock.holder",
        pid => $exited_pid, host => Sys::Hostname::hostname(), script => 'almanac-note.pl',
        verb => 'update', target => $locktarget->{path}, acquired_at => iso_now(), acquired_at_epoch => time());
    $ALL_EXPECT{"LOCK-HOLDER-GONE\x1F" . norm_root("$locktarget->{path}.lock")} = {
        detail_re => qr/^lock held but its recorded holder pid \Q$exited_pid\E \(script almanac-note\.pl, recorded /,
        repair => qq(end the process holding $locktarget->{path}.lock open; never delete a lock file),
    };

    # F9 (AC15-flavoured): legacy queue at H, orphan.
    make_path("$ALL_HOME/.ccpraxis-local-data/.subagent-guard");
    my $legacy_all = "$ALL_HOME/.ccpraxis-local-data/.subagent-guard/questions.md";
    write_raw($legacy_all, "- one?\n");
    $ALL_EXPECT{"LEGACY-QUEUE\x1F" . norm_root($legacy_all)} = {
        detail => 'unabsorbed legacy question queue',
        # D (the repair's --root argument) comes from canonical_root(), same
        # as the LEGACY-QUEUE <path> itself (review S1) -- never the raw H.
        repair => qq(almanac inbox list --root "@{[norm_root($ALL_HOME)]}"),
    };

    # Snapshot BEFORE running doctor (excluding names ending .lock/.lock.holder).
    sub snapshot_bytes {
        my ($dir) = @_;
        my %out;
        return \%out unless -d $dir;
        my @stack = ($dir);
        while (my $d = pop @stack) {
            opendir(my $dh, $d) or next;
            for my $e (readdir $dh) {
                next if $e eq '.' || $e eq '..';
                my $full = "$d/$e";
                if (-d $full) { push @stack, $full; next }
                next if $e =~ /\.lock(\.holder)?\z/;
                (my $rel = $full) =~ s{\\}{/}g;
                $out{$rel} = slurp_raw($full);
            }
            closedir $dh;
        }
        return \%out;
    }
    my $before_p1   = snapshot_bytes($ALL_P1);
    my $before_home = snapshot_bytes($ALL_HOME);

    my $t0 = Time::HiRes::time();
    my $res = run_doctor(home => $ALL_HOME, args => [ '--root', $ALL_P1 ]);
    my $elapsed = Time::HiRes::time() - $t0;
    $alllock->release if defined $alllock;

    is($res->{rc}, 1, 'AC16: exit 1 with the all-findings fixture');

    my @lines = split /\n/, $res->{stdout};
    ok(@lines >= 1, 'AC16: at least one stdout line') or diag('empty stdout');
    my $summary = pop @lines;
    like($summary, qr/^almanac doctor: (\d+) finding\(s\); nothing was changed$/,
        'AC16: the last line is the summary line');
    my ($k) = $summary =~ /^almanac doctor: (\d+) finding/;
    is(scalar(@lines), $k, 'AC16: K equals the number of finding lines that precede it');

    my $bad_count = 0;
    for my $line (@lines) {
        unless ($line =~ $FINDING_RE) { $bad_count++; diag("AC16: line does not match the finding regex: $line"); next }
        my ($class, undef, undef, undef, $detail, $path, $repair) = ($1, $2, $3, $4, $5, $6, $7);
        my $key = "$class\x1F" . norm_root($path);
        my $exp = $ALL_EXPECT{$key};
        unless ($exp) { diag("AC16: unexpected finding, not registered by this fixture: $line"); next }
        if ($exp->{detail_re}) { like($detail, $exp->{detail_re}, "AC16: $class detail matches for $path") }
        else                    { is($detail, $exp->{detail}, "AC16: $class detail matches for $path") }
        if (exists $exp->{repair_not}) {
            isnt($repair, $exp->{repair_not}, "AC16/spec 2.8: $class repair is no longer the retired-verb text for $path");
        } else {
            is($repair, $exp->{repair}, "AC16: $class repair matches the section 2.2.4 table for $path");
        }
        delete $ALL_EXPECT{$key};
    }
    is($bad_count, 0, 'AC16: every stdout line except the last matches the finding regex');
    is(scalar(keys %ALL_EXPECT), 0, 'AC16: every registered expected finding was actually present')
        or diag('missing: ' . join(', ', keys %ALL_EXPECT));

    my $after_p1   = snapshot_bytes($ALL_P1);
    my $after_home = snapshot_bytes($ALL_HOME);
    is_deeply($after_p1, $before_p1, 'AC17: P1\'s non-lock file bytes are unchanged by doctor');
    is_deeply($after_home, $before_home, 'AC17: H\'s non-lock file bytes are unchanged by doctor');
}

# =============================================================================
# M1 regression (review report specs/../reports/17-review.md, MUST-FIX) --
# the DANGLING-POINTER and DANGLING-REF repair lines must print a non-ASCII
# project root BYTE-EXACT as UTF-8, never mojibake (the root re-encoded as if
# its already-decoded characters were Latin-1 -- "AndrÃ©" instead of
# "André"), and the printed repair command must actually FIND THE STORE when
# run for real. mk_root() alone cannot see this bug: tempdir's 8.3 short form
# is pure ASCII (ANDR~1), so this fixture builds its OWN "André" path segment
# rather than depending on the real user profile name.
# =============================================================================
{
    my $ALMANAC_PL = "$S/almanac.pl";
    my $M1_BASE     = mk_root();
    my $M1_ROOT_RAW = "$M1_BASE/André/proj";
    make_path($M1_ROOT_RAW);
    ok(-d $M1_ROOT_RAW, 'M1 fixture: the non-ASCII "André" project directory was actually created on disk')
        or diag("could not create $M1_ROOT_RAW: $!");
    my $M1_HOME = mk_root();
    # Per spec sec 2.2.2(1), the scanned project root IS the --root value as
    # given (never canonicalised for THIS purpose) -- doctor's F4/F5 <path>
    # field is literally "project root P", so the byte-exact comparison
    # below is against the RAW value this fixture passed on argv, not a
    # Store-canonicalised form (that distinction is what LEGACY-QUEUE's own
    # D, sourced from canonical_root(), does differently -- see AC15/S1).
    my $M1_ROOT = $M1_ROOT_RAW;

    my (undef, $dnote) = mk_record(scope => 'project', type => 'note', root => $M1_ROOT_RAW,
        fields => { title => 'm1 dangling', audience => 'internal', target => 'gone.md' },
        order => [qw(title audience target)]);
    # where-things-go package 02-thread-store (specs/02-thread-store-spec.md
    # 2.8): DANGLING-REF no longer scans the flat `task` store at all (see
    # AC10/AC13/AC18 above, already pinning that behaviour) -- a dangling
    # blocked_on now has to live on a THREAD task to produce a DANGLING-REF
    # finding, so this fixture builds one directly (mirroring AC10's
    # pattern) purely to keep exercising M1's actual regression: byte-exact
    # non-ASCII encoding of the repair line, for whichever finding kind can
    # still carry one.
    mk_record(scope => 'project', type => 'thread', root => $M1_ROOT_RAW, id => 'm1-thread',
        fields => { created => '2026-01-01T00:00:00Z', state => 'live', owner_kind => 'none', owner_id => '-' },
        order => [qw(created state owner_kind owner_id)]);
    my (undef, $dtask) = mk_record(scope => 'project', type => 'thread-tasks-m1-thread', root => $M1_ROOT_RAW,
        fields => { title => 'm1 blocked', created => '2026-01-01T00:00:00Z', status => 'pending', blocked_on => 'nosuch-decision' },
        order => [qw(title created status blocked_on)]);

    my $res = run_doctor(home => $M1_HOME, args => [ '--root', $M1_ROOT_RAW ]);
    my @findings = parse_findings($res->{stdout});

    my ($pf) = grep { $_->{class} eq 'DANGLING-POINTER' } @findings;
    my ($rf) = grep { $_->{class} eq 'DANGLING-REF' } @findings;
    ok(defined $pf, 'M1: the non-ASCII-root project produced a DANGLING-POINTER finding') or diag($res->{stdout});
    ok(defined $rf, 'M1: ...and a DANGLING-REF finding') or diag($res->{stdout});

    if ($pf) {
        ok(index($pf->{repair}, $M1_ROOT) >= 0,
            'M1: the DANGLING-POINTER repair line contains the non-ASCII root BYTE-EXACT (never double-encoded)')
            or diag("repair: $pf->{repair}\nexpected substring (bytes): $M1_ROOT");
        unlike($pf->{repair}, qr/Ã/, 'M1: ...and never shows the mojibake "Ã" byte sequence (double-encoded UTF-8)');
    } else {
        fail('M1: the DANGLING-POINTER repair line contains the non-ASCII root BYTE-EXACT (never double-encoded)');
        fail('M1: ...and never shows the mojibake "Ã" byte sequence (double-encoded UTF-8)');
    }
    if ($rf) {
        ok(index($rf->{repair}, $M1_ROOT) >= 0,
            'M1: the DANGLING-REF repair line contains the non-ASCII root BYTE-EXACT (never double-encoded)')
            or diag("repair: $rf->{repair}\nexpected substring (bytes): $M1_ROOT");
        unlike($rf->{repair}, qr/Ã/, 'M1: ...and never shows the mojibake "Ã" byte sequence (double-encoded UTF-8)');
    } else {
        fail('M1: the DANGLING-REF repair line contains the non-ASCII root BYTE-EXACT (never double-encoded)');
        fail('M1: ...and never shows the mojibake "Ã" byte sequence (double-encoded UTF-8)');
    }

    # "the printed repair command, when run, finds the store" -- parse the
    # verb/args OUT of the repair text (never through a shell: a real argv
    # list) and run it for real through almanac.pl.
    if ($pf && $pf->{repair} =~ /^almanac note delete (\S+) --root "(.+)", or recreate the target file$/) {
        my ($id, $root_arg) = ($1, $2);
        my $del_res = run_child([ $^X, $ALMANAC_PL, 'note', 'delete', $id, '--root', $root_arg ],
            env => { ALMANAC_HOME => $M1_HOME, HOME => $M1_HOME, USERPROFILE => $M1_HOME });
        is($del_res->{rc}, 0,
            'M1: running the printed DANGLING-POINTER repair verbatim (byte-exact argv) finds the store and succeeds')
            or diag("rc=$del_res->{rc} out=$del_res->{stdout} err=$del_res->{stderr}");
    } else {
        fail('M1: running the printed DANGLING-POINTER repair verbatim (byte-exact argv) finds the store and succeeds');
    }
    if ($rf && $rf->{repair} =~ /^almanac thread edit m1-thread (\S+) --clear-blocked-on --root "(.+)"$/) {
        my ($id, $root_arg) = ($1, $2);
        # blueprint where-things-go package 03-thread-sessions (Decision 18
        # F6/F7): 'thread edit' is now a hard-gated write verb -- running
        # this doctor-printed repair verbatim needs a ticket minted for the
        # EXACT argv almanac-thread.pl will see (the type word 'thread' is
        # stripped by almanac.pl's dispatch, so the ticket's argv starts at
        # 'edit'), under its OWN pinned BUTLER_STATE_DIR (this file never
        # otherwise sets one, so leaving it ambient would reach the
        # operator's real butler state -- exactly what this session's
        # earlier unpinned CLI probing already corrupted twice).
        my $m1_bsd = mk_root();
        require "$S/../../butler/scripts/BpHook.pm" unless grep { m{(?:^|/)BpHook\.pm$} } keys %INC;
        {
            local $ENV{BUTLER_STATE_DIR} = $m1_bsd;
            BpHook::write_ticket(
                { session_id => 'M1-SESSION', tool_use_id => 'M1T1',
                  transcript_path => undef, cwd => '/fixture' },
                'almanac-thread', [ 'edit', 'm1-thread', $id, '--clear-blocked-on', '--root', $root_arg ]);
        }
        my $edit_res = run_child([ $^X, $ALMANAC_PL, 'thread', 'edit', 'm1-thread', $id, '--clear-blocked-on', '--root', $root_arg ],
            env => { ALMANAC_HOME => $M1_HOME, HOME => $M1_HOME, USERPROFILE => $M1_HOME, BUTLER_STATE_DIR => $m1_bsd });
        is($edit_res->{rc}, 0,
            'M1: running the printed DANGLING-REF repair verbatim (byte-exact argv) finds the store and succeeds')
            or diag("rc=$edit_res->{rc} out=$edit_res->{stdout} err=$edit_res->{stderr}");
    } else {
        fail('M1: running the printed DANGLING-REF repair verbatim (byte-exact argv) finds the store and succeeds');
    }
}

# =============================================================================
# S3 regression (review report, SHOULD-FIX) -- a lock error that is NOT a
# timeout (Almanac::Lock->acquire returning kind => 'io', e.g. the Decision 7
# read-only-vault path) must be reported honestly, never misreported as F3
# "record lock held by an unknown holder; waited 0ms" -- a repair that can
# never succeed. Forced deterministically and portably: a DIRECTORY sits at
# the exact `<record>.lock` path, so acquire()'s own `open($fh, '>',
# $lock_path)` fails immediately with a real, non-timeout `kind => 'io'`
# error -- no timing race, no platform-specific permission bits required.
# =============================================================================
{
    my $H_S3 = mk_root();
    my $P_S3 = mk_root();
    my (undef, $rec) = mk_record(scope => 'project', type => 'todo', root => $P_S3,
        fields => { title => 's3 io lock error' }, order => [qw(title)]);
    tamper_bytes($rec->{path});
    my $expect_digest = sha256_hex(slurp_raw($rec->{path}));

    # create()'s own Almanac::Lock->acquire already left an empty <path>.lock
    # FILE behind (release() removes nothing, spec sec "Almanac::Lock"). It
    # must be removed before a DIRECTORY can occupy that exact name.
    unlink "$rec->{path}.lock";
    make_path("$rec->{path}.lock");
    ok(-d "$rec->{path}.lock", 'S3 fixture: a directory occupies the exact .lock path (forces a non-timeout io error)');

    my $res = run_doctor(home => $H_S3, args => [ '--root', $P_S3 ]);
    my @findings = parse_findings($res->{stdout});

    unlike($res->{stdout}, qr/unknown holder/,
        'S3: a non-timeout lock error is never reported as "held by an unknown holder"');
    ok(!(grep { $_->{class} eq 'UNVERIFIED' && $_->{path} eq $rec->{path} } @findings),
        'S3: the record does not get a fabricated UNVERIFIED finding from the io error');
    my ($tf) = grep { $_->{class} eq 'TAMPERED' && $_->{path} eq $rec->{path} } @findings;
    ok(defined $tf, 'S3: the unlocked check_seal state (tampered) is kept and reported instead') or diag($res->{stdout});
    is($tf->{detail}, "digest $expect_digest matches no sealed digest", 'S3: ...with its real digest, unaffected by the lock error')
        if $tf;

    rmdir("$rec->{path}.lock");
}

# =============================================================================
# AC18 (DC13) -- covered as part of the F6/AC16 fixture above; an additional,
# isolated assertion that the journal and task records survive untouched and
# DANGLING-REF checks for P1 still run alongside it.
# =============================================================================
{
    my $H18 = mk_root();
    my $P18 = mk_root();
    my (undef, $task1) = mk_record(scope => 'project', type => 'task', root => $P18,
        fields => { title => 't1', status => 'pending', blocked_on => 'nosuch' }, order => [qw(title status blocked_on)]);
    my $tstore = Almanac::Store->open(scope => 'project', type => 'task', root => $P18);
    my $journal_path = "@{[$tstore->dir]}/.reorder-journal.json";
    my $journal_bytes = JSON::PP->new->canonical->encode({
        version => 1, writer => 'fixture', started_at => time(),
        entries => { $task1->{id} => { prev_rank => undef, next_rank => undef } },
    });
    write_raw($journal_path, $journal_bytes);
    my $task_bytes_before = slurp_raw($task1->{path});

    my $res = run_doctor(home => $H18, args => [ '--root', $P18 ]);
    my @findings = parse_findings($res->{stdout});
    my @reorder = grep { $_->{class} eq 'INTERRUPTED-REORDER' } @findings;
    is(scalar(@reorder), 1, 'AC18: exactly one INTERRUPTED-REORDER line') or diag($res->{stdout});
    if (@reorder) {
        is($reorder[0]{id}, '-', 'AC18: id is "-"');
        is($reorder[0]{type}, 'task', 'AC18: type is task');
        # spec 2.8 item 5: task no longer has a listing verb, so the old
        # "almanac task list --root ..." repair text can no longer be right;
        # the spec does not pin its replacement, so only the negative holds.
        isnt($reorder[0]{repair}, qq(almanac task list --root "$P18"),
            'AC18/spec 2.8: repair is no longer the retired "almanac task list" text');
    }
    ok(-f $journal_path, 'AC18: the journal still exists after doctor');
    is(slurp_raw($journal_path), $journal_bytes, 'AC18: ...byte-identical');
    is(slurp_raw($task1->{path}), $task_bytes_before, 'AC18: the task record bytes are unchanged');

    # spec 2.8: DANGLING-REF no longer scans the flat task store at all, so
    # this fixture's flat blocked_on no longer produces one.
    my @dref = grep { $_->{class} eq 'DANGLING-REF' } @findings;
    is(scalar(@dref), 0, 'AC18/spec 2.8: no DANGLING-REF from a flat-task-store blocked_on (not scanned any more)');
}

# =============================================================================
# AC19 (DC12) -- isolated: a note record whose frontmatter id does not match
# its filename -> one CHECK-FAILED line.
# =============================================================================
{
    my $H19 = mk_root();
    my $P19 = mk_root();
    my (undef, $rec) = mk_record(scope => 'project', type => 'note', root => $P19,
        fields => { title => 'mismatch', audience => 'internal', target => 'z.md' }, order => [qw(title audience target)]);
    {
        my $raw = slurp_raw($rec->{path});
        $raw =~ s/^id: \Q$rec->{id}\E$/id: some-other-id/m;
        write_raw($rec->{path}, $raw);
        reseal($rec->{path});
    }
    my $res = run_doctor(home => $H19, args => [ '--root', $P19 ]);
    my @findings = parse_findings($res->{stdout});
    my @cf = grep { $_->{class} eq 'CHECK-FAILED' } @findings;
    is(scalar(@cf), 1, 'AC19: exactly one CHECK-FAILED line') or diag($res->{stdout});
    if (@cf) {
        is($cf[0]{scope}, 'project', 'AC19: scope is project');
        is($cf[0]{type}, 'note', 'AC19: type is note');
        is($cf[0]{id}, '-', 'AC19: id is "-"');
        is($cf[0]{detail}, 'check_pointers unavailable (reason id_mismatch)', 'AC19: exact detail text');
    }
}

# =============================================================================
# AC20 (DC10, DC11) -- exit codes: clean 0; any finding 1; --bogus, a bare
# --root, and a positional each 2 with the usage line on stderr, empty stdout.
# =============================================================================
{
    my $H20 = mk_root();
    my $P20 = mk_root();
    my $res_clean = run_doctor(home => $H20, args => [ '--root', $P20 ]);
    is($res_clean->{rc}, 0, 'AC20: a clean tree exits 0');

    my (undef, $rec) = mk_record(scope => 'project', type => 'note', root => $P20,
        fields => { title => 'dangling', audience => 'internal', target => 'gone.md' }, order => [qw(title audience target)]);
    my $res_finding = run_doctor(home => $H20, args => [ '--root', $P20 ]);
    is($res_finding->{rc}, 1, 'AC20: any finding exits 1');

    my $USAGE = 'almanac doctor: usage: almanac doctor [--root DIR]';
    for my $case (
        [ 'bogus flag',  [ '--bogus' ] ],
        [ 'bare --root', [ '--root' ] ],
        [ 'positional',  [ 'extra-positional' ] ],
    ) {
        my ($label, $args) = @$case;
        my $res = run_doctor(home => $H20, args => $args);
        is($res->{rc}, 2, "AC20: $label exits 2");
        is($res->{stdout}, '', "AC20: $label -- stdout empty");
        like($res->{stderr}, qr/\Q$USAGE\E/, "AC20: $label -- stderr has the usage line");
    }
}

# =============================================================================
# AC21 (DC14, DC13) -- static source properties of almanac-doctor.pl / almanac.pl.
# =============================================================================
{
    my $ALMANAC_PL = "$S/almanac.pl";
    if (-f $DOCTOR_PL) {
        my $src = slurp_raw($DOCTOR_PL) // '';
        my @nc_lines = grep { $_ !~ /^\s*#/ } split /\n/, $src;
        my $nc = join("\n", @nc_lines);
        for my $forbidden (qw{--- Digest:: sha256_hex JSON::PP questions.md subagent-guard
                               Almanac::Inbox open_inbox migrate_legacy_store absorb( ->create( ->update(
                               ->delete( ->reorder( ->insert_ ->recover( unlink rename
                               write_atomic make_path mkdir alarm}) {
            unlike($nc, qr/\Q$forbidden\E/, "AC21: almanac-doctor.pl (comments stripped) never contains '$forbidden'");
        }
        # The raw file `open(`/`open (` call (the lock probe) -- never a
        # `->open(` METHOD call on Almanac::Store, of which the doctor
        # legitimately makes several (one per scope/type it scans).
        my @opens = ($nc =~ /(?<!->)\bopen\s*\(/g);
        is(scalar(@opens), 1, 'AC21: exactly one raw open(/open ( call in almanac-doctor.pl (excluding ->open( method calls)');
        my @open_lines = grep { /(?<!->)\bopen\s*\(/ } @nc_lines;
        like($open_lines[0] // '', qr/'>>'/, 'AC21: ...and its mode is \'>>\'') if @open_lines;
        my @lockex_lines = grep { /LOCK_EX/ } @nc_lines;
        my @bad_lockex = grep { !/LOCK_NB/ } @lockex_lines;
        is(scalar(@bad_lockex), 0, 'AC21: every flock( call naming LOCK_EX also names LOCK_NB')
            or diag(join("\n", @bad_lockex));
        my @acquire = ($nc =~ /Almanac::Lock->acquire/g);
        is(scalar(@acquire), 1, 'AC21: exactly one Almanac::Lock->acquire in almanac-doctor.pl');
        ok($nc =~ /Almanac::Lock->acquire\([^)]*timeout_ms/s, 'AC21: the acquire( call passes timeout_ms');
        for my $spawn_kw (qw(system exec qx)) {
            unlike($nc, qr/\b\Q$spawn_kw\E\b/, "AC21: almanac-doctor.pl never uses $spawn_kw");
        }
        ok(index($nc, '`') < 0, 'AC21: almanac-doctor.pl never uses backticks');
        ok(index($nc, '|-') < 0 && index($nc, '-|') < 0, 'AC21: almanac-doctor.pl never uses a pipe-open');
    } else {
        fail('AC21: almanac-doctor.pl must exist to be scanned');
    }
    if (-f $ALMANAC_PL) {
        my $src = slurp_raw($ALMANAC_PL) // '';
        my @nc_lines = grep { $_ !~ /^\s*#/ } split /\n/, $src;
        my @systems = grep { /\bsystem\b/ } @nc_lines;
        is(scalar(@systems), 1, 'AC21: almanac.pl contains exactly one system call');
        ok(!(grep { /\bexec\b/ } @nc_lines), 'AC21: almanac.pl contains no exec call');
    } else {
        fail('AC21: almanac.pl must exist to be scanned');
    }
}

# =============================================================================
# AC22 (DC14) -- almanac-doctor.pl names each of the read functions, and
# localizes SCOPE_POLICY.
# =============================================================================
{
    if (-f $DOCTOR_PL) {
        my $src = slurp_raw($DOCTOR_PL) // '';
        for my $needle (qw(Almanac::Record::check_file Almanac::Store::record_files_in
                            Almanac::Store::check_seal Almanac::Note::check_pointers
                            Almanac::Task::check_refs AlmanacBug::verify
                            Almanac::Lock::read_holder Almanac::LegacyQueue::legacy_path)) {
            ok(index($src, $needle) >= 0, "AC22: almanac-doctor.pl contains '$needle'");
        }
        ok($src =~ /\blocal\b[^;]*SCOPE_POLICY/s, 'AC22: SCOPE_POLICY appears inside a `local`');
    } else {
        fail("AC22: almanac-doctor.pl must exist to be scanned");
    }
}

# =============================================================================
# AC23 (DC16) -- Decision 37(3) parser uniqueness. Purely static; does not
# depend on almanac.pl/almanac-doctor.pl existing.
# =============================================================================
{
    my @files;
    my $SCRIPTS_DIR = $S;
    my $HOOKS_DIR   = "$S/../hooks";
    for my $dir ($SCRIPTS_DIR, $HOOKS_DIR) {
        next unless -d $dir;
        opendir(my $dh, $dir) or next;
        for my $e (sort readdir $dh) {
            next if $e eq '.' || $e eq '..';
            next unless $e =~ /\.(pl|pm|sh)\z/;
            push @files, "$dir/$e";
        }
        closedir $dh;
        opendir(my $dh2, $dir) or next;
        for my $e (sort readdir $dh2) {
            next if $e =~ /^\./;
            my $sub = "$dir/$e";
            next unless -d $sub;
            opendir(my $sdh, $sub) or next;
            for my $f (sort readdir $sdh) {
                next unless $f =~ /\.(pl|pm|sh)\z/;
                push @files, "$sub/$f";
            }
            closedir $sdh;
        }
        closedir $dh2;
    }
    my %found;
    for my $f (@files) {
        my $src = slurp_raw($f) // '';
        my @lines = split /\n/, $src;
        for my $line (@lines) {
            next if $line =~ /^\s*#/;
            if ($line =~ /\\A---|\^---|\beq\s*['"]---['"]/) { $found{$f} = 1; last }
        }
    }
    my %basename_of = map { $_ => (File::Basename::basename($_)) } keys %found;
    my @found_basenames = sort values %basename_of;
    my @expect = sort qw(Record.pm almanac-bug.pl almanac-migrate-todos.pl almanac-migrate-memories.pl gen-statusline-counters.pl);
    is_deeply(\@found_basenames, \@expect,
        'AC23: the parser-uniqueness set is exactly {Record.pm, almanac-bug.pl, almanac-migrate-todos.pl, almanac-migrate-memories.pl, gen-statusline-counters.pl} (Decision 38)')
        or diag('found: ' . join(', ', @found_basenames));
}
use File::Basename ();

# =============================================================================
# AC24 (performance) -- 300 sealed records in P1: doctor exits 0, empty
# stdout, within a 20s timeout.
# =============================================================================
{
    my $H24 = mk_root();
    my $P24 = mk_root();
    my @decisions;
    for my $i (1 .. 20) {
        my (undef, $d) = mk_record(scope => 'project', type => 'inbox', root => $P24,
            fields => { title => "inbox item $i", status => 'unanswered' }, order => [qw(title status)]);
        push @decisions, $d;
    }
    for my $i (1 .. 100) {
        mk_record(scope => 'project', type => 'todo', root => $P24,
            fields => { title => "todo $i", status => 'open' }, order => [qw(title status)]);
    }
    for my $i (1 .. 50) {
        mk_record(scope => 'project', type => 'note', root => $P24,
            fields => { title => "note $i", audience => 'internal', target => "n$i.md" }, order => [qw(title audience target)]);
        write_raw("$P24/n$i.md", "target\n");
    }
    for my $i (1 .. 50) {
        mk_record(scope => 'global', type => 'note', home => $H24,
            fields => { title => "gnote $i", audience => 'internal', target => "gn$i.md" }, order => [qw(title audience target)]);
        write_raw("$H24/.claude/claude-code-vault/gn$i.md", "target\n");
    }
    for my $i (1 .. 20) {
        mk_record(scope => 'project', type => 'task', root => $P24,
            fields => { title => "blocked task $i", status => 'pending', blocked_on => $decisions[$i - 1]{id} },
            order => [qw(title status blocked_on)]);
    }
    for my $i (1 .. 60) {
        mk_record(scope => 'project', type => 'task', root => $P24,
            fields => { title => "task $i", status => 'pending' }, order => [qw(title status)]);
    }

    my $t0 = Time::HiRes::time();
    my $res = run_doctor(home => $H24, args => [ '--root', $P24 ]);
    my $elapsed = Time::HiRes::time() - $t0;
    diag(sprintf('AC24: doctor over 300 records took %.2fs wall', $elapsed));
    ok($elapsed < 20, sprintf('AC24: doctor completes within a 20s timeout (%.2fs)', $elapsed));
    # where-things-go package 02-thread-store (specs/02-thread-store-spec.md
    # 2.8, finding 13): this fixture seeds 80 records (20 blocked + 60 plain)
    # straight into the flat `task` Store, which now unconditionally fires
    # one UNMIGRATED-TASKLIST finding -- "clean" here means clean of every
    # OTHER finding kind (the 20 blocked_on records are no longer scanned for
    # DANGLING-REF at all; see AC13/AC18 above, already pinning that).
    my @ac24_findings = parse_findings($res->{stdout});
    is(scalar(@ac24_findings), 1, 'AC24: exactly 1 finding total') or diag($res->{stdout});
    my ($ac24_um) = grep { $_->{class} eq 'UNMIGRATED-TASKLIST' } @ac24_findings;
    ok(defined $ac24_um, 'AC24: the one finding is UNMIGRATED-TASKLIST') or diag($res->{stdout});
    if ($ac24_um) {
        is($ac24_um->{scope}, 'project', 'AC24: UNMIGRATED-TASKLIST scope is project');
        is($ac24_um->{type}, 'task', 'AC24: UNMIGRATED-TASKLIST type is task');
        like($ac24_um->{detail}, qr/the flat tasklist holds 80 record\(s\) not yet migrated to threads/,
            'AC24: UNMIGRATED-TASKLIST detail names the count (80 = 20 blocked + 60 plain)');
    } else {
        fail('AC24: UNMIGRATED-TASKLIST scope is project');
        fail('AC24: UNMIGRATED-TASKLIST type is task');
        fail('AC24: UNMIGRATED-TASKLIST detail names the count (80 = 20 blocked + 60 plain)');
    }
    is($res->{rc}, 1, 'AC24: exit 1 (UNMIGRATED-TASKLIST only)');
}

# =============================================================================
# AC25 (DC3) -- ALMANAC_SURFACE=container: global stores are neither scanned
# nor reported; project findings still are.
# =============================================================================
{
    my $H25 = mk_root();
    my $P25 = mk_root();
    my (undef, $gnote) = mk_record(scope => 'global', type => 'note', home => $H25,
        fields => { title => 'container global', audience => 'internal', target => 'x.md' }, order => [qw(title audience target)]);
    tamper_bytes($gnote->{path});
    my (undef, $pnote) = mk_record(scope => 'project', type => 'note', root => $P25,
        fields => { title => 'container project', audience => 'internal', target => 'gone.md' }, order => [qw(title audience target)]);

    my $res = run_doctor(home => $H25, args => [ '--root', $P25 ], surface => 'container');
    my @findings = parse_findings($res->{stdout});
    ok(!(grep { $_->{path} eq $gnote->{path} } @findings), 'AC25: the global tampered note is NOT reported under container surface');
    my ($pf) = grep { $_->{path} eq $pnote->{path} } @findings;
    ok(defined $pf, 'AC25: the project dangling pointer IS reported under container surface');
    is($res->{stderr}, '', 'AC25: no stderr (global is skipped silently, not noted)');
    is($res->{rc}, 1, 'AC25: exit 1');
}

# =============================================================================
# AC26 (DC11) -- running doctor twice on the all-findings fixture gives
# identical stdout; P1 under both registry spellings yields no duplicates.
# =============================================================================
{
    my $res1 = run_doctor(home => $ALL_HOME, args => [ '--root', $ALL_P1 ]);
    my $res2 = run_doctor(home => $ALL_HOME, args => [ '--root', $ALL_P1 ]);
    is($res2->{stdout}, $res1->{stdout}, 'AC26: running doctor twice on the same fixture gives identical stdout');

    my @findings = parse_findings($res1->{stdout});
    my %by_key;
    $by_key{"$_->{class}\x1F$_->{path}"}++ for @findings;
    my @dups = grep { $by_key{$_} > 1 } keys %by_key;
    is(scalar(@dups), 0, 'AC26: no (class,path) pair appears more than once -- P1 under both registry spellings is deduped')
        or diag(join(', ', @dups));
}

# =============================================================================
# AC28 (D37-4) -- almanac-doctor.pl.about satisfies the same section 2.3
# rules as AC27.
# =============================================================================
{
    ok(-f $DOCTOR_ABOUT, 'AC28: plugins/almanac/scripts/almanac-doctor.pl.about exists')
        or diag("missing: $DOCTOR_ABOUT");
    if (-f $DOCTOR_ABOUT) {
        my $bytes = slurp_raw($DOCTOR_ABOUT) // '';
        require Encode;
        my $decoded = eval { Encode::decode('UTF-8', $bytes, Encode::FB_CROAK() | Encode::LEAVE_SRC()) };
        ok(!$@, 'AC28: almanac-doctor.pl.about is valid UTF-8') or diag("decode error: $@");
        my @nl = ($bytes =~ /\n/g);
        is(scalar(@nl), 1, 'AC28: exactly one \n');
        ok($bytes =~ /\n\z/, 'AC28: ...and it is the last byte') if @nl == 1;
        (my $content = $bytes) =~ s/\n\z//;
        unlike($content, qr/\r/, 'AC28: no \r');
        unlike($content, qr/\t/, 'AC28: no tab');
        unlike($content, qr/^\s/, 'AC28: no leading whitespace');
        unlike($content, qr/\s$/, 'AC28: no trailing whitespace');
        ok(length($content) >= 1 && length($content) <= 120, 'AC28: 1 to 120 characters (got ' . length($content) . ')');
        unlike($content, qr/questions\.md/, 'AC28: never contains the literal "questions.md"');
    } else {
        fail($_) for ('AC28: almanac-doctor.pl.about is valid UTF-8', 'AC28: exactly one \n', 'AC28: 1 to 120 characters');
    }

    # Package 18's sidecar check: no stray .about names a script that does
    # not exist, among the two this package added.
    for my $about ("$S/almanac.pl.about", $DOCTOR_ABOUT) {
        if (-f $about) {
            (my $script = $about) =~ s/\.about\z//;
            ok(-f $script, "AC28: $about names a script that exists ($script)");
        }
    }
}

# =============================================================================
# NEW (blueprint where-things-go, package 03-thread-sessions, specs/
# 03-thread-sessions-spec.md section 2.12): almanac-doctor.pl warns on
# STDERR, once, when butler is not installed beside almanac -- never a
# finding (exit code unaffected). Almanac::SessionLive.pm does not exist yet,
# so every assertion in this block is expected to fail for exactly that
# reason until package 03 lands.
# =============================================================================
{
    # Negative case: in THIS repo's real layout, butler IS a sibling of
    # almanac -- doctor must print no such warning.
    my $r = run_doctor(args => ['--root', mk_root()]);
    unlike($r->{stderr}, qr/butler is not installed beside almanac/,
        'package 03 AC12: with butler present (this repo\'s real layout), doctor prints no absent-butler warning');
}
{
    # Positive case: a copy of plugins/almanac with no butler/ sibling.
    my $copyroot = tempdir(CLEANUP => 1); $copyroot =~ s{\\}{/}g;
    (my $src_abs = abs_path("$S/..")) =~ s{\\}{/}g; # plugins/almanac
    my $dest = "$copyroot/plugins/almanac";
    make_path($dest);
    my @files;
    require File::Find;
    File::Find::find(sub { push @files, $File::Find::name if -f $_ }, $src_abs);
    for my $f (@files) {
        (my $norm = $f) =~ s{\\}{/}g;
        (my $rel = $norm) =~ s/\A\Q$src_abs\E//;
        next if $rel =~ m{^/tests/};
        my $destf = "$dest$rel";
        make_path(File::Basename::dirname($destf));
        require File::Copy;
        File::Copy::copy($f, $destf);
    }
    ok(!-d "$copyroot/plugins/butler", 'package 03 AC12 fixture: no butler/ sibling exists beside the copy');
    SKIP: {
        skip 'package 03 AC12: copy of almanac-doctor.pl missing', 2
            unless -f "$dest/scripts/almanac-doctor.pl";
        my $ROOT = mk_root();
        my $res = run_child([ $^X, "$dest/scripts/almanac-doctor.pl", '--root', $ROOT ],
            env => { ALMANAC_HOME => $ROOT, HOME => $ROOT, USERPROFILE => $ROOT });
        like($res->{stderr},
            qr/almanac doctor: warning: butler is not installed beside almanac \(.*BpHook\.pm not found\); thread writes are not gated against subagents/,
            'package 03 AC12: the copied almanac-doctor.pl prints the exact 2.12 warning text') or diag($res->{stderr});
    }
}

# =============================================================================
# REGRESSION (blueprint tooling-backlog, package 13-almanac-decision-
# relative-path; almanac bug 20261001-184636-75fe; no architect spec --
# Decision 65, mechanical fix): almanac-doctor.pl, almanac-bug.pl,
# almanac-migrate-todos.pl and almanac-migrate-memories.pl, invoked by their
# everyday RELATIVE path from the repo root (the bug report's exact repro
# style: `perl plugins/almanac/scripts/<name>.pl ...`), must never fail with
# perl's "Can't locate ... in @INC". almanac-doctor.pl's BEGIN block derives
# $NOTE_PL/$BUG_PL as "$DIR/almanac-note.pl"/"$DIR/almanac-bug.pl" from
# (possibly relative) __FILE__ and `require`s both (almanac-doctor.pl:30-39,
# 46-50) -- the exact doubled-join defect the bug report describes for
# almanac-decision.pl's sibling require, so this is the PRIMARY failing
# assertion in this file before the fix lands. almanac-bug.pl,
# almanac-migrate-todos.pl and almanac-migrate-memories.pl's own BEGIN
# blocks are bareword-only (`use Module::Name ()`, no sibling-SCRIPT
# require) and already pass for a harmless read verb; they are asserted
# here too so the fix (touching every BEGIN block named by the ledger's
# write_set) cannot regress them. almanac-bug.pl's SEPARATE
# _butler_module_path()->require($bphook_path) relative-sibling defect is
# only reached from the ticket-gated set-status/takeover verbs, not the
# harmless "list" used here -- out of scope for this block (ledger's "fix
# every instance found" covers it regardless of whether a dedicated test
# invokes that exact gated path).
# =============================================================================
{
    # run_relative(\@cmd, %opt) -- same fork()+exec() + per-stream-tempfile
    # discipline as run_child() above, but the CHILD additionally chdir()s to
    # $REPO_ROOT first, and the command's script path is given RELATIVE
    # (never resolved to absolute) -- reproducing the bug report's literal
    # invocation style. This process's own cwd is never touched.
    sub run_relative {
        my ($cmd, %opt) = @_;
        my (undef, $outfile) = tempfile();
        my (undef, $errfile) = tempfile();
        my $pid = fork();
        die "fork: $!" unless defined $pid;
        if ($pid == 0) {
            chdir($REPO_ROOT) or exit(125);
            delete $ENV{CLAUDE_PROJECT_DIR};
            delete $ENV{CCPRAXIS_DATA_DIR};
            delete $ENV{BP_PROJECT_ROOT};
            delete $ENV{BP_LEDGER};
            delete $ENV{ALMANAC_SURFACE};
            delete $ENV{ALMANAC_LOCK_TIMEOUT_MS};
            if ($opt{env}) {
                for my $k (keys %{ $opt{env} }) {
                    if (defined $opt{env}{$k}) { $ENV{$k} = $opt{env}{$k} } else { delete $ENV{$k} }
                }
            }
            open(STDOUT, '>', $outfile) or exit(126);
            open(STDERR, '>', $errfile) or exit(126);
            open(STDIN, '<', File::Spec->devnull) or exit(126);
            exec(@$cmd) or exit(127);
        }
        waitpid($pid, 0);
        my $rc = $? >> 8;
        return { rc => $rc, stdout => (slurp_raw($outfile) // ''), stderr => (slurp_raw($errfile) // '') };
    }

    my $CANT_LOCATE_RE = qr/Can't locate \S+ in \@INC/;

    my $Rd = mk_root();
    my $rdoc = run_relative([ $^X, 'plugins/almanac/scripts/almanac-doctor.pl', '--root', $Rd ],
        env => { ALMANAC_HOME => $Rd, HOME => $Rd, USERPROFILE => $Rd });
    unlike($rdoc->{stdout} . $rdoc->{stderr}, $CANT_LOCATE_RE,
        'REGRESSION (75fe): almanac-doctor.pl by RELATIVE path from the repo root never fails "Can\'t locate ... in @INC"')
        or diag("rc=$rdoc->{rc}\nstdout:\n$rdoc->{stdout}\nstderr:\n$rdoc->{stderr}");
    is($rdoc->{rc}, 0, 'REGRESSION (75fe): almanac-doctor.pl on a clean empty --root exits 0 via relative invocation')
        or diag("stdout:\n$rdoc->{stdout}\nstderr:\n$rdoc->{stderr}");

    my $Rb = mk_root();
    my $rbug = run_relative([ $^X, 'plugins/almanac/scripts/almanac-bug.pl', 'list', '--project', $Rb ],
        env => { ALMANAC_HOME => $Rb, HOME => $Rb, USERPROFILE => $Rb });
    unlike($rbug->{stdout} . $rbug->{stderr}, $CANT_LOCATE_RE,
        'REGRESSION (75fe): almanac-bug.pl by RELATIVE path from the repo root never fails "Can\'t locate ... in @INC" (harmless "list" verb)')
        or diag("rc=$rbug->{rc}\nstdout:\n$rbug->{stdout}\nstderr:\n$rbug->{stderr}");
    is($rbug->{rc}, 0, 'REGRESSION (75fe): almanac-bug.pl "list" on an empty --project exits 0 via relative invocation')
        or diag("stdout:\n$rbug->{stdout}\nstderr:\n$rbug->{stderr}");

    my $Rmt = mk_root();
    my $rmt = run_relative([ $^X, 'plugins/almanac/scripts/almanac-migrate-todos.pl', '--home', $Rmt ]);
    unlike($rmt->{stdout} . $rmt->{stderr}, $CANT_LOCATE_RE,
        'REGRESSION (75fe): almanac-migrate-todos.pl by RELATIVE path from the repo root never fails "Can\'t locate ... in @INC"')
        or diag("rc=$rmt->{rc}\nstdout:\n$rmt->{stdout}\nstderr:\n$rmt->{stderr}");

    my $Rmm = mk_root();
    my $rmm = run_relative([ $^X, 'plugins/almanac/scripts/almanac-migrate-memories.pl', 'plan', '--home', $Rmm ]);
    unlike($rmm->{stdout} . $rmm->{stderr}, $CANT_LOCATE_RE,
        'REGRESSION (75fe): almanac-migrate-memories.pl by RELATIVE path from the repo root never fails "Can\'t locate ... in @INC"')
        or diag("rc=$rmm->{rc}\nstdout:\n$rmm->{stdout}\nstderr:\n$rmm->{stderr}");
    is($rmm->{rc}, 0, 'REGRESSION (75fe): almanac-migrate-memories.pl "plan" on an empty --home exits 0 via relative invocation')
        or diag("stdout:\n$rmm->{stdout}\nstderr:\n$rmm->{stderr}");
}

# =============================================================================
# Isolation guard, again, at the end.
# =============================================================================
{
    my $real_after = {
        almanac      => list_tree("$REPO_ROOT/.ccpraxis-local-data/almanac"),
        bug_reports  => list_tree("$REPO_ROOT/.ccpraxis-local-data/bug-reports"),
    };
    is_deeply($real_after, $REAL_BEFORE,
        'house convention: the real repo\'s almanac + bug-reports trees have the same file listing before and after this file');
}

done_testing();
