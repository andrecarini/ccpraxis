#!/usr/bin/env perl
# agent-telemetry package 04-runstate-run-and-package-facts: orchestrator
# liveness/start-time, per-package attempts, pipeline step, and next action
# on RunState::summarize_dir's return hash.
#
# THIS FILE IS THE IMMUTABLE ORACLE for that package
# (specs/04-runstate-run-and-package-facts-spec.md). It is written BLIND to
# any RunState.pm implementation of the new surface -- directly from the
# spec plus driver rulings AT-4 (three new keys: packages, orchestrator_alive,
# orchestrator_started_at -- 13 -> 16) and AT-5 (orchestrator_started_at is a
# TIMESTAMP, never a computed uptime; RunState must never read a clock).
#
# None of _reg_count / _attempt_cap / _parse_pipeline / _parse_next_action /
# _ledger_facts / _mtime / orchestrator_alive / orchestrator_started_at exist
# on disk yet (verified before writing this file) -- every assertion below is
# EXPECTED to fail for "key missing" / "sub not found" reasons until the
# implementer lands the package, not for syntax or fixture-scaffolding
# reasons.
#
# Coverage: B1-B22 (spec S3) via AC4-AC41 (spec S4). AC41 (t/45-run-state.t
# whole-suite-green) is deliberately NOT encoded here -- it is a
# coordinator-side check, exactly as t/45 itself excludes its own AC-27 and
# the rationale documented there ("AC-27 ... is deliberately NOT encoded
# here -- it is a coordinator-side check").
#
# Hard constraints honoured here (mirrors t/45's stated locale rules):
#   * this file MUST NOT `use utf8`; the André / café fixtures are written as
#     explicit UTF-8 byte escapes ("Andr\xC3\xA9", "\xC3\xA9"), never as
#     \x{...} chars.
#   * RunState.pm is never require'd except via use_ok (same as t/45); no
#     other implementation file in the package's write set is read by this
#     file, and none of its internals are consulted beyond the pinned
#     private-sub names the spec itself names.
#   * every fixture is built under File::Temp::tempdir (CLEANUP => 1).
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Encode qw(decode);

my $SCRIPTS_DIR   = "$Bin/../../scripts";
my $RUNSTATE_PATH = "$SCRIPTS_DIR/RunState.pm";
my $T45_PATH      = "$Bin/45-run-state.t";

use constant SPEC_MAX_REGISTRY_BYTES => 4 * 1024 * 1024;
use constant SPEC_MAX_LEDGER_BYTES   => 65536;
use constant SPEC_MAX_MARKER_BYTES   => 4096;
use constant SPEC_MAX_PACKAGES       => 512;

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
    open my $fh, '<:raw', $path or return '';
    local $/;
    my $s = <$fh>;
    close $fh;
    return $s;
}

# --- $FAILED sentinel + probe helpers (t/45's pattern, verbatim rationale):
# a missing sub/module degrades to a clean per-assertion FAIL, never a
# spurious PASS and never a file-aborting die. ----------------------------
my $FAILED = bless { t184 => 'call did not happen' }, 'T184::CallFailed';

sub probe_call {
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
sub RS {
    my ($res, $err) = probe_call(@_);
    return $FAILED if $err ne '';
    return $res;
}

sub probe_list {
    my ($fn, @args) = @_;
    my @warns;
    my @res;
    my $err;
    {
        local $SIG{__WARN__} = sub { push @warns, $_[0] };
        @res = eval { no strict 'refs'; &{"RunState::$fn"}(@args) };
        $err = $@;
    }
    $err = '' unless defined $err;
    return (\@res, $err, \@warns);
}
sub RS_LIST {
    my ($res, $err) = probe_list(@_);
    return ($FAILED) if $err ne '';
    return @$res;
}

sub is_hashref  { my ($h) = @_; return ref($h) eq 'HASH'; }
sub is_arrayref { my ($h) = @_; return ref($h) eq 'ARRAY'; }
sub field       { my ($h, $k) = @_; return is_hashref($h) ? $h->{$k} : $FAILED; }

# is_real_str($v) -> 1|0. True only for a defined, UNBLESSED, non-ref
# scalar. Every assertion below that inspects a STRING'S PROPERTIES (byte
# content, length, regex match) rather than comparing it for exact equality
# must gate on this first -- otherwise, when the field is genuinely absent
# and field() returns the blessed $FAILED sentinel, Perl happily
# stringifies that ref to something like "T184::CallFailed=HASH(0x...)",
# which is short, has no embedded newline, has no control bytes, and IS
# valid UTF-8 -- so a naive length/regex/byte check on it would spuriously
# PASS before the feature exists at all. Exact-value `is($x, 'literal')` /
# `is_deeply` assertions elsewhere do not need this guard: the sentinel's
# stringification never equals a literal expected string or arrayref.
sub is_real_str { my ($v) = @_; return defined($v) && !ref($v); }

sub find_pkg {
    my ($s, $name) = @_;
    return $FAILED unless is_hashref($s) && is_arrayref($s->{packages});
    for my $e (@{ $s->{packages} }) {
        return $e if ref($e) eq 'HASH' && defined($e->{name}) && $e->{name} eq $name;
    }
    return undef;
}

# --- JSON literal builder (hand-rolled, byte-exact -- same rationale as ---
# --- t/45: control over non-ASCII/NUL package keys without `use utf8`). --
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
sub RAW_JSON { my ($json) = @_; return { __raw_json => 1, json => $json }; }

# registry_json(%pkgs) -> '{"packages":{...}}'. Each value is either:
#  - a plain scalar          : shorthand for {"status":<scalar>}
#  - RAW_JSON(...)           : used verbatim (malformed/non-object entries)
#  - a hashref {status=>,pid=>,attempt=>,turn_continuations=>,rate_limit_discounts=>}
#    : only the keys present are emitted, numerics emitted unquoted.
sub registry_json {
    my (%pkgs) = @_;
    my @entries;
    for my $k (sort keys %pkgs) {
        my $v = $pkgs{$k};
        my $val_json;
        if (ref($v) eq 'HASH' && $v->{__raw_json}) {
            $val_json = $v->{json};
        }
        elsif (ref($v) eq 'HASH') {
            my @fields;
            push @fields, '"status":' . json_str($v->{status})            if exists $v->{status};
            push @fields, '"pid":' . (defined($v->{pid}) ? ($v->{pid} + 0) : 'null')                       if exists $v->{pid};
            push @fields, '"attempt":' . (defined($v->{attempt}) ? $v->{attempt} : 'null')                  if exists $v->{attempt};
            push @fields, '"turn_continuations":' . (defined($v->{turn_continuations}) ? $v->{turn_continuations} : 'null') if exists $v->{turn_continuations};
            push @fields, '"rate_limit_discounts":' . (defined($v->{rate_limit_discounts}) ? $v->{rate_limit_discounts} : 'null') if exists $v->{rate_limit_discounts};
            $val_json = '{' . join(',', @fields) . '}';
        }
        else {
            $val_json = '{"status":' . json_str($v) . '}';
        }
        push @entries, json_str($k) . ':' . $val_json;
    }
    return '{"packages":{' . join(',', @entries) . '}}';
}

# make_blueprint($root, $name, %opts) -> "$root/$name" (created). %opts:
#   no_runs_dir        => 1                        : skip creating runs/ entirely
#   registry            => <text>                   : write runs/registry.json (any bytes)
#   orchestrator        => <text>                   : write runs/.orchestrator
#   shutdown            => 1                         : touch runs/.shutdown (empty)
#   packages             => { pkg => <ledger text> } : writes packages/<pkg>.md
#   empty_packages_dir   => 1                         : make packages/ with nothing in it
sub make_blueprint {
    my ($root, $name, %o) = @_;
    my $dir = "$root/$name";
    make_path($dir);
    unless ($o{no_runs_dir}) {
        make_path("$dir/runs");
        write_file("$dir/runs/registry.json",  $o{registry})     if exists $o{registry};
        write_file("$dir/runs/.orchestrator",  $o{orchestrator}) if exists $o{orchestrator};
        write_file("$dir/runs/.shutdown", '') if $o{shutdown};
    }
    if ($o{packages}) {
        make_path("$dir/packages");
        for my $pkg (keys %{ $o{packages} }) {
            write_file("$dir/packages/$pkg.md", $o{packages}{$pkg});
        }
    }
    if ($o{empty_packages_dir}) {
        make_path("$dir/packages");
    }
    return $dir;
}

# checkbox_lines(%marks) -> 8 lines "- [<mark>] N. Step N title", mark ' '
# unless overridden in %marks (keyed by step number 1..8).
sub checkbox_lines {
    my (%marks) = @_;
    my @out;
    for my $n (1 .. 8) {
        my $m = exists $marks{$n} ? $marks{$n} : ' ';
        push @out, "- [$m] $n. Step $n title";
    }
    return @out;
}

# A ledger with frontmatter + an eight-step Pipeline (given marks) + a Next
# action section (given text, or omitted if undef).
sub mk_ledger {
    my (%o) = @_;
    my $status = $o{status};
    my @lines = ('---', 'package: x');
    push @lines, "status: $status" if defined $status;
    push @lines, ('---', '# ledger body', '');
    if ($o{pipeline}) {
        push @lines, ('## Pipeline', '', checkbox_lines(%{ $o{marks} // {} }), '');
    }
    if (defined $o{next_action}) {
        push @lines, ('## Next action', '', $o{next_action}, '');
    }
    return join("\n", @lines) . "\n";
}

# ===========================================================================
# Shape helpers
# ===========================================================================
my @SUMMARY_KEYS_16 = qw(
    blueprint runs_dir state orchestrator_pid orchestrator_alive orchestrator_started_at
    paused_manual paused_reason packages_total packages_done current_package
    running_coordinators decisions_waiting decisions_operator decisions_triage packages
);
my @PKG_KEYS_7 = qw(name status attempt attempt_cap step steps_pending next_action);

sub assert_16_keys {
    my ($s, $label) = @_;
    ok(is_hashref($s), "$label: summary is a hashref") or return;
    is_deeply([ sort keys %$s ], [ sort @SUMMARY_KEYS_16 ], "$label: AC1 -- exactly the 16 S2.1 keys, no more, no fewer");
}

sub assert_pkg_shape {
    my ($e, $label) = @_;
    ok(is_hashref($e), "$label: package entry is a hashref") or return;
    is_deeply([ sort keys %$e ], [ sort @PKG_KEYS_7 ], "$label: AC28 -- exactly the 7 S2.2 keys, 'agents' absent");
}

sub assert_new_key_types {
    my ($s, $label) = @_;
    return unless is_hashref($s);
    ok(!defined($s->{orchestrator_alive}) || $s->{orchestrator_alive} == 0 || $s->{orchestrator_alive} == 1,
        "$label: AC3 -- orchestrator_alive is 1, 0, or undef");
    ok(!defined($s->{orchestrator_started_at})
        || ($s->{orchestrator_started_at} =~ /\A\d+\z/ && $s->{orchestrator_started_at} > 0),
        "$label: AC3 -- orchestrator_started_at is undef or matches /\\A\\d+\\z/ and is > 0");
    ok(is_arrayref($s->{packages}), "$label: AC3 -- packages is always an ARRAY ref, defined, even for empty runs");
}

# ===========================================================================
# 0. Load.
# ===========================================================================
use_ok('RunState');

# ===========================================================================
# 1. Module contract -- AC38, AC39, AC40.
# ===========================================================================
{
    my $rc_out = `"$^X" -I "$SCRIPTS_DIR" -c "$RUNSTATE_PATH" 2>&1`;
    my $rc = $? >> 8;
    is($rc, 0, 'AC38: `perl -c` on RunState.pm exits 0') or diag("  output: $rc_out");
}
{
    my $raw = slurp($RUNSTATE_PATH);
    ok(length($raw) > 0, 'AC39 precondition: RunState.pm exists and is readable on disk') or diag("expected at $RUNSTATE_PATH");
    my $have = (length($raw) > 0);
    my $src  = $raw;
    $src =~ s/#[^\n]*//g;    # strip #-to-end-of-line comments

    my @forbidden = (
        [ 'kill',                 qr/\bkill\b/ ],
        [ 'a backtick character', qr/`/ ],
        [ 'qx',                   qr/\bqx\b/ ],
        [ 'system(',              qr/\bsystem\s*\(/ ],
        [ q{open '-|'},           qr/open\s*\(?\s*[^,]*,\s*['"]-\|['"]/ ],
        [ 'glob',                 qr/\bglob\b/ ],
        [ 'print',                qr/\bprint\b/ ],
        [ 'warn',                 qr/\bwarn\b/ ],
        [ 'die',                  qr/\bdie\b/ ],
        [ 'time(',                qr/\btime\s*\(/ ],
        [ 'localtime',            qr/\blocaltime\b/ ],
        [ 'gmtime',               qr/\bgmtime\b/ ],
        [ 'Exporter/@EXPORT',     qr/\b(?:Exporter|\@EXPORT)\b/ ],
    );
    for my $f (@forbidden) {
        my ($label, $qr) = @$f;
        my $desc = "AC39: RunState.pm source (comments stripped) contains no $label -- no new clock read, no I/O";
        $have ? unlike($src, $qr, $desc) : fail("$desc [RunState.pm not on disk]");
    }
}
{
    is($RunState::MAX_REGISTRY_BYTES, SPEC_MAX_REGISTRY_BYTES, 'AC40: $RunState::MAX_REGISTRY_BYTES == 4 MiB (unchanged)');
    is($RunState::MAX_LEDGER_BYTES,   SPEC_MAX_LEDGER_BYTES,   'AC40: $RunState::MAX_LEDGER_BYTES == 64 KiB (unchanged)');
    is($RunState::MAX_MARKER_BYTES,   SPEC_MAX_MARKER_BYTES,   'AC40: $RunState::MAX_MARKER_BYTES == 4096 (unchanged)');
    is($RunState::MAX_PACKAGES,       SPEC_MAX_PACKAGES,       'AC40: $RunState::MAX_PACKAGES == 512 (unchanged)');
}

# ===========================================================================
# 2. AC2 -- t/45-run-state.t's key-list variable is renamed to @SUMMARY_KEYS
#    (no digit in the name), and no identifier KEYS_11 remains anywhere in
#    that file. Static source scan only -- t/45 itself is never edited or
#    executed for behaviour here (that is a separate, excluded AC41 check).
# ===========================================================================
{
    my $t45_src = slurp($T45_PATH);
    ok(length($t45_src) > 0, 'AC2 precondition: t/45-run-state.t is readable on disk') or diag("expected at $T45_PATH");
    my $have = (length($t45_src) > 0);
    $have ? like($t45_src, qr/\@SUMMARY_KEYS\b/, 'AC2: t/45-run-state.t contains the identifier @SUMMARY_KEYS')
          : fail('AC2: t/45-run-state.t contains @SUMMARY_KEYS [file not on disk]');
    $have ? unlike($t45_src, qr/\bKEYS_11\b/, 'AC2: t/45-run-state.t contains no identifier KEYS_11 anywhere')
          : fail('AC2: t/45-run-state.t contains no KEYS_11 [file not on disk]');
}

# ===========================================================================
# 3. AC1/AC3 -- the 16-key shape and new-key types, across >= 3 structurally
#    different fixtures.
# ===========================================================================
{
    my $root = tempdir(CLEANUP => 1);

    my $dir_empty = make_blueprint($root, 'empty-run', registry => registry_json());
    my $s_empty = RS('summarize_dir', $dir_empty);
    assert_16_keys($s_empty, 'AC1 [no packages]');
    assert_new_key_types($s_empty, 'AC1 [no packages]');

    my $dir_one = make_blueprint($root, 'one-pkg', orchestrator => "42\n",
        registry => registry_json(), packages => { p1 => mk_ledger(status => 'running', pipeline => 1, marks => { 1 => 'x' }) });
    my $s_one = RS('summarize_dir', $dir_one);
    assert_16_keys($s_one, 'AC1 [one package, orchestrator marker]');
    assert_new_key_types($s_one, 'AC1 [one package, orchestrator marker]');

    my %many;
    $many{"p$_"} = mk_ledger(status => 'pending') for (1 .. 5);
    my $dir_many = make_blueprint($root, 'many-pkg', shutdown => 1, registry => registry_json(), packages => \%many);
    my $s_many = RS('summarize_dir', $dir_many);
    assert_16_keys($s_many, 'AC1 [many packages, parked state]');
    assert_new_key_types($s_many, 'AC1 [many packages, parked state]');
}

# ===========================================================================
# 4. Orchestrator liveness and start time -- AC4-AC9.
# ===========================================================================

# --- AC4: marker + prober false -> pid defined, alive==0, started_at undef.
{
    my $root = tempdir(CLEANUP => 1);
    local $RunState::PID_ALIVE = sub { 0 };
    my $dir = make_blueprint($root, 'bp', orchestrator => "4242\n", registry => registry_json());
    my $s = RS('summarize_dir', $dir);
    is(field($s, 'orchestrator_pid'), 4242, 'AC4: orchestrator_pid == 4242');
    is(field($s, 'orchestrator_alive'), 0, 'AC4: prober false -> orchestrator_alive == 0');
    is(field($s, 'orchestrator_started_at'), undef, 'AC4: positively checked-dead -> orchestrator_started_at undef (suppressed)');
}

# --- AC5: same marker, prober true -> alive==1, started_at == marker mtime.
{
    my $root = tempdir(CLEANUP => 1);
    local $RunState::PID_ALIVE = sub { 1 };
    my $dir = make_blueprint($root, 'bp', orchestrator => "4242\n", registry => registry_json());
    my @st = stat("$dir/runs/.orchestrator");
    my $expected_mtime = $st[9];
    my $s = RS('summarize_dir', $dir);
    is(field($s, 'orchestrator_alive'), 1, 'AC5: prober true -> orchestrator_alive == 1');
    is(field($s, 'orchestrator_started_at'), $expected_mtime, 'AC5: orchestrator_started_at equals the marker\'s own mtime (derived via stat in the test, not hard-coded)');
}

# --- AC6: no prober / prober dies / prober returns undef -> alive undef,
# --- started_at still defined (unknown != dead); summarize_dir never dies
# --- or warns.
{
    my $root = tempdir(CLEANUP => 1);
    for my $case (
        [ 'no prober installed', undef ],
        [ 'prober dies',         sub { die "boom\n" } ],
        [ 'prober returns undef', sub { undef } ],
    ) {
        my ($label, $prober) = @$case;
        local $RunState::PID_ALIVE = $prober;
        my $dir = make_blueprint($root, "bp-" . ($label =~ s/\W+/_/gr), orchestrator => "555\n", registry => registry_json());
        my ($res, $err, $warns) = probe_call('summarize_dir', $dir);
        is($err, '', "AC6 [$label]: summarize_dir does not die");
        ok(!@$warns, "AC6 [$label]: summarize_dir does not warn") or diag(join('; ', @$warns));
        is(field($res, 'orchestrator_alive'), undef, "AC6 [$label]: orchestrator_alive is undef (unknown)");
        ok(defined(field($res, 'orchestrator_started_at')), "AC6 [$label]: orchestrator_started_at is still defined (unknown liveness does not suppress the start time)");
    }
}

# --- AC7: no runs/ dir at all, and runs/ present without .orchestrator ---
# --- -> both orchestrator_alive and orchestrator_started_at undef.
{
    my $root = tempdir(CLEANUP => 1);
    local $RunState::PID_ALIVE = sub { 1 };

    # no runs/ dir at all, but a ledger so summarize_dir still returns a
    # summary (state 'solo').
    my $dir1 = make_blueprint($root, 'solo', no_runs_dir => 1, packages => { p1 => mk_ledger(status => 'pending') });
    my $s1 = RS('summarize_dir', $dir1);
    is(field($s1, 'orchestrator_alive'), undef, 'AC7 [no runs/ dir]: orchestrator_alive undef');
    is(field($s1, 'orchestrator_started_at'), undef, 'AC7 [no runs/ dir]: orchestrator_started_at undef');

    # runs/ present, no .orchestrator marker.
    my $dir2 = make_blueprint($root, 'idle', registry => registry_json());
    my $s2 = RS('summarize_dir', $dir2);
    is(field($s2, 'orchestrator_alive'), undef, 'AC7 [runs/ present, no .orchestrator]: orchestrator_alive undef');
    is(field($s2, 'orchestrator_started_at'), undef, 'AC7 [runs/ present, no .orchestrator]: orchestrator_started_at undef');
}

# --- AC8: .shutdown + live .orchestrator -> state parked (unchanged), ---
# --- orchestrator_alive still 1 (liveness not shadowed by state).
{
    my $root = tempdir(CLEANUP => 1);
    local $RunState::PID_ALIVE = sub { 1 };
    my $dir = make_blueprint($root, 'bp', orchestrator => "9\n", shutdown => 1, registry => registry_json());
    my $s = RS('summarize_dir', $dir);
    is(field($s, 'state'), 'parked', 'AC8: .shutdown present -> state eq "parked" (unchanged)');
    is(field($s, 'orchestrator_alive'), 1, 'AC8: orchestrator_alive == 1 despite parked state -- liveness not shadowed');
}

# --- AC9: counting prober -- the exact expected number of probe calls is
# --- one for the orchestrator pid, plus one per registry-recorded
# --- running-package pid (never a second probe added).
{
    my $root = tempdir(CLEANUP => 1);
    my $n = 0;
    local $RunState::PID_ALIVE = sub { $n++; return 1; };
    my $dir = make_blueprint($root, 'bp', orchestrator => "1000\n",
        registry => registry_json(
            'p-run1'       => { status => 'running', pid => 555 },
            'p-run2'       => { status => 'running', pid => 777 },
            'p-done'       => { status => 'done' },
            'p-run-nopid'  => { status => 'running' },
        ),
        packages => {
            'p-run1'      => mk_ledger(status => 'running'),
            'p-run2'      => mk_ledger(status => 'running'),
            'p-done'      => mk_ledger(status => 'done'),
            'p-run-nopid' => mk_ledger(status => 'running'),
        });
    my $s = RS('summarize_dir', $dir);
    ok(is_hashref($s), 'AC9 precondition: summarize_dir returned a summary');
    is($n, 3, 'AC9: prober invoked exactly 3 times (1 orchestrator pid + p-run1 pid + p-run2 pid; p-done not running, p-run-nopid has no pid) -- no second probe added by this package');
}

# ===========================================================================
# 5. Package attempts / cap -- AC10-AC15.
# ===========================================================================

# --- AC10 (MANDATORY): the falsifying fixture. attempt=4, tc=1, rld=1 -----
# --- must yield attempt == 2, never 4. Without this fixture an
# --- implementation reading only `attempt` is indistinguishable from a
# --- correct one.
{
    my $root = tempdir(CLEANUP => 1);
    my $dir = make_blueprint($root, 'discount', registry => registry_json(
        pkgA => { status => 'pending', attempt => 4, turn_continuations => 1, rate_limit_discounts => 1 },
    ));
    my $s = RS('summarize_dir', $dir);
    my $e = find_pkg($s, 'pkgA');
    is(field($e, 'attempt'), 2, 'AC10 (MANDATORY): {attempt=>4,turn_continuations=>1,rate_limit_discounts=>1} -> attempt == 2, NOT 4 -- effective_attempts, not raw attempt');
}

# --- AC11: attempt at 0, mid, at cap, above cap -- never clamped. ---------
{
    my $root = tempdir(CLEANUP => 1);
    my $dir = make_blueprint($root, 'sweep', registry => registry_json(
        p0 => { status => 'pending', attempt => 0 },
        p3 => { status => 'pending', attempt => 3 },
        p5 => { status => 'pending', attempt => 5 },
        p9 => { status => 'pending', attempt => 9 },
    ));
    my $s = RS('summarize_dir', $dir);
    for my $c ( [ p0 => 0 ], [ p3 => 3 ], [ p5 => 5 ], [ p9 => 9 ] ) {
        my ($name, $want) = @$c;
        is(field(find_pkg($s, $name), 'attempt'), $want, "AC11: {attempt=>$want} -> attempt == $want" . ($want == 9 ? ' (above default cap, reported AS-IS, never clamped)' : ''));
    }
}

# --- AC12: discounts exceeding attempt -> floored at 0, never negative. ---
{
    my $root = tempdir(CLEANUP => 1);
    my $dir = make_blueprint($root, 'floor', registry => registry_json(
        pkgA => { status => 'pending', attempt => 2, turn_continuations => 5 },
    ));
    my $s = RS('summarize_dir', $dir);
    is(field(find_pkg($s, 'pkgA'), 'attempt'), 0, 'AC12: {attempt=>2, turn_continuations=>5} -> attempt == 0 (floored, never negative)');
}

# --- AC13: _reg_count called directly. ------------------------------------
{
    for my $c (
        [ 'undef',              undef,          0 ],
        [ 'arrayref []',        [],             0 ],
        [ 'hashref {}',         {},             0 ],
        [ q{empty string ''},   '',             0 ],
        [ q{'abc'},             'abc',          0 ],
        [ q{'-1'},              '-1',           0 ],
        [ q{'1.5'},             '1.5',          0 ],
        [ q{'1e3'},             '1e3',          0 ],
        [ q{'12345678901' (11 digits)}, '12345678901', 0 ],
        [ q{'0'},               '0',            0 ],
        [ q{'7'},               '7',            7 ],
        [ 'the number 7',       7,              7 ],
        [ q{'0007'},            '0007',         7 ],
    ) {
        my ($label, $arg, $want) = @$c;
        is(RS('_reg_count', $arg), $want, "AC13: _reg_count($label) == $want");
    }
}

# --- AC14: _attempt_cap. ---------------------------------------------------
{
    {
        local $ENV{BP_ATTEMPT_CAP};
        delete $ENV{BP_ATTEMPT_CAP};
        is(RS('_attempt_cap'), 5, 'AC14: BP_ATTEMPT_CAP unset -> attempt_cap == 5');
    }
    for my $c ( [ "'3'", '3', 3 ], [ "'0'", '0', 5 ], [ "'-2'", '-2', 5 ], [ "'abc'", 'abc', 5 ], [ "''", '', 5 ] ) {
        my ($label, $val, $want) = @$c;
        local $ENV{BP_ATTEMPT_CAP} = $val;
        is(RS('_attempt_cap'), $want, "AC14: BP_ATTEMPT_CAP=$label -> attempt_cap == $want");
    }
}

# --- AC15: registry unusable (5 vectors) -- every entry's attempt/cap -----
# --- undef, while ledger-derived fields stay populated. -------------------
{
    my $rich = mk_ledger(status => 'running', pipeline => 1, marks => { 1 => 'x' }, next_action => 'Do the next concrete thing.');
    my $root = tempdir(CLEANUP => 1);

    my %cases = (
        'runs/ absent'                    => { no_runs_dir => 1 },
        'registry.json absent'            => { registry_absent => 1 },
        'registry.json malformed JSON'    => { registry => '{"packages":{' },
        'registry.json a JSON array'      => { registry => '["a","b"]' },
        'per-package value a scalar'      => { registry => registry_json(p1 => RAW_JSON('"just-a-string"')) },
    );
    for my $label (sort keys %cases) {
        my %o = %{ $cases{$label} };
        my %mk_o = ( packages => { p1 => $rich } );
        $mk_o{no_runs_dir} = 1 if $o{no_runs_dir};
        $mk_o{registry} = $o{registry} if exists $o{registry};
        # 'registry.json absent': runs/ created (no_runs_dir not set), but no
        # registry key passed to make_blueprint -> file never written.
        my $dir = make_blueprint($root, 'ac15-' . ($label =~ s/\W+/_/gr), %mk_o);
        my $s = RS('summarize_dir', $dir);
        my $e = find_pkg($s, 'p1');
        is(field($e, 'attempt'), undef, "AC15 [$label]: attempt undef");
        is(field($e, 'attempt_cap'), undef, "AC15 [$label]: attempt_cap undef");
        is(field($e, 'status'), 'running', "AC15 [$label]: status still populated from the ledger");
        is(field($e, 'step'), '2/8', "AC15 [$label]: step still populated from the ledger");
        is(field($e, 'next_action'), 'Do the next concrete thing.', "AC15 [$label]: next_action still populated from the ledger");
    }
}

# ===========================================================================
# 6. Pipeline step -- AC16-AC20.
# ===========================================================================

# --- AC16: template's 8 checkboxes, steps 1+2 ticked (one [x], one [X]). --
{
    my $root = tempdir(CLEANUP => 1);
    my $ledger = mk_ledger(pipeline => 1, marks => { 1 => 'x', 2 => 'X' });
    my $dir = make_blueprint($root, 'bp', registry => registry_json(), packages => { p1 => $ledger });
    my $s = RS('summarize_dir', $dir);
    my $e = find_pkg($s, 'p1');
    is(field($e, 'step'), '3/8', 'AC16: steps 1 ([x]) and 2 ([X]) ticked -> step eq "3/8"');
    is_deeply(field($e, 'steps_pending'), [ 3, 4, 5, 6, 7, 8 ], 'AC16: steps_pending == [3,4,5,6,7,8]');
}

# --- AC17: none ticked / all ticked. --------------------------------------
{
    my $root = tempdir(CLEANUP => 1);
    my $dir1 = make_blueprint($root, 'none', registry => registry_json(), packages => { p1 => mk_ledger(pipeline => 1) });
    my $e1 = find_pkg(RS('summarize_dir', $dir1), 'p1');
    is(field($e1, 'step'), '1/8', 'AC17: nothing ticked -> step eq "1/8"');
    is_deeply(field($e1, 'steps_pending'), [ 1 .. 8 ], 'AC17: nothing ticked -> steps_pending == [1..8]');

    my $dir2 = make_blueprint($root, 'all', registry => registry_json(),
        packages => { p1 => mk_ledger(pipeline => 1, marks => { map { $_ => 'x' } 1 .. 8 }) });
    my $e2 = find_pkg(RS('summarize_dir', $dir2), 'p1');
    is(field($e2, 'step'), '8/8', 'AC17: all ticked -> step eq "8/8"');
    is_deeply(field($e2, 'steps_pending'), [], 'AC17: all ticked -> steps_pending == [] (an ARRAY ref of length 0, not undef)');
    ok(is_arrayref(field($e2, 'steps_pending')), 'AC17: all-ticked steps_pending is an ARRAY ref, not undef');
}

# --- AC18: 4 vectors -> step/steps_pending both undef in every case. ------
{
    my $root = tempdir(CLEANUP => 1);
    my %cases = (
        'no Pipeline heading at all' =>
            "---\npackage: x\n---\n# body\n\nJust prose, no Pipeline section.\n",
        'Pipeline heading immediately followed by another heading' =>
            "---\npackage: x\n---\n# body\n\n## Pipeline\n## Decisions & attempt log\n\nnothing between\n",
        'Pipeline section holds only prose' =>
            "---\npackage: x\n---\n# body\n\n## Pipeline\n\nThis section has no checkbox lines at all, just prose.\n",
        'Pipeline checkbox numbers all outside 1-8' =>
            "---\npackage: x\n---\n# body\n\n## Pipeline\n\n- [ ] 0. Zero is not a valid step\n- [ ] 9. Nine is not a valid step\n",
    );
    for my $label (sort keys %cases) {
        my $dir = make_blueprint($root, 'ac18-' . ($label =~ s/\W+/_/gr), registry => registry_json(), packages => { p1 => $cases{$label} });
        my $e = find_pkg(RS('summarize_dir', $dir), 'p1');
        is(field($e, 'step'), undef, "AC18 [$label]: step undef");
        is(field($e, 'steps_pending'), undef, "AC18 [$label]: steps_pending undef (never [] here -- no recognised checkbox at all)");
    }
}

# --- AC19: checkbox lines after the next heading are not counted. --------
{
    my $root = tempdir(CLEANUP => 1);
    my $ledger = "---\npackage: x\n---\n# body\n\n"
        . "## Pipeline\n\n"
        . "- [ ] 1. Scout\n- [ ] 2. Spec\n- [ ] 3. Tests\n\n"
        . "## Decisions & attempt log\n\n"
        . "Quoted from a stale report: \"- [x] 8. UI pass\" must not be counted.\n";
    my $dir = make_blueprint($root, 'bp', registry => registry_json(), packages => { p1 => $ledger });
    my $e = find_pkg(RS('summarize_dir', $dir), 'p1');
    is(field($e, 'step'), '1/3', 'AC19: a step-8 checkbox line quoted AFTER the next heading is not counted -> step eq "1/3"');
    is_deeply(field($e, 'steps_pending'), [ 1, 2, 3 ], 'AC19: steps_pending == [1,2,3], step 8 never appears');
}

# --- AC20: _parse_pipeline called directly. -------------------------------
{
    for my $c ( [ 'undef', undef ], [ q{''}, '' ], [ '4 KiB of random text', ('qwzxjk ' x 600) ] ) {
        my ($label, $arg) = @$c;
        my ($res, $err, $warns) = probe_list('_parse_pipeline', $arg);
        is($err, '', "AC20 [$label]: _parse_pipeline does not die");
        is_deeply($res, [ undef, undef ], "AC20 [$label]: _parse_pipeline returns (undef, undef)");
    }
}

# ===========================================================================
# 7. Next action -- AC21-AC26.
# ===========================================================================

# --- AC21: exact text round-trips. ----------------------------------------
{
    my $root = tempdir(CLEANUP => 1);
    my $text = q{Read blueprint.md's Decisions table in full before the first tool call.};
    my $dir = make_blueprint($root, 'bp', registry => registry_json(), packages => { p1 => mk_ledger(next_action => $text) });
    my $e = find_pkg(RS('summarize_dir', $dir), 'p1');
    is(field($e, 'next_action'), $text, 'AC21: next_action is the exact ## Next action text');
}

# --- AC22: multi-line, blank lines, leading indentation -> collapsed. ----
{
    my $root = tempdir(CLEANUP => 1);
    my $ledger = "---\npackage: x\n---\n# body\n\n## Next action\n\n"
        . "  Read the spec first,\n\n"
        . "    then re-verify every citation\n"
        . "  before touching anything.\n";
    my $dir = make_blueprint($root, 'bp', registry => registry_json(), packages => { p1 => $ledger });
    my $e = find_pkg(RS('summarize_dir', $dir), 'p1');
    my $got = field($e, 'next_action');
    ok(is_real_str($got), 'AC22 precondition: next_action is a defined, unblessed string');
    unlike((is_real_str($got) ? $got : "\n(sentinel, not a real string)\n"), qr/\n/, 'AC22: next_action contains no embedded newline');
    unlike((is_real_str($got) ? $got : ' (sentinel, not a real string) '), qr/\A\s|\s\z/, 'AC22: next_action has no leading or trailing whitespace');
    is($got, 'Read the spec first, then re-verify every citation before touching anything.',
        'AC22: three lines with blank lines + indentation collapse to one space-separated string');
}

# --- AC23: absent / empty / whitespace-only / placeholder -> undef. ------
{
    my $root = tempdir(CLEANUP => 1);
    my %cases = (
        'no ## Next action heading' => "---\npackage: x\n---\n# body\n\nno next-action section here\n",
        'empty section'             => "---\npackage: x\n---\n# body\n\n## Next action\n\n## Outputs\n",
        'whitespace-only section'   => "---\npackage: x\n---\n# body\n\n## Next action\n\n   \n\t\n\n## Outputs\n",
        'template placeholder'      => "---\npackage: x\n---\n# body\n\n## Next action\n\n<ALWAYS current. The exact instruction a fresh coordinator executes first.>\n",
    );
    for my $label (sort keys %cases) {
        my $dir = make_blueprint($root, 'ac23-' . ($label =~ s/\W+/_/gr), registry => registry_json(), packages => { p1 => $cases{$label} });
        my $e = find_pkg(RS('summarize_dir', $dir), 'p1');
        is(field($e, 'next_action'), undef, "AC23 [$label]: next_action undef");
    }
}

# --- AC24: "## Next actions" (plural) does not match. ---------------------
{
    my $root = tempdir(CLEANUP => 1);
    my $ledger = "---\npackage: x\n---\n# body\n\n## Next actions\n\nThis heading is plural and must not match.\n";
    my $dir = make_blueprint($root, 'bp', registry => registry_json(), packages => { p1 => $ledger });
    my $e = find_pkg(RS('summarize_dir', $dir), 'p1');
    is(field($e, 'next_action'), undef, 'AC24: "## Next actions" (plural) does not match the anchored heading regex -> undef');
}

# --- AC25: raw ESC + NUL are neutralised (no control byte reaches the ----
# --- rendered string). -----------------------------------------------------
{
    my $root = tempdir(CLEANUP => 1);
    my $ledger = "---\npackage: x\n---\n# body\n\n## Next action\n\n"
        . "Run \x1b[31mthis\x1b[0m command\x00 now.\n";
    my $dir = make_blueprint($root, 'bp', registry => registry_json(), packages => { p1 => $ledger });
    my $e = find_pkg(RS('summarize_dir', $dir), 'p1');
    my $got = field($e, 'next_action');
    ok(is_real_str($got), 'AC25 precondition: next_action is a defined, unblessed string');
    my @bad_bytes = is_real_str($got)
        ? (grep { ord($_) < 0x20 || ord($_) == 0x7F } split //, $got)
        : ('SENTINEL-NOT-A-REAL-STRING');
    is(scalar(@bad_bytes), 0, 'AC25: every byte of next_action is >= 0x20 and != 0x7F (raw ESC / NUL neutralised)')
        or diag('found control byte(s)/failure: ' . join(',', map { is_real_str($got) ? sprintf('0x%02X', ord($_)) : $_ } @bad_bytes));
}

# --- AC26: 500 ASCII bytes -> truncated to <= 200 bytes. ------------------
{
    my $root = tempdir(CLEANUP => 1);
    my $long = 'a' x 500;
    my $dir = make_blueprint($root, 'bp', registry => registry_json(), packages => { p1 => mk_ledger(next_action => $long) });
    my $e = find_pkg(RS('summarize_dir', $dir), 'p1');
    my $got = field($e, 'next_action');
    ok(is_real_str($got) && length($got) <= 200, 'AC26: a 500-byte next-action section is truncated to <= 200 bytes (and is a real string, not the call-failed sentinel)')
        or diag('got: ' . (is_real_str($got) ? "real string, length " . length($got) : ref($got) || 'undef'));
}

# ===========================================================================
# 8. Package array shape / cross-source consistency -- AC27-AC32.
# ===========================================================================

# --- AC27/AC28: ARRAY shape + count agreement + 7-key shape, across ------
# --- structurally different fixtures (also exercises "no packages" / -----
# --- "one" / "many" from the launcher's enumeration list). ---------------
{
    my $root = tempdir(CLEANUP => 1);

    my $dir0 = make_blueprint($root, 'zero', registry => registry_json());
    my $s0 = RS('summarize_dir', $dir0);
    ok(is_arrayref(field($s0, 'packages')), 'AC27 [zero]: packages is an ARRAY ref');
    is(scalar(@{ field($s0, 'packages') // [] }), field($s0, 'packages_total'), 'AC27 [zero]: scalar(@packages) == packages_total (0)');

    my $dir1 = make_blueprint($root, 'one', registry => registry_json(), packages => { p1 => mk_ledger(status => 'pending') });
    my $s1 = RS('summarize_dir', $dir1);
    ok(is_arrayref(field($s1, 'packages')), 'AC27 [one]: packages is an ARRAY ref');
    is(scalar(@{ field($s1, 'packages') // [] }), field($s1, 'packages_total'), 'AC27 [one]: scalar(@packages) == packages_total (1)');
    assert_pkg_shape(field($s1, 'packages')->[0], 'AC28 [one]') if is_arrayref(field($s1, 'packages')) && @{ field($s1, 'packages') };

    my %many;
    $many{"p$_"} = mk_ledger(status => 'pending') for (1 .. 6);
    my $dir_many = make_blueprint($root, 'many', registry => registry_json(), packages => \%many);
    my $s_many = RS('summarize_dir', $dir_many);
    ok(is_arrayref(field($s_many, 'packages')), 'AC27 [many]: packages is an ARRAY ref');
    is(scalar(@{ field($s_many, 'packages') // [] }), field($s_many, 'packages_total'), 'AC27 [many]: scalar(@packages) == packages_total (6)');
    if (is_arrayref(field($s_many, 'packages'))) {
        assert_pkg_shape($_, 'AC28 [many]') for @{ field($s_many, 'packages') };
    }
}

# --- AC29: ascending-name order regardless of on-disk creation order. ----
{
    my $root = tempdir(CLEANUP => 1);
    my $dir = "$root/order";
    make_path($dir);
    make_path("$dir/runs");
    write_file("$dir/runs/registry.json", registry_json());
    make_path("$dir/packages");
    # written in REVERSE order on disk.
    write_file("$dir/packages/03-c.md", mk_ledger(status => 'pending'));
    write_file("$dir/packages/02-b.md", mk_ledger(status => 'pending'));
    write_file("$dir/packages/01-a.md", mk_ledger(status => 'pending'));
    my $s = RS('summarize_dir', $dir);
    is_deeply([ map { $_->{name} } @{ field($s, 'packages') // [] } ], [ qw(01-a 02-b 03-c) ],
        'AC29: packages array is in ascending-name order regardless of on-disk creation order -- the renderer never sorts');
}

# --- AC30: empty packages/ dir + usable registry with empty packages ------
# --- object -> summary defined, packages_total == 0, packages == []. -----
{
    my $root = tempdir(CLEANUP => 1);
    my $dir = make_blueprint($root, 'bp', empty_packages_dir => 1, registry => '{"packages":{}}');
    my $s = RS('summarize_dir', $dir);
    ok(is_hashref($s), 'AC30: summary is defined');
    is(field($s, 'packages_total'), 0, 'AC30: packages_total == 0');
    is_deeply(field($s, 'packages'), [], 'AC30: packages == []');
}

# --- AC31: MAX_PACKAGES+1 -> undef (no packages array produced); exactly --
# --- MAX_PACKAGES -> a summary with that many entries. --------------------
{
    my $root = tempdir(CLEANUP => 1);
    my $cap = $RunState::MAX_PACKAGES;

    my $dir_over = make_blueprint($root, 'over', registry => registry_json());
    make_path("$dir_over/packages");
    for my $i ( 1 .. $cap + 1 ) {
        write_file(sprintf("%s/packages/p%04d.md", $dir_over, $i), "---\npackage: x\nstatus: pending\n---\n");
    }
    is(RS('summarize_dir', $dir_over), undef, "AC31: a ledger set of MAX_PACKAGES+1 (" . ($cap + 1) . ") packages -> summarize_dir undef (unchanged)");

    my $dir_at = make_blueprint($root, 'atcap', registry => registry_json());
    make_path("$dir_at/packages");
    for my $i ( 1 .. $cap ) {
        write_file(sprintf("%s/packages/p%04d.md", $dir_at, $i), "---\npackage: x\nstatus: pending\n---\n");
    }
    my $s_at = RS('summarize_dir', $dir_at);
    ok(is_hashref($s_at), "AC31: exactly MAX_PACKAGES ($cap) packages -> summarize_dir returns a summary");
    is(field($s_at, 'packages_total'), $cap, "AC31: packages_total == $cap");
    is(scalar(@{ field($s_at, 'packages') // [] }), $cap, "AC31: packages array has exactly $cap entries");
}

# --- AC32: ledger present + no registry entry; registry-only fallback. ---
{
    my $root = tempdir(CLEANUP => 1);
    my $rich = mk_ledger(status => 'running', pipeline => 1, marks => { 1 => 'x' }, next_action => 'Concrete next step.');

    my $dir_ledger_only = make_blueprint($root, 'ledger-only', registry => registry_json(), packages => { p1 => $rich });
    my $e1 = find_pkg(RS('summarize_dir', $dir_ledger_only), 'p1');
    ok(is_hashref($e1), 'AC32 [ledger, no registry entry]: entry present');
    is(field($e1, 'attempt'), undef, 'AC32 [ledger, no registry entry]: attempt undef');
    is(field($e1, 'attempt_cap'), undef, 'AC32 [ledger, no registry entry]: attempt_cap undef');
    is(field($e1, 'status'), 'running', 'AC32 [ledger, no registry entry]: status populated from ledger');
    is(field($e1, 'step'), '2/8', 'AC32 [ledger, no registry entry]: step populated from ledger');
    is(field($e1, 'next_action'), 'Concrete next step.', 'AC32 [ledger, no registry entry]: next_action populated from ledger');

    # registry-fallback mode: packages/ absent entirely.
    my $dir_registry_only = make_blueprint($root, 'registry-only', registry => registry_json(
        p1 => { status => 'pending', attempt => 3 },
    ));
    my $e2 = find_pkg(RS('summarize_dir', $dir_registry_only), 'p1');
    ok(is_hashref($e2), 'AC32 [registry-fallback, no ledger]: entry present');
    is(field($e2, 'status'), undef, 'AC32 [registry-fallback, no ledger]: status undef (Decision 13, unchanged: registry status never adopted)');
    is(field($e2, 'step'), undef, 'AC32 [registry-fallback, no ledger]: step undef');
    is(field($e2, 'steps_pending'), undef, 'AC32 [registry-fallback, no ledger]: steps_pending undef');
    is(field($e2, 'next_action'), undef, 'AC32 [registry-fallback, no ledger]: next_action undef');
    is(field($e2, 'attempt'), 3, 'AC32 [registry-fallback, no ledger]: attempt populated from registry (3)');
    is(field($e2, 'attempt_cap'), 5, 'AC32 [registry-fallback, no ledger]: attempt_cap populated (default 5)');
}

# ===========================================================================
# 9. Malformed / hostile ledgers -- AC33-AC35.
# ===========================================================================

# --- AC33: zero-length; "---\n---\n" only; oversized w/ Pipeline inside ---
# --- the cap; oversized w/ Next action beyond the cap. --------------------
{
    my $root = tempdir(CLEANUP => 1);

    my $dir1 = make_blueprint($root, 'zerolen', registry => registry_json(), packages => { p1 => '' });
    my ($r1, $err1, $w1) = probe_call('summarize_dir', $dir1);
    is($err1, '', 'AC33 [zero-length ledger]: summarize_dir does not die');
    ok(!@$w1, 'AC33 [zero-length ledger]: summarize_dir does not warn');
    my $e1 = find_pkg($r1, 'p1');
    is(field($e1, 'step'), undef, 'AC33 [zero-length ledger]: step undef, never fabricated');
    is(field($e1, 'next_action'), undef, 'AC33 [zero-length ledger]: next_action undef, never fabricated');

    my $dir2 = make_blueprint($root, 'barefence', registry => registry_json(), packages => { p1 => "---\n---\n" });
    my ($r2, $err2, $w2) = probe_call('summarize_dir', $dir2);
    is($err2, '', 'AC33 ["---\n---\n" only]: summarize_dir does not die');
    ok(!@$w2, 'AC33 ["---\n---\n" only]: summarize_dir does not warn');
    my $e2 = find_pkg($r2, 'p1');
    is(field($e2, 'step'), undef, 'AC33 ["---\n---\n" only]: step undef');
    is(field($e2, 'next_action'), undef, 'AC33 ["---\n---\n" only]: next_action undef');

    # over-cap ledger, ## Pipeline sits inside the first 64 KiB.
    my $pipeline_early = "---\npackage: x\n---\n# body\n\n## Pipeline\n\n"
        . join("\n", checkbox_lines(1 => 'x', 2 => 'x')) . "\n\n"
        . ('x' x (SPEC_MAX_LEDGER_BYTES + 4096));   # filler pushes total size past the cap
    my $dir3 = make_blueprint($root, 'pipeline-inside-cap', registry => registry_json(), packages => { p1 => $pipeline_early });
    ok(length($pipeline_early) > SPEC_MAX_LEDGER_BYTES, 'AC33 precondition: fixture 3 ledger file is over MAX_LEDGER_BYTES on disk');
    my ($r3, $err3, $w3) = probe_call('summarize_dir', $dir3);
    is($err3, '', 'AC33 [Pipeline inside cap, ledger over MAX_LEDGER_BYTES]: summarize_dir does not die');
    ok(!@$w3, 'AC33 [Pipeline inside cap, ledger over MAX_LEDGER_BYTES]: summarize_dir does not warn');
    my $e3 = find_pkg($r3, 'p1');
    is(field($e3, 'step'), '3/8', 'AC33 [Pipeline inside cap]: step still parses correctly (3/8) despite the file being over the cap');

    # over-cap ledger, ## Next action sits BEYOND the first 64 KiB.
    my $next_beyond = "---\npackage: x\n---\n# body\n\n"
        . ('x' x (SPEC_MAX_LEDGER_BYTES + 4096))    # filler pushes the heading itself past the cap
        . "\n\n## Next action\n\nThis text is unreachable by the head read.\n";
    my $dir4 = make_blueprint($root, 'next-beyond-cap', registry => registry_json(), packages => { p1 => $next_beyond });
    ok(length($next_beyond) > SPEC_MAX_LEDGER_BYTES, 'AC33 precondition: fixture 4 ledger file is over MAX_LEDGER_BYTES on disk');
    my ($r4, $err4, $w4) = probe_call('summarize_dir', $dir4);
    is($err4, '', 'AC33 [Next action beyond cap]: summarize_dir does not die');
    ok(!@$w4, 'AC33 [Next action beyond cap]: summarize_dir does not warn');
    my $e4 = find_pkg($r4, 'p1');
    is(field($e4, 'next_action'), undef, 'AC33 [Next action beyond cap]: next_action undef -- an honest absence, not a partial or invented string');
}

# --- AC34: CRLF + UTF-8 BOM ledger yields the same step/steps_pending/ ---
# --- next_action as its LF, BOM-less twin; status is undef either way ----
# --- because the strict _ledger_status parse is unchanged. ----------------
{
    my $root = tempdir(CLEANUP => 1);
    my $canonical = mk_ledger(status => 'running', pipeline => 1, marks => { 1 => 'x' }, next_action => 'Verify then proceed.');
    my $crlf_bom = "\xEF\xBB\xBF" . ($canonical =~ s/\n/\r\n/gr);

    my $dir1 = make_blueprint($root, 'lf', registry => registry_json(), packages => { p1 => $canonical });
    my $dir2 = make_blueprint($root, 'crlf-bom', registry => registry_json(), packages => { p1 => $crlf_bom });
    my $e1 = find_pkg(RS('summarize_dir', $dir1), 'p1');
    my $e2 = find_pkg(RS('summarize_dir', $dir2), 'p1');

    is(field($e1, 'status'), 'running', 'AC34 precondition: the LF/BOM-less twin has status "running"');
    is(field($e2, 'status'), undef, 'AC34: the CRLF+BOM ledger has status undef (strict _ledger_status parse unchanged)');
    is(field($e2, 'step'), field($e1, 'step'), 'AC34: CRLF+BOM ledger yields the same step as its LF, BOM-less twin');
    is_deeply(field($e2, 'steps_pending'), field($e1, 'steps_pending'), 'AC34: CRLF+BOM ledger yields the same steps_pending as its LF, BOM-less twin');
    is(field($e2, 'next_action'), field($e1, 'next_action'), 'AC34: CRLF+BOM ledger yields the same next_action as its LF, BOM-less twin');
}

# --- AC35: a single 4096-byte line inside ## Pipeline is skipped by the --
# --- 1024-byte line-length guard and does not affect the surrounding -----
# --- valid checkbox lines. A near-miss: the long line is ITSELF shaped ---
# --- like a valid checkbox for step 2, so if the guard is missing it -----
# --- would wrongly be counted. ---------------------------------------------
{
    my $root = tempdir(CLEANUP => 1);
    my $long_almost_checkbox = '- [ ] 2. ' . ('a' x 4100);   # > 1024 bytes -> must be skipped entirely
    my $ledger = "---\npackage: x\n---\n# body\n\n## Pipeline\n\n"
        . "- [x] 1. Scout\n"
        . "$long_almost_checkbox\n"
        . "- [ ] 3. Tests\n- [ ] 4. Implementation\n- [ ] 5. Validation\n- [ ] 6. Review\n- [ ] 7. Fix-batch\n- [ ] 8. UI pass\n";
    ok(length($long_almost_checkbox) > 1024, 'AC35 precondition: the injected line is over the 1024-byte guard threshold');
    my $dir = make_blueprint($root, 'bp', registry => registry_json(), packages => { p1 => $ledger });
    my $e = find_pkg(RS('summarize_dir', $dir), 'p1');
    is(field($e, 'step'), '3/8', 'AC35 (fix-batch AT-6): the over-length near-checkbox line for step 2 is skipped entirely (7 recognised steps), but the denominator is the HIGHEST STEP NUMBER OBSERVED (8), not a count of parsed lines -- step eq "3/8"');
    is_deeply(field($e, 'steps_pending'), [ 3, 4, 5, 6, 7, 8 ], 'AC35: steps_pending == [3,4,5,6,7,8] -- step 2 never appears, proving the guard fired, and steps 1/3-8 parsed unaffected');
}

# ===========================================================================
# 10. Non-ASCII -- AC36-AC37.
# ===========================================================================

# --- AC36: a package named andré-café (raw UTF-8 bytes) round-trips ------
# --- byte-identically. ------------------------------------------------------
{
    my $root = tempdir(CLEANUP => 1);
    my $pkg_name = "andr\xC3\xA9-caf\xC3\xA9";   # "andré-café" as raw UTF-8 bytes, no \x{...} char
    my $dir = make_blueprint($root, 'bp', registry => registry_json(), packages => { $pkg_name => mk_ledger(status => 'pending') });
    my $s = RS('summarize_dir', $dir);
    my $e = find_pkg($s, $pkg_name);
    ok(is_hashref($e), 'AC36 precondition: the André/café-named package entry is found');
    is(field($e, 'name'), $pkg_name, 'AC36: name is byte-identical to the filename stem (raw UTF-8 bytes, no mangling)');
}

# --- AC37: a 260-byte ## Next action ending in a multi-byte é is ---------
# --- truncated to <= 200 bytes with no split UTF-8 sequence at the end. --
{
    my $root = tempdir(CLEANUP => 1);
    # 199 'a' bytes + a 2-byte UTF-8 'é' (\xC3\xA9) + 59 'b' bytes == 260
    # bytes total. Truncating to exactly 200 bytes lands INSIDE the 'é'
    # sequence (byte 199 is 0xC3, byte 200 -- 0xA9 -- is cut off), so a
    # correct implementation must additionally drop the dangling lead byte.
    my $text = ('a' x 199) . "\xC3\xA9" . ('b' x 59);
    is(length($text), 260, 'AC37 precondition: fixture text is exactly 260 bytes');
    my $dir = make_blueprint($root, 'bp', registry => registry_json(), packages => { p1 => mk_ledger(next_action => $text) });
    my $e = find_pkg(RS('summarize_dir', $dir), 'p1');
    my $got = field($e, 'next_action');
    ok(is_real_str($got), 'AC37 precondition: next_action is a defined, unblessed string');
    ok(is_real_str($got) && length($got) <= 200, 'AC37: next_action is truncated to <= 200 bytes (and is a real string, not the call-failed sentinel)')
        or diag('got: ' . (is_real_str($got) ? "real string, length " . length($got) : ref($got) || 'undef'));
    my $decoded_ok = is_real_str($got) && eval { decode('UTF-8', $got, Encode::FB_CROAK); 1 };
    ok($decoded_ok, 'AC37: the truncated next_action is valid UTF-8 (no split multi-byte sequence at the end)')
        or diag("decode error / not a real string: " . ($@ || 'n/a'));
}

done_testing();
