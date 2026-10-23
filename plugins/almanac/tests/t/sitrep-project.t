#!/usr/bin/env perl
# platform: any
# Oracle for blueprint where-things-go, package 11-sitrep-commands
# (specs/11-sitrep-commands-spec.md sec 4, AC1-AC16 and AC25-AC27 -- the "ST"
# column of the AC table). Covers /sitrep's project mode: project_report(),
# the sitrep SKILL.md's frontmatter/pinned invocation line, and the CLI's
# usage-error contract.
#
# WRITTEN BLIND to any implementation: AlmanacSitrep (the script that would
# define it) and the sitrep repo skill's SKILL.md DO NOT EXIST YET at the
# time this file is written. Every AC below is expected to fail red for that
# reason (a missing file/require), never for a harness crash or a fixture
# defect of this file's own making.
#
# Fixtures reuse plugins/almanac/tests/t/almanac-gather.t's helpers verbatim
# (write_record, mk_inbox, mk_todo, mk_note, write_pkg_ledger,
# write_blueprint_meta, mk_bug_raw, write_registry, new_root's non-ASCII
# decode convention), plus a severity override on mk_bug_raw per spec sec 5.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use File::Spec ();
use Cwd ();
use JSON::PP ();
use Encode qw(decode);

# ---------------------------------------------------------------------------
# isolation: fixtures only, never the real ~/.claude (blueprint Constraints).
# ---------------------------------------------------------------------------
my $FIX_HOME = tempdir(CLEANUP => 1);
$ENV{HOME}                  = $FIX_HOME;
$ENV{ALMANAC_HOME}          = $FIX_HOME;
$ENV{BUTLER_STATE_DIR}      = $FIX_HOME;
$ENV{CCPRAXIS_DATA_DIR}     = $FIX_HOME;
$ENV{CCPRAXIS_SPEND_NO_FETCH} = 1;
delete $ENV{CLAUDE_PROJECT_DIR};
delete $ENV{USERPROFILE};

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
use lib "$Bin/../../scripts";
(my $BUTLER_S = "$Bin/../../../butler/scripts") =~ s{\\}{/}g;

my $SITREP_PL = "$S/almanac-sitrep.pl";

require "$S/Almanac/Thread.pm";
require "$S/Almanac/PackageLink.pm";
require "$S/Almanac/Store.pm";
require "$S/Almanac/SessionLive.pm";
require "$BUTLER_S/BpState.pm";

my $A = "$S/almanac-bug.pl";
{
    local $@;
    do $A;
    diag("loading $A for fixtures failed: $@") if $@;
}

my $SITREP_LOADS = eval { require $SITREP_PL; 1 } ? 1 : 0;
diag("almanac-sitrep.pl load error: $@") unless $SITREP_LOADS;

# ---------------------------------------------------------------------------
# scaffolding -- copied from almanac-gather.t, severity override added to
# mk_bug_raw per spec sec 5 ("give it a severity override").
# ---------------------------------------------------------------------------
my $ROOT_SEQ = 0;
sub new_root {
    my $base = tempdir(CLEANUP => 1);
    (my $r = "$base/André-sitrep" . (++$ROOT_SEQ)) =~ s{\\}{/}g;
    utf8::decode($r);
    make_path(_bytes_path($r));
    make_path(_bytes_path("$r/.ccpraxis-local-data/almanac"));
    return $r;
}

# Encode-if-flagged right before any filesystem call, same idiom
# Almanac::Gather::_fs_bytes uses, so a utf8::decode'd ("André") root never
# gets double-encoded or mis-written by a ':raw' filehandle.
sub _bytes_path {
    my ($p) = @_;
    my $b = $p;
    utf8::encode($b) if utf8::is_utf8($b);
    return $b;
}

sub write_record {
    my ($path, %f) = @_;
    $path = _bytes_path($path);
    make_path(File::Spec->catpath((File::Spec->splitpath($path))[0,1]));
    open(my $fh, '>:raw', $path) or die "fixture: cannot write $path: $!";
    print {$fh} "---\n";
    for my $k (sort keys %f) {
        next unless defined $f{$k};
        print {$fh} "$k: $f{$k}\n";
    }
    print {$fh} "---\n";
    close $fh;
}

sub mk_inbox {
    my ($root, $id, %f) = @_;
    write_record("$root/.ccpraxis-local-data/almanac/inbox/$id.md", id => $id, %f);
}
sub mk_todo {
    my ($root, $id, %f) = @_;
    write_record("$root/.ccpraxis-local-data/almanac/todo/$id.md", id => $id, %f);
}
sub mk_note {
    my ($root, $id, %f) = @_;
    write_record("$root/.ccpraxis-local-data/almanac/note/$id.md", id => $id, %f);
}

sub write_pkg_ledger {
    my ($root, $bp, $pkg, $status, %opt) = @_;
    my $base = $opt{archived}
        ? "$root/.ccpraxis-local-data/blueprints/_archive/$bp/packages"
        : "$root/.ccpraxis-local-data/blueprints/$bp/packages";
    $base = _bytes_path($base);
    make_path($base);
    open(my $fh, '>:raw', "$base/$pkg.md") or die "fixture: cannot write $base/$pkg.md: $!";
    print {$fh} "---\nstatus: $status\n---\n";
    close $fh;
}

sub write_blueprint_meta {
    my ($root, $bp, %f) = @_;
    my $base = _bytes_path("$root/.ccpraxis-local-data/blueprints/$bp");
    make_path($base);
    open(my $fh, '>:raw', "$base/blueprint.md") or die "fixture: cannot write $base/blueprint.md: $!";
    print {$fh} "---\n";
    print {$fh} "$_: $f{$_}\n" for sort keys %f;
    print {$fh} "---\n";
    close $fh;
}

my $BUG_SEQ = 0;
sub mk_bug_raw {
    my ($root, %o) = @_;
    my $id   = $o{id} // (AlmanacBug::new_id() . sprintf('-st%02d', ++$BUG_SEQ));
    my $now  = AlmanacBug::_iso(time);
    my $body = $o{body} // 'body text';
    my $dir  = AlmanacBug::reports_dir($root);
    make_path(_bytes_path($dir)) unless -d _bytes_path($dir);
    my $path = "$dir/$id.md";
    my %f = (
        id => $id, title => ($o{title} // 'bug'), status => $o{status},
        severity => ($o{severity} // 'unknown'), area => 'unknown', project => $root,
        created_at => $now, updated_at => $now,
        ($o{no_freeze} ? () : (frozen_at => $now, content_sha256 => AlmanacBug::body_digest($body))),
        (defined $o{package}      ? (package      => $o{package})      : ()),
        (defined $o{package_root} ? (package_root  => $o{package_root}) : ()),
        (defined $o{scheduled_at} ? (scheduled_at  => $o{scheduled_at}) : ()),
        (defined $o{fixed_at}     ? (fixed_at      => $o{fixed_at})     : ()),
    );
    my @order = qw(id title status severity area project created_at updated_at frozen_at
                   content_sha256 package package_root scheduled_at fixed_at);
    my $bpath = _bytes_path($path);
    open my $fh, '>:raw', $bpath or die "fixture: cannot write $bpath: $!";
    my $out = "---\n" . join("\n", map { defined $f{$_} ? "$_: $f{$_}" : () } @order) . "\n---\n$body";
    utf8::encode($out) if utf8::is_utf8($out);
    print {$fh} $out;
    close $fh;
    return ($path, $id);
}

sub write_registry {
    my ($almanac_home, %slug_to_path) = @_;
    my $dir = "$almanac_home/.claude/claude-code-vault";
    make_path($dir);
    my %projects;
    for my $slug (keys %slug_to_path) {
        $projects{$slug} = { path => $slug_to_path{$slug} };
    }
    open(my $fh, '>:raw', "$dir/.registry-local.json") or die "fixture: registry: $!";
    print {$fh} JSON::PP->new->utf8->canonical->encode({ projects => \%projects });
    close $fh;
}

sub iso_of {
    my ($epoch) = @_;
    my @t = gmtime($epoch);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

# write_snapshot($root, %doc) -- D2's exact shape, written directly to the
# D2-pinned path formula (this file's own literal, not a call into the
# module under test -- the module does not exist yet).
sub write_snapshot {
    my ($root, %doc) = @_;
    my $dir = _bytes_path("$root/.ccpraxis-local-data/sitrep");
    make_path($dir);
    my $path = "$dir/last.json";
    open(my $fh, '>:raw', $path) or die "fixture: cannot write $path: $!";
    print {$fh} JSON::PP->new->utf8->canonical->encode({ %doc });
    close $fh;
    return "$root/.ccpraxis-local-data/sitrep/last.json";
}

sub read_snapshot_raw {
    my ($root) = @_;
    my $path = _bytes_path("$root/.ccpraxis-local-data/sitrep/last.json");
    return undef unless -f $path;
    open(my $fh, '<:raw', $path) or return undef;
    local $/;
    my $raw = <$fh>;
    close $fh;
    return $raw;
}

sub write_gate_script {
    my ($path, $line, $exit_code) = @_;
    open(my $fh, '>', $path) or die "fixture: gate: $!";
    print {$fh} "#!/usr/bin/env perl\nprint \"$line\\n\";\nexit $exit_code;\n";
    close $fh;
    chmod 0755, $path;
    return $path;
}

sub decoded {
    my ($bytes) = @_;
    return defined $bytes ? decode('UTF-8', $bytes) : undef;
}

# index-based ordering helper: true iff every literal in @needles appears in
# $text, each one strictly after the previous.
sub appear_in_order {
    my ($text, @needles) = @_;
    my $pos = -1;
    for my $n (@needles) {
        my $p = index($text, $n, $pos + 1);
        return 0 if $p < 0;
        $pos = $p;
    }
    return 1;
}

my $GATE_DIR = tempdir(CLEANUP => 1);
my $OK_GATE    = write_gate_script("$GATE_DIR/ok-gate.pl", 'OK five=52 seven=71 token_life_h=5.00', 0);
my $CREDS_GATE = write_gate_script("$GATE_DIR/creds-gate.pl", 'CREDS detail=no-creds', 30);

# ===========================================================================
# Fixture F -- spec sec 5.1's single comprehensive project. Used read-only
# (write_snapshot => 0) by AC1-AC11/AC14; never mutated after construction.
# ===========================================================================
my $F = new_root();

Almanac::Thread::create_thread('alpha', root => $F);
Almanac::Thread::add_task('alpha', root => $F, title => 'first thing');
Almanac::Thread::add_task('alpha', root => $F, title => 'second thing');
{
    my $tasks = Almanac::Thread::tasks('alpha', root => $F);
    Almanac::Thread::set_task_status('alpha', $tasks->[0]{id}, 'doing', root => $F);
}
Almanac::Thread::create_thread('beta', root => $F);
Almanac::Thread::add_task('beta', root => $F, title => 'beta task');
Almanac::Thread::record_event('beta', 'handed-off', root => $F, reason => 'needs a human');

mk_todo($F, 'todo-open-1', title => 'ship it', status => 'open', created => '2026-01-01T00:00:00Z', tags => 'urgent');
mk_todo($F, 'todo-done-1', title => 'already shipped', status => 'done', created => '2026-01-01T00:00:01Z');

mk_inbox($F, 'ibx-plain', title => 'what next', status => 'unanswered', created => '2026-01-01T00:00:00Z');
mk_inbox($F, 'ibx-fleet', title => 'escalation echo', status => 'unanswered',
    created => '2026-01-01T00:00:01Z', link => 'escbp/01-esc-pkg/esc001', choices => '["accept","drop"]');

make_path(_bytes_path("$F/.ccpraxis-local-data/blueprints/escbp/runs/escalations"));
{
    open(my $fh, '>:raw', _bytes_path("$F/.ccpraxis-local-data/blueprints/escbp/runs/escalations/esc001.json"))
        or die;
    print {$fh} JSON::PP->new->utf8->canonical->encode({
        package => '01-esc-pkg', category => 'product', question => 'is this ok?',
        resolution => 'yes, go ahead',
    });
    close $fh;
}
write_pkg_ledger($F, 'escbp', '01-esc-pkg', 'running');
{
    # escbp's orchestrator marker present and NOT flocked -> orphaned (3.1 P8).
    open(my $fh, '>:raw', _bytes_path("$F/.ccpraxis-local-data/blueprints/escbp/runs/.orchestrator")) or die;
    print {$fh} "99999\n";
    close $fh;
}

make_path(_bytes_path("$F/.ccpraxis-local-data/blueprints/bp2/runs"));
{
    open(my $fh, '>:raw', _bytes_path("$F/.ccpraxis-local-data/blueprints/bp2/runs/.paused")) or die;
    close $fh;
}

make_path(_bytes_path("$F/.ccpraxis-local-data/blueprints/bp1/runs/escalations"));
{
    open(my $fh, '>:raw', _bytes_path("$F/.ccpraxis-local-data/blueprints/bp1/runs/escalations/esc-res-1.json"))
        or die;
    print {$fh} JSON::PP->new->utf8->canonical->encode({
        package => '02-b', category => 'implementation', question => 'resolver-only question',
    });
    close $fh;
}

my ($open_bug_path, $OPEN_BUG_ID) = mk_bug_raw($F, status => 'open', title => 'open bug', severity => 'high');
my ($fixed_bug_path, $FIXED_BUG_ID) = mk_bug_raw($F, status => 'fixed', title => 'fixed bug', fixed_at => AlmanacBug::_iso(time));
mk_bug_raw($F, status => 'dropped', title => 'dropped bug');

write_pkg_ledger($F, 'bp1', '01-a', 'done');
write_pkg_ledger($F, 'bp1', '02-b', 'done');
write_blueprint_meta($F, 'bp1', status => 'running');
write_blueprint_meta($F, 'bp2', status => 'parked', parked_reason => 'waiting on operator');
write_pkg_ledger($F, 'bp2', '01-only', 'pending');

my $S1_EPOCH = time() - 3600;
my $SINCE1   = iso_of($S1_EPOCH);
write_snapshot($F,
    schema => 1, generated_at => $SINCE1, root => $F, session_id => JSON::PP::null,
    packages => {
        bp1   => { '01-a' => 'done', '02-b' => 'pending' },
        bp2   => { '01-only' => 'pending' },
        escbp => { '01-esc-pkg' => 'running' },
    },
    inbox => { 'ibx-old' => 'an old question', 'ibx-plain' => 'what next' },
    usage => { at => $SINCE1, five_hour => 40, seven_day => 65 },
);

SKIP: {
    my $git = `bash -c "command -v git"`; chomp $git;
    skip 'AC11 fixture: no git on PATH -- commit fixture skipped', 0 unless length $git;
    system("git -C " . quotemeta($F) . " init -q");
    system("git -C " . quotemeta($F) . " -c user.email=t\@t -c user.name=t commit --allow-empty -q -m after-snapshot");
}

# ===========================================================================
# Case 1: AC1-AC9, AC14 -- one call over fixture F.
# ===========================================================================
my $NOW1 = time();
SKIP: {
    skip 'AlmanacSitrep not loadable', 1 unless $SITREP_LOADS;
    my $bytes = eval {
        AlmanacSitrep::project_report(root => $F, refresh => 0, gate_script => $OK_GATE,
            write_snapshot => 0, now => $NOW1);
    };
    ok(defined $bytes, 'project_report returns defined bytes for fixture F') or diag("err: $@");
    SKIP: {
        skip 'project_report died', 40 unless defined $bytes;
        my $text = decoded($bytes);
        my $base = (split m{/}, $F)[-1];

        # --- AC1: nine P1 headers, in order --------------------------------
        ok(appear_in_order($text,
            "Sitrep: $base",
            '== Changes since last sitrep ==',
            '== Blueprints ==',
            '== Threads ==',
            '== Todos ==',
            '== Inbox ==',
            '== Fleets ==',
            '== Bugs ==',
            '== Usage ==',
        ), 'AC1: all nine P1 section headers present, in P1 order');
        like($text, qr/^Sitrep: \Q$base\E  \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/m,
            'AC1: header line is exactly "Sitrep: <basename>  <generated_at>"');

        # --- AC2: Blueprints ------------------------------------------------
        like($text, qr/^ {2}bp1  done  2\/2$/m, 'AC2: bp1 line is "bp1  done  2/2"');
        like($text, qr/^ {4}done: 01-a, 02-b$/m, 'AC2: bp1 package-status row is "done: 01-a, 02-b"');
        like($text, qr/^ {2}bp2  parked  0\/1  parked: waiting on operator$/m,
            'AC2: bp2 line is "bp2  parked  0/1  parked: waiting on operator"');
        like($text, qr/^ {4}pending: 01-only$/m, 'AC2: bp2 package-status row is "pending: 01-only"');

        # --- AC3: Threads -----------------------------------------------------
        like($text, qr/^ {2}alpha  \[live, \w+\]  0\/2.*doing: first thing.*next: second thing/m,
            'AC3: live thread alpha shows doing: and next:, with done/total');
        like($text, qr/^ {2}beta  \[handed-off, \w+\]  0\/1/m, 'AC3: handed-off thread beta shows done/total');
        like($text, qr/^ {4}handoff: needs a human$/m, 'AC3: beta shows "handoff: needs a human"');

        # --- AC4: Todos ------------------------------------------------------
        like($text, qr/^ {2}todo-open-1  ship it  \[urgent\]$/m, 'AC4: open todo id+title+tags shown');
        unlike($text, qr/already shipped/, 'AC4: a done todo\'s title does not appear');

        # --- AC5: Inbox -------------------------------------------------------
        like($text, qr/^ {2}ibx-plain  what next$/m, 'AC5: unanswered plain item shows its question');
        like($text, qr/^ {4}answer: almanac inbox answer ibx-plain$/m, 'AC5: ibx-plain answer line');
        like($text, qr/^ {2}ibx-fleet  escalation echo$/m, 'AC5: fleet-linked item shows its question');
        like($text, qr/^ {4}fleet: escbp\/01-esc-pkg\/esc001$/m, 'AC5: fleet-linked item shows fleet: <link>');
        like($text, qr/^ {4}rationale: yes, go ahead$/m, 'AC5: fleet-linked item shows rationale: <resolution>');
        like($text, qr/^ {4}actions: accept \| drop$/m, 'AC5: fleet-linked item shows actions: accept | drop');
        like($text, qr/^ {4}answer: almanac inbox answer ibx-fleet$/m, 'AC5: ibx-fleet answer line');

        # --- AC6: Fleets --------------------------------------------------------
        like($text,
            qr/^ {4}orchestrator is dead -- resume: run \/butler:dispatch-fleet escbp in this project's sandbox \(it continues the run, never duplicates\)$/m,
            'AC6: orphaned run prints the resume line naming escbp');
        like($text, qr/^ {4}paused -- runs\/\.paused is set$/m, 'AC6: paused run prints "paused -- runs/.paused is set"');
        like($text, qr/^ {4}resolver  esc-res-1  02-b  implementation  resolver-only question$/m,
            'AC6: resolver escalation\'s question appears under Fleets');
        like($text, qr/^ {4}inbox  esc001  -> ibx-fleet$/m, 'AC6: inbox escalation appears as "inbox <id> -> <inbox_id>"');

        # --- AC7: Bugs ------------------------------------------------------
        like($text, qr/^ {2}Open:$/m, 'AC7: "Open:" heading present');
        like($text, qr/^ {4}\Q$OPEN_BUG_ID\E  open  high  open bug$/m, 'AC7: open bug listed with severity "high"');
        ok(appear_in_order($text, 'Closed since', "$FIXED_BUG_ID  fixed  fixed bug"),
            'AC7: the fixed bug (fixed_at after the snapshot) appears under "Closed since"');

        # --- AC8: Packages diff ----------------------------------------------
        like($text, qr/^ {4}finished  bp1\/02-b  \(pending -> done\)$/m,
            'AC8: a package moved to done with no thread-log entry naming it renders "finished  bp1/02-b  (pending -> done)"');

        # --- AC9: Inbox added / answered --------------------------------------
        ok(appear_in_order($text, 'Inbox added:', 'ibx-fleet  escalation echo'),
            'AC9: ibx-fleet (not in the snapshot) is listed under "Inbox added:"');
        ok(appear_in_order($text, 'Inbox answered:', 'ibx-old  an old question'),
            'AC9: ibx-old (in the snapshot, no longer unanswered) is listed under "Inbox answered:" with the snapshot\'s question text');

        # --- AC11: Commits (SKIP without git) ---------------------------------
        SKIP: {
            my $git = `bash -c "command -v git"`; chomp $git;
            skip 'AC11: no git on PATH', 1 unless length $git;
            ok(appear_in_order($text, 'Commits:', 'after-snapshot'),
                'AC11: a commit after generated_at appears under "Commits:"');
        }

        # --- AC14: Usage utilisation with a baseline --------------------------
        like($text, qr/^ {2}5-hour  40% -> 52%  \(\+12 pts\)$/m,
            'AC14: "5-hour  40% -> 52%  (+12 pts)"');
        like($text, qr/^ {2}7-day  65% -> 71%  \(\+6 pts\)$/m,
            'AC14: "7-day  65% -> 71%  (+6 pts)"');
    }
}

# ===========================================================================
# Case 2: AC10 -- thread-log events since the snapshot; none when the
# snapshot's generated_at is in the future.
# ===========================================================================
SKIP: {
    skip 'AlmanacSitrep not loadable', 1 unless $SITREP_LOADS;
    my $bytes = eval {
        AlmanacSitrep::project_report(root => $F, refresh => 0, gate_script => $OK_GATE,
            write_snapshot => 0, now => $NOW1);
    };
    SKIP: {
        skip 'project_report died', 1 unless defined $bytes;
        my $text = decoded($bytes);
        ok(appear_in_order($text, 'Thread log:', 'beta', 'handed-off'),
            'AC10: Thread log: lists the beta handed-off event (recorded after the snapshot)');
    }

    write_snapshot($F,
        schema => 1, generated_at => iso_of(time() + 3600), root => $F, session_id => JSON::PP::null,
        packages => { bp1 => { '01-a' => 'done', '02-b' => 'done' }, bp2 => { '01-only' => 'pending' },
                      escbp => { '01-esc-pkg' => 'running' } },
        inbox => { 'ibx-plain' => 'what next', 'ibx-fleet' => 'escalation echo' },
        usage => { at => iso_of(time() + 3600), five_hour => 52, seven_day => 71 },
    );
    my $bytes2 = eval {
        AlmanacSitrep::project_report(root => $F, refresh => 0, gate_script => $OK_GATE,
            write_snapshot => 0, now => $NOW1);
    };
    SKIP: {
        skip 'project_report died (future snapshot)', 1 unless defined $bytes2;
        my $text2 = decoded($bytes2);
        my $after = substr($text2, index($text2, 'Thread log:'));
        (my $block = $after) =~ s/\A(.*?)\n==.*\z/$1/s;
        like($block, qr/\(none\)/, 'AC10: with a future snapshot generated_at, "Thread log:" shows (none)');
    }

    # restore S1 for subsequent cases that depend on it.
    write_snapshot($F,
        schema => 1, generated_at => $SINCE1, root => $F, session_id => JSON::PP::null,
        packages => { bp1 => { '01-a' => 'done', '02-b' => 'pending' }, bp2 => { '01-only' => 'pending' },
                      escbp => { '01-esc-pkg' => 'running' } },
        inbox => { 'ibx-old' => 'an old question', 'ibx-plain' => 'what next' },
        usage => { at => $SINCE1, five_hour => 40, seven_day => 65 },
    );
}

# ===========================================================================
# Case 3 (AC12): no snapshot -> baseline; last.json written with the exact
# D2 keys; a second unchanged run gives (none); write_snapshot=>0 writes
# nothing. Independent fresh fixture, so it never disturbs F/S1 above.
# ===========================================================================
{
    my $P = new_root();
    write_pkg_ledger($P, 'bp1', '01-a', 'done');
    write_pkg_ledger($P, 'bp1', '02-b', 'done');
    write_blueprint_meta($P, 'bp1', status => 'running');
    mk_inbox($P, 'ibx-plain', title => 'what next', status => 'unanswered', created => '2026-01-01T00:00:00Z');

    SKIP: {
        skip 'AlmanacSitrep not loadable', 1 unless $SITREP_LOADS;
        ok(!-f "$P/.ccpraxis-local-data/sitrep/last.json", 'AC12 precondition: no snapshot exists yet');
        my $bytes = eval {
            AlmanacSitrep::project_report(root => $P, refresh => 0, gate_script => $OK_GATE,
                write_snapshot => 1, now => time());
        };
        ok(defined $bytes, 'AC12: project_report with no snapshot succeeds') or diag("err: $@");
        SKIP: {
            skip 'project_report died', 6 unless defined $bytes;
            my $text = decoded($bytes);
            like($text, qr/No previous sitrep: this one is the baseline\./,
                'AC12: P2 baseline line present with no snapshot');

            my $raw = read_snapshot_raw($P);
            ok(defined $raw, 'AC12: last.json now exists');
            my $doc = eval { JSON::PP->new->utf8->decode($raw) };
            ok(ref $doc eq 'HASH', 'AC12: last.json decodes as a JSON object') or diag($raw // '<undef>');
            SKIP: {
                skip 'AC12: snapshot did not decode', 4 unless ref $doc eq 'HASH';
                is_deeply([ sort keys %$doc ], [ sort qw(schema generated_at root session_id packages inbox usage) ],
                    'AC12: last.json has exactly the D2 keys');
                is($doc->{schema}, 1, 'AC12: schema == 1');
                is($doc->{packages}{bp1}{'02-b'}, 'done', 'AC12: packages.bp1.02-b is "done"');
                is($doc->{inbox}{'ibx-plain'}, 'what next', 'AC12: inbox.ibx-plain is "what next"');
                is(0 + $doc->{usage}{five_hour}, 52, 'AC12: usage.five_hour == 52');
            }

            my $bytes2 = eval {
                AlmanacSitrep::project_report(root => $P, refresh => 0, gate_script => $OK_GATE,
                    write_snapshot => 1, now => time());
            };
            SKIP: {
                skip 'second project_report died', 3 unless defined $bytes2;
                my $text2 = decoded($bytes2);
                my $changes = substr($text2, 0, index($text2, '== Blueprints =='));
                unlike($changes, qr/finished|moved/, 'AC12: a second unchanged run shows no Packages diff rows');
                like($changes, qr/\(none\)/, 'AC12: Packages/Inbox added/Inbox answered print (none) on an unchanged re-run');
            }
        }
    }

    my $FRESH = new_root();
    SKIP: {
        skip 'AlmanacSitrep not loadable', 1 unless $SITREP_LOADS;
        eval {
            AlmanacSitrep::project_report(root => $FRESH, refresh => 0, gate_script => $OK_GATE,
                write_snapshot => 0, now => time());
        };
        ok(!-f "$FRESH/.ccpraxis-local-data/sitrep/last.json",
            'AC12: write_snapshot => 0 on a fresh project leaves no snapshot file');
    }
}

# ===========================================================================
# Case 4 (AC13): an unreadable (invalid JSON) snapshot is treated as
# unreadable, not absent; the run still succeeds and rewrites a valid one.
# ===========================================================================
{
    my $P = new_root();
    write_pkg_ledger($P, 'bp1', '01-a', 'done');
    write_blueprint_meta($P, 'bp1', status => 'running');
    make_path(_bytes_path("$P/.ccpraxis-local-data/sitrep"));
    open(my $fh, '>:raw', _bytes_path("$P/.ccpraxis-local-data/sitrep/last.json")) or die;
    print {$fh} '{not json';
    close $fh;

    SKIP: {
        skip 'AlmanacSitrep not loadable', 1 unless $SITREP_LOADS;
        my $bytes = eval {
            AlmanacSitrep::project_report(root => $P, refresh => 0, gate_script => $OK_GATE,
                write_snapshot => 1, now => time());
        };
        ok(defined $bytes, 'AC13: project_report with an unreadable snapshot still succeeds') or diag("err: $@");
        SKIP: {
            skip 'project_report died', 2 unless defined $bytes;
            my $text = decoded($bytes);
            like($text, qr/Previous snapshot unreadable: this one is the new baseline\./,
                'AC13: the distinct "Previous snapshot unreadable" P2 line is shown');
            my $raw = read_snapshot_raw($P);
            my $doc = eval { JSON::PP->new->utf8->decode($raw // '') };
            is(ref $doc eq 'HASH' ? $doc->{schema} : undef, 1,
                'AC13: afterwards the snapshot file decodes with schema == 1');
        }
    }
}

# ===========================================================================
# Case 5 (AC15): spend -- main session vs subagent tokens, by worker type,
# by package with dispatch wall-clock; a pre-snapshot request excluded.
# ===========================================================================
{
    my $P = new_root();
    my $now = time();
    my $s1_epoch = $now - 1000;
    write_snapshot($P, schema => 1, generated_at => iso_of($s1_epoch), root => $P,
        session_id => JSON::PP::null, packages => {}, inbox => {}, usage => JSON::PP::null);

    my $T = tempdir(CLEANUP => 1);
    sub _iso_ms {
        my ($epoch) = @_;
        my @t = gmtime($epoch);
        return sprintf('%04d-%02d-%02dT%02d:%02d:%02d.000Z', $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
    }
    my $JSON1 = JSON::PP->new->canonical;
    open(my $mfh, '>:raw', "$T/sess-1.jsonl") or die;
    print {$mfh} $JSON1->encode({
        type => 'assistant', timestamp => _iso_ms($now - 7200), requestId => 'r0',
        message => { id => 'm0', model => 'claude-opus-4-1', usage => { input_tokens => 1000, output_tokens => 1 } },
    }), "\n";
    print {$mfh} $JSON1->encode({
        type => 'assistant', timestamp => _iso_ms($s1_epoch + 30), requestId => 'r1',
        message => { id => 'm1', model => 'claude-opus-4-1', usage => { input_tokens => 100, output_tokens => 50 } },
    }), "\n";
    close $mfh;

    make_path("$T/sess-1/subagents");
    open(my $sfh, '>:raw', "$T/sess-1/subagents/agent-a1.jsonl") or die;
    print {$sfh} $JSON1->encode({
        type => 'assistant', timestamp => _iso_ms($s1_epoch + 30), requestId => 'r2',
        message => { id => 'm2', model => 'claude-opus-4-1', usage => { input_tokens => 200, output_tokens => 20 } },
    }), "\n";
    close $sfh;
    open(my $metafh, '>:raw', "$T/sess-1/subagents/agent-a1.meta.json") or die;
    print {$metafh} $JSON1->encode({ agentType => 'butler:bp-implementer', toolUseId => 'toolu_A1' });
    close $metafh;

    make_path(_bytes_path("$P/.ccpraxis-local-data/.dispatch-log"));
    open(my $attrfh, '>:raw', _bytes_path("$P/.ccpraxis-local-data/.dispatch-log/attribution.jsonl")) or die;
    print {$attrfh} $JSON1->encode({ tool_use_id => 'toolu_A1', blueprint => 'bp1', package => '02-b', source => 'dispatch-hook' }), "\n";
    close $attrfh;
    open(my $dfh, '>:raw', _bytes_path("$P/.ccpraxis-local-data/.dispatch-log/d1.json")) or die;
    print {$dfh} $JSON1->encode({ id => 'd1', worker_type => 'bp-implementer',
        started_at => $s1_epoch + 60, ended_at => $s1_epoch + 185, blueprint => 'bp1', package => '02-b' });
    close $dfh;

    SKIP: {
        skip 'AlmanacSitrep not loadable', 1 unless $SITREP_LOADS;
        my $bytes = eval {
            AlmanacSitrep::project_report(root => $P, refresh => 0, gate_script => $OK_GATE,
                write_snapshot => 0, now => $now, transcript => "$T/sess-1.jsonl");
        };
        ok(defined $bytes, 'AC15: project_report with a fixture transcript succeeds') or diag("err: $@");
        SKIP: {
            skip 'project_report died', 4 unless defined $bytes;
            my $text = decoded($bytes);
            like($text, qr/^ {2}Main session  150$/m, 'AC15: "Main session  150" (1000+1 excluded as before the snapshot)');
            like($text, qr/^ {2}Subagents  220$/m, 'AC15: "Subagents  220"');
            ok(appear_in_order($text, 'By worker type:', 'butler:bp-implementer  220'),
                'AC15: By worker type: has the subagent\'s agentType with 220');
            like($text, qr/^ {4}bp1\/02-b  220  dispatches 1  wall 2m05s$/m,
                'AC15: By package: row "bp1/02-b  220  dispatches 1  wall 2m05s"');
        }
    }
}

# ===========================================================================
# Case 6 (AC16): usage degradations.
# ===========================================================================
{
    my $P = new_root();
    my $usage_snap_epoch = time() - 1000;
    write_snapshot($P, schema => 1, generated_at => iso_of($usage_snap_epoch), root => $P,
        session_id => JSON::PP::null, packages => {}, inbox => {},
        usage => { at => iso_of($usage_snap_epoch), five_hour => 40, seven_day => 65 });

    SKIP: {
        skip 'AlmanacSitrep not loadable', 1 unless $SITREP_LOADS;
        my $bytes = eval {
            AlmanacSitrep::project_report(root => $P, refresh => 0, gate_script => $CREDS_GATE,
                write_snapshot => 1, now => time());
        };
        ok(defined $bytes, 'AC16a: project_report with a CREDS-exiting gate succeeds') or diag("err: $@");
        SKIP: {
            skip 'project_report died', 2 unless defined $bytes;
            my $text = decoded($bytes);
            like($text, qr/^ {2}utilisation unavailable:/m, 'AC16a: "utilisation unavailable:" line on a non-ok gate reading');
            my $raw = read_snapshot_raw($P);
            my $doc = eval { JSON::PP->new->utf8->decode($raw // '') };
            is_deeply($doc->{usage}, { at => iso_of($usage_snap_epoch), five_hour => 40, seven_day => 65 },
                'AC16a: the written snapshot keeps the previous usage object unchanged on a failed reading')
                if ref $doc eq 'HASH';
        }
    }

    SKIP: {
        skip 'AlmanacSitrep not loadable', 1 unless $SITREP_LOADS;
        my $bytes = eval {
            AlmanacSitrep::project_report(root => $P, refresh => 0, gate_script => $OK_GATE,
                write_snapshot => 0, now => time());
        };
        SKIP: {
            skip 'project_report died', 1 unless defined $bytes;
            my $text = decoded($bytes);
            like($text, qr/spend unavailable: no session transcript/,
                'AC16b: no transcript/session_id gives "spend unavailable: no session transcript"');
        }
    }

    my $FRESH = new_root();
    SKIP: {
        skip 'AlmanacSitrep not loadable', 1 unless $SITREP_LOADS;
        my $bytes = eval {
            AlmanacSitrep::project_report(root => $FRESH, refresh => 0, gate_script => $OK_GATE,
                write_snapshot => 0, now => time());
        };
        SKIP: {
            skip 'project_report died', 1 unless defined $bytes;
            my $text = decoded($bytes);
            like($text, qr/^ {2}5-hour  52%  \(no baseline\)$/m,
                'AC16c: no snapshot + an ok reading gives "5-hour  52%  (no baseline)"');
        }
    }
}

# ===========================================================================
# Case 7 (AC25/AC26): skills/sitrep/SKILL.md frontmatter + pinned D1 line,
# and the D1 resolution path from almanac's bin/ shim.
# ===========================================================================
{
    my $skill_path = "$Bin/../../../../skills/sitrep/SKILL.md";
    ok(-f $skill_path, 'AC25/AC26 precondition: skills/sitrep/SKILL.md exists')
        or diag('not written yet');
    SKIP: {
        skip 'skills/sitrep/SKILL.md does not exist yet', 4 unless -f $skill_path;
        open(my $fh, '<:raw', $skill_path) or die;
        local $/;
        my $raw = <$fh>;
        close $fh;
        my $content = decode('UTF-8', $raw);
        my ($fm) = $content =~ /\A---\n(.*?)\n---\n/s;
        ok(defined $fm, 'AC25: SKILL.md has a frontmatter block') or diag($content);
        SKIP: {
            skip 'no frontmatter block', 2 unless defined $fm;
            like($fm, qr/^name:\s*sitrep\s*$/m, 'AC25: frontmatter has "name: sitrep"');
            like($fm, qr/^description:\s*\S.+$/m, 'AC25: frontmatter has a non-empty description:');
        }
        my $pinned = q{perl "$(dirname "$(command -v almanac)")/../scripts/almanac-sitrep.pl" project --session-id "${CLAUDE_SESSION_ID}"};
        like($content, qr/```bash\n\Q$pinned\E\n```/, 'AC26: body contains the pinned D1 line inside a ```bash fence');
    }

    my $almanac_bin_dir = "$Bin/../../bin";
    my $path_with_bin = "$almanac_bin_dir:$ENV{PATH}";
    # Through the environment, not interpolated into the command line: a PATH
    # holding a space (C:/Program Files/...) split the assignment, so the probe
    # ran `Files/...` as a command and never found the shim.
    my $found = do { local $ENV{PATH} = $path_with_bin; `bash -c 'command -v almanac'` };
    chomp $found;
    ok(length $found, 'AC26 precondition: "command -v almanac" resolves with PATH prefixed by plugins/almanac/bin');
    SKIP: {
        skip 'almanac shim not found on PATH', 1 unless length $found;
        my $resolved = $found;
        $resolved =~ s{/[^/]+\z}{};
        my $script = "$resolved/../scripts/almanac-sitrep.pl";
        ok(-f $script, 'AC26: dirname(command -v almanac)/../scripts/almanac-sitrep.pl is a file');
    }
}

# ===========================================================================
# Case 8 (AC27): CLI usage errors.
# ===========================================================================
{
    ok(-f $SITREP_PL, 'AC27 precondition: almanac-sitrep.pl exists') or diag('not written yet');
    SKIP: {
        skip 'almanac-sitrep.pl does not exist yet', 4 unless -f $SITREP_PL;
        my $run_cli = sub {
            my (@args) = @_;
            my (undef, $out) = tempfile();
            my (undef, $err) = tempfile();
            my @cmd = ($^X, $SITREP_PL, @args);
            my $inner = join(' ', map { qq("$_") } @cmd) . qq( < /dev/null > "$out" 2> "$err");
            system('bash', '-c', $inner);
            my $rc = ($? == -1) ? -1 : ($? >> 8);
            open(my $ofh, '<:raw', $out) or return { rc => $rc, out => '' };
            local $/; my $o = <$ofh>; close $ofh;
            return { rc => $rc, out => (defined $o ? $o : '') };
        };

        my $res_bogus = $run_cli->('bogus');
        is($res_bogus->{rc}, 2, 'AC27: "almanac-sitrep.pl bogus" exits 2');
        is($res_bogus->{out}, '', 'AC27: "almanac-sitrep.pl bogus" prints nothing to stdout');

        my $res_bad_now = $run_cli->('project', '--now', 'abc');
        is($res_bad_now->{rc}, 2, 'AC27: "project --now abc" exits 2');
        is($res_bad_now->{out}, '', 'AC27: "project --now abc" prints nothing to stdout');
    }
}

done_testing();
