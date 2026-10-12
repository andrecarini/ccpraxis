#!/usr/bin/env perl
# platform: any
# t/01 — bug reports are frozen once ccpraxis picks them up.
#
# The guarantee: a report's body cannot change from `triaging` onward, so a
# triager cannot have it rewritten underneath them and a `taken` report cannot
# be quietly reworded afterwards. Three layers back that up — the script
# refuses, a PreToolUse hook denies direct edits, and a sha256 recorded at
# freeze time DETECTS a write that got through anyway. The first two are
# bypassable by a determined Bash call; the third is not, because it does not
# rely on preventing anything.
#
# RENAME (12-bug-claimant-and-triaging, Decision 31): `reviewing` is renamed
# `triaging` everywhere, and moving a report to `triaging` now records the
# calling session's identity from a butler hook TICKET
# (BpHook::take_ticket('almanac-bug', ...)), never from a CLI argument. Every
# `set-status` call that enters or leaves `triaging` therefore needs a
# matching ticket minted first (see mint_ticket()/run_as() below) — the exact
# ARGV_RAW the almanac-bug.pl subprocess receives must equal the argv the
# ticket was minted for (BpHook keys a ticket on sha1(name, argv)).
#
# WRITTEN BLIND TO THE IMPLEMENTATION: almanac-bug.pl has NO claimant/ticket
# logic yet at the time this file is written, and @AlmanacBug::STATES still
# says `reviewing`. Every assertion below that depends on the rename or on
# claim recording is EXPECTED TO FAIL (red) until package 12 lands; that is
# the point of a failing-first oracle, not a bug in this file.
#
# SECOND RENAME (blueprint where-things-go, package 07-bug-lifecycle,
# Decision 8): `taken -> resolved | declined` becomes
# `scheduled -> fixed | dropped`. `scheduled` carries a validated
# `--package <blueprint>/<package>` link; `fixed` can never be set by hand
# (reconcile only); `dropped` requires a reason. almanac-bug.pl has NONE of
# this at the time this file is updated -- every fixture and assertion
# touched by this rename is likewise EXPECTED TO FAIL (red) until package
# 07-bug-lifecycle lands. See bug-lifecycle.t for the full oracle on
# scheduling, reconcile and migration; this file keeps only the renamed
# edges of the state machine itself.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
my $A = "$S/almanac-bug.pl";
ok(-f $A, 'almanac-bug.pl exists') or BAIL_OUT('script missing');

(my $BUTLER_SCRIPTS = "$Bin/../../../butler/scripts") =~ s{\\}{/}g;
my $BPHOOK_PM = "$BUTLER_SCRIPTS/BpHook.pm";
ok(-f $BPHOOK_PM, 'BpHook.pm exists (needed to mint test tickets)') or BAIL_OUT('BpHook.pm missing');
require $BPHOOK_PM;

# ---------------------------------------------------------------------------
# AC19 hygiene: snapshot the REAL ~/.claude/butler-state and the real repo's
# .ccpraxis-local-data/bug-reports BEFORE this file touches $ENV{HOME} etc,
# and compare again at the very end. A missing directory is fine either way.
# ---------------------------------------------------------------------------
my $REAL_HOME = $ENV{HOME} // $ENV{USERPROFILE} // '';
(my $REAL_BUTLER_STATE = length($REAL_HOME) ? "$REAL_HOME/.claude/butler-state" : '/nonexistent-no-real-home') =~ s{\\}{/}g;
(my $REPO_ROOT = "$Bin/../../../..") =~ s{\\}{/}g;
my $REAL_BUG_REPORTS = "$REPO_ROOT/.ccpraxis-local-data/bug-reports";

sub snapshot_dir {
    my ($dir) = @_;
    return { exists => 0 } unless -d $dir;
    my %info;
    my @stack = ($dir);
    while (my $d = pop @stack) {
        opendir(my $dh, $d) or next;
        for my $e (readdir $dh) {
            next if $e eq '.' || $e eq '..';
            next if $e eq 'continuity';
            my $full = "$d/$e";
            if (-d $full) { push @stack, $full }
            else { $info{$full} = (stat $full)[9] }
        }
        closedir $dh;
    }
    return { exists => 1, files => \%info };
}
my $HYGIENE_BEFORE_BUTLER = snapshot_dir($REAL_BUTLER_STATE);
my $HYGIENE_BEFORE_BUGS   = snapshot_dir($REAL_BUG_REPORTS);

# ---------------------------------------------------------------------------
# Isolated environment (AC in spec sec 4): fresh tempdirs for everything a
# claim operation could touch, so no claim/ticket op ever reaches the real
# machine state.
# ---------------------------------------------------------------------------
my $HOME = tempdir(CLEANUP => 1);
my $PROJ = tempdir(CLEANUP => 1);
my $CFG  = tempdir(CLEANUP => 1);   # CLAUDE_CONFIG_DIR
my $BSD  = tempdir(CLEANUP => 1);   # BUTLER_STATE_DIR
for ($HOME, $PROJ, $CFG, $BSD) { s{\\}{/}g }

$ENV{HOME}              = $HOME;
$ENV{USERPROFILE}       = $HOME;
$ENV{ALMANAC_HOME}      = $HOME;
$ENV{CLAUDE_CONFIG_DIR} = $CFG;
$ENV{BUTLER_STATE_DIR}  = $BSD;
delete $ENV{CCPRAXIS_DATA_DIR};
delete $ENV{CLAUDE_PROJECT_DIR};

sub run {
    my (@args) = @_;
    my $cmd = qq{ALMANAC_HOME="$HOME" HOME="$HOME" USERPROFILE="$HOME" }
            . qq{CLAUDE_CONFIG_DIR="$CFG" BUTLER_STATE_DIR="$BSD" perl "$A" }
            . join(' ', @args) . ' 2>&1';
    my $out = `$cmd`;
    return ($? >> 8, $out // '');
}
sub body_of {
    my ($p) = @_;
    open my $f, '<:raw', $p or return '';
    local $/; my $t = <$f>;
    return $t =~ /\A---\r?\n.*?\r?\n---\r?\n(.*)\z/s ? $1 : '';
}
sub field_of {
    my ($p, $k) = @_;
    open my $f, '<:raw', $p or return undef;
    local $/; my $t = <$f>;
    return $t =~ /^\Q$k\E:\s*(.*)$/m ? $1 : undef;
}

# ---------------------------------------------------------------------------
# Ticket minting (spec sec 5.4): a claim's identity comes ONLY from a butler
# hook ticket, keyed on sha1(name, argv). mint_ticket's argv must equal
# EXACTLY the argv the almanac-bug.pl subprocess receives.
# ---------------------------------------------------------------------------
my $TICKET_SEQ = 0;
sub ensure_transcript {
    my ($sid) = @_;
    my $dir = "$CFG/projects/p";
    make_path($dir) unless -d $dir;
    my $path = "$dir/$sid.jsonl";
    unless (-f $path) {
        open my $fh, '>', $path or die "fixture: cannot write transcript $path: $!";
        print {$fh} "{}\n";
        close $fh;
    }
    return $path;
}
sub mint_ticket {
    my ($session, $agent, @argv) = @_;
    my $transcript = ensure_transcript($session);
    local $ENV{BUTLER_STATE_DIR} = $BSD;
    my $ok = BpHook::write_ticket(
        { session_id => $session, tool_use_id => 'T' . (++$TICKET_SEQ),
          (defined $agent ? (agent_id => $agent) : ()),
          transcript_path => $transcript, cwd => $PROJ },
        'almanac-bug', [ @argv ]);
    die "fixture: could not write ticket for (@argv)\n" unless $ok;
    return;
}
# run_as($session, $agent_or_undef, @args) -- mints a ticket for EXACTLY
# @args, then spawns almanac-bug.pl with that same argv. Use this (never
# plain run()) for any set-status call whose --to or current status is
# triaging.
sub run_as {
    my ($session, $agent, @args) = @_;
    mint_ticket($session, $agent, @args);
    return run(@args);
}

# ---- AC1: state machine constants, loaded in-process (no subprocess) ------
#
# `do $A` executes the script with a defined caller(), so its own
# `unless (caller) { ... }` CLI block never runs — only the package-level
# declarations load. Same technique almanac-doctor.t already uses.
{
    local $@;
    do $A;
    diag("AC1: loading $A failed: $@") if $@;
}
# RENAMED (blueprint where-things-go, package 07-bug-lifecycle, Decision 8):
# taken -> scheduled, resolved -> fixed, declined -> dropped. %LEGACY_STATUS
# now ALSO maps the two retired-but-mappable names (resolved, declined) on
# read, on top of the pre-existing reviewing -> triaging mapping; `taken` is
# deliberately NOT in %LEGACY_STATUS (it cannot be mapped without a package
# link -- see bug-lifecycle.t for the migration oracle).
is_deeply(\@AlmanacBug::STATES, [qw(open triaging scheduled fixed dropped)],
    'AC1: @AlmanacBug::STATES is open triaging scheduled fixed dropped');
ok(!exists $AlmanacBug::NEXT{reviewing}, 'AC1: %NEXT has no reviewing key');
ok(!exists $AlmanacBug::NEXT{taken}, 'AC1: %NEXT has no taken key (retired)');
is_deeply($AlmanacBug::NEXT{triaging}, [qw(scheduled open dropped)],
    "AC1: \$NEXT{triaging} is scheduled open dropped");
is_deeply($AlmanacBug::NEXT{scheduled}, [qw(fixed dropped)],
    "AC1: \$NEXT{scheduled} is fixed dropped");
is_deeply($AlmanacBug::NEXT{fixed}, [], "AC1: \$NEXT{fixed} is terminal (empty)");
is_deeply($AlmanacBug::NEXT{dropped}, [], "AC1: \$NEXT{dropped} is terminal (empty)");
is($AlmanacBug::LEGACY_STATUS{reviewing}, 'triaging',
    "AC1: \$LEGACY_STATUS{reviewing} eq 'triaging'");
is($AlmanacBug::LEGACY_STATUS{resolved}, 'fixed',
    "AC1: \$LEGACY_STATUS{resolved} eq 'fixed'");
is($AlmanacBug::LEGACY_STATUS{declined}, 'dropped',
    "AC1: \$LEGACY_STATUS{declined} eq 'dropped'");
ok(!exists $AlmanacBug::LEGACY_STATUS{taken},
    "AC1: \$LEGACY_STATUS{taken} is NOT set -- it cannot be mapped without a package link");

# ---- AC2: USAGE and doc text no longer say "reviewing" ---------------------
{
    my ($rc_usage, $out_usage) = run();
    like($out_usage, qr/triaging/, 'AC2: USAGE mentions triaging');
    like($out_usage, qr/takeover/, 'AC2: USAGE mentions the takeover verb');
    unlike($out_usage, qr/reviewing/i, 'AC2: USAGE no longer mentions reviewing');
}
{
    (my $ALMANAC_DIR = "$Bin/../..") =~ s{\\}{/}g;
    for my $rel (qw(skills/bug-triage/SKILL.md skills/bug-report/SKILL.md hooks/guard-almanac-write.sh)) {
        my $p = "$ALMANAC_DIR/$rel";
        SKIP: {
            skip "AC2: $rel missing", 1 unless -f $p;
            open my $fh, '<:raw', $p or do { fail("AC2: cannot read $rel"); last SKIP; };
            local $/; my $txt = <$fh>; close $fh;
            unlike($txt, qr/reviewing/i, "AC2: $rel contains no 'reviewing' (case-insensitive)");
        }
    }
}

# ---- file ------------------------------------------------------------------
my ($rc, $out) = run('file', '--project', $PROJ, '--title', '"judge deadlocks"',
                     '--severity', 'high', '--area', 'butler', '--body', '"it exits before writing"');
is($rc, 0, 'file: creates a report') or diag $out;
chomp(my $path = $out);
ok(-f $path, 'file: the report exists on disk');
like($path, qr{/\.ccpraxis-local-data/bug-reports/[^/]+\.md$}, 'file: lands in the reports dir');
my ($id) = $path =~ m{/([^/]+)\.md$};
is(field_of($path, 'status'), 'open', 'file: starts open');
is(field_of($path, 'severity'), 'high', 'file: records severity');

# A report with no body is noise, and the script says so rather than writing it.
my ($rc_nb) = run('file', '--project', $PROJ, '--title', '"empty"');
isnt($rc_nb, 0, 'file: refuses a report with no body');

# ---- update while open -----------------------------------------------------
#
# RE-POINTED 2026-08-29: a whole-body REPLACEMENT now requires --replace.
#
# The claim being asserted is unchanged -- a filer can still revise their own
# report while it is open, and the revision really lands. What changed is that
# the destructive form must say so, because `update` was one keystroke away from
# erasing a report and there is no undo (reports are gitignored). That happened
# to 20260828-095201-7c1e; see the destructive-update block further down, which
# pins both the refusal and the escape hatches.
my ($rc_u) = run('update', $id, '--project', $PROJ, '--body', '"revised while open"', '--replace');
is($rc_u, 0, 'update --replace: allowed while open');
like(body_of($path), qr/revised while open/, 'update --replace: the body actually changed');

# ---- AC3: the renamed state refuses the OLD name, with a hint -------------
{
    my ($rc3, $out3) = run('set-status', $id, '--project', $PROJ, '--to', 'reviewing');
    isnt($rc3, 0, 'AC3: --to reviewing is refused');
    like($out3, qr/use --to triaging/, 'AC3: STDERR tells the caller to use --to triaging');
    is(field_of($path, 'status'), 'open', 'AC3: the report stays open after the refused call');
}

# ---- AC5 (specs/07-bug-lifecycle-spec.md section 2.4 step 1): the THREE
# retired bug-lifecycle target names (taken, resolved, declined) each refuse
# with their own rename hint, before anything else is written, and the file
# stays byte-identical -- package 07-bug-lifecycle, Decision 8.
#
# A FRESH report, deliberately -- not $id/$path. Under the CURRENT (pre-
# package-07) implementation these three old names are still legal targets,
# so a refusal here is exactly what is under test; reusing the main report
# would let an erroneously-accepted `declined` silently retire it before the
# rest of this file's lifecycle assertions ever run.
# ---------------------------------------------------------------------------
{
    my (undef, $o5) = run('file', '--project', $PROJ, '--title', '"ac5 retired names"', '--body', '"b"');
    chomp(my $path5 = $o5);
    my ($id5) = $path5 =~ m{/([^/]+)\.md$};
    my $before = body_of($path5);
    my ($rcT, $outT) = run('set-status', $id5, '--project', $PROJ, '--to', 'taken');
    isnt($rcT, 0, 'AC5: --to taken is refused');
    like($outT, qr/use --to scheduled --package <blueprint>\/<package>/,
        'AC5: ...STDERR tells the caller to use --to scheduled --package');
    my ($rcR, $outR) = run('set-status', $id5, '--project', $PROJ, '--to', 'resolved');
    isnt($rcR, 0, 'AC5: --to resolved is refused');
    like($outR, qr/replaced by 'fixed'/, "AC5: ...STDERR says it was replaced by 'fixed'");
    my ($rcD, $outD) = run('set-status', $id5, '--project', $PROJ, '--to', 'declined');
    isnt($rcD, 0, 'AC5: --to declined is refused');
    like($outD, qr/use --to dropped --note/, 'AC5: ...STDERR tells the caller to use --to dropped --note');
    is(field_of($path5, 'status'), 'open', 'AC5: the report stays open after all three refused calls');
    is(body_of($path5), $before, 'AC5: the body is byte-identical after all three refused calls');
}

# ---- freeze ----------------------------------------------------------------
my ($rc_r) = run_as('S1', undef, 'set-status', $id, '--project', $PROJ, '--to', 'triaging');
is($rc_r, 0, 'set-status: open -> triaging (AC4), claimed by a hook ticket');
is(field_of($path, 'status'), 'triaging', 'status is triaging');
my $digest = field_of($path, 'content_sha256');
ok(defined $digest && length $digest, 'leaving open RECORDS a body digest');
ok(defined field_of($path, 'frozen_at'), '...and stamps frozen_at');

my ($rc_u2, $out_u2) = run('update', $id, '--project', $PROJ, '--body', '"sneaky rewrite"');
isnt($rc_u2, 0, 'update: REFUSED once triaging');
like($out_u2, qr/frozen/i, '...and the refusal explains why (AC17)');
like($out_u2, qr/triaging/i, '...and names triaging specifically, not the old name (AC17)');
unlike(body_of($path), qr/sneaky rewrite/, '...and the body is genuinely unchanged');

# ---- transitions -----------------------------------------------------------
#
# RENAMED (package 07-bug-lifecycle): `resolved` is retired (AC5 above covers
# its own refusal). The "you cannot skip the middle step" claim is now best
# demonstrated by `fixed`, which can NEVER be reached by hand from ANY state
# -- it is set only by reconcile (spec sec 2.4 step 2) -- so attempting it
# from `triaging` is refused with that specific message, not "not a legal
# transition".
my ($rc_bad, $out_bad) = run_as('S1', undef, 'set-status', $id, '--project', $PROJ, '--to', 'fixed');
isnt($rc_bad, 0, 'triaging -> fixed is refused -- fixed is never set by hand (AC4)');
like($out_bad, qr/is set only by reconcile/, '...and the refusal names reconcile');

my ($rc_x) = run_as('S1', undef, 'set-status', $id, '--project', $PROJ, '--to', 'nonsense');
isnt($rc_x, 0, 'an unknown state is refused');

# `scheduled` requires a valid --package (spec sec 2.4 step 5), validated
# against a real ledger.
(my $pkg_dir = "$PROJ/.ccpraxis-local-data/blueprints/smtest/packages") =~ s{\\}{/}g;
make_path($pkg_dir);
open(my $pfh, '>:raw', "$pkg_dir/01-smtest.md") or die "fixture: cannot write package ledger: $!";
print {$pfh} "---\nstatus: running\n---\n";
close $pfh;

is((run_as('S1', undef, 'set-status', $id, '--project', $PROJ, '--to', 'scheduled', '--package', 'smtest/01-smtest'))[0], 0,
   'triaging -> scheduled, by the claimant, with a valid --package (AC4)');
ok(defined field_of($path, 'scheduled_at'), 'scheduled stamps scheduled_at');
is(field_of($path, 'package'), 'smtest/01-smtest', 'scheduled records the package link');

my ($rc_fixed_by_hand, $out_fixed_by_hand) = run('set-status', $id, '--project', $PROJ, '--to', 'fixed');
isnt($rc_fixed_by_hand, 0, 'scheduled -> fixed by hand is refused -- fixed is set only by reconcile');
like($out_fixed_by_hand, qr/is set only by reconcile/, '...and the refusal names reconcile');

is((run('set-status', $id, '--project', $PROJ, '--to', 'dropped', '--note', '"fixed in abc123"'))[0], 0,
   'scheduled -> dropped');
is(field_of($path, 'resolution'), 'fixed in abc123', 'the resolution note is recorded');

my ($rc_term) = run('set-status', $id, '--project', $PROJ, '--to', 'scheduled', '--package', 'smtest/01-smtest');
isnt($rc_term, 0, 'dropped is TERMINAL — no transitions out of it');

# ---- hand-back unfreezes ---------------------------------------------------
# A triager who wants more from the filer must be able to give the report back,
# or "frozen" becomes a trap rather than a guarantee.
{
    my (undef, $o) = run('file', '--project', $PROJ, '--title', '"second"', '--body', '"b"');
    chomp(my $p2 = $o); my ($id2) = $p2 =~ m{/([^/]+)\.md$};
    run_as('S2', undef, 'set-status', $id2, '--project', $PROJ, '--to', 'triaging');
    is((run_as('S2', undef, 'set-status', $id2, '--project', $PROJ, '--to', 'open'))[0], 0,
       'triaging -> open hands it back, by the claimant (AC4)');
    is(field_of($p2, 'content_sha256'), undef, 'handing back CLEARS the digest');
    # `append` rather than `update --replace`: the claim here is that handing a
    # report back to the filer lets them EDIT it again, and adding detail is the
    # shape that actually means. Using the destructive verb to prove
    # "editable" was always slightly beside the point.
    is((run('append', $id2, '--project', $PROJ, '--body', '"more detail"'))[0], 0,
       '...and the filer can edit again');
}

# ---- tamper detection: the layer that cannot be routed around --------------
my $id3;
{
    my (undef, $o) = run('file', '--project', $PROJ, '--title', '"third"', '--body', '"original body"');
    chomp(my $p3 = $o); ($id3) = $p3 =~ m{/([^/]+)\.md$};
    run_as('S3', undef, 'set-status', $id3, '--project', $PROJ, '--to', 'triaging');
    my $digest3 = field_of($p3, 'content_sha256');

    is((run('verify', '--project', $PROJ))[0], 0, 'verify: clean while nothing has been tampered with');

    # Write straight past the script and the hook, the way a determined Bash
    # call would. Neither can stop this; the digest is what catches it.
    open my $fh, '<:raw', $p3 or die; local $/; my $raw = <$fh>; close $fh;
    $raw =~ s/original body/tampered body/;
    open my $w, '>:raw', $p3 or die; print {$w} $raw; close $w;

    my ($rc_v, $out_v) = run('verify', '--project', $PROJ);
    isnt($rc_v, 0, 'verify: DETECTS an out-of-band edit to a frozen report (AC15/B13)');
    like($out_v, qr/TAMPERED/, '...and says so unmistakably');

    my ($rc_c, $out_c) = run('collect', '--project', $PROJ);
    is($rc_c, 0, 'collect: exits 0 even with a tampered report present (AC11/B9)');
    like($out_c, qr/^!! TAMPERED: \Q$id3\E\b/m,
         'collect: a column-0 TAMPERED summary line names the report (AC11)');

    # AC3: the laundering path is closed -- the claimant can no longer move a
    # tampered triaging report to open and have its digest silently cleared.
    my ($rc_open, $out_open) = run_as('S3', undef, 'set-status', $id3, '--project', $PROJ, '--to', 'open');
    isnt($rc_open, 0, 'AC3: claimant set-status --to open on a tampered report is refused');
    like($out_open, qr/TAMPERED/, 'AC3: ...with a TAMPERED refusal');
    is(field_of($p3, 'content_sha256'), $digest3,
       'AC3: the digest is NOT cleared by the refused --to open (the laundering path is closed)');
    is(field_of($p3, 'status'), 'triaging', 'AC3: the report stays triaging after the refusal');
}

# ---- listing ---------------------------------------------------------------
{
    my ($rc_l, $l) = run('list', '--project', $PROJ);
    is($rc_l, 0, 'list: exits 0 even with a tampered report present (AC10/B9)');
    like($l, qr/judge deadlocks/, 'list: shows this project\'s reports');
    my ($rc_lj, $lj) = run('list', '--project', $PROJ, '--json');
    is($rc_lj, 0, 'list --json: exits 0 (AC12/B10)');
    my $parsed = eval { JSON::PP->new->decode($lj) };
    ok(ref $parsed eq 'ARRAY', 'list --json: emits a JSON array');
    SKIP: {
        skip 'AC12: decode failed', 2 unless ref $parsed eq 'ARRAY';
        my ($row3) = grep { ($_->{id} // '') eq $id3 } @$parsed;
        ok(defined $row3, 'AC12: tampered row present in list --json output')
            or diag "AC12: id $id3 missing from --json output: $lj";
        SKIP: {
            skip 'AC12: tampered row not found in list --json (failed above)', 1 unless defined $row3;
            like($row3->{integrity}, qr/^TAMPERED: /,
                 "AC12: the tampered report's integrity field matches ^TAMPERED: ");
        }
    }
    my (undef, $lo) = run('list', '--project', $PROJ, '--status', 'open');
    unlike($lo, qr/judge deadlocks/, 'list --status open: filters out the dropped one');

    # collect always includes the CURRENT project even when it is not in the
    # registry — a report filed from an unregistered project must still be
    # visible to the person standing in it. Cross-project discovery is covered
    # by the registry block below.
    my (undef, $c) = run('collect', '--project', $PROJ);
    like($c, qr/judge deadlocks/, 'collect: includes the current project unconditionally');
}

# ---- discovery: the registry, not an index, and not glob -------------------
#
# The first design kept an append-only index under the writer's $HOME. That is
# broken for the primary filer: inside a sandbox, $HOME/.claude IS the project's
# own claude-home (bind-mounted at /root/.claude), so the index write lands in
# that one project and never reaches the host — the machine-wide index would
# silently miss exactly the reports it exists to collect. Discovery now walks
# steward's machine-local project registry, the same one /steward:backup uses.
{
    my $HOME2 = tempdir(CLEANUP => 1);
    my $P1 = tempdir(CLEANUP => 1);
    my $P2 = tempdir(CLEANUP => 1);
    # A path with a SPACE. Perl's built-in glob splits its argument on
    # whitespace, so "/…/Personal Files/Job search/…" came back as fragments and
    # the directory was never read. Two of this machine's registered projects
    # have spaces, so this silently missed real reports.
    my $P3 = "$P2/proj with spaces";
    mkdir $P3 or die;

    my $reg = "$HOME2/.claude/claude-code-vault";
    for my $d ("$HOME2/.claude", $reg) { mkdir $d or die "mkdir $d: $!" }
    open my $rf, '>:raw', "$reg/.registry-local.json" or die;
    print {$rf} JSON::PP->new->canonical->encode({ version => 1, projects => {
        one     => { path => $P1 },
        spaced  => { path => $P3 },
    }});
    close $rf;

    my $run2 = sub {
        my (@a) = @_;
        my $c = qq{ALMANAC_HOME="$HOME2" perl "$A" } . join(' ', @a) . ' 2>&1';
        my $o = `$c`; return ($? >> 8, $o // '');
    };

    $run2->('file', '--project', qq{"$P1"}, '--title', '"in project one"', '--body', '"b"');
    $run2->('file', '--project', qq{"$P3"}, '--title', '"in the spaced project"', '--body', '"b"');

    my (undef, $out2) = $run2->('collect');
    like($out2, qr/in project one/,
         'collect finds a report via the registry, with no index anywhere');
    like($out2, qr/in the spaced project/,
         'collect finds one in a project whose PATH CONTAINS A SPACE (glob split these away)');

    # And nothing was written outside the projects themselves.
    ok(!-e "$HOME2/.claude/almanac", 'no index directory is created under $HOME');
    ok(!-e "$HOME2/.claude/ccpraxis/bug-index.jsonl", 'nothing is written into the live install');
}

# ---- update must not silently destroy the report it is updating -----------
#
# `update` replaces the body wholesale. That is a legitimate verb, but its most
# common use is ADDING progress -- and the obvious invocation for that deletes
# everything the filer wrote, in one step, with no confirmation and no undo
# (reports live under a gitignored directory).
#
# Done exactly that to 20260828-095201-7c1e on 2026-08-29: an update meant to
# record progress erased the original evidence -- the pid, the nine-day uptime,
# the CPU figure, the probe source. It was recoverable only because the whole
# report happened to still be in the agent's context.
#
# Three properties, and the third is what keeps this from being a nuisance
# rather than a guard: a deliberate rewrite must still be possible.
{
    my $ap = "$PROJ/orig-body.md";
    open my $ofh, '>', $ap or die "fixture: $!"; print {$ofh} "ORIGINAL EVIDENCE\npid 87244\n"; close $ofh;
    my $np = "$PROJ/new-body.md";
    open my $nfh, '>', $np or die "fixture: $!"; print {$nfh} "PROGRESS NOTE\nfixed in abc123\n"; close $nfh;

    my (undef, $out) = run('file', '--project', $PROJ, '--title', '"destructive-update probe"',
                           '--severity', 'low', '--area', 'sandbox', '--body-file', qq{"$ap"});
    chomp(my $dpath = $out);
    my ($did) = $dpath =~ m{/([^/]+)\.md$};

    # 1. The destructive shape is refused, and the refusal names BOTH ways out.
    my ($rc_d, $out_d) = run('update', $did, '--project', $PROJ, '--body-file', qq{"$np"});
    isnt($rc_d, 0, 'update: refuses a body that would discard the existing one');
    like($out_d, qr/\bappend\b/,   'update: ...the refusal points at `append`');
    like($out_d, qr/--replace/,    'update: ...and at --replace');
    like(body_of($dpath), qr/pid 87244/, 'update: the original body is untouched after the refusal');

    # 2. append keeps both halves.
    my ($rc_a) = run('append', $did, '--project', $PROJ, '--body-file', qq{"$np"});
    is($rc_a, 0, 'append: succeeds on an open report');
    like(body_of($dpath), qr/pid 87244/,      'append: the original body survives');
    like(body_of($dpath), qr/fixed in abc123/, 'append: ...and the new text is there too');

    # 3. A deliberate rewrite is still possible -- otherwise this guard would
    #    just be an obstacle, and the next person would route around it.
    my ($rc_r) = run('update', $did, '--project', $PROJ, '--body-file', qq{"$np"}, '--replace');
    is($rc_r, 0, 'update --replace: an intentional rewrite is still allowed');
    unlike(body_of($dpath), qr/pid 87244/, 'update --replace: ...and it really did replace');

    # 3b. A BOOLEAN FLAG FOLLOWED BY ANOTHER FLAG MUST SURVIVE PARSING.
    #
    # The CLI parser read `--foo` then decided whether the NEXT argv element was
    # its value, using `$ARGV[0] !~ /^--/`. That lookahead is itself a match, and
    # a successful match resets the capture variables -- so `--replace --body x`
    # reset $1 to undef and stored the flag under the EMPTY key. The flag was
    # silently dropped: the command then ran as though it had never been passed.
    #
    # Latent for as long as every flag in this CLI happened to carry a value.
    # Asserted here with the boolean FIRST, which is the order that broke.
    {
        my (undef, $o2) = run('file', '--project', $PROJ, '--title', '"flag-order probe"',
                              '--severity', 'low', '--area', 'sandbox', '--body-file', qq{"$ap"});
        chomp(my $fp = $o2);
        my ($fid) = $fp =~ m{/([^/]+)\.md$};
        my ($rc_o) = run('update', $fid, '--project', $PROJ, '--replace', '--body-file', qq{"$np"});
        is($rc_o, 0, 'argv: a boolean flag placed BEFORE another flag is not silently dropped');
        like(body_of($fp), qr/fixed in abc123/, 'argv: ...and the command actually took effect');
    }

    # 4. append respects the freeze, exactly as update does. Adding a paragraph
    #    to a report someone is triaging changes what they are reading just as
    #    surely as rewriting it.
    run_as('S4', undef, 'set-status', $did, '--project', $PROJ, '--to', 'triaging');
    my ($rc_f, $out_f) = run('append', $did, '--project', $PROJ, '--body-file', qq{"$np"});
    isnt($rc_f, 0, 'append: refused once the report is frozen (AC17)');
    like($out_f, qr/frozen/, '...and says why (AC17)');
    like($out_f, qr/triaging/i, '...and names triaging specifically (AC17)');
}

# ---- repairing a report that is OUTSIDE the machine -----------------------
#
# A status that is not one of @STATES cannot be reached by any transition, so
# can_transition rejects it as an unknown CURRENT state -- correct for a typo,
# but it left no way out. 20260825-193930-fff0 carried an out-of-machine
# status, written by hand or by a version predating this machine, and was
# wedged: set-status refused it and guard-almanac-write.sh denies editing the
# reports directory directly. Correct by every rule, unfixable by every
# sanctioned path.
#
# RENAMED (package 07-bug-lifecycle): `fixed` is now an IN-MACHINE state (set
# only by reconcile), so it can no longer stand in for "a status outside
# @STATES" -- this fixture uses `closed` instead, a status that equally
# predates this machine and still belongs to no version of @STATES.
#
# --repair is that path. These assertions exist to keep it NARROW: the value is
# in what it still refuses.
{
    my ($rc_f, $out_f) = run('file', '--project', $PROJ, '--title', '"legacy report"',
                             '--severity', 'low', '--area', 'sandbox', '--body', '"filed before the machine"');
    is($rc_f, 0, 'repair fixture: a report was filed') or diag $out_f;
    chomp(my $lpath = $out_f);
    my ($lid) = $lpath =~ m{/([^/]+)\.md$};

    # Put it outside the machine the only way anything ever did -- by writing
    # the frontmatter directly. This is the situation being recovered from, so
    # the fixture has to create it the same way it arose.
    {
        open my $fh, '<:raw', $lpath or die "fixture: cannot read $lpath: $!";
        local $/; my $t = <$fh>; close $fh;
        $t =~ s/^status:\s*open$/status: closed/m;
        open my $out, '>:raw', $lpath or die "fixture: cannot write $lpath: $!";
        print {$out} $t; close $out;
    }
    is(field_of($lpath, 'status'), 'closed', 'repair fixture: the report is now outside the state machine');

    # 1. Without --repair it is still refused -- but the message must say how to
    #    recover, or the operator is left exactly as stuck as before.
    my ($rc_no, $out_no) = run('set-status', $lid, '--project', $PROJ, '--to', 'dropped', '--note', '"stale"');
    isnt($rc_no, 0, 'repair: set-status still refuses an out-of-machine report without --repair');
    like($out_no, qr/--repair/, 'repair: ...and the refusal names the way out');

    # 2. --repair does NOT become a general override. From a VALID state, an
    #    illegal transition stays illegal -- this is the assertion that stops the
    #    flag turning into "skip the state machine".
    my ($rc_f2, $out_f2) = run('file', '--project', $PROJ, '--title', '"ordinary report"',
                               '--severity', 'low', '--area', 'sandbox', '--body', '"still open"');
    chomp(my $opath = $out_f2);
    my ($oid) = $opath =~ m{/([^/]+)\.md$};
    my ($rc_skip, $out_skip) = run('set-status', $oid, '--project', $PROJ,
                                   '--to', 'scheduled', '--repair');
    isnt($rc_skip, 0, 'repair: --repair CANNOT skip a legal transition from a valid state');
    like($out_skip, qr/not a legal transition/, 'repair: ...it is refused for the ordinary reason');
    is(field_of($opath, 'status'), 'open', 'repair: the refused report is untouched');

    # 3. The target must still be a real state.
    my ($rc_bad) = run('set-status', $lid, '--project', $PROJ, '--to', 'bogus', '--repair');
    isnt($rc_bad, 0, 'repair: --repair still refuses an unknown target state');

    # 3b. --repair cannot reach `fixed` either -- that refusal is unconditional
    # (spec sec 2.4 step 2), regardless of how far outside the machine the
    # report currently is.
    my ($rc_fx, $out_fx) = run('set-status', $lid, '--project', $PROJ, '--to', 'fixed', '--repair');
    isnt($rc_fx, 0, 'repair: --repair cannot reach fixed -- it is set only by reconcile');
    like($out_fx, qr/is set only by reconcile/, 'repair: ...with the reconcile-only message');

    # 4. And it works.
    my ($rc_ok, $out_ok) = run('set-status', $lid, '--project', $PROJ,
                               '--to', 'dropped', '--note', '"stale, filed before the machine"', '--repair');
    is($rc_ok, 0, 'repair: --repair moves an out-of-machine report into a valid state') or diag $out_ok;
    is(field_of($lpath, 'status'), 'dropped', 'repair: the status is now a real state');
    like($out_ok, qr/repaired/, 'repair: the output SAYS it was a repair, not an ordinary transition');
}

# ---- AC19: this file never touched the REAL machine state ------------------
{
    my $after_butler = snapshot_dir($REAL_BUTLER_STATE);
    my $after_bugs   = snapshot_dir($REAL_BUG_REPORTS);
    is_deeply($after_butler, $HYGIENE_BEFORE_BUTLER,
        'AC19: the real ~/.claude/butler-state is untouched by this file');
    is_deeply($after_bugs, $HYGIENE_BEFORE_BUGS,
        'AC19: the real repo .ccpraxis-local-data/bug-reports is untouched by this file');
}

done_testing();
