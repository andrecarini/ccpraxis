#!/usr/bin/env perl
# s10-run-state-panel: orchestrator/run state on the dashboard (RunState.pm +
# launcher.pl wiring + Dashboard.pm Run-panel append).
#
# This file is the IMMUTABLE ORACLE for blueprint sandbox-butler-overhaul,
# package s10-run-state-panel (specs/07-run-state-panel-spec.md). It is
# written BLIND to any RunState.pm / launcher.pl / Dashboard.pm implementation
# -- directly from the spec -- so it can serve as an oracle rather than an
# echo of whatever the implementer eventually writes.
#
# Coverage: every numbered S3 observable behavior (B1-B39) and AC-1..AC-26
# (spec S4). AC-27 (whole-suite-green gate) is deliberately NOT encoded here
# -- it is a coordinator-side check, exactly as t/43/t/44 treat their final
# AC.
#
# RunState.pm DOES NOT EXIST YET, and neither launcher.pl's `use RunState ()`
# / `_gather_runs` / `$cached_runs` / `runs =>` wiring nor Dashboard::_run_lines
# have landed. Every RunState::* call below goes through a probe helper that
# wraps the call in `eval` and returns a blessed sentinel on failure, so a
# missing module/sub degrades to a clean per-assertion FAIL rather than
# aborting the file. That is EXPECTED and correct until the implementer lands
# s10.
#
# Hard constraints honoured here (spec S5 "Locale / encoding"):
#   * this file MUST NOT `use utf8`; the André fixture path segment is written
#     as an explicit UTF-8 byte escape ("Andr\xC3\xA9"), never a \x{...} char.
#   * launcher.pl is NEVER require'd/do'ne -- source-text slurp + regex only
#     (t/36's stated convention, followed by t/43/t/44).
#   * every fixture is built under File::Temp::tempdir (CLEANUP => 1) --
#     nothing here reads .ccpraxis-local-data/ (gitignored, does not travel).
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Find ();

my $SCRIPTS_DIR    = "$Bin/../../scripts";
my $RUNSTATE_PATH  = "$SCRIPTS_DIR/RunState.pm";
my $LAUNCHER_PATH  = "$SCRIPTS_DIR/launcher.pl";
my $DASHBOARD_PATH = "$SCRIPTS_DIR/Dashboard.pm";

# Spec-pinned caps (S2.0), asserted independently below against the module's
# own `our` variables -- literals here, not read from the module.
use constant SPEC_MAX_REGISTRY_BYTES => 4 * 1024 * 1024;
use constant SPEC_MAX_LEDGER_BYTES   => 65536;
use constant SPEC_MAX_MARKER_BYTES   => 4096;

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

# --- fixture builders --------------------------------------------------

# json_escape/json_str/registry_json: a tiny hand-rolled JSON literal builder
# (not JSON::PP::encode) so byte-for-byte control over package KEYS is exact
# -- including keys containing NUL / '/' / non-ASCII bytes -- without any
# wide-character promotion risk (this file must not `use utf8`).
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

# RAW_JSON($json_snippet) -> a marker so a package's registry value can be
# something other than {"status":...} (e.g. a bare string, null, an array).
sub RAW_JSON { my ($json) = @_; return { __raw_json => 1, json => $json }; }

# registry_json(%pkgs) -> a full '{"packages":{...}}' document. Each value is
# either a plain scalar (shorthand for {"status":<scalar>}), a RAW_JSON(...)
# marker (used verbatim), or a hashref (used verbatim, JSON-escaped by hand
# only for its 'status' field -- callers needing more control use RAW_JSON).
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
            $val_json = '{"status":' . json_str($v->{status}) . '}';
        }
        else {
            $val_json = '{"status":' . json_str($v) . '}';
        }
        push @entries, json_str($k) . ':' . $val_json;
    }
    return '{"packages":{' . join(',', @entries) . '}}';
}

sub ledger_with_status {
    my ($status, %o) = @_;
    my $extra = $o{extra} // '';
    return "---\npackage: x\nstatus: $status\n$extra---\n# ledger body\n";
}
sub ledger_no_status_line {
    return "---\npackage: x\nno-status-here: true\n---\n# ledger body\n";
}
sub ledger_no_closing_fence {
    my ($status) = @_;
    return "---\npackage: x\nstatus: $status\n# no closing fence, EOF ends the scan\n";
}

# make_blueprint($root, $name, %opts) -> "$root/$name" (created). %opts:
#   no_runs_dir => 1                         : skip creating runs/ entirely
#   registry    => <text>                    : write runs/registry.json (any bytes)
#   orchestrator=> <text>                    : write runs/.orchestrator
#   paused      => <text>                    : write runs/.paused
#   shutdown    => 1                         : touch runs/.shutdown (empty)
#   needs_you   => [ { name=>, is_dir=>, content=> }, ... ]
#   packages    => { pkg => <ledger text> }  : writes packages/<pkg>.md
sub make_blueprint {
    my ($root, $name, %o) = @_;
    my $dir = "$root/$name";
    make_path($dir);
    unless ($o{no_runs_dir}) {
        make_path("$dir/runs");
        write_file("$dir/runs/registry.json",  $o{registry})     if exists $o{registry};
        write_file("$dir/runs/.orchestrator",  $o{orchestrator}) if exists $o{orchestrator};
        write_file("$dir/runs/.paused",        $o{paused})       if exists $o{paused};
        write_file("$dir/runs/.shutdown", '') if $o{shutdown};
        if ($o{needs_you}) {
            make_path("$dir/runs/escalations");
            for my $f (@{ $o{needs_you} }) {
                if ($f->{is_dir}) { make_path("$dir/runs/escalations/$f->{name}"); }
                else              { write_file("$dir/runs/escalations/$f->{name}", $f->{content} // '{}'); }
            }
        }
    }
    if ($o{packages}) {
        make_path("$dir/packages");
        for my $pkg (keys %{ $o{packages} }) {
            write_file("$dir/packages/$pkg.md", $o{packages}{$pkg});
        }
    }
    return $dir;
}

sub snapshot_tree {
    my ($root) = @_;
    my %snap;
    File::Find::find({
        no_chdir => 1,
        wanted   => sub {
            return unless -f $File::Find::name;
            my @st = stat($File::Find::name);
            $snap{$File::Find::name} = "$st[7]:$st[9]";   # size:mtime
        },
    }, $root);
    return \%snap;
}

# mirror_count_needs_you($blueprints_root) -> a byte-for-byte reimplementation
# of launcher.pl's _count_needs_you (launcher.pl:3111-3130) starting directly
# at $blueprints_root, so AC-25 can assert agreement WITHOUT requiring/
# side-effecting launcher.pl.
sub mirror_count_needs_you {
    my ($root) = @_;
    return 0 unless -d $root;
    my $n = 0;
    opendir(my $bd, $root) or return 0;
    for my $bp (readdir $bd) {
        next if $bp eq '.' || $bp eq '..';
        my $nd = "$root/$bp/runs/escalations";
        next unless -d $nd;
        opendir(my $d, $nd) or next;
        for my $f (readdir $d) {
            next if $f =~ /^\./ || $f =~ /\.tmp$/;
            $n++ if -f "$nd/$f";
        }
        closedir $d;
    }
    closedir $bd;
    return $n;
}

# $FAILED is the sentinel returned in place of a value whenever a RunState
# call could not be made at all (missing module/sub) or died. It exists so an
# assertion expecting `undef` can never PASS just because RunState.pm is not
# there yet (t/44's pattern, verbatim rationale).
my $FAILED = bless { t45 => 'call did not happen' }, 'T45::CallFailed';

# probe_call($fn, @args) -> ($scalar_result, $err, \@warnings). Never
# propagates a die.
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

# RS($fn, @args) -> the scalar-context return value, or $FAILED on death.
# Used for summarize_dir (hashref|undef) and summarize (arrayref).
sub RS {
    my ($res, $err) = probe_call(@_);
    return $FAILED if $err ne '';
    return $res;
}

# probe_list/RS_LIST: list-context wrapper, used ONLY for blueprint_dirs
# (S2.1: "-> LIST of absolute dir paths").
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

# The closed key set. Deliberately an EQUALITY, not a floor: this is a declared
# struct with a spec, and a key appearing by accident is exactly the drift the
# assertion exists to catch. Extending it is therefore a deliberate act, made
# here, not something a producer gets to do silently.
#
# Widened to 13 on 2026-08-24. `decisions_waiting` was the total number of queued
# escalations and the panel rendered it as "needs you", which asserted operator
# ownership over a queue nothing had looked inside -- most of those records are
# handled by the escalation resolver without waking anyone. The split is
# additive: decisions_waiting keeps its old meaning and its old value, and the
# two new keys say who each half belongs to.
my @KEYS_11 = qw(
    blueprint runs_dir state orchestrator_pid paused_manual paused_reason
    packages_total packages_done current_package running_coordinators
    decisions_waiting decisions_operator decisions_triage
);

# assert_summary_shape($summary, $label): the closed 11-key set (S2.2) plus
# the declared type/nullability of each key. AC-6 / B28.
sub assert_summary_shape {
    my ($s, $label) = @_;
    ok(is_hashref($s), "$label: summary is a hashref") or return;
    is_deeply([ sort keys %$s ], [ sort @KEYS_11 ], "$label: exactly the 13 S2.2 keys, no more, no fewer");
    ok(defined($s->{blueprint}) && !ref($s->{blueprint}) && length($s->{blueprint}), "$label: blueprint is a non-empty Str");
    ok(defined($s->{runs_dir})  && !ref($s->{runs_dir})  && length($s->{runs_dir}),  "$label: runs_dir is a non-empty Str");
    # Widened by blueprint unified-tui-design-system package
    # 04-run-panel-ledger-truth (driver ruling on escalation E4, 2026-08-07):
    # RunState::summarize_dir now also emits 'stale' (a run marker exists but
    # its coordinator PID is checked-dead) and 'solo' (ledgers exist, no
    # runs/ directory at all -- driven entirely outside the fleet). This
    # assertion previously pinned only the 4 legacy values and was already
    # WRONG about the design the moment those two states were specified; it
    # stayed green only because no fixture in this file constructs them.
    # Widened here, in the same edit that introduces the states, rather than
    # left for whoever first constructs one to discover.
    ok(defined($s->{state}) && grep { $s->{state} eq $_ } qw(running paused parked idle stale solo), "$label: state is one of the 6 enum values");
    ok(!defined($s->{orchestrator_pid}) || ($s->{orchestrator_pid} =~ /^\d+$/), "$label: orchestrator_pid is undef or a non-negative Int");
    ok(defined($s->{paused_manual}) && ($s->{paused_manual} == 0 || $s->{paused_manual} == 1), "$label: paused_manual is 0 or 1");
    ok(!defined($s->{paused_reason}) || (!ref($s->{paused_reason}) && length($s->{paused_reason})), "$label: paused_reason is undef or a non-empty Str");
    ok(defined($s->{packages_total}) && $s->{packages_total} =~ /^\d+$/, "$label: packages_total is a non-negative Int");
    ok(defined($s->{packages_done})  && $s->{packages_done}  =~ /^\d+$/, "$label: packages_done is a non-negative Int");
    ok(!defined($s->{current_package}) || (!ref($s->{current_package}) && length($s->{current_package})), "$label: current_package is undef or a non-empty Str");
    ok(defined($s->{running_coordinators}) && $s->{running_coordinators} =~ /^\d+$/, "$label: running_coordinators is a non-negative Int");
    ok(defined($s->{decisions_waiting}) && $s->{decisions_waiting} =~ /^\d+$/, "$label: decisions_waiting is a non-negative Int");
}

# ===========================================================================
# 0. Load.
# ===========================================================================
use_ok('RunState');
use_ok('Dashboard') or BAIL_OUT('Dashboard.pm did not load');

# tui::DashboardScreen is a READ-ONLY dependency here (blueprint
# unified-tui-design-system package 06-dashboard-screen): LABEL_GUTTER() is
# this file's derivation source for the re-pointed Run-panel row labels
# below (spec 06-dashboard-screen-spec.md S2.4.1), so every expected label
# string is DERIVED, never hand-padded.
my $DASHBOARD_SCREEN_OK45 = eval { require tui::DashboardScreen; 1 };
BAIL_OUT("tui::DashboardScreen.pm did not load ($@) -- LABEL_GUTTER() is this file's derivation source for the re-pointed Run-panel row assertions; nothing below can mean anything without it")
    unless $DASHBOARD_SCREEN_OK45;

# ===========================================================================
# 1. Module-wide contract (S2.0): purity source scan + read caps.
#    AC-8 (kill/spawn scan), AC-11 (no glob).
# ===========================================================================
{
    my $raw  = slurp($RUNSTATE_PATH);
    ok(length($raw) > 0, 'RunState.pm exists and is readable on disk') or diag("expected at $RUNSTATE_PATH");
    my $have = (length($raw) > 0);
    my $src  = $raw;
    $src =~ s/#[^\n]*//g;    # strip #-to-end-of-line comments

    # --- AC-8 (B14): no kill, no spawn/backtick constructs. ---------------
    my @forbidden = (
        [ 'kill',                 qr/\bkill\b/ ],
        [ 'a backtick character', qr/`/ ],
        [ 'qx',                   qr/\bqx\b/ ],
        [ 'system(',              qr/\bsystem\s*\(/ ],
        [ q{open '-|'},           qr/open\s*\(?\s*[^,]*,\s*['"]-\|['"]/ ],
    );
    for my $f (@forbidden) {
        my ($label, $qr) = @$f;
        my $desc = "AC-8: RunState.pm source (comments stripped) contains no $label";
        $have ? unlike($src, $qr, $desc) : fail("$desc [RunState.pm not on disk]");
    }

    # --- AC-11 (B3): no glob call and no diamond glob operator. -----------
    my $desc_glob = 'AC-11: RunState.pm source contains no glob() call / bareword glob';
    $have ? unlike($src, qr/\bglob\b/, $desc_glob) : fail("$desc_glob [RunState.pm not on disk]");
    my $desc_diamond = 'AC-11: RunState.pm source contains no <...> glob-shaped diamond operator';
    $have ? unlike($src, qr/<[^<>\n]*\*[^<>\n]*>/, $desc_diamond) : fail("$desc_diamond [RunState.pm not on disk]");

    # --- S2.0: no console I/O, no clock, no process probing. --------------
    my @quiet = (
        [ 'print',     qr/\bprint\b/ ],
        [ 'warn',      qr/\bwarn\b/ ],
        [ 'die',       qr/\bdie\b/ ],
        [ 'time(',     qr/\btime\s*\(/ ],
        [ 'localtime', qr/\blocaltime\b/ ],
        [ 'gmtime',    qr/\bgmtime\b/ ],
    );
    for my $q (@quiet) {
        my ($label, $qr) = @$q;
        my $desc = "S2.0: RunState.pm source (comments stripped) contains no $label";
        $have ? unlike($src, $qr, $desc) : fail("$desc [RunState.pm not on disk]");
    }

    # --- S2.0: nothing exported. -------------------------------------------
    my $desc_exp = 'S2.0: RunState.pm source contains no Exporter usage / @EXPORT';
    $have ? unlike($src, qr/\b(?:Exporter|\@EXPORT)\b/, $desc_exp) : fail("$desc_exp [RunState.pm not on disk]");
}

# --- S2.0: package-scoped read caps, inspectable via `our`. ---------------
{
    is($RunState::MAX_REGISTRY_BYTES, SPEC_MAX_REGISTRY_BYTES, 'S2.0: $RunState::MAX_REGISTRY_BYTES == 4 MiB');
    is($RunState::MAX_LEDGER_BYTES,   SPEC_MAX_LEDGER_BYTES,   'S2.0: $RunState::MAX_LEDGER_BYTES == 64 KiB');
    is($RunState::MAX_MARKER_BYTES,   SPEC_MAX_MARKER_BYTES,   'S2.0: $RunState::MAX_MARKER_BYTES == 4096');
}

# ===========================================================================
# 2. blueprint_dirs -- B1, B2, B3.
# ===========================================================================

# --- B1: ordering, skip files, skip symlinks. -----------------------------
#
# EDITED by blueprint unified-tui-design-system package
# 04-run-panel-ledger-truth (driver ruling, 2026-08-07; spec S2.4/AC-23..25).
# RunState::blueprint_dirs ALREADY has the correct guard
# ('next if -l "$root/$e"', RunState.pm:74) -- that guard is NOT touched
# here. What could not work was the FIXTURE: on this Git-for-Windows host,
# perl's symlink() returns success (1, no errno) but produces a plain
# directory COPY -- '-l' is false, '-d' is true, readlink returns undef --
# so the guard has nothing to fire on and the old single-root assertion
# failed through no fault of RunState.pm. This is the SAME CLASS of
# platform-blind fixture as package 00's t/51 fix.
#
# Split into an ALWAYS-arm (every platform: ordering + plain-file skipping,
# using a root that contains NO symlink at all) and a PROBED arm (only where
# this host can construct a symlink '-l' can actually detect). The two arms
# use SEPARATE fixture roots (architect refinement on top of the driver's
# ruling): reusing one root would mean that on a copy-making host, the fake
# "symlink" created for the probed arm becomes a REAL THIRD DIRECTORY sitting
# in the root the always-arm asserts holds exactly two entries everywhere --
# breaking the arm that is supposed to be platform-independent.
#
# FORBIDDEN (spec, explicit): weakening/removing RunState.pm:74's '-l' guard
# (it is correct and load-bearing IN THE CONTAINER, where the sandbox
# actually runs Linux and symlinks are real); asserting that symlink() FAILS
# on this host (that would pin a platform quirk, not the behaviour under
# test).

# can_detect_symlink($scratch_dir) -> 1|0
#
# Constructs a target dir and a symlink to it under $scratch_dir, then asks
# whether THIS host can tell the symlink apart from a directory via '-l'.
# Git-for-Windows perl without MSYS winsymlinks enabled returns success from
# symlink() and silently produces a plain COPY instead: '-l' false, '-d'
# true, readlink undef. This probes the CAPABILITY; it deliberately does NOT
# assert that symlink() fails, which would pin the platform quirk itself
# rather than the behaviour under test (RunState.pm:74's guard).
#
# (Recommended promotion per spec E10: this belongs in
# tests/lib/TestSandbox.pm as a shared host-capability probe -- this is the
# second ad-hoc platform probe in this initiative (t/51 was the first,
# fixed via a $^O branch, a different technique). Left local here because
# TestSandbox.pm is outside this package's write set.)
sub can_detect_symlink {
    my ($scratch_dir) = @_;
    my $target = "$scratch_dir/probe-target";
    my $link   = "$scratch_dir/probe-link";
    make_path($target);
    my $made = eval { symlink($target, $link) };
    my $ok = ($made && -l $link) ? 1 : 0;
    unlink($link)    if -e $link || -l $link;
    rmdir($target)   if -d $target;
    return $ok;
}

# --- B1 always-arm: ordering + plain-file skipping, on EVERY platform. ----
# This root deliberately contains NO symlink at all -- on a copy-making host
# a fake "symlink" would land here as a real third directory and break the
# "exactly two entries" expectation this arm is supposed to hold everywhere.
{
    my $root1 = tempdir(CLEANUP => 1);
    make_path("$root1/zeta/runs");
    make_path("$root1/alpha/runs");
    write_file("$root1/note.md", "just a file\n");
    my @got1 = RS_LIST('blueprint_dirs', $root1);
    is_deeply(\@got1, [ "$root1/alpha", "$root1/zeta" ],
        'B1 always-arm: blueprint_dirs(root) returns exactly ("$root/alpha","$root/zeta") in that order, on every platform (ordering + plain-file skip; no symlink present in this root)');
}

# --- B1 probed arm: symlink-skipping, only where this host can construct --
# --- a symlink '-l' can actually detect. Its OWN, separate fixture root. --
{
    my $probe_dir = tempdir(CLEANUP => 1);
    my $detectable = can_detect_symlink($probe_dir);

  SKIP: {
        skip 'this host\'s symlink() produces an undetectable copy, not a "-l"-true link (Git-for-Windows perl without MSYS winsymlinks) -- cannot construct the scenario B1 needs', 1
            unless $detectable;

        my $root2 = tempdir(CLEANUP => 1);
        make_path("$root2/zeta/runs");
        make_path("$root2/alpha/runs");
        symlink("$root2/alpha", "$root2/link");
        my @got2 = RS_LIST('blueprint_dirs', $root2);
        is_deeply(\@got2, [ "$root2/alpha", "$root2/zeta" ],
            'B1 probed arm: blueprint_dirs(root) skips a symlinked directory entry ("$root/link") on a host that can construct a detectable symlink');
    }
}

# --- B2 -> AC-4: blueprint_dirs(undef/''/nonexistent) -> (). --------------
{
    for my $c ( [ 'undef', undef ], [ "''", '' ], [ "'/no/such/dir'", '/no/such/dir' ] ) {
        my ($label, $arg) = @$c;
        my ($res, $err, $warns) = probe_list('blueprint_dirs', $arg);
        is($err, '', "B2/AC-4: blueprint_dirs($label) does not die");
        is_deeply($res, [], "B2/AC-4: blueprint_dirs($label) returns the empty list");
        ok(!@$warns, "B2/AC-4: blueprint_dirs($label) emits no warnings");
    }
    # opendir failure on an existing-but-unreadable-as-a-dir path: a regular
    # file path used as "the root" behaves the same as "not an existing
    # directory" per S2.1's "not an existing directory -> ()" bullet.
    my $root = tempdir(CLEANUP => 1);
    write_file("$root/plainfile", 'x');
    is_deeply([ RS_LIST('blueprint_dirs', "$root/plainfile") ], [],
        'B2: blueprint_dirs(a plain file path) -> () (not an existing directory)');
}

# --- B3 -> AC-11: opendir/readdir only -- spaces + André bytes. -----------
{
    my $ascii_root = tempdir(CLEANUP => 1);
    make_path("$ascii_root/alpha/runs");
    write_file("$ascii_root/alpha/runs/registry.json", registry_json(p1 => 'running'));
    make_path("$ascii_root/beta/runs");
    write_file("$ascii_root/beta/runs/registry.json", registry_json(p1 => 'done', p2 => 'running'));

    my $base = tempdir(CLEANUP => 1);
    # "the raw bytes of André" -- explicit UTF-8 byte escapes, plus a space,
    # in the ROOT path itself (not just a blueprint name). No `use utf8`.
    my $andre_root = "$base/Andr\xC3\xA9 space test root";
    make_path("$andre_root/alpha/runs");
    write_file("$andre_root/alpha/runs/registry.json", registry_json(p1 => 'running'));
    make_path("$andre_root/beta/runs");
    write_file("$andre_root/beta/runs/registry.json", registry_json(p1 => 'done', p2 => 'running'));

    my @ascii_dirs = RS_LIST('blueprint_dirs', $ascii_root);
    my @andre_dirs = RS_LIST('blueprint_dirs', $andre_root);
    is(scalar(@andre_dirs), scalar(@ascii_dirs), 'B3/AC-11: André+space root yields the same NUMBER of blueprint dirs as the ASCII root');
    is_deeply([ map { (split m{/})[-1] } @andre_dirs ], [ map { (split m{/})[-1] } @ascii_dirs ],
        'B3/AC-11: André+space root yields the SAME blueprint dir NAMES, in the same order, as the ASCII root');

    my $ascii_summaries = RS('summarize', $ascii_root);
    my $andre_summaries = RS('summarize', $andre_root);
    if (is_arrayref($ascii_summaries) && is_arrayref($andre_summaries)) {
        is(scalar(@$andre_summaries), scalar(@$ascii_summaries),
            'B3/AC-11: summarize() over the André+space root returns the same COUNT of summaries as ASCII');
        for my $i (0 .. $#$ascii_summaries) {
            my ($as, $an) = ($ascii_summaries->[$i], $andre_summaries->[$i]);
            is(field($an, 'state'), field($as, 'state'), "B3/AC-11: summary[$i] state identical between André and ASCII roots");
            is(field($an, 'packages_total'), field($as, 'packages_total'), "B3/AC-11: summary[$i] packages_total identical");
            is(field($an, 'packages_done'),  field($as, 'packages_done'),  "B3/AC-11: summary[$i] packages_done identical");
        }
    } else {
        fail('B3/AC-11: summarize() returned an arrayref for both the ASCII and André+space roots');
    }
}

# ===========================================================================
# 3. summarize_dir -- inclusion/skipping. B4, B5, B6, B7.
# ===========================================================================

# --- B4 -> AC-4: no runs/ subdirectory -> undef, contributes nothing. -----
{
    my $root = tempdir(CLEANUP => 1);
    my $dir = make_blueprint($root, 'norun', no_runs_dir => 1);
    is(RS('summarize_dir', $dir), undef, 'B4/AC-4: a blueprint dir with no runs/ subdir -> summarize_dir undef');
    is_deeply(RS('summarize', $root), [], 'B4/AC-4: ... and summarize() over that root -> []');
}

# --- B5 -> AC-4: runs/ present, no registry.json -> undef. ----------------
{
    my $root = tempdir(CLEANUP => 1);
    my $dir = make_blueprint($root, 'neverran');   # runs/ created, no registry key
    is(RS('summarize_dir', $dir), undef, 'B5/AC-4: runs/ with no registry.json -> summarize_dir undef (never-ran blueprint)');
}

# --- B6 -> AC-5: malformed registry never suppresses a valid sibling. -----
{
    for my $malformed (
        [ 'truncated JSON object', '{"packages":{' ],
        [ 'JSON array',            '["a","b"]' ],
        [ 'JSON string',           '"hello"' ],
        [ 'empty file',            '' ],
    ) {
        my ($label, $body) = @$malformed;
        my $root = tempdir(CLEANUP => 1);
        make_blueprint($root, 'zz-broken', registry => $body);
        make_blueprint($root, 'aa-valid',  registry => registry_json(p1 => 'running', p2 => 'done'));

        my $list = RS('summarize', $root);
        ok(is_arrayref($list), "B6/AC-5 [$label]: summarize() returns an arrayref");
        if (is_arrayref($list)) {
            is(scalar(@$list), 1, "B6/AC-5 [$label]: exactly ONE summary survives (the valid sibling)");
            is(field($list->[0], 'blueprint'), 'aa-valid', "B6/AC-5 [$label]: the surviving summary is 'aa-valid'");
            is(field($list->[0], 'packages_total'), 2, "B6/AC-5 [$label]: the surviving summary's packages_total is intact");
        } else {
            fail("B6/AC-5 [$label]: exactly one summary survives (not an arrayref)");
        }
    }

    # over-cap registry (AC-5's fourth vector).
    my $root = tempdir(CLEANUP => 1);
    make_blueprint($root, 'zz-huge', registry => ('x' x (SPEC_MAX_REGISTRY_BYTES + 1024)));
    make_blueprint($root, 'aa-ok',   registry => registry_json(p1 => 'running'));
    my $list2 = RS('summarize', $root);
    if (is_arrayref($list2)) {
        is(scalar(@$list2), 1, 'B6/AC-5 [over MAX_REGISTRY_BYTES]: exactly one summary survives');
        is(field($list2->[0], 'blueprint'), 'aa-ok', 'B6/AC-5 [over MAX_REGISTRY_BYTES]: the surviving summary is aa-ok');
    } else {
        fail('B6/AC-5 [over MAX_REGISTRY_BYTES]: exactly one summary survives (not an arrayref)');
    }
}

# --- B7 -> AC-4: zero blueprints / only-skipped blueprints -> []. ---------
{
    my $empty_root = tempdir(CLEANUP => 1);
    is_deeply(RS('summarize', $empty_root), [], 'B7/AC-4: summarize() on a root with zero blueprints -> []');

    my $skipped_root = tempdir(CLEANUP => 1);
    make_blueprint($skipped_root, 'norun', no_runs_dir => 1);
    make_blueprint($skipped_root, 'neverran');
    is_deeply(RS('summarize', $skipped_root), [], 'B7/AC-4: summarize() on a root whose only blueprints are skipped -> []');
}

# ===========================================================================
# 4. Totality -- AC-4 (B2, B27) + generic S2.0 totality.
# ===========================================================================
{
    for my $c ( [ 'undef', undef ], [ "''", '' ], [ '{}', {} ], [ '[]', [] ], [ "'/nonexistent'", '/nonexistent' ] ) {
        my ($label, $arg) = @$c;
        my ($res, $err, $warns) = probe_call('summarize', $arg);
        is($err, '', "B27/AC-4: summarize($label) does not die");
        ok(!@$warns, "B27/AC-4: summarize($label) does not warn");
        is_deeply($res, [], "B27/AC-4: summarize($label) == [] (ARRAYREF, never undef)");
    }

    # summarize_dir hostile inputs (S2.1 prose; supports AC-4).
    for my $c ( [ 'undef', undef ], [ "''", '' ], [ "'/no/such/dir'", '/no/such/dir' ], [ '{}', {} ], [ '[]', [] ] ) {
        my ($label, $arg) = @$c;
        my ($res, $err, $warns) = probe_call('summarize_dir', $arg);
        is($err, '', "S2.1/AC-4: summarize_dir($label) does not die");
        ok(!@$warns, "S2.1/AC-4: summarize_dir($label) does not warn");
        is($res, undef, "S2.1/AC-4: summarize_dir($label) == undef");
    }

    # runs/ present but as a FILE, not a directory (S5 hostile input list).
    my $root = tempdir(CLEANUP => 1);
    my $dir = "$root/weird";
    make_path($dir);
    write_file("$dir/runs", "not a directory\n");
    is(RS('summarize_dir', $dir), undef, 'S5: runs/ that is a plain FILE (not a dir) -> summarize_dir undef');
}

# ===========================================================================
# 5. AC-6 (B28): the closed 11-key struct, across many fixtures.
# ===========================================================================
{
    my $root = tempdir(CLEANUP => 1);
    make_blueprint($root, 'running-bp', orchestrator => "111\n",
        registry => registry_json(p1 => 'running', p2 => 'done'));
    make_blueprint($root, 'paused-bp', orchestrator => "222\n", paused => '{"manual":true,"reason":"x"}',
        registry => registry_json(p1 => 'done'));
    make_blueprint($root, 'idle-bp', registry => registry_json());
    make_blueprint($root, 'parked-bp', orchestrator => "333\n", shutdown => 1,
        registry => registry_json(p1 => 'running'));

    my $list = RS('summarize', $root);
    if (is_arrayref($list)) {
        is(scalar(@$list), 4, 'AC-6: all 4 valid blueprints survive');
        for my $s (@$list) {
            assert_summary_shape($s, 'AC-6/B28 [' . (is_hashref($s) ? $s->{blueprint} : '?') . ']');
        }
    } else {
        fail('AC-6: summarize() returned an arrayref of 4 summaries');
    }
}

# ===========================================================================
# 6. state classification -- B9-B14 -> AC-1, AC-2, AC-7, AC-8.
# ===========================================================================

# --- B9: .orchestrator only -> running. -----------------------------------
{
    my $root = tempdir(CLEANUP => 1);
    my $dir = make_blueprint($root, 'bp', orchestrator => "111\n", registry => registry_json(p1 => 'pending'));
    is(field(RS('summarize_dir', $dir), 'state'), 'running', "B9: .orchestrator present, no .paused/.shutdown -> state 'running'");
}

# --- B10: .orchestrator + .paused -> paused (pause beats running). -------
{
    my $root = tempdir(CLEANUP => 1);
    my $dir = make_blueprint($root, 'bp', orchestrator => "111\n", paused => '{}', registry => registry_json(p1 => 'pending'));
    is(field(RS('summarize_dir', $dir), 'state'), 'paused', 'B10/AC-2: .orchestrator + .paused -> state \'paused\'');
}

# --- B11/AC-7: .shutdown -> parked, regardless of the other two markers. -
{
    my $root = tempdir(CLEANUP => 1);
    my $dir = make_blueprint($root, 'bp', orchestrator => "111\n", paused => '{}', shutdown => 1,
        registry => registry_json(p1 => 'pending'));
    is(field(RS('summarize_dir', $dir), 'state'), 'parked', 'B11/AC-7: .shutdown present -> state \'parked\' even with .orchestrator and .paused present');
}

# --- B12/AC-7: no marker -> idle. -----------------------------------------
{
    my $root = tempdir(CLEANUP => 1);
    my $dir = make_blueprint($root, 'bp', registry => registry_json(p1 => 'pending'));
    is(field(RS('summarize_dir', $dir), 'state'), 'idle', 'B12/AC-7: no marker present -> state \'idle\'');
}

# --- B13/AC-2: .paused content -> paused_manual / paused_reason. ---------
{
    my $root = tempdir(CLEANUP => 1);
    my $dir1 = make_blueprint($root, 'bp1', orchestrator => "1\n",
        paused => '{"manual":true,"reason":"needs human"}', registry => registry_json(p1 => 'pending'));
    my $s1 = RS('summarize_dir', $dir1);
    is(field($s1, 'paused_manual'), 1, 'B13/AC-2: .paused {manual:true,reason:...} -> paused_manual == 1');
    is(field($s1, 'paused_reason'), 'needs human', 'B13/AC-2: ... -> paused_reason eq "needs human"');

    for my $bad ( [ 'empty file', '' ], [ 'malformed JSON', '{not json' ] ) {
        my ($label, $content) = @$bad;
        my $dir2 = make_blueprint($root, "bp-$label" =~ s/\W+/_/gr, orchestrator => "1\n",
            paused => $content, registry => registry_json(p1 => 'pending'));
        my $s2 = RS('summarize_dir', $dir2);
        is(field($s2, 'paused_manual'), 0, "B13/AC-2 [$label]: .paused $label -> paused_manual == 0");
        is(field($s2, 'paused_reason'), undef, "B13/AC-2 [$label]: .paused $label -> paused_reason undef");
        is(field($s2, 'state'), 'paused', "B13/AC-2 [$label]: .paused $label -> state is still 'paused' (existence only)");
    }
}

# --- B14/AC-8: orchestrator_pid parsing, never process-probed. -----------
{
    my $root = tempdir(CLEANUP => 1);
    my $dir1 = make_blueprint($root, 'bp1', orchestrator => "30543\n", registry => registry_json());
    is(field(RS('summarize_dir', $dir1), 'orchestrator_pid'), 30543, 'B14/AC-8: .orchestrator "30543\\n" -> orchestrator_pid == 30543');

    my $dir2 = make_blueprint($root, 'bp2', registry => registry_json());   # no .orchestrator at all
    is(field(RS('summarize_dir', $dir2), 'orchestrator_pid'), undef, 'B14/AC-8: no .orchestrator -> orchestrator_pid undef');

    my $dir3 = make_blueprint($root, 'bp3', orchestrator => '', registry => registry_json());
    is(field(RS('summarize_dir', $dir3), 'orchestrator_pid'), undef, 'B14/AC-8: empty .orchestrator -> orchestrator_pid undef');

    my $dir4 = make_blueprint($root, 'bp4', orchestrator => "not-a-pid\n", registry => registry_json());
    is(field(RS('summarize_dir', $dir4), 'orchestrator_pid'), undef, 'B14/AC-8: non-numeric .orchestrator -> orchestrator_pid undef');

    my $dir5 = make_blueprint($root, 'bp5', orchestrator => ('9' x (SPEC_MAX_MARKER_BYTES + 100)), registry => registry_json());
    is(field(RS('summarize_dir', $dir5), 'orchestrator_pid'), undef, 'B14/AC-8: .orchestrator over MAX_MARKER_BYTES -> orchestrator_pid undef');

    # No process is ever signalled or probed: RunState.pm's source has no
    # kill/backtick/system/qx/open '-|' (already asserted in section 1), so
    # this behavioral check is the companion assertion, not a duplicate.
    ok(1, 'B14/AC-8: process-liveness-probe absence is asserted via source scan in section 1');
}

# ===========================================================================
# 7. counts & current package -- B15-B24 -> AC-1, AC-3, AC-9, plus
#    uncited-but-required B17/B18/B22/B23/B24.
# ===========================================================================

# --- AC-1: B9, B15, B16 combined -- the flagship fixture. -----------------
{
    my $root = tempdir(CLEANUP => 1);
    my %pkgs;
    $pkgs{"p$_"} = 'done'    for (1 .. 3);
    $pkgs{"p$_"} = 'running' for (4, 5);
    $pkgs{"p$_"} = 'pending' for (6 .. 8);
    my $dir = make_blueprint($root, 'flagship', orchestrator => "42\n", registry => registry_json(%pkgs));
    my $s = RS('summarize_dir', $dir);
    is(field($s, 'state'), 'running', 'AC-1: state eq "running" (8 pkgs, 3 done, 2 running, .orchestrator present)');
    is(field($s, 'packages_total'), 8, 'AC-1: packages_total == 8');
    # s02/Decision 13: no ledger file exists for ANY of these 8 packages, so
    # every status came exclusively from the now-removed registry fallback.
    # _effective_status must return '' (never adopt the registry's claim),
    # so nothing counts as done and nothing counts as running.
    is(field($s, 'packages_done'), 0, 's02/AC-1 flagship [corrected]: packages_done == 0 -- the registry fallback is gone, so a ledger-absent package is never "done" no matter what the registry claims');
    is(field($s, 'current_package'), undef, 's02/AC-1 flagship [corrected]: current_package undef -- no ledger-absent package is ever adopted as "running" from the registry');
    is(field($s, 'running_coordinators'), 0, 's02/AC-1 flagship [corrected]: running_coordinators == 0 -- same reason');
}

# --- B17 (uncited by any single AC, S2.7 rationale): .orchestrator absent. -
{
    my $root = tempdir(CLEANUP => 1);
    my %pkgs = (p1 => 'done', p2 => 'done', p3 => 'done', p4 => 'running', p5 => 'running', p6 => 'pending', p7 => 'pending', p8 => 'pending');
    my $dir = make_blueprint($root, 'noorch', registry => registry_json(%pkgs));   # no .orchestrator
    my $s = RS('summarize_dir', $dir);
    is(field($s, 'state'), 'idle', 'B17: same registry, .orchestrator ABSENT -> state eq "idle"');
    is(field($s, 'running_coordinators'), 0, 'B17: ... -> running_coordinators == 0 (a stale registry "running" is never reported live)');
    is(field($s, 'packages_total'), 8, 'B17: ... -> packages_total unchanged (8)');
    # s02/Decision 13 [corrected]: no ledger file exists for any of these 8
    # packages either, so packages_done can no longer come from the
    # registry's "done" claims -- 0, not 3.
    is(field($s, 'packages_done'), 0, 's02/B17 [corrected]: packages_done == 0 -- registry fallback removed, no ledger present for any package');
}

# --- B18 (uncited): no package running -> current_package undef. ---------
{
    my $root = tempdir(CLEANUP => 1);
    my $dir = make_blueprint($root, 'none-running', orchestrator => "1\n",
        registry => registry_json(p1 => 'done', p2 => 'pending', p3 => 'blocked'));
    is(field(RS('summarize_dir', $dir), 'current_package'), undef, 'B18: no package at status running -> current_package undef');
}

# --- AC-3 (B21): a parked-status package. ---------------------------------
{
    my $root = tempdir(CLEANUP => 1);
    my $dir = make_blueprint($root, 'withparked', orchestrator => "1\n",
        registry => registry_json(p1 => 'running', p2 => 'parked', p3 => 'done'));
    my $s = RS('summarize_dir', $dir);
    is(field($s, 'packages_total'), 3, 'AC-3: a parked-status package counts in packages_total');
    # s02/Decision 13 [corrected]: no ledger file exists for p1/p2/p3 in this
    # fixture, so p1's registry "running" claim and p3's registry "done" claim
    # are both now ignored outright -- 0/0/undef, not 1/1/'p1'.
    is(field($s, 'packages_done'), 0, 's02/AC-3 [corrected]: packages_done == 0 -- registry fallback removed, p3 was only "done" via the now-dead fallback');
    is(field($s, 'running_coordinators'), 0, 's02/AC-3 [corrected]: running_coordinators == 0 -- p1 was only "running" via the now-dead fallback');
    is(field($s, 'current_package'), undef, 's02/AC-3 [corrected]: current_package undef -- same reason');
}

# --- AC-9 (B19, B20): ledger authority over registry. ---------------------
{
    my $root = tempdir(CLEANUP => 1);
    my $dir = make_blueprint($root, 'ledgerwins', orchestrator => "1\n",
        registry => registry_json(p1 => 'running'),
        packages => { p1 => ledger_with_status('done') });
    my $s1 = RS('summarize_dir', $dir);
    is(field($s1, 'packages_done'), 1, 'AC-9: registry says running, ledger says done -> counts as done (B19)');
    is(field($s1, 'running_coordinators'), 0, 'AC-9: ... -> does not count as a running coordinator');
    is(field($s1, 'current_package'), undef, 'AC-9: ... -> not current_package');

    unlink("$dir/packages/p1.md") or die "unlink: $!";
    my $s2 = RS('summarize_dir', $dir);
    # s02/Decision 13 [corrected]: this sub-case used to prove "the registry
    # value is used when the ledger file is absent" -- that is now exactly
    # the forbidden fallback. It now proves the OPPOSITE: with the ledger
    # gone, the registry's "running" claim for p1 is never adopted. The
    # packages_done value (0) is numerically unchanged from before, but its
    # meaning has flipped -- it is no longer evidence the fallback fired
    # (registry never said "done" here), it is now evidence registry status
    # is never consulted at all, full stop.
    is(field($s2, 'packages_done'), 0, 's02/AC-9 second half [corrected, meaning flipped]: packages_done == 0 -- value unchanged, but this no longer proves the registry fallback fired; it proves the registry is never consulted');
    is(field($s2, 'running_coordinators'), 0, 's02/AC-9 second half [corrected]: running_coordinators == 0 -- with the ledger file removed, the registry status ("running") is NEVER adopted (Decision 13)');
    is(field($s2, 'current_package'), undef, 's02/AC-9 second half [corrected]: current_package undef -- same reason');
}

# --- B20 (further): ledger unreadable/oversized/no-status-line fallback. -
#
# CORRECTED by blueprint unified-tui-design-system, consolidated fix-batch
# for package 04-run-panel-ledger-truth (2026-08-07), per redteam.md HIGH-2.
# These two sub-cases previously pinned the PRE-fix expectation (a ledger
# FILE THAT EXISTS, but is oversized/statusless, falling back to the
# registry's status). That is exactly the defect-generator shape HIGH-2
# closes: "the registry is consulted only when the ledger file is ABSENT --
# never when it is present but unparseable" / "When a ledger file exists but
# yields no status, return ''" (redteam.md HIGH-2 mitigation, verbatim).
# Both dir1 and dir2 below write a REAL packages/p1.md (the file IS
# present); the corrected expectation is running_coordinators == 0, not 1.
# redteam.md's blanket claim that "t/45's B20 fixtures have no packages/ dir
# at all" does not hold for this sub-section (as opposed to the AC-9/B19-B20
# case a few lines above, which genuinely unlinks the ledger file first) --
# see test-writer-fixbatch.md's "Discrepancy found" note.
{
    my $root = tempdir(CLEANUP => 1);
    my $dir1 = make_blueprint($root, 'oversized', orchestrator => "1\n",
        registry => registry_json(p1 => 'running'),
        packages => { p1 => ('x' x (SPEC_MAX_LEDGER_BYTES + 1024)) });
    is(field(RS('summarize_dir', $dir1), 'running_coordinators'), 0, 'B20 [fix-batch HIGH-2]: an over-MAX_LEDGER_BYTES ledger file that EXISTS must NOT fall back to the registry status -- the ledger is present, just unparseable, so the package is neither done nor a running coordinator');

    my $dir2 = make_blueprint($root, 'nostatusline', orchestrator => "1\n",
        registry => registry_json(p1 => 'running'),
        packages => { p1 => ledger_no_status_line() });
    is(field(RS('summarize_dir', $dir2), 'running_coordinators'), 0, 'B20 [fix-batch HIGH-2]: a ledger frontmatter with no status: line, but whose FILE EXISTS, must NOT fall back to the registry status -- presence, not parseability, is what excludes the registry fallback');

    my $dir3 = make_blueprint($root, 'noclosefence', orchestrator => "1\n",
        registry => registry_json(p1 => 'done'),
        packages => { p1 => ledger_no_closing_fence('running') });
    my $s3 = RS('summarize_dir', $dir3);
    ok(defined field($s3, 'running_coordinators'), 'B20: a ledger with no closing "---" fence (scans to EOF) does not die');
}

# --- B22 (uncited): a per-package registry value that is not a HASH. -----
{
    my $root = tempdir(CLEANUP => 1);
    my $dir = make_blueprint($root, 'nonhash', orchestrator => "1\n",
        registry => registry_json(p1 => 'running', p2 => RAW_JSON('"x"'), p3 => RAW_JSON('null'), p4 => RAW_JSON('[1,2]')));
    my $s = RS('summarize_dir', $dir);
    is(field($s, 'packages_total'), 4, 'B22: non-HASH per-package registry values (string/null/array) still count toward packages_total');
    is(field($s, 'packages_done'), 0, 'B22: ... but count nowhere else (packages_done)');
    # s02/Decision 13 [corrected]: no ledger file exists for p1 either, so its
    # registry "running" claim (a real HASH entry, unlike p2/p3/p4) is now
    # ignored just like every other ledger-absent package -- 0, not 1.
    is(field($s, 'running_coordinators'), 0, 's02/B22 [corrected]: running_coordinators == 0 -- p1 had no ledger file, so its registry HASH entry\'s "running" status is never adopted (Decision 13), not merely "the only real HASH entry among decoys"');
}

# --- B23 (uncited): {} and {"packages":{}} -> included, all-zero. --------
{
    my $root = tempdir(CLEANUP => 1);
    for my $c ( [ 'bare {}', '{}' ], [ '{"packages":{}}', '{"packages":{}}' ] ) {
        my ($label, $body) = @$c;
        my $dir = make_blueprint($root, "empty-$label" =~ s/\W+/_/gr, orchestrator => "1\n", registry => $body);
        my $s = RS('summarize_dir', $dir);
        ok(is_hashref($s), "B23 [$label]: registry decoding to $label yields an INCLUDED summary (not skipped)");
        is(field($s, 'packages_total'), 0, "B23 [$label]: packages_total == 0");
        is(field($s, 'packages_done'), 0, "B23 [$label]: packages_done == 0");
        is(field($s, 'running_coordinators'), 0, "B23 [$label]: running_coordinators == 0");
        is(field($s, 'current_package'), undef, "B23 [$label]: current_package undef");
    }

    # S2.4 further: "packages" present but not a HASH (scalar/array/null).
    for my $c ( [ 'packages is a string', '{"packages":"nope"}' ], [ 'packages is an array', '{"packages":[1,2,3]}' ],
                [ 'packages is null', '{"packages":null}' ] ) {
        my ($label, $body) = @$c;
        my $dir = make_blueprint($root, "s24-$label" =~ s/\W+/_/gr, orchestrator => "1\n", registry => $body);
        my $s = RS('summarize_dir', $dir);
        ok(is_hashref($s), "S2.4 [$label]: still included");
        is(field($s, 'packages_total'), 0, "S2.4 [$label]: packages_total == 0 (treated as the empty hash)");
    }
}

# --- B24 (uncited): a package key containing '/' never opens a file -----
# --- outside <blueprint_dir>/packages/. -----------------------------------
{
    my $root = tempdir(CLEANUP => 1);
    my $dir = make_blueprint($root, 'traversal', orchestrator => "1\n",
        registry => registry_json('../decoy' => 'running'));
    make_path("$dir/packages");
    # A decoy ledger placed exactly where "$dir/packages/../decoy.md" resolves
    # to on disk (i.e. "$dir/decoy.md"), claiming status "done". If the
    # implementation is NOT skipping the unsafe key and naively opens
    # "$blueprint_dir/packages/$pkg.md", it will read THIS file and the
    # package will wrongly count as done instead of running.
    write_file("$dir/decoy.md", ledger_with_status('done'));
    my $s = RS('summarize_dir', $dir);
    # s02/Decision 13 [corrected]: the traversal decoy has no ledger at
    # "$dir/packages/../decoy.md" (skipped as unsafe) -- and since s02 removes
    # the registry fallback entirely, the "safe" outcome is no longer "falls
    # back to the registry status (running)", it is "resolves to no status at
    # all". running_coordinators must NOT count this package.
    is(field($s, 'running_coordinators'), 0,
        "s02/B24 [corrected]: a package key containing '/' skips the ledger read entirely AND is never adopted from the registry (Decision 13) -- the decoy ledger one path segment above packages/ is never consulted, and the registry's \"running\" claim is never consulted either");
    # This assertion is now B24's WHOLE safety property (unchanged 0, but its
    # job has changed): with running_coordinators no longer able to
    # distinguish "read the registry correctly" from "read nothing", THIS is
    # the only remaining proof the decoy's "done" claim was never adopted.
    is(field($s, 'packages_done'), 0, 's02/B24 [unchanged, now load-bearing]: packages_done == 0 -- the decoy ledger\'s "done" status is NOT picked up (this is now the only assertion in this block proving the traversal-safe path, not merely a companion to running_coordinators)');

    # Companion unsafe-key cases (S2.5 step 1's other three clauses): NUL
    # byte, leading dot, and length > 128. All fall through to step 2.
    my $root2 = tempdir(CLEANUP => 1);
    my $long_key = 'p' x 129;
    my $dir2 = make_blueprint($root2, 'unsafekeys', orchestrator => "1\n",
        registry => registry_json("p\x00q" => 'running', '.hidden' => 'running', $long_key => 'running'));
    my $s2 = RS('summarize_dir', $dir2);
    is(field($s2, 'running_coordinators'), 0, 's02/B24 [corrected]: NUL-byte / leading-dot / >128-char package keys all skip the ledger read AND are never adopted from the registry (Decision 13) -- 0, not 3');
}

# ===========================================================================
# s02-registry-runtime-only / RunState.pm regression -- Decision 13, Decision
# 16, spec §2.4 (behaviors 9, 10). `_effective_status`'s registry fallback
# (the `return _normalize_status($raw)` branch that read `$entry->{status}`
# when `$ledger_present` was false) is DELETED by this package. These two
# assertions pin `_effective_status` DIRECTLY, independent of `summarize_dir`
# (which the corrected §5 table above pins indirectly), so a future refactor
# of `summarize_dir`'s call shape cannot silently resurrect the fallback
# while still passing the higher-level assertions above.
# ===========================================================================
{
    my $root = tempdir(CLEANUP => 1);

    # Behavior 9: no ledger file at all for 'p1' ($ledger_present == 0), and
    # a registry entry claiming status "done". Pre-s02 this returned 'done'
    # (the fallback). Post-s02 it must return '' -- the registry carries no
    # authority, present or absent, per-package-ledger-exists or not.
    my $dir9 = make_blueprint($root, 'behavior9-no-ledger', registry => registry_json());
    is(RS('_effective_status', $dir9, 'p1', { status => 'done' }, 0), '',
        "s02/behavior9: _effective_status(no ledger file, \$entry={status=>'done'}, \$ledger_present=0) -> '' -- NOT 'done'; the removed registry fallback, pinned directly");

    # Behavior 10: a ledger file that EXISTS but is unparseable (over
    # SPEC_MAX_LEDGER_BYTES, same shape as the B20 'oversized' fixture above),
    # so $ledger_present == 1 and _ledger_status(...) returns ''. This case
    # was ALREADY correct pre-s02 (the fallback only fired when
    # $ledger_present was false) -- this is a regression guard, not a new fix.
    my $dir10 = make_blueprint($root, 'behavior10-unparseable-ledger',
        registry => registry_json(),
        packages => { p1 => ('x' x (SPEC_MAX_LEDGER_BYTES + 1024)) });
    is(RS('_effective_status', $dir10, 'p1', { status => 'done' }, 1), '',
        "s02/behavior10: _effective_status(ledger present but unparseable, \$entry={status=>'done'}, \$ledger_present=1) -> '' -- unchanged from pre-s02 behavior, regression guard only");
}

# ===========================================================================
# 8. decisions_waiting -- B25, B26 -> AC-10.
# ===========================================================================
{
    # AMENDED BY t07-needs-you-lifecycle (blueprint tui-operator-feedback).
    #
    # THIS ASSERTION'S SUBJECT IS THE SKIP RULES -- which directory entries are
    # eligible to be counted at all (plain files yes; .tmp, dotfiles and
    # subdirectories no). It is not about the decision lifecycle, which t07
    # added and which plugins/sandbox/tests/t/95-needs-you-lifecycle.t owns.
    #
    # The fixture used to write each record as a bare `{}`. Under t07's rule
    # that is a record with no package to resolve against, in a blueprint with
    # no orchestrator and no .paused -- i.e. a run that is OVER -- so all three
    # are correctly SETTLED and the count is 0. The skip rules were never
    # exercised; the assertion had silently changed subject.
    #
    # So the records are now unambiguously LIVE (each names a package whose
    # ledger reads `blocked`, the state that most clearly still needs a human),
    # and the assertion tests exactly what its description says again.
    my $root = tempdir(CLEANUP => 1);
    my $blocked_ledger = "---\npackage: p\nstatus: blocked\n---\n\n# body\n";
    my $dir = make_blueprint($root, 'decisions', registry => registry_json(),
        packages  => { p1 => $blocked_ledger, p2 => $blocked_ledger, p3 => $blocked_ledger },
        needs_you => [
            { name => 'a.json',   content => '{"package":"p1","kind":"stuck-package"}' },
            { name => 'b.json',   content => '{"package":"p2","kind":"stuck-package"}' },
            { name => 'c.json',   content => '{"package":"p3","kind":"stuck-package"}' },
            { name => 'skip.tmp', content => '{"package":"p1","kind":"stuck-package"}' },
            { name => '.hidden',  content => '{"package":"p1","kind":"stuck-package"}' },
            { name => 'a-subdir', is_dir => 1 },
        ]);
    is(field(RS('summarize_dir', $dir), 'decisions_waiting'), 3,
        'AC-10/B25: escalations/ with 3 plain files + a .tmp + a dotfile + a subdir -> decisions_waiting == 3');

    my $root2 = tempdir(CLEANUP => 1);
    my $dir_absent = make_blueprint($root2, 'noneedsyou', registry => registry_json());
    is(field(RS('summarize_dir', $dir_absent), 'decisions_waiting'), 0, 'AC-10/B26: escalations/ absent -> decisions_waiting == 0');

    my $dir_empty = make_blueprint($root2, 'emptyneedsyou', registry => registry_json(), needs_you => []);
    is(field(RS('summarize_dir', $dir_empty), 'decisions_waiting'), 0, 'AC-10/B26: escalations/ present but empty -> decisions_waiting == 0');
}

# ===========================================================================
# 9. AC-12: RunState.pm never writes.
# ===========================================================================
{
    my $root = tempdir(CLEANUP => 1);
    make_blueprint($root, 'a', orchestrator => "1\n", registry => registry_json(p1 => 'running', p2 => 'done'),
        packages => { p1 => ledger_with_status('running') },
        needs_you => [ { name => 'x.json' } ]);
    make_blueprint($root, 'b', paused => '{"manual":true,"reason":"r"}', registry => registry_json());
    make_blueprint($root, 'c', registry => 'not json at all');

    my $before = snapshot_tree($root);
    my ($res, $err) = probe_call('summarize', $root);
    if ($err ne '') {
        fail('AC-12: summarize() completed so the no-writes invariant could be checked [call did not happen -- module missing]');
    } else {
        my $after = snapshot_tree($root);
        is_deeply($after, $before, 'AC-12: after a full summarize() over the fixture, every file\'s size:mtime is unchanged and no new file exists');
    }
}

# ===========================================================================
# 10. AC-24 (B8): multiple active blueprints, ordering + independence.
# ===========================================================================
{
    my $root = tempdir(CLEANUP => 1);
    make_blueprint($root, 'zzz-third', orchestrator => "1\n", registry => registry_json(p1 => 'running'),
        needs_you => [ { name => 'd1.json' } ]);
    make_blueprint($root, 'aaa-first', registry => registry_json(p1 => 'done', p2 => 'done'));
    make_blueprint($root, 'mmm-second', paused => '{"manual":true,"reason":"mid"}', orchestrator => "1\n",
        registry => registry_json(p1 => 'running', p2 => 'pending'));

    my $list = RS('summarize', $root);
    if (is_arrayref($list)) {
        is(scalar(@$list), 3, 'AC-24/B8: three valid blueprints -> three summaries');
        is_deeply([ map { field($_, 'blueprint') } @$list ], [ qw(aaa-first mmm-second zzz-third) ],
            'AC-24/B8: ordered ascending by blueprint directory name');
        is(field($list->[0], 'state'), 'idle',    'AC-24/B8: aaa-first (no markers) -> idle');
        is(field($list->[1], 'state'), 'paused',  'AC-24/B8: mmm-second (.orchestrator+.paused) -> paused');
        is(field($list->[2], 'state'), 'running', 'AC-24/B8: zzz-third (.orchestrator only) -> running');
        is(field($list->[2], 'decisions_waiting'), 1, 'AC-24/B8: zzz-third carries its own independent decisions_waiting');
        is(field($list->[0], 'decisions_waiting'), 0, 'AC-24/B8: aaa-first carries its own independent decisions_waiting (0, no escalations/)');
    } else {
        fail('AC-24/B8: summarize() returned an arrayref of 3 summaries');
    }
}

# ===========================================================================
# 11. AC-25: decisions_waiting SUM agrees with launcher.pl's
#     _count_needs_you counting rule (same skip rules, by construction).
# ===========================================================================
{
    # AMENDED BY t07-needs-you-lifecycle, for the same reason as B25 above and
    # with one extra note.
    #
    # mirror_count_needs_you is an independent reimplementation of the SKIP
    # RULES, and that is still exactly what it is worth here. What it can no
    # longer mirror is the launcher's whole counting rule, because t07 made the
    # launcher derive its number from RunState::summarize rather than walk the
    # tree itself -- so "the two agree" is now true by construction, and
    # asserting it against a third hand-written walk would be asserting a
    # tautology while pretending otherwise.
    #
    # What this pair still earns: the skip rules agree between the mirror and
    # RunState. The lifecycle half is owned by
    # plugins/sandbox/tests/t/95-needs-you-lifecycle.t, and the launcher's
    # derivation is pinned by that file's AC5.
    my $root = tempdir(CLEANUP => 1);
    my $blocked = "---\npackage: p\nstatus: blocked\n---\n\n# body\n";
    my $live    = sub { my ($p) = @_; qq({"package":"$p","kind":"stuck-package"}) };
    make_blueprint($root, 'x1', registry => registry_json(),
        packages  => { p1 => $blocked, p2 => $blocked },
        needs_you => [ { name => 'a.json', content => $live->('p1') },
                       { name => 'b.json', content => $live->('p2') },
                       { name => '.dot',   content => $live->('p1') },
                       { name => 'z.tmp',  content => $live->('p1') } ]);
    make_blueprint($root, 'x2', registry => registry_json(),
        packages  => { p3 => $blocked },
        needs_you => [ { name => 'c.json', content => $live->('p3') },
                       { name => 'sub', is_dir => 1 } ]);
    make_blueprint($root, 'x3', registry => registry_json());   # no escalations/ at all
    make_blueprint($root, 'x4-broken', registry => 'not json');   # malformed, excluded from summarize entirely

    my $list = RS('summarize', $root);
    my $rs_sum = is_arrayref($list) ? eval { my $t = 0; $t += ($_->{decisions_waiting} // 0) for @$list; $t } : undef;
    my $mirror_sum = mirror_count_needs_you($root);   # deliberately includes x4-broken's escalations/ (none here) too
    is($mirror_sum, 3, 'AC-25: sanity -- the independent mirror of _count_needs_you counts 3 over this fixture (a,b,c; not .dot/.tmp/subdir)');
    is($rs_sum, $mirror_sum, 'AC-25: sum(decisions_waiting) across all RunState summaries equals the launcher._count_needs_you-equivalent count over the same tree');
}

# ===========================================================================
# 12. Launcher wiring -- AC-13, AC-14, AC-15 (B29, B30, B31).
#     Source-text only: launcher.pl is NEVER require'd (side effects).
# ===========================================================================
my $launcher_src = slurp($LAUNCHER_PATH);
ok(length($launcher_src) > 0, 'launcher.pl is readable on disk') or BAIL_OUT("cannot read $LAUNCHER_PATH");

# --- AC-13 (B31): use RunState (); + sub _gather_runs calling RunState::summarize. ---
{
    like($launcher_src, qr/\buse\s+RunState\s*\(\s*\)\s*;/, 'AC-13: launcher.pl source contains "use RunState ();"');
    like($launcher_src, qr/\bsub\s+_gather_runs\b/, 'AC-13: launcher.pl defines sub _gather_runs');

    my $body = extract_block($launcher_src, 'sub _gather_runs');
    if (defined $body) {
        like($body, qr/RunState::summarize\s*\(/, 'AC-13: _gather_runs body calls RunState::summarize(...)');
        like($body, qr/\$project\b/, 'AC-13: _gather_runs body references its $project argument');
        like($body, qr/\.ccpraxis-local-data\/blueprints/, "AC-13: _gather_runs body references the project's .ccpraxis-local-data/blueprints path");
    } else {
        fail('AC-13: _gather_runs body calls RunState::summarize(...) (sub not found -- cannot extract body)');
        fail('AC-13: _gather_runs body references $project (sub not found)');
        fail('AC-13: _gather_runs body references .ccpraxis-local-data/blueprints (sub not found)');
    }
}

# --- AC-14 (B30): $cached_runs = _gather_runs(...) inside the 10s guard, --
# --- NOT inside the Resources::should_sample block. -----------------------
{
    my $gather_block = extract_block($launcher_src, 'gather    => sub {');
    ok(defined $gather_block, 'AC-14: the gather => sub {...} closure is extractable from launcher.pl')
        or diag('cannot locate the "gather    => sub {" literal -- has formatting changed?');
    if (defined $gather_block) {
        my ($guard_slice) = $gather_block =~ /if\s*\(\s*\$now\s*-\s*\$last_inspect\s*>=\s*(?:\d+|\$[A-Za-z_]\w*)\s*\)\s*\{(.*?)\$last_inspect\s*=\s*\$now\s*;/s;
        ok(defined $guard_slice, 'AC-14: located the ~10s cache guard slice inside the gather closure');
        if (defined $guard_slice) {
            like($guard_slice, qr/\$cached_runs\s*=\s*_gather_runs\s*\(/,
                'AC-14: $cached_runs = _gather_runs(...) is inside the ~10s cache guard');
        } else {
            fail('AC-14: $cached_runs = _gather_runs(...) is inside the ~10s cache guard (guard slice not found)');
        }

        my ($should_sample_slice) = $gather_block =~ /if\s*\(\s*Resources::should_sample\s*\((.*)/s;
        my $rs_block = defined $should_sample_slice ? _balanced($gather_block, index($gather_block, 'if (Resources::should_sample(')) : undef;
        $rs_block = _balanced($gather_block, index($gather_block, 'Resources::should_sample')) unless defined $rs_block;
        if (defined $rs_block) {
            unlike($rs_block, qr/_gather_runs\s*\(/,
                'AC-14: the Resources::should_sample(...) block does NOT contain the _gather_runs(...) call');
        } else {
            fail('AC-14: the Resources::should_sample(...) block does not contain _gather_runs (block not found)');
        }

        my $n_calls = () = $gather_block =~ /_gather_runs\s*\(/g;
        is($n_calls, 1, 'AC-14: _gather_runs(...) is called exactly once in the whole gather closure');
    } else {
        fail('AC-14: $cached_runs = _gather_runs(...) is inside the ~10s cache guard (gather closure not found)');
        fail('AC-14: the Resources::should_sample(...) block does not contain _gather_runs (gather closure not found)');
        fail('AC-14: _gather_runs(...) called exactly once (gather closure not found)');
    }
}

# --- AC-15 (B29): runs => $cached_runs in the same return hash as --------
# --- needs_you/backpack/tokens/resources. ---------------------------------
{
    like($launcher_src, qr/runs\s*=>\s*\$cached_runs\s*,/, 'AC-15: gather return hash contains "runs => $cached_runs,"');
    like($launcher_src, qr/my\s+\$cached_runs\s*=\s*\[\s*\]\s*;/, 'AC-15: $cached_runs is declared, initialised to [] (never undef)');

    my $gather_block = extract_block($launcher_src, 'gather    => sub {');
    if (defined $gather_block) {
        my $return_block = _balanced($gather_block, index($gather_block, 'return {'));
        if (defined $return_block) {
            for my $sibling (qw(needs_you backpack tokens resources)) {
                like($return_block, qr/\Q$sibling\E\s*=>/, "AC-15: the return hashref also contains \"$sibling =>\" (same hash literal)");
            }
            like($return_block, qr/runs\s*=>\s*\$cached_runs/, 'AC-15: the return hashref contains "runs => $cached_runs" (same hash literal as the siblings)');
        } else {
            fail('AC-15: the gather closure\'s "return {...}" hash literal is extractable');
        }
    } else {
        fail('AC-15: the gather closure\'s "return {...}" hash literal is extractable (gather closure not found)');
    }
}

# ===========================================================================
# 13. Dashboard rendering -- AC-16..AC-23, AC-26 (B32-B39).
# ===========================================================================

# run_lines_of($runs) -> Dashboard::_run_lines($runs) as a list; a single
# sentinel element on death (never lets a missing sub silently look like ()).
sub run_lines_of {
    my ($runs) = @_;
    my @lines = eval { Dashboard::_run_lines($runs) };
    return ({ __CALL_FAILED => ($@ || 'unknown') }) if $@;
    return @lines;
}

# as_arrayref($v) -> $v if it's an ARRAY ref, else [] (so a call-failed
# sentinel -- a single HASH element -- never blows up a `@{...}` deref).
sub as_arrayref { my ($v) = @_; return (ref($v) eq 'ARRAY') ? $v : []; }

# mk_summary(%o) -> a literal S2.2-shaped hashref, defaults filled in.
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

my %BASE_STATE = (
    project_name => 'demo', container => 'c1', status => 'running',
    beat_age => 12, uptime => 3660, oauth_remaining => 11520,
    busy_age => 30, stay_awake => 1, needs_you => 2,
);
# _label45($label) -> the ONE shared label-gutter rendering of $label (spec
# S2.4.1: sprintf('%-*s : ', LABEL_GUTTER(), label)), so every expected
# label string below is DERIVED, never hand-padded.
sub _label45 { return sprintf('%-*s : ', tui::DashboardScreen::LABEL_GUTTER(), $_[0]); }

# ===========================================================================
# RE-POINTED (package 06-dashboard-screen, spec S2.4.3, driver report item
# 4). heartbeat/uptime MOVED to the front of Run (the deleted Sandbox
# panel's rows -- see t/41-panel-semantics.t AC1), so busy-lease/
# keep-awake/escalations shift from Run indices 0/1/2 to 2/3/4. This also
# means the Run panel's TOTAL line count is no longer 3 (or 4, or 7) in any
# of the three ACs below -- every fixture in this section also carries an
# unconditional oauth row (none of them sets $state->{tokens}), on top of
# the two migrated rows. Re-pointing those totals to new numbers would just
# re-encode the SAME whole-shape pin Decision 15 / t/00-oracle-hygiene.t
# already forbids elsewhere in this package. What survives, PRESERVED not
# weakened: each affected row, individually identified by content and
# position -- the property "exactly N lines" was actually standing in for.
# @PINNED_RUN_LABELS itself is also re-derived via _label45()/LABEL_GUTTER()
# rather than hand-padded: the OLD hand-typed literals ('busy-lease : ', 1
# space before the colon) assumed the pre-package-06 Run panel's own
# LOCAL gutter (sized to fit only busy-lease/keep-awake/escalations); the
# NEW shared LABEL_GUTTER()==11 is wider (sized across every panel), so
# the correct padding is now 2-3 spaces before the colon depending on the
# label -- a fact this file must derive, never re-type.
# ===========================================================================
my @PINNED_RUN_LABELS = ( _label45('busy-lease'), _label45('keep-awake'), _label45('needs you') );

# --- AC-16 (B32): no runs key / runs=>[] / runs=>'x' -> the SAME Run ------
# --- panel, byte-identical, unaffected by the new code path. --------------
{
    my @variants = ( [ 'no runs key', {} ], [ 'runs => []', { runs => [] } ], [ "runs => 'x'", { runs => 'x' } ] );
    my @all_lines03;
    for my $v (@variants) {
        my ($label, $extra) = @$v;
        my %s = (%BASE_STATE, %$extra);
        my @panels = eval { Dashboard::_fixed_panels(\%s, 80) };
        my ($run) = grep { ref($_) eq 'HASH' && ($_->{title} // '') eq 'Run' } @panels;
        ok($run, "AC-16: a Run panel is present ($label)");
        if ($run) {
            ok(defined($run->{lines}[4]),
                "AC-16/B32: Run has a row at the escalations position (index 4) ($label) -- re-pointed off the old exactly-3-lines count, t/41:137 non-regression");
            for my $i (0 .. 2) {
                is($run->{lines}[$i + 2][0]{text}, $PINNED_RUN_LABELS[$i],
                    "AC-16: Run line " . ($i + 2) . " (was line $i pre-package-06) label text unchanged ($label)");
                is($run->{lines}[$i + 2][0]{role}, 'label',
                    "AC-16: Run line " . ($i + 2) . " label role is 'label' ($label)");
            }
            push @all_lines03, $run->{lines};
        } else {
            push @all_lines03, undef;
        }
    }
    if (defined $all_lines03[0] && defined $all_lines03[1] && defined $all_lines03[2]) {
        is_deeply($all_lines03[1], $all_lines03[0], 'AC-16: runs=>[] produces the IDENTICAL Run-panel line structure as no runs key at all');
        is_deeply($all_lines03[2], $all_lines03[0], "AC-16: runs=>'x' (non-arrayref) produces the IDENTICAL Run-panel line structure as no runs key at all");
    } else {
        fail('AC-16: runs=>[] identical to no-runs-key (Run panel missing in at least one variant)');
        fail('AC-16: runs=>\'x\' identical to no-runs-key (Run panel missing in at least one variant)');
    }
}

# --- AC-17 (B33): one running summary -> a 4th line, exact span list. ----
{
    my $summary = mk_summary(blueprint => 'demo-bp', state => 'running', packages_total => 8, packages_done => 3,
        current_package => 'pkgX', running_coordinators => 2, decisions_waiting => 0);
    my %s = (%BASE_STATE, runs => [ $summary ]);
    my @panels = eval { Dashboard::_fixed_panels(\%s, 80) };
    my ($run) = grep { ref($_) eq 'HASH' && ($_->{title} // '') eq 'Run' } @panels;
    ok($run, 'AC-17: Run panel present with one running summary');
    if ($run) {
        # RE-POINTED (driver report item 4): same index shift as AC-16
        # above (fixed rows now at 2/3/4, not 0/1/2 -- no backpack row in
        # this fixture); the summary row -- appended immediately after
        # them -- moves from index 3 to index 5. "Exactly 4 lines" is
        # re-pointed to a per-row presence+content check instead of a new
        # total, for the same Decision-15 reason as AC-16.
        ok(defined($run->{lines}[4]),
            'AC-17/B33: Run has a row at the escalations position (index 4) -- re-pointed off the old exactly-4-lines count');
        for my $i (0 .. 2) {
            is($run->{lines}[$i + 2][0]{text}, $PINNED_RUN_LABELS[$i], "AC-17: line " . ($i + 2) . " (was line $i pre-package-06) unchanged");
        }
        my $expected_line3 = [
            { text => 'demo-bp : ', role => 'accent' },
            { text => 'running',    role => 'good' },
            { text => '  3/8 pkg',  role => 'value' },
            { text => '  cur pkgX', role => 'strong' },
            { text => '  2 coord',  role => 'accent' },
        ];
        is_deeply($run->{lines}[5], $expected_line3,
            'AC-17/B33: the summary line (now at index 5, immediately after escalations) is EXACTLY the S2.10 span list for this summary (decisions_waiting==0 -> no trailing "waiting" span)');
    } else {
        fail('AC-17/B33: Run has a row at the escalations position (no Run panel)');
        fail('AC-17/B33: summary line exact span list (no Run panel)');
    }
}

# --- AC-18 (B34): the state -> role table. --------------------------------
{
    my @cases = ( [ 'running', 'good' ], [ 'paused', 'warn' ], [ 'parked', 'warn' ], [ 'idle', 'muted' ], [ 'totally-unknown', 'muted' ] );
    for my $c (@cases) {
        my ($state, $erole) = @$c;
        my @lines = run_lines_of([ mk_summary(blueprint => 'b', state => $state) ]);
        my $line = $lines[0];
        ok(ref($line) eq 'ARRAY', "AC-18: _run_lines([{state=>'$state'}]) yields one ARRAY line");
        my $state_span = (ref($line) eq 'ARRAY') ? $line->[1] : undef;
        is(ref($state_span) eq 'HASH' ? $state_span->{text} : undef, $state, "AC-18: state=$state -- span 2 text is the state verbatim");
        is(ref($state_span) eq 'HASH' ? $state_span->{role} : undef, $erole, "AC-18: state=$state -- span 2 role is '$erole'");
    }
}

# --- AC-19 (B35): decisions_waiting trailing span role (warn vs paused/bad). ---
{
    my @lines_running = run_lines_of([ mk_summary(blueprint => 'b', state => 'running', decisions_waiting => 5) ]);
    my ($trailing_r) = grep { ref($_) eq 'HASH' && defined($_->{text}) && $_->{text} =~ /waiting$/ } @{ as_arrayref($lines_running[0]) };
    is($trailing_r ? $trailing_r->{text} : undef, '  5 waiting', 'AC-19: decisions_waiting=5, state running -- trailing span text "  5 waiting"');
    is($trailing_r ? $trailing_r->{role} : undef, 'warn', 'AC-19: ... role "warn" (state is not paused)');

    my @lines_paused = run_lines_of([ mk_summary(blueprint => 'b', state => 'paused', decisions_waiting => 5) ]);
    my ($trailing_p) = grep { ref($_) eq 'HASH' && defined($_->{text}) && $_->{text} =~ /waiting$/ } @{ as_arrayref($lines_paused[0]) };
    is($trailing_p ? $trailing_p->{text} : undef, '  5 waiting', 'AC-19: decisions_waiting=5, state paused -- trailing span text unchanged');
    is($trailing_p ? $trailing_p->{role} : undef, 'bad', 'AC-19: ... role "bad" (state IS paused -- fully stalled on the human)');
}

# --- AC-20 (B36): optional spans OMITTED, not blanked. --------------------
{
    my @lines_nocur = run_lines_of([ mk_summary(blueprint => 'b', state => 'running', current_package => undef, running_coordinators => 3) ]);
    my @cur_spans = grep { ref($_) eq 'HASH' && defined($_->{text}) && $_->{text} =~ /^\s*cur\s/ } @{ as_arrayref($lines_nocur[0]) };
    is(scalar(@cur_spans), 0, 'AC-20: current_package undef -> no span whose text starts with "  cur "');

    my @lines_nocoord = run_lines_of([ mk_summary(blueprint => 'b', state => 'running', current_package => 'p1', running_coordinators => 0) ]);
    my @coord_spans = grep { ref($_) eq 'HASH' && defined($_->{text}) && $_->{text} =~ /coord$/ } @{ as_arrayref($lines_nocoord[0]) };
    is(scalar(@coord_spans), 0, 'AC-20: running_coordinators == 0 -> no span whose text ends in " coord"');
}

# --- AC-21 (B37): 5 summaries -> 3 shown + "+2 more blueprint(s)". -------
{
    my @five = map { mk_summary(blueprint => "bp$_", state => 'idle') } (1 .. 5);
    my @lines = run_lines_of(\@five);
    is(scalar(@lines), 4, 'AC-21/B37: _run_lines(5 summaries) -> 3 summary lines + 1 overflow line = 4');
    is_deeply($lines[3], [ { text => '  +2 more blueprint(s)', role => 'muted' } ],
        'AC-21/B37: the trailing overflow line is EXACTLY [{text=>"  +2 more blueprint(s)", role=>"muted"}]');

    my %s = (%BASE_STATE, runs => \@five);
    my @panels = eval { Dashboard::_fixed_panels(\%s, 80) };
    my ($run) = grep { ref($_) eq 'HASH' && ($_->{title} // '') eq 'Run' } @panels;
    ok($run, 'AC-21/B37: a Run panel is present with 5 run summaries');
    if ($run) {
        # RE-POINTED (driver report item 4): same index shift as AC-16/
        # AC-17 above (fixed rows at 2/3/4, no backpack row in this
        # fixture); the 4 lines run_lines_of(\@five) produced above (still
        # green, unchanged) are appended starting at index 5, through
        # index 8. "3 (fixed) + 3 (summaries) + 1 (overflow) = 7 lines" is
        # re-pointed to a per-row identity check (the SAME 4 lines,
        # byte-identical, at the expected indices) instead of a new total,
        # for the same Decision-15 reason as AC-16/AC-17.
        is_deeply([ @{ $run->{lines} }[5 .. 8] ], \@lines,
            'AC-21/B37: Run indices 5-8 (immediately after escalations) are BYTE-IDENTICAL, in order, to run_lines_of(5 summaries)\'s own 4 lines (3 summaries + 1 overflow), appended verbatim');
    } else {
        fail('AC-21/B37: Run indices 5-8 match run_lines_of(5 summaries) (no Run panel)');
    }
}

# --- AC-22 (B38): totality of Dashboard::_run_lines. ----------------------
{
    is_deeply([ run_lines_of(undef) ], [], 'AC-22/B38: _run_lines(undef) -> empty list, never dies');
    is_deeply([ run_lines_of({}) ], [], 'AC-22/B38: _run_lines({}) (non-arrayref) -> empty list, never dies');
    is_deeply([ run_lines_of([ undef ]) ], [], 'AC-22/B38: _run_lines([undef]) -> empty list (non-hashref element skipped)');
    is_deeply([ run_lines_of([ 'x' ]) ], [], "AC-22/B38: _run_lines(['x']) -> empty list (non-hashref element skipped)");

    my @one = run_lines_of([ {} ]);
    is(scalar(@one), 1, 'AC-22/B38: _run_lines([{}]) -> exactly one line');
    my $first_span = (ref($one[0]) eq 'ARRAY') ? $one[0][0] : undef;
    is(ref($first_span) eq 'HASH' ? $first_span->{text} : undef, '? : ', 'AC-22/B38: _run_lines([{}]) -- first span text is exactly "? : " (blueprint undef fallback)');
}

# --- AC-23: Dashboard.pm never use/require's RunState; _run_lines does ---
# --- no file I/O. -----------------------------------------------------------
{
    my $dash_src = slurp($DASHBOARD_PATH);
    ok(length($dash_src) > 0, 'AC-23: Dashboard.pm is readable on disk') or BAIL_OUT("cannot read $DASHBOARD_PATH");
    unlike($dash_src, qr/\buse\s+RunState\b/,     'AC-23: Dashboard.pm source contains no "use RunState"');
    unlike($dash_src, qr/\brequire\s+RunState\b/, 'AC-23: Dashboard.pm source contains no "require RunState"');

    my $body = extract_block($dash_src, 'sub _run_lines');
    if (defined $body) {
        unlike($body, qr/\bopen\s*\(/,    'AC-23: _run_lines body contains no open(...) call');
        unlike($body, qr/\bopendir\b/,    'AC-23: _run_lines body contains no opendir');
    } else {
        fail('AC-23: _run_lines body contains no open(...) (sub not found)');
        fail('AC-23: _run_lines body contains no opendir (sub not found)');
    }
}

# --- AC-26 (B39): Run panel index/title invariant. ------------------------
# RE-POINTED (package 06-dashboard-screen, spec S2.4.3): the Sandbox panel
# -- which used to occupy index 0, pushing Run to index 1 -- is deleted, so
# Run is now the FIRST fixed panel. The claim ("Run sits at a STABLE index,
# whether or not runs are populated -- no new panel is ever inserted before
# it") survives unchanged; only the pinned index moves from 1 to 0.
{
    my @p_without = eval { Dashboard::build_panels(\%BASE_STATE, 80) };
    is($p_without[0] ? $p_without[0]{title} : undef, 'Run', 'AC-26/B39: with no runs populated, build_panels()[0]->{title} eq "Run"');

    my %with_runs = (%BASE_STATE, runs => [ mk_summary(blueprint => 'b', state => 'running') ]);
    my @p_with = eval { Dashboard::build_panels(\%with_runs, 80) };
    is($p_with[0] ? $p_with[0]{title} : undef, 'Run', 'AC-26/B39: with runs populated, build_panels()[0]->{title} is STILL "Run" (no new panel inserted before it)');
}

done_testing();
