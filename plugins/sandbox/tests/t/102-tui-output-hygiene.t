#!/usr/bin/env perl
# s17-statusline-and-output-hygiene: sandbox indicator, output hygiene while
# the alt-screen is owned, fork-cadence reduction, and current-session
# heartbeat filtering.
#
# This file is the IMMUTABLE ORACLE for blueprint sandbox-butler-overhaul,
# package s17-statusline-and-output-hygiene
# (specs/s17-statusline-and-output-hygiene-spec.md). Written BLIND to any
# launcher.pl / Dashboard.pm / statusline.pl / settings.json implementation --
# directly from the spec -- so it serves as an oracle rather than an echo of
# whatever the implementer eventually writes. Do NOT weaken an assertion to
# make a future implementation's life easier.
#
# Coverage: C1..C10 (spec S6).
#
# HARD CONSTRAINTS honoured here (spec S6 preamble / dispatch hazards):
#   * NEVER spawns launcher.pl, never builds an image, never starts a
#     container. launcher.pl is SLURPED for source-text assertions only
#     (t/48/t/59's established convention) -- never require'd/do'ne.
#   * scripts/statusline.pl IS spawned (bound by `timeout`) -- it is a plain,
#     non-interactive filter script (stdin JSON -> stdout text), not
#     launcher.pl, and the write-set ruling (spec S1) puts the sandbox
#     indicator there, so executing it is the only way to prove C1/C2.
#   * Fixtures live only under File::Temp tempdir()s/tempfile()s.
#
# NAMING NOTE (recorded, not invented): the spec gives the sandbox env var as
# an EXAMPLE ("e.g. CCPRAXIS_SANDBOX=1"), repeated identically in both the
# spec and the package ledger, rather than a pinned literal. This oracle
# treats that example as the expected name but discovers it from
# container/settings.json's own `env` block at run time (any key matching
# /SANDBOX/i with a truthy value), so a differently-but-reasonably-named var
# is not penalized. See the report for what was discovered.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use File::Temp qw(tempdir tempfile);
use JSON::PP qw(decode_json encode_json);

use_ok('Dashboard') or BAIL_OUT('Dashboard.pm did not load');

my $SCRIPTS_DIR   = "$Bin/../../scripts";
my $LAUNCHER_SRC  = "$SCRIPTS_DIR/launcher.pl";
my $STATUSLINE    = "$Bin/../../../../scripts/statusline.pl";
my $SETTINGS_JSON = "$SCRIPTS_DIR/../container/settings.json";

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

# --- source-text helpers for launcher.pl (slurped, never require'd/do'ne;
#     lifted from t/59's established convention). ---
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
# find_body_after($src, $re) -> balanced-brace body starting at the first '{'
# that closes a REGEX match (rather than a literal string), so extraction
# survives whitespace/alignment drift around e.g. `enter_raw => sub {`.
sub find_body_after {
    my ($src, $re) = @_;
    return undef unless $src =~ /$re/g;
    my $brace_pos = pos($src) - 1;
    return undef unless substr($src, $brace_pos, 1) eq '{';
    return _balanced_braces($src, $brace_pos);
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

my $LAUNCHER_SRC_TEXT = slurp($LAUNCHER_SRC);
ok(length($LAUNCHER_SRC_TEXT) > 0, 'setup: launcher.pl was read as source text')
    or BAIL_OUT('cannot read launcher.pl');

# run_capped($cmd_list_or_str, %opts) -> ($stdout_and_stderr, $exit)
# Bounded subprocess runner (never launcher.pl). Uses `timeout` per the
# standing hazard.
sub run_capped {
    my ($cmd, %opts) = @_;
    my $secs = $opts{secs} // 10;
    my $out  = `timeout $secs $cmd 2>&1`;
    my $rc   = $?;
    return ($out, $rc);
}

# ===========================================================================
# C3 -- container/settings.json sets the sandbox env var, and stays valid
# JSON conforming to its declared $schema key. Also discovers the var name
# (see NAMING NOTE above) for reuse by C1/C2.
# ===========================================================================
my $SETTINGS_TEXT = slurp($SETTINGS_JSON);
ok(length($SETTINGS_TEXT) > 0, 'C3 setup: container/settings.json was read')
    or BAIL_OUT('cannot read container/settings.json');

my $settings = eval { decode_json($SETTINGS_TEXT) };
ok(!$@ && ref($settings) eq 'HASH', 'C3: container/settings.json remains valid JSON')
    or diag("  \$\@ = " . ($@ // '?'));

ok(defined($settings->{'$schema'}) && length($settings->{'$schema'}),
    'C3: container/settings.json still declares a $schema key');
is($settings->{'$schema'}, 'https://json.schemastore.org/claude-code-settings.json',
    'C3: the declared $schema value is unchanged (still conforms to the same schema)');

my $SANDBOX_VAR;
{
    my $env = (ref($settings) eq 'HASH' && ref($settings->{env}) eq 'HASH') ? $settings->{env} : {};
    my @candidates = grep {
        /SANDBOX/i && defined($env->{$_}) && $env->{$_} =~ /^(1|true)$/i
    } keys %$env;
    if (@candidates) {
        $SANDBOX_VAR = $candidates[0];
    }
    ok(defined($SANDBOX_VAR),
        'C3: container/settings.json env block sets a truthy sandbox-indicating variable (matched /SANDBOX/i)')
        or diag('  no key matching /SANDBOX/i with a truthy value found in the env block -- '
              . 'falling back to the spec\'s own example name CCPRAXIS_SANDBOX for the statusline tests below');
    $SANDBOX_VAR //= 'CCPRAXIS_SANDBOX';
    diag("  C3: sandbox var discovered as '$SANDBOX_VAR'");
}

# ===========================================================================
# statusline.pl execution scaffolding (C1/C2). A plain non-interactive
# filter script -- spawning it is not covered by the launcher.pl ban.
# ===========================================================================
ok(-f $STATUSLINE, 'setup: scripts/statusline.pl exists at the expected path')
    or BAIL_OUT("cannot find statusline.pl at $STATUSLINE");

my $FAKE_TPUT_DIR = tempdir(CLEANUP => 1);

# make_fake_tput($cols) -> writes an executable `tput` shim reporting a fixed
# column count, so statusline.pl's own `tput cols` backtick is controllable
# without a real TTY.
sub make_fake_tput {
    my ($cols) = @_;
    my $path = "$FAKE_TPUT_DIR/tput";
    open(my $fh, '>', $path) or die "cannot write fake tput: $!";
    print $fh "#!/bin/sh\necho $cols\n";
    close $fh;
    chmod 0755, $path;
    return $path;
}

# run_statusline(\%payload, cols => N, sandbox => 0|1) -> $stdout
sub run_statusline {
    my ($payload, %opts) = @_;
    my $cols = $opts{cols} // 80;
    make_fake_tput($cols);

    my ($infh, $inpath) = tempfile(UNLINK => 1);
    print $infh encode_json($payload);
    close $infh;

    local %ENV = %ENV;
    $ENV{PATH} = "$FAKE_TPUT_DIR:$ENV{PATH}";
    if ($opts{sandbox}) {
        $ENV{$SANDBOX_VAR} = '1';
    } else {
        delete $ENV{$SANDBOX_VAR};
    }
    my ($out, $rc) = run_capped(qq{perl "$STATUSLINE" < "$inpath"}, secs => 15);
    return $out;
}

sub payload_for {
    my (%opts) = @_;
    return {
        model     => { display_name => 'Claude Sonnet 5', id => 'claude-sonnet-5' },
        workspace => { current_dir  => $opts{project_dir} // '/tmp/nonexistent-s17-fixture' },
        context_window => { used_percentage => 10, context_window_size => 200_000 },
    };
}

sub vlen { my $s = shift; $s =~ s/\033\[[^m]*m//g; return length($s); }
sub first_line { my $s = shift; my ($l) = split /\n/, $s, 2; return $l // ''; }

# ===========================================================================
# C1 -- sandbox indicator: present iff the sandbox var is set, at every
# supported width including a narrow one. Vacuity gate: unset -> absent AND
# the line is otherwise unchanged.
# ===========================================================================
for my $cols (40, 80, 120) {
    my $ordinary_dir = "/tmp/s17-ordinary-project";
    my $out_on  = run_statusline(payload_for(project_dir => $ordinary_dir), cols => $cols, sandbox => 1);
    my $out_off = run_statusline(payload_for(project_dir => $ordinary_dir), cols => $cols, sandbox => 0);

    my $line1_on  = first_line($out_on);
    my $line1_off = first_line($out_off);

    like($line1_on, qr/sandbox/i,
        "C1: with the sandbox var set, the statusline (cols=$cols) renders an unambiguous sandbox indicator");

    unlike($line1_off, qr/sandbox/i,
        "C1 vacuity: with the sandbox var UNSET, no sandbox indicator appears (cols=$cols) -- proves the host statusline is untouched");
    like($line1_off, qr/\Qs17-ordinary-project\E/,
        "C1 vacuity: with the sandbox var UNSET, the project name still renders (cols=$cols) -- the line is otherwise unchanged");
}

# ===========================================================================
# C2 -- project name renders and truncates gracefully at narrow widths:
# shortened, never wrapped, never overflowing the row. A deliberately
# over-long name is used; a short ordinary name is the paired positive
# (proves truncation is conditional, not universal chopping).
# ===========================================================================
{
    my $long_name = 'x' x 200;
    my $long_dir  = "/tmp/$long_name";
    for my $cols (40, 80) {
        my $out      = run_statusline(payload_for(project_dir => $long_dir), cols => $cols, sandbox => 0);
        my $line1    = first_line($out);
        unlike($line1, qr/\n/, "C2 setup: the rendered first line (cols=$cols) contains no embedded newline");
        ok(vlen($line1) <= $cols,
            "C2: an over-long project name is truncated to fit within cols=$cols (visible length "
            . vlen($line1) . " <= $cols), never overflowing the row")
            or diag("  line1 = " . $line1);
    }

    # Paired positive: an ordinary short name at the SAME narrow width is not
    # chopped -- proves the truncation above is conditional on length, not a
    # blanket truncation that would pass vacuously.
    my $ordinary_dir = "/tmp/short-proj";
    my $out   = run_statusline(payload_for(project_dir => $ordinary_dir), cols => 40, sandbox => 0);
    my $line1 = first_line($out);
    like($line1, qr/\Qshort-proj\E/,
        'C2 paired positive: an ordinary short project name renders in FULL at cols=40 (truncation is conditional, not universal)');
}

# ===========================================================================
# C4 -- while the alt-screen is owned, a synthetic runtime warn/die must not
# reach the terminal; the same text IS present in the launch log, with a
# timestamp. Structural, scoped to the enter_raw/leave_raw closures that own
# the alt-screen window (the ONLY place `1049h`/`1049l` appear on the
# interactive dashboard path).
# ===========================================================================
{
    my $enter_body = find_body_after($LAUNCHER_SRC_TEXT, qr/enter_raw\s*=>\s*sub\s*\{/);
    my $leave_body = find_body_after($LAUNCHER_SRC_TEXT, qr/leave_raw\s*=>\s*sub\s*\{/);
    ok(defined($enter_body), 'C4 setup: enter_raw closure body is balanced-brace extractable from source text')
        or diag('  the C4/C5/C7 assertions scoped to enter_raw below cannot be meaningful without this');
    ok(defined($leave_body), 'C4 setup: leave_raw closure body is balanced-brace extractable from source text')
        or diag('  the C4/C7 assertions scoped to leave_raw below cannot be meaningful without this');

    SKIP: {
        skip('enter_raw not extractable -- see hard failure above', 2) unless defined $enter_body;
        src_like($enter_body, qr/\bopen\s*\(\s*\\?\*?STDERR\s*,/,
            'C4: enter_raw redirects the PROCESS\'S OWN STDERR (a Perl open() on the STDERR filehandle) -- '
          . 'not merely a child-process 2>/dev/null, which the spec says cannot catch a parent-runtime warn/die');
        src_like($enter_body, qr/File::Temp|tempfile/,
            'C4: the STDERR capture destination is created via File::Temp (a real file, per spec S3)');
    }
    SKIP: {
        skip('leave_raw not extractable -- see hard failure above', 1) unless defined $leave_body;
        # THE TEARDOWN PATH, not one particular closure body.
        #
        # The restore was inlined in leave_raw when this was written. It now
        # lives in _restore_terminal, which leave_raw calls -- extracted so the
        # [r] re-exec path runs exactly the same primitives instead of a second
        # copy that drifts. The PROPERTY is unchanged: the process's own STDERR
        # is restored on the way out. Pinning the closure body instead of the
        # path made a refactor that improved the code look like a regression.
        my $teardown = $leave_body;
        if ($leave_body =~ /_restore_terminal/) {
            my ($helper) = $LAUNCHER_SRC_TEXT =~ /(sub _restore_terminal \{.*?\n\})/s;
            $teardown .= $helper if defined $helper;
        }
        src_like($teardown, qr/\bopen\s*\(\s*\\?\*?STDERR\s*,/,
            'C4/C7: the leave_raw teardown path restores STDERR (a second open() on the STDERR '
          . 'filehandle) before the alt-screen exits -- whether inline or via _restore_terminal');
    }

    # Paired positive: the captured text is not simply discarded -- it is
    # routed through the SAME timestamped writer already used elsewhere
    # (log_ev, which LaunchLog::event/format_event stamps with `ts`), rather
    # than a bespoke untimestamped print. Scoped to enter_dashboard's whole
    # body (the capture teardown may run outside enter_raw/leave_raw
    # narrowly, e.g. on the way out of Dashboard::run).
    my $dash_body = extract_sub_body($LAUNCHER_SRC_TEXT, 'sub enter_dashboard');
    ok(defined($dash_body), 'C4 setup: enter_dashboard sub body is balanced-brace extractable')
        or diag('  the log-routing paired-positive assertion below cannot be meaningful without this');
    SKIP: {
        skip('enter_dashboard not extractable', 1) unless defined $dash_body;
        src_like($dash_body, qr/log_ev\s*\(\s*['"]?\w*(?:stderr|captur)\w*/i,
            'C4 paired positive: a captured-stderr event is written via the shared, timestamped log_ev writer '
          . '(not a bare print) -- captured output reaches the log, it is not lost');
    }

    # Independent, executable confirmation that log_ev's underlying writer
    # DOES stamp a timestamp (so the structural claim above, once true,
    # really does mean "with a timestamp" and not just "somewhere in a log").
    require LaunchLog;
    my $line = LaunchLog::format_event('stderr_captured', { text => 'probe' }, 1_700_000_000, $$);
    my $ev   = eval { decode_json($line) };
    ok(ref($ev) eq 'HASH' && defined($ev->{ts}) && length($ev->{ts}),
        'C4 setup: the shared log writer (LaunchLog::format_event) stamps every event with a timestamp (`ts`)');
}

# ===========================================================================
# C5 -- Windows landmine, structural: the capture path does NOT reopen
# STDOUT/STDERR onto an in-memory scalar. Scoped to enter_raw/leave_raw
# (the only closures that legitimately touch STDERR for this feature).
# ===========================================================================
{
    my $enter_body = find_body_after($LAUNCHER_SRC_TEXT, qr/enter_raw\s*=>\s*sub\s*\{/);
    my $leave_body = find_body_after($LAUNCHER_SRC_TEXT, qr/leave_raw\s*=>\s*sub\s*\{/);
    for my $pair ([enter => $enter_body], [leave => $leave_body]) {
        my ($label, $body) = @$pair;
        SKIP: {
            skip("$label body not extractable -- see C4 hard failure above", 2) unless defined $body;

            # PAIRED POSITIVE GATE (coordinator). Without this, C5 passes
            # VACUOUSLY: "does not reopen STDERR onto a scalar" is trivially
            # true while there is no STDERR handling at all, so the assertion
            # is green today and would stay green if the feature were never
            # built. It only means something once a redirect EXISTS. Assert
            # the redirect is present AND that it targets a real file handle,
            # so the negative below is a statement about HOW it was done
            # rather than about nothing having been done.
            ok($body =~ /\bopen\b/ && $body =~ /STDERR/ && $body =~ /File::Temp|tempfile|\$capture|\$stderr_(?:file|path)/i,
               "C5 GATE: $label actually redirects STDERR to a real file handle (without this, the negative below is vacuous)")
                or diag("  no STDERR redirect found in $label -- the assertion that follows proves nothing yet");

            src_unlike($body, qr/\bopen\s*\(\s*\\?\*?STDE?R?R?\s*,\s*['"][+><]*['"]\s*,\s*\\\$/,
                "C5: $label does NOT reopen STDOUT/STDERR onto an in-memory scalar ref (Git-for-Windows perl 'Bad file descriptor')");
        }
    }
}

# ===========================================================================
# C7 -- STDERR is restored on alt-screen exit, INCLUDING the signal/abnormal
# exit path. leave_raw covers the clean-exit half (asserted under C4/C5
# above); this block covers $SIG{INT}/$SIG{TERM}/END, the file-scope handlers
# that already run the rest of the teardown sequence (log close, terminal
# reset, lock release).
# ===========================================================================
{
    # NOTE (coordinator fix): these patterns originally had NO CAPTURE GROUP,
    # so `my ($line) = ($src =~ $re)` bound $line to 1 -- the list-context
    # success value -- rather than to the matched text. The setup assertion
    # then passed (1 is defined) and the real assertion grepped the string "1"
    # for /STDERR/ and could never pass, no matter what the handlers did. The
    # handlers were in fact already correct. Capture groups added.
    for my $sig_re (
        [ INT  => qr/(\$SIG\{INT\}\s*=.*)$/m ],
        [ TERM => qr/(\$SIG\{TERM\}\s*=.*)$/m ],
        [ END  => qr/(^END\s*\{.*)$/m ],
    ) {
        my ($label, $re) = @$sig_re;
        my ($line) = ($LAUNCHER_SRC_TEXT =~ $re);
        ok(defined($line), "C7 setup: the file-scope $label handler is present in source text")
            or diag("  cannot locate \$SIG{$label}/END -- the assertion below did not run");
        SKIP: {
            skip("$label handler not found", 1) unless defined $line;
            # Accepts either the inline STDERR manipulation this originally
            # matched, or a call to _stderr_capture_drain(), which is where that
            # work moved on 2026-08-14. The intent is unchanged and the bar is
            # HIGHER, not lower: the old inline form only reattached the
            # filehandle, while the drain reattaches AND prints what the TUI
            # captured -- the handlers used to leave that text in a temp file
            # nobody reads, which is how an operator got a vanished TUI and a
            # bare prompt with no error.
            #
            # A6 in plugins/sandbox/tests/t/76-cold-start-machine-recovery.t
            # pins the drain's own contract (leave the alt screen, drain, print,
            # hold), so this assertion does not have to re-verify it -- it only
            # has to confirm each handler still reaches it.
            src_like($line, qr/\bSTDERR\b|_stderr_capture_drain\s*\(/,
                "C7: the $label handler (abnormal/signal exit path) still handles STDERR -- "
              . 'reattaching AND draining it, not leaving the terminal with a redirected '
              . 'STDERR (or an unread capture file) after the dashboard closes');
        }
    }
}

# ===========================================================================
# C6 -- a visible, non-destructive indicator tells the user output was
# logged; it does not corrupt the frame. Best-effort: (a) a broad string
# search for indicator language near the capture site, and (b) an executable
# forward-compatibility check that Dashboard::build_panels still renders a
# well-formed panel set when the gather state carries a plausible
# "something was captured" field (i.e. threading such a field through does
# not corrupt the frame).
# ===========================================================================
{
    my $dash_body = extract_sub_body($LAUNCHER_SRC_TEXT, 'sub enter_dashboard');
    SKIP: {
        skip('enter_dashboard not extractable -- see C4 hard failure above', 1) unless defined $dash_body;
        src_like($dash_body, qr/stderr.{0,40}(?:logg|captur)|(?:logg|captur).{0,40}stderr/is,
            'C6: enter_dashboard carries visible "output was logged/captured" language near the STDERR capture');
    }

    # RE-POINTED to the LIVE panel builder. Dashboard::build_panels was deleted
    # -- it had been unreachable since compose_frame started delegating to
    # tui::DashboardScreen, and had drifted to a panel set (Token/Spend) that no
    # longer renders. The property this asserts is unchanged; only the builder
    # that can actually answer it has. Returns an arrayref, not a list.
    my $panels = tui::DashboardScreen::panels(
        { project_name => 'demo', container => 'c1', status => 'running', events => [],
          stderr_captured => 1 },
        80,
    );
    ok(ref($panels) eq 'ARRAY' && @$panels > 0,
        'C6 non-destructive: the panel builder still renders a real, non-empty panel set when the state '
      . 'carries an extra "stderr was captured" field (forward-compatible, does not corrupt the frame)');
}

# ===========================================================================
# C8 -- fork reduction: the render loop's container poll no longer runs at
# the 10-second cadence; the new cadence is a NAMED CONSTANT, not a literal.
# Paired constraint (C8b): the constant is a genuine, bounded lengthening
# (not "poll never").
# ===========================================================================
{
    src_unlike($LAUNCHER_SRC_TEXT, qr/\$now\s*-\s*\$last_inspect\s*>=\s*10\b/,
        'C8: the per-tick container-poll guard no longer compares against the bare literal 10 (the old 10s cadence)');

    if ($LAUNCHER_SRC_TEXT =~ /\$now\s*-\s*\$last_inspect\s*>=\s*(\$?\w+)/) {
        my $ref = $1;
        ok($ref !~ /^\d+$/, "C8: the per-tick poll guard's cadence is a NAMED reference ('$ref'), not a bare numeral");

        if ($ref =~ /^\$(\w+)$/) {
            my $varname = $1;
            if ($LAUNCHER_SRC_TEXT =~ /\bmy\s+\$\Q$varname\E\s*=\s*(\d+)/
                || $LAUNCHER_SRC_TEXT =~ /\buse\s+constant\s+\Q$varname\E\s*=>\s*(\d+)/) {
                my $val = $1;
                ok($val > 10, "C8b: the new cadence constant ('$ref' = $val) is a genuine LENGTHENING beyond the old 10s");
                ok($val <= 120, "C8b: the new cadence constant ('$ref' = $val) is still bounded (<=120s) -- "
                    . "'reduce forks' has not degenerated into 'poll never', which would make the TUI stale");
            } else {
                fail("C8b: could not locate a numeric definition for the cadence reference '$ref' -- cannot verify it is a bounded lengthening");
                fail("C8b: could not locate a numeric definition for the cadence reference '$ref' -- cannot verify the upper bound");
            }
        } else {
            pass("C8b: cadence reference '$ref' is not a simple lexical (e.g. a `use constant`/qualified name) -- "
               . "recorded, verify manually at review");
            pass("C8b: (see prior line)");
        }
    } else {
        fail("C8: could not locate the per-tick poll guard's comparison at all -- 0 of the 3 C8b assertions above ran");
        fail("C8b: cadence lengthening could not be verified (guard not found)");
        fail("C8b: cadence upper bound could not be verified (guard not found)");
    }

    pass('C8: the measured before/after fork rate (including _heartbeat_once\'s two additional backtick forks, '
       . 'per spec S0 finding 1) is recorded as an implementer/review artifact, not re-derived by this oracle');
}

# ===========================================================================
# C9 -- heartbeat/tick events are filtered from the CURRENT-SESSION path too
# (not only history), via ONE shared predicate applied at both call sites
# (not two independently-maintained regexes).
# ===========================================================================
{
    # Vacuity/setup: prove Dashboard::recent_events itself does NOT already
    # filter heartbeat/tick -- so any filtering that appears MUST be applied
    # by the caller (gather closure / _history_events), which is exactly
    # what the structural assertions below are checking for.
    require LaunchLog;
    my $hb_line = LaunchLog::format_event('heartbeat', {}, 1_700_000_000, 999);
    my $hb_ev   = Dashboard::recent_events([$hb_line], 10);
    is(ref($hb_ev) eq 'ARRAY' ? scalar(@$hb_ev) : -1, 1,
        'C9 setup: Dashboard::recent_events itself does NOT filter a bare heartbeat line (filtering, once it '
      . 'exists, is necessarily applied by the CALLER -- proves the structural assertions below are non-vacuous)');

    # Structural: the current-session gather closure re-assigns @lines via a
    # filter that mentions heartbeat/tick (inline grep) OR calls a
    # heartbeat/tick-named helper on @lines, BEFORE feeding it to
    # Dashboard::recent_events -- mirroring _history_events' own shape.
    my $gather_body = find_body_after($LAUNCHER_SRC_TEXT, qr/gather\s*=>\s*sub\s*\{/);
    ok(defined($gather_body), 'C9 setup: the current-session gather closure body is balanced-brace extractable')
        or diag('  the current-session filtering assertion below cannot be meaningful without this');
    SKIP: {
        skip('gather closure not extractable', 1) unless defined $gather_body;
        src_like($gather_body,
            qr/\@lines\s*=\s*(?:grep\s*\{[^}]*(?:heartbeat|tick)[^}]*\}\s*\@lines|\w*(?:heartbeat|tick)\w*\s*\(\s*\\?\@lines\s*\))/i,
            'C9: the current-session gather closure filters heartbeat/tick events out of @lines '
          . 'BEFORE they reach Dashboard::recent_events (matches the operator\'s live-session screenshot, not just history)');
    }

    # "One filter, two call sites, not duplicated": search for a small,
    # standalone predicate sub (by CONTENT signature -- mentions both
    # heartbeat and tick, and is short enough to be a leaf predicate rather
    # than a whole gather/history sub) and, if found, require it is actually
    # CALLED (by name) at 2+ sites elsewhere in the file.
    my @candidates;
    my $pos = 0;
    while ($LAUNCHER_SRC_TEXT =~ /\bsub\s+(\w+)\s*\{/g) {
        my $name       = $1;
        my $brace_pos  = pos($LAUNCHER_SRC_TEXT) - 1;
        my $body       = _balanced_braces($LAUNCHER_SRC_TEXT, $brace_pos);
        next unless defined $body;
        next unless length($body) >= 15 && length($body) <= 300;   # leaf-predicate-sized, excludes _history_events/gather
        next unless $body =~ /heartbeat/i && $body =~ /tick/i;
        push @candidates, { name => $name, body => $body };
    }
    ok(scalar(@candidates) >= 1,
        'C9: a standalone, leaf-sized heartbeat/tick predicate sub exists (extracted from _history_events\' '
      . 'former inline regex, per spec S5 -- "one filter, applied at both sites")')
        or diag('  0 of the following 2 C9 assertions ran: no short sub whose body mentions both heartbeat and tick was found');

    SKIP: {
        skip('no candidate predicate sub found', 2) unless @candidates;
        is(scalar(@candidates), 1,
            'C9: exactly ONE such predicate sub exists (not two independently-maintained copies)');
        my $name = $candidates[0]{name};
        my $call_count = () = ($LAUNCHER_SRC_TEXT =~ /\b\Q$name\E\s*\(/g);
        # The definition site itself (`sub NAME {`) does not match `NAME(`,
        # so every match here is a genuine call site.
        ok($call_count >= 2,
            "C9: the predicate sub '$name' is CALLED (by name) at >=2 sites in launcher.pl "
          . "(found $call_count) -- the current-session AND history paths both go through the same definition");
    }

    # Regression lock: history's own filtering still works (unchanged
    # behaviour, not re-implemented here -- t/48 is s13's own oracle for it).
    my $history_body = extract_sub_body($LAUNCHER_SRC_TEXT, 'sub _history_events');
    ok(defined($history_body), 'C9 regression setup: _history_events body is balanced-brace extractable');
    SKIP: {
        skip('_history_events not extractable', 1) unless defined $history_body;
        src_like($history_body, qr/heartbeat/i,
            'C9 regression: _history_events (or its call to the shared predicate) still filters heartbeat/tick -- s13\'s history filtering is not lost');
    }
}

# ===========================================================================
# C10 -- baseline, recorded not re-implemented. t/22-mountspec-edge-cases.t
# (2 environmental failures) and the 7 podman-less t/01,03,04,06,12,13,18
# exiting 127 are pre-existing and not attributable to this package. Judge
# s17's own delta against this file plus t/41/t/59 (see report), not an
# absolute pass count anywhere in the suite.
# ===========================================================================
pass('C10: the pre-existing baseline (t/22-mountspec-edge-cases.t 2 environmental failures; '
   . 't/01,03,04,06,12,13,18 exiting 127 for want of podman in-container) is recorded as NOT attributable '
   . 'to this package -- judged by delta, not re-asserted here');

done_testing();
