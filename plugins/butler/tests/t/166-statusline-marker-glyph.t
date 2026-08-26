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

# THE BADGE WORD, declared once (re-pointed 2026-08-25 -- it was the literal
# 'WATCHED'). Mirrors t/151's own declaration; every claim here is about WHEN
# and WHERE the badge renders, never what it spells.
my $BADGE = 'watched';

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

# THE GLYPH MEANS CONTINUITY NOW, NOT ENVIRONMENT (operator, 2026-08-26).
#
# t06's Decision 3 spent the lead glyph on host-versus-sandbox. That fact is
# CONSTANT for a session, so the glyph never changed and therefore never told
# anyone anything the word beside it did not already say in full. The operator
# reassigned it: "instead of it representing sandbox vs host it should represent
# continuity watching vs not". Whether this turn can end is the thing that
# actually varies, and it is what deserves a shape you can read without reading.
#
# Decision 3's REAL guarantee is preserved and is what this section still pins:
# the distinction is carried by SHAPE (filled vs hollow), not by colour, so it
# survives an SGR strip. Only the subject of the distinction changed.
#
# The environment moved into the WORD'S COLOUR -- text.primary on HOST,
# text.muted on SANDBOX -- per "the `HOST` string could have some slight color
# difference ... but without screaming too much".
#
# Raw UTF-8 bytes throughout: this file reads statusline.pl's stdout as bytes.
my $GLYPH_WATCHED_BYTES   = encode('UTF-8', chr(0x25CF)); # filled -- a Stop gate is armed
my $GLYPH_UNWATCHED_BYTES = encode('UTF-8', chr(0x25CB)); # hollow -- nothing watching

# ===========================================================================
# AC1/AC2 -- glyph, space, environment word lead row 1. RE-POINTED: the word
# is no longer padded to a common slot ("No need to reserve space on HOST vs
# SANDBOX string cell. Have it shrink to fit available space"), so HOST is
# followed directly by its separator rather than by three columns of padding.
# ===========================================================================
{
    my ($out, $rc) = run_statusline(payload_for(), sandbox => 0);
    is($rc, 0, 'AC1 setup: host run exits 0');
    my $vis = strip_sgr(first_line($out));
    like($vis, qr/\A\Q$GLYPH_UNWATCHED_BYTES\E HOST /,
        'AC1: host, unarmed -- row 1 begins with the hollow glyph, one space, HOST, and NO '
      . 'reserved padding after the word');
}
{
    my ($out, $rc) = run_statusline(payload_for(), sandbox => 1);
    is($rc, 0, 'AC2 setup: sandbox run exits 0');
    my $vis = strip_sgr(first_line($out));
    like($vis, qr/\A\Q$GLYPH_UNWATCHED_BYTES\E SANDBOX /,
        'AC2: sandbox, unarmed -- row 1 begins with the hollow glyph, one space, SANDBOX');
}

# ===========================================================================
# AC3 -- RE-POINTED to the new subject. The glyph's colour tracks ARMING
# (state.ok when watched, text.faint when not); the WORD's colour tracks the
# environment (text.primary on host, text.muted in a sandbox). Asserted as
# substring checks on RAW stdout, so the opening escape must sit immediately
# before the bytes it colours.
# ===========================================================================
{
    my ($out) = run_statusline(payload_for(), sandbox => 0);
    my $faint = "\033[38;2;100;116;139m";
    ok(index($out, $faint . $GLYPH_UNWATCHED_BYTES) >= 0,
        'AC3: an UNWATCHED glyph is immediately preceded by the text.faint truecolor SGR sequence');
    my $primary = "\033[38;2;230;230;230m";
    ok(index($out, $primary . ' HOST') >= 0,
        'AC3: the HOST word carries text.primary -- the brightness step that marks the host '
      . 'without shouting');
}
{
    my $cdir = tempdir(CLEANUP => 1);
    plant_marker($cdir, 'sess-ac3-armed');
    my ($out) = run_statusline(payload_for(session_id => 'sess-ac3-armed'),
                               sandbox => 0, cdir => $cdir);
    my $ok_sgr = "\033[38;2;26;168;74m";
    ok(index($out, $ok_sgr . $GLYPH_WATCHED_BYTES) >= 0,
        'AC3: a WATCHED glyph is immediately preceded by the state.ok truecolor SGR sequence');
}
{
    my ($out) = run_statusline(payload_for(), sandbox => 1);
    my $muted = "\033[38;2;148;163;184m";
    ok(index($out, $muted . ' SANDBOX') >= 0,
        'AC3: the SANDBOX word stays text.muted -- the safe default gets the quieter treatment');
}

# ===========================================================================
# AC4/AC5 -- the distinction survives colour being stripped, and the polarity
# is exact (not "some circle appears"). RE-POINTED to arming, which is what
# the shape now encodes; the environment is checked by its WORD, which is
# equally strip-proof.
# ===========================================================================
{
    my $cdir = tempdir(CLEANUP => 1);
    plant_marker($cdir, 'sess-ac4-armed');
    my ($out_armed)   = run_statusline(payload_for(session_id => 'sess-ac4-armed'),
                                       sandbox => 0, cdir => $cdir);
    my ($out_unarmed) = run_statusline(payload_for(session_id => 'sess-ac4-unarmed'),
                                       sandbox => 0, cdir => $cdir);
    my $vis_armed   = strip_sgr($out_armed);
    my $vis_unarmed = strip_sgr($out_unarmed);

    ok(index($vis_armed, $GLYPH_WATCHED_BYTES) >= 0,
        'AC4: with all SGR stripped, a watched session still shows the FILLED glyph');
    ok(index($vis_unarmed, $GLYPH_UNWATCHED_BYTES) >= 0,
        'AC4: with all SGR stripped, an unwatched session still shows the HOLLOW glyph');

    is(index($vis_armed, $GLYPH_UNWATCHED_BYTES), -1,
        "AC5: a watched session's stripped output never contains the hollow glyph");
    is(index($vis_unarmed, $GLYPH_WATCHED_BYTES), -1,
        "AC5: an unwatched session's stripped output never contains the filled glyph");

    # ...and the environment is still tellable apart without colour, which is
    # the half of Decision 3 that must not be lost in the reassignment.
    my ($vh) = run_statusline(payload_for(), sandbox => 0);
    my ($vs) = run_statusline(payload_for(), sandbox => 1);
    like(strip_sgr(first_line($vh)), qr/\bHOST\b/,
        'AC5: the environment survives an SGR strip too -- as the WORD, now that the glyph '
      . 'carries something else');
    like(strip_sgr(first_line($vs)), qr/\bSANDBOX\b/,
        'AC5: ...on both surfaces');
}

# ===========================================================================
# AC6 -- the row COUNT, and how it varies. RE-POINTED 2026-08-26: the two
# status rows merged into one ("I think we can have it all in a single line
# instead of two"), and the path row became host-only ("I want it hidden only
# on the sandbox. On the host it can and should continue appearing").
#
# So the count is no longer a fixed 2-plus-path. It is derived here from the
# two things that actually decide it, exactly as the old version derived its
# own -- never hardcoded, and exercised on both surfaces so a single magic
# number can never stand in for the rule.
# ===========================================================================
{
    my ($out, $rc) = run_statusline(payload_for(current_dir => '/w/proj-alpha'), sandbox => 0);
    is($rc, 0, 'AC6 setup (host, cwd present): exits 0');
    ok(index($out, $BADGE) < 0, 'AC6: the badge is no longer a WORD anywhere in the output');
    my @rows = split /\n/, $out;
    is(scalar(@rows), 2,
        'AC6 (host, cwd present): the merged status row plus the path row');
}
{
    my ($out, $rc) = run_statusline(payload_for(current_dir => '/w/proj-alpha'), sandbox => 1);
    is($rc, 0, 'AC6 setup (sandbox, cwd present): exits 0');
    my @rows = split /\n/, $out;
    is(scalar(@rows), 1,
        'AC6 CANONICAL (sandbox): the path row is suppressed -- in a container the working '
      . 'directory is always the same mount, so it is a row spent saying nothing');
}
{
    my ($out, $rc) = run_statusline(payload_for(current_dir => ''), sandbox => 0);
    is($rc, 0, 'AC6 setup (host, cwd absent): exits 0');
    my @rows = split /\n/, $out;
    is(scalar(@rows), 1,
        'AC6 (host, cwd absent): no path row when there is no path -- the merged status row alone');
}

# ===========================================================================
# AC7 -- arming changes the LEAD GLYPH and nothing else.
#
# RE-POINTED TWICE, and the history is the point. It first asserted the badge
# occupied a ROW OF ITS OWN; the operator called that "awful" and it moved to
# row 2; then they reassigned it to the lead glyph outright ("Should instead
# use the `● HOST` versus `○ SANDBOX` to signalize the continuity watcher
# trigger on that first icon as it is").
#
# What survived all three shapes is the claim worth keeping: the state is
# visible, it is visible in exactly one place, and it costs no rows. That is
# now stronger than it has ever been -- it costs no COLUMNS either.
# ===========================================================================
for my $case ([ '/w/proj-alpha', 'path row present' ], [ '', 'no path row' ]) {
    my ($cwd, $label) = @$case;
    my $cdir = tempdir(CLEANUP => 1);
    plant_marker($cdir, 'sess-ac7');
    my ($armed, $rc) = run_statusline(
        payload_for(current_dir => $cwd, session_id => 'sess-ac7'),
        sandbox => 0, cdir => $cdir);
    my ($unarmed) = run_statusline(
        payload_for(current_dir => $cwd, session_id => 'sess-ac7-unarmed'),
        sandbox => 0, cdir => $cdir);
    is($rc, 0, "AC7 setup ($label): exits 0");

    my $a = strip_sgr(first_line($armed));
    my $u = strip_sgr(first_line($unarmed));

    like($a, qr/\A\Q$GLYPH_WATCHED_BYTES\E /,
        "AC7 ($label): an armed session leads with the filled glyph");
    like($u, qr/\A\Q$GLYPH_UNWATCHED_BYTES\E /,
        "AC7 ($label): an unarmed session leads with the hollow glyph");

    is(scalar(my @ra = split /\n/, $armed), scalar(my @ru = split /\n/, $unarmed),
        "AC7 ($label): arming changes no ROW COUNT at all");
}

# ===========================================================================
# AC8 -- row 1 varies with arming in EXACTLY ONE CHARACTER, and is otherwise
# byte-identical.
#
# SUPERSEDED AND REPLACED, deliberately, by operator decision 2026-08-26. This
# asserted row 1 was byte-identical between an armed and an unarmed run. That
# invariant existed to stop the badge reflowing row 1 -- a real problem when
# the badge was a WORD of variable width sitting in the marker field.
#
# The operator then put the state ON row 1 on purpose, as the lead glyph. So
# "row 1 does not vary" is now false BY DESIGN and keeping it would be
# asserting the absence of the feature.
#
# What replaces it is the guarantee that actually mattered underneath it, and
# it is the stronger half: row 1 must not REFLOW. Same length, same content,
# one differing character in position zero. A word-shaped badge could never
# have satisfied this; a glyph does it by construction.
# ===========================================================================
for my $sb (0, 1) {
    my $label = $sb ? 'sandbox' : 'host';
    my $cdir = tempdir(CLEANUP => 1);
    plant_marker($cdir, "sess-ac8-armed-$label");

    my ($out_armed)   = run_statusline(payload_for(session_id => "sess-ac8-armed-$label"),   sandbox => $sb, cdir => $cdir);
    my ($out_unarmed) = run_statusline(payload_for(session_id => "sess-ac8-unarmed-$label"), sandbox => $sb, cdir => $cdir);

    my $a = strip_sgr(first_line($out_armed));
    my $u = strip_sgr(first_line($out_unarmed));

    isnt($a, $u,
        "AC8 ($label): row 1 DOES vary with arming now -- the state is on row 1 on purpose "
      . '(this replaces the byte-identity invariant it superseded)');
    is(length($a), length($u),
        "AC8 CANONICAL ($label): ...and varies without REFLOWING -- identical length, so nothing "
      . 'after the glyph moves by a column');

    # ...and the difference is the LEAD GLYPH alone. Stripping the first
    # character from each must leave two identical strings.
    my $ta = $a; my $tu = $u;
    $ta =~ s/\A\Q$GLYPH_WATCHED_BYTES\E//;
    $tu =~ s/\A\Q$GLYPH_UNWATCHED_BYTES\E//;
    is($ta, $tu,
        "AC8 ($label): the ONLY difference is the lead glyph -- everything after it is "
      . 'byte-identical between an armed and an unarmed run');
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
    ok(index($out, $BADGE) < 0, 'Edge case: no badge when the continuity dir is unresolvable');
}

done_testing();
