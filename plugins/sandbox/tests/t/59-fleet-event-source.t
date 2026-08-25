#!/usr/bin/env perl
# s16-fleet-event-source: butler fleet + keep-awake events into the activity panel.
#
# This file is the IMMUTABLE ORACLE for blueprint sandbox-butler-overhaul,
# package s16-fleet-event-source (specs/s16-fleet-event-source-spec.md). It is
# written BLIND to any launcher.pl / LaunchLog.pm / Dashboard.pm / KeepAwake.pm
# implementation -- directly from the spec -- so it serves as an oracle rather
# than an echo of whatever the implementer eventually writes. Do NOT weaken an
# assertion to make a future implementation's life easier.
#
# Coverage: C1..C9 (spec S5).
#
# HARD CONSTRAINTS honoured here (spec S5 preamble):
#   * PURE/structural: never spawns launcher.pl, never builds an image, never
#     starts a container. launcher.pl is SLURPED for source-text assertions
#     only (t/48's established convention) -- never require'd/do'ne.
#   * Fixtures live only under File::Temp tempdir()s.
#
# PINNED INTERFACE (spec S1.1). Two symbols this package introduces are named
# in the spec so the oracle and the implementer agree rather than negotiating
# through failures:
#
#   LaunchLog::merge_by_key($sources, key => $coderef, max => $n) -> \@merged
#       The cross-source interleave. NEVER inspects an item itself -- the
#       caller's `key` coderef does, so s13's opacity guarantee survives.
#       `key` is REQUIRED: defaulting it would let a caller silently get
#       append-order-only merging while believing it was time-ordered.
#       STABLE -- equal keys, undef keys and apparent clock skew all preserve
#       each source's own relative order.
#
#   KeepAwake->new(..., on_event => sub { my (%event) = @_; ... })
#       The emit seam, matching KeepAwake's existing start/stop injection
#       style. Fires ONLY on a state transition.
#
# An earlier draft of this file GUESSED both -- eight candidate sub names under
# two calling conventions, and four candidate constructor keys. That is a
# latent false negative (an implementer who picks a ninth name has a correct
# implementation that reads as broken) and, worse, it invites name-matching
# instead of design. The spec was amended to pin them; this file asserts the
# pinned names only.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use File::Temp qw(tempdir);
use Scalar::Util qw(refaddr blessed);
use Encode qw(encode);

use_ok('Dashboard')  or BAIL_OUT('Dashboard.pm did not load');
use_ok('LaunchLog')  or BAIL_OUT('LaunchLog.pm did not load');
use_ok('KeepAwake')  or BAIL_OUT('KeepAwake.pm did not load');

my $SCRIPTS_DIR  = "$Bin/../../scripts";
my $LAUNCHER_SRC = "$SCRIPTS_DIR/launcher.pl";

# ===========================================================================
# Scaffolding
# ===========================================================================

sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return '';
    local $/;
    my $s = <$fh>;
    close $fh;
    return $s;
}

# ev_line($type, \%fields, $epoch, $pid) -> one real JSON line, never a
# hand-written JSON string (mirrors t/48's ev_line).
sub ev_line {
    my ($type, $fields, $epoch, $pid) = @_;
    return LaunchLog::format_event($type, $fields || {}, $epoch, $pid);
}

# rowtext($row) -> plain concatenated text of one Dashboard::recent_events row.
sub rowtext {
    my ($row) = @_;
    return '' unless ref($row) eq 'ARRAY';
    return Dashboard::spans_text($row);
}

# --- source-text helpers for launcher.pl (slurped, never require'd/do'ne;
#     lifted verbatim from t/48-activity-history.t's established convention) --
sub _balanced_braces {
    my ($src, $from) = @_;
    my $idx = index($src, '{', $from);
    return undef if $idx < 0;
    my $depth = 0;
    my $i     = $idx;
    my $len   = length($src);
    for (; $i < $len; $i++) {
        my $c = substr($src, $i, 1);
        if    ($c eq '{') { $depth++; }
        elsif ($c eq '}') { $depth--; last if $depth == 0; }
    }
    return undef if $depth != 0;
    return substr($src, $idx, $i - $idx + 1);
}
sub extract_sub_body {
    my ($src, $start_literal) = @_;
    my $idx = index($src, $start_literal);
    return undef if $idx < 0;
    return _balanced_braces($src, $idx);
}
sub src_like {
    my ($str, $re, $name) = @_;
    my $got = (defined $str && $str =~ $re) ? 1 : 0;
    ok($got, $name) or diag("  source did not match $re");
    return $got;
}
sub src_unlike {
    my ($str, $re, $name) = @_;
    my $got = (defined $str && $str =~ $re) ? 0 : 1;
    ok($got, $name) or diag("  source unexpectedly matched $re");
    return $got;
}

# ===========================================================================
# C3 first: compute the GENUINE generic-fallback signature via a deliberately
# invented, never-mapped kind. Used as the live reference point for C1/C2's
# "this kind got a REAL mapping, not the fallback" assertions below, so
# nothing here hardcodes a fallback color literal that could rot.
# ===========================================================================
my $INVENTED_KIND = 's16_zzz_never_mapped_kind_' . $$ . '_' . time();
my ($fallback_role, $fallback_glyph) = Dashboard::event_style($INVENTED_KIND, undef, undef);
ok(defined($fallback_role) && defined($fallback_glyph),
    'C3 setup: event_style(invented kind) returns a defined (role, glyph) -- never dropped');

{
    my $line = ev_line($INVENTED_KIND, {}, 1_700_000_000, 111);
    my $ev   = Dashboard::recent_events([$line], 10);
    is(ref($ev), 'ARRAY', 'C3: recent_events does not die/crash on an invented, never-mapped kind');
    is(scalar(@$ev), 1, 'C3: the invented-kind event is NOT dropped (exactly one row emitted)');
    if (ref($ev) eq 'ARRAY' && @$ev) {
        like(rowtext($ev->[0]), qr/\Q$INVENTED_KIND\E/, 'C3: the invented kind text survives into the row');
    } else {
        fail('C3: the invented kind text survives into the row');
    }
}

# ===========================================================================
# C1 -- orchestrator.log kinds appear via the extended classifier, with a
# vacuity gate (a launch-log-only feed of an ORDINARY pre-existing kind still
# renders exactly as before -- proves the assertions below are about the NEW
# source, not "recent_events produces output at all").
# ===========================================================================
{
    # Vacuity gate: a pre-existing, already-classified kind is untouched.
    my $line = ev_line('container_start', {}, 1_700_000_000, 200);
    my $ev   = Dashboard::recent_events([$line], 10);
    is(ref($ev), 'ARRAY', 'C1 vacuity: recent_events still handles a pre-existing kind');
    is(scalar(@$ev), 1, 'C1 vacuity: pre-existing kind still yields exactly one row') if ref($ev) eq 'ARRAY';
}

# Butler kinds that do NOT already match Dashboard::event_style's pre-existing
# regexes (verified by hand against Dashboard.pm:725-738: none end in
# _failed/_failure/_error/_gone/_dead, none are heartbeat/tick, none end in
# _start/_create/_launch(ed) with an underscore-or-string-start boundary) --
# so a role DIFFERENT from the invented-kind fallback can ONLY come from a
# genuine new mapping landed by this package. This is the assertion that
# actually exercises s16's classifier extension rather than pre-existing s06
# regex coverage.
my @NEEDS_NEW_MAPPING = qw(watchdog_relaunch pkg_finished pause checkpoint notice review
                            broken-env turn-starved acquire release);
for my $kind (@NEEDS_NEW_MAPPING) {
    my ($role, $glyph) = Dashboard::event_style($kind, undef, undef);
    ok(defined($role) && defined($glyph), "C1: event_style('$kind') returns a defined (role, glyph)");
    my $same_as_fallback = (defined($role) && defined($glyph)
        && $role eq $fallback_role && $glyph eq $fallback_glyph) ? 1 : 0;
    is($same_as_fallback, 0,
        "C1: event_style('$kind') differs from the generic (invented-kind) fallback -- a real mapping exists");
}

# Kinds already covered by s06's pre-existing regexes (pkg_failed,
# checkpoint_failed, creds_error, launch_failed, fleet_launched, launch,
# orchestrator_start) -- included as a plain roles/glyphs-are-sane regression
# guard, NOT as evidence of new s16 work (they'd pass before s16 too).
for my $kind (qw(pkg_failed checkpoint_failed creds_error launch_failed)) {
    my ($role, $glyph) = Dashboard::event_style($kind, undef, undef);
    is($role, 'bad', "C1 regression: event_style('$kind') is 'bad' (pre-existing _failed/_error suffix match)");
}
for my $kind (qw(fleet_launched launch orchestrator_start)) {
    my ($role, $glyph) = Dashboard::event_style($kind, undef, undef);
    is($role, 'accent', "C1 regression: event_style('$kind') is 'accent' (pre-existing _launch(ed)/start suffix match)");
}

# "pause (carrying its reason)" -- spec S3 explicitly calls this out: the
# reason text must actually reach the rendered row, which recent_events does
# NOT do today for any field but exit/state.
{
    my $line = ev_line('pause', { reason => 'creds-needed-s16-marker' }, 1_700_000_000, 210);
    my $ev   = Dashboard::recent_events([$line], 10);
    my $text = (ref($ev) eq 'ARRAY' && @$ev) ? rowtext($ev->[0]) : '';
    like($text, qr/creds-needed-s16-marker/, "C1: pause's reason field is carried into the rendered row");
}

# ===========================================================================
# C2 -- keep-awake acquire/release: classifier + "appear" (kind-level, does
# not depend on KeepAwake.pm's exact emit mechanism) plus the KeepAwake.pm
# transition-only emit itself (candidate-coderef heuristic, see header note).
# ===========================================================================
{
    for my $kind (qw(acquire release)) {
        my $line = ev_line($kind, {}, 1_700_000_000, 300);
        my $ev   = Dashboard::recent_events([$line], 10);
        is(ref($ev) eq 'ARRAY' ? scalar(@$ev) : -1, 1, "C2: a bare '$kind' event line appears as exactly one row");
    }
}
{
    my @fired;
    my $collect = sub { push @fired, [@_]; };
    my $obj = eval {
        # PINNED by spec S1.1: the emit seam is the constructor coderef
        # `on_event`, matching KeepAwake's existing start/stop injection style.
        # This previously wired FOUR candidate keys at one collector and hoped
        # the implementer picked one of them -- a guess that would read a
        # spec-faithful implementation as broken if it chose a fifth name.
        KeepAwake->new(
            start    => sub { return 'HANDLE'; },
            stop     => sub { },
            on_event => $collect,
        );
    };
    ok(defined($obj) && !$@, 'C2 setup: a KeepAwake object accepts the pinned on_event emit seam');

    my $a1 = $obj->sync(1);   # acquire: a transition
    my $a2 = $obj->sync(1);   # already held: NOT a transition
    my $a3 = $obj->sync(1);   # already held again: NOT a transition
    my $a4 = $obj->sync(0);   # release: a transition

    # Positive gate: sync()'s own pre-existing transition-only return-value
    # contract (unchanged by this package) -- proves the SEQUENCE below really
    # does model "acquire once, repeat twice, release once".
    is_deeply([$a1, $a2, $a3, $a4], ['start', 'noop', 'noop', 'stop'],
        'C2 setup: sync() return-value contract confirms the exercised sequence is acquire,repeat,repeat,release');

    is(scalar(@fired), 2,
        'C2: a candidate emit seam fires exactly twice across [sync(1),sync(1),sync(1),sync(0)] -- transition only, no duplicate-noise on repeated sync(1) while already held');
}

# ===========================================================================
# C4 -- the ordering ruling (spec S1), as three separate properties, using
# deliberately OPAQUE items (blessed scalar refs with NO usable field of
# their own) so a helper that peeked inside an item -- rather than using the
# caller's key-extractor coderef -- would die outright on these fixtures.
# ===========================================================================
my %KEY_FOR;   # refaddr(item) -> sort key, populated as items are minted
my $next_id = 0;
sub opaque_item {
    my ($label, $key) = @_;
    my $payload = "s16-opaque-$label-" . (++$next_id);
    my $item = bless \$payload, 'S16::OpaqueItem';
    $KEY_FOR{ refaddr($item) } = $key;
    return $item;
}
my $KEYFN = sub {
    my ($it) = @_;
    return undef unless blessed($it) && $it->isa('S16::OpaqueItem');
    return $KEY_FOR{ refaddr($it) };
};

# PINNED INTERFACE (spec S1.1), replacing an earlier candidate-name search.
#
# This originally guessed across eight plausible sub names under two calling
# conventions. That is a latent FALSE NEGATIVE -- an implementer who picks a
# ninth name has a correct implementation that reads as broken -- and worse, it
# invites name-matching instead of design. The spec now pins the name and the
# signature, exactly as b24's oracle pins its BpWait:: surface, so the oracle
# and the implementer agree instead of negotiating through failures.
#
#   LaunchLog::merge_by_key($sources, key => $coderef, max => $n) -> \@merged
#
# `key` is REQUIRED by the spec: defaulting it would let a caller silently get
# append-order-only merging while believing it was time-ordered.
use constant CROSS_MERGE_SUB => 'LaunchLog::merge_by_key';

# try_cross_merge(\@sources, $keyfn, %extra) -> \@merged | undef.
# Calls the PINNED sub only. Returns undef when it is absent or returns a
# result whose element count does not match the input (a sanity gate before
# any ORDERING claim about it is trusted).
sub try_cross_merge {
    my ($sources, $keyfn, %extra) = @_;
    my $want_n = 0;
    $want_n += scalar(@$_) for @$sources;
    no strict 'refs';
    my $fq = CROSS_MERGE_SUB;
    return undef unless defined &{$fq};
    # Take the coderef FIRST. `\&{$fq}->(...)` parses as `\( &{$fq}->(...) )` --
    # it calls the sub and then takes a reference to the RESULT, so the arrayref
    # check below sees a REF and a perfectly correct implementation reads as
    # missing. That precedence trap was introduced here while removing a
    # candidate-name search whose whole purpose was avoiding false negatives.
    my $cr = \&{$fq};
    my $r = eval { $cr->($sources, key => $keyfn, %extra) };
    return undef if $@;
    return (ref($r) eq 'ARRAY' && scalar(@$r) == $want_n) ? $r : undef;
}

# --- C4a: within-source append order preserved even with a non-monotonic
#     clock -- a source whose own timestamps jump backwards mid-file must not
#     have ITS OWN items reordered relative to each other.
{
    my $x1 = opaque_item('x1', 500);   # appended 1st, key 500
    my $x2 = opaque_item('x2', 100);   # appended 2nd, key JUMPS BACKWARD to 100
    my $x3 = opaque_item('x3', 300);   # appended 3rd, key 300 (still not monotonic)
    my $merged = try_cross_merge([ [ $x1, $x2, $x3 ] ], $KEYFN);
    ok(defined($merged), 'C4a: the cross-source helper produced a result for a single non-monotonic source')
        or diag('  (LaunchLog::merge_by_key absent or wrong shape -- pinned by spec S1.1)');
    if (ref($merged) eq 'ARRAY') {
        my @idx = map { my $r = $_; (grep { $merged->[$_] == $r } (0 .. $#$merged))[0] } ($x1, $x2, $x3);
        is_deeply(\@idx, [ sort { $a <=> $b } @idx ],
            'C4a: x1,x2,x3 keep their ORIGINAL append order in the output despite non-monotonic keys');
        is(scalar(@$merged), 3, 'C4a: single-source count is preserved exactly (3 in, 3 out)');
    } else {
        fail('C4a: x1,x2,x3 keep their ORIGINAL append order in the output despite non-monotonic keys');
        fail('C4a: single-source count is preserved exactly (3 in, 3 out)');
    }
}

# --- C4b: across sources with SANE clocks, events interleave by time.
{
    my $s1a = opaque_item('s1a', 100);
    my $s1b = opaque_item('s1b', 101);
    my $s1c = opaque_item('s1c', 102);
    my $s2a = opaque_item('s2a', 100.5);
    my $s2b = opaque_item('s2b', 101.5);
    my $merged = try_cross_merge([ [ $s1a, $s1b, $s1c ], [ $s2a, $s2b ] ], $KEYFN);
    if (ref($merged) eq 'ARRAY' && scalar(@$merged) == 5) {
        my @keys = map { $KEYFN->($_) } @$merged;
        my @sorted = sort { $a <=> $b } @keys;
        is_deeply(\@keys, \@sorted, 'C4b: sane-clock cross-source events interleave in ascending time order');
    } else {
        fail('C4b: sane-clock cross-source events interleave in ascending time order');
    }
}

# --- C4c: across sources with a SKEWED (non-monotonic) clock on one side,
#     each source's own internal order still holds even though a PLAIN
#     timestamp sort would scramble it. a1 (key 1000, appended FIRST in its
#     source) must still precede a2 (key 100, appended SECOND) in the output,
#     even though key(a1) > key(a2) -- a naive `sort by key` would place a2
#     before a1, which is exactly the bug S1 rules out.
{
    my $a1 = opaque_item('a1', 1000);   # container-clock source, appended 1st
    my $a2 = opaque_item('a2', 100);    # same source, appended 2nd, clock skewed backward
    my $b1 = opaque_item('b1', 500);    # host-clock source, sane, lands between a1/a2 by key
    my $merged = try_cross_merge([ [ $a1, $a2 ], [ $b1 ] ], $KEYFN);
    if (ref($merged) eq 'ARRAY' && scalar(@$merged) == 3) {
        my ($idx_a1) = grep { $merged->[$_] == $a1 } (0 .. $#$merged);
        my ($idx_a2) = grep { $merged->[$_] == $a2 } (0 .. $#$merged);
        ok(defined($idx_a1) && defined($idx_a2) && $idx_a1 < $idx_a2,
            'C4c: a1 (appended first, higher key) still precedes a2 (appended second, lower key) -- '
            . 'a plain timestamp sort would have reversed them');
    } else {
        fail('C4c: a1 (appended first, higher key) still precedes a2 (appended second, lower key) -- '
            . 'a plain timestamp sort would have reversed them');
    }
}

# ===========================================================================
# C5 -- merge_sessions is UNCHANGED: same signature/behaviour, still opaque
# (never inspects an item), plus the new cross-source helper takes its sort
# key from a caller-supplied coderef (proven by the C4 fixtures above: those
# opaque items have NO usable field of their own -- only $KEYFN can read
# them, so the helper resolved above provably never inspected an item
# itself).
# ===========================================================================
{
    my $x1 = opaque_item('m1', 1);
    my $x2 = opaque_item('m2', 2);
    my $y1 = opaque_item('m3', 3);
    my $M  = 'MARKER-s16';
    my $r  = eval { LaunchLog::merge_sessions([ [ $x1, $x2 ], [ $y1 ] ], max => 50, marker => $M) };
    ok(!$@, 'C5: merge_sessions still runs without dying on wholly-opaque blessed-scalar-ref items (never inspects them)')
        or diag("  \$\@ = $@");
    is_deeply($r, [ $x1, $x2, $M, $y1 ],
        'C5: merge_sessions is unchanged -- pure concatenation in group order, no reordering by any key');
}
{
    # C9-adjacent recorded validation command (not re-implemented here): the
    # sibling package's own oracle must independently confirm merge_sessions
    # stayed green. See report.
    pass('C5: s13\'s own merge_sessions oracle (t/48-activity-history.t) is recorded as a validation command, not reimplemented here');
}

# ===========================================================================
# C6 -- untrusted event strings are sanitized before display, with a vacuity
# gate (ordinary text passes through unmangled).
# ===========================================================================
{
    my $ordinary = 'a perfectly ordinary reason string';
    my $line     = ev_line('pause', { reason => $ordinary }, 1_700_000_000, 400);
    my $ev       = Dashboard::recent_events([$line], 10);
    my $text     = (ref($ev) eq 'ARRAY' && @$ev) ? rowtext($ev->[0]) : '';
    like($text, qr/\Q$ordinary\E/, 'C6 vacuity: ordinary event text passes through unmangled');
}
{
    my $hostile = ("innocuous\x1b[31mBOOM\x07\x00" x 200);   # ESC/BEL/NUL, and oversized (~4000 bytes)
    my $line    = ev_line('pause', { reason => $hostile }, 1_700_000_000, 401);
    my $ev      = Dashboard::recent_events([$line], 10);
    my $text    = (ref($ev) eq 'ARRAY' && @$ev) ? rowtext($ev->[0]) : '';
    unlike($text, qr/\x1b/, 'C6: a raw ESC byte from an untrusted event field never reaches the rendered row');
    unlike($text, qr/\x07/, 'C6: a raw BEL byte from an untrusted event field never reaches the rendered row');
    ok(length($text) < length($hostile),
        'C6: an oversized untrusted field is bounded, not emitted verbatim (rendered row shorter than the input)');
}

# ===========================================================================
# C7 -- every orchestrator-source failure mode degrades to no orchestrator
# events AND a working dashboard. The file-location/open half of this is
# private to launcher.pl (_gather_orchestrator_events) and is asserted as
# source text below (mirroring _history_events' established degrade posture,
# t/48's own precedent for the same class of concern). The downstream-
# rendering half (malformed JSONL, empty input) is asserted executably via
# the shared Dashboard::recent_events machinery the spec requires the new
# gather sub to reuse, PLUS a positive gate that the dashboard still composes
# a real panel set with zero orchestrator events.
# ===========================================================================
{
    my @cases = (
        [ 'malformed JSONL' => [ 'not-json-{{{garbage' ] ],
        [ 'empty input'     => [] ],
        [ 'blank lines'     => [ '', '   ', "\n" ] ],
    );
    for my $c (@cases) {
        my ($label, $lines) = @$c;
        my $ev;
        my $ok = eval { $ev = Dashboard::recent_events($lines, 10); 1 };
        my $err = $@;
        ok($ok, "C7: recent_events does not die on $label") or diag("  \$\@ = $err");
        is(ref($ev), 'ARRAY', "C7: recent_events($label) still returns an arrayref (degrades, does not vanish)");
    }
    # Positive gate: the dashboard still renders a full panel set with ZERO
    # orchestrator events -- degrading is only correct if what remains works.
    # RE-POINTED to the LIVE panel builder (tui::DashboardScreen::panels), which
    # returns an ARRAYREF. Dashboard::build_panels was deleted: unreachable since
    # compose_frame began delegating, and drifted to a Token/Spend panel set that
    # no longer renders at all.
    my $panels = tui::DashboardScreen::panels({ project_name => 'demo', container => 'c1', status => 'running', events => [] }, 80);
    ok(ref($panels) eq 'ARRAY' && @$panels > 0, 'C7 positive gate: the panel builder still renders a real panel set when there are zero orchestrator events');
    my ($activity) = grep { ref($_) eq 'HASH' && ($_->{title} || '') eq 'Recent activity' } @$panels;
    ok(defined($activity), 'C7 positive gate: the Activity panel itself is still present');
}
{
    my $src = slurp($LAUNCHER_SRC);
    ok(length($src) > 0, 'C7 setup: launcher.pl was read as source text') or BAIL_OUT('cannot read launcher.pl');

    my $has_gather_sub = ($src =~ /sub\s+_gather_orchestrator_events\b/) ? 1 : 0;
    ok($has_gather_sub, 'C7: launcher.pl defines _gather_orchestrator_events')
        or diag('  0 of the following C7/C8 source-text assertions can be meaningful without this sub existing');

    SKIP: {
        skip('_gather_orchestrator_events not found in launcher.pl -- degrade/caps assertions below are moot until it exists', 6)
            unless $has_gather_sub;

        my $body = extract_sub_body($src, 'sub _gather_orchestrator_events');
        ok(defined($body), 'C7: the sub body is balanced-brace extractable from source text')
            or diag('  0 of the remaining 5 assertions in this block ran');

        SKIP: {
            skip('sub body not extractable', 5) unless defined $body;
            src_like($body, qr/\beval\s*\{/,
                'C7: _gather_orchestrator_events wraps its work in eval, mirroring _history_events\' degrade-on-any-failure posture');
            src_unlike($body, qr/\bdie\b/,
                'C7: _gather_orchestrator_events contains no unguarded die (a missing fleet run must never crash the dashboard)');
            src_like($body, qr/Dashboard::recent_events\s*\(/,
                'C7/C1: _gather_orchestrator_events pipes lines through Dashboard::recent_events (classification/sanitization happen in one place)');
            src_like($body, qr/orchestrator\.log/,
                'C7 setup: the sub actually names orchestrator.log as its target file');
            src_like($body, qr/ccpraxis-local-data/,
                'C7 setup: the sub locates the log under the project\'s .ccpraxis-local-data (host-visible, per spec S2)');
        }
    }
}

# ===========================================================================
# C8 -- no new per-tick cost: named constants (not literals) for the caps,
# and the log is read at most once per tick. Source-text, for the reasons
# given in the C7 block above.
# ===========================================================================
{
    my $src = slurp($LAUNCHER_SRC);
    my $body = ($src =~ /sub\s+_gather_orchestrator_events\b/) ? extract_sub_body($src, 'sub _gather_orchestrator_events') : undef;

    SKIP: {
        skip('_gather_orchestrator_events not found/extractable -- see C7 block above for the hard failure', 3)
            unless defined $body;

        src_unlike($body, qr/_tail_lines\s*\(\s*\$\w+\s*,\s*\d+\s*\)/,
            'C8: the tail-lines cap passed to _tail_lines is a NAMED CONSTANT, not a bare numeric literal');
        src_unlike($body, qr/Dashboard::recent_events\s*\(\s*\\?\@?\$?\w+\s*,\s*\d+\s*\)/,
            'C8: the events-per-log cap passed to Dashboard::recent_events is a NAMED CONSTANT, not a bare numeric literal');

        my $tail_calls = () = ($body =~ /_tail_lines\s*\(/g);
        is($tail_calls <= 1 ? 1 : 0, 1,
            'C8: the orchestrator log file is tailed at most once within the gather sub (no double-read per tick)');
    }
}

# ===========================================================================
# C9 -- no regression, recorded as validation commands (not re-implemented
# here, per spec S5): s06's t/41-panel-semantics.t and s13's
# t/48-activity-history.t. See report for the exact run + exit code.
# ===========================================================================
pass('C9: no-regression is recorded via the validation commands `perl plugins/sandbox/tests/t/41-panel-semantics.t` '
    . 'and `perl plugins/sandbox/tests/t/48-activity-history.t` (see report), not reimplemented in this file');

done_testing();
