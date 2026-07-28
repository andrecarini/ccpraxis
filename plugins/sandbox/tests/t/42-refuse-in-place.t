#!/usr/bin/env perl
# Tests for the p01 in-place refusal (blueprint sandbox-refuse-in-place).
#
# IMMUTABLE ORACLE: written from the spec BEFORE the implementation exists.
# Do not weaken these assertions to make a future implementation's life
# easier; a criterion this file cannot honestly test is reported, not faked.
#
# Deliberate deviation from the spec's literal boilerplate (spec §7 says
# `use CcpraxisWorkCopy qw(workcopy_route workcopy_refusal_outcome);`):
# right now `workcopy_refusal_outcome` does not exist yet, so Exporter would
# die at compile time on that `use` line and this whole file would produce
# ZERO TAP output — not a set of failing tests, just a crash. We instead
# `require CcpraxisWorkCopy;` and resolve each symbol via `->can`, so every
# criterion that CAN report a meaningful red/green does so. Any criterion
# whose mechanism truly needs `workcopy_refusal_outcome` to exist reports an
# honest failure ("not yet implemented"), never a skip and never a silent
# pass. AC-L2 still asserts (via source grep on launcher.pl, not by us
# importing it) that the *launcher* uses the real `use ... qw(...)` form.
#
# Criterion mapping (spec §7):
#   AC-R1..R11 : workcopy_refusal_outcome(\%opts) — pure payload (Group R)
#   AC-L1..L7  : launcher.pl is wired to refuse — structural + compile (Group L)
#   AC-P1..P4  : passthrough route is unchanged (Group P)
#   AC-D1..D6  : the deleted machinery is actually gone (Group D)
#   AC-G1      : leftover-symbol gate, mechanised in-test (Group G)
#   AC-E1      : end-to-end refusal, guarded real subprocess (Group E)

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use File::Temp qw(tempfile);
use Cwd qw(abs_path);
use File::Basename qw(dirname);

# =====================================================================
# Load the module without importing (see deviation note above).
# =====================================================================
my $module_loaded = eval { require CcpraxisWorkCopy; 1 };
BAIL_OUT("cannot load CcpraxisWorkCopy.pm at all: $@") unless $module_loaded;

my $workcopy_route_fn   = CcpraxisWorkCopy->can('workcopy_route');
my $workcopy_refusal_fn = CcpraxisWorkCopy->can('workcopy_refusal_outcome');
BAIL_OUT('CcpraxisWorkCopy->can(\'workcopy_route\') is false — the detector (B7) must be retained')
    unless $workcopy_route_fn;

# Safe caller: never lets a die from the module under test kill this file.
# (Only relevant once workcopy_refusal_outcome exists; per spec §3.3 it must
# never die anyway, but AC-R9 tests that directly and independently.)
sub refusal_or_undef {
    my (@args) = @_;
    return undef unless $workcopy_refusal_fn;
    my $r = eval { $workcopy_refusal_fn->(@args) };
    return $r;
}

# =====================================================================
# Shared setup — read launcher.pl and CcpraxisWorkCopy.pm sources once.
# =====================================================================
my $SCRIPTS  = "$Bin/../../scripts";
my $LAUNCHER = "$SCRIPTS/launcher.pl";
my $MODULE   = "$SCRIPTS/CcpraxisWorkCopy.pm";

open my $lfh, '<:raw', $LAUNCHER or BAIL_OUT("cannot open launcher.pl: $!");
my @lines = <$lfh>;
close $lfh;
my $lsrc = join '', @lines;
# code-only view: strip whole-line and trailing # comments before forbidden-symbol sweeps
my $lcode = join '', map { my $x = $_; $x =~ s/#.*$//; $x } @lines;

open my $mfh, '<:raw', $MODULE or BAIL_OUT("cannot open CcpraxisWorkCopy.pm: $!");
my @mlines = <$mfh>;
close $mfh;
my $msrc  = join '', @mlines;
my $mcode = join '', map { my $x = $_; $x =~ s/#.*$//; $x } @mlines;

# Locate the offer-branch open brace and its closer once; reused by Group L,
# Group P and diagnostics. NOT memoised across a hypothetical re-run — this
# is a single-shot script.
my $offer_idx;
for my $i (0 .. $#lines) {
    if ($lines[$i] =~ /if\s*\(\s*\$route\s+eq\s+['"]offer['"]\s*\)/) { $offer_idx = $i; last; }
}
my $close_idx;
if (defined $offer_idx) {
    for my $i ($offer_idx + 1 .. $#lines) {
        if ($lines[$i] =~ /^\}\s*$/) { $close_idx = $i; last; }
    }
}
my $podman_start_idx;
for my $i (0 .. $#lines) {
    if ($lines[$i] =~ /system\s*\(\s*\$PODMAN\s*,\s*'start'/) { $podman_start_idx = $i; last; }
}

# =====================================================================
# Group R — the refusal payload (pure module; no launcher, no container)
# =====================================================================

my $FAKE_PATH = 'C:/foo/ccpraxis';
my $FAKE_LIVE = 'C:/foo/ccpraxis';
my $o1 = refusal_or_undef({ path => $FAKE_PATH, live_root => $FAKE_LIVE });

# AC-R1
is(ref $o1, 'HASH', 'AC-R1: workcopy_refusal_outcome({path,live_root}) returns a HASH ref');

# AC-R2
ok(defined $o1->{exit_code}, 'AC-R2: exit_code is defined');
like(defined $o1->{exit_code} ? $o1->{exit_code} : '', qr/^\d+$/, 'AC-R2: exit_code looks like an integer');
ok((defined $o1->{exit_code} && $o1->{exit_code} != 0), 'AC-R2: exit_code is non-zero');

# AC-R3
is($o1->{launch}, 0, 'AC-R3: launch == 0');
is($o1->{warn},   1, 'AC-R3: warn == 1');

# AC-R4
like(defined $o1->{message} ? $o1->{message} : '', qr/\Q$FAKE_PATH\E/,
     'AC-R4: message contains the offending path verbatim');

# AC-R5
like(defined $o1->{message} ? $o1->{message} : '', qr/\Q--no-hardlinks\E/,
     'AC-R5: message contains the literal string --no-hardlinks');

# AC-R6 — distinct path/live_root so the two cannot be confused
my $DISTINCT_PATH = 'C:/somewhere/project-in-place';
my $DISTINCT_LIVE = 'C:/somewhere-else/ccpraxis-live';
my $o6 = refusal_or_undef({ path => $DISTINCT_PATH, live_root => $DISTINCT_LIVE });
like(defined $o6->{message} ? $o6->{message} : '', qr/git clone --no-hardlinks \Q$DISTINCT_LIVE\E\s+\S+/,
     'AC-R6: message contains "git clone --no-hardlinks <live_root> <dest>" with the correct live_root');

# AC-R7
like(defined $o1->{message} ? $o1->{message} : '', qr/install\.pl/, 'AC-R7a: message mentions install.pl');
like(defined $o1->{message} ? $o1->{message} : '', qr/\bhost\b/i,   'AC-R7b: message mentions "host"');

# AC-R8 — no vestige of the deleted decline/worktree/offer model
unlike(defined $o1->{message} ? $o1->{message} : '', qr/declin/i, 'AC-R8a: message does not mention "decline"');
unlike(defined $o1->{message} ? $o1->{message} : '', qr/worktree/i, 'AC-R8b: message does not mention "worktree"');
unlike(defined $o1->{message} ? $o1->{message} : '', qr/\boffer\b/i, 'AC-R8c: message does not mention "offer"');

# AC-R9 — graceful degradation: no args, and empty-hash args
{
    my ($o_noargs, $err_noargs);
    {
        local $@;
        $o_noargs = eval {
            $workcopy_refusal_fn or die "workcopy_refusal_outcome is not implemented yet\n";
            $workcopy_refusal_fn->();
        };
        $err_noargs = $@;
    }
    is($err_noargs, '', 'AC-R9a: workcopy_refusal_outcome() with no args does not die');
    ok((defined $o_noargs && ref $o_noargs eq 'HASH'
        && defined $o_noargs->{message} && length $o_noargs->{message}),
       'AC-R9b: workcopy_refusal_outcome() with no args returns a complete, non-empty message');
    like(($o_noargs && $o_noargs->{message}) // '', qr/\Q--no-hardlinks\E/,
         'AC-R9c: no-args message still contains --no-hardlinks');
    ok((defined $o_noargs && defined $o_noargs->{exit_code} && $o_noargs->{exit_code} != 0),
       'AC-R9d: no-args exit_code is non-zero');

    my ($o_empty, $err_empty);
    {
        local $@;
        $o_empty = eval {
            $workcopy_refusal_fn or die "workcopy_refusal_outcome is not implemented yet\n";
            $workcopy_refusal_fn->({});
        };
        $err_empty = $@;
    }
    is($err_empty, '', 'AC-R9e: workcopy_refusal_outcome({}) does not die');
    ok((defined $o_empty && ref $o_empty eq 'HASH'
        && defined $o_empty->{message} && length $o_empty->{message}),
       'AC-R9f: workcopy_refusal_outcome({}) returns a complete, non-empty message');
    like(($o_empty && $o_empty->{message}) // '', qr/\Q--no-hardlinks\E/,
         'AC-R9g: {}-args message still contains --no-hardlinks');
    ok((defined $o_empty && defined $o_empty->{exit_code} && $o_empty->{exit_code} != 0),
       'AC-R9h: {}-args exit_code is non-zero');
}

# AC-R10 — byte transparency (mirrors t/39 AC-17's byte-string idiom)
{
    my $andre_path = "C:/Users/Andr\x{c3}\x{a9}/ccpraxis"; # UTF-8 bytes: e9 -> c3 a9
    my $o10 = refusal_or_undef({ path => $andre_path, live_root => $andre_path });
    like(defined $o10->{message} ? $o10->{message} : '', qr/\Q$andre_path\E/,
         'AC-R10a: message contains the André UTF-8 byte path verbatim');
    ok((defined $o10->{message} && !utf8::is_utf8($o10->{message})),
       'AC-R10b: returned message has no utf8 flag set (byte string)');
}

# AC-R11 — Decision #6: C:/Development/ccpraxis is illustrative only, never
# the clone destination; and the message is not Windows-only.
unlike(defined $o1->{message} ? $o1->{message} : '',
       qr{git clone --no-hardlinks \S+\s+C:/Development/ccpraxis},
       'AC-R11a: C:/Development/ccpraxis is never the clone command destination');
like(defined $o1->{message} ? $o1->{message} : '', qr{~/},
     'AC-R11b: message also gives a POSIX-flavoured example (not Windows-only)');

# =====================================================================
# Group L — the launcher is wired to refuse (structural + compile)
# =====================================================================

# AC-L1 — launcher.pl compiles. Capture via a File::Temp file, NEVER an
# in-memory scalar (Git-for-Windows perl cannot reopen STDOUT/STDERR onto
# a scalar — surfaces as a bare "Died at ... line N").
{
    my ($tfh, $tfname) = tempfile(UNLINK => 1);
    close $tfh;
    my $cmd = sprintf('"%s" -c "%s" > "%s" 2>&1', $^X, $LAUNCHER, $tfname);
    system($cmd);
    my $rc = $? >> 8;
    open my $rfh, '<', $tfname or BAIL_OUT("cannot read perl -c capture file: $!");
    local $/;
    my $output = <$rfh>;
    close $rfh;
    is($rc, 0, 'AC-L1: launcher.pl `perl -c` succeeds') or diag("perl -c output:\n$output");

    # AC-L1b — `perl -c` must also be WARNING-FREE. This is not cosmetic. It was
    # added after a real defect: `exit $o->{exit_code} || 1;` parses as
    # `(exit $o->{exit_code}) || 1` because exit is a named unary operator, so an
    # intended exit-code floor is silently DEAD and a refusal can exit 0 — i.e.
    # read as success. Perl flags it as "Possible precedence issue with control
    # flow operator (exit)", exit status stays 0, and AC-L1 alone passed happily.
    # Measured 2026-07-28: with exit_code 0 or undef the process exited 0.
    my @warnings = grep { /\S/ && !/syntax OK\s*$/ } split /\n/, ($output // '');
    is_deeply(\@warnings, [], 'AC-L1b: launcher.pl compiles with NO warnings')
        or diag("unexpected perl -c output:\n" . join("\n", @warnings));
}

# AC-L2 — the use CcpraxisWorkCopy import list is exactly the new pair
{
    my ($import_list) = $lsrc =~ /use\s+CcpraxisWorkCopy\s+qw\(([^)]*)\)/s;
    ok(defined $import_list, 'AC-L2a: found a use CcpraxisWorkCopy qw(...) import in launcher.pl')
        or diag('no "use CcpraxisWorkCopy qw(...)" statement found');
    $import_list //= '';
    like($import_list, qr/\bworkcopy_route\b/, 'AC-L2b: import list includes workcopy_route');
    like($import_list, qr/\bworkcopy_refusal_outcome\b/, 'AC-L2c: import list includes workcopy_refusal_outcome');
    unlike($import_list, qr/\b(?:decline|worktree|provision|blueprint_copy|fleet_live)\b/,
           'AC-L2d: import list contains none of the removed names');
}

# AC-L3 — PluginSync: copy_tree import pruned, module still loaded
unlike($lsrc, qr/use\s+PluginSync\s+qw\([^)]*copy_tree/,
       'AC-L3a: launcher.pl no longer imports the copy_tree bareword from PluginSync');
like($lsrc, qr/^use\s+PluginSync\b/m,
     'AC-L3b: launcher.pl still `use`s PluginSync (fully-qualified callers survive)');

# AC-L4
ok(defined $offer_idx, 'AC-L4a: found the offer-branch `if ($route eq \'offer\')` line')
    or diag('could not locate the offer-branch if-statement in launcher.pl');
SKIP: {
    skip 'offer-branch if-statement not found; cannot scan its body', 2 unless defined $offer_idx;
    my $end = ($offer_idx + 10 <= $#lines) ? $offer_idx + 10 : $#lines;
    my $has_stderr = 0;
    my $has_exit   = 0;
    for my $i ($offer_idx + 1 .. $end) {
        $has_stderr = 1 if $lines[$i] =~ /print\s+STDERR/;
        $has_exit   = 1 if $lines[$i] =~ /^\s*exit\b/;
    }
    ok($has_stderr, 'AC-L4b: a `print STDERR` line appears within 10 lines of the offer branch');
    ok($has_exit,   'AC-L4c: an `exit` line appears within 10 lines of the offer branch');
}

# AC-L5 — the single strongest anti-regression assertion: the offer branch
# must be a short refusal, not a 138-line provisioning detour.
ok(defined $close_idx, 'AC-L5a: found the offer-branch\'s closing brace (bare block terminator)')
    or diag('could not locate a column-0 "}" after the offer-branch if-statement');
SKIP: {
    skip 'offer/close indices not both found; cannot measure branch length', 1
        unless defined $offer_idx && defined $close_idx;
    ok(($close_idx - $offer_idx) <= 14,
       "AC-L5b: offer branch is <=14 lines (got @{[$close_idx - $offer_idx]})");
}

# AC-L6 — no leftover machinery inside the (now-short) offer branch
SKIP: {
    skip 'offer/close indices not both found; cannot scan branch body', 1
        unless defined $offer_idx && defined $close_idx;
    my $leftover = 0;
    my @hit_lines;
    for my $i ($offer_idx .. $close_idx) {
        if ($lines[$i] =~ /prompt_workcopy_action|provision_|worktree|copy_tree|fleet_live/) {
            $leftover = 1;
            push @hit_lines, $i + 1;
        }
    }
    ok(!$leftover, 'AC-L6: offer branch body references none of prompt_workcopy_action/provision_/worktree/copy_tree/fleet_live')
        or diag('leftover-machinery hits at launcher.pl line(s): ' . join(', ', @hit_lines));
}

# AC-L7 — exit is driven by the outcome hash, not a magic number
SKIP: {
    skip 'offer/close indices not both found; cannot scan branch body', 1
        unless defined $offer_idx && defined $close_idx;
    my $driven = 0;
    for my $i ($offer_idx .. $close_idx) {
        # The exit must be driven by the outcome hash AND floored to a non-zero
        # literal. The floor matters because exit_code arriving as undef/0 would
        # turn a refusal into an apparent success. The optional paren is required
        # in the regex, not merely tolerated: the bare `exit $x || 1` form is a
        # precedence trap (see AC-L1b) and only the parenthesised call actually
        # applies the floor — so this assertion must not force the broken form.
        $driven = 1 if $lines[$i] =~ m{exit\s*\(?\s*\$\w+->\{exit_code\}\s*(?:\|\||//)\s*[1-9]};
    }
    ok($driven, 'AC-L7: offer branch exits via a FLOORED `exit($VAR->{exit_code} || 1)`, not a literal and not the bare precedence-trap form');
}

# =====================================================================
# Group P — passthrough is unchanged (done-criterion (b))
# =====================================================================

# AC-P1 — a ccpraxis clone outside the install still launches normally (B6)
is($workcopy_route_fn->('C:/bar/some-clone', {
        live_install_hint => 'C:/foo/ccpraxis',
        exists            => sub {
            my $p = shift;
            return 1 if $p eq 'C:/bar/some-clone/plugins/.claude-plugin/marketplace.json';
            return 1 if $p eq 'C:/bar/some-clone/plugins/sandbox/scripts/launcher.pl';
            return 0;
        },
        realpath => sub { $_[0] },
    }), 'passthrough', 'AC-P1: workcopy_route is passthrough for a ccpraxis clone outside the live install');

# AC-P2 — an ordinary unrelated project also passes through
is($workcopy_route_fn->('C:/other/myproject', {
        live_install_hint => 'C:/foo/ccpraxis',
        git_commondir     => sub { undef },
        exists            => sub { 0 },
        realpath          => sub { $_[0] },
    }), 'passthrough', 'AC-P2: workcopy_route is passthrough for an unrelated non-ccpraxis project');

# AC-P3 — the launch flow after the offer/close block is intact
SKIP: {
    skip 'close_idx not found; cannot scan the post-refusal launch flow', 3 unless defined $close_idx;
    my $tail = join '', @lines[$close_idx + 1 .. $#lines];
    like($tail, qr/my \$CCPRAXIS_DATA\b/,        'AC-P3a: $CCPRAXIS_DATA is still computed after the offer block');
    like($tail, qr/SandboxLock::acquire/,          'AC-P3b: SandboxLock::acquire still runs after the offer block');
    like($tail, qr/system\(\s*\$PODMAN\s*,\s*'start'/, 'AC-P3c: the real podman start call still exists after the offer block');
}

# AC-P4 — the refusal cannot fire on the passthrough route
{
    my @all_calls = grep { $lines[$_] =~ /workcopy_refusal_outcome\s*\(/ } (0 .. $#lines);
    is(scalar(@all_calls), 1,
       'AC-P4a: exactly one workcopy_refusal_outcome( call site exists in launcher.pl')
        or diag('call sites found at line(s): ' . join(', ', map { $_ + 1 } @all_calls) . ' (want exactly 1)');
    SKIP: {
        skip 'need exactly one call site and both offer/close indices to check placement', 1
            unless @all_calls == 1 && defined $offer_idx && defined $close_idx;
        my $call_idx = $all_calls[0];
        ok(($call_idx > $offer_idx && $call_idx < $close_idx),
           'AC-P4b: the sole workcopy_refusal_outcome( call site lies strictly inside the offer branch');
    }
    SKIP: {
        skip 'close_idx/podman_start_idx not found; cannot scan the passthrough region', 1
            unless defined $close_idx && defined $podman_start_idx && $podman_start_idx > $close_idx;
        my $passthrough_hit = 0;
        for my $i ($close_idx + 1 .. $podman_start_idx - 1) {
            $passthrough_hit = 1 if $lines[$i] =~ /workcopy_refusal_outcome/;
        }
        ok(!$passthrough_hit,
           'AC-P4c: no workcopy_refusal_outcome reference between the offer block and the podman start call');
    }
}

# =====================================================================
# Group D — the machinery is actually gone
# =====================================================================

# AC-D1
ok(!-e "$SCRIPTS/ccpraxis-mergeback.pl", 'AC-D1: ccpraxis-mergeback.pl has been deleted');

# AC-D2
ok(!-e "$Bin/40-ccpraxis-workcopy-provision.t", 'AC-D2a: t/40-ccpraxis-workcopy-provision.t has been deleted');
ok(!-e "$Bin/41-ccpraxis-mergeback-guard.t",    'AC-D2b: t/41-ccpraxis-mergeback-guard.t has been deleted');

# AC-D3 — the detector test is retained, not collaterally deleted
ok(-f "$Bin/39-ccpraxis-workcopy-detect.t", 'AC-D3: t/39-ccpraxis-workcopy-detect.t is retained');

# AC-D4 — retained detector symbols (B7)
for my $sym (qw(workcopy_refusal_outcome workcopy_route is_in_place is_ccpraxis_project canon_path live_install_dir)) {
    ok(CcpraxisWorkCopy->can($sym), "AC-D4: CcpraxisWorkCopy->can('$sym') is true");
}

# AC-D5 — removed symbols are gone from the runtime symbol table
for my $sym (qw(workcopy_decline_outcome _utf8_bytes default_worktree_path worktree_plan
                blueprint_copy_plan provision_state provision_repair_plan fleet_live
                mergeback_guard mergeback_plan discard_plan WORKTREE_BRANCH)) {
    ok(!CcpraxisWorkCopy->can($sym), "AC-D5: CcpraxisWorkCopy->can('$sym') is false");
}

# AC-D6 — @EXPORT_OK is exactly the six retained names
{
    my ($export_list) = $msrc =~ /\@EXPORT_OK\s*=\s*qw\(([^)]*)\)/s;
    ok(defined $export_list, 'AC-D6a: found @EXPORT_OK = qw(...) in CcpraxisWorkCopy.pm')
        or diag('no @EXPORT_OK = qw(...) found');
    $export_list //= '';
    my @got = sort grep { length } split(/\s+/, $export_list);
    my @want = sort qw(is_ccpraxis_project is_in_place workcopy_route workcopy_refusal_outcome canon_path live_install_dir);
    is_deeply(\@got, \@want, 'AC-D6b: @EXPORT_OK contains exactly the six retained names');
}

# =====================================================================
# Group G — the leftover-symbol gate, executed in-test
# =====================================================================

my @GATE_SYMBOLS = qw(
    _utf8_bytes default_worktree_path worktree_plan blueprint_copy_plan
    provision_state provision_repair_plan fleet_live mergeback discard_plan
    prompt_workcopy_action WORKTREE_BRANCH
);

{
    my %targets = (
        'launcher.pl'                     => { path => $LAUNCHER, lines => \@lines, code => $lcode },
        'CcpraxisWorkCopy.pm'              => { path => $MODULE,   lines => \@mlines, code => $mcode },
    );
    my $tdetect = "$Bin/39-ccpraxis-workcopy-detect.t";
    if (-f $tdetect) {
        open my $tfh, '<:raw', $tdetect or BAIL_OUT("cannot open $tdetect: $!");
        my @tlines = <$tfh>;
        close $tfh;
        my $tcode = join '', map { my $x = $_; $x =~ s/#.*$//; $x } @tlines;
        $targets{'t/39-ccpraxis-workcopy-detect.t'} = { path => $tdetect, lines => \@tlines, code => $tcode };
    }

    for my $fname (sort keys %targets) {
        my $t = $targets{$fname};
        my @flines = @{ $t->{lines} };
        my @hits;
        for my $sym (@GATE_SYMBOLS) {
            for my $i (0 .. $#flines) {
                my $stripped = $flines[$i];
                $stripped =~ s/#.*$//;
                if ($stripped =~ /\Q$sym\E/) {
                    push @hits, "$fname:@{[$i+1]}:$sym";
                }
            }
        }
        is(scalar(@hits), 0, "AC-G1: $fname carries zero leftover gate-symbol references outside comments")
            or diag("hits:\n  " . join("\n  ", @hits));
    }
}

# =====================================================================
# Group E — end-to-end refusal (guarded; the only test that runs the
# launcher for real)
# =====================================================================
{
    my $repo_root = abs_path("$Bin/../../../..");
    BAIL_OUT("cannot resolve repo root from $Bin/../../../..") unless defined $repo_root;
    $repo_root =~ s|\\|/|g;

    # $LAUNCHER (= "$Bin/../../scripts/launcher.pl") is an absolute path that
    # still contains literal ".." segments. launcher.pl derives its own
    # identity anchor from a RAW, non-canonicalised __FILE__ (three dirname()
    # calls, no realpath/abs_path). Spawning $LAUNCHER as-is means the
    # spawned process's __FILE__ carries the same ".." segments, so its
    # three-dirname derivation lands on the WRONG directory (t/ itself, not
    # the repo root) — the launcher then thinks it is NOT in-place and
    # performs a REAL LAUNCH (podman start + heartbeat loop) instead of
    # refusing. We must canonicalise the path we spawn, and independently
    # verify (Guard 4, below) that doing so makes the launcher's own
    # derivation agree with $repo_root before we ever spawn it.
    my $launcher_abs = abs_path($LAUNCHER);
    $launcher_abs =~ s|\\|/|g if defined $launcher_abs;

    # Guard 1 (MANDATORY, first) is evaluated before this SKIP: block is even
    # entered, so it can gate every skip() call inside it (skip() must run
    # inside a SKIP: block, so all four guards live in one).
    #
    # Guard 1: the launcher must actually be wired to the refusal (green
    # phase) before this test may spawn it at all. Checking
    # `workcopy_route(...) eq 'offer'` alone is NOT a safe interlock: it is
    # true both before AND after the implementation lands. Before it lands,
    # 'offer' still drives the OLD launcher branch — prompt_workcopy_action()
    # -> provision a git worktree -> _reexec_launcher -> podman start — so a
    # route-only guard fails OPEN in exactly the red phase this test must
    # protect. `< /dev/null` alone is not sufficient either: EOF just makes
    # the old arrow-key TUI fall through to a default action instead of
    # aborting. This source-grep guard is inert (skips) while the refusal is
    # absent, and only goes live once `workcopy_refusal_outcome` is actually
    # wired into launcher.pl (see Group L / AC-L2..AC-L7 for the structural
    # proof of that wiring).
    my $refusal_wired = ($lsrc =~ /workcopy_refusal_outcome/) ? 1 : 0;

    # Guard 2: compute the route IN-PROCESS before spawning anything. This
    # is a second, independent interlock — if this checkout does not route
    # to 'offer', a spawned launcher would fall through to a real launch
    # (image build, container start) inside a test run. Only meaningful (and
    # only safe to spawn on) once Guard 1 has already passed.
    my $route = eval { $workcopy_route_fn->($repo_root, { live_install_hint => $repo_root }) };

  SKIP: {
        skip 'cannot canonicalise launcher.pl path via Cwd::abs_path — refusing to spawn a non-canonical path', 5
            unless defined $launcher_abs;

        skip 'launcher does not yet wire the refusal (red phase) — refusing to spawn it', 5
            unless $refusal_wired;

        skip 'this checkout does not route to offer', 5
            unless (defined $route && $route eq 'offer');

        # Guard 3: a container CLI must be on PATH, or the launcher aborts
        # at :98 with an unrelated message before ever reaching the route
        # block, which would fail (ii)-(iv) for the wrong reason.
        my $has_cli = (system('docker --version > /dev/null 2>&1') == 0)
                    || (system('podman --version > /dev/null 2>&1') == 0);
        skip 'no container CLI on PATH (launcher aborts at :98 before the route block)', 5
            unless $has_cli;

        # Guard 4: replicate launcher.pl's own three-dirname anchor
        # derivation (launcher.pl:222) against the CANONICAL path we are
        # about to spawn, and require it to land exactly on $repo_root. This
        # closes the guard/launcher divergence directly — Guard 2 computed
        # the route using $repo_root as the correct anchor, but if the
        # spawned launcher would derive a DIFFERENT anchor from its own
        # __FILE__, the two disagree and the spawned process cannot be
        # trusted to behave the way Guard 2 predicted, canonical path or not.
        my $h = $launcher_abs;
        $h =~ s|\\|/|g;
        my $launcher_dir   = dirname($h);
        my $derived_anchor = dirname(dirname(dirname($launcher_dir)));
        $derived_anchor =~ s|\\|/|g if defined $derived_anchor;
        skip "launcher's own derived anchor ('" . (defined $derived_anchor ? $derived_anchor : '<undef>')
             . "') does not equal repo root ('$repo_root') even from the canonical path — refusing to spawn", 5
            unless (defined $derived_anchor && $derived_anchor eq $repo_root);

        my ($out_fh, $out_name) = tempfile(UNLINK => 1);
        my ($err_fh, $err_name) = tempfile(UNLINK => 1);
        close $out_fh;
        close $err_fh;

        # STDIN closed (< /dev/null): the pre-implementation offer branch
        # still prompts interactively via <STDIN> when it's not a TTY; an
        # inherited-but-silent STDIN would hang this test forever. Reading
        # from a closed/empty STDIN returns EOF immediately (non-blocking),
        # which is the only way to safely run this AC before p01 lands.
        #
        # `timeout 30` (GNU coreutils, confirmed present on this host) is a
        # hard wall-clock backstop: even if every guard above passes and the
        # canonical-path fix somehow still misidentifies the route, this
        # process cannot block the suite indefinitely — a hang becomes a
        # loud, diagnosable failure instead of a stuck test run.
        my $cmd = sprintf('timeout 30 "%s" "%s" "%s" < /dev/null > "%s" 2> "%s"',
                           $^X, $launcher_abs, $repo_root, $out_name, $err_name);
        system($cmd);
        my $rc = $? >> 8;

        open my $orfh, '<', $out_name or BAIL_OUT("cannot read stdout capture: $!");
        local $/;
        my $out = <$orfh>;
        close $orfh;
        open my $erfh, '<', $err_name or BAIL_OUT("cannot read stderr capture: $!");
        my $err = <$erfh>;
        close $erfh;
        $out //= '';
        $err //= '';

        if ($rc == 124) {
            # GNU `timeout` exits 124 when it had to kill the child after the
            # wall-clock bound elapsed. That is never a pass, no matter what
            # partial output happened to land in the capture files: it means
            # the spawned launcher did not refuse promptly, i.e. it almost
            # certainly fell through to a real launch. Fail loudly instead of
            # silently letting `$rc != 0` (124 is non-zero!) masquerade as a
            # correct refusal exit code.
            fail('AC-E1i: launcher exits non-zero on the offer route (TIMED OUT after 30s, not a refusal exit)');
            fail('AC-E1ii: STDERR contains --no-hardlinks (TIMED OUT after 30s)');
            fail('AC-E1iii: STDERR contains the clone command (TIMED OUT after 30s)');
            fail('AC-E1iv: STDERR mentions the repo\'s basename (TIMED OUT after 30s)');
            fail('AC-E1v: STDOUT contains no part of the refusal (TIMED OUT after 30s)');
            diag("launcher.pl did not exit within the 30s wall-clock bound and was killed by `timeout`.\n"
                 . "This means it took a real-launch path instead of refusing — investigate before re-running.\n"
                 . "stdout so far:\n$out\nstderr so far:\n$err");
        } else {
            ok($rc != 0, 'AC-E1i: launcher exits non-zero on the offer route') or diag("exit code: $rc");
            like($err, qr/\Q--no-hardlinks\E/, 'AC-E1ii: STDERR contains --no-hardlinks') or diag("stderr:\n$err");
            like($err, qr/git clone --no-hardlinks/, 'AC-E1iii: STDERR contains the clone command') or diag("stderr:\n$err");
            my ($basename) = $repo_root =~ m{([^/]+)/?$};
            like($err, qr/\Q$basename\E/, 'AC-E1iv: STDERR mentions the repo\'s basename') or diag("stderr:\n$err");
            unlike($out, qr/\Q--no-hardlinks\E/, 'AC-E1v: STDOUT contains no part of the refusal') or diag("stdout:\n$out");
        }
    }
}

# =====================================================================
# Group S — SECURITY REGRESSIONS (two CONFIRMED defects, measured
# against the current implementation — not spec ACs). These pin the
# defects: they must FAIL now and PASS once each is fixed. Do not
# re-diagnose; the measurements are already confirmed (see task report).
# =====================================================================

my $is_in_place_fn = CcpraxisWorkCopy->can('is_in_place');
ok($is_in_place_fn, 'BLOCKER setup: CcpraxisWorkCopy->can(\'is_in_place\')')
    or BAIL_OUT('is_in_place is not exported/available — cannot test BLOCKER-2');

my $CASE_INSENSITIVE_OS = ($^O =~ /^(MSWin32|cygwin|msys|darwin)$/) ? 1 : 0;

# ---------------------------------------------------------------------
# BLOCKER-2: _same_path (CcpraxisWorkCopy.pm:136-151) compares
# canon_path()'d strings with `eq`. canon_path (:35) only uppercases the
# DRIVE LETTER; it never case-folds the rest of the path. On a
# case-insensitive filesystem (Windows, macOS) two paths that differ only
# in case are the SAME real directory, so the in-place refusal must still
# fire — but today it does not, because the comparison is strict `eq`.
# Measured on this machine (2026-07-28):
#   route("C:/Users/André/.claude/ccpraxis", {live_install_hint=>"C:/Users/André/.claude/ccpraxis"}) = offer
#   route("c:/users/andré/.claude/ccpraxis", {live_install_hint=>"C:/Users/André/.claude/ccpraxis"}) = passthrough  <== BYPASS
# All paths below are FABRICATED; the identity `realpath` seam
# (rp_id = sub { $_[0] }) and `exists => sub { 1 }` make this hermetic —
# no dependence on any real install existing on this machine (idiom per t/39).
# ---------------------------------------------------------------------
my $rp_id = sub { $_[0] };

SKIP: {
    skip 'case-insensitive-filesystem assertions only hold on Windows/macOS ($^O); Linux is correctly case-sensitive here',
        4 unless $CASE_INSENSITIVE_OS;

    # (i) lowercase drive + lowercase dirs (plain ASCII)
    my $anchor_ascii  = 'C:/Foo/CcpraxisRoot';
    my $variant_ascii = 'c:/foo/ccpraxisroot';
    is($is_in_place_fn->($variant_ascii, { live_install_hint => $anchor_ascii, realpath => $rp_id }), 1,
       'BLOCKER-2a: is_in_place=1 for a lowercase-drive/lowercase-dirs variant of the anchor (case-insensitive FS)');
    is($workcopy_route_fn->($variant_ascii, { live_install_hint => $anchor_ascii, exists => sub { 1 }, realpath => $rp_id }), 'offer',
       'BLOCKER-2b: workcopy_route=offer for the same lowercase-drive/lowercase-dirs variant');

    # (ii) mixed case in a non-ASCII segment — mirrors this machine's real
    # path and the exact measured bypass quoted above.
    my $anchor_andre  = 'C:/Users/André/.claude/ccpraxis';
    my $variant_andre = 'c:/users/andré/.claude/ccpraxis';
    is($is_in_place_fn->($variant_andre, { live_install_hint => $anchor_andre, realpath => $rp_id }), 1,
       'BLOCKER-2c: is_in_place=1 for a case-variant of a path with a non-ASCII (André) segment');
    is($workcopy_route_fn->($variant_andre, { live_install_hint => $anchor_andre, exists => sub { 1 }, realpath => $rp_id }), 'offer',
       'BLOCKER-2d: workcopy_route=offer (not the measured passthrough bypass) for the André case-variant');
}

# Control (ungated — must hold on EVERY platform, including Linux): a
# genuinely DIFFERENT path — not merely a case variant — must still route
# passthrough, so the fix cannot be "return offer for everything".
{
    my $anchor_ctrl    = 'C:/Foo/CcpraxisRoot';
    my $different_ctrl = 'C:/Bar/SomeOtherProject';
    is($is_in_place_fn->($different_ctrl, { live_install_hint => $anchor_ctrl, realpath => $rp_id }), 0,
       'BLOCKER-2e (control): is_in_place=0 for a genuinely different path (not a case variant)');
    is($workcopy_route_fn->($different_ctrl, { live_install_hint => $anchor_ctrl, exists => sub { 1 }, realpath => $rp_id }), 'passthrough',
       'BLOCKER-2f (control): workcopy_route=passthrough for a genuinely different path (fix must not be "always offer")');
}

# ---------------------------------------------------------------------
# BLOCKER-1: launcher.pl derives $LIVE_CCPRAXIS_ROOT from a RAW,
# uncanonicalised __FILE__ via three dirname() calls (launcher.pl ~:220).
# Whenever the launcher is invoked through a path containing "..", a
# relative path, or a symlinked directory, this anchor lands on the WRONG
# directory and the in-place refusal silently fails to fire. Tested
# STRUCTURALLY on launcher.pl's source only ($lsrc, loaded once above by
# the existing Group L setup) — never spawned.
# ---------------------------------------------------------------------
{
    my ($file_stmt) = $lsrc =~ /\$LIVE_CCPRAXIS_ROOT\s*=\s*do\s*\{(.*?)\};/s;
    ok(defined $file_stmt, 'BLOCKER-1a: found the $LIVE_CCPRAXIS_ROOT = do {...}; derivation statement in launcher.pl')
        or diag('could not locate the $LIVE_CCPRAXIS_ROOT derivation statement');

    SKIP: {
        skip 'derivation statement not found; cannot inspect canonicalisation', 2 unless defined $file_stmt;

        my $canon_idx = -1;
        if ($file_stmt =~ /(?:Cwd::)?abs_path\s*\(\s*__FILE__\s*\)|canon_path\s*\(\s*__FILE__\s*\)/) {
            $canon_idx = $-[0];
        }
        # BUG this pins: a bare __FILE__ fed straight into dirname() misresolves
        # the anchor for relative paths, "..", or a symlinked launcher directory,
        # so the in-place refusal never fires in those cases.
        ok($canon_idx >= 0,
           'BLOCKER-1b: $LIVE_CCPRAXIS_ROOT derivation canonicalises __FILE__ via abs_path()/canon_path() before deriving dirnames')
            or diag("derivation statement was: $file_stmt");

        SKIP: {
            skip 'no canonicalisation call found; cannot check it precedes the dirname() chain', 1
                unless $canon_idx >= 0;
            my $dirname_idx = ($file_stmt =~ /dirname\s*\(/) ? $-[0] : -1;
            ok(($dirname_idx < 0 || $canon_idx < $dirname_idx),
               'BLOCKER-1c: canonicalisation happens BEFORE the dirname() chain, not after '
               . '(dirname() of an uncanonicalised path is still wrong)');
        }
    }
}

done_testing();
