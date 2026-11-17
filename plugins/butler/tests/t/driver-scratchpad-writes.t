#!/usr/bin/env perl
# platform: any
# Oracle for package 31-driver-scratchpad-writes (blueprint hook-continuity-remake),
# specs/31-driver-scratchpad-writes-spec.md AC-1..AC-15 (AC-16 is the regression run,
# executed separately by the validator, not from this file).
#
# WRITTEN BLIND TO THE IMPLEMENTATION: BpHook::WriteGuards.pm is in this package's
# write set, so this file is derived only from the spec text above and from the
# already-shipped BpHook.pm / GuardHarness.pm interfaces it documents as reused
# (mirrored from guards-per-subagent.t's own conventions), never from reading
# WriteGuards.pm's current source. `_own_scratchpad` does not exist yet at the
# time this file is written, so every "allowed" assertion below is expected to
# fail (rc 2 instead of rc 0) until the implementer adds it -- legibly, never a
# crash in this file.
#
# Fixture strings only (spec sec 3): Z:\fx31\... and Z:/fx31/... paths. Nothing
# under the real %TEMP%, the real scratchpad, or the real ~/.claude is ever
# read, written, or named. R/D (the project root and data dir) are real
# directories under this test file's own hermetic scratch root -- never under
# the fictitious Z:\fx31\... tree, so rule 4 (never inside root/data) always
# holds honestly.
#
# Runs standalone: perl this file
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Path qw(make_path remove_tree);
use JSON::PP ();
use Cwd ();

BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }

use lib dirname(__FILE__) . '/../lib';
use GuardHarness;

delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
$ENV{CCPRAXIS_NO_WAKELOCK} = 1;

my $J = JSON::PP->new->utf8->canonical;

# =============================================================================
# Hermetic scratch root: under THIS FILE's own directory, never /tmp, never the
# real %TEMP% (spec sec 4's fixture rule; same technique as
# guards-per-subagent.t). Only R/D live here; the scratchpad/transcript fixture
# strings below are fictitious and never touch disk.
# =============================================================================
(my $TEST_DIR = Cwd::abs_path(dirname(__FILE__))) =~ s{\\}{/}g;
my $SCRATCH_ROOT = "$TEST_DIR/.scratch-driver-scratchpad-writes-$$";
make_path($SCRATCH_ROOT);
my $SCRATCH_SEQ = 0;
END { remove_tree($SCRATCH_ROOT, { safe => 1 }) if defined $SCRATCH_ROOT && -d $SCRATCH_ROOT }

sub scratch_dir {
    my ($name) = @_;
    $name = defined($name) ? $name : 'x';
    my $d = "$SCRATCH_ROOT/" . $name . '-' . (++$SCRATCH_SEQ);
    make_path($d);
    return $d;
}

sub write_bytes {
    my ($path, $bytes) = @_;
    (my $dir = $path) =~ s{[/\\][^/\\]*\z}{};
    make_path($dir) if length($dir) && !-d $dir;
    open(my $fh, '>:raw', $path) or die "cannot write $path: $!";
    print {$fh} $bytes;
    close $fh;
}
sub write_json { my ($path, $data) = @_; write_bytes($path, $J->encode($data) . "\n") }

sub ledger_body {
    my (%o) = @_;
    my $pkg    = $o{package};
    my $bp     = $o{blueprint} // 'bpx';
    my $status = $o{status} // 'running';
    my $ws     = $o{write_set} // '';
    my $tp     = $o{test_paths} // '';
    my $lu     = $o{last_updated} // '2025-01-01T00:00:00Z';
    return "---\npackage: $pkg\nblueprint: $bp\nstatus: $status\n"
         . "write_set: $ws\ntest_paths: $tp\nlast_updated: $lu\n---\n\n"
         . "## Next action\n\nkeep going\n\n"
         . "## Decisions & attempt log\n\n- note\n\n"
         . "## Pipeline\n\n- [x] 1\n\n"
         . "## Outputs\n\nnone\n\n"
         . "## Escalation\n\nnone\n";
}
sub write_ledger {
    my ($d, %o) = @_;
    my $bp  = $o{blueprint} // 'bpx';
    my $pkg = $o{package};
    write_bytes("$d/blueprints/$bp/packages/$pkg.md", ledger_body(%o));
}

# =============================================================================
# Fixture constants (spec sec 3, verbatim). SID has no letters, so the "SID
# upper-cased" clause of B5 is a no-op for it -- the case-fold coverage for B5
# instead comes from varying "claude"/SLUG/"scratchpad".
# =============================================================================
my $SID  = '11111111-2222-4333-8444-555555555555';
my $OSID = '99999999-8888-4777-8666-555555555555';
my $SLUG = 'Z--fx31-proj';

# LA: UTF-8 BYTES (as %ENV actually carries it) -- two Latin-1 bytes 0xC3 0xA9
# forming the UTF-8 encoding of U+00E9, never a single wide character.
my $LA  = "Z:/fx31/Users/Andr\xC3\xA9/AppData/Local";
# TP/SP L: CHARACTER form (as JSON delivers a decoded string) -- one character
# U+00E9, which _to_bytes must turn into the same two bytes as $LA carries.
my $TP  = "Z:\\fx31\\Users\\Andr\xe9\\.claude\\projects\\$SLUG\\$SID.jsonl";
my $SP8 = "Z:\\fx31\\Users\\ANDR~1\\AppData\\Local\\Temp\\claude\\$SLUG\\$SID\\scratchpad";
my $SPL = "Z:/fx31/Users/Andr\xe9/AppData/Local/Temp/claude/$SLUG/$SID/scratchpad";

# =============================================================================
# fixture(%o) -- R/D real on disk (hermetic scratch), .drive-solo/inflight.json
# with $o{members} packages (0, 1 or 2), SID armed as driver. Mirrors
# guards-per-subagent.t's fixture() shape.
# =============================================================================
sub fixture {
    my (%o) = @_;
    my $members = $o{members} // 2;
    my $R = $o{base} // scratch_dir('proj31');
    my $D = "$R/.ccpraxis-local-data";
    make_path("$D/blueprints/bpx/packages");
    write_ledger($D, package => 'p1-a', write_set => 'src/a/:docs/a.md', test_paths => 't/a/');
    write_ledger($D, package => 'p2-b', write_set => 'src/b/',           test_paths => 't/b/');

    my @all_members = ({ blueprint => 'bpx', package => 'p1-a' }, { blueprint => 'bpx', package => 'p2-b' });
    my @use = ($members == 0) ? () : ($members == 1) ? ($all_members[0]) : @all_members;
    make_path("$D/.drive-solo");
    write_json("$D/.drive-solo/inflight.json", { packages => [ map { { %$_, ledger => 'ignored', since => 1 } } @use ], updated_at => 1 });

    GuardHarness::fresh_state();
    GuardHarness::arm($SID, 'driver');

    # Same SLUG as the driver's own transcript_path (TP), so AC-9's subagent
    # fixture is refused by the driver-mode gate ALONE, never by a slug/tail
    # mismatch it would otherwise fail on first (review 31-review.md M1).
    my $X = "$R-transcripts/$SLUG";
    make_path("$X/$SID/subagents");
    write_json("$X/$SID/subagents/agent-aaaa1.meta.json", { toolUseId => 'toolu_A' });
    make_path("$D/.drive-solo/bindings");
    write_json("$D/.drive-solo/bindings/toolu_A.json", { blueprint => 'bpx', package => 'p1-a' });

    return { R => $R, D => $D, X => $X };
}

sub shape_a_transcript { my ($fx) = @_; return "$fx->{X}/$SID.jsonl" }

# ---------------------------------------------------------------------------
# payload builders
# ---------------------------------------------------------------------------
sub driver_payload {
    my (%o) = @_;
    my $p = {
        hook_event_name => ($o{event} // 'PreToolUse'),
        tool_name       => ($o{tool_name} // 'Write'),
        tool_input      => {},
    };
    $p->{session_id}      = $o{session_id}      if exists $o{session_id};
    $p->{cwd}             = $o{cwd}             if exists $o{cwd};
    $p->{transcript_path} = $o{transcript_path} if exists $o{transcript_path};
    for my $k (qw(file_path notebook_path content old_string new_string edits replace_all)) {
        $p->{tool_input}{$k} = $o{$k} if exists $o{$k};
    }
    return $p;
}
sub subagent_payload {
    my (%o) = @_;
    my $p = driver_payload(%o);
    $p->{agent_id}   = $o{agent_id}   if exists $o{agent_id};
    $p->{agent_type} = $o{agent_type} if exists $o{agent_type};
    $p->{agent_type} //= 'general-purpose' unless exists $o{agent_type};
    return $p;
}

# every driver-path case here uses this SID + TP unless the case is explicitly
# varying one of them (AC-11).
sub own_driver {
    my (%o) = @_;
    return driver_payload(session_id => $SID, transcript_path => $TP, %o);
}

# ---------------------------------------------------------------------------
# env builder -- every call sets CCPRAXIS_DATA_DIR and explicitly
# deletes TMPDIR/TEMP/TMP, sets or deletes LOCALAPPDATA (spec sec 4).
# ---------------------------------------------------------------------------
sub env_for {
    my ($D, %extra) = @_;
    return {
        CCPRAXIS_DATA_DIR  => $D,
        TMPDIR             => undef,
        TEMP               => undef,
        TMP                => undef,
        LOCALAPPDATA       => $LA,
        BP_PROJECT_ROOT    => undef,
        CLAUDE_PROJECT_DIR => undef,
        %extra,
    };
}

sub wg_writes { my ($p, %o) = @_; return GuardHarness::run_module('WriteGuards', $p, env => ($o{env} // {}), args => ['writes']) }
sub wg_ledger { my ($p, %o) = @_; return GuardHarness::run_module('WriteGuards', $p, env => ($o{env} // {}), args => ['ledger']) }

# =============================================================================
# Spec sec 3: "$BpHook::WriteGuards::CASE_INSENSITIVE = 1 unless stated" -- so
# every case below runs with it set to 1, EXCEPT AC-13's B19 sub-block, which
# sets it to 0 via its own nested `local`. `local` is dynamically scoped: this
# statement sits at the file's own top level (not inside a trailing-brace
# block of its own), so it stays in effect across every subsequent AC-N block
# for the rest of the file; B19's inner `local = 0` shadows it only for that
# block's duration and then reverts here (review 31-review.md M2). Without
# this, AC-1..AC-5 depend on the host's default (_is_ci() true only on
# msys/MSWin32) even though the file is tagged `platform: any`.
# =============================================================================
no warnings 'once';
local $BpHook::WriteGuards::CASE_INSENSITIVE = 1;

# =============================================================================
# AC-1 (B1): driver Write to SP8\p22-commit.txt, two in flight: allowed.
# =============================================================================
{
    my $fx = fixture(members => 2);
    my $p = own_driver(cwd => $fx->{R}, file_path => "$SP8\\p22-commit.txt");
    my $r = wg_writes($p, env => env_for($fx->{D}));
    is($r->{rc}, 0, 'AC-1: driver Write under its own scratchpad gives rc 0');
    is($r->{err}, '', 'AC-1: rc0 case has empty stderr');
}

# =============================================================================
# AC-2 (B2): Edit and MultiEdit to the same path: allowed.
# =============================================================================
{
    my $fx = fixture(members => 2);
    my $fp = "$SP8\\p22-commit.txt";
    my $edit = own_driver(cwd => $fx->{R}, tool_name => 'Edit', file_path => $fp,
        old_string => 'a', new_string => 'b');
    is(wg_writes($edit, env => env_for($fx->{D}))->{rc}, 0, 'AC-2: driver Edit under its own scratchpad gives rc 0');

    my $multi = own_driver(cwd => $fx->{R}, tool_name => 'MultiEdit', file_path => $fp,
        edits => [ { old_string => 'a', new_string => 'b' } ]);
    is(wg_writes($multi, env => env_for($fx->{D}))->{rc}, 0, 'AC-2: driver MultiEdit under its own scratchpad gives rc 0');
}

# =============================================================================
# AC-3 (B3, B4): nested path allowed; single-in-flight allowed.
# =============================================================================
{
    my $fx = fixture(members => 2);
    my $r = wg_writes(own_driver(cwd => $fx->{R}, file_path => "$SP8\\a\\b\\c.txt"), env => env_for($fx->{D}));
    is($r->{rc}, 0, 'AC-3(B3): nested path under the scratchpad gives rc 0');

    my $fx1 = fixture(members => 1);
    my $r4 = wg_writes(own_driver(cwd => $fx1->{R}, file_path => "$SP8\\x.txt"), env => env_for($fx1->{D}));
    is($r4->{rc}, 0, 'AC-3(B4): single package in flight, scratchpad write gives rc 0');
}

# =============================================================================
# AC-4 (B5): case variant of claude/SLUG/scratchpad is allowed under folding.
# =============================================================================
{
    my $fx = fixture(members => 2);
    my $case_variant = "Z:\\fx31\\Users\\ANDR~1\\AppData\\Local\\Temp\\CLAUDE\\" . uc($SLUG) . "\\$SID\\SCRATCHPAD\\x.txt";
    my $r = wg_writes(own_driver(cwd => $fx->{R}, file_path => $case_variant), env => env_for($fx->{D}));
    is($r->{rc}, 0, 'AC-4(B5): case-folded scratchpad path gives rc 0 with CASE_INSENSITIVE=1');
}

# =============================================================================
# AC-5 (B6, B7): long form allowed (Decision 68); MSYS form allowed.
# =============================================================================
{
    my $fx = fixture(members => 2);
    my $r6 = wg_writes(own_driver(cwd => $fx->{R}, file_path => "$SPL/x.txt"), env => env_for($fx->{D}));
    is($r6->{rc}, 0, 'AC-5(B6): long-form scratchpad write gives rc 0');

    my $msys = "/z/fx31/Users/ANDR~1/AppData/Local/Temp/claude/$SLUG/$SID/scratchpad/x.txt";
    my $r7 = wg_writes(own_driver(cwd => $fx->{R}, file_path => $msys), env => env_for($fx->{D}));
    is($r7->{rc}, 0, 'AC-5(B7): MSYS-form scratchpad write gives rc 0');
}

# =============================================================================
# AC-6 (B8): another session's scratchpad (same SLUG, OSID) is refused.
# =============================================================================
{
    my $fx = fixture(members => 2);
    my $other = "Z:\\fx31\\Users\\ANDR~1\\AppData\\Local\\Temp\\claude\\$SLUG\\$OSID\\scratchpad\\x.txt";
    my $r = wg_writes(own_driver(cwd => $fx->{R}, file_path => $other), env => env_for($fx->{D}));
    is($r->{rc}, 2, 'AC-6(B8): another session\'s scratchpad gives rc 2');
    like($r->{err}, qr/outside the project root/, 'AC-6(B8): deny mentions "outside the project root"');
}

# =============================================================================
# AC-7 (B9, B10, B11): traversals out of the own scratchpad are each refused.
# =============================================================================
{
    my $fx = fixture(members => 2);
    my $b9  = "$SP8\\..\\..\\$OSID\\scratchpad\\x.txt";
    my $b10 = "$SP8\\..\\x.txt";
    my $b11 = "$SP8\\..\\..\\..\\..\\x.txt";
    for my $case ([ 'B9', $b9 ], [ 'B10', $b10 ], [ 'B11', $b11 ]) {
        my ($label, $fp) = @$case;
        my $r = wg_writes(own_driver(cwd => $fx->{R}, file_path => $fp), env => env_for($fx->{D}));
        is($r->{rc}, 2, "AC-7($label): traversal outside the own scratchpad gives rc 2");
    }
}

# =============================================================================
# AC-8 (B12): the scratchpad directory itself (no filename below it) refused.
# =============================================================================
{
    my $fx = fixture(members => 2);
    my $r = wg_writes(own_driver(cwd => $fx->{R}, file_path => $SP8), env => env_for($fx->{D}));
    is($r->{rc}, 2, 'AC-8(B12): target is the scratchpad dir itself, gives rc 2');
}

# =============================================================================
# AC-9 (B13, B14): a bound subagent and a sole unbound subagent, both writing
# into the (same-session) scratchpad, are refused -- the allowance is
# driver-only.
# =============================================================================
{
    my $fx = fixture(members => 2);
    my $bound = subagent_payload(agent_id => 'aaaa1', session_id => $SID,
        transcript_path => shape_a_transcript($fx), cwd => $fx->{R}, file_path => "$SP8\\x.txt");
    my $r13 = wg_writes($bound, env => env_for($fx->{D}));
    is($r13->{rc}, 2, 'AC-9(B13): bound subagent writing the scratchpad gives rc 2');

    my $fx1 = fixture(members => 1);
    my $unres = subagent_payload(agent_id => 'ccc09', session_id => $SID,
        transcript_path => shape_a_transcript($fx1), cwd => $fx1->{R}, file_path => "$SP8\\x.txt");
    my $r14 = wg_writes($unres, env => env_for($fx1->{D}));
    is($r14->{rc}, 2, 'AC-9(B14): sole unbound subagent writing the scratchpad gives rc 2');
}

# =============================================================================
# AC-10 (B15): coordinator path, writing the scratchpad, refused (unchanged).
# =============================================================================
{
    my $R = scratch_dir('coord-proj31');
    make_path("$R/.ccpraxis-local-data/blueprints/bpx/packages");
    my $BP_DIR = "$R/.ccpraxis-local-data/blueprints/bpx";
    make_path("$BP_DIR/runs");
    my %coord_env = (
        CCPRAXIS_DATA_DIR  => undef,
        TMPDIR => undef, TEMP => undef, TMP => undef, LOCALAPPDATA => $LA,
        BP_LEDGER       => "$BP_DIR/packages/p1-a.md",
        BP_DIR          => $BP_DIR,
        BP_PROJECT_ROOT => $R,
        CLAUDE_PROJECT_DIR => $R,
        BP_PACKAGE      => 'p1-a',
        BP_WRITE_SET    => 'src/:docs/api.md',
        BP_TEST_PATHS   => 't/',
    );
    my $p = own_driver(cwd => $R, file_path => "$SP8\\x.txt");
    my $r = wg_writes($p, env => \%coord_env);
    is($r->{rc}, 2, 'AC-10(B15): coordinator writing the scratchpad gives rc 2 (unchanged)');
}

# =============================================================================
# AC-11 (B16): each of three malformed/mismatched transcript_path variants
# leaves the allowance off -- refused.
# =============================================================================
{
    my $fx = fixture(members => 2);
    my %variants = (
        absent          => driver_payload(session_id => $SID, cwd => $fx->{R}, file_path => "$SP8\\x.txt"),
        other_basename  => driver_payload(session_id => $SID, cwd => $fx->{R}, file_path => "$SP8\\x.txt",
            transcript_path => "Z:\\fx31\\Users\\Andr\xe9\\.claude\\projects\\$SLUG\\$OSID.jsonl"),
        other_slug_dir  => driver_payload(session_id => $SID, cwd => $fx->{R}, file_path => "$SP8\\x.txt",
            transcript_path => "Z:\\fx31\\Users\\Andr\xe9\\.claude\\projects\\Z--other-proj\\$SID.jsonl"),
    );
    for my $label (sort keys %variants) {
        my $r = wg_writes($variants{$label}, env => env_for($fx->{D}));
        is($r->{rc}, 2, "AC-11(B16, $label): mismatched/absent transcript_path gives rc 2");
    }
}

# =============================================================================
# AC-12 (B17): both base mismatches (wrong 8.3 profile stem, no matching temp
# candidate) are refused.
# =============================================================================
{
    my $fx = fixture(members => 2);
    my $bad_profile = "Z:\\fx31\\Users\\BOB~1\\AppData\\Local\\Temp\\claude\\$SLUG\\$SID\\scratchpad\\x.txt";
    my $r1 = wg_writes(own_driver(cwd => $fx->{R}, file_path => $bad_profile), env => env_for($fx->{D}));
    is($r1->{rc}, 2, 'AC-12(B17, profile mismatch): rc 2');

    my $bad_base = "Z:\\elsewhere\\claude\\$SLUG\\$SID\\scratchpad\\x.txt";
    my $r2 = wg_writes(own_driver(cwd => $fx->{R}, file_path => $bad_base), env => env_for($fx->{D}));
    is($r2->{rc}, 2, 'AC-12(B17, no temp candidate): rc 2');
}

# =============================================================================
# AC-13 (B18, B19): no temp vars at all refused; CASE_INSENSITIVE=0 refuses
# SP8 (8.3 form) but still allows SPL (long form).
# =============================================================================
{
    my $fx = fixture(members => 2);
    my $r18 = wg_writes(own_driver(cwd => $fx->{R}, file_path => "$SP8\\x.txt"),
        env => env_for($fx->{D}, LOCALAPPDATA => undef));
    is($r18->{rc}, 2, 'AC-13(B18): no LOCALAPPDATA/TEMP/TMP/TMPDIR gives rc 2');

    {
        no warnings 'once';
        local $BpHook::WriteGuards::CASE_INSENSITIVE = 0;
        my $r19a = wg_writes(own_driver(cwd => $fx->{R}, file_path => "$SP8\\x.txt"), env => env_for($fx->{D}));
        is($r19a->{rc}, 2, 'AC-13(B19): CASE_INSENSITIVE=0, 8.3-form scratchpad write gives rc 2');
        my $r19b = wg_writes(own_driver(cwd => $fx->{R}, file_path => "$SPL/x.txt"), env => env_for($fx->{D}));
        is($r19b->{rc}, 0, 'AC-13(B19): CASE_INSENSITIVE=0, long-form scratchpad write still gives rc 0');
    }
}

# =============================================================================
# S2 (review 31-review.md): the tail (claude/SLUG/SID/scratchpad) is spec sec
# 2.1 point 5's "never 8.3-tolerant" segments, and the 8.3 stem tolerance of
# sec 2.2 is bounded to (up to) the first six folded characters of the long
# segment. None of AC-1..AC-14 exercises a wrong final segment, or a stem that
# is a substring but not a prefix, or a short stem that is a genuine prefix
# too short to be the real 8.3 basis -- each refused.
# =============================================================================
{
    my $fx = fixture(members => 2);

    # Wrong final segment, not "scratchpad": exact-match only, no 8.3
    # tolerance applies to the tail even when the wrong segment is itself
    # shaped like a short name. Two different wrong short names, so a fix
    # that special-cased one literal string would still be caught.
    for my $case ([ 'SCRAT~1', "Z:\\fx31\\Users\\ANDR~1\\AppData\\Local\\Temp\\claude\\$SLUG\\$SID\\SCRAT~1\\x.txt" ],
                  [ 'SCRPAD~1', "Z:\\fx31\\Users\\ANDR~1\\AppData\\Local\\Temp\\claude\\$SLUG\\$SID\\SCRPAD~1\\x.txt" ]) {
        my ($label, $fp) = @$case;
        my $r = wg_writes(own_driver(cwd => $fx->{R}, file_path => $fp), env => env_for($fx->{D}));
        is($r->{rc}, 2, "S2(tail, $label): wrong final segment (not scratchpad) gives rc 2");
    }

    # Stem occurs mid-name, not as a prefix: "PDATA~1" is a substring of
    # "AppData" starting at index 2, never at index 0.
    my $mid = "Z:\\fx31\\Users\\ANDR~1\\PDATA~1\\Local\\Temp\\claude\\$SLUG\\$SID\\scratchpad\\x.txt";
    my $rmid = wg_writes(own_driver(cwd => $fx->{R}, file_path => $mid), env => env_for($fx->{D}));
    is($rmid->{rc}, 2, 'S2(stem mid-name): "PDATA~1" against "AppData" gives rc 2');

    # Stem is a genuine prefix, but shorter than the up-to-6-char 8.3 basis:
    # "A~1" against "AppData" (basis "appdat"), "U~1" against "Users" (basis
    # "users", already <6 chars so the full basis is required).
    my $short_a = "Z:\\fx31\\Users\\ANDR~1\\A~1\\Local\\Temp\\claude\\$SLUG\\$SID\\scratchpad\\x.txt";
    my $rshort_a = wg_writes(own_driver(cwd => $fx->{R}, file_path => $short_a), env => env_for($fx->{D}));
    is($rshort_a->{rc}, 2, 'S2(stem too short): "A~1" against "AppData" gives rc 2');

    my $short_u = "Z:\\fx31\\U~1\\ANDR~1\\AppData\\Local\\Temp\\claude\\$SLUG\\$SID\\scratchpad\\x.txt";
    my $rshort_u = wg_writes(own_driver(cwd => $fx->{R}, file_path => $short_u), env => env_for($fx->{D}));
    is($rshort_u->{rc}, 2, 'S2(stem too short): "U~1" against "Users" gives rc 2');
}

# =============================================================================
# AC-14 (B20): a look-alike scratchpad path that lands INSIDE the project root
# is never granted by this allowance -- refused as outside every in-flight
# package's write set (2 members, so T5's union phrasing applies).
# =============================================================================
{
    my $fx = fixture(members => 2);
    my $la_inside = "$fx->{R}/la";
    my $target = "$fx->{R}/la/Temp/claude/$SLUG/$SID/scratchpad/x.txt";
    my $r = wg_writes(own_driver(cwd => $fx->{R}, file_path => $target),
        env => env_for($fx->{D}, LOCALAPPDATA => $la_inside));
    is($r->{rc}, 2, 'AC-14(B20): inside-root look-alike scratchpad path gives rc 2');
    like($r->{err}, qr/outside the write set of every package in flight/,
        'AC-14(B20): deny uses the union phrase "outside the write set of every package in flight"');
}

# =============================================================================
# AC-15 (B21, B22): no package in flight -- allowed (unchanged); ledger mode
# -- rc 0 (unchanged).
# =============================================================================
{
    my $fx0 = fixture(members => 0);
    my $r21 = wg_writes(own_driver(cwd => $fx0->{R}, file_path => "$SP8\\x.txt"), env => env_for($fx0->{D}));
    is($r21->{rc}, 0, 'AC-15(B21): no package in flight, scratchpad write gives rc 0 (unchanged)');

    my $fx = fixture(members => 2);
    my $ledger_payload = own_driver(cwd => $fx->{R}, tool_name => 'Write',
        file_path => "$SP8\\x.txt", content => 'irrelevant content');
    my $r22 = wg_ledger($ledger_payload, env => env_for($fx->{D}));
    is($r22->{rc}, 0, 'AC-15(B22): ledger mode on a scratchpad path gives rc 0 (unchanged)');
}

# =============================================================================
# AC-16 (macOS port): the POSIX shape of the same allowance. macOS sets TMPDIR to
# /var/folders/.../T, but Claude Code hands out its temp root -- scratchpad
# included -- as /private/tmp/claude-<uid>/<slug>/<sid>/scratchpad, and /tmp is
# the same directory through a symlink. Neither spelling started with "/tmp/"
# AND sat under TMPDIR, so the driver's writes to its own scratchpad were
# denied there. Non-Windows only: on a Windows-family perl the scratchpad is
# under %TEMP%\claude (AC-1..AC-15). Fixture strings only, never touched.
# =============================================================================
SKIP: {
    skip 'AC-16: the /private/tmp/claude-<uid> shape is a non-Windows concern', 9
        if $^O =~ /\A(?:MSWin32|msys|cygwin)\z/;
    my $MSLUG  = '-Users-fx31-proj';
    my $mac_tp = "/Users/fx31/.claude/projects/$MSLUG/$SID.jsonl";
    my $mac_env = sub { my ($D) = @_; return env_for($D, TMPDIR => '/var/folders/zz/fx31/T/', LOCALAPPDATA => undef) };
    my $fx = fixture(members => 2);

    for my $fp ("/private/tmp/claude-501/$MSLUG/$SID/scratchpad/p22-commit.txt",
                "/tmp/claude-501/$MSLUG/$SID/scratchpad/a/b.txt") {
        my $r = wg_writes(driver_payload(session_id => $SID, transcript_path => $mac_tp,
                                         cwd => $fx->{R}, file_path => $fp), env => $mac_env->($fx->{D}));
        is($r->{rc}, 0, "AC-16: driver Write to its own scratchpad at $fp gives rc 0");
    }

    # _own_scratchpad on its own (the writes-mode verdict above can also be
    # reached through _is_temp, which on darwin now knows /private/tmp too).
    my $R = { mode => 'driver', root => $fx->{R}, data => $fx->{D} };
    my $p = { session_id => $SID, transcript_path => $mac_tp };
    my $own = sub {
        my ($abs) = @_;
        local %ENV = %ENV;
        delete @ENV{qw(TMPDIR TEMP TMP LOCALAPPDATA)};
        $ENV{TMPDIR} = '/var/folders/zz/fx31/T/';
        return BpHook::WriteGuards::_own_scratchpad($p, BpHook::Guards::Common::canon($abs), $R);
    };
    is($own->("/private/tmp/claude-501/$MSLUG/$SID/scratchpad/x.txt"), 1,
       'AC-16: _own_scratchpad accepts the /private/tmp/claude-<uid> base');
    is($own->("/tmp/claude-0/$MSLUG/$SID/scratchpad/x.txt"), 1,
       'AC-16: _own_scratchpad accepts the /tmp/claude-<uid> base (Linux shape)');
    is($own->("/tmp/claude/$MSLUG/$SID/scratchpad/x.txt"), 1,
       'AC-16: _own_scratchpad still accepts a bare "claude" segment');
    is($own->("/private/tmp/claude-501/$MSLUG/$OSID/scratchpad/x.txt"), 0,
       'AC-16: another session\'s scratchpad is not this driver\'s');
    is($own->("/private/tmp/claude-x/$MSLUG/$SID/scratchpad/x.txt"), 0,
       'AC-16: "claude-" must be followed by a numeric uid');

    # darwin: a TMPDIR candidate also counts under its /private spelling.
    SKIP: {
        skip 'AC-16: the /var <-> /private/var alias is darwin-only', 2 unless $^O eq 'darwin';
        local %ENV = %ENV;
        delete @ENV{qw(TMPDIR TEMP TMP LOCALAPPDATA)};
        $ENV{TMPDIR} = '/var/folders/zz/fx31/T/';
        is(BpHook::WriteGuards::_is_temp('/private/var/folders/zz/fx31/T/x.txt', $fx->{R}, $fx->{D}), 1,
           'AC-16 (darwin): /private/var/... is under TMPDIR=/var/...');
        is(BpHook::WriteGuards::_is_temp('/private/tmp/anything/x.txt', $fx->{R}, $fx->{D}), 1,
           'AC-16 (darwin): /private/tmp/... is /tmp/... under its real name');
    }
}

done_testing();
