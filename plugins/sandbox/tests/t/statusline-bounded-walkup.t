#!/usr/bin/env perl
# platform: windows
# The ORACLE for blueprint tooling-backlog,
# package 01-statusline-bounded-walkup (specs/01-statusline-bounded-walkup-spec.md).
#
# Written BLIND to the generator's/statusline.pl's planned new code: this
# file was derived from the spec, BpDataRoot.pm (the source of truth) and
# Almanac::Store.pm (the landed precedent for the same mirroring pattern),
# never from a not-yet-written implementation. Do NOT weaken an assertion to
# make a future implementation's life easier.
#
# Coverage: AC-1 through AC-8 (spec section 4). AC-9/AC-10/AC-11 are
# "existing" -- served by statusline-rebuild.t, unify-walkups.t and the other
# statusline test files, UNEDITED; nothing for them lives here.
#
# HARD CONSTRAINTS honoured here (spec section 4):
#   * NEVER spawns launcher.pl. The only children are `perl
#     gen-statusline-counters.pl` and `perl scripts/statusline.pl`, each
#     bounded by `timeout`.
#   * Fixtures live only under File::Temp tempdir().
#   * Never redirects to NUL; /dev/null only.
#   * This file deliberately does NOT carry the generated-block begin/end
#     marker literals at column 0 -- built by concatenation, like
#     statusline-rebuild.t's $CTR_BEGIN/$CTR_END, so a repo-wide marker scan
#     does not trip over this oracle's own subject matter.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use JSON::PP qw(encode_json);
use Encode qw(decode);
use Cwd ();

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
my $STATUSLINE = "$Bin/../../../../scripts/statusline.pl";
my $GENERATOR  = "$Bin/../../../almanac/scripts/gen-statusline-counters.pl";
my $DATAROOT_PM = "$Bin/../../../butler/scripts/BpDataRoot.pm";

ok(-f $STATUSLINE, 'setup: scripts/statusline.pl exists at the expected path');
ok(-f $GENERATOR,  'setup: gen-statusline-counters.pl exists at the expected path');
ok(-f $DATAROOT_PM, 'setup: BpDataRoot.pm exists at the expected path');

# The test's own side loads BpDataRoot.pm and Almanac::Store.pm by path (spec
# section 4: "-I/require from the test's side only"). Neither module may be
# loaded by the payload itself; that is the whole point of the mirror.
use lib "$Bin/../../../butler/scripts";
use lib "$Bin/../../../almanac/scripts";
require BpDataRoot;
require Almanac::Store;

# ---------------------------------------------------------------------------
# Scaffolding
# ---------------------------------------------------------------------------
sub slurp_raw {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $s = <$fh>;
    close $fh;
    return $s;
}

sub spew_raw {
    my ($path, $bytes) = @_;
    open my $fh, '>:raw', $path or die "cannot write $path: $!";
    print {$fh} $bytes;
    close $fh;
}

# extract_between($text, $begin_line, $end_line) -> ($n_begin, $n_end, $body)
# Same shape as statusline-rebuild.t's own helper: marker counts are
# whole-line matches, and $body is everything strictly between BEGIN's
# newline and END's line start (undef unless both occur exactly once, BEGIN
# first).
sub extract_between {
    my ($text, $b, $e) = @_;
    $text =~ s/\r\n/\n/g;
    my @bs; my @es;
    while ($text =~ /^[ \t]*\Q$b\E[ \t]*$/mg) { push @bs, $-[0] }
    while ($text =~ /^[ \t]*\Q$e\E[ \t]*$/mg) { push @es, $-[0] }
    return (scalar(@bs), scalar(@es), undef) unless @bs == 1 && @es == 1 && $bs[0] < $es[0];
    my $start = index($text, "\n", $bs[0]) + 1;
    my $line_start = rindex($text, "\n", $es[0]) + 1;
    return (1, 1, substr($text, $start, $line_start - $start));
}

# Built by concatenation so this file never carries a generated-block marker
# line at column 0.
my $CTR_BEGIN = '# >>> BEGIN GENERATED FROM ' . 'gen-statusline-counters.pl -- DO NOT EDIT BY HAND >>>';
my $CTR_END   = '# <<< END GENERATED FROM '   . 'gen-statusline-counters.pl <<<';

my $sl_raw = slurp_raw($STATUSLINE);
ok(defined $sl_raw, 'setup: statusline.pl read');
my (undef, undef, $PAYLOAD) = extract_between($sl_raw // '', $CTR_BEGIN, $CTR_END);
ok(defined $PAYLOAD, 'setup: the generated block exists between the markers in statusline.pl')
    or BAIL_OUT('cannot find the generated block in statusline.pl -- statusline-rebuild.t AC-8 should already be red');

# The generator's own stdout, run fresh (never the implementation's say-so
# about what it prints): a bounded child, timeout-wrapped.
my $gen_out = `timeout 20 perl "$GENERATOR" 2>/dev/null`;
my $gen_rc  = $? >> 8;
is($gen_rc, 0, 'setup: gen-statusline-counters.pl exits 0 with no arguments (AC-11)');

my $bdr_txt = slurp_raw($DATAROOT_PM);
ok(defined $bdr_txt, 'setup: BpDataRoot.pm read');

# extract_sub_body($text, $name) -- same regex as unify-walkups.t's own
# helper for the identical job.
sub extract_sub_body {
    my ($text, $name) = @_;
    return undef unless defined $text && $text =~ /^sub \Q$name\E\s*\{\n(.*?)\n\}\n/ms;
    return $1;
}

# normalize_alm_mirror_body($body) -- spec section 2.4, with the _alm_sw_/
# ALMANAC_SW_IS_WIN names swapped in for unify-walkups.t's _sw_/SW_IS_WIN.
sub normalize_alm_mirror_body {
    my ($body) = @_;
    return '' unless defined $body;
    $body =~ s/\$ALMANAC_SW_IS_WIN\b/\$IS_WIN/g;
    $body =~ s/_alm_sw_same_path_any_form/_same_path_any_form/g;
    $body =~ s/_alm_sw_same_path\b/same_path/g;
    $body =~ s/_alm_sw_/_/g;
    my @lines = split /\n/, $body;
    @lines = map { my $l = $_; $l =~ s/^\s*#.*$//; $l } @lines;
    my $joined = join(' ', @lines);
    $joined =~ s/\s+/ /g;
    $joined =~ s/;\s*\}/ }/g;
    $joined =~ s/^\s+|\s+\z//g;
    return $joined;
}

# ---------------------------------------------------------------------------
# AC-1 / AC-2: _alm_project_root's body, in both the generator's stdout and
# statusline.pl's block, drops the hand-rolled loop and delegates to
# _alm_bounded_walk.
# ---------------------------------------------------------------------------
for my $case ([ 'generator stdout', $gen_out ], [ "statusline.pl's block", $PAYLOAD ]) {
    my ($label, $text) = @$case;
    my $body = extract_sub_body($text, '_alm_project_root');
    ok(defined $body, "AC-1 setup: _alm_project_root is defined in $label") or next;
    unlike($body, qr/\bwhile\b/,   "AC-1: _alm_project_root's body in $label contains no 'while'");
    unlike($body, qr/\bfor\b/,     "AC-1: _alm_project_root's body in $label contains no 'for'");
    unlike($body, qr/\bforeach\b/, "AC-1: _alm_project_root's body in $label contains no 'foreach'");
    unlike($body, qr/\buntil\b/,   "AC-1: _alm_project_root's body in $label contains no 'until'");
    unlike($body, qr/\brindex\b/,  "AC-1: _alm_project_root's body in $label contains no 'rindex'");
    like($body, qr/_alm_bounded_walk\s*\(/, "AC-1: _alm_project_root's body in $label calls _alm_bounded_walk(");

    unlike($text, qr/my\s+\$idx\s*=\s*rindex\(\$dir,\s*'\/'\);/,
        "AC-2: $label does not contain the old loop's rindex signature line");
    unlike($text, qr/\$parent\s*=\s*"\$parent\/"\s+if\s+\$parent\s*=~\s*m\{\\A\[A-Za-z\]:\\z\};/,
        "AC-2: $label does not contain the old loop's drive-root fix-up signature line");
}

# ---------------------------------------------------------------------------
# AC-3: source parity for the 11 _alm_sw_* subs (mod naming) and the
# $ALMANAC_SW_IS_WIN scalar's right-hand side.
# ---------------------------------------------------------------------------
my @PAIRS = (
    [ '_alm_sw_fold_ascii',         '_fold_ascii' ],
    [ '_alm_sw_is_abs_ish',         '_is_abs_ish' ],
    [ '_alm_sw_lex_canon',          '_lex_canon' ],
    [ '_alm_sw_seg_eq',             '_seg_eq' ],
    [ '_alm_sw_same_path',          'same_path' ],
    [ '_alm_sw_real_path',          '_real_path' ],
    [ '_alm_sw_same_path_any_form', '_same_path_any_form' ],
    [ '_alm_sw_compute_stops',      '_compute_stops' ],
    [ '_alm_sw_is_stop',            '_is_stop' ],
    [ '_alm_sw_collapse_dotdot',    '_collapse_dotdot' ],
    [ '_alm_sw_home_usable',        '_home_usable' ],
);
is(scalar(@PAIRS), 11, 'sanity: 11 source-parity pairs, per spec section 2.2');

for my $p (@PAIRS) {
    my ($alm_name, $bdr_name) = @$p;
    my $alm_body = extract_sub_body($PAYLOAD, $alm_name);
    my $bdr_body = extract_sub_body($bdr_txt, $bdr_name);
    ok(defined $alm_body, "AC-3: statusline.pl's payload defines $alm_name") or next;
    ok(defined $bdr_body, "AC-3 sanity: BpDataRoot.pm defines $bdr_name") or next;
    is(normalize_alm_mirror_body($alm_body), normalize_alm_mirror_body($bdr_body),
        "AC-3: payload's $alm_name body matches BpDataRoot::$bdr_name body (mod _alm_sw_/ALMANAC_SW_IS_WIN naming)");
}

{
    my ($rhs_alm) = $PAYLOAD =~ /my\s+\$ALMANAC_SW_IS_WIN\s*=\s*(.*?);/s;
    my ($rhs_bdr) = $bdr_txt =~ /my\s+\$IS_WIN\s*=\s*(.*?);/s;
    ok(defined $rhs_alm, 'AC-3: statusline.pl\'s payload defines $ALMANAC_SW_IS_WIN');
    ok(defined $rhs_bdr, 'AC-3 sanity: BpDataRoot.pm defines $IS_WIN');
    if (defined $rhs_alm && defined $rhs_bdr) {
        my $n_alm = normalize_alm_mirror_body($rhs_alm);
        my $n_bdr = normalize_alm_mirror_body($rhs_bdr);
        is($n_alm, $n_bdr, 'AC-3: $ALMANAC_SW_IS_WIN right-hand side matches $IS_WIN (mod naming)');
    }
}

# ---------------------------------------------------------------------------
# Load the payload standalone, exactly as spec section 4 instructs: extract
# the block, then evaluate it in its own package. Built by concatenation
# (never by interpolating $PAYLOAD into a double-quoted string, which would
# let Perl's own @array interpolation mangle the payload's many @-sigil
# variables before eval ever sees them).
# ---------------------------------------------------------------------------
my $probe_src = "package SLWalkProbe;\nno strict 'refs';\n" . $PAYLOAD . "\n1;\n";
my $probe_ok = eval $probe_src; ## no critic
ok($probe_ok, 'setup: the extracted payload block compiles standalone in its own package')
    or diag("payload eval error: $@");

my $HAVE_BOUNDED_WALK  = $probe_ok && defined &SLWalkProbe::_alm_bounded_walk;
my $HAVE_PROJECT_ROOT  = $probe_ok && defined &SLWalkProbe::_alm_project_root;
ok($HAVE_BOUNDED_WALK, 'AC-4 setup: the payload defines _alm_bounded_walk');
ok($HAVE_PROJECT_ROOT, 'AC-4 setup: the payload defines _alm_project_root (pre-existing; should already be true)');

# ---------------------------------------------------------------------------
# Fixtures (spec section 3 notation): R is the fixture root; H = R/home holds
# H/.ccpraxis-local-data; T = H/AppData/Local/Temp is the fake temp dir,
# nested inside home to match this host, per spec.
# ---------------------------------------------------------------------------
my $R = tempdir(CLEANUP => 1);
(my $Rn = $R) =~ s{\\}{/}g;
my $H = "$Rn/home";
make_path("$H/.ccpraxis-local-data");
my $T = "$H/AppData/Local/Temp";
make_path($T);
my $X = "$T/x";                       # case 1: the 0f1e case
make_path($X);
my $Y = "$H/a/b";                     # case 2: home not adopted from below
make_path($Y);
my $P = "$H/proj";                    # case 4: marker below the stops
make_path("$P/.ccpraxis-local-data");
my $PSUB = "$P/sub/dir";
make_path($PSUB);
my $G = "$T/g";                       # case 5: .git marker kept
make_path("$G/.git");
my $GY = "$G/y";
make_path($GY);
my $DOTDOT = "$P/sub/foo/..";         # a start containing ".." -> resolves to P/sub

sub norm_slash { my ($p) = @_; (my $q = $p) =~ s{\\}{/}g; $q =~ s{/+\z}{} unless $q =~ m{\A(?:[A-Za-z]:)?/\z}; return $q }

sub with_env {
    my ($overrides, $code) = @_;
    local %ENV = %ENV;
    for my $k (keys %$overrides) {
        if (defined $overrides->{$k}) { $ENV{$k} = $overrides->{$k} }
        else { delete $ENV{$k} }
    }
    return $code->();
}

my %BASELINE = (HOME => $H, USERPROFILE => $H, TMP => $T, TEMP => $T, TMPDIR => $T, CLAUDE_PROJECT_DIR => undef);

# ---------------------------------------------------------------------------
# AC-4: behaviours 1-7, exact return values.
# ---------------------------------------------------------------------------
SKIP: {
    skip 'payload does not define _alm_bounded_walk / _alm_project_root yet', 24
        unless $HAVE_BOUNDED_WALK && $HAVE_PROJECT_ROOT;

    with_env(\%BASELINE, sub {
        # Behaviour 1: temp start, no marker below temp (the 0f1e case).
        my $w1 = eval { SLWalkProbe::_alm_bounded_walk($X) };
        ok(!$@, "behaviour 1: _alm_bounded_walk(X) does not die ($@)");
        is($w1, undef, 'behaviour 1: _alm_bounded_walk(X) is undef (does not adopt H)');
        my $r1 = eval { SLWalkProbe::_alm_project_root($X) };
        is(norm_slash($r1 // ''), norm_slash($X), 'behaviour 1: _alm_project_root(X) falls back to X itself');
        my $bdr1 = BpDataRoot::walkup(cwd => $X);
        is($bdr1, undef, 'behaviour 1: BpDataRoot::walkup(cwd=>X) is also undef');

        # Behaviour 2: home is not adopted from below.
        my $w2 = eval { SLWalkProbe::_alm_bounded_walk($Y) };
        is($w2, undef, 'behaviour 2: _alm_bounded_walk(Y) is undef (H is strictly above Y and is never examined)');
        my $r2 = eval { SLWalkProbe::_alm_project_root($Y) };
        is(norm_slash($r2 // ''), norm_slash($Y), 'behaviour 2: _alm_project_root(Y) falls back to Y itself');

        # Behaviour 3: home adopted when the start IS home (R3).
        my $w3 = eval { SLWalkProbe::_alm_bounded_walk($H) };
        ok(defined($w3) && BpDataRoot::same_path($w3, $H), 'behaviour 3: _alm_bounded_walk(H) is H itself');
        my $r3 = eval { SLWalkProbe::_alm_project_root($H) };
        ok(defined($r3) && BpDataRoot::same_path($r3, $H), 'behaviour 3: _alm_project_root(H) is H itself');

        # Behaviour 4: marker below the stops still found.
        my $w4 = eval { SLWalkProbe::_alm_bounded_walk($PSUB) };
        ok(defined($w4) && BpDataRoot::same_path($w4, $P), 'behaviour 4: _alm_bounded_walk(P/sub/dir) finds P');
        my $r4 = eval { SLWalkProbe::_alm_project_root($PSUB) };
        ok(defined($r4) && BpDataRoot::same_path($r4, $P), 'behaviour 4: _alm_project_root(P/sub/dir) resolves to P');

        # Behaviour 5: .git marker kept.
        my $w5 = eval { SLWalkProbe::_alm_bounded_walk($GY) };
        ok(defined($w5) && BpDataRoot::same_path($w5, $G), 'behaviour 5: _alm_bounded_walk(G/y) finds G via its .git marker');
    });

    # Behaviour 6: CLAUDE_PROJECT_DIR fallback unchanged.
    my $Q = tempdir(CLEANUP => 1);
    (my $Qn = $Q) =~ s{\\}{/}g;
    with_env({ %BASELINE, CLAUDE_PROJECT_DIR => $Qn }, sub {
        my $r6a = eval { SLWalkProbe::_alm_project_root($X) };
        is(norm_slash($r6a // ''), norm_slash($Qn), 'behaviour 6: _alm_project_root(X) falls back to CLAUDE_PROJECT_DIR when set');
        my $r6b = eval { SLWalkProbe::_alm_project_root('rel/dir') };
        is(norm_slash($r6b // ''), norm_slash($Qn), 'behaviour 6: a relative start is never walked; CLAUDE_PROJECT_DIR still wins');
    });
    with_env(\%BASELINE, sub {
        my $r6c = eval { SLWalkProbe::_alm_project_root('rel/dir') };
        is($r6c, undef, 'behaviour 6: a relative start with no CLAUDE_PROJECT_DIR resolves to undef');
    });

    # Behaviour 7: no usable home means no ascent (8(b)).
    with_env({ HOME => undef, USERPROFILE => undef, TMP => $T, TEMP => $T, TMPDIR => $T, CLAUDE_PROJECT_DIR => undef }, sub {
        my $w7a = eval { SLWalkProbe::_alm_bounded_walk($PSUB) };
        is($w7a, undef, 'behaviour 7: with no usable home, _alm_bounded_walk(P/sub) does not ascend to P');
        my $r7a = eval { SLWalkProbe::_alm_project_root($PSUB) };
        is(norm_slash($r7a // ''), norm_slash($PSUB), 'behaviour 7: _alm_project_root(P/sub) falls back to P/sub itself');
        my $w7b = eval { SLWalkProbe::_alm_bounded_walk($P) };
        ok(defined($w7b) && BpDataRoot::same_path($w7b, $P), 'behaviour 7: starting AT P still finds its own marker');
        my $r7b = eval { SLWalkProbe::_alm_project_root($P) };
        ok(defined($r7b) && BpDataRoot::same_path($r7b, $P), 'behaviour 7: _alm_project_root(P) is P itself');
    });

    # Never-dies robustness (behaviour 10): a pathological start must not
    # throw out of the eval already wrapping every caller in statusline.pl.
    with_env(\%BASELINE, sub {
        my $w_empty = eval { SLWalkProbe::_alm_bounded_walk('') };
        ok(!$@, "behaviour 10: _alm_bounded_walk('') does not die ($@)");
        my $w_undef = eval { SLWalkProbe::_alm_bounded_walk(undef) };
        ok(!$@, "behaviour 10: _alm_bounded_walk(undef) does not die ($@)");
    });
}

# ---------------------------------------------------------------------------
# AC-5 / AC-6: parity against Almanac::Store::_bounded_walk and
# BpDataRoot::walkup, across the fixture-shape set. Both run under the SAME
# env for every start in the set.
# ---------------------------------------------------------------------------
SKIP: {
    skip 'payload does not define _alm_bounded_walk yet', 12
        unless $HAVE_BOUNDED_WALK;

    my @STARTS = (
        [ 'X (temp, no marker)',        $X ],
        [ 'Y (home/a/b, no marker)',    $Y ],
        [ 'H (home itself)',            $H ],
        [ 'P/sub/dir (marker at P)',    $PSUB ],
        [ 'G/y (.git marker at G)',     $GY ],
        [ 'P/sub/foo/.. (-> P/sub)',    $DOTDOT ],
    );

    with_env(\%BASELINE, sub {
        for my $s (@STARTS) {
            my ($label, $start) = @$s;
            my $alm   = eval { SLWalkProbe::_alm_bounded_walk($start) };
            my $store = Almanac::Store::_bounded_walk($start);
            if (!defined($alm) && !defined($store)) {
                pass("AC-5: payload and Almanac::Store agree (both undef) for $label");
            }
            else {
                ok(defined($alm) && defined($store) && BpDataRoot::same_path($alm, $store),
                    "AC-5: payload and Almanac::Store agree for $label (payload=" . ($alm // 'undef') . ", store=" . ($store // 'undef') . ")");
            }

            next if $label =~ /^G\/y/;   # AC-6 excludes the .git case by design (spec section 1.4/2.2)
            my $bdr = BpDataRoot::walkup(cwd => $start);
            if (!defined($alm) && !defined($bdr)) {
                pass("AC-6: payload and BpDataRoot::walkup agree (both undef) for $label");
            }
            else {
                ok(defined($alm) && defined($bdr) && BpDataRoot::same_path($alm, $bdr),
                    "AC-6: payload and BpDataRoot::walkup agree for $label (payload=" . ($alm // 'undef') . ", bdr=" . ($bdr // 'undef') . ")");
            }
        }
    });
}

# ---------------------------------------------------------------------------
# AC-7: Windows spellings (backslash / upper-case TMP) -- skipped off-Windows.
# ---------------------------------------------------------------------------
SKIP: {
    my $is_win_family = ($^O =~ /^(MSWin32|msys|cygwin)$/) ? 1 : 0;
    skip 'Windows-family perl only (spec behaviour 9)', 12 unless $is_win_family;
    skip 'payload does not define _alm_bounded_walk yet', 12 unless $HAVE_BOUNDED_WALK;

    (my $T_back = $T) =~ s{/}{\\}g;
    my $T_upper = uc($T);

    for my $spelling ([ 'backslash TMP', $T_back ], [ 'upper-case TMP', $T_upper ]) {
        my ($slabel, $tval) = @$spelling;
        my %env = (HOME => $H, USERPROFILE => $H, TMP => $tval, TEMP => $tval, TMPDIR => $tval, CLAUDE_PROJECT_DIR => undef);
        with_env(\%env, sub {
            for my $s (
                [ 'X', $X ], [ 'Y', $Y ], [ 'H', $H ],
                [ 'P/sub/dir', $PSUB ], [ 'G/y', $GY ],
            ) {
                my ($label, $start) = @$s;
                my $alm   = eval { SLWalkProbe::_alm_bounded_walk($start) };
                my $store = Almanac::Store::_bounded_walk($start);
                if (!defined($alm) && !defined($store)) {
                    pass("AC-7 ($slabel): payload and Almanac::Store agree (both undef) for $label");
                }
                else {
                    ok(defined($alm) && defined($store) && BpDataRoot::same_path($alm, $store),
                        "AC-7 ($slabel): payload and Almanac::Store agree for $label");
                }
            }
        });
    }
}

# ---------------------------------------------------------------------------
# AC-8: the 0f1e case end-to-end, through a real `perl scripts/statusline.pl`
# child, plus the counter-fixture control showing the assertion can fire.
# ---------------------------------------------------------------------------
{
    my $R2 = tempdir(CLEANUP => 1);
    (my $R2n = $R2) =~ s{\\}{/}g;
    my $H2 = "$R2n/home";
    make_path("$H2/.ccpraxis-local-data/almanac/todo");
    spew_raw("$H2/.ccpraxis-local-data/almanac/todo/one.md", "---\nstatus: open\n---\n");
    my $T2 = "$H2/AppData/Local/Temp";
    my $X2 = "$T2/x";
    make_path($X2);
    my $PROJ2 = "$H2/proj2";
    make_path("$PROJ2/.ccpraxis-local-data/almanac/todo");
    spew_raw("$PROJ2/.ccpraxis-local-data/almanac/todo/one.md", "---\nstatus: open\n---\n");
    my $CLEAN_DATA = tempdir(CLEANUP => 1);
    (my $CLEAN_DATAn = $CLEAN_DATA) =~ s{\\}{/}g;

    sub run_statusline_for_walkup {
        my ($current_dir) = @_;
        my $payload = { workspace => { current_dir => $current_dir } };
        my ($infh, $inpath) = tempfile();
        binmode $infh, ':raw';
        print {$infh} encode_json($payload);
        close $infh;

        local %ENV = %ENV;
        $ENV{HOME} = $H2;
        $ENV{USERPROFILE} = $H2;
        $ENV{TMP} = $T2;
        $ENV{TEMP} = $T2;
        $ENV{TMPDIR} = $T2;
        delete $ENV{CLAUDE_PROJECT_DIR};
        $ENV{CCPRAXIS_DATA_DIR} = $CLEAN_DATAn;
        delete $ENV{CCPRAXIS_SANDBOX};

        my $prev_cwd = Cwd::getcwd();
        chdir($CLEAN_DATAn) or die "fixture setup: cannot chdir: $!";
        my $out = `timeout 20 perl "$STATUSLINE" < "$inpath" 2>/dev/null`;
        my $rc  = $? >> 8;
        chdir($prev_cwd) or die "fixture teardown: cannot chdir back: $!";
        return (defined($out) ? $out : '', $rc);
    }

    my ($outA, $rcA) = run_statusline_for_walkup($X2);
    is($rcA, 0, 'AC-8: statusline.pl exits 0 for the 0f1e fixture (cwd under temp, no marker below it)');
    my $decodedA = eval { decode('UTF-8', $outA) } // $outA;
    my $has_glyph_a = (index($decodedA, chr(0x274F)) >= 0);
    ok(!$has_glyph_a,
        'AC-8 (behaviour 1/11, the 0f1e regression): rendering from a cwd under temp with no marker below it must NOT show the distant H2 ancestor\'s todo count');

    my ($outB, $rcB) = run_statusline_for_walkup($PROJ2);
    is($rcB, 0, 'AC-8 control: statusline.pl exits 0 for the counter-fixture');
    my $decodedB = eval { decode('UTF-8', $outB) } // $outB;
    my $has_glyph_b = (index($decodedB, chr(0x274F)) >= 0);
    ok($has_glyph_b,
        'AC-8 counter-fixture (control): a cwd that IS the project root with its own seeded store shows its todo count -- proves the assertion above can fire');
}

done_testing();
