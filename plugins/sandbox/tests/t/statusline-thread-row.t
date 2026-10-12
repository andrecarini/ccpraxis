#!/usr/bin/env perl
# platform: windows
# Immutable oracle for blueprint where-things-go, package 12-statusline-threads
# (specs/12-statusline-threads-spec.md). Written BLIND to scripts/statusline.pl,
# plugins/almanac/scripts/gen-statusline-counters.pl and
# plugins/sandbox/scripts/Theme.pm's thread-row code: every expectation below
# comes from the spec, so this file is an oracle rather than an echo of
# whatever the implementer eventually writes. Do NOT weaken an assertion to
# make a future implementation's life easier.
#
# Coverage: spec section 4, AC1-AC6 (AC7 is the statusline-counters-layout.t
# rewrite; AC8-AC10 are theme-tokens.t / statusline-rebuild.t AC-S5; AC11 is
# statusline-rebuild.t AC-18; AC12/AC13 are statusline-rebuild.t's generator
# and sweep-wide green checks).
#
# Conventions copied from plugins/sandbox/tests/t/statusline-counters-layout.t
# (never `require`d -- this file stands alone): mk_proj/mk_home tempdirs, the
# tput/git shims, a scrubbed HOME, a timeout-bounded spawn, fixtures written
# through the almanac modules (never hand-written .md files for thread/task
# records -- ledgers ARE hand-written, per spec section 3: "Ledgers are
# written by hand under <P>/.ccpraxis-local-data/blueprints/").
#
# THE BLK GLYPH IS NOT HARD-CODED (spec 2.4 "Conflict: U+26D4"): the
# thread.blocked glyph's codepoint is read from Theme::glyphs() at runtime,
# never assumed to be any particular codepoint.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use JSON::PP qw(encode_json);
use Encode qw(encode decode);
use Cwd ();
use POSIX ();

use_ok('Theme') or BAIL_OUT('Theme.pm did not load');

my $STATUSLINE  = "$Bin/../../../../scripts/statusline.pl";
my $ALMANAC_DIR = "$Bin/../../../almanac/scripts";

# ===========================================================================
# Scaffolding
# ===========================================================================
sub slurp_raw {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return '';
    local $/;
    my $s = <$fh>;
    close $fh;
    return defined($s) ? $s : '';
}
sub spew_raw {
    my ($path, $bytes) = @_;
    open my $fh, '>:raw', $path or die "cannot write $path: $!";
    print {$fh} $bytes;
    close $fh;
    return $path;
}

sub strip_sgr { my $s = shift; $s = '' unless defined $s; $s =~ s/\033\[[^m]*m//g; return $s }
sub col_cost {
    my ($bytes) = @_;
    my $s = strip_sgr($bytes);
    my $dec = decode('UTF-8', $s, Encode::FB_DEFAULT);
    return scalar(split //, $dec);
}
sub row_cost {
    my ($bytes) = @_;
    my $s = strip_sgr($bytes);
    my $b = length($s);
    my $c = col_cost($bytes);
    return $c > $b ? $c : $b;
}
sub last_line  { my $s = shift; $s = '' unless defined $s; my @l = split /\n/, $s; return @l ? $l[-1] : '' }

# sgr_runs($raw) -> \@runs: for each byte of the SGR-stripped string, the run
# of SGR escapes emitted immediately before it.
sub sgr_runs {
    my ($raw) = @_;
    my @runs;
    my $cur = '';
    my $i = 0;
    my $n = length $raw;
    while ($i < $n) {
        if (substr($raw, $i, 1) eq "\e" && substr($raw, $i) =~ /\A(\033\[[^m]*m)/) {
            $cur .= $1;
            $i += length $1;
            next;
        }
        push @runs, $cur;
        $cur = '';
        $i++;
    }
    return \@runs;
}
sub run_ends_with { my ($run, $sgr) = @_; return (defined($run) && length($run) >= length($sgr) && substr($run, -length($sgr)) eq $sgr) ? 1 : 0 }
sub fg_sgr { my $rgb = Theme::roles()->{ $_[0] }{rgb}; return sprintf("\e[38;2;%d;%d;%dm", @$rgb) }
sub bg_sgr { my $rgb = Theme::roles()->{ $_[0] }{bg};  return sprintf("\e[48;2;%d;%d;%dm", @$rgb) }

my $SEPBAR_BYTES = Theme::glyph('sep.bar');
my $SEP_RENDERED = " " . (defined($SEPBAR_BYTES) ? $SEPBAR_BYTES : '');
sub sep_fields {
    my ($line) = @_;
    my $s = strip_sgr($line);
    return split /\Q$SEP_RENDERED\E/, $s, -1;
}

# counter_seg($stripped_row, $glyph_bytes) -- same cut rule as
# statusline-counters-layout.t's helper of the same name.
sub counter_seg {
    my ($vis, $glyph) = @_;
    my $i = index($vis, $glyph);
    return undef if $i < 0;
    my $rest = substr($vis, $i);
    my $cut = length $rest;
    for my $stop ('  ', " " . (defined($SEPBAR_BYTES) ? $SEPBAR_BYTES : '')) {
        my $j = index($rest, $stop);
        $cut = $j if $j >= 0 && $j < $cut;
    }
    (my $seg = substr($rest, 0, $cut)) =~ s/\s+\z//;
    return $seg;
}

# --- shims (mirrors statusline-rebuild.t F-tput; no git shim needed here) ---
my $SHIM_DIR = tempdir(CLEANUP => 1);
sub make_tput {
    my ($cols) = @_;
    spew_raw("$SHIM_DIR/tput", "#!/bin/sh\necho $cols\n");
    chmod 0755, "$SHIM_DIR/tput";
}
sub make_git_absent {
    # No toplevel/branch files -> the shim's git always exits 1. The thread
    # row never reads git, but row 1's counters loop may try.
    unlink "$SHIM_DIR/toplevel.txt", "$SHIM_DIR/branch.txt";
    my $sh = "#!/bin/sh\nexit 1\n";
    spew_raw("$SHIM_DIR/git", $sh);
    chmod 0755, "$SHIM_DIR/git";
}
make_git_absent();

my $FAKE_ROOT = tempdir(CLEANUP => 1);
$FAKE_ROOT =~ s{\\}{/}g;
mkdir "$FAKE_ROOT/.git" or die "fixture setup: cannot mkdir $FAKE_ROOT/.git: $!";

my @SCRUB_ENV = qw(CLAUDE_PROJECT_DIR ALMANAC_HOME ALMANAC_SURFACE BUTLER_STATE_DIR);
my $CLEAN_HOME = tempdir(CLEANUP => 1);
my $CLEAN_DATA = tempdir(CLEANUP => 1);

my $SID = 'sess-thread-row';

sub nslash { my ($p) = @_; $p =~ s{\\}{/}g; $p =~ s{/\z}{} if length($p) > 1; return $p }
sub mk_proj {
    my $base = nslash(tempdir(CLEANUP => 1));
    make_path("$base/.git");
    return $base;
}
sub mk_home {
    my $h = nslash(tempdir(CLEANUP => 1));
    make_path("$h/.claude");
    return $h;
}

sub payload_for {
    my (%opt) = @_;
    my %p = (
        model          => { display_name => 'Claude Sonnet 5', id => 'claude-sonnet-5' },
        workspace      => { current_dir  => $opt{current_dir} // '/w/thread-fixture/src' },
        context_window => { used_percentage => 10, context_window_size => 200_000 },
    );
    $p{session_id} = $opt{session_id} if defined $opt{session_id};
    return \%p;
}

# run_statusline(\%payload, %opt) -> ($stdout_bytes, $rc). Mirrors the house
# pattern (statusline-rebuild.t / statusline-counters-layout.t).
sub run_statusline {
    my ($payload, %opt) = @_;
    make_tput($opt{cols} // 200);

    my ($infh, $inpath) = tempfile();
    binmode $infh, ':raw';
    print {$infh} encode_json($payload);
    close $infh;

    local %ENV = %ENV;
    $ENV{PATH} = "$SHIM_DIR:$ENV{PATH}";
    $ENV{HOME} = $opt{home} // $CLEAN_HOME;
    $ENV{USERPROFILE} = $ENV{HOME};
    delete $ENV{$_} for @SCRUB_ENV;
    $ENV{CCPRAXIS_DATA_DIR} = $opt{data} // $CLEAN_DATA;
    if ($opt{sandbox}) { $ENV{CCPRAXIS_SANDBOX} = '1' } else { delete $ENV{CCPRAXIS_SANDBOX} }
    for my $k (sort keys %{ $opt{env} || {} }) {
        if (defined $opt{env}{$k}) { $ENV{$k} = $opt{env}{$k} } else { delete $ENV{$k} }
    }

    my $prev_cwd = Cwd::getcwd();
    chdir($FAKE_ROOT) or die "fixture setup: cannot chdir: $!";
    my $out = `timeout 20 perl "$STATUSLINE" < "$inpath" 2>/dev/null`;
    my $rc  = $? >> 8;
    chdir($prev_cwd) or die "fixture teardown: cannot chdir back to $prev_cwd: $!";
    return (defined($out) ? $out : '', $rc);
}

# render(%o) -> ($stdout, $rc). o: root (CLAUDE_PROJECT_DIR), cwd (payload
# current_dir, default the spec's fixed 21-byte path), home, sandbox, sid,
# cols, data, env.
sub render {
    my (%o) = @_;
    my %env = (CLAUDE_PROJECT_DIR => $o{root});
    $env{$_} = $o{env}{$_} for keys %{ $o{env} || {} };
    return run_statusline(
        payload_for(current_dir => $o{cwd} // '/w/thread-fixture/src', session_id => $o{sid} // $SID),
        cols => $o{cols} // 200, sandbox => ($o{sandbox} ? 1 : 0),
        home => $o{home} // mk_home(), data => $o{data} // $CLEAN_DATA, env => \%env);
}

# ===========================================================================
# Almanac library loading -- Almanac::Thread (+ its own dependencies), loaded
# by absolute path exactly as thread-store.t does (BEGIN { unshift @INC, ... }
# then require Almanac::Thread).
# ===========================================================================
BEGIN {
    my $dir = "$FindBin::Bin/../../../almanac/scripts";
    $dir =~ s{\\}{/}g;
    unshift @INC, $dir;
}
my $THREAD_OK = eval { require Almanac::Thread; 1 };
my $THREAD_ERR = $@;
diag("Almanac::Thread did not load: $THREAD_ERR") unless $THREAD_OK;

sub with_host_policy {
    my ($code) = @_;
    no warnings 'once';
    local $Almanac::Store::SCOPE_POLICY{container} = $Almanac::Store::SCOPE_POLICY{host};
    return $code->();
}

sub create_live_thread {
    my ($name, $P, %o) = @_;
    return with_host_policy(sub {
        Almanac::Thread::create_thread($name, root => $P,
            owner_kind => 'session', owner_id => $o{sid} // $SID);
    });
}
sub add_unlinked {
    my ($name, $P, $title, %o) = @_;
    return with_host_policy(sub {
        Almanac::Thread::add_task($name, root => $P, title => $title,
            (exists $o{blocked_on} ? (blocked_on => $o{blocked_on}) : ()));
    });
}
sub add_linked {
    my ($name, $P, $link, %o) = @_;
    return with_host_policy(sub {
        Almanac::Thread::add_task($name, root => $P, link => $link,
            (exists $o{title} ? (title => $o{title}) : ()));
    });
}
sub set_status {
    my ($name, $P, $id, $status) = @_;
    with_host_policy(sub { Almanac::Thread::set_task_status($name, $id, $status, root => $P) });
}
sub edit_task {
    my ($name, $P, $id, %set) = @_;
    with_host_policy(sub { Almanac::Thread::edit_task($name, $id, root => $P, %set) });
}

# write_ledger(%o) -- a hand-written package ledger (spec section 3: ledgers
# are NOT written through any library). o: root, bp, pkg, status,
# archived (bool), checked (arrayref of 0/1 for pipeline steps 1..8, missing
# treated as 0/unchecked), no_pipeline (bool: omit the Pipeline section
# entirely), no_frontmatter (bool: write a frontmatter-free ledger, forcing
# status to fall back to 'pending' per PackageLink::resolve).
my @PIPELINE_STEPS = (
    'Scout (skip if scope already maps cleanly -- record the skip)',
    'Spec written to specs/<NN-slug>-spec.md and checked against done criteria',
    'Tests written from spec (bp-test-writer) and sanity-checked against spec',
    'Implementation converged (bp-implementer; tests immutable; loop <= 4 attempts)',
    'Validation suite green from disk (commands + exit codes recorded below)',
    'Review red-team complete (report paths below)',
    'Fix-batch applied (single dispatch) and re-validated',
    'UI pass (only if package touches UI) -- screenshots read, checklist applied',
);
sub write_ledger {
    my (%o) = @_;
    my $dir = $o{archived}
        ? "$o{root}/.ccpraxis-local-data/blueprints/_archive/$o{bp}/packages"
        : "$o{root}/.ccpraxis-local-data/blueprints/$o{bp}/packages";
    make_path($dir);
    my $body = '';
    unless ($o{no_frontmatter}) {
        $body .= "---\nstatus: $o{status}\n---\n\n";
    }
    unless ($o{no_pipeline}) {
        $body .= "## Pipeline\n\n";
        my $checked = $o{checked} || [];
        for my $i (0 .. $#PIPELINE_STEPS) {
            my $mark = $checked->[$i] ? 'x' : ' ';
            $body .= "- [$mark] " . ($i + 1) . ". $PIPELINE_STEPS[$i]\n";
        }
    }
    spew_raw("$dir/$o{pkg}.md", $body);
    return "$dir/$o{pkg}.md";
}
sub delete_ledger {
    my (%o) = @_;
    my $dir = $o{archived}
        ? "$o{root}/.ccpraxis-local-data/blueprints/_archive/$o{bp}/packages"
        : "$o{root}/.ccpraxis-local-data/blueprints/$o{bp}/packages";
    unlink "$dir/$o{pkg}.md";
}

# write_snapshot($home, %fields) -- the GlobalCounts snapshot shape, with an
# optional thread member (spec 2.1 "_alm_snapshot").
sub write_snapshot {
    my ($home, %v) = @_;
    make_path("$home/.claude");
    my %d = (generated_at => '2026-09-26T00:00:00Z', schema => 1,
              todo => { open => 0, done => 0, total => 0 }, note => { total => 0 }, %v);
    spew_raw("$home/.claude/almanac-global-counts.json", JSON::PP->new->canonical->encode(\%d) . "\n");
}

# ===========================================================================
# Glyphs -- fixed codepoints per spec 2.3, as BYTES. thread.blocked is NOT
# fixed (spec 2.4 "Conflict: U+26D4"): read from Theme at runtime.
# ===========================================================================
my $T  = encode('UTF-8', chr(0x23E3));   # icon.threads
my $F  = encode('UTF-8', chr(0x25B0));   # thread.full
my $E  = encode('UTF-8', chr(0x25B1));   # thread.empty
my $DG = encode('UTF-8', chr(0x25B6));   # cursor (doing)
my $AR = encode('UTF-8', chr(0x2192));   # arrow.right
my $BR = encode('UTF-8', chr(0x2502));   # rule.v
my $ID = encode('UTF-8', chr(0x23F8));   # thread.idle
my $DOT = encode('UTF-8', chr(0x00B7));
my $FLAG = encode('UTF-8', chr(0x2691));

my $BK_CP = Theme::glyphs()->{'thread.blocked'}{cp};
my $BK = defined($BK_CP) ? encode('UTF-8', chr($BK_CP)) : '';
diag('thread.blocked glyph not yet declared in Theme.pm -- BLK-containing rows will not match')
    unless defined $BK_CP;

# ===========================================================================
# Fixture builders (spec section 3). Ledgers are written BEFORE the linked
# task that references them, because add_task validates link resolution at
# creation time.
# ===========================================================================
sub build_F1 {
    my $P = mk_proj();
    return $P unless $THREAD_OK;
    create_live_thread('drive-tooling', $P);
    # Decision 37's landmine (spec section 3): "a thread whose tasks are all
    # done auto-archives". Every linked task's done-ness is a property of its
    # LEDGER FILE, visible the instant the ledger says so -- so T1/T2's
    # ledgers are written as NOT-YET-DONE, every task is added while the
    # thread still has an undone task, and only THEN are T1/T2 flipped to
    # done/dropped by rewriting the ledger directly (no Thread.pm call, so no
    # archive_check fires) and T3/T4 flipped via set_task_status (which does
    # archive_check, but by then T5-T9 are already present and undone).
    write_ledger(root => $P, bp => 'tooling-fixes', pkg => '10-alpha',          status => 'running');
    write_ledger(root => $P, bp => 'tooling-fixes', pkg => '11-beta',           status => 'pending');
    write_ledger(root => $P, bp => 'tooling-fixes', pkg => '12-bug-claimant',   status => 'running');
    write_ledger(root => $P, bp => 'tooling-fixes', pkg => '13-guard',          status => 'pending');
    add_linked('drive-tooling', $P, 'tooling-fixes/10-alpha');                                    # T1 (not yet done)
    add_linked('drive-tooling', $P, 'tooling-fixes/11-beta');                                      # T2 (not yet dropped)
    my $t3 = add_unlinked('drive-tooling', $P, 'Write the release notes');                         # T3 (pending)
    my $t4 = add_unlinked('drive-tooling', $P, 'Retire the old flag');                              # T4 (pending)
    add_linked('drive-tooling', $P, 'tooling-fixes/12-bug-claimant', title => 'SHOULD NOT RENDER'); # T5 doing (running) -- behaviour 31
    my $t6 = add_unlinked('drive-tooling', $P, 'Refresh the fixtures');                             # T6 (pending)
    add_linked('drive-tooling', $P, 'tooling-fixes/13-guard');                                      # T7 pending
    add_unlinked('drive-tooling', $P, 'Tidy the docs');                                              # T8 pending
    add_unlinked('drive-tooling', $P, 'Ship it');                                                    # T9 pending
    # Now finalise: T1/T2 become done via the ledger alone (no store write,
    # no archive_check); T3/T4 via set_task_status (archive_check fires, but
    # T6-T9 are still undone, so it is a safe no-op); T6 becomes doing.
    write_ledger(root => $P, bp => 'tooling-fixes', pkg => '10-alpha', status => 'done');
    write_ledger(root => $P, bp => 'tooling-fixes', pkg => '11-beta',  status => 'dropped');
    set_status('drive-tooling', $P, $t3->{id}, 'done');
    set_status('drive-tooling', $P, $t4->{id}, 'obsoleted');
    set_status('drive-tooling', $P, $t6->{id}, 'doing');
    return $P;
}
sub build_F3 {
    my $P = mk_proj();
    return $P unless $THREAD_OK;
    create_live_thread('notes-cleanup', $P);
    my $t1 = add_unlinked('notes-cleanup', $P, 'Draft outline');            # pending for now
    add_unlinked('notes-cleanup', $P, 'Write the summary section');
    add_unlinked('notes-cleanup', $P, 'Proofread');
    set_status('notes-cleanup', $P, $t1->{id}, 'done');                      # safe: 2 others still pending
    return $P;
}
sub build_F4 {
    my $P = mk_proj();
    return $P unless $THREAD_OK;
    create_live_thread('release-prep', $P);
    my $t1 = add_unlinked('release-prep', $P, 'Tag the build');             # pending for now
    my $t2 = add_unlinked('release-prep', $P, 'Publish the package');
    add_unlinked('release-prep', $P, 'Announce it');
    edit_task('release-prep', $P, $t2->{id}, blocked_on => '20261002-120000-abcd');
    set_status('release-prep', $P, $t2->{id}, 'blocked');                    # safe: others still pending/not-done
    set_status('release-prep', $P, $t1->{id}, 'done');                      # safe: 'Announce it' still pending
    return $P;
}
# build_F5(%o) -- o: no_archived_ledger (bool, behaviour 29's precondition is
# applied by the caller via delete_ledger instead), add_live (bool, behaviour
# 28).
sub build_F5 {
    my $P = mk_proj();
    return $P unless $THREAD_OK;
    create_live_thread('old-drive', $P);
    write_ledger(root => $P, bp => 'retired-bp', pkg => '03-thing', archived => 1,
        status => 'running', checked => [1, 1, 1, 0]);   # step 4 lowest unchecked -> "implementation"
    add_linked('old-drive', $P, 'retired-bp/03-thing');
    add_unlinked('old-drive', $P, 'Wrap up');
    return $P;
}
sub build_F7 {
    my $P = mk_proj();
    return $P unless $THREAD_OK;
    create_live_thread('pkg-wait', $P);
    write_ledger(root => $P, bp => 'bpx', pkg => '07-alpha',
        status => 'blocked', checked => [1, 1, 0]);       # step 3 lowest unchecked -> "tests"
    add_linked('pkg-wait', $P, 'bpx/07-alpha');
    add_unlinked('pkg-wait', $P, 'Follow up');
    return $P;
}

SKIP: {
    skip('Almanac::Thread did not load -- no fixture can be written', 1) unless $THREAD_OK;
    ok(1, 'setup: Almanac::Thread loaded');
}

# ===========================================================================
# AC6 (behaviours 1-8) -- the row-1 thread counter.
# ===========================================================================
SKIP: {
    skip('Almanac::Thread did not load', 20) unless $THREAD_OK;

    # Behaviour 1: P has a(live), b(handed-off), c(archived); snapshot
    # thread.open=5, projects=[P,Q]. Host and sandbox both render "T 2.5".
    {
        my $P = mk_proj();
        my $Q = mk_proj();
        create_live_thread('a', $P);
        create_live_thread('b', $P);
        with_host_policy(sub { Almanac::Thread::record_event('b', 'handed-off', root => $P, reason => 'moving on') });
        create_live_thread('c', $P);
        with_host_policy(sub { Almanac::Thread::archive('c', root => $P) });
        my $H = mk_home();
        write_snapshot($H, thread => { open => 5, projects => [$P, $Q] });
        for my $sb (0, 1) {
            my ($out, $rc) = render(root => $P, home => $H, sandbox => $sb);
            is($rc, 0, "behaviour 1 (sandbox=$sb): render exits 0");
            my $vis = strip_sgr(last_line($out));
            # row 1 is the first line regardless of surface.
            my $row1 = strip_sgr((split /\n/, $out)[0] // '');
            is(counter_seg($row1, $T), "$T 2${DOT}5", "behaviour 1 (sandbox=$sb): thread counter is \"T 2.5\"")
                or diag("  row 1 = [$row1]");
        }
    }

    # Behaviour 2: same P, no snapshot file -> "T 2", no dot.
    {
        my $P = mk_proj();
        create_live_thread('a2', $P);
        create_live_thread('b2', $P);
        with_host_policy(sub { Almanac::Thread::record_event('b2', 'handed-off', root => $P, reason => 'moving on') });
        for my $sb (0, 1) {
            my ($out) = render(root => $P, home => mk_home(), sandbox => $sb);
            my $row1 = strip_sgr((split /\n/, $out)[0] // '');
            is(counter_seg($row1, $T), "$T 2", "behaviour 2 (sandbox=$sb): no snapshot -> \"T 2\", no dot");
        }
    }

    # Behaviour 3: P has no open threads; snapshot thread.open=3 -> "T 3",
    # glyph and number in text.faint, no dot.
    {
        my $P = mk_proj();
        my $H = mk_home();
        write_snapshot($H, thread => { open => 3 });
        my ($out) = render(root => $P, home => $H);
        my $row = (split /\n/, $out)[0] // '';
        my $vis = strip_sgr($row);
        is(counter_seg($vis, $T), "$T 3", 'behaviour 3: P=0, G=3 -> "T 3"');
        my $raw = fg_sgr('text.faint') . $T . "\e[0m" . fg_sgr('text.faint') . ' 3' . "\e[0m";
        ok(index($row, $raw) >= 0, 'behaviour 3: both glyph and number are in text.faint')
            or diag("  row 1 = [$row]");
    }

    # Behaviour 4: P=2, snapshot thread.open=1 -> "T 2.2" (clamp).
    {
        my $P = mk_proj();
        create_live_thread('x4', $P);
        create_live_thread('y4', $P);
        my $H = mk_home();
        write_snapshot($H, thread => { open => 1 });
        my ($out) = render(root => $P, home => $H);
        my $vis = strip_sgr((split /\n/, $out)[0] // '');
        is(counter_seg($vis, $T), "$T 2${DOT}2", 'behaviour 4: G < P is clamped to P -> "T 2.2"');
    }

    # Behaviour 5: sandbox; snapshot has valid todo/note and thread.open=-1.
    # todo/note still render from the snapshot; thread counter is "T 2".
    {
        my $P = mk_proj();
        create_live_thread('x5', $P);
        create_live_thread('y5', $P);
        my $H = mk_home();
        write_snapshot($H, todo => { open => 7, done => 1, total => 8 }, note => { total => 2 },
            thread => { open => -1 });
        my ($out, $rc) = render(root => $P, home => $H, sandbox => 1);
        is($rc, 0, 'behaviour 5: exits 0 with a malformed thread.open');
        my $vis = strip_sgr((split /\n/, $out)[0] // '');
        is(counter_seg($vis, $T), "$T 2", 'behaviour 5: a malformed thread.open (-1) is dropped, P-only renders');
    }

    # Behaviour 6: P=0, no thread G -> no U+23E3 anywhere on row 1.
    {
        my $P = mk_proj();
        my ($out) = render(root => $P, home => mk_home());
        is(index((split /\n/, $out)[0] // '', $T), -1, 'behaviour 6: P=0 and no G -> no thread glyph anywhere on row 1');
    }

    # Behaviour 7: host snapshot todo.open/note.total still ignored (unchanged).
    {
        my $P = mk_proj();
        my $H = mk_home();
        write_snapshot($H, todo => { open => 99, done => 0, total => 99 }, note => { total => 99 });
        my ($out) = render(root => $P, home => $H, sandbox => 0);
        my $vis = strip_sgr((split /\n/, $out)[0] // '');
        unlike($vis, qr/99/, 'behaviour 7: on the host, the snapshot\'s todo.open/note.total are still ignored');
    }

    # Behaviour 8: U+25A3 appears nowhere in output or source.
    {
        my $P = mk_proj();
        create_live_thread('z8', $P);
        my ($out) = render(root => $P, home => mk_home());
        is(index($out, encode('UTF-8', chr(0x25A3))), -1, 'behaviour 8: U+25A3 appears nowhere in rendered output');
        my $src = slurp_raw($STATUSLINE);
        ok(index($src, '0x25A3') < 0 && index($src, "\\x{25A3}") < 0,
            'behaviour 8: U+25A3 appears nowhere in statusline.pl source');
    }
}

# ===========================================================================
# AC1 (behaviours 9-27) / AC4 (behaviours 24-26, 28, 29) / AC5 (behaviour 31)
# -- the directory row, table-driven exactly from spec section 3.
# ===========================================================================
SKIP: {
    skip('Almanac::Thread did not load', 1) unless $THREAD_OK;

    my $PATH_FULL  = '/w/thread-fixture/src';
    my $PATH_SHORT = '.../src';

    my $P1 = build_F1();
    my $P3 = build_F3();
    my $P4 = build_F4();
    my $P5 = build_F5();
    my $P7 = build_F7();

    my @ROWS = (
        # [desc, root, surface, [cols...], expected, cost]
        ['row9  F1 host 140',    $P1, 0, [140],
            "$T drive-tooling $F$F$F$F$E$E$E$E$E 4/9  $DG tooling-fixes/12 scout +1 $AR tooling-fixes/13 scout  $BR $PATH_FULL", 134],
        ['row10 F1 host 100',    $P1, 0, [100],
            "$T drive-tooling $F$F$F$F$E$E$E$E$E 4/9  $DG tooling-fixes/12 scout +1  $BR $PATH_SHORT", 93],
        ['row11 F1 host 80',     $P1, 0, [80],
            "$T drive-tooling $F$F$F$F$E$E$E$E$E 4/9  $DG too.../12 +1  $BR $PATH_SHORT", 80],
        ['row12 F1 sandbox 140', $P1, 1, [140],
            "$T drive-tooling $F$F$F$F$E$E$E$E$E 4/9  $DG tooling-fixes/12 scout +1 $AR tooling-fixes/13 scout", 107],
        ['row13 F1 sandbox 100', $P1, 1, [100],
            "$T drive-tooling $F$F$F$F$E$E$E$E$E 4/9  $DG tooling-fixes/12 scout +1 $AR tooling-f.../13", 100],
        ['row14 F1 sandbox 80',  $P1, 1, [80],
            "$T drive-tooling $F$F$F$F$E$E$E$E$E 4/9  $DG tooling-fixes/12 scout +1", 80],
        ['row15 F3 host 140/100', $P3, 0, [140, 100],
            "$T notes-cleanup $F$E$E 1/3  $ID idle $AR Write the summary section  $BR $PATH_FULL", 98],
        ['row16 F3 host 80',     $P3, 0, [80],
            "$T notes-cleanup $F$E$E 1/3  $ID idle $AR Write the summary...  $BR $PATH_SHORT", 79],
        ['row17 F3 sandbox all', $P3, 1, [140, 100, 80],
            "$T notes-cleanup $F$E$E 1/3  $ID idle $AR Write the summary section", 71],
        ['row18 F4 host 140',    $P4, 0, [140],
            "$T release-prep $F$E$E 1/3  $BK Publish the package: waiting on 20261002-120000-abcd $AR Announce it  $BR $PATH_FULL", 131],
        ['row19 F4 host 100',    $P4, 0, [100],
            "$T release-prep $F$E$E 1/3  $BK Publish the package: waiting on 20261002-120000-...  $BR $PATH_SHORT", 100],
        ['row20 F4 host 80',     $P4, 0, [80],
            "$T release-prep $F$E$E 1/3  $BK Publish the package: waiting...  $BR $PATH_SHORT", 80],
        ['row21 F4 sandbox 140', $P4, 1, [140],
            "$T release-prep $F$E$E 1/3  $BK Publish the package: waiting on 20261002-120000-abcd $AR Announce it", 104],
        ['row22 F4 sandbox 100', $P4, 1, [100],
            "$T release-prep $F$E$E 1/3  $BK Publish the package: waiting on 20261002-120000-abcd $AR Anno...", 100],
        ['row23 F4 sandbox 80',  $P4, 1, [80],
            "$T release-prep $F$E$E 1/3  $BK Publish the package: waiting on 20261002-...", 80],
        ['row24 F5 sandbox all', $P5, 1, [140, 100, 80],
            "$T old-drive $E$E 0/2  $DG retired-bp/03 implementation $AR Wrap up", 70],
        ['row25 F5 host 140/100', $P5, 0, [140, 100],
            "$T old-drive $E$E 0/2  $DG retired-bp/03 implementation $AR Wrap up  $BR $PATH_FULL", 97],
        ['row26 F5 host 80',     $P5, 0, [80],
            "$T old-drive $E$E 0/2  $DG retired-bp/03 implementation $AR W...  $BR $PATH_SHORT", 80],
        ['row27 F7 sandbox 140', $P7, 1, [140],
            "$T pkg-wait $E$E 0/2  $BK bpx/07 tests $AR Follow up", undef],
    );

    for my $r (@ROWS) {
        my ($desc, $root, $sb, $cols_list, $want, $cost) = @$r;
      SKIP: {
            skip("$desc: no project root (fixture build failed)", scalar(@$cols_list) * 2) unless defined $root;
            for my $cols (@$cols_list) {
                my ($out, $rc) = render(root => $root, sandbox => $sb, cols => $cols);
                my $row = strip_sgr(last_line($out));
                is($row, $want, "AC1 $desc (cols=$cols): directory row matches the spec exactly")
                    or diag("  got  = [$row]\n  want = [$want]");
                if (defined $cost) {
                    is(row_cost($want), $cost, "AC1 $desc (cols=$cols): the oracle's own cost figure is self-consistent ($cost)");
                }
                cmp_ok(row_cost($row), '<=', $cols, "AC1 $desc (cols=$cols): row_cost is within budget")
                    if !defined($cost) || $cost <= $cols;
            }
        }
    }

    # behaviour 31 -- the linked T5's title is never shown, at every width
    # exercised above.
  SKIP: {
        skip('F1 fixture missing', 1) unless defined $P1;
        my $never_renders = 1;
        for my $cols (50, 80, 100, 140) {
            for my $sb (0, 1) {
                my ($out) = render(root => $P1, sandbox => $sb, cols => $cols);
                $never_renders = 0 if index($out, 'SHOULD NOT RENDER') >= 0;
            }
        }
        ok($never_renders, 'AC5 (behaviour 31): a linked task\'s own title ("SHOULD NOT RENDER") never appears in output');
    }

    # behaviour 28 -- live wins over archived.
  SKIP: {
        skip('F5 fixture missing', 1) unless defined $P5;
        write_ledger(root => $P5, bp => 'retired-bp', pkg => '03-thing', archived => 0,
            status => 'running', checked => [1, 0]);   # step 2 lowest unchecked -> "spec"
        my ($out) = render(root => $P5, sandbox => 1, cols => 140);
        my $row = strip_sgr(last_line($out));
        is($row, "$T old-drive $E$E 0/2  $DG retired-bp/03 spec $AR Wrap up",
            'AC4 (behaviour 28): a live ledger at the same link wins over the archived one');
    }

    # behaviour 29 -- missing ledger (archived one deleted after task add).
  SKIP: {
        skip('F5 fixture missing', 2) unless defined $P5;
        my $P5b = build_F5();
        delete_ledger(root => $P5b, bp => 'retired-bp', pkg => '03-thing', archived => 1);
        my ($out, $rc) = render(root => $P5b, sandbox => 1, cols => 140);
        is($rc, 0, 'AC4 (behaviour 29): rendering with a missing ledger still exits 0');
        my $row = strip_sgr(last_line($out));
        is($row, "$T old-drive $E$E 0/2  $ID idle $AR retired-bp/03 missing",
            'AC4 (behaviour 29): a missing ledger renders "<bp>/<NN> missing" as a pending-class label, idle state');
    }
}

# ===========================================================================
# AC3 -- colours, F1 host 140, F4 BLK, F3 idle.
# ===========================================================================
SKIP: {
    skip('Almanac::Thread did not load', 1) unless $THREAD_OK;
    my $P1 = build_F1();
    my $P4 = build_F4();
    my $P3 = build_F3();

  SKIP: {
        skip('F1 fixture missing', 6) unless defined $P1;
        my ($out) = render(root => $P1, sandbox => 0, cols => 140);
        my $row = last_line($out);
        my $vis = strip_sgr($row);
        my $runs = sgr_runs($row);
        my $i_t = index($vis, $T);
        ok($i_t >= 0, 'AC3: the thread glyph is present on the directory row') or diag("  row = [$vis]");
      SKIP: {
            skip('glyph not found', 5) if $i_t < 0;
            ok(run_ends_with($runs->[$i_t], fg_sgr('text.muted')), 'AC3: the thread glyph run ends with text.muted');
            my $i_name = $i_t + length($T) + 1;
            ok(run_ends_with($runs->[$i_name], fg_sgr('text.primary')), 'AC3: the thread name run ends with text.primary');
            my $i_full = index($vis, $F);
            ok($i_full >= 0 && run_ends_with($runs->[$i_full], fg_sgr('accent')), 'AC3: the first filled bar cell ends with accent');
            my $i_empty = index($vis, $E);
            ok($i_empty >= 0 && run_ends_with($runs->[$i_empty], fg_sgr('text.faint')), 'AC3: the first empty bar cell ends with text.faint');
            my $i_doing = index($vis, $DG);
            ok($i_doing >= 0 && run_ends_with($runs->[$i_doing], fg_sgr('state.ok')), 'AC3: the doing glyph ends with state.ok');
            my $i_bar = index($vis, $BR);
            ok($i_bar >= 0 && run_ends_with($runs->[$i_bar], fg_sgr('rule')), 'AC3: the path separator ends with rule');
        }
    }

  SKIP: {
        skip('F4 fixture or thread.blocked glyph missing', 1) unless defined($P4) && defined($BK_CP);
        my ($out) = render(root => $P4, sandbox => 0, cols => 140);
        my $row = last_line($out);
        my $vis = strip_sgr($row);
        my $runs = sgr_runs($row);
        my $i_bk = index($vis, $BK);
        ok($i_bk >= 0 && run_ends_with($runs->[$i_bk], fg_sgr('state.crit')), 'AC3 (F4): the blocked glyph ends with state.crit')
            or diag("  row = [$vis]");
    }

  SKIP: {
        skip('F3 fixture missing', 1) unless defined $P3;
        my ($out) = render(root => $P3, sandbox => 0, cols => 140);
        my $row = last_line($out);
        my $vis = strip_sgr($row);
        my $runs = sgr_runs($row);
        my $i_idle = index($vis, $ID);
        ok($i_idle >= 0 && run_ends_with($runs->[$i_idle], fg_sgr('text.faint')), 'AC3 (F3): the idle glyph ends with text.faint')
            or diag("  row = [$vis]");
    }
}

# ===========================================================================
# AC2 -- behaviours 30 (deep ladder rungs), 32 (no-thread paths), 33 (row
# count), 35 (sanitisation).
# ===========================================================================
SKIP: {
    skip('Almanac::Thread did not load', 1) unless $THREAD_OK;
    my $P1 = build_F1();

    # behaviour 30 -- deep ladder rungs.
  SKIP: {
        skip('F1 fixture missing', 3) unless defined $P1;
        my ($o50) = render(root => $P1, sandbox => 1, cols => 50);
        is(strip_sgr(last_line($o50)), "$T drive-tooling $F$E$E$E 4/9  $DG .../12 +1",
            'AC2 (behaviour 30): F1 sandbox at 50 -- R3 minimal form, R4 shrinks the bar to w=4,f=1');
        my ($o35s) = render(root => $P1, sandbox => 1, cols => 35);
        is(strip_sgr(last_line($o35s)), "$T drive-tooling 4/9",
            'AC2 (behaviour 30): F1 sandbox at 35 -- R5 then R7');
        my ($o35h) = render(root => $P1, sandbox => 0, cols => 35);
        is(strip_sgr(last_line($o35h)), "$T drive-tooling 4/9",
            'AC2 (behaviour 30): F1 host at 35 -- R6 drops the path too');
    }
}

SKIP: {
    skip('Almanac::Thread did not load', 1) unless $THREAD_OK;

    # behaviour 32/33 -- no-thread cases and row count, each sub-case.
    my $baseline_P = mk_proj();
    my ($base_h) = render(root => $baseline_P, sandbox => 0);
    my ($base_s) = render(root => $baseline_P, sandbox => 1);
    my @base_h_rows = split /\n/, $base_h;
    my @base_s_rows = split /\n/, $base_s;

    my %CASES;
    # no thread record at all.
    $CASES{'no record'} = mk_proj();
    # the only live thread is owned by another session.
    {
        my $P = mk_proj();
        create_live_thread('someone-elses', $P, sid => 'sess-not-this-one');
        $CASES{'owned by another session'} = $P;
    }
    # the session's thread is handed-off.
    {
        my $P = mk_proj();
        create_live_thread('handed-off-one', $P);
        with_host_policy(sub { Almanac::Thread::record_event('handed-off-one', 'handed-off', root => $P, reason => 'done for now') });
        $CASES{'handed-off'} = $P;
    }
    # the session id fails _alm_is_id (contains '..').
    $CASES{'bad session id'} = mk_proj();
    if (defined $CASES{'bad session id'}) {
        create_live_thread('would-be-attached', $CASES{'bad session id'});
    }

    for my $label (sort keys %CASES) {
        my $P = $CASES{$label};
        next unless defined $P;
        my $sid_arg = ($label eq 'bad session id') ? '../sess-thread-row' : undef;
        my ($oh, $rch) = render(root => $P, sandbox => 0, (defined $sid_arg ? (sid => $sid_arg) : ()));
        is($rch, 0, "behaviour 32/34 ($label, host): exits 0");
        my @rh = split /\n/, $oh;
        is(scalar(@rh), scalar(@base_h_rows), "behaviour 33 ($label, host): row count equals the no-thread baseline");
        is(strip_sgr($rh[-1] // ''), '/w/thread-fixture/src',
            "behaviour 32 ($label, host): the last row is exactly today's path_row, unelided");

        my ($os) = render(root => $P, sandbox => 1, (defined $sid_arg ? (sid => $sid_arg) : ()));
        my @rs = split /\n/, $os;
        is(scalar(@rs), scalar(@base_s_rows), "behaviour 33 ($label, sandbox): row count equals the no-thread baseline (no directory row)");
    }
}

SKIP: {
    skip('Almanac::Thread did not load', 1) unless $THREAD_OK;
    # behaviour 35 -- sanitisation / byte safety. Almanac::Record's own
    # creation-time validator already refuses a control character (ESC, BEL,
    # CR, LF) in BOTH title and blocked_on ("field 'title' must be one line:
    # no line break, control character..."), so a defensively-stripped C0
    # byte can never legitimately reach the thread row through the library --
    # see the test-writer report for why that sub-case is not exercised here.
    # What IS exercised, per spec section 5's byte-safety bullet ("AC-17's
    # \xC3\x83 check is carried over to the thread row with a non-ASCII
    # title"): a non-ASCII title renders UTF-8-encoded exactly once, never
    # double-encoded.
    my $P = mk_proj();
    create_live_thread('cafe-thread', $P);
    my $title = "Refine the caf\x{e9} parser";
    add_unlinked('cafe-thread', $P, $title);
    my ($out, $rc) = render(root => $P, sandbox => 1, cols => 200);
    is($rc, 0, 'behaviour 35 (byte safety): a non-ASCII title still renders, exit 0');
    is(index($out, "\xC3\x83"), -1, 'behaviour 35 (byte safety): no double-encoded UTF-8 anywhere in the output');
    like($out, qr/\Qcaf\E/, 'behaviour 35 (byte safety, non-vacuity): the title text actually reached the output');
}

# ===========================================================================
# Behaviour 34 (failure modes) -- representative subset. The "unreadable
# thread dir" and "task record that fails to parse" cases are simulated per
# this suite's established convention (statusline-counters-layout.t behaviour
# 9: a plain FILE where a directory is expected forces the failure inside the
# almanac_thread eval). "Any die inside almanac_thread" cannot be forced from
# black-box tests without implementation access -- not asserted here; see the
# test-writer report.
# ===========================================================================
SKIP: {
    skip('Almanac::Thread did not load', 1) unless $THREAD_OK;

    # an unreadable thread dir: a plain file sits where thread/ should be a
    # directory.
    {
        my $P = mk_proj();
        make_path("$P/.ccpraxis-local-data/almanac");
        spew_raw("$P/.ccpraxis-local-data/almanac/thread", "not a directory\n");
        my ($out, $rc) = render(root => $P, sandbox => 0, cols => 140);
        is($rc, 0, 'behaviour 34 (unreadable thread dir): still exits 0');
        is(strip_sgr(last_line($out)), '/w/thread-fixture/src',
            'behaviour 34 (unreadable thread dir): falls back to the plain path row');
    }

    # a ledger with no frontmatter block: status falls back to 'pending', no
    # step (matches the stated outcome for an unreadable/malformed ledger).
    {
        my $P = mk_proj();
        create_live_thread('bad-ledger', $P);
        write_ledger(root => $P, bp => 'flaky', pkg => '01-thing', no_frontmatter => 1, no_pipeline => 1);
        add_linked('bad-ledger', $P, 'flaky/01-thing');
        my ($out, $rc) = render(root => $P, sandbox => 1, cols => 140);
        is($rc, 0, 'behaviour 34 (malformed ledger): still exits 0');
        my $row = strip_sgr(last_line($out));
        like($row, qr/flaky\/01 pending/, 'behaviour 34 (malformed ledger): status falls back to pending, no step')
            or diag("  row = [$row]");
    }

    # malformed stdin.
    {
        my ($bfh, $bpath) = tempfile();
        print {$bfh} "{ not json";
        close $bfh;
        local %ENV = %ENV;
        $ENV{PATH} = "$SHIM_DIR:$ENV{PATH}";
        $ENV{HOME} = mk_home();
        $ENV{USERPROFILE} = $ENV{HOME};
        delete $ENV{$_} for @SCRUB_ENV;
        $ENV{CCPRAXIS_DATA_DIR} = $CLEAN_DATA;
        my $prev = Cwd::getcwd();
        chdir($FAKE_ROOT) or die "cannot chdir: $!";
        my $out = `timeout 20 perl "$STATUSLINE" < "$bpath" 2>/dev/null`;
        my $rc = $? >> 8;
        chdir($prev) or die "cannot chdir back: $!";
        is($rc, 0, 'behaviour 34 (malformed stdin): still exits 0');
    }
}

done_testing();
