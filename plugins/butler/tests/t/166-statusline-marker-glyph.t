#!/usr/bin/env perl
# 166-statusline-marker-glyph.t -- blueprint tui-operator-feedback, package
# t06-statusline-marker (specs/t06-statusline-marker-spec.md, AC1-AC15).
#
# Written BLIND to any t06 change in scripts/statusline.pl -- as of writing,
# the file has no leading glyph on the marker and still concatenates the
# continuity badge onto the marker field ("always-reserved-width"). Every
# expectation below comes from the spec (Decision 3, blueprint Decisions 8/9),
# not from reading the eventual diff.
#
# Scaffolding (make_tput/make_git_absent/spew_raw/payload_for/run_statusline/
# plant_marker shape) is adapted from plugins/butler/tests/t/151-continuity-
# statusline-badge.t's own conventions for spawning this exact file -- only
# what this file's assertions need is copied, not the whole file.
#
# NEVER touches real state: HOME and CCPRAXIS_CONTINUITY_ACTIVE_DIR are always
# File::Temp tempdirs; PATH is overridden to a shim dir so no real `git`/
# `tput` on this machine is ever consulted; CCPRAXIS_SANDBOX is scoped with
# `local %ENV` per run and never touches the operator's actual environment.
#
# Runs standalone: perl plugins/butler/tests/t/166-statusline-marker-glyph.t
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir tempfile);
use JSON::PP qw(encode_json);
use Encode qw(encode);

my $STATUSLINE = "$Bin/../../../../scripts/statusline.pl";
my $STATUSLINE_SRC = "$Bin/../../../../scripts/statusline.pl"; # same file, read as source below

ok(-f $STATUSLINE, 'setup: scripts/statusline.pl exists') or BAIL_OUT('file missing');

# ---------------------------------------------------------------------------
# Scaffolding
# ---------------------------------------------------------------------------
sub spew_raw {
    my ($path, $bytes) = @_;
    open my $fh, '>:raw', $path or die "cannot write $path: $!";
    print {$fh} $bytes;
    close $fh;
    return $path;
}

sub slurp_raw {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return '';
    local $/;
    my $s = <$fh>;
    close $fh;
    return defined($s) ? $s : '';
}

my $SHIM_DIR = tempdir(CLEANUP => 1);
sub make_tput {
    my ($cols) = @_;
    spew_raw("$SHIM_DIR/tput", "#!/bin/sh\necho $cols\n");
    chmod 0755, "$SHIM_DIR/tput";
}
# A git shim that always reports "not a repo" -- this file's assertions are
# about the marker glyph and the badge relocation, not git rendering, so the
# simplest correct shim never supplies a toplevel/branch.
sub make_git_absent {
    spew_raw("$SHIM_DIR/git", "#!/bin/sh\nexit 1\n");
    chmod 0755, "$SHIM_DIR/git";
}
make_tput(120);
make_git_absent();

my $TMPROOT = tempdir(CLEANUP => 1);

# payload_for(%opt) -- current_dir, session_id (opt). No rate_limits key is
# ever included, which pins plan_full to '' for every fixture in this file --
# deliberate, so AC6's row-count derivation depends only on cwd-presence, per
# the spec's own instruction not to hardcode a row count.
sub payload_for {
    my (%opt) = @_;
    my %p = (
        model          => { display_name => 'Claude Sonnet 5', id => 'claude-sonnet-5' },
        workspace      => { current_dir  => $opt{current_dir} // '/w/proj-alpha' },
        context_window => { used_percentage => 10, context_window_size => 200_000 },
    );
    $p{session_id} = $opt{session_id} if exists $opt{session_id};
    return \%p;
}

# run_statusline(\%payload, %opt) -> ($stdout_bytes, $rc)
# opt: cdir (CCPRAXIS_CONTINUITY_ACTIVE_DIR), home, sandbox (0|1)
sub run_statusline {
    my ($payload, %opt) = @_;
    my ($infh, $inpath) = tempfile(DIR => $TMPROOT);
    binmode $infh, ':raw';
    print {$infh} encode_json($payload);
    close $infh;

    local %ENV = %ENV;
    $ENV{PATH} = "$SHIM_DIR:$ENV{PATH}";
    $ENV{HOME} = $opt{home} // tempdir(CLEANUP => 1);
    if (defined $opt{cdir}) { $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR} = $opt{cdir} }
    else                    { delete $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR} }
    if ($opt{sandbox}) { $ENV{CCPRAXIS_SANDBOX} = '1' } else { delete $ENV{CCPRAXIS_SANDBOX} }

    my $out = `timeout 20 perl "$STATUSLINE" < "$inpath" 2>/dev/null`;
    my $rc  = $? >> 8;
    return (defined($out) ? $out : '', $rc);
}

sub plant_marker {
    my ($cdir, $sid) = @_;
    mkdir $cdir unless -d $cdir;
    open my $fh, '>', "$cdir/$sid" or die "plant $cdir/$sid: $!";
    print {$fh} "agent 2026-01-01T00:00:00Z\n";
    close $fh;
}

sub strip_sgr { my $s = shift; $s = '' unless defined $s; $s =~ s/\033\[[^m]*m//g; return $s }
sub first_line { my $s = shift; $s = '' unless defined $s; my ($l) = split /\n/, $s, 2; return defined($l) ? $l : '' }

# Decision 3's glyphs, as raw UTF-8 bytes -- this file reads statusline.pl's
# stdout as raw bytes throughout, so comparisons must be byte-level, never
# character-level (matching 69-statusline-rebuild.t's own encoding discipline).
my $GLYPH_HOST_BYTES    = encode('UTF-8', chr(0x25CF)); # filled
my $GLYPH_SANDBOX_BYTES = encode('UTF-8', chr(0x25CB)); # hollow

# ===========================================================================
# AC1/AC2 -- glyph, space, padded/unpadded word lead row 1 (spec: Observable
# behaviors 1-2; Interfaces "Marker construction").
# ===========================================================================
{
    my ($out, $rc) = run_statusline(payload_for(), sandbox => 0);
    is($rc, 0, 'AC1 setup: host run exits 0');
    my $vis = strip_sgr(first_line($out));
    like($vis, qr/\A\Q$GLYPH_HOST_BYTES\E HOST\s* /,
        'AC1: host, unarmed, cols=120 -- row 1 begins with the filled glyph, one space, HOST, '
      . 'then the existing padding/separator');
}
{
    my ($out, $rc) = run_statusline(payload_for(), sandbox => 1);
    is($rc, 0, 'AC2 setup: sandbox run exits 0');
    my $vis = strip_sgr(first_line($out));
    like($vis, qr/\A\Q$GLYPH_SANDBOX_BYTES\E SANDBOX /,
        'AC2: sandbox, unarmed, cols=120 -- row 1 begins with the hollow glyph, one space, SANDBOX');
}

# ===========================================================================
# AC3 -- each glyph is wrapped in its own role's SGR sequence: state.warn
# (38;2;214;128;16) on HOST, text.faint (38;2;100;116;139) on SANDBOX.
# Asserted as a substring check on RAW (non-stripped) stdout: the opening
# escape must sit immediately before the glyph's own bytes.
# ===========================================================================
{
    my ($out) = run_statusline(payload_for(), sandbox => 0);
    my $open = "\033[38;2;214;128;16m";
    ok(index($out, $open . $GLYPH_HOST_BYTES) >= 0,
        'AC3: the HOST glyph is immediately preceded by the state.warn truecolor SGR sequence');
}
{
    my ($out) = run_statusline(payload_for(), sandbox => 1);
    my $open = "\033[38;2;100;116;139m";
    ok(index($out, $open . $GLYPH_SANDBOX_BYTES) >= 0,
        'AC3: the SANDBOX glyph is immediately preceded by the text.faint truecolor SGR sequence');
}

# ===========================================================================
# AC4/AC5 -- the distinction survives colour being stripped, and the polarity
# is exact (not "some circle appears").
# ===========================================================================
{
    my ($out_host)    = run_statusline(payload_for(), sandbox => 0);
    my ($out_sandbox) = run_statusline(payload_for(), sandbox => 1);
    my $vis_host    = strip_sgr($out_host);
    my $vis_sandbox = strip_sgr($out_sandbox);

    ok(index($vis_host, $GLYPH_HOST_BYTES) >= 0,
        'AC4: with all SGR sequences stripped, host output still contains the filled glyph');
    ok(index($vis_sandbox, $GLYPH_SANDBOX_BYTES) >= 0,
        'AC4: with all SGR sequences stripped, sandbox output still contains the hollow glyph');

    is(index($vis_host, $GLYPH_SANDBOX_BYTES), -1,
        "AC5: host's stripped output never contains the hollow (sandbox) glyph");
    is(index($vis_sandbox, $GLYPH_HOST_BYTES), -1,
        "AC5: sandbox's stripped output never contains the filled (host) glyph");
}

# ===========================================================================
# AC6 -- unarmed run: no WATCHED substring, and the total row count equals
# what the SAME payload produces with no continuity concept at all. Every
# payload in this file omits `rate_limits`, which pins plan_full to '' (see
# payload_for's comment) -- so the row count depends ONLY on cwd-presence,
# per the spec's row-assembly logic (line1, line2, then the path row iff cwd
# is non-empty). This is derived from the spec text, not from reading the
# implementation, and is exercised at BOTH cwd-present and cwd-absent to
# avoid hardcoding a single magic row count.
# ===========================================================================
{
    my ($out, $rc) = run_statusline(payload_for(current_dir => '/w/proj-alpha'), sandbox => 0);
    is($rc, 0, 'AC6 setup (cwd present): exits 0');
    ok(index($out, 'WATCHED') < 0, 'AC6 (cwd present): no WATCHED substring when unarmed');
    my @rows = split /\n/, $out;
    is(scalar(@rows), 2 + 1,
        'AC6 (cwd present): row count is line1 + line2 + the path row -- no extra row for an '
      . 'absent badge (plan_full is pinned empty by this fixture'."'".'s payload)');
}
{
    my ($out, $rc) = run_statusline(payload_for(current_dir => ''), sandbox => 0);
    is($rc, 0, 'AC6 setup (cwd absent): exits 0');
    ok(index($out, 'WATCHED') < 0, 'AC6 (cwd absent): no WATCHED substring when unarmed');
    my @rows = split /\n/, $out;
    is(scalar(@rows), 2,
        'AC6 (cwd absent): row count is line1 + line2 only -- no path row, no badge row');
}

# ===========================================================================
# AC7 -- armed run: exactly one row equals (after SGR strip) WATCHED, and it
# is the SECOND-TO-LAST row when a path row is present, or the LAST row when
# it is not.
# ===========================================================================
{
    my $cdir = tempdir(CLEANUP => 1);
    plant_marker($cdir, 'sess-ac7-with-path');
    my ($out, $rc) = run_statusline(
        payload_for(current_dir => '/w/proj-alpha', session_id => 'sess-ac7-with-path'),
        sandbox => 0, cdir => $cdir);
    is($rc, 0, 'AC7 setup (path row present): exits 0');
    my @rows = split /\n/, $out;
    my @watched_idx = grep { strip_sgr($rows[$_]) eq 'WATCHED' } 0 .. $#rows;
    is(scalar(@watched_idx), 1,
        'AC7 (path row present): exactly one row is byte-exact WATCHED after SGR strip');
    is($watched_idx[0], $#rows - 1,
        'AC7 (path row present): the WATCHED row is the second-to-last row -- immediately '
      . 'before the path row, never after it');
}
{
    my $cdir = tempdir(CLEANUP => 1);
    plant_marker($cdir, 'sess-ac7-no-path');
    my ($out, $rc) = run_statusline(
        payload_for(current_dir => '', session_id => 'sess-ac7-no-path'),
        sandbox => 0, cdir => $cdir);
    is($rc, 0, 'AC7 setup (no path row): exits 0');
    my @rows = split /\n/, $out;
    my @watched_idx = grep { strip_sgr($rows[$_]) eq 'WATCHED' } 0 .. $#rows;
    is(scalar(@watched_idx), 1,
        'AC7 (no path row): exactly one row is byte-exact WATCHED after SGR strip');
    is($watched_idx[0], $#rows,
        'AC7 (no path row): the WATCHED row is the LAST row when there is no path row to precede');
}

# ===========================================================================
# AC8 (= test 151's F1, must stay green) -- armed and unarmed runs at the SAME
# cols and SAME environment: split /\n/ first element is BYTE-IDENTICAL
# (SGR-stripped) between the two runs.
# ===========================================================================
for my $sb (0, 1) {
    my $label = $sb ? 'sandbox' : 'host';
    my $cdir = tempdir(CLEANUP => 1);
    plant_marker($cdir, "sess-ac8-armed-$label");

    my ($out_armed)   = run_statusline(payload_for(session_id => "sess-ac8-armed-$label"),   sandbox => $sb, cdir => $cdir);
    my ($out_unarmed) = run_statusline(payload_for(session_id => "sess-ac8-unarmed-$label"), sandbox => $sb, cdir => $cdir);

    my $line1_armed   = strip_sgr(first_line($out_armed));
    my $line1_unarmed = strip_sgr(first_line($out_unarmed));

    is($line1_armed, $line1_unarmed,
        "AC8 ($label): row 1 is BYTE-IDENTICAL (SGR-stripped) whether the run is armed or "
      . "unarmed -- the badge relocation means row 1 literally does not vary with arming state");
}

# ===========================================================================
# AC9 -- extremely narrow terminal, armed: no malformed/split ANSI escape
# sequence survives anywhere in stdout, for both environments.
# ===========================================================================
{
    my $well_formed = qr/\e(?:\[[0-9;:?]*[ -\/]*[\@-~]|[\@-_])/;
    for my $sb (0, 1) {
        my $label = $sb ? 'sandbox' : 'host';
        my $cdir = tempdir(CLEANUP => 1);
        plant_marker($cdir, "sess-ac9-$label");

        for my $cols (120, 20, 14, 10, 6, 3, 1) {
            make_tput($cols);
            my ($out, $rc) = run_statusline(payload_for(session_id => "sess-ac9-$label"), sandbox => $sb, cdir => $cdir);
            is($rc, 0, "AC9 ($label, cols=$cols): exits 0");

            my $scan = $out;
            $scan =~ s/$well_formed//g;
            ok(index($scan, "\e") < 0,
                "AC9 ($label, cols=$cols): no truncated/malformed ANSI escape survives -- the "
              . "badge row is never passed through fit_head/fit_tail")
                or diag('offending bytes: ' . join('', map { sprintf('\\x%02x', ord) } split //, $scan));
        }
        make_tput(120);
    }
}

# ===========================================================================
# AC10 -- perl -c scripts/statusline.pl exits 0.
# ===========================================================================
{
    my $check_out = `perl -c "$STATUSLINE" 2>&1`;
    my $rc = $? >> 8;
    is($rc, 0, 'AC10: perl -c scripts/statusline.pl exits 0') or diag($check_out);
}

# ===========================================================================
# AC11 -- no numeric colour literal outside the generated %THEME_* block.
# Reimplemented locally (spec: "since this package cannot depend on that
# file"), mirroring plugins/sandbox/tests/t/69-statusline-rebuild.t's own
# AC-S1 detector technique: blank whole-line comments first (this file's own
# subject matter is the constructs scanned for), then look for an rgb() call
# with a numeric argument or a hand-written truecolor/256 SGR literal.
# ===========================================================================
{
    my $src = slurp_raw($STATUSLINE_SRC);
    my $blanked = join "\n", map { /^\s*#/ ? '' : $_ } split /\n/, $src, -1;

    my @hits;
    push @hits, 'rgb() call form with a numeric argument'
        if $blanked =~ /\brgb\s*\(\s*[-+]?\d/;
    push @hits, 'hand-written truecolor/256 SGR literal'
        if $blanked =~ /(?:\\033|\\e|\\x1[bB]|\\x\{1[bB]\}|\x1b)\[38;[25];\d/;

    ok(scalar(@hits) == 0,
        'AC11: scripts/statusline.pl carries no numeric-literal colour outside the generated '
      . 'THEME block -- the new glyph colours reference $WARN/$FAINT, not a new rgb() call or a raw literal')
        or diag('  found: ' . join('; ', @hits));
}

# ===========================================================================
# AC12 -- %GLYPH_COLS does NOT gain an entry for 0x25CF or 0x25CB.
# ===========================================================================
{
    my $src = slurp_raw($STATUSLINE_SRC);
    unlike($src, qr/0x25CF/i, 'AC12: scripts/statusline.pl does not add 0x25CF to %GLYPH_COLS (or anywhere else)');
    unlike($src, qr/0x25CB/i, 'AC12: scripts/statusline.pl does not add 0x25CB to %GLYPH_COLS (or anywhere else)');
}

# ===========================================================================
# AC13 -- the stale "always-reserved-width" comment phrase is gone.
# ===========================================================================
{
    my $src = slurp_raw($STATUSLINE_SRC);
    unlike($src, qr/always-reserved-width/,
        'AC13: the stale "always-reserved-width" comment phrase no longer appears anywhere in '
      . 'scripts/statusline.pl -- the comment block must describe the new own-row, zero-width-when-unarmed design');
}

# ===========================================================================
# AC14/AC15 -- non-regression tripwires: 151 and 150 must both stay green.
# Run as SUBPROCESSES so a crash in either does not abort this file, and so
# each is judged independently by exit code + not-ok count, matching this
# project's documented convention (prove does not exist on this host).
# ===========================================================================
{
    my $t151 = "$Bin/151-continuity-statusline-badge.t";
    ok(-f $t151, 'AC14 setup: 151-continuity-statusline-badge.t exists') or BAIL_OUT('151 missing');
    my $out151 = `timeout 120 perl "$t151" 2>&1`;
    my $rc151  = $? >> 8;
    my $not_ok_151 = () = ($out151 =~ /^not ok/mg);
    is($rc151, 0, 'AC14: plugins/butler/tests/t/151-continuity-statusline-badge.t exits 0');
    is($not_ok_151, 0, 'AC14: plugins/butler/tests/t/151-continuity-statusline-badge.t has zero not-ok lines')
        or diag($out151);
}
{
    my $t150 = "$Bin/150-continuity-gate.t";
    ok(-f $t150, 'AC15 setup: 150-continuity-gate.t exists') or BAIL_OUT('150 missing');
    my $out150 = `timeout 120 perl "$t150" 2>&1`;
    my $rc150  = $? >> 8;
    my $not_ok_150 = () = ($out150 =~ /^not ok/mg);
    is($rc150, 0, 'AC15: plugins/butler/tests/t/150-continuity-gate.t exits 0');
    is($not_ok_150, 0, 'AC15: plugins/butler/tests/t/150-continuity-gate.t has zero not-ok lines')
        or diag($out150);
}

# ===========================================================================
# Edge case (spec "Edge cases & failure modes"): session_id present but no
# continuity dir resolvable at all -- $armed computes false, no crash, no
# badge, exit 0. This package must not regress this existing behavior.
# ===========================================================================
{
    my ($infh, $inpath) = tempfile(DIR => $TMPROOT);
    binmode $infh, ':raw';
    print {$infh} encode_json(payload_for(session_id => 'sess-edge-unresolvable'));
    close $infh;

    local %ENV = %ENV;
    $ENV{PATH} = "$SHIM_DIR:$ENV{PATH}";
    delete $ENV{HOME};
    delete $ENV{USERPROFILE};
    delete $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR};
    delete $ENV{CCPRAXIS_SANDBOX};
    my $out = `timeout 20 perl "$STATUSLINE" < "$inpath" 2>/dev/null`;
    my $rc  = $? >> 8;
    is($rc, 0, 'Edge case: no crash when the continuity dir is unresolvable (HOME/USERPROFILE/override all unset)');
    ok(index($out, 'WATCHED') < 0, 'Edge case: no WATCHED badge when the continuity dir is unresolvable');
}

done_testing();
