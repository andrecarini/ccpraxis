#!/usr/bin/env perl
# 63-run-panel-truth.t — ORACLE for package 04-run-panel-ledger-truth
# (blueprint unified-tui-design-system), specs/04-run-panel-ledger-truth-spec.md.
# Written BLIND to any RunState.pm/launcher.pl implementation of THIS package
# -- directly from the spec's numbered observable behaviours (S3, B1-B34) and
# acceptance criteria (S4, AC-1..AC-27) -- so this file is an oracle, not an
# echo of whatever the implementer eventually writes.
#
# TODAY'S EXPECTED STATE, recorded so a future reader is not surprised:
#   - RunState.pm exists (it is the s10 module from a prior blueprint) but has
#     NOT been extended with this package's ledger-truth / liveness logic yet:
#     summarize_dir is still registry-gated, $RunState::PID_ALIVE does not
#     exist, and `state` only ever produces the 4 legacy values.
#   - launcher.pl has neither a `_pid_alive` sub nor an assignment to
#     `$RunState::PID_ALIVE` yet.
#   Both are read from disk (RunState.pm required as a module; launcher.pl
#   read as source TEXT ONLY) so every section below reports HONESTLY on
#   today's tree rather than aborting compilation.
#
# HARD CONSTRAINTS:
#   * launcher.pl is NEVER require'd/do'ne/executed here -- source-text slurp
#     + regex/brace-balance extraction only, exactly as t/44/t/45/t/62 do.
#   * This file must NOT `use utf8`; the Andre fixture path segment (S5.4) is
#     written as an explicit UTF-8 byte escape ("Andr\xC3\xA9"), never a
#     \x{...} char, exactly like t/45's Andre fixture.
#   * Every fixture lives only under File::Temp::tempdir(CLEANUP => 1).
#     Nothing here reads .ccpraxis-local-data/ (gitignored, does not travel):
#     the 37-vs-79 fixture (AC-13/AC-14) is SYNTHETIC, modelled on the shape
#     of the real sandbox-butler-overhaul registry/ledger mismatch, not read
#     from it.
#   * No whole-shape pins (Decision 15): no is_deeply over the summary
#     struct's key set, no pin on any OPEN-ENDED discovered collection. Every
#     count asserted below is over a fixture this file built and fully
#     controls (the same sense in which t/45's AC-6/AC-24 assert
#     scalar(@$list) == <a fixture-controlled N> without that being a
#     "whole-shape pin" -- the forbidden class is pinning a CLOSED, unrelated
#     set like t/45:293's exact-11-keys assertion, which this file does not
#     repeat).
#   * This file spawns no process, forks nothing, opens no network
#     connection, touches no container.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Time::HiRes ();   # fix-batch MEDIUM-8: wall-clock bound on the gather-tick decode path

my $SCRIPTS_DIR   = "$Bin/../../scripts";
my $RUNSTATE_PATH = "$SCRIPTS_DIR/RunState.pm";
my $LAUNCHER_PATH = "$SCRIPTS_DIR/launcher.pl";
my $DASHBOARD_PATH = "$SCRIPTS_DIR/Dashboard.pm";

# ===========================================================================
# Scaffolding (self-contained -- deliberately not shared with t/45, so this
# oracle does not depend on another test file's internals).
# ===========================================================================

sub write_file {
    my ($path, $content) = @_;
    open my $fh, '>:raw', $path or die "write_file($path): $!";
    print $fh $content;
    close $fh;
}

sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return '';
    local $/;
    my $s = <$fh>;
    close $fh;
    return $s;
}

# --- source-text helpers (launcher.pl is never require'd) -----------------
sub _balanced {
    my ($src, $from) = @_;
    my $brace_idx = index($src, '{', $from);
    return undef if $brace_idx < 0;
    my $depth = 0;
    my $i     = $brace_idx;
    my $len   = length($src);
    for (; $i < $len; $i++) {
        my $c = substr($src, $i, 1);
        if    ($c eq '{') { $depth++; }
        elsif ($c eq '}') { $depth--; last if $depth == 0; }
    }
    return undef if $depth != 0;
    return substr($src, $brace_idx, $i - $brace_idx + 1);
}

sub extract_block {
    my ($src, $start_literal) = @_;
    my $idx = index($src, $start_literal);
    return undef if $idx < 0;
    return _balanced($src, $idx);
}

# --- hand-rolled JSON builder (byte-exact control over keys, no encode()). -
sub json_escape {
    my ($s) = @_;
    $s = '' unless defined $s;
    $s =~ s/([\\"])/\\$1/g;
    $s =~ s/\x00/\\u0000/g;
    $s =~ s/\n/\\n/g;
    $s =~ s/\r/\\r/g;
    $s =~ s/\t/\\t/g;
    return $s;
}
sub json_str { my ($s) = @_; return '"' . json_escape($s) . '"'; }

# registry_json(%pkgs) -> '{"packages":{...}}'. Each value is a plain scalar
# shorthand for {"status":<scalar>}.
sub registry_json {
    my (%pkgs) = @_;
    my @entries;
    for my $k (sort keys %pkgs) {
        push @entries, json_str($k) . ':{"status":' . json_str($pkgs{$k}) . '}';
    }
    return '{"packages":{' . join(',', @entries) . '}}';
}

sub ledger_with_status {
    my ($status) = @_;
    return "---\npackage: x\nstatus: $status\n---\n# ledger body\n";
}

# make_bp($root, $name, %o) -> "$root/$name" (created). %opts:
#   no_runs_dir  => 1                        : skip creating runs/ entirely
#   registry     => <text>                   : write runs/registry.json (any bytes)
#   orchestrator => <text>                    : write runs/.orchestrator
#   paused       => <text>                    : write runs/.paused
#   shutdown     => 1                         : touch runs/.shutdown (empty)
#   packages     => { pkg => <ledger text> }  : writes packages/<pkg>.md
sub make_bp {
    my ($root, $name, %o) = @_;
    my $dir = "$root/$name";
    make_path($dir);
    unless ($o{no_runs_dir}) {
        make_path("$dir/runs");
        write_file("$dir/runs/registry.json", $o{registry})     if exists $o{registry};
        write_file("$dir/runs/.orchestrator",  $o{orchestrator}) if exists $o{orchestrator};
        write_file("$dir/runs/.paused",        $o{paused})       if exists $o{paused};
        write_file("$dir/runs/.shutdown", '') if $o{shutdown};
    }
    if ($o{packages}) {
        make_path("$dir/packages");
        for my $pkg (keys %{ $o{packages} }) {
            write_file("$dir/packages/$pkg.md", $o{packages}{$pkg});
        }
    }
    return $dir;
}

sub is_hashref  { my ($h) = @_; return ref($h) eq 'HASH'; }
sub is_arrayref { my ($h) = @_; return ref($h) eq 'ARRAY'; }
sub field       { my ($h, $k) = @_; return is_hashref($h) ? $h->{$k} : undef; }

# mk_summary(%o) -> a minimal S2.2-shaped literal, defaults filled in.
# (read-only use of Dashboard.pm; no Dashboard.pm edit is part of this
# package, per spec S1.2/S6.1.)
sub mk_summary {
    my (%o) = @_;
    return {
        blueprint            => $o{blueprint} // 'bp',
        runs_dir             => $o{runs_dir} // '/x/runs',
        state                => $o{state} // 'idle',
        orchestrator_pid     => $o{orchestrator_pid},
        paused_manual        => $o{paused_manual} // 0,
        paused_reason        => $o{paused_reason},
        packages_total       => $o{packages_total} // 0,
        packages_done        => $o{packages_done} // 0,
        current_package      => $o{current_package},
        running_coordinators => $o{running_coordinators} // 0,
        decisions_waiting    => $o{decisions_waiting} // 0,
    };
}

# call_rs($fn, @args) -> ($result, $err, \@warnings). Never propagates a die;
# captures warnings so "no warning emitted" (Rule 4) is actually checkable.
sub call_rs {
    my ($fn, @args) = @_;
    my @warns;
    my $res;
    my $err;
    {
        local $SIG{__WARN__} = sub { push @warns, $_[0] };
        $res = eval { no strict 'refs'; &{"RunState::$fn"}(@args) };
        $err = $@;
    }
    $err = '' unless defined $err;
    return ($res, $err, \@warns);
}

# rs($fn, @args) -> just the result, asserting-free convenience wrapper for
# call sites that already intend to check ok(is_hashref/is_arrayref) etc.
sub rs { my ($res) = call_rs(@_); return $res; }

# ===========================================================================
# 0. Load. RunState.pm already exists on disk (prior blueprint); this
#    package extends it. Dashboard.pm is read-only here (AC-22).
# ===========================================================================
use_ok('RunState');
use_ok('Dashboard') or BAIL_OUT('Dashboard.pm did not load');

my $launcher_src = slurp($LAUNCHER_PATH);
ok(length($launcher_src) > 0, 'launcher.pl is readable on disk') or BAIL_OUT("cannot read $LAUNCHER_PATH");

# ===========================================================================
# Section 1 (done-criterion 1 / AC-1, AC-2, AC-3): counts/status/current
# derive from packages/*.md, not runs/registry.json.
# ===========================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $dir = make_bp($root, 'ledger-flagship',
        packages => {
            p1 => ledger_with_status('done'),
            p2 => ledger_with_status('done'),
            p3 => ledger_with_status('done'),
            p4 => ledger_with_status('running'),
            p5 => ledger_with_status('pending'),
        },
        # names only 2 of the 5 ledger packages, PLUS one registry-only key
        # ("aaa-reg-only") that has no ledger file at all and is
        # alphabetically FIRST -- if the implementation ever fell back to a
        # registry-driven join it would wrongly appear as current_package.
        registry => registry_json(p1 => 'pending', p4 => 'pending', 'aaa-reg-only' => 'running'),
    );
    my $s = rs('summarize_dir', $dir);
    is(field($s, 'packages_total'), 5,
        'AC-1: packages_total == 5 (the number of candidate ledger files), regardless of the registry naming only 2');
    is(field($s, 'packages_done'), 3,
        'AC-1: packages_done == 3 (ledger-set packages whose effective status is done)');
    is(field($s, 'current_package'), 'p4',
        'AC-2: current_package is the alphabetically-first RUNNING LEDGER package (p4), never the registry-only "aaa-reg-only"');
    is(field($s, 'packages_total'), 5,
        'AC-3: a ledger present in packages/ but absent from registry.json (p2,p3,p5) still counts toward packages_total');
}

# ===========================================================================
# Section 2 (done-criterion 2 / AC-4..AC-10, AC-21): coordinator liveness.
# ===========================================================================

# Shared fixture for AC-4..AC-7: no packages/ dir at all (falls back to the
# registry key set, S3 behaviour #6, unchanged), a usable registry naming two
# "running" packages, and an .orchestrator marker holding a parseable PID.
my $LIVE_ROOT = tempdir(CLEANUP => 1);
my $LIVE_DIR  = make_bp($LIVE_ROOT, 'coord-bp',
    orchestrator => "555\n",
    registry     => registry_json(p1 => 'running', p2 => 'running', p3 => 'pending'),
);

# --- AC-4: PID_ALIVE => 0 (checked-dead) -> stale, running_coordinators=0. -
{
    local $RunState::PID_ALIVE = sub { 0 };
    my ($s, $err, $warns) = call_rs('summarize_dir', $LIVE_DIR);
    is($err, '', 'AC-4: summarize_dir does not die when the injected prober reports dead');
    is(field($s, 'running_coordinators'), 0, 'AC-4: dead PID -> running_coordinators == 0');
    is(field($s, 'state'), 'stale', 'AC-4: dead PID -> state eq "stale"');
    # AC-7, same fixture: orchestrator_pid is still reported verbatim.
    is(field($s, 'orchestrator_pid'), 555, 'AC-7: orchestrator_pid is unchanged (555) in the stale case -- the panel can name the phantom');
}

# --- AC-5: PID_ALIVE => 1 (alive) -> running, running_coordinators==count. -
{
    local $RunState::PID_ALIVE = sub { 1 };
    my ($s, $err) = call_rs('summarize_dir', $LIVE_DIR);
    is($err, '', 'AC-5: summarize_dir does not die when the injected prober reports alive');
    is(field($s, 'state'), 'running', 'AC-5: alive PID -> state eq "running"');
    is(field($s, 'running_coordinators'), 2, 'AC-5: alive PID -> running_coordinators == 2 (count of running packages)');
}

# --- AC-6: prober not installed / returns undef / dies -> UNKNOWN, treated -
# --- exactly like today (never as dead). None dies or warns. --------------
{
    my @cases = (
        [ 'not installed (undef)', undef ],
        [ 'installed, returns undef', sub { undef } ],
        [ 'installed, dies', sub { die "boom\n" } ],
    );
    for my $c (@cases) {
        my ($label, $prober) = @$c;
        local $RunState::PID_ALIVE = $prober;
        my ($s, $err, $warns) = call_rs('summarize_dir', $LIVE_DIR);
        is($err, '', "AC-6 [$label]: summarize_dir does not die");
        ok(!@$warns, "AC-6 [$label]: summarize_dir does not warn");
        is(field($s, 'state'), 'running', "AC-6 [$label]: unknown liveness -> state behaves exactly as today ('running')");
        is(field($s, 'running_coordinators'), 2, "AC-6 [$label]: unknown liveness -> running_coordinators exactly as today (2), never demoted for an unknown probe");
    }
}

# --- AC-8: launcher.pl's _pid_alive, as SOURCE TEXT, uses kill(0,...) and --
# --- none of the wrong-by-construction command-line-probe spellings. ------
{
    my $body = extract_block($launcher_src, 'sub _pid_alive');
    my $have = defined $body;
    ok($have, 'AC-8: launcher.pl defines sub _pid_alive (extractable as a balanced block)')
        or diag('_pid_alive not found in launcher.pl -- expected until this package lands');

    my $desc_kill = 'AC-8: _pid_alive body contains kill(...)';
    $have ? like($body, qr/\bkill\s*\(/, $desc_kill) : fail("$desc_kill [_pid_alive not found]");

    my @forbidden = (
        [ q{a 'ps ' command-line probe},           qr/\bps\s/ ],
        [ 'tasklist',                               qr/\btasklist\b/i ],
        [ 'pgrep',                                   qr/\bpgrep\b/ ],
        [ 'a backtick character',                    qr/`/ ],
        [ 'qx',                                       qr/\bqx\b/ ],
        [ 'system(',                                   qr/\bsystem\s*\(/ ],
        [ q{open with '-|' (a piped process read)},     qr/open\s*\(?\s*[^,]*,\s*['"]-\|['"]/ ],
    );
    for my $f (@forbidden) {
        my ($label, $qr) = @$f;
        my $desc = "AC-8: _pid_alive body contains none of a wrong-by-construction liveness probe -- specifically no $label "
                 . '(a command-line-substring probe self-matches the prober\'s own command line -- DAME field report batch-1 #11 -- '
                 . 'and it would fork, violating adapter-contract Rule 1)';
        $have ? unlike($body, $qr, $desc) : fail("$desc [_pid_alive not found]");
    }
}

# --- AC-9: launcher.pl assigns $RunState::PID_ALIVE (the injection wire). -
{
    like($launcher_src, qr/\$RunState::PID_ALIVE\s*=/,
        'AC-9: launcher.pl source contains an assignment to $RunState::PID_ALIVE');
}

# --- AC-10: _gather_runs's body still calls RunState::summarize(...) and --
# --- contains no fork/spawn construct (package-local restatement of the --
# --- adapter contract; t/62 is the primary guard). -------------------------
{
    my $body = extract_block($launcher_src, 'sub _gather_runs');
    my $have = defined $body;
    if ($have) {
        like($body, qr/RunState::summarize\s*\(/, 'AC-10: _gather_runs body still calls RunState::summarize(...)');
        unlike($body, qr/`/, 'AC-10: _gather_runs body contains no backtick');
        unlike($body, qr/\bqx\b/, 'AC-10: _gather_runs body contains no qx');
        unlike($body, qr/\bsystem\s*\(/, 'AC-10: _gather_runs body contains no system(');
        unlike($body, qr/\bfork\b/, 'AC-10: _gather_runs body contains no fork');
        unlike($body, qr/open\s*\(?\s*[^,]*,\s*['"]-\|['"]/, "AC-10: _gather_runs body contains no piped open('-|', ...)");
    } else {
        fail('AC-10: _gather_runs body calls RunState::summarize(...) (sub not found)');
    }
}

# --- AC-21: RunState.pm source (comments stripped), package-local ---------
# --- restatement of t/45's AC-8/AC-11 purity scan, so the injection design -
# --- cannot silently regress inside THIS package's own oracle. ------------
{
    my $raw = slurp($RUNSTATE_PATH);
    ok(length($raw) > 0, 'AC-21: RunState.pm exists and is readable on disk') or diag("expected at $RUNSTATE_PATH");
    my $have = length($raw) > 0;
    my $src  = $raw;
    $src =~ s/#[^\n]*//g;

    my @forbidden = (
        [ 'kill',                 qr/\bkill\b/ ],
        [ 'a backtick character', qr/`/ ],
        [ 'qx',                   qr/\bqx\b/ ],
        [ 'system(',              qr/\bsystem\s*\(/ ],
        [ q{open '-|'},           qr/open\s*\(?\s*[^,]*,\s*['"]-\|['"]/ ],
        [ 'glob',                 qr/\bglob\b/ ],
        [ 'time(',                qr/\btime\s*\(/ ],
        [ 'localtime',            qr/\blocaltime\b/ ],
        [ 'gmtime',               qr/\bgmtime\b/ ],
        [ 'print',                qr/\bprint\b/ ],
        [ 'warn',                 qr/\bwarn\b/ ],
        [ 'die',                  qr/\bdie\b/ ],
    );
    for my $f (@forbidden) {
        my ($label, $qr) = @$f;
        my $desc = "AC-21: RunState.pm source (comments stripped) contains no $label";
        $have ? unlike($src, $qr, $desc) : fail("$desc [RunState.pm not on disk]");
    }
}

# ===========================================================================
# Section 3 (done-criterion 3 / AC-11, AC-12): driven entirely outside the
# fleet -- no runs/ at all, ledgers exist -> 'solo', not a phantom paused run.
# ===========================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $dir = make_bp($root, 'solo-bp', no_runs_dir => 1,
        packages => {
            p1 => ledger_with_status('done'),
            p2 => ledger_with_status('running'),
            p3 => ledger_with_status('pending'),
        });
    my $s = rs('summarize_dir', $dir);
    ok(is_hashref($s), 'AC-11: a blueprint with ledgers and NO runs/ directory at all yields a summary, not undef')
        or diag('summarize_dir returned undef/other for a solo-driven blueprint -- the phantom-paused-run regression');
    is(field($s, 'packages_total'), 3, 'AC-11: packages_total == 3 (from the ledgers)');
    is(field($s, 'state'), 'solo', 'AC-11: state eq "solo" -- never a phantom "paused" run');
    is(field($s, 'orchestrator_pid'), undef, 'AC-11: orchestrator_pid undef (no runs/, no marker to read)');
    is(field($s, 'running_coordinators'), 0, 'AC-11: running_coordinators == 0');
    is(field($s, 'decisions_waiting'), 0, 'AC-11: decisions_waiting == 0');

    my $list = rs('summarize', $root);
    ok(is_arrayref($list), 'AC-12: summarize($root) returns an arrayref for the solo-only root');
    my ($found) = is_arrayref($list) ? grep { field($_, 'blueprint') eq 'solo-bp' } @$list : ();
    ok($found, 'AC-12: solo-bp is included in summarize()\'s output -- it is not silently dropped for lacking runs/');
}

# ===========================================================================
# Section 4 (done-criterion 4 / AC-13, AC-14): 37-key registry vs 79 done
# ledgers -> 79/79, modelled on the real sandbox-butler-overhaul mismatch.
# This fixture is SYNTHETIC and self-contained (S5.4) -- nothing here reads
# .ccpraxis-local-data/.
# ===========================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my @all_names = map { sprintf('pkg%03d', $_) } (1 .. 79);
    my %packages = map { $_ => ledger_with_status('done') } @all_names;   # all 79 ledgers: status done

    # The registry names a STRICT SUBSET (the first 37 names), with a status
    # mix modelled on the real registry's "mostly pending, some done" shape
    # -- deliberately at odds with the ledgers' true "done" status, to prove
    # the ledger, not the registry, is authoritative.
    my %registry_statuses;
    for my $i (0 .. 36) {
        $registry_statuses{ $all_names[$i] } = ($i % 5 == 0) ? 'done' : 'pending';
    }
    is(scalar(keys %registry_statuses), 37, 'fixture sanity: the registry names exactly 37 packages');

    my $dir = make_bp($root, 'sandbox-butler-overhaul-shape',
        orchestrator => "424242\n",   # a "stale-looking" marker PID for AC-14
        registry     => registry_json(%registry_statuses),
        packages     => \%packages,
    );

    my $s13 = rs('summarize_dir', $dir);
    is(field($s13, 'packages_total'), 79, 'AC-13: packages_total == 79 (the ledger set), not 37 (the registry key set)');
    is(field($s13, 'packages_done'), 79, 'AC-13: packages_done == 79 (every ledger carries status: done)');

    {
        local $RunState::PID_ALIVE = sub { 0 };   # the recorded coordinator is dead
        my $s14 = rs('summarize_dir', $dir);
        is(field($s14, 'state'), 'stale', 'AC-14: dead-PID coordinator on the 37-vs-79 fixture -> state eq "stale" (no phantom paused/running row)');
        is(field($s14, 'running_coordinators'), 0, 'AC-14: ... -> running_coordinators == 0');
        is(field($s14, 'packages_total'), 79, 'AC-14: ... -> packages_total is STILL 79 (79/79, no phantom run, exactly the reported defect fixed)');
        is(field($s14, 'packages_done'), 79, 'AC-14: ... -> packages_done is STILL 79');
    }
}

# ===========================================================================
# Section 5 (done-criterion 5 / AC-15..AC-20): malformed/absent registry
# degrades to ledger truth, never an error, never a fabricated 0/0.
# ===========================================================================

# --- AC-15: ledgers + runs/ present + NO registry.json at all. ------------
{
    my $root = tempdir(CLEANUP => 1);
    my $dir = make_bp($root, 'no-registry-file',
        orchestrator => "1\n",
        packages     => { a => ledger_with_status('done'), b => ledger_with_status('pending') },
    );   # no `registry =>` key at all -- runs/ exists, registry.json does not
    my ($s, $err, $warns) = call_rs('summarize_dir', $dir);
    is($err, '', 'AC-15: no registry.json at all -> summarize_dir does not die');
    ok(is_hashref($s), 'AC-15: no registry.json at all -> a summary is still produced (not undef)');
    is(field($s, 'packages_total'), 2, 'AC-15: ledger-derived packages_total == 2');
    is(field($s, 'packages_done'), 1, 'AC-15: ledger-derived packages_done == 1');
}

# --- AC-16 / AC-17: ledgers + a registry.json that is broken 4 ways, ------
# --- each independently -> ledger-derived counts, running_coordinators==0, -
# --- no warning (Rule 4). --------------------------------------------------
{
    my @variants = (
        [ 'not json at all',        'not json at all, just prose' ],
        [ 'a JSON array',           '["a","b","c"]' ],
        [ 'empty',                  '' ],
        [ 'over MAX_REGISTRY_BYTES', ('x' x (($RunState::MAX_REGISTRY_BYTES || 4 * 1024 * 1024) + 1024)) ],
    );
    for my $v (@variants) {
        my ($label, $body) = @$v;
        my $root = tempdir(CLEANUP => 1);
        my $dir = make_bp($root, 'broken-registry',
            orchestrator => "1\n",
            registry     => $body,
            packages     => { p1 => ledger_with_status('done'), p2 => ledger_with_status('running'), p3 => ledger_with_status('pending') },
        );
        my ($s, $err, $warns) = call_rs('summarize_dir', $dir);
        is($err, '', "AC-16 [$label]: summarize_dir does not die");
        ok(!@$warns, "AC-17 [$label]: summarize_dir does not warn (Rule 4)");
        ok(is_hashref($s), "AC-16 [$label]: a summary is still produced (ledger truth), not undef");
        is(field($s, 'packages_total'), 3, "AC-16 [$label]: ledger-derived packages_total == 3");
        is(field($s, 'packages_done'), 1, "AC-16 [$label]: ledger-derived packages_done == 1");
        is(field($s, 'running_coordinators'), 0, "AC-17 [$label]: running_coordinators == 0 (the registry is unusable, even though .orchestrator is present and a package is ledger-running)");
    }
}

# --- AC-18: neither a usable ledger set nor a usable registry -> undef, ---
# --- never a fabricated 0/0. -----------------------------------------------
{
    my $root = tempdir(CLEANUP => 1);
    my $dir = make_bp($root, 'nothing-usable');   # runs/ created, no registry.json, no packages/ at all
    my ($s, $err, $warns) = call_rs('summarize_dir', $dir);
    is($err, '', 'AC-18: summarize_dir does not die when neither ledgers nor registry are usable');
    is($s, undef, 'AC-18: summarize_dir returns undef (no data yet) -- never a fabricated 0/0');
    my $list = rs('summarize', $root);
    is_deeply($list, [], 'AC-18: summarize() over that root contributes no row at all for it');
}

# --- AC-19: two blueprints, one corrupt-registry-but-ledgered, one --------
# --- healthy -- both appear, in ascending order, healthy fields intact. ---
{
    my $root = tempdir(CLEANUP => 1);
    make_bp($root, 'aaa-corrupt-registry-with-ledgers',
        orchestrator => "1\n",
        registry     => 'not json at all',
        packages     => { p1 => ledger_with_status('done'), p2 => ledger_with_status('done') },
    );
    make_bp($root, 'zzz-healthy',
        orchestrator => "1\n",
        registry     => registry_json(p1 => 'running'),
        packages     => { p1 => ledger_with_status('running'), p2 => ledger_with_status('done') },
    );

    my $list = rs('summarize', $root);
    ok(is_arrayref($list), 'AC-19: summarize() returns an arrayref for the mixed-health root');
    if (is_arrayref($list)) {
        is(scalar(@$list), 2, 'AC-19: both blueprints appear (the corrupt one degrades to ledger truth rather than vanishing)');
        is_deeply([ map { field($_, 'blueprint') } @$list ], [ 'aaa-corrupt-registry-with-ledgers', 'zzz-healthy' ],
            'AC-19: ascending name order is preserved across the pair');
        my ($corrupt) = grep { field($_, 'blueprint') eq 'aaa-corrupt-registry-with-ledgers' } @$list;
        is(field($corrupt, 'packages_total'), 2, 'AC-19: the corrupt-registry blueprint still reports its ledger-derived packages_total');
        my ($healthy) = grep { field($_, 'blueprint') eq 'zzz-healthy' } @$list;
        is(field($healthy, 'packages_total'), 2, 'AC-19: the healthy sibling\'s fields are intact -- packages_total == 2');
        is(field($healthy, 'packages_done'), 1, "AC-19: the healthy sibling's fields are intact -- packages_done == 1");
        is(field($healthy, 'state'), 'running', "AC-19: the healthy sibling's fields are intact -- state eq 'running'");
    } else {
        fail('AC-19: both blueprints appear, ascending order, healthy fields intact (not an arrayref)');
    }
}

# --- AC-20: totality, including a hostile $PID_ALIVE. ----------------------
{
    for my $c ( [ 'undef', undef ], [ "''", '' ], [ '{}', {} ], [ '[]', [] ], [ "'/no/such/dir'", '/no/such/dir' ] ) {
        my ($label, $arg) = @$c;
        my ($res, $err, $warns) = call_rs('summarize', $arg);
        is($err, '', "AC-20: summarize($label) does not die");
        ok(!@$warns, "AC-20: summarize($label) does not warn");
        is_deeply($res, [], "AC-20: summarize($label) == [] (arrayref, never undef)");

        my ($res2, $err2, $warns2) = call_rs('summarize_dir', $arg);
        is($err2, '', "AC-20: summarize_dir($label) does not die");
        ok(!@$warns2, "AC-20: summarize_dir($label) does not warn");
        is($res2, undef, "AC-20: summarize_dir($label) == undef");
    }

    # A hostile $PID_ALIVE: dies, returns a ref, returns a blessed object,
    # returns a 200-char string. Requires a fixture with a parseable PID so
    # the prober is actually invoked.
    my $root = tempdir(CLEANUP => 1);
    my $dir = make_bp($root, 'hostile-prober-bp',
        orchestrator => "77\n",
        registry     => registry_json(p1 => 'running'),
    );
    my @hostiles = (
        [ 'dies',                     sub { die "boom\n" } ],
        [ 'returns an arrayref',      sub { return [1, 2, 3] } ],
        [ 'returns a blessed object', sub { return bless({}, 'Some::Hostile::Class') } ],
        [ 'returns a 200-char string', sub { return 'x' x 200 } ],
    );
    for my $h (@hostiles) {
        my ($label, $prober) = @$h;
        local $RunState::PID_ALIVE = $prober;
        my ($s, $err, $warns) = call_rs('summarize_dir', $dir);
        is($err, '', "AC-20/AC-31: a hostile \$PID_ALIVE that $label -> summarize_dir does not die");
        ok(!@$warns, "AC-20/AC-31: a hostile \$PID_ALIVE that $label -> summarize_dir does not warn");
        ok(is_hashref($s), "AC-20/AC-31: a hostile \$PID_ALIVE that $label -> summarize_dir still returns a hashref (struct stays valid)");

        my ($list, $err3, $warns3) = call_rs('summarize', $root);
        is($err3, '', "AC-20/AC-31: a hostile \$PID_ALIVE that $label -> summarize(root) does not die");
        ok(!@$warns3, "AC-20/AC-31: a hostile \$PID_ALIVE that $label -> summarize(root) does not warn");
        ok(is_arrayref($list), "AC-20/AC-31: a hostile \$PID_ALIVE that $label -> summarize(root) still returns an arrayref");
    }
}

# ===========================================================================
# Section 6 (done-criteria 3 & 4 / AC-22): Dashboard renders the two new
# state values verbatim as muted, with NO Dashboard.pm change needed.
# ===========================================================================
{
    for my $state (qw(stale solo)) {
        my @lines = eval { Dashboard::_run_lines([ mk_summary(blueprint => 'b', state => $state) ]) };
        ok(!$@, "AC-22: Dashboard::_run_lines does not die rendering state=>'$state'");
        my $line = $lines[0];
        my $state_span = (ref($line) eq 'ARRAY') ? $line->[1] : undef;
        is(ref($state_span) eq 'HASH' ? $state_span->{text} : undef, $state,
            "AC-22: state=>'$state' -- span 2 text is the state verbatim (no Dashboard.pm change needed)");
        is(ref($state_span) eq 'HASH' ? $state_span->{role} : undef, 'muted',
            "AC-22: state=>'$state' -- span 2 role is 'muted' (Dashboard's existing unknown-state fallback)");
    }
}

# ===========================================================================
# Section 7 (S5.4): non-ASCII / space-bearing path segment. Explicit UTF-8
# byte escape, no `use utf8`.
# ===========================================================================
{
    my $base = tempdir(CLEANUP => 1);
    my $andre_root = "$base/Andr\xC3\xA9 space test root";
    my $dir = make_bp($andre_root, 'bp', no_runs_dir => 1,
        packages => { p1 => ledger_with_status('done'), p2 => ledger_with_status('running') });
    my ($s, $err, $warns) = call_rs('summarize_dir', $dir);
    is($err, '', 'S5.4: a packages/ fixture under an explicit-UTF-8-bytes + space path segment does not die');
    ok(!@$warns, 'S5.4: ... does not warn');
    ok(is_hashref($s), 'S5.4: ... yields a summary');
    is(field($s, 'packages_total'), 2, 'S5.4: ... packages_total == 2');
    is(field($s, 'state'), 'solo', 'S5.4: ... state eq "solo" (no runs/ dir, ledgers present)');
}

# ===========================================================================
# Section 8 (consolidated fix-batch, HIGH-2): the GOVERNING RULE, as a
# property over a table of malformed-ledger shapes, not a handful of
# one-off cases. "the registry is consulted only when the ledger file is
# ABSENT -- never when it is present but unparseable." Every shape below
# writes a REAL packages/p1.md file (the ledger is PRESENT); the registry
# entry for p1 is a CONTRADICTING 'running' status. A correct implementation
# must never adopt that contradicting registry value for p1 -- p1 must
# report as neither done nor running, and must never be fabricated as
# current_package. Each shape is one proven door from redteam.md HIGH-2 (or
# its "further doors" table), plus LOW-13's neighbour "no status: line at
# all" (HIGH-2's own mitigation text: "When a ledger file exists but yields
# no status, return ''" -- the same rule, not a separate case).
# ===========================================================================
{
    my @MALFORMED_LEDGER_SHAPES = (
        [ 'CRLF line endings',            "---\r\npackage: x\r\nstatus: done\r\n---\r\n" ],
        [ 'UTF-8 BOM before opening ---', "\xEF\xBB\xBF---\npackage: x\nstatus: done\n---\n" ],
        [ 'leading blank line',           "\n---\npackage: x\nstatus: done\n---\n" ],
        [ 'YAML-quoted status',           qq{---\npackage: x\nstatus: "done"\n---\n} ],
        [ 'trailing-comment status',      "---\npackage: x\nstatus: done  # shipped\n---\n" ],
        [ 'status line over 1024 chars',  "---\npackage: x\nstatus: done" . (' ' x 1100) . "\n---\n" ],
        [ 'zero-byte ledger',             '' ],
        [ 'over MAX_LEDGER_BYTES',        ('x' x (($RunState::MAX_LEDGER_BYTES || 65536) + 1024)) ],
        [ 'no status: line at all',       "---\npackage: x\nno-status-here: true\n---\n" ],
    );
    for my $shape (@MALFORMED_LEDGER_SHAPES) {
        my ($label, $content) = @$shape;
        my $root = tempdir(CLEANUP => 1);
        my $dir = make_bp($root, 'malformed-shape',
            orchestrator => "1\n",
            registry     => registry_json(p1 => 'running', p2 => 'pending', p3 => 'pending'),
            packages     => {
                p1 => $content,                     # PRESENT, unparseable -- registry CONTRADICTS with 'running'
                p2 => ledger_with_status('done'),
                p3 => ledger_with_status('done'),
            });
        my $s = rs('summarize_dir', $dir);
        is(field($s, 'packages_total'), 3, "HIGH-2 [$label]: packages_total == 3 (all three are ledger candidates -- p1's file exists on disk)");
        is(field($s, 'packages_done'), 2, "HIGH-2 [$label]: packages_done == 2 (p2,p3 only) -- p1's malformed-but-PRESENT ledger must not adopt the registry's contradicting 'running'/'done' claim");
        is(field($s, 'current_package'), undef, "HIGH-2 [$label]: current_package is undef -- p1 must NOT be fabricated as the currently-running package from the registry, because its ledger file is PRESENT (governing rule: the registry is consulted only when the ledger file is ABSENT)");
        is(field($s, 'running_coordinators'), 0, "HIGH-2 [$label]: running_coordinators == 0 -- p1's contradicting registry 'running' status must not be adopted just because its ledger failed to parse");
    }

    # Counterpart, so the fix is not overshooting: when packages/ has ZERO
    # ledger candidates (no packages/ dir at all -- true ABSENCE, not
    # unparseability), the registry fallback must still fire exactly as
    # before (this is Section 2's LIVE_DIR fixture, restated locally here so
    # the pairing with the property test above is visible in one place).
    {
        my $root = tempdir(CLEANUP => 1);
        my $dir = make_bp($root, 'truly-absent-ledger',
            orchestrator => "1\n",
            registry     => registry_json(p1 => 'running'));   # no `packages =>` key at all
        my $s = rs('summarize_dir', $dir);
        is(field($s, 'running_coordinators'), 1,
            'HIGH-2 governing-rule counterpart: when packages/ has ZERO candidates (the directory itself is absent), the registry fallback still fires -- ABSENCE, not unparseability, is what licenses adopting the registry');
    }
}

# ===========================================================================
# Section 9 (consolidated fix-batch, HIGH-3 / reviewer MINOR / LOW-15):
# _orchestrator_pid must not fabricate a plausible-looking PID by truncating
# an unanchored digit match out of unrelated content. RunState.pm:191's
# `/(\d{1,10})/` is unanchored; the anchored fix must yield undef for
# anything whose FIRST bytes are not themselves a bare digit run, matching
# bp-orchestrator.pl's own anchored `/^(\d+)/` reader (bp-orchestrator.pl:
# 1553 read_marker_pid) -- both files read the SAME marker file and must not
# silently disagree about what PID it names.
# ===========================================================================
{
    my @cases = (
        [ 'a JSON blob with an embedded "pid" field', qq{{"run":"20260807053712","pid":18979}}, undef ],
        [ 'a header comment line before the bare PID', "# orchestrator started 2026-08-07\n18979\n", undef ],
        [ 'a 12-digit run (over the 10-digit bound)',  "123456789012\n", undef ],
        [ 'a negative-looking marker',                 "-5\n", undef ],
        [ 'a bare PID (the legitimate writer contract)', "18979\n", 18979 ],
    );
    for my $c (@cases) {
        my ($label, $content, $expect) = @$c;
        my $root = tempdir(CLEANUP => 1);
        my $dir = make_bp($root, 'pid-fab', orchestrator => $content, registry => registry_json());
        my $s = rs('summarize_dir', $dir);
        is(field($s, 'orchestrator_pid'), $expect,
            "HIGH-3 [$label]: orchestrator_pid is " . (defined $expect ? $expect : 'undef')
            . ' -- never a truncated/fabricated prefix of unrelated digits (a fabricated PID is then fed to the liveness prober, which is how a dead run reads as live or a live one reads as dead)');
    }

    # Marker-format contract: RunState must never DISAGREE with
    # bp-orchestrator.pl's own anchored reader about whether a marker names
    # a PID AT ALL -- mirrored here (not required: bp-orchestrator.pl is a
    # different plugin and this file must not load it), same technique as
    # t/45's mirror_count_needs_you.
    my $mirror_read_marker_pid = sub {
        my ($blob) = @_;
        return undef unless defined $blob;
        return ($blob =~ /^(\d+)/) ? ($1 + 0) : undef;
    };
    my @agree_cases = ( "18979\n", '', "not-a-pid\n", qq{{"pid":18979}}, "# comment\n18979\n", "-5\n" );
    for my $content (@agree_cases) {
        my $mirror_is_pid = defined($mirror_read_marker_pid->($content)) ? 1 : 0;
        my $root = tempdir(CLEANUP => 1);
        my $dir = make_bp($root, 'pid-contract', orchestrator => $content, registry => registry_json());
        my $s = rs('summarize_dir', $dir);
        my $rs_is_pid = defined(field($s, 'orchestrator_pid')) ? 1 : 0;
        (my $shown = $content) =~ s/\n/\\n/g;
        is($rs_is_pid, $mirror_is_pid,
            "HIGH-3 marker-format contract: RunState and bp-orchestrator.pl's own anchored /^(\\d+)/ reader agree on whether \"$shown\" names a PID at all");
    }
}

# ===========================================================================
# Section 10 (consolidated fix-batch, CRITICAL-1): a container-written PID
# cannot be probed from the host. bp-orchestrator.pl's PID is written INSIDE
# the container; launcher.pl passes no --pid=host, so kill(0,...) on the
# host probing a live container PID returns ESRCH -- a LIVE fleet reads
# 'stale' and running_coordinators is forced to 0. Binding driver ruling:
# liveness of a container-written PID cannot be determined from the host
# without spawning (forbidden on the render tick), so it must degrade to an
# honest UNKNOWN, never a confident "dead". Source-only: launcher.pl is
# never require'd/executed here (hard constraint), and a live container PID
# cannot be constructed on this host either -- this is necessarily a source
# pin, per the redteam's own admission for this finding.
# ===========================================================================

# --- (a) _pid_alive's fallback branch (every case this host cannot prove --
# --- is its own process) must yield undef, never a bare checked-dead 0. --
{
    my $body = extract_block($launcher_src, 'sub _pid_alive');
    my $have = defined $body;
    ok($have, 'CRITICAL-1: launcher.pl defines sub _pid_alive (extractable as a balanced block)')
        or diag('_pid_alive not found in launcher.pl');

    if ($have) {
        my ($after_eperm) = $body =~ /EPERM[^\n]*\}(.*)\z/s;
        ok(defined $after_eperm, 'CRITICAL-1: located the fallback branch of _pid_alive, reached after the EPERM check')
            or diag("could not locate the branch reached after the EPERM check -- _pid_alive body:\n$body");
        if (defined $after_eperm) {
            unlike($after_eperm, qr/return\s+0\s*;/,
                'CRITICAL-1: the fallback branch (a PID this host cannot prove is its own -- e.g. a live CONTAINER orchestrator PID in a private PID namespace, where kill(0,...) returns ESRCH) does NOT return a bare checked-dead 0 -- that fabricates certainty the host does not have, and reads a live fleet as "stale" (near-certain in production, redteam CRITICAL-1 Effect A)');
            like($after_eperm, qr/return\s+undef\s*;/,
                'CRITICAL-1: the fallback branch instead returns undef (UNKNOWN) -- binding driver ruling: never a confident "dead" for a PID whose namespace this host cannot verify');
        } else {
            fail('CRITICAL-1: fallback branch does not return a bare 0 (EPERM branch not located)');
            fail('CRITICAL-1: fallback branch returns undef instead (EPERM branch not located)');
        }
    } else {
        fail('CRITICAL-1: fallback branch does not return a bare 0 (_pid_alive not found)');
        fail('CRITICAL-1: fallback branch returns undef instead (_pid_alive not found)');
    }
}

# --- (b) quiet_probe's stop-path regression guard. NOT expected to go red -
# --- today -- see report: this OR-clause already exists in the source, and -
# --- is what makes (a)'s fix load-bearing rather than merely cosmetic. It -
# --- is recorded so a future edit cannot silently strip it and reopen ------
# --- CRITICAL-1's Effect C (a live fleet becomes stoppable) even after (a) -
# --- lands -- MEDIUM-6 shows running_coordinators alone can independently -
# --- read 0 while a coordinator is genuinely running. -----------------------
{
    my $body = extract_block($launcher_src, 'quiet_probe     => sub {');
    ok(defined $body, 'CRITICAL-1(b): the quiet_probe closure is extractable from launcher.pl');
    if (defined $body) {
        like($body, qr/\$s->\{state\}\s*eq\s*['"]running['"]/,
            'CRITICAL-1(b): quiet_probe\'s $running computation checks state eq "running" -- not running_coordinators alone (MEDIUM-6: that field can independently read 0 while a coordinator is genuinely running, e.g. an unusable registry)');
        like($body, qr/running_coordinators/,
            'CRITICAL-1(b): quiet_probe\'s $running computation also checks running_coordinators (belt-and-suspenders, not instead-of state)');
    } else {
        fail('CRITICAL-1(b): quiet_probe checks state eq "running" (closure not found)');
        fail('CRITICAL-1(b): quiet_probe also checks running_coordinators (closure not found)');
    }
}

# ===========================================================================
# Section 11 (consolidated fix-batch, MEDIUM-8): the $MAX_PACKAGES
# cardinality guard must be reachable BEFORE the JSON::PP decode of
# registry.json, not after -- otherwise a cap-compliant-BY-BYTES but
# cardinality-hostile registry costs a multi-second pure-Perl decode on
# every 10s gather tick (adapter Rule 1: never block the render tick).
# Necessarily a timing assertion -- the defect itself IS a timing defect --
# with a threshold well under the ~3.49s the redteam measured for the
# decode-then-reject order, to stay robust on a slower CI host.
# ===========================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $n = 120_000;
    my @parts;
    for my $i (1 .. $n) {
        push @parts, sprintf('"pkg%06d":{"status":"pending"}', $i);
    }
    my $huge_registry = '{"packages":{' . join(',', @parts) . '}}';
    ok(length($huge_registry) < ($RunState::MAX_REGISTRY_BYTES || 4 * 1024 * 1024),
        'MEDIUM-8 fixture sanity: the huge registry is BYTE-cap-compliant (would reach the JSON::PP decode under a byte-only check)');
    ok($n > ($RunState::MAX_PACKAGES || 512),
        'MEDIUM-8 fixture sanity: its key count exceeds $MAX_PACKAGES (the cardinality guard must eventually reject it)');
    my $dir = make_bp($root, 'huge-cardinality-registry', orchestrator => "1\n", registry => $huge_registry);

    my $t0 = [ Time::HiRes::gettimeofday() ];
    my $s = rs('summarize_dir', $dir);
    my $elapsed = Time::HiRes::tv_interval($t0);
    ok($elapsed < 1.0,
        sprintf('MEDIUM-8: a cap-compliant-by-bytes (%d bytes) but cardinality-hostile (%d keys) registry is rejected in under 1s (took %.3fs) -- the cardinality guard must run BEFORE the pure-Perl JSON::PP decode, not after it (redteam measured 3.49s when decode precedes the reject)',
            length($huge_registry), $n, $elapsed));
}

# ===========================================================================
# Section 12 (consolidated fix-batch, MEDIUM-7 + MEDIUM-5): per-package
# coordinator PIDs are never liveness-checked at all, and a stray
# non-ledger .md file in packages/ inflates packages_total permanently.
# ===========================================================================

# --- MEDIUM-7: a per-package registry PID that is checked-dead must not ---
# --- count toward running_coordinators, even though its status is        -
# --- 'running' and the orchestrator itself is alive. -----------------------
{
    my $root = tempdir(CLEANUP => 1);
    my $registry = '{"packages":{"p1":{"status":"running","pid":999},"p2":{"status":"running","pid":1000}}}';
    my $dir = make_bp($root, 'per-pkg-liveness', orchestrator => "1\n", registry => $registry);
    local $RunState::PID_ALIVE = sub {
        my ($pid) = @_;
        return 1 if $pid == 1;      # the orchestrator's own PID (alive)
        return 0 if $pid == 999;    # p1's recorded coordinator: checked DEAD
        return 1 if $pid == 1000;   # p2's recorded coordinator: checked alive
        return undef;
    };
    my $s = rs('summarize_dir', $dir);
    is(field($s, 'running_coordinators'), 1,
        'MEDIUM-7: running_coordinators == 1 (p2 only) -- a per-package registry pid that is checked-dead (p1, pid 999) must not be counted, even though its recorded status is "running" and the orchestrator itself is alive; today NO per-package PID is ever probed at all, so this fixture would wrongly report 2');
}

# --- MEDIUM-5: a stray non-ledger .md file in packages/ must not inflate --
# --- packages_total permanently. -------------------------------------------
{
    my $root = tempdir(CLEANUP => 1);
    my $dir = make_bp($root, 'stray-md', no_runs_dir => 1,
        packages => {
            p1       => ledger_with_status('done'),
            p2       => ledger_with_status('done'),
            p3       => ledger_with_status('done'),
            README   => "# Notes\nThis is not a ledger, just a README someone dropped in packages/.\n",
            TEMPLATE => "# Template\nCopy me to create a new package ledger.\n",
        });
    my $s = rs('summarize_dir', $dir);
    is(field($s, 'packages_total'), 3,
        'MEDIUM-5: packages_total == 3 -- a stray README.md/TEMPLATE.md sitting in packages/ (no frontmatter -- not a ledger) must not inflate the denominator, even though its filename ends in .md and it is a plain, readable file');
    is(field($s, 'packages_done'), 3, 'MEDIUM-5: packages_done == 3 -- all three real ledgers are still counted done, unaffected by the stray files');
}

# ===========================================================================
# Section 13 (consolidated fix-batch, HIGH-4): a ledger set over
# $MAX_PACKAGES must degrade HONESTLY -- never silently substitute the
# registry's single contradicting key for the true (much larger)
# ledger-derived count.
# ===========================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $max = $RunState::MAX_PACKAGES || 512;
    my %packages;
    $packages{ sprintf('pkg%04d', $_) } = ledger_with_status('done') for (1 .. $max + 1);
    my $dir = make_bp($root, 'over-cap-ledgers', orchestrator => "1\n",
        registry => registry_json('lonely-reg-key' => 'pending'),
        packages => \%packages);
    my $s = rs('summarize_dir', $dir);
    is($s, undef,
        'HIGH-4: a ledger set of ' . ($max + 1) . " (over \$MAX_PACKAGES=$max) must yield NO row (undef) -- never the registry's single 'lonely-reg-key' silently substituted as a fabricated 1-package truth for what is really a " . ($max + 1) . '-package, all-done blueprint');
}

done_testing();
