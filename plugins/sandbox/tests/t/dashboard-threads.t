#!/usr/bin/env perl
# platform: any
# package 13-dashboard-threads (blueprint where-things-go).
# specs/13-dashboard-threads-spec.md.
#
# THIS FILE IS THE IMMUTABLE ORACLE for this package. It is written BLIND to
# any RunState.pm / Dashboard.pm / tui/DashboardScreen.pm implementation of
# the new thread surface -- directly from the spec -- so it serves as an
# oracle rather than an echo of whatever the implementer eventually writes.
# Do NOT weaken an assertion here to make a future implementation's life
# easier.
#
# Coverage: spec S3 behaviours 1-17, via S4's AC1, AC3, AC5-AC10, AC13, AC14.
# AC2, AC4, AC11, AC12 live in t/run-state.t, row-budget-and-preview.t and
# no-rendered-colons.t respectively (the architect's file split, Decision 57
# / the blueprint's "Flagging for the test-writer" note) -- not duplicated
# here.
#
# HARD CONSTRAINTS (spec S3 "Fixture conventions", AC13):
#   * PURE: this file never launches launcher.pl, podman or claude. It
#     mentions those three words only inside fixture STRINGS (never as an
#     invoked binary) -- a source scan at the very top (AC13) asserts this
#     about the file's OWN bytes, read fresh off disk, not about a hand-kept
#     claim that could drift from the code around it.
#   * Every fixture lives under File::Temp::tempdir (CLEANUP => 1). Project P
#     is such a tempdir; the blueprints root handed to RunState is always
#     "$P/.ccpraxis-local-data/blueprints".
#   * Thread/task/log records are written BY HAND as Almanac records
#     ("---\n" + "key: value\n" lines + "---\n"), matching
#     statusline.pl's almanac_parse_record (the format RunState's own
#     _parse_record is pinned to accept identically) -- never through
#     Almanac::Thread's write path, which takes locks and reads the clock.
#   * The localtime function handed to Dashboard subs is always the real
#     `sub { gmtime($_[0]) }` (deterministic, UTC, no host-timezone
#     dependency) -- matching the spec's own fixture convention.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Time::Local qw(timegm);

# ===========================================================================
# AC13 -- this file's own purity, scanned off DISK (not a hand-kept claim).
# ===========================================================================
{
    my $self = __FILE__;
    open my $fh, '<:raw', $self or die "cannot read self ($self): $!";
    local $/;
    my $src = <$fh>;
    close $fh;
    ok(length($src) > 0, 'AC13 precondition: this file is readable off disk');

    # First sentence of the file-header purity claim, asserted as text (spec:
    # "a source scan inside the test asserts the first sentence").
    like($src, qr/THIS FILE IS THE IMMUTABLE ORACLE for this package\./,
        'AC13: the file opens with its immutable-oracle sentence, verbatim');

    # This self-scan block necessarily SPELLS the forbidden shapes (its own
    # regex literals), so it excludes ITS OWN source from what gets scanned
    # (sliced from the sentinel marker below onward) -- otherwise the scan
    # would trip on its own pattern definitions before any real violation in
    # the file's actual fixtures/assertions could ever be the cause.
    my $MARKER = '# >>> ac13-self-scan-boundary';
    my $mpos = rindex($src, $MARKER);   # LAST occurrence: line 66 quotes this string literally too
    ok($mpos >= 0, 'AC13 precondition: the self-scan boundary marker is present') or diag('marker not found');
    my $scan_src = ($mpos >= 0) ? substr($src, $mpos + length($MARKER)) : $src;
    $scan_src =~ s/#[^\n]*//g;   # strip #-to-end-of-line comments before scanning code
    for my $f (
        [ 'a system call',          qr/\bsystem\s*\(/ ],
        [ 'an exec call',           qr/\bexec\s*\(/ ],
        [ 'a qx operator',          qr/\bqx\b/ ],
        [ 'a backtick character',   qr/`/ ],
        [ q{a piped open ('-|')},   qr/open\s*\(?\s*[^,]*,\s*['"]-\|['"]/ ],
        [ 'a fork call',            qr/\bfork\s*\(/ ],
    ) {
        my ($label, $qr) = @$f;
        unlike($scan_src, $qr, "AC13: this file's source (past the self-scan boundary) contains no $label");
    }
    # do/require of launcher.pl specifically (require'ing OTHER modules --
    # RunState, Dashboard, tui::DashboardScreen -- is the whole point of the
    # file and must NOT be flagged).
    unlike($scan_src, qr/\b(?:do|require)\b[^\n;]*launcher\.pl/, 'AC13: this file never do/require\'s launcher.pl');

    # "podman"/"claude" appear only inside fixture strings, never as an
    # invoked binary -- operationalised as: neither word is ever immediately
    # followed by `(` (a call) nor preceded by system/exec/qx constructs
    # (already excluded above). A plain substring count > 0 is fine (this
    # header comment itself says "podman" and "claude").
    unlike($scan_src, qr/\b(?:podman|claude)\s*\(/, 'AC13: "podman"/"claude" never appear as an invoked-binary call shape');
}
# >>> ac13-self-scan-boundary

use_ok('RunState') or BAIL_OUT('RunState.pm did not load');
use_ok('Dashboard') or BAIL_OUT('Dashboard.pm did not load');
my $DS_OK = eval { require tui::DashboardScreen; 1 };
diag("require tui::DashboardScreen failed: $@") unless $DS_OK;
my $THEME_OK = eval { require Theme; 1 };
diag("require Theme failed: $@") unless $THEME_OK;

my $SCRIPTS_DIR   = "$Bin/../../scripts";
my $LAUNCHER_PATH = "$SCRIPTS_DIR/launcher.pl";

# ===========================================================================
# Scaffolding
# ===========================================================================

sub write_file {
    my ($path, $content) = @_;
    open my $fh, '>:raw', $path or die "write_file($path): $!";
    print $fh $content;
    close $fh;
}
sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $s = <$fh>;
    close $fh;
    return $s;
}

my $FAILED = bless { dt => 'call did not happen' }, 'DashboardThreads::CallFailed';
sub probe_call {
    my ($fn, @args) = @_;
    my @warns;
    my ($res, $err);
    { local $SIG{__WARN__} = sub { push @warns, $_[0] };
      $res = eval { no strict 'refs'; &{"RunState::$fn"}(@args) };
      $err = $@; }
    $err = '' unless defined $err;
    return ($res, $err, \@warns);
}
sub RS {
    my ($res, $err) = probe_call(@_);
    return $FAILED if $err ne '';
    return $res;
}
sub is_hashref  { my ($h) = @_; return ref($h) eq 'HASH' }
sub is_arrayref { my ($h) = @_; return ref($h) eq 'ARRAY' }
sub field       { my ($h, $k) = @_; return is_hashref($h) ? $h->{$k} : $FAILED }

# call_ds($sub, @args) -> (\@results, $err) -- symbolic-ref into
# tui::DashboardScreen, same idiom the sibling oracles already use.
sub call_ds {
    my ($name, @args) = @_;
    no strict 'refs';
    my @res;
    my $ok = eval { @res = &{"tui::DashboardScreen::$name"}(@args); 1 };
    my $err = $ok ? '' : (defined($@) && length($@) ? $@ : 'unknown error');
    return (\@res, $err);
}
sub call1 { my ($name, @args) = @_; my ($r, $e) = call_ds($name, @args); return ($r->[0], $e); }

# --- Almanac record writers (hand-rolled, never via Almanac::Thread). ------
sub almanac_root { my ($P) = @_; return "$P/.ccpraxis-local-data/almanac" }
sub blueprints_root { my ($P) = @_; return "$P/.ccpraxis-local-data/blueprints" }

sub write_thread_record {
    my ($P, $name, %f) = @_;
    my $dir = almanac_root($P) . '/thread';
    make_path($dir);
    my @order = qw(created state owner_kind owner_id owner_transcript blueprints);
    my @lines = ('---');
    for my $k (@order) { push @lines, "$k: $f{$k}" if exists $f{$k} && defined $f{$k} }
    push @lines, '---', '';
    write_file("$dir/$name.md", join("\n", @lines));
}
sub write_task_record {
    my ($P, $thread, $id, %f) = @_;
    my $dir = almanac_root($P) . "/thread-tasks-$thread";
    make_path($dir);
    my @order = qw(rank title created link status blocked_on from_todo);
    my @lines = ('---');
    for my $k (@order) { push @lines, "$k: $f{$k}" if exists $f{$k} && defined $f{$k} }
    push @lines, '---', '';
    write_file("$dir/$id.md", join("\n", @lines));
}
sub write_log_record {
    my ($P, $thread, $id, %f) = @_;
    my $dir = almanac_root($P) . "/thread-log-$thread";
    make_path($dir);
    my @order = qw(at session actor event task from to reason);
    my @lines = ('---');
    for my $k (@order) { push @lines, "$k: $f{$k}" if exists $f{$k} && defined $f{$k} }
    push @lines, '---', '';
    write_file("$dir/$id.md", join("\n", @lines));
}

# iso_of($epoch) -> "YYYY-MM-DDTHH:MM:SSZ", via Time::Local's inverse
# (gmtime), used only to BUILD fixtures -- RunState.pm itself may never do
# this (its own purity scan forbids gmtime/localtime/time()).
sub iso_of {
    my ($epoch) = @_;
    my @t = gmtime($epoch);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

# ledger_text($status, @steps) -- @steps = ([checked?, num, word], ...).
sub ledger_text {
    my ($status, @steps) = @_;
    my @lines = ('---', "status: $status", '---', '', '## Pipeline', '');
    for my $st (@steps) {
        my ($checked, $num, $word) = @$st;
        push @lines, sprintf('- [%s] %d. %s', $checked ? 'x' : ' ', $num, $word);
    }
    push @lines, '';
    return join("\n", @lines);
}
# 8 pipeline steps, word at index N-1 == the step's own label (matches real
# blueprint ledgers' vocabulary -- scout/spec/test-writer/implementation/
# validation/review/fix-batch/ui-pass).
my @PIPELINE_WORDS = qw(scout spec test-writer implementation validation review fix-batch ui-pass);
# steps_all_checked_except($n) -> the 8-step list with only step $n unchecked
# (0 = none unchecked / all checked).
sub steps_all_checked_except {
    my ($n) = @_;
    return [ map { [ ($_ == $n ? 0 : 1), $_, $PIPELINE_WORDS[$_ - 1] ] } (1 .. 8) ];
}
sub steps_all_unchecked {
    return [ map { [ 0, $_, $PIPELINE_WORDS[$_ - 1] ] } (1 .. 8) ];
}

# registry_json(%pkgs) -- minimal '{"packages":{...}}' doc, same shape t/45
# uses (shorthand values only; this file never needs RAW_JSON).
sub registry_json {
    my (%pkgs) = @_;
    my @entries = map { qq("$_":{"status":"$pkgs{$_}"}) } sort keys %pkgs;
    return '{"packages":{' . join(',', @entries) . '}}';
}

# make_blueprint($root, $name, %o) -> "$root/$name" (created).
#   orchestrator => <marker text>, registry => <json text> (default: {}),
#   packages => { "<num>-<slug>" => <ledger text> }, archived => 1 (writes
#   under _archive/<name>/packages/ instead of <name>/packages/).
sub make_blueprint {
    my ($root, $name, %o) = @_;
    my $dir = "$root/$name";
    make_path("$dir/runs");
    write_file("$dir/runs/registry.json", exists $o{registry} ? $o{registry} : registry_json());
    write_file("$dir/runs/.orchestrator", $o{orchestrator}) if exists $o{orchestrator};
    if ($o{packages}) {
        my $pkg_root = $o{archived} ? "$root/_archive/$name/packages" : "$dir/packages";
        make_path($pkg_root);
        for my $pkg (keys %{ $o{packages} }) {
            write_file("$pkg_root/$pkg.md", $o{packages}{$pkg});
        }
    }
    return $dir;
}

# ===========================================================================
# AC1 -- behaviours 1, 2: the TF (fleet-like) fixture, RunState thread
# fields, and the exact rendered line text.
# ===========================================================================
my ($TF_P, $TF_ROOT, $TF_DIR);
{
    $TF_P    = tempdir(CLEANUP => 1);
    $TF_ROOT = blueprints_root($TF_P);

    $TF_DIR = make_blueprint($TF_ROOT, 'tooling-fixes',
        packages => {
            '10-alpha'        => ledger_text('done',    @{ steps_all_checked_except(0) }),
            '11-beta'         => ledger_text('dropped',  @{ steps_all_checked_except(0) }),
            '12-bug-claimant' => ledger_text('running',  @{ steps_all_checked_except(1) }),
            '13-guard'        => ledger_text('pending',  @{ steps_all_unchecked() }),
        },
    );

    write_thread_record($TF_P, 'drive-tooling',
        created => '2023-11-14T00:00:00Z', state => 'live',
        owner_kind => 'session', owner_id => 'sess-1', owner_transcript => "$TF_P/tx/sess-1.jsonl");
    make_path("$TF_P/tx");
    write_file("$TF_P/tx/sess-1.jsonl", "{}\n");
    utime(1_700_000_000, 1_700_000_000, "$TF_P/tx/sess-1.jsonl") or diag("utime failed: $!");

    write_task_record($TF_P, 'drive-tooling', 't1', rank => '1', created => '2023-11-14T00:00:01Z', link => 'tooling-fixes/10-alpha');
    write_task_record($TF_P, 'drive-tooling', 't2', rank => '2', created => '2023-11-14T00:00:02Z', link => 'tooling-fixes/11-beta');
    write_task_record($TF_P, 'drive-tooling', 't3', rank => '3', created => '2023-11-14T00:00:03Z', title => 'Write the release notes', status => 'done');
    write_task_record($TF_P, 'drive-tooling', 't4', rank => '4', created => '2023-11-14T00:00:04Z', title => 'Retire the old flag', status => 'obsoleted');
    write_task_record($TF_P, 'drive-tooling', 't5', rank => '5', created => '2023-11-14T00:00:05Z', link => 'tooling-fixes/12-bug-claimant', title => 'SHOULD NOT RENDER');
    write_task_record($TF_P, 'drive-tooling', 't6', rank => '6', created => '2023-11-14T00:00:06Z', title => 'Refresh the fixtures', status => 'doing');
    write_task_record($TF_P, 'drive-tooling', 't7', rank => '7', created => '2023-11-14T00:00:07Z', link => 'tooling-fixes/13-guard');
    write_task_record($TF_P, 'drive-tooling', 't8', rank => '8', created => '2023-11-14T00:00:08Z', title => 'Tidy the docs', status => 'pending');
    write_task_record($TF_P, 'drive-tooling', 't9', rank => '9', created => '2023-11-14T00:00:09Z', title => 'Ship it', status => 'pending');
}

{
    my $s = RS('summarize_dir', $TF_DIR);
    ok(is_hashref($s), 'AC1/B1: summarize_dir(tooling-fixes) returns a hashref') or diag(" got: " . (ref($s) || $s));
    my $th = field($s, 'thread');
    ok(is_hashref($th), 'AC1/B1: tooling-fixes summary carries a thread hash') or diag(' thread: ' . (ref($th) || (defined($th) ? $th : 'undef')));
  SKIP: {
        skip('no thread hash', 8) unless is_hashref($th);
        is($th->{name}, 'drive-tooling', 'AC1/B1: thread.name is drive-tooling');
        is($th->{state}, 'live', 'AC1/B1: thread.state is live');
        is($th->{done}, 4, 'AC1/B1: thread.done is 4 (t1,t2,t3,t4 done-class)');
        is($th->{total}, 9, 'AC1/B1: thread.total is 9');
        is(ref($th->{doing}), 'ARRAY', 'AC1/B1: thread.doing is an ARRAY');
        is(scalar(@{ $th->{doing} || [] }), 2, 'AC1/B1: thread.doing has 2 entries (t5 link, t6 text)');
        if (ref($th->{doing}) eq 'ARRAY' && @{ $th->{doing} } == 2) {
            is($th->{doing}[0]{kind}, 'link', 'AC1/B1: doing[0] is a link label (t5)');
            is($th->{doing}[0]{blueprint}, 'tooling-fixes', 'AC1/B1: doing[0].blueprint is tooling-fixes');
            is($th->{doing}[0]{number}, '12', 'AC1/B1: doing[0].number is 12');
            is($th->{doing}[0]{step}, 'scout', 'AC1/B1: doing[0].step is scout (step 1 lowest-unchecked)');
            is($th->{doing}[1]{kind}, 'text', 'AC1/B1: doing[1] is a text label (t6)');
            is($th->{doing}[1]{title}, 'Refresh the fixtures', 'AC1/B1: doing[1].title is "Refresh the fixtures"');
        }
        is($th->{current}, undef, 'AC1/B1: thread.current is undef (doing is non-empty)');
        ok(is_hashref($th->{next}), 'AC1/B1: thread.next is a label hash');
        if (is_hashref($th->{next})) {
            is($th->{next}{kind}, 'link', 'AC1/B1: next is a link (t7)');
            is($th->{next}{blueprint}, 'tooling-fixes', 'AC1/B1: next.blueprint is tooling-fixes');
            is($th->{next}{number}, '13', 'AC1/B1: next.number is 13');
            is($th->{next}{step}, 'scout', 'AC1/B1: next.step is scout (step 1 lowest-unchecked)');
        }
        ok(is_hashref($th->{owner}), 'AC1/B1: thread.owner is a hashref');
        if (is_hashref($th->{owner})) {
            is($th->{owner}{kind}, 'session', 'AC1/B1: owner.kind is session');
            is($th->{owner}{id}, 'sess-1', 'AC1/B1: owner.id is sess-1');
            is($th->{owner}{activity_at}, 1_700_000_000, 'AC1/B1: owner.activity_at is the transcript\'s own mtime');
            is($th->{owner}{armed}, 0, 'AC1/B1: owner.armed is 0 (no arm file)');
        }
    }
}

# --- AC6/B2: the exact rendered line text. ---------------------------------
SKIP: {
    skip('tui::DashboardScreen or Theme did not load', 1) unless $DS_OK && $THEME_OK;
    my $s = RS('summarize_dir', $TF_DIR);
    my $th = field($s, 'thread');
    skip('no thread hash from AC1', 1) unless is_hashref($th);

    my $FULL  = Theme::glyph('gauge.full');
    my $EMPTY = Theme::glyph('gauge.empty');
    ok(defined($FULL) && defined($EMPTY) && length($FULL) && length($EMPTY),
        'AC6/B2 precondition: Theme declares gauge.full/gauge.empty glyphs');
  SKIP: {
        skip('no gauge glyphs', 2) unless defined($FULL) && defined($EMPTY) && length($FULL) && length($EMPTY);
        my $line = eval { tui::DashboardScreen::_thread_line({ thread => $th }, 1_700_000_100) };
        my $err  = $@;
        ok(!$err, 'AC6/B2: _thread_line does not die') or diag(" error: $err");
      SKIP: {
            skip('_thread_line died', 1) unless !$err;
            my $text = Dashboard::spans_text($line);
            my $expected = "  thread drive-tooling " . ($FULL x 4) . ($EMPTY x 5)
                . " 4/9  doing tooling-fixes/12 scout +1  next tooling-fixes/13 scout  session live";
            is($text, $expected, 'AC6/B2: _thread_line spans_text matches exactly');
        }
    }
}

# ===========================================================================
# AC1/AC5 -- behaviour 3: orchestrator owner liveness + the tie-break rule
# when two open threads both drive the same blueprint.
# ===========================================================================
{
    my $P = tempdir(CLEANUP => 1);
    my $root = blueprints_root($P);
    my $dir = make_blueprint($root, 'tooling-fixes');
    write_file("$dir/runs/.orchestrator", "4242\n");

    write_thread_record($P, 'fleet-x', created => '2023-11-14T00:00:00Z', state => 'live',
        owner_kind => 'orchestrator', owner_id => 'tooling-fixes', blueprints => 'tooling-fixes');
    write_thread_record($P, 'drive-tooling', created => '2023-11-14T00:00:00Z', state => 'live',
        owner_kind => 'session', owner_id => 'other-sess', blueprints => 'tooling-fixes');

    for my $case (
        [ 'prober true',          sub { 1 },           1,     'live'    ],
        [ 'prober false',         sub { 0 },           0,     'dead'    ],
        [ 'no prober installed',  undef,               undef, 'unknown' ],
    ) {
        my ($label, $prober, $exp_alive, $exp_word) = @$case;
        local $RunState::PID_ALIVE = $prober;
        my $s = RS('summarize_dir', $dir);
        my $th = field($s, 'thread');
        ok(is_hashref($th), "AC1/B3 [$label]: tooling-fixes carries a thread") or next;
        is($th->{name}, 'fleet-x', "AC1/B3 [$label]: fleet-x wins the tie-break (owner_kind orchestrator, owner_id==blueprint)");
        is($th->{owner}{kind}, 'orchestrator', "AC1/B3 [$label]: owner.kind is orchestrator");
        is($th->{owner}{alive}, $exp_alive, "AC1/B3 [$label]: owner.alive is " . (defined($exp_alive) ? $exp_alive : 'undef'));
        SKIP: {
            skip('DashboardScreen not loaded', 1) unless $DS_OK;
            my $word = eval { tui::DashboardScreen::thread_owner_status($th, 1_700_000_000) };
            my $werr = $@;
            is($word, $exp_word, "AC5 [$label]: thread_owner_status is '$exp_word'") unless $werr;
            fail("AC5 [$label]: thread_owner_status is '$exp_word'") if $werr;
        }
    }

    # Marker removed entirely -> alive 0 (RunState's own rule), dead verdict.
    {
        local $RunState::PID_ALIVE = sub { 1 };   # irrelevant: marker absent short-circuits to alive=0
        unlink("$dir/runs/.orchestrator") or die "unlink: $!";
        my $s = RS('summarize_dir', $dir);
        my $th = field($s, 'thread');
        is(field($th, 'owner') && $th->{owner}{alive}, 0, 'AC1/B3 [marker removed]: owner.alive is 0');
    }
}

# ===========================================================================
# AC1/AC6 -- behaviour 4: handed-off + blocked thread.
# ===========================================================================
{
    my $P = tempdir(CLEANUP => 1);
    my $root = blueprints_root($P);
    make_blueprint($root, 'release-target', packages => { '01-thing' => ledger_text('done', @{ steps_all_checked_except(0) }) });

    write_thread_record($P, 'release-prep', created => '2023-11-14T00:00:00Z', state => 'handed-off',
        owner_kind => 'none');
    write_task_record($P, 'release-prep', 'r0', rank => '0', created => '2023-11-14T00:00:00Z',
        link => 'release-target/01-thing');   # drives release-target only; see note below
    write_task_record($P, 'release-prep', 'r1', rank => '1', created => '2023-11-14T00:00:01Z', title => 'Tag the build', status => 'done');
    write_task_record($P, 'release-prep', 'r2', rank => '2', created => '2023-11-14T00:00:02Z', title => 'Publish the package', status => 'blocked', blocked_on => '20261002-120000-abcd');
    write_task_record($P, 'release-prep', 'r3', rank => '3', created => '2023-11-14T00:00:03Z', title => 'Announce it', status => 'pending');

    my $dir = make_blueprint($root, 'release-target', packages => { '01-thing' => ledger_text('done', @{ steps_all_checked_except(0) }) });
    my $s = RS('summarize_dir', $dir);
    my $th = field($s, 'thread');
    ok(is_hashref($th), 'AC1/B4: release-target carries the release-prep thread (via its one linked task)') or diag(' thread: ' . (ref($th) || (defined($th) ? $th : 'undef')));
  SKIP: {
        skip('no thread', 6) unless is_hashref($th);
        is($th->{state}, 'handed-off', 'AC1/B4: state is handed-off');
        is(scalar(@{ $th->{doing} || [] }), 0, 'AC1/B4: doing is empty');
        ok(is_hashref($th->{current}), 'AC1/B4: current is a label hash (doing empty, first not-done task)');
        is($th->{current}{class}, 'blocked', 'AC1/B4: current is blocked-class ("Publish the package")');
        is($th->{current}{title}, 'Publish the package', 'AC1/B4: current.title is "Publish the package"');
        is($th->{current}{waits_on}, '20261002-120000-abcd', 'AC1/B4: current.waits_on is the blocked_on id');
        ok(is_hashref($th->{next}), 'AC1/B4: next is a label hash');
        is($th->{next}{title}, 'Announce it', 'AC1/B4: next.title is "Announce it"');

        SKIP: {
            skip('DashboardScreen/Theme not loaded', 3) unless $DS_OK && $THEME_OK;
            my ($word) = eval { tui::DashboardScreen::thread_owner_status($th, 1_700_000_000) };
            is($word, 'unowned', 'AC5/B4: thread_owner_status is unowned (state handed-off beats owner.kind)');
            my $line = eval { tui::DashboardScreen::_thread_line({ thread => $th }, 1_700_000_000) };
            my $err  = $@;
            ok(!$err, 'AC6/B4: _thread_line does not die') or diag(" error: $err");
          SKIP: {
                skip('_thread_line died', 1) unless !$err;
                my $text = Dashboard::spans_text($line);
                like($text, qr/blocked Publish the package waiting on 20261002-120000-abcd/,
                    'AC6/B4: the blocked form has no colon and carries "waiting on <id>"');
                like($text, qr/next Announce it/, 'AC6/B4: the next form is present');
                like($text, qr/handed off\z/, 'AC6/B4: the line ends "handed off"');
                unlike($text, qr/:/, 'AC6/B4: the rendered line contains no colon at all');
            }
        }
    }
}

# ===========================================================================
# AC1 -- behaviour 5: archived-blueprint link resolution (Decision 18 F1).
# ===========================================================================
for my $case (
    [ 'archived-only', 0, 1, 'implementation' ],   # archived ledger step4 unchecked
    [ 'live+archived',  1, 1, 'spec' ],            # live ledger wins, step2 unchecked
) {
    my ($label, $also_live, undef, $exp_word) = @$case;
    my $P = tempdir(CLEANUP => 1);
    my $root = blueprints_root($P);
    make_blueprint($root, 'retired-bp', archived => 1,
        packages => { '03-thing' => ledger_text('running', @{ steps_all_checked_except(4) }) });
    if ($also_live) {
        make_blueprint($root, 'retired-bp',
            packages => { '03-thing' => ledger_text('running', @{ steps_all_checked_except(2) }) });
    }
    else {
        make_path("$root/retired-bp/runs");
        write_file("$root/retired-bp/runs/registry.json", registry_json());
    }
    write_thread_record($P, 'archive-thread', created => '2023-11-14T00:00:00Z', state => 'live',
        owner_kind => 'none');
    write_task_record($P, 'archive-thread', 'a1', rank => '1', created => '2023-11-14T00:00:01Z', link => 'retired-bp/03-thing');

    my $s = RS('summarize_dir', "$root/retired-bp");
    my $th = field($s, 'thread');
    ok(is_hashref($th), "AC1/B5 [$label]: retired-bp carries archive-thread (resolved through _archive)") or diag(' thread: ' . (ref($th) || (defined($th) ? $th : 'undef')));
  SKIP: {
        skip('no thread', 2) unless is_hashref($th);
        my $label_hash = (@{ $th->{doing} || [] }) ? $th->{doing}[0] : $th->{current};
        ok(is_hashref($label_hash), "AC1/B5 [$label]: a label hash exists for the sole task");
        is($label_hash->{step}, $exp_word, "AC1/B5 [$label]: step word is '$exp_word'") if is_hashref($label_hash);
    }
}
# ... and "neither" (no ledger anywhere): missing, pending-class, counted in
# total but not done.
{
    my $P = tempdir(CLEANUP => 1);
    my $root = blueprints_root($P);
    make_blueprint($root, 'host-bp');
    write_thread_record($P, 'archive-thread2', created => '2023-11-14T00:00:00Z', state => 'live',
        owner_kind => 'none', blueprints => 'host-bp');
    write_task_record($P, 'archive-thread2', 'm1', rank => '1', created => '2023-11-14T00:00:01Z', link => 'retired-bp/03-thing');

    my $s = RS('summarize_dir', "$root/host-bp");
    my $th = field($s, 'thread');
    ok(is_hashref($th), 'AC1/B5 [neither]: host-bp carries archive-thread2');
  SKIP: {
        skip('no thread', 3) unless is_hashref($th);
        is($th->{total}, 1, 'AC1/B5 [neither]: total is 1');
        is($th->{done}, 0, 'AC1/B5 [neither]: done is 0 (missing never counts as done)');
        my $label_hash = $th->{next} // $th->{current} // (@{ $th->{doing} || [] } ? $th->{doing}[0] : undef);
        if (is_hashref($label_hash)) {
            is($label_hash->{step}, 'missing', 'AC1/B5 [neither]: step word is "missing"');
        } else {
            fail('AC1/B5 [neither]: a label hash exists naming the missing link');
        }
    }
}

# ===========================================================================
# AC1 -- behaviour 6: no-thread cases.
# ===========================================================================
{
    my $P = tempdir(CLEANUP => 1);
    my $root = blueprints_root($P);
    my $dir = make_blueprint($root, 'lonely-bp');
    # no almanac/thread/ dir created at all
    my $s = RS('summarize_dir', $dir);
    is(field($s, 'thread'), undef, 'AC1/B6: no almanac/thread/ dir -> thread is undef');
    is_deeply(field($s, 'thread_events'), [], 'AC1/B6: ... -> thread_events is []');
}
{
    my $P = tempdir(CLEANUP => 1);
    my $root = blueprints_root($P);
    my $dir = make_blueprint($root, 'undriven-bp');
    write_thread_record($P, 'elsewhere-thread', created => '2023-11-14T00:00:00Z', state => 'live',
        owner_kind => 'none', blueprints => 'some-other-bp');
    my $s = RS('summarize_dir', $dir);
    is(field($s, 'thread'), undef, 'AC1/B6: a thread exists but drives nothing here -> thread is undef');
}
{
    my $P = tempdir(CLEANUP => 1);
    my $root = blueprints_root($P);
    my $dir = make_blueprint($root, 'archived-only-bp');
    write_thread_record($P, 'long-gone', created => '2023-11-14T00:00:00Z', state => 'archived',
        owner_kind => 'none', blueprints => 'archived-only-bp', archived_at => '2023-11-15T00:00:00Z');
    my $s = RS('summarize_dir', $dir);
    is(field($s, 'thread'), undef, 'AC1/B6: an archived thread drives nothing');
}
{
    # blueprints root without the required tail.
    my $P = tempdir(CLEANUP => 1);
    my $weird_root = "$P/not-the-right-tail";
    make_path($weird_root);
    my $dir = make_blueprint($weird_root, 'bp');
    my $s = RS('summarize_dir', $dir);
    is(field($s, 'thread'), undef, 'AC1/B6: a root without the .ccpraxis-local-data/blueprints tail -> thread undef');
    is_deeply(field($s, 'thread_events'), [], 'AC1/B6: ... -> thread_events []');
}

# ===========================================================================
# AC1 -- behaviour 7: events bounded to 10 newest across threads, ascending,
# project-level (deep-equal + non-aliased across every summary).
# ===========================================================================
{
    my $P = tempdir(CLEANUP => 1);
    my $root = blueprints_root($P);
    my $dir1 = make_blueprint($root, 'ev-bp-1');
    my $dir2 = make_blueprint($root, 'ev-bp-2');

    write_thread_record($P, 'drive-tooling', created => '2023-11-14T00:00:00Z', state => 'live',
        owner_kind => 'none', blueprints => 'ev-bp-1');
    write_thread_record($P, 'fleet-x', created => '2023-11-14T00:00:00Z', state => 'live',
        owner_kind => 'none', blueprints => 'ev-bp-2');

    my $BASE = timegm(20, 13, 22, 14, 10, 123);   # 2023-11-14T22:13:20Z
    for my $i (1 .. 12) {
        write_log_record($P, 'drive-tooling', sprintf('%08d', $i),
            at => iso_of($BASE + ($i - 1) * 60), event => 'task-status', actor => 'session');
    }
    for my $i (1 .. 3) {
        write_log_record($P, 'fleet-x', sprintf('%08d', $i),
            at => iso_of($BASE + (570 + ($i - 1) * 60)), event => 'launched', actor => 'orchestrator');
    }
    # a non-parsing / empty-event / bad-at entry that must be excluded.
    write_log_record($P, 'drive-tooling', '00000099', at => 'not-a-date', event => 'task-status');
    write_log_record($P, 'drive-tooling', '00000098', at => iso_of($BASE), event => '');

    my $list = RS('summarize', $root);
    ok(is_arrayref($list), 'AC1/B7 precondition: summarize() returns an arrayref') or diag(' got ' . (ref($list) || $list));
  SKIP: {
        skip('no list', 1) unless is_arrayref($list);
        is(scalar(@$list), 2, 'AC1/B7 precondition: both blueprints survive');
        my @te_lists = map { field($_, 'thread_events') } @$list;
        ok((grep { is_arrayref($_) } @te_lists) == 2, 'AC1/B7: both summaries carry an ARRAY thread_events');
      SKIP: {
            skip('not both arrays', 5) unless (grep { is_arrayref($_) } @te_lists) == 2;
            is(scalar(@{ $te_lists[0] }), 10, 'AC1/B7: thread_events has exactly 10 entries');
            is_deeply($te_lists[0], $te_lists[1], 'AC1/B7: thread_events is deep-equal across every summary');
            isnt($te_lists[0], $te_lists[1], 'AC1/B7: ... but NOT the same reference');
            my @epochs = map { $_->{epoch} } @{ $te_lists[0] };
            my @sorted = sort { $a <=> $b } @epochs;
            is_deeply(\@epochs, \@sorted, 'AC1/B7: thread_events is ascending by epoch');
            my @ids = map { "$_->{thread}/$_->{id}" } @{ $te_lists[0] };
            my %want = map { $_ => 1 } (
                (map { "drive-tooling/" . sprintf('%08d', $_) } (6 .. 12)),
                (map { "fleet-x/" . sprintf('%08d', $_) } (1 .. 3)),
            );
            my @unexpected = grep { !$want{$_} } @ids;
            is(scalar(@unexpected), 0, 'AC1/B7: the kept 10 are exactly the 10 newest across both threads (drive-tooling 6-12, fleet-x 1-3)')
                or diag(' got: ' . join(',', @ids));
        }
    }
}

# ===========================================================================
# AC3/B8 -- a package transition is never a thread-log event.
# ===========================================================================
{
    my $P = tempdir(CLEANUP => 1);
    my $root = blueprints_root($P);
    my $dir = make_blueprint($root, 'xition-bp',
        packages => { '13-guard' => ledger_text('pending', @{ steps_all_unchecked() }) });
    write_thread_record($P, 't-xition', created => '2023-11-14T00:00:00Z', state => 'live', owner_kind => 'none');
    write_task_record($P, 't-xition', 'x1', rank => '1', created => '2023-11-14T00:00:01Z', link => 'xition-bp/13-guard');
    write_log_record($P, 't-xition', '00000001', at => '2023-11-14T00:00:02Z', event => 'created');

    my $before = RS('summarize_dir', $dir);
    write_file("$dir/packages/13-guard.md", ledger_text('done', @{ steps_all_checked_except(0) }));
    my $after = RS('summarize_dir', $dir);

    is_deeply(field($before, 'thread_events'), field($after, 'thread_events'),
        'AC3/B8: thread_events is identical before/after a ledger status rewrite');
    is(field(field($before, 'thread'), 'done'), 0, 'AC3/B8: before, thread.done is 0 (13-guard pending)');
    is(field(field($after, 'thread'), 'done'), 1, 'AC3/B8: after, thread.done is 1 (13-guard done) -- the field DID update, just not through thread_events');
}

# ===========================================================================
# AC5 -- thread_owner_status, the full rule table (spec S2.3).
# ===========================================================================
SKIP: {
    skip('DashboardScreen did not load', 1) unless $DS_OK;
    my $NOW = 1_700_000_000;
    for my $c (
        [ 'not a HASH',                          undef,                                                                1 ],
        [ 'handed-off beats owner',               { state => 'handed-off', owner => { kind => 'session' } },            1 ],
        [ 'owner.kind none',                      { state => 'live', owner => { kind => 'none' } },                     1 ],
        [ 'orchestrator alive=1',                 { state => 'live', owner => { kind => 'orchestrator', alive => 1 } }, 0 ],
        [ 'orchestrator alive=0',                 { state => 'live', owner => { kind => 'orchestrator', alive => 0 } }, 0 ],
        [ 'orchestrator alive=undef',             { state => 'live', owner => { kind => 'orchestrator', alive => undef } }, 0 ],
        [ 'session idle=3600 (<=3600 live)',      { state => 'live', owner => { kind => 'session', activity_at => $NOW - 3600, armed => 0 } }, 0 ],
        [ 'session idle=3601 unarmed (dead)',     { state => 'live', owner => { kind => 'session', activity_at => $NOW - 3601, armed => 0 } }, 0 ],
        [ 'session idle=3601 armed (live)',       { state => 'live', owner => { kind => 'session', activity_at => $NOW - 3601, armed => 1 } }, 0 ],
        [ 'session idle=46800 armed (live)',      { state => 'live', owner => { kind => 'session', activity_at => $NOW - 46800, armed => 1 } }, 0 ],
        [ 'session idle=46801 armed (dead)',      { state => 'live', owner => { kind => 'session', activity_at => $NOW - 46801, armed => 1 } }, 0 ],
        [ 'session activity_at undef (unknown)',  { state => 'live', owner => { kind => 'session', activity_at => undef, armed => 0 } }, 0 ],
    ) {
        my ($label, $thread) = @$c;
        my $word = eval { tui::DashboardScreen::thread_owner_status($thread, $NOW) };
        my $err  = $@;
        ok(!$err, "AC5 [$label]: thread_owner_status does not die") or diag(" error: $err");
    }
    # separately pin the actual VALUES (not just non-death), by label:
    my %EXPECT = (
        'not a HASH'                         => 'unowned',
        'handed-off beats owner'             => 'unowned',
        'owner.kind none'                    => 'unowned',
        'orchestrator alive=1'               => 'live',
        'orchestrator alive=0'               => 'dead',
        'orchestrator alive=undef'           => 'unknown',
        'session idle=3600 (<=3600 live)'    => 'live',
        'session idle=3601 unarmed (dead)'   => 'dead',
        'session idle=3601 armed (live)'     => 'live',
        'session idle=46800 armed (live)'    => 'live',
        'session idle=46801 armed (dead)'    => 'dead',
        'session activity_at undef (unknown)' => 'unknown',
    );
    my %FIXTURES = (
        'not a HASH'                         => undef,
        'handed-off beats owner'             => { state => 'handed-off', owner => { kind => 'session' } },
        'owner.kind none'                    => { state => 'live', owner => { kind => 'none' } },
        'orchestrator alive=1'               => { state => 'live', owner => { kind => 'orchestrator', alive => 1 } },
        'orchestrator alive=0'               => { state => 'live', owner => { kind => 'orchestrator', alive => 0 } },
        'orchestrator alive=undef'           => { state => 'live', owner => { kind => 'orchestrator', alive => undef } },
        'session idle=3600 (<=3600 live)'    => { state => 'live', owner => { kind => 'session', activity_at => $NOW - 3600, armed => 0 } },
        'session idle=3601 unarmed (dead)'   => { state => 'live', owner => { kind => 'session', activity_at => $NOW - 3601, armed => 0 } },
        'session idle=3601 armed (live)'     => { state => 'live', owner => { kind => 'session', activity_at => $NOW - 3601, armed => 1 } },
        'session idle=46800 armed (live)'    => { state => 'live', owner => { kind => 'session', activity_at => $NOW - 46800, armed => 1 } },
        'session idle=46801 armed (dead)'    => { state => 'live', owner => { kind => 'session', activity_at => $NOW - 46801, armed => 1 } },
        'session activity_at undef (unknown)' => { state => 'live', owner => { kind => 'session', activity_at => undef, armed => 0 } },
    );
    for my $label (sort keys %EXPECT) {
        my $word = eval { tui::DashboardScreen::thread_owner_status($FIXTURES{$label}, $NOW) };
        is($word, $EXPECT{$label}, "AC5: thread_owner_status('$label') is '$EXPECT{$label}'");
    }
    # $now itself undef/unparseable -> unknown for a session thread with a
    # real activity_at.
    my $word_now_undef = eval { tui::DashboardScreen::thread_owner_status(
        { state => 'live', owner => { kind => 'session', activity_at => $NOW - 10, armed => 0 } }, undef) };
    is($word_now_undef, 'unknown', 'AC5: $now undef -> unknown for a session thread');
}

# ===========================================================================
# AC9 -- Dashboard::row_time_key matches launcher.pl's _row_time_key exactly
# (same extraction technique activity-feed-ordering.t already uses for the
# SAME launcher sub -- launcher.pl is slurped as source text, never
# require'd/do'ne).
# ===========================================================================
{
    my $launcher_src = slurp($LAUNCHER_PATH);
    ok(defined($launcher_src) && length($launcher_src), 'AC9 precondition: launcher.pl is readable on disk');
  SKIP: {
        skip('launcher.pl unreadable', 1) unless defined($launcher_src) && length($launcher_src);
        my ($region) = $launcher_src =~ /\Q# >>> s-rowtimekey:BEGIN\E\n(.*?)\Q# <<< s-rowtimekey:END\E/s;
        ok(defined($region), 'AC9 precondition: the s-rowtimekey region is present in launcher.pl');
      SKIP: {
            skip('region not found', 1) unless defined $region;
            my $harness = "package LauncherRowTimeKey;\nuse strict;\nuse warnings;\n$region\n1;\n";
            my $eval_ok = eval $harness;   ## no critic
            ok($eval_ok, 'AC9 precondition: the s-rowtimekey region evals cleanly') or diag("eval error: $@");
          SKIP: {
                skip('region failed to eval', 1) unless $eval_ok;
                my $LAUNCHER_KEY = LauncherRowTimeKey->can('_row_time_key');
                ok(defined($LAUNCHER_KEY), 'AC9 precondition: the extracted package can _row_time_key');
              SKIP: {
                    skip('sub not extractable', 1) unless defined $LAUNCHER_KEY;
                    for my $c (
                        [ 'HH:MM',           [ { text => '17:43' } ] ],
                        [ 'HH:MM trailing',  [ { text => '17:43 ' } ] ],
                        [ 'HH:MM:SS',        [ { text => '08:02:09 x' } ] ],
                        [ '00:00',           [ { text => '00:00' } ] ],
                        [ '23:59',           [ { text => '23:59' } ] ],
                        [ 'a divider row',   [ { text => '-- previous session --' } ] ],
                        [ 'empty row',       [] ],
                        [ 'non-ARRAY',       'nope' ],
                    ) {
                        my ($label, $row) = @$c;
                        my $want = $LAUNCHER_KEY->($row);
                        my $got  = eval { Dashboard::row_time_key($row) };
                        is($got, $want, "AC9 [$label]: Dashboard::row_time_key agrees with launcher.pl's _row_time_key");
                    }
                }
            }
        }
    }
}

# ===========================================================================
# AC8 -- thread_event_rows + merge_thread_events (behaviours 9-13).
# ===========================================================================
my $GM = \&CORE::gmtime;

sub synth_run {
    my (%o) = @_;
    return { blueprint => $o{blueprint} // 'synth-bp', thread_events => $o{thread_events} // [] };
}
sub synth_event {
    my (%o) = @_;
    return { thread => $o{thread}, id => $o{id}, at => $o{at}, epoch => $o{epoch}, event => $o{event},
             actor => $o{actor}, session => $o{session}, task => $o{task}, from => $o{from}, to => $o{to},
             reason => $o{reason} };
}

# --- B9: thread_event_rows dedups by thread+id across two summaries -------
{
    my @events = (
        synth_event(thread => 'drive-tooling', id => '00000001', epoch => 1_700_000_000, at => iso_of(1_700_000_000), event => 'launched'),
        synth_event(thread => 'drive-tooling', id => '00000002', epoch => 1_700_000_060, at => iso_of(1_700_000_060), event => 'task-status', task => 'abc', from => 'pending', to => 'doing'),
    );
    my $runs = [ synth_run(blueprint => 'a', thread_events => \@events), synth_run(blueprint => 'b', thread_events => \@events) ];
    my $rows = eval { Dashboard::thread_event_rows($runs, $GM, undef) };
    my $err  = $@;
    ok(!$err, 'AC8/B9: thread_event_rows does not die') or diag(" error: $err");
  SKIP: {
        skip('died', 3) unless !$err;
        is(ref($rows), 'ARRAY', 'AC8/B9: thread_event_rows returns an arrayref');
        is(scalar(@$rows), 2, 'AC8/B9: duplicated-by-two-summaries events still yield exactly 2 rows (deduped), not 4');
        my ($ts_row) = grep { $_->{event} eq 'task-status' } @$rows;
        ok(defined($ts_row), 'AC8/B9: the task-status row is present') or diag(' rows: ' . join(' | ', map { $_->{event} } @$rows));
        if (defined $ts_row) {
            my $text = Dashboard::spans_text($ts_row->{row});
            like($text, qr/task-status thread=drive-tooling task=abc from=pending to=doing/,
                'AC8/B9: task-status body renders event/thread/task/from/to in order');
        }
    }
}

# --- B12: stale filter -- with $now, an event older than now-86400 is -----
# --- dropped; with $now undef, it is kept. ---------------------------------
{
    my $now = 1_800_000_000;
    my @events = ( synth_event(thread => 'drive-tooling', id => '00000003', epoch => $now - 86401, at => iso_of($now - 86401), event => 'resumed') );
    my $runs = [ synth_run(thread_events => \@events) ];
    my $rows_with_now = eval { Dashboard::thread_event_rows($runs, $GM, $now) };
    is(ref($rows_with_now) eq 'ARRAY' ? scalar(@$rows_with_now) : -1, 0, 'AC8/B12: an event older than now-86400 produces no row when $now is given');
    my $rows_no_now = eval { Dashboard::thread_event_rows($runs, $GM, undef) };
    is(ref($rows_no_now) eq 'ARRAY' ? scalar(@$rows_no_now) : -1, 1, 'AC8/B12: the same event is kept when $now is undef');
}

# --- B13: no runs / empty runs / a run with no thread_events key -> a copy
# --- of @events, unchanged, as a NEW arrayref. -----------------------------
{
    my @ev = ( [ { text => '10:00 x', role => 'muted' } ] );
    for my $c ( [ 'undef runs', undef ], [ 'empty runs', [] ], [ 'a run missing thread_events', [ { blueprint => 'x' } ] ] ) {
        my ($label, $runs) = @$c;
        my $merged = eval { Dashboard::merge_thread_events(\@ev, $runs, $GM, undef) };
        is(ref($merged), 'ARRAY', "AC8/B13 [$label]: merge_thread_events returns an arrayref");
        is_deeply($merged, \@ev, "AC8/B13 [$label]: ... is_deeply equal to the input events") if ref($merged) eq 'ARRAY';
        isnt($merged, \@ev, "AC8/B13 [$label]: ... but is a NEW arrayref") if ref($merged) eq 'ARRAY';
    }
}

# --- B10/B11: merge order + cross-source dedup. ----------------------------
{
    my $DAY0 = 1_700_000_000 - (1_700_000_000 % 86400);   # a clean local midnight for this UTC epoch
    sub row_at { my ($hhmm_text, $extra_spans) = @_;
        return [ { text => "$hhmm_text ", role => 'muted' }, @{ $extra_spans || [] } ]; }

    # fleet 'current' rows that LOOK like the real shape row_time_key/the
    # dedup candidate-detector need: >=3 spans, kind = text of span index 2
    # up to the first space.
    my $fleet_orch_start = [ { text => '10:00 ', role => 'muted' }, { text => 'g ', role => 'accent' }, { text => 'orchestrator_start extra', role => 'accent' } ];
    my $fleet_pause_1100 = [ { text => '11:00 ', role => 'muted' }, { text => 'g ', role => 'warn' },   { text => 'pause reason=x', role => 'warn' } ];
    my $fleet_pause_1130 = [ { text => '11:30 ', role => 'muted' }, { text => 'g ', role => 'warn' },   { text => 'pause reason=y', role => 'warn' } ];
    my $hist_row   = [ { text => '09:00 ', role => 'muted' }, { text => 'g ', role => 'muted' }, { text => 'history', role => 'muted' } ];
    my $marker_row = [ { text => '-- previous session (2023-11-14) --', role => 'muted' } ];
    my $cur_1000   = [ { text => '10:10 ', role => 'muted' }, { text => 'g ', role => 'muted' }, { text => 'cur-ten', role => 'muted' } ];

    my @events_fixed = (
        [ 'events', [ $hist_row, $marker_row, $fleet_orch_start, $cur_1000 ] ],
    );
    my @thread_rows = (
        synth_event(thread => 't', id => '00000001', epoch => $DAY0 + 10 * 3600 + 2 * 60, at => iso_of($DAY0 + 10 * 3600 + 2 * 60), event => 'launched'),   # 10:02, within 300s of 10:00 orchestrator_start -> dropped
        synth_event(thread => 't', id => '00000002', epoch => $DAY0 + 10 * 3600 + 20 * 60, at => iso_of($DAY0 + 10 * 3600 + 20 * 60), event => 'resumed'),  # 10:20, resumed never dropped
    );
    my $runs = [ synth_run(thread_events => \@thread_rows) ];
    my $merged = eval { Dashboard::merge_thread_events($events_fixed[0][1], $runs, $GM, undef) };
    ok(ref($merged) eq 'ARRAY', 'AC8/B10-B11 precondition: merge_thread_events does not die') or diag(" error: $@");
  SKIP: {
        skip('died', 4) unless ref($merged) eq 'ARRAY';
        my @texts = map { Dashboard::spans_text($_) } @$merged;
        ok((grep { /history/ } @texts), 'AC8/B10: the history row survives, unchanged, at the front');
        ok((grep { /previous session/ } @texts), 'AC8/B10: the session marker survives, unchanged, at the front');
        is((grep { /launched/ } @texts), 0, 'AC8/B11: the 10:02 "launched" row is dropped (counterpart orchestrator_start within 300s)');
        ok((grep { /resumed/ } @texts), 'AC8/B11: the 10:20 "resumed" row is never dropped (no fleet counterpart kind)');
    }

    # Two fleet pause rows + two thread 'paused' events, each consuming one
    # candidate -> both thread rows dropped.
    my @thread_paused = (
        synth_event(thread => 't', id => '00000003', epoch => $DAY0 + 11 * 3600 + 1 * 60, at => iso_of($DAY0 + 11 * 3600 + 1 * 60), event => 'paused'),   # 11:01
        synth_event(thread => 't', id => '00000004', epoch => $DAY0 + 11 * 3600 + 31 * 60, at => iso_of($DAY0 + 11 * 3600 + 31 * 60), event => 'paused'), # 11:31
    );
    my $runs2 = [ synth_run(thread_events => \@thread_paused) ];
    my $merged2 = eval { Dashboard::merge_thread_events([ $fleet_pause_1100, $fleet_pause_1130 ], $runs2, $GM, undef) };
    ok(ref($merged2) eq 'ARRAY', 'AC8/B11 (pause pairs) precondition: merge_thread_events does not die') or diag(" error: $@");
  SKIP: {
        skip('died', 1) unless ref($merged2) eq 'ARRAY';
        my @texts2 = map { Dashboard::spans_text($_) } @$merged2;
        is((grep { /\bpaused\b/ } @texts2), 0, 'AC8/B11: both thread "paused" rows are dropped, each consuming its own fleet candidate');
    }

    # No thread record appears twice in any merged output (B10's length rule).
    if (ref($merged) eq 'ARRAY') {
        is(scalar(@$merged) <= (scalar(@{ $events_fixed[0][1] }) + scalar(@thread_rows)), 1,
            'AC8: merged length never exceeds events+thread_rows (nothing duplicated)');
    } else {
        fail('AC8: merged length never exceeds events+thread_rows (nothing duplicated) [merge_thread_events did not return an arrayref]');
    }
}

# ===========================================================================
# AC10 -- Dashboard::run wiring: a gather returning runs carrying
# thread_events shows those rows in the Activity panel; a gather with
# runs=>[] shows none of it.
# ===========================================================================
{
    my $ev = synth_event(thread => 'wired-thread', id => '00000001', epoch => 1_700_000_000,
        at => iso_of(1_700_000_000), event => 'resumed');
    my $runs_with = [ synth_run(blueprint => 'wired-bp', thread_events => [$ev]) ];

    sub _drive {
        my (%o) = @_;
        my $clock = 0;
        my @calls;
        eval {
            Dashboard::run(
                color => 0, beat_interval => 9999, state_interval => 0, tick_interval => 0.1,
                max_ticks => 2, title_spinner_period => 9999,
                now => sub { $clock }, sleep_for => sub { $clock += $_[0] },
                read_key => sub { undef }, term_size => sub { (120, 30) },
                gather => sub { { project_name => 'demo', container => 'c1', status => 'running', runs => $o{runs} // [] } },
                heartbeat => sub { 'ok' }, spawn => sub { undef },
                stop_runs => sub { { mode => 'stop-runs', ok => 1, timed_out => 0, stages => [], machine_stopped => 0, others => [], others_known => 0, summary => 'ok' } },
                full_shutdown => sub { { mode => 'full-shutdown', ok => 1, timed_out => 0, stages => [], machine_stopped => 1, others => [], others_known => 1, summary => 'ok' } },
                enter_raw => sub { }, leave_raw => sub { }, keepawake => sub { },
                out => sub { push @calls, $_[0] },
            );
        };
        return (\@calls, $@);
    }

    my ($calls_with, $err_with) = _drive(runs => $runs_with);
    ok(!$err_with, 'AC10: Dashboard::run does not die with a thread-event-carrying run') or diag(" error: $err_with");
    my $joined_with = join('', @$calls_with);
    like($joined_with, qr/resumed/, 'AC10: the thread event text reaches a rendered frame via Dashboard::run');

    my ($calls_without, $err_without) = _drive(runs => []);
    ok(!$err_without, 'AC10: Dashboard::run does not die with runs=>[]');
    my $joined_without = join('', @$calls_without);
    unlike($joined_without, qr/wired-thread|resumed/, 'AC10: with runs=>[], none of the thread-event text appears');
}

# ===========================================================================
# AC14/B17 -- failure isolation: each case makes RunState return normally,
# the affected thread degrades gracefully, siblings are unaffected, and
# nothing warns.
# ===========================================================================
{
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    # (a) thread/ is a plain FILE, not a directory.
    {
        my $P = tempdir(CLEANUP => 1);
        my $root = blueprints_root($P);
        my $dir = make_blueprint($root, 'bp-a');
        make_path(almanac_root($P));
        write_file(almanac_root($P) . '/thread', 'not a directory');
        my ($s, $err) = probe_call('summarize_dir', $dir);
        is($err, '', 'AC14/B17a: thread/ as a plain file does not die');
        is(field($s, 'thread'), undef, 'AC14/B17a: ... -> thread is undef');
    }

    # (b) a thread record over 65536 bytes is skipped.
    {
        my $P = tempdir(CLEANUP => 1);
        my $root = blueprints_root($P);
        my $dir = make_blueprint($root, 'bp-b');
        my $tdir = almanac_root($P) . '/thread';
        make_path($tdir);
        write_file("$tdir/toobig.md", "---\nstate: live\nowner_kind: none\nblueprints: bp-b\n"
            . ('x' x 70000) . "\n---\n");
        my ($s, $err) = probe_call('summarize_dir', $dir);
        is($err, '', 'AC14/B17b: an over-cap thread record does not die');
        is(field($s, 'thread'), undef, 'AC14/B17b: ... -> the oversized thread is skipped (thread undef)');
    }

    # (c) a task record with CR line endings fails to parse; not counted.
    {
        my $P = tempdir(CLEANUP => 1);
        my $root = blueprints_root($P);
        my $dir = make_blueprint($root, 'bp-c');
        write_thread_record($P, 'cr-thread', created => '2023-11-14T00:00:00Z', state => 'live', owner_kind => 'none', blueprints => 'bp-c');
        my $tdir = almanac_root($P) . '/thread-tasks-cr-thread';
        make_path($tdir);
        write_file("$tdir/t1.md", "---\r\ntitle: CR task\r\nstatus: pending\r\n---\r\n");
        my ($s, $err) = probe_call('summarize_dir', $dir);
        is($err, '', 'AC14/B17c: a CR-line-ending task record does not die');
        my $th = field($s, 'thread');
        if (is_hashref($th)) {
            is($th->{total}, 0, 'AC14/B17c: the unparseable CR task counts in neither total');
        } else {
            fail('AC14/B17c: thread is a hashref so total can be checked');
        }
    }

    # (d) more than 512 thread records -> the whole index is empty.
    {
        my $P = tempdir(CLEANUP => 1);
        my $root = blueprints_root($P);
        my $dir = make_blueprint($root, 'bp-d');
        for my $i (1 .. 513) {
            write_thread_record($P, sprintf('t%03d', $i), created => '2023-11-14T00:00:00Z', state => 'live',
                owner_kind => 'none', blueprints => 'bp-d');
        }
        my ($s, $err) = probe_call('summarize_dir', $dir);
        is($err, '', 'AC14/B17d: 513 thread records does not die');
        is(field($s, 'thread'), undef, 'AC14/B17d: ... -> the whole index is empty (thread undef)');
    }

    # (f) a hostile owner_transcript never crashes; activity_at degrades to undef.
    {
        my $P = tempdir(CLEANUP => 1);
        my $root = blueprints_root($P);
        my $dir = make_blueprint($root, 'bp-f');
        write_thread_record($P, 'hostile-thread', created => '2023-11-14T00:00:00Z', state => 'live',
            owner_kind => 'session', owner_id => 'sess-h', owner_transcript => '../../../../etc/passwd', blueprints => 'bp-f');
        my ($s, $err) = probe_call('summarize_dir', $dir);
        is($err, '', 'AC14/B17f: a hostile owner_transcript does not die');
        my $th = field($s, 'thread');
        is(field($th, 'owner') && $th->{owner}{activity_at}, undef, 'AC14/B17f: ... -> activity_at is undef (file does not exist)') if is_hashref($th);
    }

    # (g) a $PID_ALIVE that dies.
    {
        my $P = tempdir(CLEANUP => 1);
        my $root = blueprints_root($P);
        my $dir = make_blueprint($root, 'bp-g');
        write_file("$dir/runs/.orchestrator", "4242\n");
        write_thread_record($P, 'dying-prober', created => '2023-11-14T00:00:00Z', state => 'live',
            owner_kind => 'orchestrator', owner_id => 'bp-g', blueprints => 'bp-g');
        local $RunState::PID_ALIVE = sub { die "boom\n" };
        my ($s, $err) = probe_call('summarize_dir', $dir);
        is($err, '', 'AC14/B17g: a dying $PID_ALIVE does not propagate -- summarize_dir still does not die');
        my $th = field($s, 'thread');
        is(field($th, 'owner') && $th->{owner}{alive}, undef, 'AC14/B17g: ... -> owner.alive degrades to undef') if is_hashref($th);
    }

    is(scalar(@warnings), 0, 'AC14: none of the failure-isolation cases above produced a warning')
        or diag('  warnings: ' . join('; ', @warnings));
}

done_testing();
