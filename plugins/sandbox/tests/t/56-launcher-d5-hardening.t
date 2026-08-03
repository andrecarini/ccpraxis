#!/usr/bin/env perl
# Oracle tests for q05-launcher-d5-hardening, derived from
#   .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/specs/q05-launcher-d5-hardening-spec.md
#
# IMMUTABLE ORACLE: written from the spec BEFORE the implementation exists.
# launcher.pl does not yet carry the fixes for the five D5 findings at
# authoring time -- most of the assertions below are EXPECTED to read "not
# ok" until q05 lands. Do not weaken these assertions to make a future
# implementation's life easier.
#
# ZERO-REAL-I/O + NO-LAUNCH RULE: this file never spawns launcher.pl, never
# builds an image, never starts a container. It exercises launcher.pl's own
# logic in two ways only:
#   (a) source-structural assertions on launcher.pl's text (like t/53's
#       Group A/H), and
#   (b) EXTRACTING real fragments of launcher.pl's own source text (the
#       q03:protected-path-decision sentinel region, and the span from the
#       CCPRAXIS_AUTH_HOME computation through the protected_path_outcome
#       call-site block) and eval-ing them into an isolated package, with
#       %ENV faked via `local %ENV` (restored after every call) and any
#       `exit()` inside the extracted call-site block trapped via a
#       compile-time-scoped `local *CORE::GLOBAL::exit` override so it can
#       never terminate this test process. No filesystem is touched outside
#       a File::Temp tempdir (auto-CLEANUP), and never the real HOME,
#       USERPROFILE, CLAUDE_CONFIG_DIR, or ~/.claude.
#
# This is the same "eval the real extracted source" idiom t/53 already uses
# for the sentinel region (its AC-10 harness) -- extended here to also cover
# the launcher's OWN wiring immediately around the call site, because C1/C2/
# C5/C6/C7/C9 are specifically about whether registry_path/extra_list_path
# are derived THROUGH the authoritative-home seam at that exact call site,
# which the pure ProtectedPaths.pm module alone cannot prove.
#
# Criterion mapping (see the full table in this header and inline comments):
#   C1        : HOME redirected to a decoy -- marketplace roots still derived,
#               refused target still refused (D5's reproduction case)
#   C2        : same for USERPROFILE alone, and both together
#   C3        : _pp_env_seam hardens both HOME and USERPROFILE; unrelated key
#               and undef authoritative_home still fall through
#   C4        : the authoritative-home gate is keyed on $^O ne 'MSWin32' alone
#               (driven via injected $^O), not $WINDOWS_FAMILY; $WINDOWS_FAMILY
#               itself is unnarrowed
#   C5        : registry_path AND extra_list_path both derived through the seam
#   C6        : extra list unions CLAUDE_CONFIG_DIR with the home candidates
#               and falls back correctly when unset
#   C7        : CLAUDE_CONFIG_DIR does NOT redirect the registry (paired with
#               a vacuity gate that it DOES redirect the extra list)
#   C8        : live_install_hint passes the bare-root/home rejection guards;
#               a legitimate hint is still admitted and reason-ranked
#   C9        : no regression -- a ccpraxis clone outside the install and an
#               ordinary project still route passthrough (refuse == 0)
#   C10       : validation commands only, recorded not re-implemented (see
#               tail of this file)

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Cwd qw(abs_path);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP ();
use ProtectedPaths qw(path_relation protected_roots target_self_codes normalize_path);

# =====================================================================
# Environment resolution -- BAIL_OUT reserved for a genuinely broken
# environment, never for the expected-absent q05 fixes (see header ruling).
# =====================================================================
my $repo_root = abs_path("$Bin/../../../..");
BAIL_OUT("cannot resolve repo root from $Bin/../../../..") unless defined $repo_root;

my $LAUNCHER = "$Bin/../../scripts/launcher.pl";
open my $lfh, '<:raw', $LAUNCHER or BAIL_OUT("cannot read launcher.pl: $!");
my @lines = <$lfh>;
close $lfh;
my $src = join '', @lines;

my $SKIP_REASON_REGION =
    'q05: q03:protected-path-decision sentinel region not found (or failed to eval) '
  . 'in launcher.pl -- implementation pending (TDD red phase)';
my $SKIP_REASON_CALLSITE =
    'q05: the CCPRAXIS_AUTH_HOME..protected_path_outcome call-site span could not be '
  . 'located/extracted/eval-ed from launcher.pl -- implementation pending (TDD red phase)';
my $SKIP_REASON_AUTHGATE =
    'q05: the CCPRAXIS_AUTH_HOME eval{} block could not be located/extracted/eval-ed '
  . 'from launcher.pl -- implementation pending (TDD red phase)';

# =====================================================================
# Small local helpers (test scaffolding only).
# =====================================================================

sub _write_json {
    my ($path, $data) = @_;
    open my $fh, '>:raw', $path or die "cannot write $path: $!";
    print { $fh } JSON::PP->new->canonical->encode($data);
    close $fh;
}

# Balanced-brace extraction starting at the index of an opening '{'.
sub _extract_braced {
    my ($str, $open_idx) = @_;
    return undef unless substr($str, $open_idx, 1) eq '{';
    my $depth = 0;
    my $i = $open_idx;
    while ($i < length($str)) {
        my $c = substr($str, $i, 1);
        $depth++ if $c eq '{';
        $depth-- if $c eq '}';
        if ($depth == 0) {
            return substr($str, $open_idx, $i - $open_idx + 1);
        }
        $i++;
    }
    return undef;
}

# =====================================================================
# Extraction 1 -- the q03:protected-path-decision sentinel region (same
# idiom as t/53's AC-10 harness). Gives us protected_path_outcome() and
# _pp_env_seam() as pure, directly-callable functions -- no launcher wiring
# involved, so C3/C8 do not depend on C1/C2/C5/C6/C7/C9's extraction below.
# =====================================================================
my ($region) = $src =~ /^\# >>> q03:protected-path-decision:BEGIN\b.*?\n(.*?)^\# <<< q03:protected-path-decision:END\b/ms;

my ($DECIDE, $ENVSEAM);
if (defined $region) {
    my $harness = "package Q05Region;\nuse strict;\nuse warnings;\n"
                . "use ProtectedPaths qw(path_relation protected_roots target_self_codes normalize_path);\n"
                . $region . "\n1;\n";
    my $eval_ok = eval $harness;   ## no critic
    my $eval_err = $@;
    if ($eval_ok) {
        $DECIDE  = Q05Region->can('protected_path_outcome');
        $ENVSEAM = Q05Region->can('_pp_env_seam');
    } else {
        diag("Q05Region eval error: $eval_err");
    }
}

# =====================================================================
# Extraction 2 -- the CCPRAXIS_AUTH_HOME eval{} block (the platform gate,
# item 2 / C4). Extracted standalone so C4 can drive it with an injected
# $^O regardless of this host's real platform.
# =====================================================================
my $AUTH_ANCHOR = 'my $CCPRAXIS_AUTH_HOME = eval ';
my $auth_anchor_idx = index($src, $AUTH_ANCHOR);
my $auth_braced;
if ($auth_anchor_idx >= 0) {
    my $open_idx = index($src, '{', $auth_anchor_idx + length($AUTH_ANCHOR) - 1);
    $auth_braced = _extract_braced($src, $open_idx) if $open_idx >= 0;
}

my $AUTHGATE_OK = 0;
if (defined $auth_braced) {
    my $harness = "package Q05AuthGate;\nuse strict;\nuse warnings;\n"
                . "sub compute {\n"
                . "    my \$CCPRAXIS_AUTH_HOME = eval " . $auth_braced . ";\n"
                . "    \$CCPRAXIS_AUTH_HOME = undef if \$@;\n"
                . "    return \$CCPRAXIS_AUTH_HOME;\n"
                . "}\n1;\n";
    my $eval_ok = eval $harness;   ## no critic
    $AUTHGATE_OK = 1 if $eval_ok;
    diag("Q05AuthGate eval error: $@") unless $eval_ok;
}

# =====================================================================
# Extraction 3 -- the span from immediately after the CCPRAXIS_AUTH_HOME
# assignment through the end of the protected_path_outcome call-site block
# (same block-boundary technique as t/53's AC-44: scan back <=5 lines from
# the call for a bare '{' line, forward for a bare '}' line). This captures
# BOTH the current call-site AND any corrective statements q05 inserts in
# that gap (a shadowed $CLAUDE_HOST_CONFIG, etc.), whichever shape the fix
# takes, without pinning an exact implementation.
# =====================================================================
my ($auth_undef_line_idx) = grep { $lines[$_] =~ /\$CCPRAXIS_AUTH_HOME\s*=\s*undef\s+if\s*\$\@;/ } (0 .. $#lines);
my ($call_line_idx) = grep { $lines[$_] =~ /protected_path_outcome\(\s*\$PROJECT_PATH\b/ } (0 .. $#lines);
my ($block_open_idx, $block_close_idx);
if (defined $call_line_idx) {
    for (my $i = $call_line_idx; $i >= 0 && $i >= $call_line_idx - 5; $i--) {
        if ($lines[$i] =~ /^\{\s*$/) { $block_open_idx = $i; last; }
    }
    if (defined $block_open_idx) {
        for my $i ($block_open_idx + 1 .. $#lines) {
            if ($lines[$i] =~ /^\}\s*$/) { $block_close_idx = $i; last; }
        }
    }
}

my $CALLSITE_OK = 0;
if (defined $region && defined $auth_undef_line_idx && defined $block_close_idx
    && $block_close_idx > $auth_undef_line_idx) {
    my $span = join('', @lines[($auth_undef_line_idx + 1) .. $block_close_idx]);
    (my $span_our_pp = $span) =~ s/\bmy(\s+\$pp\b)/our$1/;

    my $harness = "package Q05CallSite;\nuse strict;\nuse warnings;\n"
                . "use ProtectedPaths qw(path_relation protected_roots target_self_codes normalize_path);\n"
                . $region . "\n"
                . "our (\$PROJECT_PATH, \$CLAUDE_HOST_CONFIG, \$HOST_PLUGINS_DIR, \$LIVE_CCPRAXIS_ROOT, "
                . "\$CCPRAXIS_AUTH_HOME, \$WINDOWS_FAMILY, \$PODMAN, \$pp);\n"
                . "sub _run {\n" . $span_our_pp . "\n  return 1;\n}\n1;\n";

    # NOT `local` -- a CORE::GLOBAL:: override is dispatched dynamically at
    # CALL time (not resolved once at compile time), so a `local` override
    # that was restored before _run() is actually invoked leaves the
    # compiled exit() call pointing at nothing ("Undefined subroutine
    # &CORE::GLOBAL::exit called"). We only ever want the real exit()
    # anywhere else in this test file's own execution, and it is never
    # called: this file's own flow only ever reaches Test::More's
    # done_testing() at the very end, which does not call a bareword
    # exit() in the matched-plan path this file always takes.
    *CORE::GLOBAL::exit = sub {
        die "Q05_LAUNCHER_EXIT_CALLED:" . (defined $_[0] ? $_[0] : 0) . "\n";
    };
    my $eval_ok = eval $harness;   ## no critic
    if ($eval_ok) {
        $CALLSITE_OK = 1;
    } else {
        diag("Q05CallSite eval error: $@");
    }
}

# Invoke the extracted call-site span with a fully-controlled environment.
# Returns the resulting $pp hashref (protected_path_outcome's return value),
# regardless of whether the span's own exit() fired (trapped above) or it
# fell through normally -- $pp is a package global either way.
sub _run_guard {
    my (%set) = @_;
    no strict 'refs';
    ${'Q05CallSite::PROJECT_PATH'}       = $set{project_path};
    ${'Q05CallSite::CLAUDE_HOST_CONFIG'} = $set{claude_host_config};
    ${'Q05CallSite::HOST_PLUGINS_DIR'}   = $set{host_plugins_dir} // '';
    ${'Q05CallSite::LIVE_CCPRAXIS_ROOT'} = $set{live_ccpraxis_root} // '';
    ${'Q05CallSite::CCPRAXIS_AUTH_HOME'} = $set{auth_home};
    ${'Q05CallSite::WINDOWS_FAMILY'}     = 0;
    ${'Q05CallSite::PODMAN'}             = '';
    ${'Q05CallSite::pp'}                 = undef;
    use strict 'refs';
    local %ENV = %{ $set{env} // {} };
    my $ok = eval { Q05CallSite::_run(); 1 };
    my $err = $@;
    if (!$ok && (!defined $err || $err !~ /^Q05_LAUNCHER_EXIT_CALLED/)) {
        return (undef, $err);
    }
    no strict 'refs';
    return (${'Q05CallSite::pp'}, undef);
}

# =====================================================================
# Shared fixture (File::Temp, auto-CLEANUP) for C1/C2/C5/C6/C7/C9. Never
# touches the real filesystem outside this tempdir; never the real HOME,
# USERPROFILE, CLAUDE_CONFIG_DIR, or ~/.claude.
# =====================================================================
my $ROOT       = tempdir(CLEANUP => 1);
my $AUTH_HOME  = "$ROOT/auth_home";
my $DECOY_HOME = "$ROOT/decoy_home";
my $CFG_DIR    = "$ROOT/cfg_dir";

make_path("$AUTH_HOME/.claude/plugins", "$DECOY_HOME", "$CFG_DIR/plugins");

_write_json("$AUTH_HOME/.claude/plugins/known_marketplaces.json", {
    'ext-one' => {
        source          => { source => 'directory', path => "$AUTH_HOME/ext-src" },
        installLocation => "$AUTH_HOME/ext-install",
    },
});
_write_json("$AUTH_HOME/.claude/ccpraxis-protected-paths.json", ["$AUTH_HOME/authhome-protected"]);

_write_json("$CFG_DIR/ccpraxis-protected-paths.json", ["$ROOT/cfgdir-protected"]);
_write_json("$CFG_DIR/plugins/known_marketplaces.json", {
    'evil' => {
        source          => { source => 'directory', path => "$ROOT/cfgdir-market-src" },
        installLocation => "$ROOT/cfgdir-market-install",
    },
});

# =====================================================================
# C1/C2/C5 (structural pair) -- ProtectedPaths.pm's own q04 candidate-source
# fan-out (protected_roots' "try the same relative file under every notion-A
# home candidate" loop, keyed off env_fn('HOME')) ALREADY re-derives the
# registry/extra-list roots from the authoritative home in the plain
# HOME-redirected case, *given that $CCPRAXIS_AUTH_HOME is available* --
# because _pp_env_seam already hardens the 'HOME' key today (only
# USERPROFILE is unhardened, item 1). Measured directly: calling
# protected_roots() with an explicit, DECOY-rooted registry_path/
# extra_list_path but a seam-hardened env_fn('HOME') still resolves the
# marketplace/extra-list roots via that fan-out. So refuse/reason/root
# alone, below, are real correctness checks but are NOT independently
# red-before-green for the registry_path/extra_list_path literal bypass
# itself (item 3) -- they would already pass unfixed, given a defined
# authoritative home. The genuinely discriminating signal is structural:
# item 3 requires registry_path/extra_list_path to be derived THROUGH the
# seam at the call site itself, not merely rescued by a downstream safety
# net that item 3's fix must not be read as license to omit (spec S3: "Both
# must be derived through the seam, so a redirected HOME or USERPROFILE
# cannot move them" -- a requirement on the call site, not on whether some
# other path happens to still work). So: assert the extracted span (from
# immediately after $CCPRAXIS_AUTH_HOME's computation through the call)
# itself derives the value it interpolates as $CLAUDE_HOST_CONFIG from
# $CCPRAXIS_AUTH_HOME, BEFORE the registry_path/extra_list_path keys are
# built -- i.e. the call site's own construction, not a module-side rescue.
# =====================================================================
SKIP: {
    # HARNESS GATE (coordinator): a bare `skip ... unless <extraction succeeded>`
    # would turn a FAILED EXTRACTION into 1 silent PASSES -- and the implementer is
    # about to edit launcher.pl, which is exactly what can break extraction. Assert the
    # precondition as a FAILURE first, so the suite can never go green on a region
    # this file could not even find. The skip below then only prevents a die.
    ok($CALLSITE_OK, 'C1/C2/C5 structural HARNESS: the launcher.pl region under test was located and extracted -- if this fails, the 1 assertion(s) below did NOT run');
    skip "$SKIP_REASON_CALLSITE (C1/C2/C5 structural)", 1 unless $CALLSITE_OK;
    my $span_for_struct = join('', @lines[($auth_undef_line_idx + 1) .. $block_close_idx]);
    my ($pre_call) = $span_for_struct =~ /\A(.*?)registry_path\s*=>/s;
    $pre_call //= '';
    like($pre_call, qr/\$CLAUDE_HOST_CONFIG\s*=[^=~].*\$CCPRAXIS_AUTH_HOME/s,
         "C1/C2/C5 (structural): before the registry_path/extra_list_path keys are built, the call site's own "
       . "\$CLAUDE_HOST_CONFIG is (re)derived from \$CCPRAXIS_AUTH_HOME -- routed through the seam at the call "
       . "site itself, not merely rescued by protected_roots' own candidate-source fan-out")
        or diag("span examined:\n$pre_call");
}

# =====================================================================
# C1 -- HOME redirected to a decoy: marketplace-install / marketplace-source
# roots (registry-derived) are still derived, refused target still refused.
# Plus the genuinely-discriminating signal: no stale registry-missing
# warning naming the decoy path (item 3's literal-bypass symptom -- the
# explicit, wrong registry_path is tried FIRST and warns even though q04's
# fan-out later rescues the roots via env_fn('HOME')).
# =====================================================================
SKIP: {
    # HARNESS GATE (coordinator): a bare `skip ... unless <extraction succeeded>`
    # would turn a FAILED EXTRACTION into 9 silent PASSES -- and the implementer is
    # about to edit launcher.pl, which is exactly what can break extraction. Assert the
    # precondition as a FAILURE first, so the suite can never go green on a region
    # this file could not even find. The skip below then only prevents a die.
    ok($CALLSITE_OK, 'C1 HARNESS: the launcher.pl region under test was located and extracted -- if this fails, the 9 assertion(s) below did NOT run');
    skip "$SKIP_REASON_CALLSITE (C1)", 9 unless $CALLSITE_OK;

    my %base = (
        claude_host_config => "$DECOY_HOME/.claude",
        auth_home           => $AUTH_HOME,
        live_ccpraxis_root  => "$AUTH_HOME/ccpraxis-anchor",
        env                 => { HOME => $DECOY_HOME },
    );

    my ($pp1, $err1) = _run_guard(%base, project_path => "$AUTH_HOME/ext-install");
    ok(defined $pp1, "C1: protected_path_outcome call succeeds with HOME redirected to a decoy")
        or diag("error: " . ($err1 // 'undef'));
    if (defined $pp1) {
        is($pp1->{refuse}, 1, "C1: marketplace-install target ($AUTH_HOME/ext-install) is still refused with HOME redirected to a decoy");
        is($pp1->{reason}, 'marketplace-install', "C1: refusal reason is marketplace-install");
        is($pp1->{root}, "$AUTH_HOME/ext-install", "C1: refusal root is the registry-derived installLocation");
        my @decoy_warnings = grep { index($_, $DECOY_HOME) >= 0 } @{ $pp1->{warnings} // [] };
        is(scalar(@decoy_warnings), 0,
           "C1 (the genuinely discriminating signal): no warning line names the decoy path -- registry_path was "
         . "built from the authoritative home directly, not tried-and-failed against the decoy first")
            or diag('decoy-naming warnings: ' . join(' | ', @decoy_warnings));
    } else {
        ok(0, "C1: refuse == 1 (call failed)"); ok(0, "C1: reason eq marketplace-install (call failed)"); ok(0, "C1: root (call failed)");
        ok(0, "C1: no warning names the decoy path (call failed)");
    }

    my ($pp2, $err2) = _run_guard(%base, project_path => "$AUTH_HOME/ext-src");
    ok(defined $pp2, "C1: protected_path_outcome call succeeds for the marketplace-source target")
        or diag("error: " . ($err2 // 'undef'));
    if (defined $pp2) {
        is($pp2->{refuse}, 1, "C1: marketplace-source target ($AUTH_HOME/ext-src) is still refused with HOME redirected to a decoy");
        is($pp2->{reason}, 'marketplace-source', "C1: refusal reason is marketplace-source");
    } else {
        ok(0, "C1: refuse == 1 for marketplace-source (call failed)"); ok(0, "C1: reason eq marketplace-source (call failed)");
    }
}

# =====================================================================
# C2 -- same reproduction, with USERPROFILE redirected alone, and with both
# HOME and USERPROFILE redirected together.
# =====================================================================
SKIP: {
    # HARNESS GATE (coordinator): a bare `skip ... unless <extraction succeeded>`
    # would turn a FAILED EXTRACTION into 6 silent PASSES -- and the implementer is
    # about to edit launcher.pl, which is exactly what can break extraction. Assert the
    # precondition as a FAILURE first, so the suite can never go green on a region
    # this file could not even find. The skip below then only prevents a die.
    ok($CALLSITE_OK, 'C2 HARNESS: the launcher.pl region under test was located and extracted -- if this fails, the 6 assertion(s) below did NOT run');
    skip "$SKIP_REASON_CALLSITE (C2)", 6 unless $CALLSITE_OK;

    for my $case (
        ['USERPROFILE alone', { USERPROFILE => $DECOY_HOME }],
        ['HOME and USERPROFILE together', { HOME => $DECOY_HOME, USERPROFILE => $DECOY_HOME }],
    ) {
        my ($label, $env) = @$case;
        my ($pp, $err) = _run_guard(
            claude_host_config => "$DECOY_HOME/.claude",
            auth_home           => $AUTH_HOME,
            live_ccpraxis_root  => "$AUTH_HOME/ccpraxis-anchor",
            env                 => $env,
            project_path        => "$AUTH_HOME/ext-install",
        );
        ok(defined $pp, "C2: protected_path_outcome call succeeds with $label redirected to a decoy")
            or diag("error: " . ($err // 'undef'));
        if (defined $pp) {
            is($pp->{refuse}, 1, "C2: marketplace-install target is still refused with $label redirected to a decoy");
            is($pp->{reason}, 'marketplace-install', "C2: refusal reason is marketplace-install ($label)");
        } else {
            ok(0, "C2: refuse == 1 ($label, call failed)"); ok(0, "C2: reason eq marketplace-install ($label, call failed)");
        }
    }
}

# =====================================================================
# C3 -- _pp_env_seam returns the authoritative home for BOTH HOME and
# USERPROFILE; an unrelated key still falls through to the raw hash
# (paired negative: the seam must not become a blanket override); and the
# pre-existing undef-authoritative-home fallback is preserved.
# =====================================================================
SKIP: {
    # HARNESS GATE (coordinator): a bare `skip ... unless <extraction succeeded>`
    # would turn a FAILED EXTRACTION into 5 silent PASSES -- and the implementer is
    # about to edit launcher.pl, which is exactly what can break extraction. Assert the
    # precondition as a FAILURE first, so the suite can never go green on a region
    # this file could not even find. The skip below then only prevents a die.
    ok(defined $ENVSEAM, 'C3 HARNESS: the launcher.pl region under test was located and extracted -- if this fails, the 8 assertion(s) below did NOT run');
    skip "$SKIP_REASON_REGION (C3)", 8 unless defined $ENVSEAM;

    my $seam = $ENVSEAM->({ HOME => '/decoy/home', USERPROFILE => '/decoy/profile', PATH => '/usr/bin' },
                           '/real/auth/home');
    is($seam->('HOME'), '/real/auth/home', 'C3: _pp_env_seam returns the authoritative home for HOME');
    # RULING NARROWED by the coordinator 2026-08-03. This originally required
    # USERPROFILE to be hardened unconditionally, which put item 1 in direct
    # conflict with q03's AC-54 (USERPROFILE passes through unchanged) and with
    # q04's source-set design, recorded in ProtectedPaths.pm, which is built on
    # this seam hardening HOME specifically. Both of those are done siblings
    # and neither is in q05's write set.
    #
    # The conflict dissolves once the finding is stated precisely: USERPROFILE
    # is dangerous only when it STANDS IN for an absent HOME, because that is
    # the one case where it moves the whole protected set via home_dir(). When
    # HOME is present, USERPROFILE is just another key. So the seam hardens it
    # exactly then, and both contracts hold on their own terms rather than one
    # being weakened to accommodate the other.
    is($seam->('USERPROFILE'), '/decoy/profile',
       'C3: with HOME PRESENT, USERPROFILE is an ordinary key and falls through unchanged (q03 AC-54 holds)');

    my $seam_no_home = $ENVSEAM->({ USERPROFILE => '/decoy/profile', PATH => '/usr/bin' },
                                   '/real/auth/home');
    is($seam_no_home->('USERPROFILE'), '/real/auth/home',
       'C3 (item 1, the actual finding): with HOME ABSENT, USERPROFILE would stand in for it via home_dir() -- so it IS hardened');
    is($seam_no_home->('PATH'), '/usr/bin',
       'C3 (paired negative): hardening USERPROFILE in the HOME-absent case does not make the seam a blanket override');
    my $seam_empty_home = $ENVSEAM->({ HOME => '', USERPROFILE => '/decoy/profile' }, '/real/auth/home');
    is($seam_empty_home->('USERPROFILE'), '/real/auth/home',
       'C3: an EMPTY HOME counts as absent -- home_dir() would fall through to USERPROFILE, so the seam must too');
    is($seam->('PATH'), '/usr/bin', 'C3 (paired negative): an unrelated key still falls through to the supplied env hash');
    is($seam->('CLAUDE_CONFIG_DIR'), undef, 'C3 (paired negative): a key absent from the supplied env hash stays undef, not silently invented');

    my $seam_no_auth = $ENVSEAM->({ HOME => '/x/home' }, undef);
    is($seam_no_auth->('HOME'), '/x/home', 'C3: with no authoritative home available, HOME still falls through to the raw hash (fallback preserved)');
}

# =====================================================================
# C4 -- the authoritative-home gate is keyed on $^O ne 'MSWin32' alone,
# ACTIVE under msys and cygwin, driven by an injected $^O (not by observing
# this host, which is neither Windows nor msys/cygwin). $WINDOWS_FAMILY
# itself must not be narrowed -- it keeps its ~10 other uses.
# =====================================================================
SKIP: {
    # HARNESS GATE (coordinator): a bare `skip ... unless <extraction succeeded>`
    # would turn a FAILED EXTRACTION into 4 silent PASSES -- and the implementer is
    # about to edit launcher.pl, which is exactly what can break extraction. Assert the
    # precondition as a FAILURE first, so the suite can never go green on a region
    # this file could not even find. The skip below then only prevents a die.
    ok($AUTHGATE_OK, 'C4 HARNESS: the launcher.pl region under test was located and extracted -- if this fails, the 4 assertion(s) below did NOT run');
    skip "$SKIP_REASON_AUTHGATE (C4)", 4 unless $AUTHGATE_OK;

    for my $case (
        ['MSWin32', 0, 'the gate is inactive on native Windows perl (getpwuid is unimplemented there)'],
        ['msys',    1, 'the gate is ACTIVE under msys (Git-for-Windows perl, the primary host it must work on)'],
        ['cygwin',  1, 'the gate is ACTIVE under cygwin'],
        ['linux',   1, 'the gate is ACTIVE on an arbitrary non-Windows $^O'],
    ) {
        my ($os, $want_defined, $why) = @$case;
        local $^O = $os;
        my $got = eval { Q05AuthGate::compute() };
        my $is_defined = defined($got) ? 1 : 0;
        is($is_defined, $want_defined, "C4: \$^O='$os' -- $why")
            or diag("compute() returned: " . (defined $got ? "'$got'" : 'undef'));
    }
}

# ---- C4 (structural pair) -- the extracted gate no longer references
#      $WINDOWS_FAMILY at all (that would re-admit cygwin/msys into the
#      exclusion), and the file-scope $WINDOWS_FAMILY definition itself is
#      unnarrowed (still matches all three platform names, for its other
#      uses). ----
{
    ok((defined $auth_braced && index($auth_braced, '$WINDOWS_FAMILY') == -1),
       'C4: the CCPRAXIS_AUTH_HOME gate no longer references $WINDOWS_FAMILY (structural)')
        or diag(defined $auth_braced ? "gate body: $auth_braced" : 'gate body not found');

    my $WF_DEF_LINE = 'my $WINDOWS_FAMILY = $^O =~ /^(MSWin32|cygwin|msys)$/;';
    ok(index($src, $WF_DEF_LINE) >= 0,
       'C4 (no-narrowing pair): the $WINDOWS_FAMILY definition line is unchanged (still MSWin32|cygwin|msys)');

    my $wf_count = () = $src =~ /\$WINDOWS_FAMILY\b/g;
    ok($wf_count >= 11,
       "C4 (no-narrowing pair): \$WINDOWS_FAMILY still has at least 11 occurrences in launcher.pl "
     . "(definition + its ~10 other uses; got $wf_count) -- proves the fix did not delete/narrow those uses");
}

# =====================================================================
# C5 -- extra_list_path (not just registry_path) is derived through the
# seam: with HOME redirected to a decoy, a user-configured root from the
# AUTHORITATIVE home's extra list is still derived and still refused.
# =====================================================================
SKIP: {
    # HARNESS GATE (coordinator): a bare `skip ... unless <extraction succeeded>`
    # would turn a FAILED EXTRACTION into 4 silent PASSES -- and the implementer is
    # about to edit launcher.pl, which is exactly what can break extraction. Assert the
    # precondition as a FAILURE first, so the suite can never go green on a region
    # this file could not even find. The skip below then only prevents a die.
    ok($CALLSITE_OK, 'C5 HARNESS: the launcher.pl region under test was located and extracted -- if this fails, the 4 assertion(s) below did NOT run');
    skip "$SKIP_REASON_CALLSITE (C5)", 4 unless $CALLSITE_OK;

    my ($pp, $err) = _run_guard(
        claude_host_config => "$DECOY_HOME/.claude",
        auth_home           => $AUTH_HOME,
        live_ccpraxis_root  => "$AUTH_HOME/ccpraxis-anchor",
        env                 => { HOME => $DECOY_HOME },
        project_path        => "$AUTH_HOME/authhome-protected",
    );
    ok(defined $pp, "C5: protected_path_outcome call succeeds for the extra-list target with HOME redirected")
        or diag("error: " . ($err // 'undef'));
    if (defined $pp) {
        is($pp->{refuse}, 1, "C5: the authoritative home's own extra-list entry is still refused with HOME redirected to a decoy");
        is($pp->{reason}, 'user-configured', "C5: refusal reason is user-configured");
        is($pp->{root}, "$AUTH_HOME/authhome-protected", "C5: refusal root is the extra-list-derived path (extra_list_path routed through the seam, not the decoy)");
    } else {
        ok(0, "C5: refuse == 1 (call failed)"); ok(0, "C5: reason (call failed)"); ok(0, "C5: root (call failed)");
    }
}

# =====================================================================
# C6 / C7 -- CLAUDE_CONFIG_DIR is honoured for the extra list (unioned with
# the authoritative home's own extra list, not replacing it) and NOT for
# the registry (the security asymmetry). HOME is the real authoritative home
# here (not a decoy) -- this isolates CLAUDE_CONFIG_DIR's own effect from
# item 3's HOME-redirection fix.
# =====================================================================
SKIP: {
    # HARNESS GATE (coordinator): a bare `skip ... unless <extraction succeeded>`
    # would turn a FAILED EXTRACTION into 8 silent PASSES -- and the implementer is
    # about to edit launcher.pl, which is exactly what can break extraction. Assert the
    # precondition as a FAILURE first, so the suite can never go green on a region
    # this file could not even find. The skip below then only prevents a die.
    ok($CALLSITE_OK, 'C6/C7 HARNESS: the launcher.pl region under test was located and extracted -- if this fails, the 7 assertion(s) below did NOT run');
    skip "$SKIP_REASON_CALLSITE (C6/C7)", 7 unless $CALLSITE_OK;

    my %base = (
        claude_host_config => "$AUTH_HOME/.claude",
        auth_home           => $AUTH_HOME,
        live_ccpraxis_root  => "$AUTH_HOME/ccpraxis-anchor",
        env                 => { HOME => $AUTH_HOME, CLAUDE_CONFIG_DIR => $CFG_DIR },
    );

    # ---- C7 vacuity gate: CLAUDE_CONFIG_DIR DID take effect for the extra list ----
    my ($pp_extra, $err_extra) = _run_guard(%base, project_path => "$ROOT/cfgdir-protected");
    ok(defined $pp_extra, "C7 (vacuity gate): call succeeds for the CLAUDE_CONFIG_DIR-only extra-list target")
        or diag("error: " . ($err_extra // 'undef'));
    if (defined $pp_extra) {
        # RULING REVERSED by the coordinator 2026-08-03. These two assertions
        # originally required the extra list to HONOUR CLAUDE_CONFIG_DIR, on the
        # reasoning that the extra list is add-only and therefore fails safe.
        # That reasoning is wrong, and t/53's AC-57/AC-58 caught it: add-only is
        # true of the list's CONTENTS, not of its LOCATION. Redirecting WHERE the
        # list is read from means the user's real list is never read at all --
        # fewer protected roots, fewer refusals, failing OPEN. That is precisely
        # the "silently void the user list" failure q03's Decision #5 pinned this
        # path to prevent, and ProtectedPaths.pm separately records q04 dropping
        # CLAUDE_CONFIG_DIR from the source set for the same reason, with
        # measurements. So the code was right and the help text's promise was
        # wrong; the promise is what this package corrects.
        is($pp_extra->{refuse}, 0,
           "C7: a path named ONLY in \$CLAUDE_CONFIG_DIR/ccpraxis-protected-paths.json is NOT refused -- "
         . "the extra list is never read from CLAUDE_CONFIG_DIR, so setting it cannot VOID the user's real list");
    } else {
        ok(0, "C7: refuse == 0 (call failed)");
    }

    # ---- C7 negative: CLAUDE_CONFIG_DIR must NOT redirect the registry ----
    my ($pp_reg, $err_reg) = _run_guard(%base, project_path => "$ROOT/cfgdir-market-install");
    ok(defined $pp_reg, "C7 (negative): call succeeds for the CLAUDE_CONFIG_DIR-only registry target")
        or diag("error: " . ($err_reg // 'undef'));
    if (defined $pp_reg) {
        is($pp_reg->{refuse}, 0,
           "C7 (negative, the asymmetry): a marketplace registered ONLY in \$CLAUDE_CONFIG_DIR/plugins/known_marketplaces.json is "
         . "NOT refused -- the registry is never read from CLAUDE_CONFIG_DIR, so an attacker-controlled CLAUDE_CONFIG_DIR "
         . "cannot shrink the protected set");
    } else {
        ok(0, "C7 (negative): refuse == 0 (call failed)");
    }

    # ---- C6: union, not replacement -- the authoritative home's OWN extra
    #      list entry is STILL protected even while CLAUDE_CONFIG_DIR is set ----
    my ($pp_union, $err_union) = _run_guard(%base, project_path => "$AUTH_HOME/authhome-protected");
    ok(defined $pp_union, "C6: call succeeds for the authoritative-home extra-list target while CLAUDE_CONFIG_DIR is set")
        or diag("error: " . ($err_union // 'undef'));
    if (defined $pp_union) {
        is($pp_union->{refuse}, 1,
           "C6: the authoritative home's own extra-list entry is STILL refused while CLAUDE_CONFIG_DIR is set "
         . "(union, not a precedence chain that would replace it)");
    } else {
        ok(0, "C6: refuse == 1 (call failed)");
    }
}

# =====================================================================
# C8 -- live_install_hint passes the same rejection/quarantine guards as
# every other root (a bare-root or home-directory hint is REJECTED, not
# admitted), paired with a vacuity gate that a legitimate hint is still
# admitted, and reason-ranked as 'ccpraxis-install'. Tested directly against
# protected_path_outcome (zero real I/O: registry/extra_list/exists/
# read_file are all injected), independent of the launcher call-site wiring.
# =====================================================================
SKIP: {
    # HARNESS GATE (coordinator): a bare `skip ... unless <extraction succeeded>`
    # would turn a FAILED EXTRACTION into 9 silent PASSES -- and the implementer is
    # about to edit launcher.pl, which is exactly what can break extraction. Assert the
    # precondition as a FAILURE first, so the suite can never go green on a region
    # this file could not even find. The skip below then only prevents a die.
    ok(defined $DECIDE, 'C8 HARNESS: the launcher.pl region under test was located and extracted -- if this fails, the 9 assertion(s) below did NOT run');
    skip "$SKIP_REASON_REGION (C8)", 9 unless defined $DECIDE;

    my $tripwire = sub { die "test touched the filesystem\n" };
    my %O = (
        registry   => {},
        extra_list => [],
        exists     => sub { 0 },
        read_file  => $tripwire,
        env        => sub { $_[0] eq 'HOME' ? '/home/u' : undef },
    );

    # ---- bare-root hint: must be rejected, not admitted ----
    {
        my $out = eval { $DECIDE->('/home/u/work/unrelated-project', { %O, live_install_hint => '/' }) };
        my $err = $@;
        ok((!$err && ref($out) eq 'HASH'), 'C8: protected_path_outcome call succeeds for the bare-root-hint case')
            or diag("error: $err");
        if (!$err && ref($out) eq 'HASH') {
            is($out->{refuse}, 0,
               "C8: a bare-root live_install_hint ('/') is REJECTED, not admitted as a protected root "
             . "-- an ordinary unrelated project is not refused because of it");
        } else {
            ok(0, "C8: refuse == 0 for the bare-root-hint case (call failed)");
        }
    }

    # ---- home-directory hint: must be rejected, not admitted ----
    {
        my $out = eval { $DECIDE->('/home/u/work/unrelated-project', { %O, live_install_hint => '/home/u' }) };
        my $err = $@;
        ok((!$err && ref($out) eq 'HASH'), 'C8: protected_path_outcome call succeeds for the home-directory-hint case')
            or diag("error: $err");
        if (!$err && ref($out) eq 'HASH') {
            is($out->{refuse}, 0,
               "C8: a home-directory live_install_hint ('/home/u', equal to the env-derived user home) is REJECTED, "
             . "not admitted as a protected root -- an ordinary unrelated project descendant of it is not refused");
        } else {
            ok(0, "C8: refuse == 0 for the home-directory-hint case (call failed)");
        }
    }

    # ---- vacuity gate: a legitimate hint IS still admitted, reason-ranked ----
    {
        my $out = eval { $DECIDE->('/home/u/ccpraxis', { %O, live_install_hint => '/home/u/ccpraxis' }) };
        my $err = $@;
        ok((!$err && ref($out) eq 'HASH'), 'C8 (vacuity gate): protected_path_outcome call succeeds for the legitimate-hint case')
            or diag("error: $err");
        if (!$err && ref($out) eq 'HASH') {
            is($out->{refuse}, 1, "C8 (vacuity gate): a legitimate live_install_hint ('/home/u/ccpraxis') IS still admitted");
            is($out->{reason}, 'ccpraxis-install', "C8 (vacuity gate): admitted hint is reason-ranked as ccpraxis-install");
            is($out->{root}, '/home/u/ccpraxis', "C8 (vacuity gate): admitted hint's root is the normalized hint itself");
        } else {
            ok(0, "C8 (vacuity gate): refuse == 1 (call failed)");
            ok(0, "C8 (vacuity gate): reason eq ccpraxis-install (call failed)");
            ok(0, "C8 (vacuity gate): root (call failed)");
        }
    }
}

# =====================================================================
# C9 -- no regression (the C6 property q03/q04 both carry): a clone outside
# the install and an ordinary project still route passthrough (refuse == 0)
# once every fix above is wired -- run through the same real call-site span
# as C1/C2/C5/C6/C7, with a legitimate (non-decoy) environment throughout.
# =====================================================================
SKIP: {
    # HARNESS GATE (coordinator): a bare `skip ... unless <extraction succeeded>`
    # would turn a FAILED EXTRACTION into 4 silent PASSES -- and the implementer is
    # about to edit launcher.pl, which is exactly what can break extraction. Assert the
    # precondition as a FAILURE first, so the suite can never go green on a region
    # this file could not even find. The skip below then only prevents a die.
    ok($CALLSITE_OK, 'C9 HARNESS: the launcher.pl region under test was located and extracted -- if this fails, the 4 assertion(s) below did NOT run');
    skip "$SKIP_REASON_CALLSITE (C9)", 4 unless $CALLSITE_OK;

    my %base = (
        claude_host_config => "$AUTH_HOME/.claude",
        auth_home           => $AUTH_HOME,
        env                 => { HOME => $AUTH_HOME },
    );

    my ($pp_unrelated, $err_u) = _run_guard(%base,
        live_ccpraxis_root => "$AUTH_HOME/ccpraxis-anchor",
        project_path        => "$ROOT/work/myproject");
    ok(defined $pp_unrelated, "C9: protected_path_outcome call succeeds for an ordinary unrelated project")
        or diag("error: " . ($err_u // 'undef'));
    if (defined $pp_unrelated) {
        is($pp_unrelated->{refuse}, 0, "C9: an ordinary unrelated project still routes passthrough (refuse == 0) with every fix wired");
    } else {
        ok(0, "C9: refuse == 0 for an ordinary unrelated project (call failed)");
    }

    my ($pp_clone, $err_c) = _run_guard(%base,
        live_ccpraxis_root => "$AUTH_HOME/ccpraxis-anchor",
        project_path        => "$ROOT/src/ccpraxis-clone");
    ok(defined $pp_clone, "C9: protected_path_outcome call succeeds for a ccpraxis clone outside the install")
        or diag("error: " . ($err_c // 'undef'));
    if (defined $pp_clone) {
        is($pp_clone->{refuse}, 0, "C9: a ccpraxis clone outside the install still routes passthrough (refuse == 0) with every fix wired");
    } else {
        ok(0, "C9: refuse == 0 for a ccpraxis clone outside the install (call failed)");
    }
}

# =====================================================================
# C10 -- read-only contracts stay green. Recorded as validation commands,
# NOT re-implemented here (t/53 and t/51 are read-only inputs to this
# package, per the spec and the coordinator's write-set):
#
#   perl plugins/sandbox/tests/t/53-refuse-protected-paths.t   # expect 298/298
#   perl plugins/sandbox/tests/t/51-protected-paths.t          # expect 266/266
#
# Both must be re-run from disk after q05 lands, never sampled mid-write
# (the q04 torn-read trap recorded in this package's ledger).
# =====================================================================

done_testing();
