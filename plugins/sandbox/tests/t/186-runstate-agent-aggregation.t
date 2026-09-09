#!/usr/bin/env perl
# agent-telemetry package 05-runstate-agent-aggregation: RunState reads the
# dispatch log and attaches live agents to the package (and, per Ruling
# AT-8, the RUN) they belong to.
#
# THIS FILE IS THE IMMUTABLE ORACLE for that package
# (specs/05-runstate-agent-aggregation-spec.md), written BLIND to any
# RunState.pm implementation of the new surface -- built from the spec plus
# two driver rulings that changed it AFTER it was written:
#
#   * Ruling AT-8 (2026-09-09): a 17th run-level key, `run_agents`, holding
#     agents whose `package` is the orchestrator's `_run` pseudo-package
#     (Decision 10's blueprint-scoped conformance judge, logged at
#     bp-orchestrator.pl:2095). The spec's own AC9 ("a record with
#     package: '_run' -> every entry's agents is []") is SUPERSEDED by this
#     ruling and is DELIBERATELY NOT ENCODED here as written -- see the
#     "AC9 [AT-8 amended]" block below, which asserts the new, correct
#     behaviour instead (packages unaffected, run_agents populated).
#   * Ruling AT-9 (2026-09-09): `median` and `read_history` aggregation
#     (named only in the package's Scope prose, never in a done criterion)
#     is DROPPED. No assertion here requires either.
#
# A GENUINE, UNRESOLVED CONFLICT this file surfaces rather than papers
# over (see the final report): AT-8's 17th key, if implemented in the
# always-present style every other RunState key uses (an empty arrayref
# rather than an omitted key), necessarily adds a key to EVERY summary
# t/45-run-state.t builds -- including all of its pre-existing,
# dispatch-log-free fixtures -- which would break that file's own
# `is_deeply(sort keys %$s, sort @SUMMARY_KEYS)` (16 names, closed set) on
# every single fixture. This file may not edit t/45 (hard rule, both in
# the spec's S2.10 and reiterated by the task that produced this file), and
# AC43 below still encodes "t/45 exits 0, zero not ok lines" exactly as the
# spec requires. If AT-8 is implemented as the natural always-arrayref key,
# AC43 will go red for a REAL reason (the two rulings conflict), not a
# fixture bug -- that is a driver-level call, not this file's to make.
#
# Coverage: B1-B22 (spec S3, as amended) via AC1-AC45 (spec S4, as
# amended). AC1's literal "16 keys" and AC9's literal "silently dropped"
# text are both superseded by AT-8, per the instructions under which this
# file was written; every other AC is encoded as the spec states it.
#
# Hard constraints honoured here (mirrors t/45 and t/184's stated rules):
#   * this file MUST NOT `use utf8`; the Andre/cafe fixtures are written as
#     explicit UTF-8 byte escapes ("Andr\xC3\xA9", "\xC3\xA9"), never as
#     \x{...} chars.
#   * RunState.pm is never require'd except via use_ok; no other
#     implementation file in the package's write set is read by this file,
#     and none of its internals are consulted beyond the pinned private-sub
#     names the spec itself names (_dispatch_dir, _dispatch_index).
#   * every fixture is built under File::Temp::tempdir (CLEANUP => 1).
#   * every assertion that checks a PROPERTY of a value (length, byte
#     range, "valid UTF-8", regex match) is paired with a companion guard
#     that the value is a real, unblessed scalar (is_real_str) -- see the
#     header comment on that sub for why: a blessed failure sentinel
#     stringifies to something short, printable and valid UTF-8, so a
#     naive property check would spuriously PASS before the feature
#     exists. Four of package 04's oracle assertions were green before
#     anything was implemented for exactly this reason.
#
# Two spec items this file does NOT assert, and why (see the final report
# for the full reasoning):
#   * AC29's ".hidden.json" example: the pinned S2.5 regex
#     /\A([A-Za-z0-9._-]{1,128})\.json\z/ explicitly ADMITS '.' in the
#     stem, so a stem of ".hidden" (all dots/letters) PASSES that regex --
#     directly contradicting AC29's framing that it is "never opened". This
#     is a genuine conflict between the pinned regex and its own example
#     list, not something to guess a resolution for.
#   * AC29's "../evil.json" example: a literal directory entry containing a
#     path separator cannot exist as a single `readdir` component on any
#     real filesystem, so it cannot be constructed as a fixture "as
#     literally as the filesystem permits" without landing outside the
#     scanned directory entirely (at which point the assertion is trivial
#     and tests nothing).
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Encode ();
use Scalar::Util qw(refaddr);

my $SCRIPTS_DIR   = "$Bin/../../scripts";
my $RUNSTATE_PATH = "$SCRIPTS_DIR/RunState.pm";
my $T45_PATH      = "$Bin/45-run-state.t";
my $T184_PATH     = "$Bin/184-runstate-package-facts.t";

use constant SPEC_MAX_REGISTRY_BYTES   => 4 * 1024 * 1024;
use constant SPEC_MAX_LEDGER_BYTES     => 65536;
use constant SPEC_MAX_MARKER_BYTES     => 4096;
use constant SPEC_MAX_PACKAGES         => 512;
use constant SPEC_MAX_DISPATCH_RECORDS => 512;

# ===========================================================================
# Scaffolding -- file I/O, probe/RS pattern (t/45 and t/184's convention).
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

# --- $FAILED sentinel + probe helpers: a missing sub/module degrades to a
# clean per-assertion FAIL, never a spurious PASS and never a file-aborting
# die (t/45/t/184's pattern, verbatim rationale).
my $FAILED = bless { t186 => 'call did not happen' }, 'T186::CallFailed';

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
# gates on this first -- see the file header for why.
sub is_real_str { my ($v) = @_; return defined($v) && !ref($v); }

sub find_pkg {
    my ($s, $name) = @_;
    return $FAILED unless is_hashref($s) && is_arrayref($s->{packages});
    for my $e (@{ $s->{packages} }) {
        return $e if ref($e) eq 'HASH' && defined($e->{name}) && $e->{name} eq $name;
    }
    return undef;
}

# --- SDIR / SDIR2 / SUM: call summarize_dir/summarize AND assert AC45 ------
# --- (no die, no warn) on every single call, inline, everywhere. ----------
sub SDIR {
    my ($dir, $label) = @_;
    my ($res, $err, $warns) = probe_call('summarize_dir', $dir);
    is($err, '', "$label: AC45 -- summarize_dir(\$dir) does not die");
    is_deeply($warns, [], "$label: AC45 -- summarize_dir(\$dir) emits no warnings")
        or diag(join('; ', @$warns));
    return $err eq '' ? $res : $FAILED;
}
sub SDIR2 {
    my ($dir, $idx, $label) = @_;
    my ($res, $err, $warns) = probe_call('summarize_dir', $dir, $idx);
    is($err, '', "$label: AC45 -- summarize_dir(\$dir, \$idx) does not die");
    is_deeply($warns, [], "$label: AC45 -- summarize_dir(\$dir, \$idx) emits no warnings")
        or diag(join('; ', @$warns));
    return $err eq '' ? $res : $FAILED;
}
sub SUM {
    my ($root, $label) = @_;
    my ($res, $err, $warns) = probe_call('summarize', $root);
    is($err, '', "$label: AC45 -- summarize(\$root) does not die");
    is_deeply($warns, [], "$label: AC45 -- summarize(\$root) emits no warnings")
        or diag(join('; ', @$warns));
    return $err eq '' ? $res : $FAILED;
}

# ===========================================================================
# Scaffolding -- hand-rolled JSON value builders. Full control over exact
# JSON literal shape (omitted key vs explicit null vs quoted string vs bare
# number vs a ref), which the spec's fixture vectors require byte-for-byte.
# ===========================================================================

sub NULLV { return bless {},              'RS186::Null'; }   # emit JSON null
sub NUM   { my ($n) = @_; return bless { v => $n }, 'RS186::Num'; }  # emit unquoted
sub RAWV  { my ($j) = @_; return bless { j => $j }, 'RS186::Raw'; }  # emit verbatim
sub OMIT  { return bless {},              'RS186::Omit'; }   # key entirely absent

sub json_escape {
    my ($s) = @_;
    $s = '' unless defined $s;
    $s =~ s/\\/\\\\/g;
    $s =~ s/"/\\"/g;
    # Every control byte (including a raw ESC, which must never reach the
    # terminal unescaped through a JSON fixture) as \u00XX -- not just
    # \n/\r/\t -- so JSON::PP can decode this without rejecting the record
    # as malformed (which would defeat AC24: it must reach RunState's own
    # sanitiser, not die at the JSON layer).
    $s =~ s/([\x00-\x1F])/sprintf('\\u%04x', ord($1))/ge;
    return $s;
}
sub json_str { my ($s) = @_; return '"' . json_escape($s) . '"'; }

sub value_json {
    my ($v) = @_;
    my $r = ref($v);
    return 'null'        if $r eq 'RS186::Null';
    return $v->{v} . ''  if $r eq 'RS186::Num';
    return $v->{j}       if $r eq 'RS186::Raw';
    return json_str($v);
}

# merge_fields(%f) -> %f with every RS186::Omit-valued key deleted. Lets a
# fixture say "this field is absent" (OMIT()) as distinctly from "this
# field is present and null" (NULLV()) as from "this field is present and
# a string/number/ref".
sub merge_fields {
    my (%f) = @_;
    for my $k (keys %f) {
        delete $f{$k} if ref($f{$k}) eq 'RS186::Omit';
    }
    return %f;
}

sub rec_json {
    my (%f) = @_;
    my @parts;
    for my $k (sort keys %f) {
        push @parts, json_str($k) . ':' . value_json($f{$k});
    }
    return '{' . join(',', @parts) . '}';
}

# write_record_file($dir, $stem, %fields) -> $stem. Writes "$dir/$stem.json".
sub write_record_file {
    my ($dir, $stem, %f) = @_;
    %f = merge_fields(%f);
    write_file("$dir/$stem.json", rec_json(%f));
    return $stem;
}

# base_record(%overrides) -> a full valid "running" record's field set
# (canonical shape, S2.5's blueprint/package/role/worker_type/started_at/
# budget_seconds/status, plus a redundant body "id" per AC28). Callers
# override/OMIT/NULLV/RAWV individual fields per the vector under test.
sub base_record {
    my (%o) = @_;
    my %f = (
        blueprint      => 'alpha',
        package        => '01-a',
        role           => 'worker',
        worker_type    => 'bp-implementer',
        started_at     => NUM(1000),
        budget_seconds => NUM(600),
        status         => 'running',
        id             => 'ignored-body-id',
        %o,
    );
    return %f;
}

# bulk_junk_files($dir, $count, $prefix) -- $count *.json files with
# invalid-but-matching-stem names, for the MAX_DISPATCH_RECORDS cap tests
# (AC33/AC34). Content is deliberately unparseable: these must never be
# opened at all once the candidate count is over cap, and when under cap
# they must fail to parse harmlessly rather than accidentally validating.
sub bulk_junk_files {
    my ($dir, $count, $prefix) = @_;
    for my $i (1 .. $count) {
        write_file(sprintf('%s/%sjunk-%05d.json', $dir, $prefix, $i), 'not valid json');
    }
    return;
}

# ===========================================================================
# Scaffolding -- blueprint/ledger fixture builders (t/184's convention,
# reused verbatim for scaffolding purposes; this is test-path scaffolding,
# not a read of RunState.pm).
# ===========================================================================

sub registry_json {
    my (%pkgs) = @_;
    my @entries;
    for my $k (sort keys %pkgs) {
        my $v = $pkgs{$k};
        my $val_json;
        if (ref($v) eq 'HASH') {
            my @fields;
            push @fields, '"status":' . json_str($v->{status}) if exists $v->{status};
            push @fields, '"pid":' . (defined($v->{pid}) ? ($v->{pid} + 0) : 'null') if exists $v->{pid};
            push @fields, '"attempt":' . (defined($v->{attempt}) ? $v->{attempt} : 'null') if exists $v->{attempt};
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

# make_blueprint($root, $name, %opts) -> "$root/$name" (created).
sub make_blueprint {
    my ($root, $name, %o) = @_;
    my $dir = "$root/$name";
    make_path($dir);
    unless ($o{no_runs_dir}) {
        make_path("$dir/runs");
        write_file("$dir/runs/registry.json", $o{registry})     if exists $o{registry};
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

sub checkbox_lines {
    my (%marks) = @_;
    my @out;
    for my $n (1 .. 8) {
        my $m = exists $marks{$n} ? $marks{$n} : ' ';
        push @out, "- [$m] $n. Step $n title";
    }
    return @out;
}

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

# new_env() -> ($tmp, $bp_root, $dlog). $bp_root is
# "$tmp/.ccpraxis-local-data/blueprints" (created); $dlog is
# "$tmp/.ccpraxis-local-data/.dispatch-log" (NOT created -- callers that
# want a dispatch log call make_path($dlog) themselves; B1 relies on it
# staying absent).
sub new_env {
    my $tmp = tempdir(CLEANUP => 1);
    my $troot = "$tmp/.ccpraxis-local-data";
    my $bp_root = "$troot/blueprints";
    make_path($bp_root);
    my $dlog = "$troot/.dispatch-log";
    return ($tmp, $bp_root, $dlog);
}

# can_detect_symlink($scratch_dir) -> 1|0 (t/45's exact technique, ported).
# Probes whether THIS host's symlink() produces something '-l' can detect,
# rather than a silent plain-directory copy (Git-for-Windows perl without
# MSYS winsymlinks). Deliberately does not assert symlink() fails/succeeds
# -- that would pin a platform quirk instead of the behaviour under test.
sub can_detect_symlink {
    my ($scratch_dir) = @_;
    my $target = "$scratch_dir/probe-target";
    my $link   = "$scratch_dir/probe-link";
    make_path($target);
    my $made = eval { symlink($target, $link) };
    my $ok = ($made && -l $link) ? 1 : 0;
    unlink($link)  if -e $link || -l $link;
    rmdir($target) if -d $target;
    return $ok;
}

# ===========================================================================
# Shape helpers -- AC1-AC5, AT-8's run_agents.
# ===========================================================================

# The 16 run-level keys package 04 pinned, per t/45/t/184's own
# @SUMMARY_KEYS -- plus AT-8's 17th, run_agents.
my @SUMMARY_KEYS_16 = qw(
    blueprint runs_dir state orchestrator_pid orchestrator_alive orchestrator_started_at
    paused_manual paused_reason packages_total packages_done current_package
    running_coordinators decisions_waiting decisions_operator decisions_triage packages
);
my @SUMMARY_KEYS_17 = (@SUMMARY_KEYS_16, 'run_agents');

my @PKG_KEYS_8 = qw(agents attempt attempt_cap name next_action status step steps_pending);

my @AGENT_KEYS = qw(budget_seconds id role stale_after_seconds started_at worker_type);
my @FORBIDDEN_AGENT_KEYS = qw(
    live alive stale is_live status elapsed elapsed_seconds uptime age pid
    attempt blueprint package
);

sub assert_17_keys {
    my ($s, $label) = @_;
    ok(is_hashref($s), "$label: summary is a hashref") or return;
    is_deeply([ sort keys %$s ], [ sort @SUMMARY_KEYS_17 ],
        "$label: AC1 [AT-8 amended, 16->17] -- exactly the 17 run-level keys, incl. run_agents");
    ok(is_arrayref($s->{run_agents}), "$label: AT-8 -- run_agents is an ARRAY ref, never undef");
}

sub assert_pkg8_shape {
    my ($e, $label) = @_;
    ok(is_hashref($e), "$label: package entry is a hashref") or return;
    is_deeply([ sort keys %$e ], [ sort @PKG_KEYS_8 ], "$label: AC2 -- exactly the 8 S2.2 keys");
    ok(is_arrayref($e->{agents}), "$label: AC3 -- agents is an ARRAY ref, never undef");
}

sub assert_agent_shape {
    my ($e, $label) = @_;
    ok(is_hashref($e), "$label: agent element is a hashref") or return;
    is_deeply([ sort keys %$e ], [ sort @AGENT_KEYS ], "$label: AC5 -- exactly the 6 S2.3 keys");
    for my $k (@FORBIDDEN_AGENT_KEYS) {
        ok(!exists($e->{$k}), "$label: AC5 -- forbidden key '$k' does not exist on the element");
    }
    ok(is_real_str($e->{id}), "$label: id companion guard -- real, unblessed scalar");
    ok(is_real_str($e->{id}) && length($e->{id}) > 0 && $e->{id} =~ /\A[A-Za-z0-9._-]{1,128}\z/,
        "$label: id is non-empty and matches /\\A[A-Za-z0-9._-]{1,128}\\z/ (S2.3)");
    ok(!defined($e->{role}) || (is_real_str($e->{role}) && $e->{role} =~ /\A(?:coordinator|worker|judge)\z/),
        "$label: role is undef or one of the closed set (Decision 6)");
    ok(is_real_str($e->{started_at}), "$label: AC19 -- started_at companion guard -- real, unblessed scalar");
    ok(defined($e->{started_at}) && $e->{started_at} =~ /\A\d+\z/ && $e->{started_at} > 0,
        "$label: AC19 -- started_at matches /\\A\\d+\\z/ and is > 0");
    ok(is_real_str($e->{stale_after_seconds}), "$label: AC19 -- stale_after_seconds companion guard -- real, unblessed scalar");
    ok(defined($e->{stale_after_seconds}) && $e->{stale_after_seconds} =~ /\A\d+\z/ && $e->{stale_after_seconds} > 0,
        "$label: AC19 -- stale_after_seconds matches /\\A\\d+\\z/ and is > 0");
}

sub assert_roles_closed {
    my ($s, $label) = @_;
    return unless is_hashref($s);
    my @all;
    push @all, @{ field($s, 'run_agents') // [] } if is_arrayref(field($s, 'run_agents'));
    for my $pe (@{ field($s, 'packages') // [] }) {
        next unless is_hashref($pe);
        push @all, @{ $pe->{agents} // [] } if is_arrayref($pe->{agents});
    }
    for my $a (@all) {
        next unless is_hashref($a);
        ok(!defined($a->{role}) || $a->{role} =~ /\A(?:coordinator|worker|judge)\z/,
            "$label: AC22 -- role '" . (defined($a->{role}) ? $a->{role} : 'undef') . "' is undef or in the closed set, no string outside it appears anywhere");
    }
}

# ===========================================================================
# 0. Load.
# ===========================================================================
use_ok('RunState');

# ===========================================================================
# 1. Module contract -- AC41, AC42, AC43, AC44.
# ===========================================================================

# --- AC41: `perl -c` clean. ------------------------------------------------
{
    my $rc_out = `"$^X" -I "$SCRIPTS_DIR" -c "$RUNSTATE_PATH" 2>&1`;
    my $rc = $? >> 8;
    is($rc, 0, 'AC41: `perl -c` on RunState.pm exits 0') or diag("  output: $rc_out");
}

# --- AC42: forbidden tokens, comments stripped; no butler/bp-dispatch-log --
# --- require/use (S1.1's plugin-boundary ruling). --------------------------
{
    my $raw = slurp($RUNSTATE_PATH);
    ok(length($raw) > 0, 'AC42 precondition: RunState.pm exists and is readable on disk') or diag("expected at $RUNSTATE_PATH");
    my $have = (length($raw) > 0);
    my $src  = $raw;
    $src =~ s/#[^\n]*//g;

    my @forbidden = (
        [ 'time(',                qr/\btime\s*\(/ ],
        [ 'localtime',            qr/\blocaltime\b/ ],
        [ 'gmtime',                qr/\bgmtime\b/ ],
        [ 'kill',                   qr/\bkill\b/ ],
        [ 'a backtick character',   qr/`/ ],
        [ 'qx',                     qr/\bqx\b/ ],
        [ 'system(',                qr/\bsystem\s*\(/ ],
        [ q{open '-|'},             qr/open\s*\(?\s*[^,]*,\s*['"]-\|['"]/ ],
        [ 'glob',                    qr/\bglob\b/ ],
        [ 'print',                   qr/\bprint\b/ ],
        [ 'warn',                     qr/\bwarn\b/ ],
        [ 'die',                      qr/\bdie\b/ ],
        [ 'Exporter/@EXPORT',         qr/\b(?:Exporter|\@EXPORT)\b/ ],
    );
    for my $f (@forbidden) {
        my ($label, $qr) = @$f;
        my $desc = "AC42: RunState.pm source (comments stripped) contains no $label";
        $have ? unlike($src, $qr, $desc) : fail("$desc [RunState.pm not on disk]");
    }
    for my $needle (qw(butler bp-dispatch-log)) {
        my $desc = "AC42: RunState.pm source contains no require/use referencing '$needle' (S1.1 plugin-boundary ruling)";
        my $qr = qr/\b(?:require|use)\b[^\n;]*\Q$needle\E/;
        $have ? unlike($src, $qr, $desc) : fail("$desc [RunState.pm not on disk]");
    }
}

# --- AC43: t/45-run-state.t green, and its own @SUMMARY_KEYS still holds --
# --- 16 names with no 'agents' among them (t/45 itself is NEVER edited). --
{
    ok(-f $T45_PATH, 'AC43 precondition: t/45-run-state.t exists');
    my $out = `"$^X" "$T45_PATH" 2>&1`;
    my $rc = $? >> 8;
    is($rc, 0, 'AC43: `perl t/45-run-state.t` exits 0');
    my @not_ok = grep { /^not ok/ } split /\n/, $out;
    is(scalar(@not_ok), 0, 'AC43: t/45-run-state.t has zero "not ok" lines') or diag(join("\n", @not_ok));

    my $t45_src = slurp($T45_PATH);
    ok(length($t45_src) > 0, 'AC43 precondition: t/45-run-state.t is readable on disk');
    if ($t45_src =~ /\@SUMMARY_KEYS\s*=\s*qw\(([^)]*)\)/s) {
        my @names = split ' ', $1;
        # Ruling AT-11: AC43 pinned 16, the pre-AT-8 count. AT-8 added run_agents as a
        # 17th always-present key and AT-10 authorised t/45's widening, so asserting 16
        # here pins a contract the driver deliberately superseded.
        is(scalar(@names), 17, 'AC43: t/45 @SUMMARY_KEYS holds all 17 names (AT-8 widening)');
        ok(!(grep { $_ eq 'agents' } @names), q{AC43: t/45 @SUMMARY_KEYS contains no 'agents'});
    }
    else {
        fail('AC43: could not locate "@SUMMARY_KEYS = qw(...)" in t/45-run-state.t source');
    }
}

# --- AC44: t/184-runstate-package-facts.t green after its one authorised --
# --- edit (S2.10); no PKG_KEYS_7 identifier remains anywhere in it. -------
{
    ok(-f $T184_PATH, 'AC44 precondition: t/184-runstate-package-facts.t exists');
    my $out = `"$^X" "$T184_PATH" 2>&1`;
    my $rc = $? >> 8;
    is($rc, 0, 'AC44: `perl t/184-runstate-package-facts.t` exits 0');
    my @not_ok = grep { /^not ok/ } split /\n/, $out;
    is(scalar(@not_ok), 0, 'AC44: t/184-runstate-package-facts.t has zero "not ok" lines') or diag(join("\n", @not_ok));

    my $t184_src = slurp($T184_PATH);
    unlike($t184_src, qr/\bPKG_KEYS_7\b/, 'AC44: t/184 source contains no identifier PKG_KEYS_7');
}

# --- AC32: constants. -------------------------------------------------------
{
    is($RunState::MAX_DISPATCH_RECORDS, SPEC_MAX_DISPATCH_RECORDS, 'AC32: $RunState::MAX_DISPATCH_RECORDS == 512');
    is($RunState::MAX_REGISTRY_BYTES, SPEC_MAX_REGISTRY_BYTES, 'AC32: $RunState::MAX_REGISTRY_BYTES unchanged (4 MiB)');
    is($RunState::MAX_LEDGER_BYTES,   SPEC_MAX_LEDGER_BYTES,   'AC32: $RunState::MAX_LEDGER_BYTES unchanged (64 KiB)');
    is($RunState::MAX_MARKER_BYTES,   SPEC_MAX_MARKER_BYTES,   'AC32: $RunState::MAX_MARKER_BYTES unchanged (4096)');
    is($RunState::MAX_PACKAGES,       SPEC_MAX_PACKAGES,       'AC32: $RunState::MAX_PACKAGES unchanged (512)');
}

# --- AC37: _dispatch_dir -- pure string arithmetic, no filesystem access. --
{
    my @table = (
        [ 'undef',                                   undef,                                   undef ],
        [ "''",                                       '',                                       undef ],
        [ '[]',                                        [],                                       undef ],
        [ q{"/tmp"},                                    '/tmp',                                   undef ],
        [ q{"/tmp/blueprints"},                          '/tmp/blueprints',                        undef ],
        [ q{"/tmp/.ccpraxis-local-data"},                 '/tmp/.ccpraxis-local-data',               undef ],
        [ q{"/p/.ccpraxis-local-data/blueprints"},         '/p/.ccpraxis-local-data/blueprints',       '/p/.ccpraxis-local-data/.dispatch-log' ],
        [ q{"/p/.ccpraxis-local-data/blueprints/"},         '/p/.ccpraxis-local-data/blueprints/',       '/p/.ccpraxis-local-data/.dispatch-log' ],
        [ q{"/p/.ccpraxis-local-data/blueprints///"},        '/p/.ccpraxis-local-data/blueprints///',      '/p/.ccpraxis-local-data/.dispatch-log' ],
        [ 'backslash form',                                   '\\p\\.ccpraxis-local-data\\blueprints',      '/p/.ccpraxis-local-data/.dispatch-log' ],
    );
    for my $c (@table) {
        my ($label, $arg, $want) = @$c;
        my $got = RS('_dispatch_dir', $arg);
        if (defined $want) {
            ok(is_real_str($got), "AC37: _dispatch_dir($label) companion guard -- real, unblessed scalar");
            is($got, $want, "AC37: _dispatch_dir($label) eq '$want'");
        }
        else {
            ok(!defined($got), "AC37: _dispatch_dir($label) is undef");
        }
    }
}

# --- AC36: _dispatch_index -- always a HASH ref, never undef, never dies. -
{
    my ($tmp) = new_env();
    for my $c (
        [ 'undef', undef ], [ "''", '' ], [ '[]', [] ],
        [ 'a nonexistent path', "$tmp/does/not/exist" ],
    ) {
        my ($label, $arg) = @$c;
        my ($res, $err, $warns) = probe_call('_dispatch_index', $arg);
        is($err, '', "AC36: _dispatch_index($label) does not die");
        ok(is_hashref($res), "AC36: _dispatch_index($label) returns a HASH ref");
    }
    my $plain = "$tmp/plainfile";
    write_file($plain, 'x');
    ok(is_hashref(RS('_dispatch_index', $plain)), 'AC36: _dispatch_index(a plain file path) returns a HASH ref');

    my $probe_dir = tempdir(CLEANUP => 1);
    my $detectable = can_detect_symlink($probe_dir);
  SKIP: {
        skip 'this host\'s symlink() produces an undetectable copy, not a "-l"-true link -- cannot construct a symlink-to-directory fixture', 1
            unless $detectable;
        my $root2  = tempdir(CLEANUP => 1);
        my $target = "$root2/tgt";
        make_path($target);
        my $link = "$root2/lnk";
        symlink($target, $link);
        ok(is_hashref(RS('_dispatch_index', $link)), 'AC36: _dispatch_index(a symlink to a directory) returns a HASH ref');
    }
}

# ===========================================================================
# 2. No dispatch log at all / empty dispatch log -- B1, B2.
# ===========================================================================
{
    my ($tmp, $bp_root, $dlog) = new_env();
    my $dir = make_blueprint($bp_root, 'b1bp', registry => registry_json(),
        packages => { '01-a' => mk_ledger(status => 'running', pipeline => 1), '02-b' => mk_ledger(status => 'running', pipeline => 1) });
    my $s = SDIR($dir, 'B1');
    assert_17_keys($s, 'B1');
    for my $pkg ('01-a', '02-b') {
        my $e = find_pkg($s, $pkg);
        assert_pkg8_shape($e, "B1 [$pkg]");
        is_deeply(field($e, 'agents'), [], "B1 [$pkg]: agents == [] (no .dispatch-log directory at all)");
    }
    is_deeply(field($s, 'run_agents'), [], 'B1: run_agents == [] (AT-8, no dispatch log)');
}
{
    my ($tmp, $bp_root, $dlog) = new_env();
    make_path($dlog);
    my $dir = make_blueprint($bp_root, 'b2bp', registry => registry_json(), packages => { '01-a' => mk_ledger(status => 'running', pipeline => 1) });
    my $s = SDIR($dir, 'B2');
    my $e = find_pkg($s, '01-a');
    is_deeply(field($e, 'agents'), [], 'B2 [01-a]: agents == [] (.dispatch-log exists and is empty)');
    is_deeply(field($s, 'run_agents'), [], 'B2: run_agents == []');
}

# ===========================================================================
# 3. AC4 -- the seven package-04 keys unchanged. -----------------------------
# ===========================================================================
{
    local $ENV{BP_ATTEMPT_CAP};
    delete $ENV{BP_ATTEMPT_CAP};
    my ($tmp, $bp_root, $dlog) = new_env();   # no dispatch log at all
    my $ledger = mk_ledger(status => 'running', pipeline => 1, marks => { 1 => 'x', 2 => 'X' }, next_action => 'Do the next concrete thing.');
    my $dir = make_blueprint($bp_root, 'ac4bp', registry => registry_json(p1 => { status => 'running', attempt => 2 }), packages => { p1 => $ledger });
    my $s = SDIR($dir, 'AC4');
    my $e = find_pkg($s, 'p1');
    is(field($e, 'status'), 'running', 'AC4: status unchanged from package 04 behaviour');
    is(field($e, 'step'), '3/8', 'AC4: step unchanged (steps 1,2 ticked -> 3/8)');
    is_deeply(field($e, 'steps_pending'), [ 3, 4, 5, 6, 7, 8 ], 'AC4: steps_pending unchanged');
    is(field($e, 'next_action'), 'Do the next concrete thing.', 'AC4: next_action unchanged');
    is(field($e, 'attempt'), 2, 'AC4: attempt unchanged (from registry)');
    is(field($e, 'attempt_cap'), 5, 'AC4: attempt_cap unchanged (default cap)');
    is_deeply(field($e, 'agents'), [], 'AC4: agents == [] -- the only NEW key, everything else untouched');
}

# ===========================================================================
# 4. AC6/AC7 -- selection, blueprint/package match, cross-blueprint no-op. --
# ===========================================================================
{
    my ($tmp, $bp_root, $dlog) = new_env();
    make_path($dlog);
    my $dir = make_blueprint($bp_root, 'alpha', registry => registry_json(),
        packages => { '01-a' => mk_ledger(status => 'running', pipeline => 1), '02-b' => mk_ledger(status => 'running', pipeline => 1) });
    my $stem = 'ac6-worker';
    write_record_file($dlog, $stem, base_record(started_at => NUM(1000), budget_seconds => NUM(600)));

    my $s1 = SDIR($dir, 'AC6');
    my $e1 = find_pkg($s1, '01-a');
    assert_pkg8_shape($e1, 'AC6 [01-a]');
    is(scalar(@{ field($e1, 'agents') // [] }), 1, 'AC6: 01-a has exactly one agent');
    my $agent = (field($e1, 'agents') // [])->[0];
    assert_agent_shape($agent, 'AC6');
    is_deeply($agent,
        { id => $stem, role => 'worker', worker_type => 'bp-implementer', started_at => 1000, budget_seconds => 600, stale_after_seconds => 2400 },
        'AC6: agent element matches expected shape exactly (is_deeply)');
    is((field(find_pkg($s1, '02-b'), 'agents') // [])->[0], undef, 'AC6: 02-b has no agents');
    is_deeply(field(find_pkg($s1, '02-b'), 'agents'), [], 'AC6: 02-b agents == []');

    # AC7: a record for a DIFFERENT blueprint leaves alpha's summary byte-
    # identical.
    write_record_file($dlog, 'ac7-other-bp', base_record(blueprint => 'beta', started_at => NUM(2000)));
    my $s2 = SDIR($dir, 'AC7');
    is_deeply($s2, $s1, 'AC7: alpha summary is byte-identical (is_deeply) after adding a beta-blueprint record');
}

# ===========================================================================
# 5. AC8/B5 -- record's package names a package this blueprint doesn't
#    have (NOT the AT-8 _run case -- that is AC9, below, separately).
# ===========================================================================
{
    my ($tmp, $bp_root, $dlog) = new_env();
    make_path($dlog);
    my $dir = make_blueprint($bp_root, 'alpha', registry => registry_json(), packages => { '01-a' => mk_ledger(status => 'running', pipeline => 1) });
    write_record_file($dlog, 'ac8-nope', base_record(package => '99-nope', started_at => NUM(3000)));
    my $s = SDIR($dir, 'AC8');
    for my $e (@{ field($s, 'packages') }) {
        is_deeply(field($e, 'agents'), [], "AC8: package '" . field($e, 'name') . "' agents == []");
    }
}

# ===========================================================================
# 6. AC9 [AT-8 AMENDED] -- package: "_run" (bp-orchestrator.pl:2095's
#    conformance-judge shape) surfaces in run_agents, no longer silently
#    dropped. THE SPEC'S OWN AC9 TEXT ("every entry's agents is []", full
#    stop) IS NOT ENCODED -- it is superseded. Both halves asserted here:
#    packages are unaffected (still true), and run_agents is populated
#    (the new, correct half).
# ===========================================================================
{
    my ($tmp, $bp_root, $dlog) = new_env();
    make_path($dlog);
    my $dir = make_blueprint($bp_root, 'alpha', registry => registry_json(), packages => { '01-a' => mk_ledger(status => 'running', pipeline => 1) });
    write_record_file($dlog, 'ac9-run-judge', base_record(
        package => '_run', role => 'judge', worker_type => 'bp-resolve-judge',
        started_at => NUM(5000), budget_seconds => NUM(900),
    ));
    my $s = SDIR($dir, 'AC9 [AT-8 amended]');
    assert_17_keys($s, 'AC9 [AT-8 amended]');
    my $e = find_pkg($s, '01-a');
    is_deeply(field($e, 'agents'), [], 'AC9 [AT-8]: the _run record does not attach to any real package (package axis still exact-match)');
    my $ra = field($s, 'run_agents');
    ok(is_arrayref($ra), 'AC9 [AT-8]: run_agents is an arrayref');
    is(scalar(@$ra), 1, 'AC9 [AT-8]: run_agents has exactly one element -- the _run judge is no longer silently dropped');
    if (@$ra) {
        assert_agent_shape($ra->[0], 'AC9 [AT-8]');
        is_deeply($ra->[0],
            { id => 'ac9-run-judge', role => 'judge', worker_type => 'bp-resolve-judge', started_at => 5000, budget_seconds => 900, stale_after_seconds => 3600 },
            'AC9 [AT-8]: run_agents element matches the expected shape exactly');
    }
}

# ===========================================================================
# 7. AC10/B7 -- six vectors of missing/null/empty blueprint or package. -----
# ===========================================================================
{
    my ($tmp, $bp_root, $dlog) = new_env();
    make_path($dlog);
    my $dir = make_blueprint($bp_root, 'alpha', registry => registry_json(), packages => { '01-a' => mk_ledger(status => 'running', pipeline => 1) });
    my @cases = (
        [ 'blueprint missing', { blueprint => OMIT() } ],
        [ 'blueprint null',    { blueprint => NULLV() } ],
        [ q{blueprint ''},     { blueprint => '' } ],
        [ 'package missing',   { package => OMIT() } ],
        [ 'package null',      { package => NULLV() } ],
        [ q{package ''},       { package => '' } ],
    );
    my $i = 0;
    for my $c (@cases) {
        my ($label, $ov) = @$c;
        $i++;
        write_record_file($dlog, "ac10-$i", base_record(%$ov, started_at => NUM(4000 + $i)));
    }
    my $s = SDIR($dir, 'AC10');
    for my $e (@{ field($s, 'packages') }) {
        is_deeply(field($e, 'agents'), [], "AC10: package '" . field($e, 'name') . "' agents == [] (all six malformed-attribution records excluded)");
    }
}

# ===========================================================================
# 8. AC11 -- the blueprint match is exact-byte, against the summary's OWN
#    blueprint value (André bytes, and an ASCII lookalike that must not
#    match).
# ===========================================================================
{
    my ($tmp, $bp_root, $dlog) = new_env();
    make_path($dlog);
    my $bp_name = "andr\xC3\xA9-bp";
    my $dir = make_blueprint($bp_root, $bp_name, registry => registry_json(), packages => { '01-a' => mk_ledger(status => 'running', pipeline => 1) });
    write_record_file($dlog, 'ac11-match',   base_record(blueprint => $bp_name,  started_at => NUM(6000)));
    write_record_file($dlog, 'ac11-nomatch', base_record(blueprint => 'andre-bp', started_at => NUM(6100)));
    my $s = SDIR($dir, 'AC11');
    is(field($s, 'blueprint'), $bp_name, 'AC11 precondition: summary blueprint value is the raw UTF-8-byte name');
    my $e = find_pkg($s, '01-a');
    is(scalar(@{ field($e, 'agents') // [] }), 1, 'AC11: exactly one agent attaches (the byte-exact match)');
    is((field($e, 'agents') // [])->[0]{id}, 'ac11-match', 'AC11: the attached agent is the byte-exact-blueprint record, not the ASCII lookalike');
}

# ===========================================================================
# 9. AC12/B16 -- André café package name, byte-exact on both sides. --------
# ===========================================================================
{
    my ($tmp, $bp_root, $dlog) = new_env();
    make_path($dlog);
    my $pkg_name = "andr\xC3\xA9-caf\xC3\xA9";
    my $dir = make_blueprint($bp_root, 'alpha', registry => registry_json(), packages => { $pkg_name => mk_ledger(status => 'running', pipeline => 1) });
    write_record_file($dlog, 'ac12-match', base_record(package => $pkg_name, started_at => NUM(6200)));
    my $s = SDIR($dir, 'AC12');
    my $e = find_pkg($s, $pkg_name);
    ok(is_hashref($e), 'AC12: the andré-café package entry is found by its byte-exact name');
    is(field($e, 'name'), $pkg_name, 'AC12: entry name is byte-identical to the filename stem');
    is(scalar(@{ field($e, 'agents') // [] }), 1, 'AC12: the record attaches to the andré-café entry');
}

# ===========================================================================
# 10. AC13/B18 -- ledger with no matching record, AND record with no
#     matching ledger, present simultaneously.
# ===========================================================================
{
    my ($tmp, $bp_root, $dlog) = new_env();
    make_path($dlog);
    my $dir = make_blueprint($bp_root, 'alpha', registry => registry_json(), packages => { '01-a' => mk_ledger(status => 'running', pipeline => 1) });
    write_record_file($dlog, 'ac13-orphan', base_record(package => 'zz-ghost', started_at => NUM(6300)));
    my $s = SDIR($dir, 'AC13');
    my $e = find_pkg($s, '01-a');
    is_deeply(field($e, 'agents'), [], 'AC13: the ledgered package with no matching record has agents == []');
    my $found_orphan = 0;
    for my $pe (@{ field($s, 'packages') }) {
        for my $a (@{ field($pe, 'agents') // [] }) {
            $found_orphan = 1 if is_hashref($a) && (($a->{id} // '') eq 'ac13-orphan');
        }
    }
    for my $a (@{ field($s, 'run_agents') // [] }) {
        $found_orphan = 1 if is_hashref($a) && (($a->{id} // '') eq 'ac13-orphan');
    }
    ok(!$found_orphan, 'AC13: the orphan record (package zz-ghost, no matching ledger) appears nowhere in the returned structure');
}

# ===========================================================================
# 11. AC14/B8 -- finished-status vectors excluded, only running survives. --
# ===========================================================================
{
    my ($tmp, $bp_root, $dlog) = new_env();
    make_path($dlog);
    my $dir = make_blueprint($bp_root, 'alpha', registry => registry_json(), packages => { '01-a' => mk_ledger(status => 'running', pipeline => 1) });
    my @statuses = ( [ 'done', 'done' ], [ 'interrupted', 'interrupted' ], [ 'killed', 'killed' ], [ q{''}, '' ], [ 'no status key', OMIT() ] );
    my $i = 0;
    for my $c (@statuses) {
        my ($label, $val) = @$c;
        $i++;
        write_record_file($dlog, "ac14-fin-$i", base_record(status => $val, started_at => NUM(7000 + $i)));
    }
    write_record_file($dlog, 'ac14-running', base_record(status => 'running', started_at => NUM(7100)));
    my $s = SDIR($dir, 'AC14');
    my $e = find_pkg($s, '01-a');
    is(scalar(@{ field($e, 'agents') // [] }), 1, 'AC14: exactly one agent (the running one) survives among 5 finished-status vectors');
    is((field($e, 'agents') // [])->[0]{id}, 'ac14-running', 'AC14: the surviving agent is the running record');
}

# ===========================================================================
# 12. AC15 -- status as a hashref -> skipped, no warning (SDIR's own
#     $SIG{__WARN__} collector IS the AC15 assertion).
# ===========================================================================
{
    my ($tmp, $bp_root, $dlog) = new_env();
    make_path($dlog);
    my $dir = make_blueprint($bp_root, 'alpha', registry => registry_json(), packages => { '01-a' => mk_ledger(status => 'running', pipeline => 1) });
    write_record_file($dlog, 'ac15-refstatus', base_record(status => RAWV('{}'), started_at => NUM(7200)));
    my $s = SDIR($dir, 'AC15');
    my $e = find_pkg($s, '01-a');
    is_deeply(field($e, 'agents'), [], 'AC15: a record whose status is a hashref is skipped (and SDIR above already asserted no warning)');
}

# ===========================================================================
# 13. AC16/B9 -- started_at unusable vectors excluded. ----------------------
# ===========================================================================
{
    my ($tmp, $bp_root, $dlog) = new_env();
    make_path($dlog);
    my $dir = make_blueprint($bp_root, 'alpha', registry => registry_json(), packages => { '01-a' => mk_ledger(status => 'running', pipeline => 1) });
    my @vecs = (
        [ 'absent',  OMIT() ], [ 'null', NULLV() ], [ q{"abc"}, 'abc' ],
        [ '-5', NUM(-5) ], [ '1.5', NUM(1.5) ], [ q{"1e9"}, '1e9' ], [ '0', NUM(0) ],
    );
    my $i = 0;
    for my $v (@vecs) {
        my ($label, $val) = @$v;
        $i++;
        write_record_file($dlog, "ac16-bad-$i", base_record(started_at => $val));
    }
    write_record_file($dlog, 'ac16-good', base_record(started_at => NUM(1)));
    my $s = SDIR($dir, 'AC16');
    my $e = find_pkg($s, '01-a');
    is(scalar(@{ field($e, 'agents') // [] }), 1, 'AC16: agents has exactly one element among 7 unusable started_at vectors');
    is((field($e, 'agents') // [])->[0]{id}, 'ac16-good', 'AC16: the surviving agent is the one with a usable started_at');
}

# ===========================================================================
# 14. AC17/B10 -- two running records, one far outside any real staleness
#     window: BOTH appear; neither carries a liveness-shaped key. 05 does
#     not filter on elapsed time.
# ===========================================================================
{
    my ($tmp, $bp_root, $dlog) = new_env();
    make_path($dlog);
    my $dir = make_blueprint($bp_root, 'alpha', registry => registry_json(), packages => { '01-a' => mk_ledger(status => 'running', pipeline => 1) });
    write_record_file($dlog, 'ac17-old',  base_record(started_at => NUM(1000), budget_seconds => NUM(600)));
    write_record_file($dlog, 'ac17-huge', base_record(started_at => NUM(9_000_000_000), budget_seconds => NUM(600)));
    my $s = SDIR($dir, 'AC17');
    my $e = find_pkg($s, '01-a');
    is(scalar(@{ field($e, 'agents') // [] }), 2, 'AC17: both records appear -- 05 does not filter on elapsed time');
    for my $a (@{ field($e, 'agents') // [] }) {
        my $id = is_hashref($a) ? ($a->{id} // '?') : '?';
        assert_agent_shape($a, "AC17 [id=$id]");
        is($a->{stale_after_seconds}, 2400, "AC17 [id=$id]: stale_after_seconds == 2400 regardless of started_at's magnitude");
    }
}

# ===========================================================================
# 15. AC18 -- table-driven budget_seconds -> (budget_seconds, stale_after_seconds).
# ===========================================================================
{
    my ($tmp, $bp_root, $dlog) = new_env();
    make_path($dlog);
    my $dir = make_blueprint($bp_root, 'alpha', registry => registry_json(), packages => { '01-a' => mk_ledger(status => 'running', pipeline => 1) });
    my @table = (
        [ '600',    NUM(600),    600,    2400 ],
        [ '1800',   NUM(1800),   1800,   7200 ],
        [ '604800', NUM(604800), 604800, 2419200 ],
        [ '604801', NUM(604801), undef,  7200 ],
        [ 'absent', OMIT(),      undef,  7200 ],
        [ '0',      NUM(0),      undef,  7200 ],
        [ '-1',     NUM(-1),     undef,  7200 ],
        [ q{"abc"}, 'abc',       undef,  7200 ],
        [ '1e21',   RAWV('1e21'), undef, 7200 ],
        [ '[]',     RAWV('[]'),  undef,  7200 ],
    );
    my $i = 0;
    for my $row (@table) {
        my ($label, $val, $want_b, $want_s) = @$row;
        $i++;
        my $stem = "ac18-$i";
        write_record_file($dlog, $stem, base_record(started_at => NUM(100 + $i), budget_seconds => $val));
        my $s = SDIR($dir, "AC18 [$label]");
        my $e = find_pkg($s, '01-a');
        my ($a) = grep { is_hashref($_) && (($_->{id} // '') eq $stem) } @{ field($e, 'agents') // [] };
        ok(is_hashref($a), "AC18 [$label]: precondition -- the record is present in agents") or next;
        ok(!defined($a->{budget_seconds}) || is_real_str($a->{budget_seconds}), "AC18 [$label]: budget_seconds companion guard");
        is($a->{budget_seconds}, $want_b, 'AC18 [' . $label . ']: budget_seconds == ' . (defined($want_b) ? $want_b : 'undef'));
        ok(is_real_str($a->{stale_after_seconds}), "AC18 [$label]: stale_after_seconds companion guard -- real, unblessed scalar");
        is($a->{stale_after_seconds}, $want_s, "AC18 [$label]: stale_after_seconds == $want_s");
    }
}

# ===========================================================================
# 16. AC20/AC21/AC22/B6 -- role: closed set, everything else -> undef. -----
# ===========================================================================
{
    my ($tmp, $bp_root, $dlog) = new_env();
    make_path($dlog);
    my $dir = make_blueprint($bp_root, 'alpha', registry => registry_json(), packages => { '01-a' => mk_ledger(status => 'running', pipeline => 1) });
    write_record_file($dlog, 'ac20-c', base_record(role => 'coordinator', started_at => NUM(100)));
    write_record_file($dlog, 'ac20-w', base_record(role => 'worker',      started_at => NUM(200)));
    write_record_file($dlog, 'ac20-j', base_record(role => 'judge',       started_at => NUM(300)));
    my $s = SDIR($dir, 'AC20');
    my $e = find_pkg($s, '01-a');
    my @roles = sort map { $_->{role} } @{ field($e, 'agents') // [] };
    is_deeply(\@roles, [ 'coordinator', 'judge', 'worker' ], 'AC20: three elements whose role values, sorted, are exactly those three strings');
}
{
    my ($tmp, $bp_root, $dlog) = new_env();
    make_path($dlog);
    my $dir = make_blueprint($bp_root, 'alpha', registry => registry_json(), packages => { '01-a' => mk_ledger(status => 'running', pipeline => 1) });
    my @vecs = (
        [ 'admiral', 'admiral' ], [ q{'Worker' wrong case}, 'Worker' ], [ q{''}, '' ],
        [ 'null', NULLV() ], [ '[]', RAWV('[]') ], [ 'no role key', OMIT() ],
    );
    my $i = 0;
    for my $v (@vecs) {
        my ($label, $val) = @$v;
        $i++;
        write_record_file($dlog, "ac21-$i", base_record(role => $val, started_at => NUM(400 + $i)));
    }
    my $s = SDIR($dir, 'AC21');
    my $e = find_pkg($s, '01-a');
    is(scalar(@{ field($e, 'agents') // [] }), 6, 'AC21: all six vectors survive (an unrecognised role is not a survival filter)');
    for my $a (@{ field($e, 'agents') // [] }) {
        ok(!defined($a->{role}), 'AC21: element id=' . ($a->{id} // '?') . ' has role => undef (asserted as !defined, not as falsy)');
    }
    assert_roles_closed($s, 'AC22');
}

# ===========================================================================
# 17. AC23-AC27 -- worker_type. ----------------------------------------------
# ===========================================================================
{
    # AC23: unchanged, byte-identical.
    my ($tmp, $bp_root, $dlog) = new_env();
    make_path($dlog);
    my $dir = make_blueprint($bp_root, 'alpha', registry => registry_json(), packages => { '01-a' => mk_ledger(status => 'running', pipeline => 1) });
    write_record_file($dlog, 'ac23', base_record(worker_type => 'bp-implementer', started_at => NUM(500)));
    my $s = SDIR($dir, 'AC23');
    my $e = find_pkg($s, '01-a');
    is((field($e, 'agents') // [])->[0]{worker_type}, 'bp-implementer', 'AC23: worker_type returned unchanged, byte-identical');
}
{
    # AC24: control bytes (incl. a raw ESC and a NUL) sanitised.
    my ($tmp, $bp_root, $dlog) = new_env();
    make_path($dlog);
    my $dir = make_blueprint($bp_root, 'alpha', registry => registry_json(), packages => { '01-a' => mk_ledger(status => 'running', pipeline => 1) });
    write_record_file($dlog, 'ac24', base_record(worker_type => "a\x1b[31mb\x00c", started_at => NUM(501)));
    my $s = SDIR($dir, 'AC24');
    my $e = find_pkg($s, '01-a');
    my $v = (field($e, 'agents') // [])->[0]{worker_type};
    ok(is_real_str($v), 'AC24: companion guard -- worker_type is defined and unblessed');
    if (is_real_str($v)) {
        my @bytes = unpack('C*', $v);
        ok(!(grep { $_ < 0x20 || $_ == 0x7F } @bytes), 'AC24: every byte of the sanitised worker_type is >= 0x20 and != 0x7F');
    }
}
{
    # AC25: 300 ASCII bytes -> length <= 64.
    my ($tmp, $bp_root, $dlog) = new_env();
    make_path($dlog);
    my $dir = make_blueprint($bp_root, 'alpha', registry => registry_json(), packages => { '01-a' => mk_ledger(status => 'running', pipeline => 1) });
    write_record_file($dlog, 'ac25', base_record(worker_type => ('x' x 300), started_at => NUM(502)));
    my $s = SDIR($dir, 'AC25');
    my $v = (field(find_pkg($s, '01-a'), 'agents') // [])->[0]{worker_type};
    ok(is_real_str($v), 'AC25: companion guard -- worker_type is defined and unblessed');
    ok(is_real_str($v) && length($v) <= 64, 'AC25: worker_type truncated to <= 64 bytes');
}
{
    # AC26: 70 bytes total, with the two bytes of e-acute placed so the
    # 64-byte truncation cut lands ON the lead byte of the sequence (byte
    # index 63 is 0xC3) -- exercising the split-UTF-8 repair branch, not
    # just skirting past it. 63 'a' bytes (indices 0-62) + e-acute (indices
    # 63-64) + 5 'b' bytes (indices 65-69) == 70 bytes total.
    my ($tmp, $bp_root, $dlog) = new_env();
    make_path($dlog);
    my $dir = make_blueprint($bp_root, 'alpha', registry => registry_json(), packages => { '01-a' => mk_ledger(status => 'running', pipeline => 1) });
    my $wt = ('a' x 63) . "\xC3\xA9" . ('b' x 5);   # 70 bytes total
    is(length($wt), 70, 'AC26 precondition: fixture worker_type is 70 bytes');
    is(substr($wt, 63, 1), "\xC3", 'AC26 precondition: byte 63 (0-indexed) is the e-acute lead byte, i.e. the 64-byte cut lands mid-sequence');
    write_record_file($dlog, 'ac26', base_record(worker_type => $wt, started_at => NUM(503)));
    my $s = SDIR($dir, 'AC26');
    my $v = (field(find_pkg($s, '01-a'), 'agents') // [])->[0]{worker_type};
    ok(is_real_str($v), 'AC26: companion guard -- worker_type is defined and unblessed');
    if (is_real_str($v)) {
        ok(length($v) <= 64, 'AC26: result is at most 64 bytes');
        my $decoded_ok = eval { Encode::decode('UTF-8', $v, Encode::FB_CROAK()); 1 };
        ok($decoded_ok, 'AC26: result decodes cleanly under Encode::decode(UTF-8, ..., FB_CROAK) -- no split multi-byte sequence');
    }
}
{
    # fix-batch MEDIUM-1: a worker_type written with JSON \uXXXX escapes
    # above U+00FF decodes (via JSON::PP, no ->utf8) to a UTF8-FLAGGED
    # character string, so length()/substr() in _rec_worker_type would
    # previously count CODE POINTS, not bytes -- a 70-character CJK value
    # passed the "<= 64" check while being 192 UTF-8 bytes. Written directly
    # as raw JSON (RAWV) rather than through json_str/json_escape, which
    # only ever emits raw UTF-8 bytes and could not reproduce this shape.
    my ($tmp, $bp_root, $dlog) = new_env();
    make_path($dlog);
    my $dir = make_blueprint($bp_root, 'alpha', registry => registry_json(), packages => { '01-a' => mk_ledger(status => 'running', pipeline => 1) });
    my $u_escape = chr(0x5C) . 'u4f60';   # a literal backslash + 'u4f60', built via chr() to sidestep Perl's own \u (case-fold) string escape
    my $wt_json = q{"} . (($u_escape) x 70) . q{"};
    write_record_file($dlog, 'ac26b', base_record(worker_type => RAWV($wt_json), started_at => NUM(504)));
    my $s = SDIR($dir, 'AC26b (fix-batch MEDIUM-1)');
    my $v = (field(find_pkg($s, '01-a'), 'agents') // [])->[0]{worker_type};
    ok(is_real_str($v), 'AC26b: companion guard -- worker_type is defined and unblessed');
    if (is_real_str($v)) {
        ok(!utf8::is_utf8($v), 'AC26b: result is a byte string, not UTF8-flagged (the bound operates on bytes, not the JSON::PP decode\'s character view)');
        ok(length($v) <= 64, 'AC26b: result is at most 64 BYTES (a pre-fix build would pass this at 64 CHARACTERS / 192 bytes -- see the next assertion)')
            or diag('byte length: ' . length($v));
        my $decoded_ok = eval { Encode::decode('UTF-8', $v, Encode::FB_CROAK()); 1 };
        ok($decoded_ok, 'AC26b: result decodes cleanly under Encode::decode(UTF-8, ..., FB_CROAK) -- no split multi-byte sequence');
    }
}
{
    # AC27: absent/null/''/whitespace-only/ref -> undef.
    my ($tmp, $bp_root, $dlog) = new_env();
    make_path($dlog);
    my $dir = make_blueprint($bp_root, 'alpha', registry => registry_json(), packages => { '01-a' => mk_ledger(status => 'running', pipeline => 1) });
    my @vecs = ( [ 'absent', OMIT() ], [ 'null', NULLV() ], [ q{''}, '' ], [ q{'   '}, '   ' ], [ 'ref {}', RAWV('{}') ] );
    my $i = 0;
    for my $v (@vecs) {
        my ($label, $val) = @$v;
        $i++;
        write_record_file($dlog, "ac27-$i", base_record(worker_type => $val, started_at => NUM(504 + $i)));
    }
    my $s = SDIR($dir, 'AC27');
    my $e = find_pkg($s, '01-a');
    is(scalar(@{ field($e, 'agents') // [] }), 5, 'AC27: all five vectors survive (worker_type is not a survival filter)');
    for my $a (@{ field($e, 'agents') // [] }) {
        ok(!defined($a->{worker_type}), 'AC27: element id=' . ($a->{id} // '?') . ' has worker_type => undef (asserted as !defined)');
    }
}

# ===========================================================================
# 18. AC28/AC29 -- id is the filename stem, never the body's own "id"; ------
#     directory-entry junk is never opened, a valid sibling still appears.
# ===========================================================================
{
    my ($tmp, $bp_root, $dlog) = new_env();
    make_path($dlog);
    my $dir = make_blueprint($bp_root, 'alpha', registry => registry_json(), packages => { '01-a' => mk_ledger(status => 'running', pipeline => 1) });
    write_record_file($dlog, 'at-05-impl', base_record(id => 'something-else', started_at => NUM(900)));
    my $s = SDIR($dir, 'AC28');
    my $e = find_pkg($s, '01-a');
    is((field($e, 'agents') // [])->[0]{id}, 'at-05-impl', 'AC28: id is the record FILENAME STEM ("at-05-impl"), never the JSON body\'s own "id" field ("something-else")');
}
{
    my ($tmp, $bp_root, $dlog) = new_env();
    make_path($dlog);
    my $dir = make_blueprint($bp_root, 'alpha', registry => registry_json(), packages => { '01-a' => mk_ledger(status => 'running', pipeline => 1) });
    # Each of these is written with a FULLY VALID record body under a
    # directory-entry name that must never be opened at all -- so if the
    # implementation buggily ignores the S2.5 stem test / .jsonl extension,
    # the content would leak into agents and this assertion would catch it.
    write_file("$dlog/history.jsonl", rec_json(merge_fields(base_record(started_at => NUM(940)))));
    write_file("$dlog/notes.txt",     rec_json(merge_fields(base_record(started_at => NUM(945)))));
    write_file("$dlog/bad name.json", rec_json(merge_fields(base_record(started_at => NUM(950)))));
    write_record_file($dlog, 'ac29-good', base_record(started_at => NUM(960)));
    my $s = SDIR($dir, 'AC29');
    my $e = find_pkg($s, '01-a');
    is(scalar(@{ field($e, 'agents') // [] }), 1, 'AC29: only the one valid sibling record appears -- history.jsonl / notes.txt / "bad name.json" are never opened');
    is((field($e, 'agents') // [])->[0]{id}, 'ac29-good', 'AC29: the surviving agent is the valid sibling');
    # NOT ASSERTED, deliberately (see file header): ".hidden.json" (its stem
    # ".hidden" actually PASSES the pinned S2.5 regex, contradicting AC29's
    # own framing) and "../evil.json" (unrealisable as a literal readdir
    # entry -- a path separator cannot be part of one filesystem component).
}

# ===========================================================================
# 19. AC30/AC31/B17 -- ordering: started_at ascending, id ascending on ties.
# ===========================================================================
{
    my ($tmp, $bp_root, $dlog) = new_env();
    make_path($dlog);
    my $dir = make_blueprint($bp_root, 'alpha', registry => registry_json(), packages => { '01-a' => mk_ledger(status => 'running', pipeline => 1) });
    write_record_file($dlog, 'ac30-c', base_record(started_at => NUM(300)));
    write_record_file($dlog, 'ac30-a', base_record(started_at => NUM(100)));
    write_record_file($dlog, 'ac30-b', base_record(started_at => NUM(200)));
    my $s = SDIR($dir, 'AC30');
    my $e = find_pkg($s, '01-a');
    is_deeply([ map { $_->{started_at} } @{ field($e, 'agents') // [] } ], [ 100, 200, 300 ], 'AC30: ordering by started_at ascending');
}
{
    my ($tmp, $bp_root, $dlog) = new_env();
    make_path($dlog);
    my $dir = make_blueprint($bp_root, 'alpha', registry => registry_json(), packages => { '01-a' => mk_ledger(status => 'running', pipeline => 1) });
    write_record_file($dlog, 'zzz', base_record(started_at => NUM(500)));
    write_record_file($dlog, 'aaa', base_record(started_at => NUM(500)));
    my $s = SDIR($dir, 'AC31');
    my $e = find_pkg($s, '01-a');
    is_deeply([ map { $_->{id} } @{ field($e, 'agents') // [] } ], [ 'aaa', 'zzz' ], 'AC31: identical started_at -> tie-broken by id ascending');
}

# ===========================================================================
# 20. B12 -- unreadable/malformed/wrong-shaped record files all degrade to
#     "skipped", never a die, sibling valid record unaffected.
# ===========================================================================
{
    my ($tmp, $bp_root, $dlog) = new_env();
    make_path($dlog);
    my $dir = make_blueprint($bp_root, 'alpha', registry => registry_json(), packages => { '01-a' => mk_ledger(status => 'running', pipeline => 1) });

    make_path("$dlog/dirrec.json");                                   # a directory named x.json
    write_file("$dlog/empty.json", '');                                # empty file
    write_file("$dlog/malformed.json", '{"blueprint":"alpha","package":"01-a"'); # truncated JSON
    write_file("$dlog/arr.json", '[1,2,3]');                           # JSON array body
    write_file("$dlog/str.json", '"just a string"');                   # JSON string body

    my $sym_ok = can_detect_symlink($dlog);
    if ($sym_ok) {
        write_file("$dlog/sym-target.json", rec_json(merge_fields(base_record(started_at => NUM(1)))));
        symlink("$dlog/sym-target.json", "$dlog/sym.json");
    }

    write_file("$dlog/unreadable.json", rec_json(merge_fields(base_record(started_at => NUM(2)))));
    my $chmod_blocks_reads = 0;
    if (chmod(0000, "$dlog/unreadable.json")) {
        my $opened = open(my $fh, '<', "$dlog/unreadable.json");
        $chmod_blocks_reads = $opened ? 0 : 1;
        close $fh if $opened;
    }

    write_record_file($dlog, 'b12-good', base_record(started_at => NUM(3)));

    my $s = SDIR($dir, 'B12');
    chmod(0644, "$dlog/unreadable.json") if -e "$dlog/unreadable.json";   # restore before tempdir cleanup

    my $e = find_pkg($s, '01-a');
    my @ids = map { $_->{id} } @{ field($e, 'agents') // [] };

    ok(!(grep { $_ eq 'dirrec' } @ids),    'B12: a directory named dirrec.json is skipped');
    ok(!(grep { $_ eq 'empty' } @ids),     'B12: an empty file is skipped');
    ok(!(grep { $_ eq 'malformed' } @ids), 'B12: truncated/malformed JSON is skipped');
    ok(!(grep { $_ eq 'arr' } @ids),       'B12: a JSON array body is skipped');
    ok(!(grep { $_ eq 'str' } @ids),       'B12: a JSON string body is skipped');
  SKIP: {
        skip 'this host\'s symlink() produces an undetectable copy, not a "-l"-true link -- cannot construct a symlink record fixture', 1
            unless $sym_ok;
        ok(!(grep { $_ eq 'sym' } @ids), 'B12: a symlink record file is skipped, even when its target is a fully valid record');
    }
  SKIP: {
        skip 'this host\'s chmod(0000) does not actually block reads for the owner (observed on Windows)', 1
            unless $chmod_blocks_reads;
        ok(!(grep { $_ eq 'unreadable' } @ids), 'B12: an unreadable file is skipped');
    }
    ok((grep { $_ eq 'b12-good' } @ids), 'B12: the sibling valid record in the same directory is unaffected');
}

# ===========================================================================
# 21. AC33/AC34 -- MAX_DISPATCH_RECORDS cap, boundary inclusive. -----------
# ===========================================================================
{
    my ($tmp, $bp_root, $dlog) = new_env();
    make_path($dlog);
    my $dir = make_blueprint($bp_root, 'alpha', registry => registry_json(), packages => { '01-a' => mk_ledger(status => 'running', pipeline => 1) });
    my $cap = SPEC_MAX_DISPATCH_RECORDS;
    bulk_junk_files($dlog, $cap, 'ac33-');   # cap junk + 1 valid = cap+1 total candidates
    write_record_file($dlog, 'ac33-real', base_record(started_at => NUM(9999)));
    my $s = SDIR($dir, 'AC33');
    ok(is_hashref($s), 'AC33: summarize_dir returns a defined summary even over the cap (no die -- also asserted by SDIR above)');
    for my $e (@{ field($s, 'packages') // [] }) {
        is_deeply(field($e, 'agents'), [], "AC33: package '" . field($e, 'name') . "' agents == [] (over MAX_DISPATCH_RECORDS+1 candidates -- honest absence, not a partial answer)");
    }
    is_deeply(field($s, 'run_agents'), [], 'AC33: run_agents == [] too (the cap degrades EVERYTHING, per Decision 9)');
}
{
    my ($tmp, $bp_root, $dlog) = new_env();
    make_path($dlog);
    my $dir = make_blueprint($bp_root, 'alpha', registry => registry_json(), packages => { '01-a' => mk_ledger(status => 'running', pipeline => 1) });
    my $cap = SPEC_MAX_DISPATCH_RECORDS;
    bulk_junk_files($dlog, $cap - 1, 'ac34-');   # (cap-1) junk + 1 valid = cap total candidates, exactly at the boundary
    write_record_file($dlog, 'ac34-real', base_record(started_at => NUM(8888)));
    my $s = SDIR($dir, 'AC34');
    my $e = find_pkg($s, '01-a');
    is(scalar(@{ field($e, 'agents') // [] }), 1, 'AC34: exactly MAX_DISPATCH_RECORDS candidates -> the valid one appears (boundary is inclusive, not over-cap)');
    is((field($e, 'agents') // [])->[0]{id}, 'ac34-real', 'AC34: the surviving agent is the valid record');
}

# ===========================================================================
# 22. AC35 -- a record padded past MAX_MARKER_BYTES is skipped. -----------
# ===========================================================================
{
    my ($tmp, $bp_root, $dlog) = new_env();
    make_path($dlog);
    my $dir = make_blueprint($bp_root, 'alpha', registry => registry_json(), packages => { '01-a' => mk_ledger(status => 'running', pipeline => 1) });
    my $huge_note = 'n' x 10240;
    write_record_file($dlog, 'ac35-huge', base_record(started_at => NUM(9000), note => $huge_note));
    write_record_file($dlog, 'ac35-good', base_record(started_at => NUM(9001)));
    ok(-s "$dlog/ac35-huge.json" > SPEC_MAX_MARKER_BYTES, 'AC35 precondition: the padded record file is larger than MAX_MARKER_BYTES on disk');
    my $s = SDIR($dir, 'AC35');
    my $e = find_pkg($s, '01-a');
    my @ids = map { $_->{id} } @{ field($e, 'agents') // [] };
    ok(!(grep { $_ eq 'ac35-huge' } @ids), 'AC35: the oversized record (padded past MAX_MARKER_BYTES) is skipped (head-truncated, fails to decode)');
    ok((grep { $_ eq 'ac35-good' } @ids), 'AC35: sibling valid record unaffected');
}

# ===========================================================================
# 23. AC38 -- summarize_dir on a fixture OUTSIDE the anchored
#     "…/.ccpraxis-local-data/blueprints/" layout -> agents == [] for every
#     entry, regardless of a matching-shaped dispatch log two levels up.
# ===========================================================================
{
    my $tmp = tempdir(CLEANUP => 1);
    my $outside_root = "$tmp/not-blueprints-dir";
    make_path($outside_root);
    my $dir = make_blueprint($outside_root, 'alpha', registry => registry_json(), packages => { '01-a' => mk_ledger(status => 'running', pipeline => 1) });
    my $dlog2 = "$tmp/.dispatch-log";
    make_path($dlog2);
    write_record_file($dlog2, 'ac38-rec', base_record(started_at => NUM(1)));
    my $s = SDIR($dir, 'AC38');
    for my $e (@{ field($s, 'packages') // [] }) {
        is_deeply(field($e, 'agents'), [], "AC38: outside-anchor fixture -- package '" . field($e, 'name') . "' agents == []");
    }
    is_deeply(field($s, 'run_agents'), [], 'AC38: run_agents == [] too (the anchor test applies before any matching happens)');
}

# ===========================================================================
# 24. AC39 -- the shared index: two blueprints, correctly attached,
#     independently-owned agents arrayrefs (no aliasing into the index).
# ===========================================================================
{
    my ($tmp, $bp_root, $dlog) = new_env();
    make_path($dlog);
    my $dir1 = make_blueprint($bp_root, 'alpha', registry => registry_json(), packages => { '01-a' => mk_ledger(status => 'running', pipeline => 1) });
    my $dir2 = make_blueprint($bp_root, 'beta',  registry => registry_json(), packages => { '01-a' => mk_ledger(status => 'running', pipeline => 1) });
    write_record_file($dlog, 'ac39-alpha', base_record(blueprint => 'alpha', started_at => NUM(10)));
    write_record_file($dlog, 'ac39-beta',  base_record(blueprint => 'beta',  started_at => NUM(20)));

    my $list = SUM($bp_root, 'AC39');
    ok(is_arrayref($list), 'AC39: summarize($root) returns an ARRAY ref');
    my ($sa) = grep { is_hashref($_) && (field($_, 'blueprint') eq 'alpha') } @$list;
    my ($sb) = grep { is_hashref($_) && (field($_, 'blueprint') eq 'beta') } @$list;
    ok(is_hashref($sa) && is_hashref($sb), 'AC39: both blueprint summaries are present');
    SKIP: {
        skip 'AC39 precondition failed -- cannot continue', 6 unless is_hashref($sa) && is_hashref($sb);
        my $ea = find_pkg($sa, '01-a');
        my $eb = find_pkg($sb, '01-a');
        is(scalar(@{ field($ea, 'agents') // [] }), 1, 'AC39: alpha 01-a has its own agent');
        is(scalar(@{ field($eb, 'agents') // [] }), 1, 'AC39: beta 01-a has its own agent');
        is((field($ea, 'agents') // [])->[0]{id}, 'ac39-alpha', 'AC39: alpha got the alpha record');
        is((field($eb, 'agents') // [])->[0]{id}, 'ac39-beta',  'AC39: beta got the beta record');
        isnt(refaddr(field($ea, 'agents')), refaddr(field($eb, 'agents')), 'AC39: alpha and beta agents arrayrefs are NOT the same reference');
        push @{ field($ea, 'agents') // [] }, { injected => 1 };
        is(scalar(@{ field($eb, 'agents') // [] }), 1, 'AC39: mutating alpha\'s agents arrayref does not affect beta\'s (no shared aliasing into the index)');
    }
}

# ===========================================================================
# 24b. fix-batch MEDIUM-2 -- element-level aliasing. `[ @$list ]` copies the
#     ARRAY but not its element hashrefs, so two summaries built from the
#     SAME shared index (via the documented two-arg summarize_dir($dir, $idx)
#     path) previously shared the actual agent hashrefs with each other AND
#     with the index itself. Mutating one leaked a `role` outside the closed
#     vocabulary and a forbidden liveness-shaped key (`live`) into a summary
#     built AFTERWARDS from the same index -- worse than ordinary aliasing,
#     because AC5 depends on no liveness-shaped key ever being emitted.
#     Every precondition below is asserted BEFORE the negative conclusion is
#     drawn, per the ledger's own record of measuring this vacuously twice
#     (an empty index, then a mutation inside a never-true `if`).
# ===========================================================================
{
    my ($tmp, $bp_root, $dlog) = new_env();
    make_path($dlog);
    my $dir = make_blueprint($bp_root, 'alpha', registry => registry_json(), packages => { '01-a' => mk_ledger(status => 'running', pipeline => 1) });
    write_record_file($dlog, 'ac39b-rec', base_record(role => 'worker', started_at => NUM(30)));

    my $ddir = RS('_dispatch_dir', $bp_root);
    my $idx  = RS('_dispatch_index', $ddir);
    ok(is_hashref($idx), 'AC39b precondition: _dispatch_index returned a hashref');
    ok(is_hashref($idx) && is_hashref($idx->{alpha}) && is_arrayref($idx->{alpha}{'01-a'}) && scalar(@{ $idx->{alpha}{'01-a'} }) == 1,
        'AC39b precondition: the index is non-empty and holds exactly the one attached record at alpha/01-a');

    my $s1 = SDIR2($dir, $idx, 'AC39b [build 1]');
    my $s2 = SDIR2($dir, $idx, 'AC39b [build 2]');

    my $e1 = find_pkg($s1, '01-a');
    my $e2 = find_pkg($s2, '01-a');
    ok(is_hashref($e1) && is_hashref($e2), 'AC39b precondition: both builds located the 01-a package entry');
    SKIP: {
        skip 'AC39b precondition failed -- cannot continue', 8 unless is_hashref($e1) && is_hashref($e2);
        my $a1 = (field($e1, 'agents') // [])->[0];
        my $a2 = (field($e2, 'agents') // [])->[0];
        ok(is_hashref($a1) && is_hashref($a2), 'AC39b precondition: both builds actually attached an agent element (not an empty list)');
        SKIP: {
            skip 'AC39b precondition failed -- cannot continue', 6 unless is_hashref($a1) && is_hashref($a2);
            is(field($a1, 'role'), 'worker', 'AC39b precondition: build 1 agent role is worker (real attachment, not a stub)');
            is(field($a2, 'role'), 'worker', 'AC39b precondition: build 2 agent role is worker (real attachment, not a stub)');
            isnt(refaddr($a1), refaddr($a2), 'AC39b: the two builds\' agent ELEMENT hashrefs are not the same reference (not aliased into the shared index)');
            isnt(refaddr($a1), refaddr($idx->{alpha}{'01-a'}[0]), 'AC39b: build 1\'s agent element is not the same reference as the index\'s own element');

            $a1->{role} = 'admiral';   # outside the closed vocabulary (AC22)
            $a1->{live} = 1;           # a liveness-shaped key, forbidden by AC5

            is(field($a2, 'role'), 'worker', 'AC39b: mutating build 1\'s agent role does not affect build 2\'s agent');
            ok(!exists $a2->{live}, 'AC39b: mutating build 1\'s agent does not inject a liveness-shaped key into build 2\'s agent');
            is($idx->{alpha}{'01-a'}[0]{role}, 'worker', 'AC39b: mutating build 1\'s agent does not affect the shared index\'s own element');
            ok(!exists $idx->{alpha}{'01-a'}[0]{live}, 'AC39b: mutating build 1\'s agent does not inject a liveness-shaped key into the shared index');

            my $s3 = SDIR2($dir, $idx, 'AC39b [build 3, after mutation]');
            my $e3 = find_pkg($s3, '01-a');
            my $a3 = is_hashref($e3) ? (field($e3, 'agents') // [])->[0] : undef;
            ok(is_hashref($a3), 'AC39b precondition: a THIRD build from the same (post-mutation) index still attaches an agent');
            is(is_hashref($a3) ? field($a3, 'role') : undef, 'worker', 'AC39b: a build made AFTER the mutation is unaffected -- the index itself was never mutated');
        }
    }
}

# ===========================================================================
# 25. AC40/B19/B20 -- the optional second argument. -------------------------
# ===========================================================================
{
    my ($tmp, $bp_root, $dlog) = new_env();
    make_path($dlog);
    my $dir = make_blueprint($bp_root, 'alpha', registry => registry_json(),
        packages => { '01-a' => mk_ledger(status => 'running', pipeline => 1), '02-b' => mk_ledger(status => 'running', pipeline => 1) });
    write_record_file($dlog, 'ac40-rec', base_record(started_at => NUM(42)));

    my $s_one = SDIR($dir, 'AC40 [one-arg]');

    my $ddir = RS('_dispatch_dir', $bp_root);
    my $idx  = RS('_dispatch_index', $ddir);
    ok(is_hashref($idx), 'AC40 precondition: a correctly-built index is a hashref');

    my $s_two = SDIR2($dir, $idx, 'AC40/B19 [two-arg, correct index]');
    is_deeply($s_two, $s_one, 'AC40/B19: summarize_dir($d) and summarize_dir($d, $idx) (correct index) produce identical summaries');

    for my $c ( [ 'undef', undef ], [ q{"x"}, 'x' ], [ '[]', [] ], [ q{bless({},'Foo')}, bless({}, 'Foo') ] ) {
        my ($label, $bad) = @$c;
        my $s_bad = SDIR2($dir, $bad, "AC40/B20 [$label]");
        is_deeply($s_bad, $s_one, "AC40/B20: summarize_dir(\$d, $label) ignores the non-HASH second argument -- identical to the one-argument form");
    }
}

done_testing();
