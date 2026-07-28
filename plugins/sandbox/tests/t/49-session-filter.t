#!/usr/bin/env perl
# s14-session-filter — unit + end-to-end tests for the butler-session filter.
# Spec: /project/.ccpraxis-local-data/blueprints/sandbox-butler-overhaul/specs/11-session-filter-spec.md
#
#   DC-1 = SessionFilter.pm pure tests (classification + malformed-registry
#          robustness)                                          -- §4.2, AC-1..AC-6
#   DC-2 = picker hides by default + toggle + footer + empty-view line
#                                                        -- §4.3/§4.4, AC-7..AC-17
#   DC-3 = no regression; t/21+t/29 green; this file covers the classifier +
#          picker filter/toggle                                  -- throughout
#
# IMPORTANT: SessionFilter.pm does not exist yet, and select-session.pl has not
# been given filter_options / footer_text / empty_view_note / show_empty_note /
# derive_blueprints_dir / is_butler-tagged build_options yet. This file is
# written from the spec only (no implementation was read). Every criterion
# below is therefore EXPECTED to fail right now:
#   - "Can't locate .../SessionFilter.pm" (module missing), or
#   - "Undefined subroutine &SessionFilter::foo" / "&main::foo" (module/script
#     present but the specific sub doesn't exist yet), or
#   - a plain wrong-value assertion failure (e.g. build_options exists today
#     but doesn't tag is_butler yet).
# criterion() below turns the first two failure modes into ONE explicit
# failing Test::More assertion (instead of letting an uncaught die abort the
# whole file), so every criterion still gets a chance to run and report its
# own result independently. Once the real implementation exists, criterion()
# is a no-op wrapper and every assertion inside runs and scores normally.

use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use Storable qw(dclone);
use Time::HiRes qw(time);

# ---------------------------------------------------------------------------
# Load the two things under test.
# ---------------------------------------------------------------------------

my $sf_path = "$Bin/../../scripts/SessionFilter.pm";
my $HAVE_SF = eval { require $sf_path; 1 };
my $SF_LOAD_ERR = $@;
ok($HAVE_SF, "SessionFilter.pm loads via require '$sf_path' (prerequisite for AC-1..AC-6)")
    or diag("load error was: $SF_LOAD_ERR");

my $script = "$Bin/../../scripts/select-session.pl";
ok(-f $script, 'select-session.pl exists') or BAIL_OUT('select-session.pl is missing');
require $script;   # guarded by `unless (caller)`; must not run main()
pass('require of select-session.pl did not run main() (needed for AC-7..AC-13 pure-helper calls)');

# ---------------------------------------------------------------------------
# criterion($name, $coderef) — see file header for rationale.
# ---------------------------------------------------------------------------
sub criterion {
    my ($name, $code) = @_;
    my $ok = eval { $code->(); 1 };
    if (!$ok) {
        my $err = $@;
        $err = 'unknown error' unless length $err;
        $err =~ s/\s+\z//;
        fail("$name -- DIED (missing behavior): $err");
    }
    return;
}

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

sub write_file {
    my ($path, $content) = @_;
    open my $fh, '>:raw', $path or die "write_file($path): $!";
    print $fh $content;
    close $fh;
}

# §4.1 — the shared fixture registry tree. Built fresh per criterion so each
# one is independent of the others' filesystem state.
sub build_fixture_registry_root {
    my $root = tempdir(CLEANUP => 1);

    make_path("$root/bp-alpha/runs");
    write_file("$root/bp-alpha/runs/registry.json",
        '{"packages":{"p1":{"session_id":"aaaaaaaa-1111-2222-3333-444444444444","status":"done"},"p2":{"session_id":"BBBBBBBB-1111-2222-3333-444444444444"}}}');

    make_path("$root/bp-beta/runs");
    write_file("$root/bp-beta/runs/registry.json",
        '{"packages":{"q1":{"session_id":"cccccccc-1111-2222-3333-444444444444"},"q2":{"session_id":""},"q3":{"status":"pending"},"q4":{"session_id":null},"q5":"not-an-object","q6":{"session_id":{"nested":1}}}}');

    make_path("$root/bp-broken/runs");
    write_file("$root/bp-broken/runs/registry.json", '{not json at all');

    make_path("$root/bp-nopack/runs");
    write_file("$root/bp-nopack/runs/registry.json", '{"version":1}');

    make_path("$root/bp-arraypack/runs");
    write_file("$root/bp-arraypack/runs/registry.json", '{"packages":[1,2,3]}');

    make_path("$root/bp-toplevel-array/runs");
    write_file("$root/bp-toplevel-array/runs/registry.json", '["a","b"]');

    make_path("$root/bp-empty/runs");
    write_file("$root/bp-empty/runs/registry.json", '');

    make_path("$root/bp-norun");   # directory only, no runs/

    write_file("$root/loose-file.txt", "just a file\n");

    return $root;
}

my @EXPECTED_BUTLER_SIDS = sort qw(
    aaaaaaaa-1111-2222-3333-444444444444
    bbbbbbbb-1111-2222-3333-444444444444
    cccccccc-1111-2222-3333-444444444444
);

# E2E session-dir / registry-root builders (§4.4).
sub build_sessions_dir {
    my (@specs) = @_;   # list of { uuid => ..., age => <seconds old> }
    my $dir = tempdir(CLEANUP => 1);
    for my $s (@specs) {
        my $path = "$dir/$s->{uuid}.jsonl";
        open my $w, '>', $path or die "build_sessions_dir: $!";
        print $w qq({"type":"permission-mode","sessionId":"$s->{uuid}"}\n);
        print $w qq({"type":"user","message":{"role":"user","content":"prose prompt for $s->{uuid}"},"sessionId":"$s->{uuid}","cwd":"/project"}\n);
        close $w;
        my $mtime = time - $s->{age};
        utime($mtime, $mtime, $path) or die "build_sessions_dir: utime: $!";
    }
    return $dir;
}

sub build_registry_root {
    my (@uuids) = @_;   # each becomes one package's session_id in one blueprint
    my $root = tempdir(CLEANUP => 1);
    make_path("$root/bp-e2e/runs");
    my $i = 0;
    my @entries;
    for my $u (@uuids) {
        $i++;
        push @entries, qq("pkg$i":{"session_id":"$u"});
    }
    write_file("$root/bp-e2e/runs/registry.json", '{"packages":{' . join(',', @entries) . '}}');
    return $root;
}

# Drives select-session.pl through the non-TTY line-prompt fallback, exactly
# like t/21-select-session-multiple.t's pattern
# (`open my $p, "| $cmd > /dev/null 2>&1"`), but captures STDERR to a file
# (needed for AC-15's menu-text assertions) instead of discarding it, and
# optionally appends --blueprints-dir.
sub run_picker {
    my (%a) = @_;
    my $sessions_dir = $a{sessions_dir};
    my $out          = $a{out};
    my $input        = $a{input} // '';

    my $cmd = qq("$^X" "$script" --sessions-dir "$sessions_dir" --output "$out");
    $cmd .= qq( --blueprints-dir "$a{blueprints_dir}") if exists $a{blueprints_dir};

    my (undef, $err_file) = tempfile(DIR => $sessions_dir, SUFFIX => '.stderr');

    open my $p, "| $cmd >\"$err_file\" 2>&1" or die "run_picker: open pipe failed: $!";
    print $p $input;
    close $p;
    my $rc = $? >> 8;

    my $content;
    if (open my $rfh, '<', $out) {
        local $/;
        $content = <$rfh>;
        close $rfh;
    }
    # NOTE: chomp() is a no-op while $/ is locally undef (slurp mode), so the
    # trailing "\n" written by write_action() is stripped with a regex here,
    # outside that scope, instead.
    $content =~ s/\r?\n\z// if defined $content;

    my $stderr = '';
    if (open my $efh, '<', $err_file) {
        local $/;
        $stderr = <$efh>;
        close $efh;
    }

    return { content => $content, rc => $rc, stderr => $stderr };
}

# =============================================================================
# §4.2 — The classifier (DC-1)
# =============================================================================

criterion('AC-1 -> DC-1: registry_paths() returns exactly the 7 present registries, sorted, and () for bad roots', sub {
    my $root = build_fixture_registry_root();
    my @paths = SessionFilter::registry_paths($root);
    my @expected = map { "$root/$_/runs/registry.json" }
        sort qw(bp-alpha bp-arraypack bp-beta bp-broken bp-empty bp-nopack bp-toplevel-array);
    is_deeply(\@paths, \@expected,
        'registry_paths: exactly the 7 present registries, sorted by blueprint dir name');
    ok(!(grep { m{/bp-norun/} } @paths), 'bp-norun (directory only, no runs/) contributes nothing');
    ok(!(grep { /loose-file\.txt/ } @paths), 'loose-file.txt (not a directory) is skipped');

    is_deeply([SessionFilter::registry_paths(undef)],                       [], 'undef root -> ()');
    is_deeply([SessionFilter::registry_paths('')],                          [], 'empty-string root -> ()');
    is_deeply([SessionFilter::registry_paths("$root/does-not-exist")],      [], 'nonexistent root -> ()');
    is_deeply([SessionFilter::registry_paths("$root/bp-alpha/runs/registry.json")], [],
        'a path to a plain FILE (not a dir) -> ()');
});

criterion('AC-2 -> DC-1: collect_butler_sids returns exactly the 3 expected UUIDs; a corrupt sibling does not suppress valid ones', sub {
    my $root = build_fixture_registry_root();
    my $sids = SessionFilter::collect_butler_sids($root);
    is(ref $sids, 'HASH', 'collect_butler_sids returns a hashref');
    my @got = sort keys %$sids;
    is_deeply(\@got, \@EXPECTED_BUTLER_SIDS,
        'collect_butler_sids: exactly the 3 expected lowercase UUIDs (bp-broken does not suppress bp-alpha/bp-beta)');
});

criterion('AC-3 -> DC-1: case + shape normalization; malformed beta entries contribute nothing', sub {
    my $root = build_fixture_registry_root();
    my $sids = SessionFilter::collect_butler_sids($root);
    is(scalar(keys %$sids), 3, 'exactly 3 keys total (q2/q3/q4/q5/q6 in bp-beta contribute nothing)');
    ok(exists $sids->{'bbbbbbbb-1111-2222-3333-444444444444'},
        'the uppercase BBBBBBBB-... fixture value is stored lowercase');
    is(SessionFilter::is_butler_session('bbbbbbbb-1111-2222-3333-444444444444', $sids), 1,
        'lowercase query matches the stored (lowercase) SID');
    is(SessionFilter::is_butler_session('BBBBBBBB-1111-2222-3333-444444444444', $sids), 1,
        'uppercase query still matches (case-insensitive)');
    is(SessionFilter::is_butler_session('', $sids), 0, "empty-string uuid -> 0");
});

criterion('AC-4 -> DC-1 (never dies): sids_from_registry_file returns () and never dies/warns, over every malformed shape', sub {
    my @cases = (
        ['path is undef',                      undef],
        ['path is a directory (not a file)',   tempdir(CLEANUP => 1)],
        ['0-byte file', do { my (undef, $p) = tempfile(); write_file($p, ''); $p }],
        ['file larger than MAX_REGISTRY_BYTES (4 MiB)',
            do { my (undef, $p) = tempfile(); write_file($p, 'x' x (4 * 1024 * 1024 + 1024)); $p }],
        ['malformed JSON (truncated object)',  do { my (undef, $p) = tempfile(); write_file($p, '{not json at all'); $p }],
        ['top-level array',                    do { my (undef, $p) = tempfile(); write_file($p, '["a","b"]'); $p }],
        ['top-level string',                   do { my (undef, $p) = tempfile(); write_file($p, '"hello"'); $p }],
        ['top-level number',                   do { my (undef, $p) = tempfile(); write_file($p, '42'); $p }],
        ['top-level null',                     do { my (undef, $p) = tempfile(); write_file($p, 'null'); $p }],
        ['object with no "packages" key',      do { my (undef, $p) = tempfile(); write_file($p, '{"version":1}'); $p }],
        ['"packages" is an array',              do { my (undef, $p) = tempfile(); write_file($p, '{"packages":[1,2,3]}'); $p }],
        ['"packages" is a string',              do { my (undef, $p) = tempfile(); write_file($p, '{"packages":"nope"}'); $p }],
        ['"packages" is a number',              do { my (undef, $p) = tempfile(); write_file($p, '{"packages":42}'); $p }],
        ['"packages" is null',                  do { my (undef, $p) = tempfile(); write_file($p, '{"packages":null}'); $p }],
    );

    for my $case (@cases) {
        my ($desc, $path) = @$case;
        my $warn_count = 0;
        local $SIG{__WARN__} = sub { $warn_count++ };
        my @res = eval { SessionFilter::sids_from_registry_file($path) };
        is($@, '', "sids_from_registry_file [$desc]: does not die");
        is_deeply(\@res, [], "sids_from_registry_file [$desc]: returns ()");
        is($warn_count, 0, "sids_from_registry_file [$desc]: emits no warnings");
    }

    # NOTE: the §2.3 table's "unreadable (open fails)" sub-case is not
    # independently exercised here — this suite runs as root inside the
    # sandbox container, where CAP_DAC_OVERRIDE bypasses permission bits, so
    # a chmod-0 fixture would not actually reproduce an open() failure. The
    # "path is a directory" case above exercises the same `return () unless
    # ... -f $path` guard clause.

    my @extra = (
        ["collect_butler_sids(undef)",              undef],
        ["collect_butler_sids('')",                 ''],
        ["collect_butler_sids('/no/such/dir')",      '/no/such/dir'],
        ["collect_butler_sids(empty tempdir)",       tempdir(CLEANUP => 1)],
    );
    for my $case (@extra) {
        my ($desc, $arg) = @$case;
        my $warn_count = 0;
        local $SIG{__WARN__} = sub { $warn_count++ };
        my $sids = eval { SessionFilter::collect_butler_sids($arg) };
        is($@, '', "$desc: does not die");
        is(ref($sids) eq 'HASH' ? 1 : 0, 1, "$desc: returns a hashref");
        is(ref($sids) eq 'HASH' ? scalar(keys %$sids) : -1, 0, "$desc: hashref has 0 keys");
        is($warn_count, 0, "$desc: emits no warnings");
    }
});

# ---------------------------------------------------------------------------
# Red-team MEDIUM-1 regression (perf, not a numbered AC): quadratic regex
# backtracking in _norm_sid's whitespace trim (`$v =~ s/^\s+|\s+$//g;`,
# SessionFilter.pm ~line 85). A session_id value with a large *interior*
# whitespace run flanked by non-whitespace characters on BOTH sides forces
# the regex engine to backtrack through the whole run at nearly every
# starting position -- O(n^2). Independently measured by the red-team and
# the coordinator at ~8s for a ~200KB such value (and ~50 minutes
# extrapolated for a value just under the 4 MiB MAX_REGISTRY_BYTES cap). The
# fix (a length-cap applied before the trim) lands in a following implementer
# dispatch -- this block is deliberately non-deterministic-only (it asserts
# wall-clock time, unlike every other assertion in this file) and is
# EXPECTED to fail (slowly) until that fix exists.
criterion('MEDIUM-1 regression -> DC-1: sids_from_registry_file does not exhibit O(n^2) backtracking on a pathological interior-whitespace session_id', sub {
    my $huge_sid = 'a' . (' ' x 200_000) . 'b';
    my $root = tempdir(CLEANUP => 1);
    make_path("$root/bp-pathological/runs");
    my $reg_path = "$root/bp-pathological/runs/registry.json";
    write_file($reg_path, qq({"packages":{"p1":{"session_id":"$huge_sid"}}}));

    my $t0 = Time::HiRes::time();
    my @res = SessionFilter::sids_from_registry_file($reg_path);
    my $elapsed = Time::HiRes::time() - $t0;

    is_deeply(\@res, [],
        'a 200,002-char all-whitespace-padded, non-hex session_id does not match the UUID-shape regex -> ()');
    ok(($elapsed < 2),
        "sids_from_registry_file completes in under 2s even with a pathological interior-whitespace session_id (took ${elapsed}s)");
});

criterion('AC-5 -> DC-1: is_butler_session contract table', sub {
    my $root = build_fixture_registry_root();
    my $sids = SessionFilter::collect_butler_sids($root);
    my $known = 'aaaaaaaa-1111-2222-3333-444444444444';

    is(SessionFilter::is_butler_session($known, $sids), 1, 'known registered uuid -> 1');
    is(SessionFilter::is_butler_session('99999999-0000-0000-0000-000000000000', $sids), 0,
        'a uuid not present in any registry classifies as a user session -> 0');
    is(SessionFilter::is_butler_session(undef, $sids), 0, 'undef uuid -> 0');
    is(SessionFilter::is_butler_session('', $sids), 0, 'empty-string uuid -> 0');
    is(SessionFilter::is_butler_session('not-a-uuid', $sids), 0, 'non-UUID-shaped uuid -> 0');
    is(SessionFilter::is_butler_session($known, undef), 0, 'undef $sids -> 0');
    is(SessionFilter::is_butler_session($known, 'string'), 0, 'non-hash (string) $sids -> 0');
    is(SessionFilter::is_butler_session($known, {}), 0, 'empty-hash $sids -> 0');
});

criterion('AC-6 -> DC-1: mark_sessions sets is_butler in place, preserves order/keys, returns the same arrayref, tolerates junk', sub {
    my $root = build_fixture_registry_root();
    my $sids = SessionFilter::collect_butler_sids($root);

    my @sessions = (
        { uuid => 'aaaaaaaa-1111-2222-3333-444444444444', mtime => 1, preview => 'one' },    # registered
        { uuid => '99999999-0000-0000-0000-000000000000', mtime => 2, preview => 'two' },    # unregistered
        { uuid => 'cccccccc-1111-2222-3333-444444444444', mtime => 3, preview => 'three' },  # registered
        { uuid => 'BBBBBBBB-1111-2222-3333-444444444444', mtime => 4, preview => 'four' },   # registered, uppercase
    );
    my $ret = SessionFilter::mark_sessions(\@sessions, $sids);
    is($ret, \@sessions, 'mark_sessions returns the SAME arrayref (reference identity)');
    is_deeply([map { $_->{is_butler} } @sessions], [1, 0, 1, 1],
        'is_butler set correctly (1,0,1,1) on each element, in order');
    is($sessions[0]{uuid}, 'aaaaaaaa-1111-2222-3333-444444444444', 'uuid untouched');
    is($sessions[0]{preview}, 'one', 'preview untouched');
    is($sessions[3]{mtime}, 4, 'mtime untouched');

    my @junk = (
        { uuid => 'aaaaaaaa-1111-2222-3333-444444444444' },
        undef,
        'not-a-hashref',
        { uuid => '99999999-0000-0000-0000-000000000000' },
    );
    my $survived = eval { SessionFilter::mark_sessions(\@junk, $sids); 1 };
    ok($survived, 'mark_sessions tolerates undef / non-hash elements without dying');
    is($junk[0]{is_butler}, 1, 'first (valid) element still marked correctly amid junk');
    is($junk[3]{is_butler}, 0, 'last (valid) element still marked correctly amid junk');
});

# =============================================================================
# §4.3 — The picker's pure filter layer (DC-2, DC-3)
# =============================================================================

# AC-7 calls build_options(), which already exists today (only its is_butler
# tagging is new), so no die is expected here regardless of implementation
# state -- no criterion() wrapper needed; a missing is_butler key just yields
# a plain wrong-value failure, exactly as intended.
{
    my $U1 = 'aaaaaaaa-1111-2222-3333-444444444444';
    my $U2 = 'bbbbbbbb-1111-2222-3333-444444444444';
    my @sessions = (
        { uuid => $U1, mtime => 2, preview => 'p1', is_butler => 1 },
        { uuid => $U2, mtime => 1, preview => 'p2' },   # no is_butler key at all
    );
    my @opts = build_options(@sessions);
    is($opts[0]{action}, 'NEW', 'AC-7 -> DC-2: option 0 is still "Start a new session" (NEW)');
    ok(!exists $opts[0]{is_butler}, 'AC-7 -> DC-2: option 0 carries no is_butler key');
    is($opts[1]{is_butler}, 1, 'AC-7 -> DC-2: session tagged is_butler=>1 carries through to its option');
    is($opts[2]{is_butler}, 0, 'AC-7 -> DC-2: session with no is_butler key defaults its option to 0');
    like($opts[1]{action}, qr/^RESUME \Q$U1\E$/, 'AC-7 -> DC-2: action shape unchanged for U1');
    like($opts[2]{action}, qr/^RESUME \Q$U2\E$/, 'AC-7 -> DC-2: action shape unchanged for U2');
}

criterion('AC-8 -> DC-2: filter_options user/butler views, order preserved, no mutation, option 0 reference-identical', sub {
    my @sessions = (
        { uuid => 'u1', mtime => 3, preview => 's1', is_butler => 1 },
        { uuid => 'u2', mtime => 2, preview => 's2', is_butler => 0 },
        { uuid => 'u3', mtime => 1, preview => 's3', is_butler => 1 },
    );
    my @opts = build_options(@sessions);
    my $before = dclone(\@opts);

    my @user_view = filter_options(\@opts, 'user');
    is(scalar(@user_view), 2, "'user' view: NEW + the 1 non-butler session = 2 options");
    is($user_view[0]{action}, 'NEW', "'user' view: option 0 is NEW");
    is($user_view[1]{action}, 'RESUME u2', "'user' view: only the non-butler session (u2) survives");

    my @butler_view = filter_options(\@opts, 'butler');
    is(scalar(@butler_view), 3, "'butler' view: NEW + the 2 butler sessions = 3 options");
    is($butler_view[0]{action}, 'NEW', "'butler' view: option 0 is NEW");
    is($butler_view[1]{action}, 'RESUME u1', "'butler' view: first butler session (u1) in input order");
    is($butler_view[2]{action}, 'RESUME u3', "'butler' view: second butler session (u3) in input order");

    for my $v (undef, '', 'bogus') {
        my $label = defined $v ? "'$v'" : 'undef';
        my @view = filter_options(\@opts, $v);
        is(scalar(@view), 2, "view=$label behaves like 'user' (option count)");
    }

    is($user_view[0], $opts[0], "'user' view's option 0 is the SAME hashref (==) as input option 0");
    is($butler_view[0], $opts[0], "'butler' view's option 0 is the SAME hashref (==) as input option 0");

    is_deeply(\@opts, $before, 'filter_options mutates neither the input array nor its elements');
});

criterion('AC-9 -> DC-2: filter_options edge shapes', sub {
    is_deeply([filter_options([], 'user')], [], 'empty arrayref input -> ()');
    is_deeply([filter_options(undef, 'user')], [], 'undef input -> ()');

    my @only_new = ({ action => 'NEW' });
    is(scalar(filter_options(\@only_new, 'user')), 1, 'NEW-only list: exactly 1 option in the "user" view');
    is(scalar(filter_options(\@only_new, 'butler')), 1, 'NEW-only list: exactly 1 option in the "butler" view');

    my @all_butler = (
        { action => 'NEW' },
        { action => 'RESUME x', is_butler => 1 },
        { action => 'RESUME y', is_butler => 1 },
    );
    is(scalar(filter_options(\@all_butler, 'user')), 1,
        'all-sessions-are-butler list: "user" view yields exactly 1 option (NEW only)');
});

criterion("AC-10 -> DC-2: footer_text returns the four pinned strings exactly (is, not like)", sub {
    is(footer_text('user', 0),
       "  view: user   [t] show butler sessions   up/down: select   pgup/pgdn/home/end: jump   enter: confirm   q/esc: cancel",
       "footer_text('user', 0) matches the pinned long-form string exactly");
    is(footer_text('butler', 0),
       "  view: butler   [t] show user sessions   up/down: select   pgup/pgdn/home/end: jump   enter: confirm   q/esc: cancel",
       "footer_text('butler', 0) matches the pinned long-form string exactly");
    is(footer_text('user', 1),
       "  view: user   [t] butler   up/down  pgup/pgdn  enter  q/esc",
       "footer_text('user', 1) matches the pinned short-form string exactly");
    is(footer_text('butler', 1),
       "  view: butler   [t] user   up/down  pgup/pgdn  enter  q/esc",
       "footer_text('butler', 1) matches the pinned short-form string exactly");

    for my $pair ([qw(user 0)], [qw(butler 0)], [qw(user 1)], [qw(butler 1)]) {
        my ($v, $short) = @$pair;
        my $s = footer_text($v, $short);
        like($s, qr/^  view: (?:user|butler)\b/, "footer_text($v,$short) matches /^  view: (user|butler)/");
        like($s, qr/\[t\]/, "footer_text($v,$short) contains [t]");
        unlike($s, qr/[\x00-\x1f\x7f]/, "footer_text($v,$short) contains no control bytes");
    }
});

criterion('AC-11 -> DC-2: empty_view_note', sub {
    is(empty_view_note('user'), '(no user sessions)', "empty_view_note('user')");
    is(empty_view_note('butler'), '(no butler sessions)', "empty_view_note('butler')");
    is(empty_view_note(undef), '(no user sessions)', 'empty_view_note(undef) returns the user-view form');
});

criterion('AC-12 -> DC-2, DC-3: show_empty_note truth table, and the frame-never-overflows budget sweep', sub {
    is(show_empty_note(1, 1, 3), 1, '(1,1,3) -> 1');
    is(show_empty_note(1, 1, 1), 0, '(1,1,1) -> 0');
    is(show_empty_note(0, 0, 1), 1, '(0,0,1) -> 1');
    is(show_empty_note(2, 2, 5), 0, '(2,2,5) -> 0');
    is(show_empty_note(5, 3, 3), 0, '(5,3,3) -> 0');
    my $warn_count = 0;
    local $SIG{__WARN__} = sub { $warn_count++ };
    is(show_empty_note(undef, 1, 3), 0, 'undef $n_view -> 0');
    is(show_empty_note(1, undef, 3), 0, 'undef $shown -> 0');
    is(show_empty_note(1, 1, undef), 0, 'undef $cap -> 0');
    is($warn_count, 0, 'no undef-argument case warns');

    my $overflow = 0;
    for my $rows (1 .. 40) {
        my $L = plan_frame($rows, 1);       # only the NEW option in view
        my $shown = 1;
        my $note = show_empty_note(1, $shown, $L->{cap});
        my $total = $L->{head} + $L->{foot} + 2 * $L->{hints} + $shown + $note;
        $overflow++ if $total > ($rows < 1 ? 1 : $rows);
    }
    is($overflow, 0, 'budget sweep rows=1..40: the empty-view note never pushes the frame past the terminal height');
});

criterion('AC-13 -> DC-2: derive_blueprints_dir', sub {
    is(derive_blueprints_dir('/home/u/proj/.ccpraxis-local-data/claude-home/projects/-project'),
       '/home/u/proj/.ccpraxis-local-data/blueprints',
       'unix-separator path derives the blueprints dir');
    is(derive_blueprints_dir('C:\Users\A\proj\.ccpraxis-local-data\claude-home\projects\-project'),
       'C:\Users\A\proj\.ccpraxis-local-data/blueprints',
       'windows-separator (backslash) path derives the blueprints dir');
    is(derive_blueprints_dir('/tmp/xyz123'), '', 'no .ccpraxis-local-data ancestor (e.g. a tempdir) -> empty string');
    is(derive_blueprints_dir(''), '', 'empty string -> empty string');
    my $warn_count = 0;
    local $SIG{__WARN__} = sub { $warn_count++ };
    is(derive_blueprints_dir(undef), '', 'undef -> empty string');
    is($warn_count, 0, 'undef input does not warn');
    is(derive_blueprints_dir('/a/.ccpraxis-local-data'), '',
       '.ccpraxis-local-data with no trailing component -> empty string (not a strict ancestor)');
});

# =============================================================================
# §4.4 — End-to-end: hidden by default (DC-2, DC-3)
# =============================================================================
#
# Modeled on t/21-select-session-multiple.t's child-process / line-prompt
# pattern. No criterion() wrapper is needed here: run_picker() never calls a
# possibly-missing sub directly (it only spawns a child process and reads
# files), so a missing feature shows up as an ordinary wrong-value/wrong-exit-
# code assertion failure rather than a die in this test process.
{
    my $NEWEST = 'e1000000-0000-0000-0000-000000000001';
    my $MIDDLE = 'e2000000-0000-0000-0000-000000000002';
    my $OLDEST = 'e3000000-0000-0000-0000-000000000003';

    my $sessions_dir = build_sessions_dir(
        { uuid => $NEWEST, age => 60 },
        { uuid => $MIDDLE, age => 3600 },
        { uuid => $OLDEST, age => 86400 },
    );
    my $reg_root = build_registry_root($NEWEST);   # only the newest is butler-registered

    # ---- AC-14 -> DC-2 ----
    {
        my $out = "$sessions_dir/.out-ac14-2";
        my $r = run_picker(sessions_dir => $sessions_dir, out => $out,
                            blueprints_dir => $reg_root, input => "2\n");
        is($r->{content}, "RESUME $MIDDLE",
            'AC-14 -> DC-2: choosing 2 resumes the newest USER session, never the registered butler one');
    }
    {
        my $out = "$sessions_dir/.out-ac14-3";
        my $r = run_picker(sessions_dir => $sessions_dir, out => $out,
                            blueprints_dir => $reg_root, input => "3\n");
        is($r->{content}, "RESUME $OLDEST", 'AC-14 -> DC-2: choosing 3 resumes the oldest user session');
    }
    {
        my $out = "$sessions_dir/.out-ac14-1";
        my $r = run_picker(sessions_dir => $sessions_dir, out => $out,
                            blueprints_dir => $reg_root, input => "1\n");
        is($r->{content}, 'NEW', 'AC-14 -> DC-2: choosing 1 yields NEW');
    }
    {
        my $out = "$sessions_dir/.out-ac14-4";
        my $r = run_picker(sessions_dir => $sessions_dir, out => $out,
                            blueprints_dir => $reg_root, input => "4\n");
        is($r->{content}, 'NEW',
            'AC-14 -> DC-2: choosing 4 (out of range: only 3 options in the default view) falls back to NEW');
    }

    # ---- AC-15 -> DC-2 ----
    {
        my $out = "$sessions_dir/.out-ac15";
        my $r = run_picker(sessions_dir => $sessions_dir, out => $out,
                            blueprints_dir => $reg_root, input => "1\n");
        my $short_newest = substr($NEWEST, 0, 8);
        my $short_middle = substr($MIDDLE, 0, 8);
        my $short_oldest = substr($OLDEST, 0, 8);
        unlike($r->{stderr}, qr/\Q$NEWEST\E/, 'AC-15 -> DC-2: menu text never contains the full butler UUID');
        unlike($r->{stderr}, qr/\Q$short_newest\E/,
            'AC-15 -> DC-2: menu text never contains the butler UUID\'s 8-char prefix');
        like($r->{stderr}, qr/\Q$short_middle\E/,
            'AC-15 -> DC-2: menu text contains the middle-age user session\'s prefix');
        like($r->{stderr}, qr/\Q$short_oldest\E/,
            'AC-15 -> DC-2: menu text contains the oldest user session\'s prefix');
        like($r->{stderr}, qr/\[1\]/, 'AC-15 -> DC-2: menu text contains "[1]"');
        like($r->{stderr}, qr/Start a new session/, 'AC-15 -> DC-2: menu text contains "Start a new session"');
    }

    # ---- AC-16 -> DC-2, DC-3 ----
    {
        my $all_reg_root = build_registry_root($NEWEST, $MIDDLE, $OLDEST);
        for my $choice ('1', '9', '') {
            my $out = "$sessions_dir/.out-ac16-" . ($choice eq '' ? 'empty' : $choice);
            my $r = run_picker(sessions_dir => $sessions_dir, out => $out,
                                blueprints_dir => $all_reg_root, input => "$choice\n");
            is($r->{content}, 'NEW', "AC-16 -> DC-2,DC-3: all-butler view, choice '$choice' writes NEW");
            is($r->{rc}, 0, "AC-16 -> DC-2,DC-3: all-butler view, choice '$choice' exits 0");
        }
    }

    # ---- AC-17 -> DC-3 (fail-open) ----
    {
        my $out_a = "$sessions_dir/.out-ac17-a";
        my $r_a = run_picker(sessions_dir => $sessions_dir, out => $out_a,
                              blueprints_dir => "$reg_root/does-not-exist", input => "2\n");
        is($r_a->{content}, "RESUME $NEWEST",
            'AC-17a -> DC-3: nonexistent --blueprints-dir fails open (today\'s behavior: newest still reachable)');
        is($r_a->{rc}, 0, 'AC-17a -> DC-3: exit code 0');

        my $out_b = "$sessions_dir/.out-ac17-b";
        my $r_b = run_picker(sessions_dir => $sessions_dir, out => $out_b,
                              blueprints_dir => '', input => "2\n");
        is($r_b->{content}, "RESUME $NEWEST",
            "AC-17b -> DC-3: --blueprints-dir '' explicitly disables the scan (newest still reachable)");
        is($r_b->{rc}, 0, 'AC-17b -> DC-3: exit code 0');

        my $out_c = "$sessions_dir/.out-ac17-c";
        my $r_c = run_picker(sessions_dir => $sessions_dir, out => $out_c, input => "2\n");  # flag omitted entirely
        is($r_c->{content}, "RESUME $NEWEST",
            'AC-17c -> DC-3: --blueprints-dir omitted entirely: unchanged (today\'s) behavior');
        is($r_c->{rc}, 0, 'AC-17c -> DC-3: exit code 0');
    }
}

done_testing();
