#!/usr/bin/env perl
# platform: any
# ORACLE for blueprint tooling-fixes, package 12-bug-claimant-and-triaging,
# AC5-AC16 and AC18 of specs/12-bug-claimant-and-triaging-spec.md sec 4
# (Decision 31, hole 1 of 3): `triaging` becomes a CLAIM. The claimant's
# identity comes ONLY from a butler hook ticket (BpHook::take_ticket), never
# from a CLI argument; only the claimant can move a triaging report on or
# back; a claim with no transcript or older than 24h is STALE, reported by
# list/collect/doctor, and can be taken over by the explicit `takeover` verb;
# a report still saying `reviewing` on disk (pre-migration) reads as a
# claimless `triaging`, never rewritten by a mere read.
#
# WRITTEN BLIND TO THE IMPLEMENTATION: at the time this file is written,
# almanac-bug.pl has NO claimant/ticket/takeover logic at all, almanac.pl's
# route table has no `takeover` verb, almanac-doctor.pl has no STALE-CLAIM
# finding, and ContinuityOffCheck issues tickets for only the three pre-
# existing names. Every assertion below is EXPECTED TO FAIL (red) until
# package 12 lands -- that is the point of a failing-first oracle.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Glob qw(bsd_glob);
use JSON::PP;
use Digest::SHA ();

# GuardHarness also require()s plugins/butler/scripts/BpHook.pm (exactly the
# same absolute path almanac-bug.pl's own claim logic will load), so BpHook::*
# is available here without a second, divergent require.
(my $GH_LIB = "$Bin/../../../butler/tests/lib") =~ s{\\}{/}g;
use lib "$Bin/../../../butler/tests/lib";
require GuardHarness;

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
my $A       = "$S/almanac-bug.pl";
my $ALMANAC = "$S/almanac.pl";
my $DOCTOR  = "$S/almanac-doctor.pl";
ok(-f $A,       'almanac-bug.pl exists')    or BAIL_OUT('script missing');
ok(-f $ALMANAC, 'almanac.pl exists')        or BAIL_OUT('script missing');
ok(-f $DOCTOR,  'almanac-doctor.pl exists') or BAIL_OUT('script missing');

(my $BUTLER_DIR = "$Bin/../../../butler") =~ s{\\}{/}g;
my $COC_SH = "$BUTLER_DIR/hooks/continuity-off-check.sh";
ok(-f $COC_SH, 'continuity-off-check.sh exists') or BAIL_OUT('hook missing');

# ---------------------------------------------------------------------------
# AC19 hygiene (shared with bug-state-machine.t, each file for its own
# scope): snapshot the REAL ~/.claude/butler-state and the real repo's
# .ccpraxis-local-data/bug-reports BEFORE this file touches $ENV{HOME} etc.
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
# Isolated environment (spec sec 4): fresh tempdirs for everything a claim
# operation could touch.
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

sub _env_prefix {
    return qq{ALMANAC_HOME="$HOME" HOME="$HOME" USERPROFILE="$HOME" }
         . qq{CLAUDE_CONFIG_DIR="$CFG" BUTLER_STATE_DIR="$BSD" };
}
sub run {
    my (@args) = @_;
    my $cmd = _env_prefix() . qq{perl "$A" } . join(' ', @args) . ' 2>&1';
    my $out = `$cmd`;
    return ($? >> 8, $out // '');
}
sub run_doctor {
    my (@args) = @_;
    my $cmd = _env_prefix() . qq{perl "$DOCTOR" } . join(' ', @args) . ' 2>&1';
    my $out = `$cmd`;
    return ($? >> 8, $out // '');
}
sub run_almanac {
    my (@args) = @_;
    my $cmd = _env_prefix() . qq{perl "$ALMANAC" } . join(' ', @args) . ' 2>&1';
    my $out = `$cmd`;
    return ($? >> 8, $out // '');
}
sub slurp_raw {
    my ($p) = @_;
    open my $f, '<:raw', $p or return undef;
    local $/; my $t = <$f>; close $f;
    return $t;
}
sub body_of {
    my ($p) = @_;
    my $t = slurp_raw($p) // '';
    return $t =~ /\A---\r?\n.*?\r?\n---\r?\n(.*)\z/s ? $1 : '';
}
sub field_of {
    my ($p, $k) = @_;
    my $t = slurp_raw($p);
    return undef unless defined $t;
    return $t =~ /^\Q$k\E:\s*(.*)$/m ? $1 : undef;
}
sub rewrite_field {
    my ($path, $key, $val) = @_;
    my $raw = slurp_raw($path);
    if ($raw =~ /^\Q$key\E:.*$/m) { $raw =~ s/^\Q$key\E:.*$/$key: $val/m }
    else                          { $raw =~ s/^---\n/---\n$key: $val\n/ }
    open my $fh, '>:raw', $path or die "fixture: cannot write $path: $!";
    print {$fh} $raw;
    close $fh;
}

# ---------------------------------------------------------------------------
# Ticket minting (spec sec 5.4): a claim's identity comes ONLY from a hook
# ticket, keyed on sha1(name, argv). The argv a mint_ticket*() call is given
# must equal EXACTLY the argv the almanac-bug.pl subprocess receives.
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
# mint_ticket_raw($session, $agent_or_undef, $transcript_or_undef, @argv)
sub mint_ticket_raw {
    my ($session, $agent, $transcript, @argv) = @_;
    local $ENV{BUTLER_STATE_DIR} = $BSD;
    my $ok = BpHook::write_ticket(
        { session_id => $session, tool_use_id => 'T' . (++$TICKET_SEQ),
          (defined $agent ? (agent_id => $agent) : ()),
          transcript_path => $transcript, cwd => $PROJ },
        'almanac-bug', [ @argv ]);
    die "fixture: could not write ticket for (@argv)\n" unless $ok;
    return;
}
# mint_ticket($session, $agent_or_undef, @argv) -- WITH a live transcript, so
# the claim it produces is never stale-by-transcript.
sub mint_ticket {
    my ($session, $agent, @argv) = @_;
    return mint_ticket_raw($session, $agent, ensure_transcript($session), @argv);
}
# age_transcript($sid, $seconds_ago) -- blueprint where-things-go package 03:
# claim staleness is now judged by TRANSCRIPT mtime (Almanac::SessionLive),
# never by claimed_at age alone, so fixtures that need a stale claim must
# age the transcript file ensure_transcript() wrote, not just rewrite
# claimed_at on the report.
sub age_transcript {
    my ($sid, $seconds_ago) = @_;
    my $path = "$CFG/projects/p/$sid.jsonl";
    utime(time - $seconds_ago, time - $seconds_ago, $path) if -f $path;
    return $path;
}
# run_as($session, $agent_or_undef, @args) -- mints a ticket for EXACTLY
# @args (with a transcript), then spawns almanac-bug.pl with that same argv.
sub run_as {
    my ($session, $agent, @args) = @_;
    mint_ticket($session, $agent, @args);
    return run(@args);
}

# ---------------------------------------------------------------------------
# AlmanacBug package functions, loaded in-process (no subprocess) for fixture
# building only -- `do $A` executes the script with a defined caller(), so
# its own CLI block never runs.
# ---------------------------------------------------------------------------
{
    local $@;
    do $A;
    diag("loading $A for fixtures failed: $@") if $@;
}

# mk_legacy_report(%opts) -> ($path, $id, $body) -- a report hand-written
# with `status: reviewing` plus a valid digest, bypassing the CLI entirely,
# to simulate a file that predates this migration (spec sec 2.2/8).
my $LEGACY_SEQ = 0;
sub mk_legacy_report {
    my (%o) = @_;
    my $id   = $o{id}   // (AlmanacBug::new_id() . sprintf('-leg%02d', ++$LEGACY_SEQ));
    my $body = $o{body} // "legacy body text, filed before claims existed.\n";
    my $now  = AlmanacBug::_iso(time);
    my $dir  = AlmanacBug::reports_dir($PROJ);
    make_path($dir) unless -d $dir;
    my $path = "$dir/$id.md";
    my %f = (
        id => $id, title => ($o{title} // 'legacy report'), status => 'reviewing',
        severity => 'unknown', area => 'unknown', project => $PROJ,
        created_at => $now, updated_at => $now, frozen_at => $now,
        content_sha256 => AlmanacBug::body_digest($body),
    );
    my @order = qw(id title status severity area project created_at updated_at frozen_at content_sha256);
    open my $fh, '>:raw', $path or die "fixture: cannot write $path: $!";
    print {$fh} "---\n" . join("\n", map { "$_: $f{$_}" } @order) . "\n---\n$body";
    close $fh;
    return ($path, $id, $body);
}

# =============================================================================
# AC5 -- a legacy `reviewing` report reads as a claimless `triaging`, is
# flagged STALE, is never rewritten by a read, and can be taken over.
# =============================================================================
{
    my ($path, $id, $body) = mk_legacy_report(title => 'legacy reviewing report');
    my $raw_before = slurp_raw($path);

    my (undef, $lj) = run('list', '--project', $PROJ, '--json');
    my $parsed = eval { JSON::PP->new->decode($lj) };
    my ($row) = grep { ($_->{id} // '') eq $id } @{ $parsed || [] };
    ok(defined $row, 'AC5: the legacy report appears in list --json') or diag $lj;
    SKIP: {
        skip 'AC5: row not found, cannot inspect its fields', 2 unless defined $row;
        is($row->{status}, 'triaging', 'AC5: legacy "reviewing" is read as "triaging"');
        is($row->{stale_claim}, 'no claimant recorded', 'AC5: stale_claim is "no claimant recorded"');
    }

    is(slurp_raw($path), $raw_before, 'AC5: list did not rewrite the legacy file bytes');
    run('collect', '--project', $PROJ);
    is(slurp_raw($path), $raw_before, 'AC5: collect did not rewrite the legacy file bytes');
    run('verify', '--project', $PROJ);
    is(slurp_raw($path), $raw_before, 'AC5: verify did not rewrite the legacy file bytes');

    my ($rc_ss, $out_ss) = run_as('LS1', undef, 'set-status', $id, '--project', $PROJ, '--to', 'scheduled');
    isnt($rc_ss, 0, 'AC5: set-status on a claimless legacy triaging report is refused');
    like($out_ss, qr/takeover/, 'AC5: ...and the refusal names takeover');
    is(slurp_raw($path), $raw_before, 'AC5: the refused set-status left the file bytes untouched');

    my ($rc_to, $out_to) = run_as('LS1', undef, 'takeover', $id, '--project', $PROJ);
    is($rc_to, 0, 'AC5: takeover succeeds on a legacy claimless report') or diag $out_to;
    is(field_of($path, 'status'), 'triaging', 'AC5: the file now says status: triaging');
    is(field_of($path, 'taken_over_from'), 'none', 'AC5: taken_over_from is none (no prior claimant)');
    is(field_of($path, 'claimant_session'), 'LS1', 'AC5: claimant_session is the taking-over caller');
}

# =============================================================================
# AC6/AC7 -- behavior 1: claim from open records fields and consumes the
# ticket; an agent_id ticket records claimant_agent, a main-thread one does
# not.
# =============================================================================
{
    my (undef, $o) = run('file', '--project', $PROJ, '--title', '"ac6 claim"', '--body', '"b"');
    chomp(my $path = $o); my ($id) = $path =~ m{/([^/]+)\.md$};

    my @argv = ('set-status', $id, '--project', $PROJ, '--to', 'triaging');
    mint_ticket('S6', undef, @argv);
    my ($rc, $out) = run(@argv);
    is($rc, 0, 'AC6: claim from open exits 0') or diag $out;
    like($out, qr/\Q$id\E: open -> triaging/, 'AC6: prints "<id>: open -> triaging"');
    is(field_of($path, 'status'), 'triaging', 'AC6: status is triaging');
    is(field_of($path, 'claimant_session'), 'S6', 'AC6: claimant_session is S6');
    ok(!defined field_of($path, 'claimant_agent'), 'AC6: no claimant_agent line for a main-thread claim');
    my $claimed_at = field_of($path, 'claimed_at');
    ok(defined $claimed_at && length $claimed_at, 'AC6: claimed_at is recorded');
    ok(defined field_of($path, 'content_sha256'), 'AC6: content_sha256 is written');
    ok(defined field_of($path, 'frozen_at'), 'AC6: frozen_at is written');

    my ($rc2) = run(@argv);
    isnt($rc2, 0, 'AC6: the ticket was consumed -- a second identical call with no new ticket is refused');
}
{
    my (undef, $o) = run('file', '--project', $PROJ, '--title', '"ac7 claim agent"', '--body', '"b"');
    chomp(my $path = $o); my ($id) = $path =~ m{/([^/]+)\.md$};
    my @argv = ('set-status', $id, '--project', $PROJ, '--to', 'triaging');
    mint_ticket('S7', 'AG1', @argv);
    my ($rc) = run(@argv);
    is($rc, 0, 'AC7: claim with an agent_id ticket exits 0');
    is(field_of($path, 'claimant_agent'), 'AG1', 'AC7: claimant_agent AG1 is recorded');
}

# =============================================================================
# AC8 -- behavior 2: no ticket is refused, exit 2, "no hook ticket", file
# byte-identical, and no identity-looking flag or env var changes anything.
# =============================================================================
{
    my (undef, $o) = run('file', '--project', $PROJ, '--title', '"ac8 no ticket"', '--body', '"b"');
    chomp(my $path = $o); my ($id) = $path =~ m{/([^/]+)\.md$};
    my $raw_before = slurp_raw($path);
    local $ENV{CLAUDE_CODE_SESSION_ID} = 'EVIL-ENV';
    my ($rc, $out) = run('set-status', $id, '--project', $PROJ, '--to', 'triaging',
                          '--claimant', 'EVIL', '--session', 'EVIL', '--agent', 'EVIL', '--session-id', 'EVIL');
    isnt($rc, 0, 'AC8: no ticket -> refused');
    is($rc, 2, 'AC8: exit code is 2');
    like($out, qr/no hook ticket/, 'AC8: STDERR says "no hook ticket"');
    is(slurp_raw($path), $raw_before, 'AC8: the file bytes are unchanged');
    is(field_of($path, 'status'), 'open', 'AC8: the report stays open');
}

# =============================================================================
# AC9 -- behavior 3: a ticket minted for argv containing identity-looking
# flags records the TICKET's session, never the flag values.
# =============================================================================
{
    my (undef, $o) = run('file', '--project', $PROJ, '--title', '"ac9 forged args"', '--body', '"b"');
    chomp(my $path = $o); my ($id) = $path =~ m{/([^/]+)\.md$};
    my @argv = ('set-status', $id, '--project', $PROJ, '--to', 'triaging', '--claimant', 'EVIL', '--session', 'EVIL');
    mint_ticket('REAL-SESSION', undef, @argv);
    my ($rc) = run(@argv);
    is($rc, 0, 'AC9: the claim succeeds (the ticket wins over the forged-looking flags)');
    is(field_of($path, 'claimant_session'), 'REAL-SESSION', 'AC9: claimant_session is the TICKET session, never EVIL');
}

# =============================================================================
# AC10 -- behavior 4: a non-claimant (another session, or a sibling agent of
# the claiming session) is refused for scheduled/open/dropped (RENAMED from
# taken/open/declined, blueprint where-things-go package 07-bug-lifecycle);
# the claimant is named; the file is unchanged.
# =============================================================================
{
    my (undef, $o) = run('file', '--project', $PROJ, '--title', '"ac10 claimant"', '--body', '"b"');
    chomp(my $path = $o); my ($id) = $path =~ m{/([^/]+)\.md$};
    run_as('S1', 'A1', 'set-status', $id, '--project', $PROJ, '--to', 'triaging');
    is(field_of($path, 'status'), 'triaging', 'AC10 setup: claimed by S1/A1');

    for my $to (qw(scheduled open dropped)) {
        my $raw_before = slurp_raw($path);
        my ($rc, $out) = run_as('S2', undef, 'set-status', $id, '--project', $PROJ, '--to', $to);
        isnt($rc, 0, "AC10: another session is refused moving it to $to");
        like($out, qr/claimed by session S1/, "AC10: ...the refusal names the claimant (to $to)");
        like($out, qr/only the claimant/, "AC10: ...and says only the claimant may act (to $to)");
        is(slurp_raw($path), $raw_before, "AC10: the file is unchanged after the refusal (to $to)");

        my ($rc2, $out2) = run_as('S1', 'A2', 'set-status', $id, '--project', $PROJ, '--to', $to);
        isnt($rc2, 0, "AC10: a sibling agent (same session S1, different agent) is refused moving it to $to");
        like($out2, qr/claimed by session S1/, "AC10: ...names the claimant for the sibling too (to $to)");
        is(slurp_raw($path), $raw_before, "AC10: the file is unchanged after the sibling refusal (to $to)");
    }
}

# =============================================================================
# AC11 -- behavior 5: the claimant (or the claiming session's own main
# thread, acting on its subagent's claim) moves it on; moving to `open`
# removes every claim/takeover field.
# =============================================================================
{
    my (undef, $o) = run('file', '--project', $PROJ, '--title', '"ac11a same agent"', '--body', '"b"');
    chomp(my $path = $o); my ($id) = $path =~ m{/([^/]+)\.md$};
    run_as('S1', 'A1', 'set-status', $id, '--project', $PROJ, '--to', 'triaging');
    # RENAMED (package 07-bug-lifecycle): the old target 'taken' is retired.
    # 'dropped' is used here instead of 'scheduled' deliberately -- this
    # assertion is about claim fields surviving a transition OUT of triaging
    # by the claimant, which 'dropped' exercises without needing a package
    # ledger fixture (scheduled's --package requirement is orthogonal and
    # covered in bug-lifecycle.t).
    my ($rc) = run_as('S1', 'A1', 'set-status', $id, '--project', $PROJ, '--to', 'dropped', '--note', '"not reproducible"');
    is($rc, 0, 'AC11: the claimant (same session+agent) moves it to dropped');
    is(field_of($path, 'claimant_session'), 'S1', 'AC11: the claim fields are KEPT after moving to dropped');
}
{
    my (undef, $o) = run('file', '--project', $PROJ, '--title', '"ac11b main thread"', '--body', '"b"');
    chomp(my $path = $o); my ($id) = $path =~ m{/([^/]+)\.md$};
    run_as('S1', 'A1', 'set-status', $id, '--project', $PROJ, '--to', 'triaging');
    my ($rc) = run_as('S1', undef, 'set-status', $id, '--project', $PROJ, '--to', 'open');
    is($rc, 0, "AC11: S1's own main thread moves its subagent A1's claim back to open");
    for my $k (qw(claimant_session claimant_agent claimed_at taken_over_from taken_over_at taken_over_reason)) {
        ok(!defined field_of($path, $k), "AC11: $k is removed after moving to open");
    }
}

# =============================================================================
# AC12 -- staleness by absent transcript.
# =============================================================================
{
    my (undef, $o) = run('file', '--project', $PROJ, '--title', '"ac12 no transcript"', '--body', '"b"');
    chomp(my $path = $o); my ($id) = $path =~ m{/([^/]+)\.md$};
    my @argv = ('set-status', $id, '--project', $PROJ, '--to', 'triaging');
    mint_ticket_raw('STALE-NOTX', undef, undef, @argv);
    run(@argv);
    is(field_of($path, 'status'), 'triaging', 'AC12 setup: claimed with no transcript for the claiming session');

    my (undef, $lo) = run('list', '--project', $PROJ);
    like($lo, qr/!! STALE CLAIM: claimant session STALE-NOTX has no transcript on this machine/,
         'AC12: list shows the STALE CLAIM line for an absent transcript');
    my (undef, $co) = run('collect', '--project', $PROJ);
    like($co, qr/!! STALE CLAIM: claimant session STALE-NOTX has no transcript on this machine/,
         'AC12: collect shows it too');
    my (undef, $lj) = run('list', '--project', $PROJ, '--json');
    my $parsed = eval { JSON::PP->new->decode($lj) };
    my ($row) = grep { ($_->{id} // '') eq $id } @{ $parsed || [] };
    SKIP: {
        skip 'AC12: row not found', 1 unless defined $row;
        is($row->{stale_claim}, 'claimant session STALE-NOTX has no transcript on this machine',
           'AC12: --json carries stale_claim with the same reason');
    }
}

# =============================================================================
# AC13 -- EDITED for blueprint where-things-go package 03-thread-sessions
# (specs/03-thread-sessions-spec.md section 2.11/behaviour 15): staleness is
# now judged by the claimant's TRANSCRIPT activity (Almanac::SessionLive),
# never by claimed_at age alone -- a 25h-old claimed_at with a FRESH
# transcript is explicitly NOT stale; a transcript idle past the shared
# $IDLE_SECONDS (60m) threshold IS stale, with the new reason text.
# =============================================================================
{
    my (undef, $o) = run('file', '--project', $PROJ, '--title', '"ac13 idle transcript"', '--body', '"b"');
    chomp(my $path = $o); my ($id) = $path =~ m{/([^/]+)\.md$};
    run_as('AGE1', undef, 'set-status', $id, '--project', $PROJ, '--to', 'triaging');

    age_transcript('AGE1', 2 * 3600); # 120m idle, unarmed -- dead/idle
    my (undef, $lo) = run('list', '--project', $PROJ);
    like($lo, qr/!! STALE CLAIM: claimant session AGE1 has been idle 120m \(dead after 60m\)/,
        'AC13: a claim whose transcript has been idle 120m is stale, with the new idle-based reason text');

    my (undef, $lj) = run('list', '--project', $PROJ, '--json');
    my $parsed = eval { JSON::PP->new->decode($lj) };
    my ($row) = grep { ($_->{id} // '') eq $id } @{ $parsed || [] };
    SKIP: {
        skip 'AC13: row not found', 1 unless defined $row;
        is($row->{stale_claim}, 'claimant session AGE1 has been idle 120m (dead after 60m)',
            'AC13: --json carries the same idle-based stale_claim reason');
    }
}
{
    my (undef, $o) = run('file', '--project', $PROJ, '--title', '"ac13 age alone is not enough"', '--body', '"b"');
    chomp(my $path = $o); my ($id) = $path =~ m{/([^/]+)\.md$};
    run_as('AGE2', undef, 'set-status', $id, '--project', $PROJ, '--to', 'triaging');

    # claimed_at alone, aged 25h, with the transcript left fresh (as
    # ensure_transcript() wrote it): behaviour 15 -- age alone no longer
    # stales a claim.
    rewrite_field($path, 'claimed_at', AlmanacBug::_iso(time - 25 * 3600));
    my (undef, $lo2) = run('list', '--project', $PROJ);
    my ($lo2_row) = grep { /\Q$id\E/ } split /\n/, $lo2;
    unlike($lo2_row // '', qr/STALE CLAIM/,
        'AC13: a 25h-old claimed_at with a FRESH transcript is NOT stale (age alone no longer stales a claim)');
    my (undef, $lj2) = run('list', '--project', $PROJ, '--json');
    my $parsed2 = eval { JSON::PP->new->decode($lj2) };
    my ($row2) = grep { ($_->{id} // '') eq $id } @{ $parsed2 || [] };
    SKIP: {
        skip 'AC13: row not found', 1 unless defined $row2;
        ok(!exists $row2->{stale_claim}, 'AC13: --json carries no stale_claim when only claimed_at is old');
    }
}

# =============================================================================
# AC13b -- transcript-root VISIBILITY fallback (S2 / red-team M1 fix),
# EDITED for package 03-thread-sessions: a claimant_transcript_path whose
# ROOT is not visible from this process falls back to the claim/attach time
# (SessionLive::judge's "since" basis) against the ARMED threshold (780m =
# 13h), not the old 24h age-only rule. Distinct from AC12 (root IS visible,
# file genuinely missing -> stale regardless of age).
# =============================================================================
{
    # A path whose grandparent directory ($HOME/no-such-mount-<n>) never
    # exists at all -- simulates a different mount/filesystem scope (e.g. a
    # sandbox checking a host claim), NOT a deleted file under a real root.
    my $invisible_root = "$HOME/no-such-mount-ac13b";
    ok(!-d $invisible_root, 'AC13b setup: the simulated root does not exist on disk');
    my $invisible_tpath = "$invisible_root/p/SID-AC13B.jsonl";

    my (undef, $o) = run('file', '--project', $PROJ, '--title', '"ac13b invisible root recent"', '--body', '"b"');
    chomp(my $path = $o); my ($id) = $path =~ m{/([^/]+)\.md$};
    my @argv = ('set-status', $id, '--project', $PROJ, '--to', 'triaging');
    mint_ticket_raw('VIS-RECENT', undef, $invisible_tpath, @argv);
    run(@argv);
    is(field_of($path, 'status'), 'triaging', 'AC13b setup: claimed with an invisible-root transcript path');
    is(field_of($path, 'claimant_transcript_path'), $invisible_tpath,
       'AC13b setup: claimant_transcript_path is recorded as given');

    # Recent claim (<24h, just claimed): must NOT be reported stale -- the
    # invisible root must fall back to the age rule, not be treated as proof
    # of staleness on its own.
    my (undef, $lo) = run('list', '--project', $PROJ);
    my ($lo_row) = grep { /\Q$id\E/ } split /\n/, $lo;
    unlike($lo_row // '', qr/STALE CLAIM/,
        'AC13b: a recent claim with an invisible transcript root is NOT reported stale');
    my (undef, $lj) = run('list', '--project', $PROJ, '--json');
    my $parsed = eval { JSON::PP->new->decode($lj) };
    my ($row) = grep { ($_->{id} // '') eq $id } @{ $parsed || [] };
    SKIP: {
        skip 'AC13b: row not found', 1 unless defined $row;
        ok(!exists $row->{stale_claim}, 'AC13b: --json carries no stale_claim for a recent invisible-root claim');
    }
    my (undef, $out_to_live) = run_as('OTHER-AC13B', undef, 'takeover', $id, '--project', $PROJ);
    like($out_to_live, qr/claim is live/,
        'AC13b: takeover of the recent invisible-root claim is refused as live (since-fallback says live)');

    # Age the same claim's claimed_at past the ARMED threshold (780m = 13h):
    # the since-fallback must still catch it -- invisibility must not ALSO
    # suppress staleness forever.
    rewrite_field($path, 'claimed_at', AlmanacBug::_iso(time - 14 * 3600));
    my (undef, $lo2) = run('list', '--project', $PROJ);
    like($lo2, qr/!! STALE CLAIM: claim is 840m old and its transcript is not visible here \(dead after 780m\)/,
        'AC13b: the same invisible-root claim, aged past 13h, IS reported stale (since-fallback still fires)');
    my ($rc_takeover, $out_takeover) = run_as('OTHER-AC13B-2', undef, 'takeover', $id, '--project', $PROJ);
    is($rc_takeover, 0, 'AC13b: takeover of the now-stale (by since-fallback) invisible-root claim succeeds') or diag $out_takeover;
    is(field_of($path, 'claimant_session'), 'OTHER-AC13B-2',
        'AC13b: the new claimant is recorded after takeover of the aged invisible-root claim');
}

# =============================================================================
# AC14 -- almanac-doctor.pl reports STALE-CLAIM, with a takeover repair hint,
# and exits 1; a live claim gives no such line for that report.
# =============================================================================
{
    my (undef, $o) = run('file', '--project', $PROJ, '--title', '"ac14 stale doctor"', '--body', '"b"');
    chomp(my $path = $o); my ($id) = $path =~ m{/([^/]+)\.md$};
    run_as('DOC-STALE', undef, 'set-status', $id, '--project', $PROJ, '--to', 'triaging');
    age_transcript('DOC-STALE', 2 * 3600); # package 03: staleness is transcript-idle-based now

    my ($rc, $out) = run_doctor('--root', $PROJ);
    is($rc, 1, 'AC14: doctor exits 1 when a STALE-CLAIM finding exists');
    like($out, qr/STALE-CLAIM: project bug\/\Q$id\E:/, 'AC14: doctor prints the STALE-CLAIM line');
    like($out, qr/repair: almanac bug takeover \Q$id\E/, 'AC14: ...with the takeover repair hint');

    my (undef, $o2) = run('file', '--project', $PROJ, '--title', '"ac14 live doctor"', '--body', '"b"');
    chomp(my $path2 = $o2); my ($id2) = $path2 =~ m{/([^/]+)\.md$};
    run_as('DOC-LIVE', undef, 'set-status', $id2, '--project', $PROJ, '--to', 'triaging');
    my (undef, $out2) = run_doctor('--root', $PROJ);
    unlike($out2, qr/STALE-CLAIM: project bug\/\Q$id2\E:/, 'AC14: a live claim gives no STALE-CLAIM line for it');
}

# =============================================================================
# AC15 -- behavior 6: takeover of a stale claim records the new claimant and
# the takeover trail; the old claimant is then refused; takeover of a live
# claim, or of an open report, is refused.
# =============================================================================
{
    my (undef, $o) = run('file', '--project', $PROJ, '--title', '"ac15 stale takeover"', '--body', '"b"');
    chomp(my $path = $o); my ($id) = $path =~ m{/([^/]+)\.md$};
    run_as('OLDC', 'OLDA', 'set-status', $id, '--project', $PROJ, '--to', 'triaging');
    age_transcript('OLDC', 2 * 3600); # package 03: staleness is transcript-idle-based now

    my ($rc, $out) = run_as('NEWC', undef, 'takeover', $id, '--project', $PROJ);
    is($rc, 0, 'AC15: takeover of a stale claim succeeds') or diag $out;
    like($out, qr/\Q$id\E: claim taken over from session OLDC agent OLDA/,
         'AC15: prints the takeover line naming the old claimant');
    is(field_of($path, 'claimant_session'), 'NEWC', 'AC15: the new claimant is recorded');
    is(field_of($path, 'taken_over_from'), 'OLDC/OLDA', 'AC15: taken_over_from records the old session/agent');
    ok(defined field_of($path, 'taken_over_at'), 'AC15: taken_over_at is recorded');
    ok(defined field_of($path, 'taken_over_reason'), 'AC15: taken_over_reason is recorded');

    my ($rc_old, $out_old) = run_as('OLDC', 'OLDA', 'set-status', $id, '--project', $PROJ, '--to', 'scheduled');
    isnt($rc_old, 0, 'AC15: the OLD claimant is refused after the takeover');
    like($out_old, qr/claimed by session NEWC/, 'AC15: ...and the refusal names the new claimant');
}
{
    my (undef, $o) = run('file', '--project', $PROJ, '--title', '"ac15 live takeover"', '--body', '"b"');
    chomp(my $path = $o); my ($id) = $path =~ m{/([^/]+)\.md$};
    run_as('LIVEC', undef, 'set-status', $id, '--project', $PROJ, '--to', 'triaging');
    my ($rc, $out) = run_as('OTHER', undef, 'takeover', $id, '--project', $PROJ);
    isnt($rc, 0, 'AC15: takeover of a LIVE claim is refused');
    like($out, qr/claim is live/, 'AC15: ...and says the claim is live');
    is(field_of($path, 'claimant_session'), 'LIVEC', 'AC15: the live claimant is unchanged');
}
{
    my (undef, $o) = run('file', '--project', $PROJ, '--title', '"ac15 open takeover"', '--body', '"b"');
    chomp(my $path = $o); my ($id) = $path =~ m{/([^/]+)\.md$};
    my ($rc) = run_as('X', undef, 'takeover', $id, '--project', $PROJ);
    isnt($rc, 0, 'AC15: takeover of an OPEN report is refused');
    is(field_of($path, 'status'), 'open', 'AC15: the open report is untouched');
}

# =============================================================================
# AC16 -- `almanac.pl bug takeover <id>` routes, and the ticket bound through
# the dispatcher's own argv (almanac-bug.pl's argv, not almanac.pl's) works.
# =============================================================================
{
    my (undef, $o) = run('file', '--project', $PROJ, '--title', '"ac16 dispatch takeover"', '--body', '"b"');
    chomp(my $path = $o); my ($id) = $path =~ m{/([^/]+)\.md$};
    run_as('AC16OLD', undef, 'set-status', $id, '--project', $PROJ, '--to', 'triaging');
    age_transcript('AC16OLD', 2 * 3600); # package 03: staleness is transcript-idle-based now

    # almanac.pl strips the leading 'bug' word and passes the rest unchanged
    # to almanac-bug.pl -- the ticket must be minted for THAT argv.
    my @dispatch_argv = ('takeover', $id, '--project', $PROJ);
    mint_ticket('AC16NEW', undef, @dispatch_argv);
    my ($rc, $out) = run_almanac('bug', @dispatch_argv);
    is($rc, 0, 'AC16: almanac.pl bug takeover routes, and the dispatcher-bound ticket works') or diag $out;
    is(field_of($path, 'claimant_session'), 'AC16NEW', 'AC16: the new claimant is recorded via the dispatcher');
}

# =============================================================================
# AC17 is bug-state-machine.t's (behavior 11, update/append frozen specifically
# for `triaging`). Not repeated here.
# =============================================================================

# =============================================================================
# AC5 (package 03-thread-sessions, specs/03-thread-sessions-spec.md section
# 2.11) -- the stale rule is switched to Almanac::SessionLive: the source no
# longer names the retired age-only constant or the BpSession dependency.
# =============================================================================
{
    open(my $fh, '<:raw', $A) or die "cannot read $A: $!";
    local $/;
    my $src = <$fh>;
    close $fh;
    unlike($src, qr/\bCLAIM_STALE_SECONDS\b/, 'AC5: almanac-bug.pl source no longer contains CLAIM_STALE_SECONDS');
    unlike($src, qr/\bBpSession\b/, 'AC5: almanac-bug.pl source no longer contains BpSession');
    like($src, qr/\bAlmanac::SessionLive\b/, 'AC5: almanac-bug.pl source now names Almanac::SessionLive');
}
{
    # claim_state never dies with butler absent (SessionLive never loads
    # butler, so a missing BpHook.pm must not crash the stale check).
    local $ENV{BUTLER_STATE_DIR} = '/no-such-butler-state-dir-ac5';
    my (undef, $o) = run('file', '--project', $PROJ, '--title', '"ac5 butler absent"', '--body', '"b"');
    chomp(my $path = $o); my ($id) = $path =~ m{/([^/]+)\.md$};
    run_as('AC5BA', undef, 'set-status', $id, '--project', $PROJ, '--to', 'triaging');
    my (undef, $lo) = run('list', '--project', $PROJ);
    ok(defined $lo, 'AC5: list does not die when BUTLER_STATE_DIR points nowhere (claim_state never dies)');
}

# =============================================================================
# AC18 -- behavior 12: ContinuityOffCheck issues `almanac-bug` tickets for
# both command shapes with the right argv/session/agent; no ticket for
# `bug list` / `todo`; the hook's own exec line now carries text:almanac.
# =============================================================================
{
    my $src = GuardHarness::read_bytes($COC_SH);
    my @lines = grep { length } split /\n/, $src;
    my $last = @lines ? $lines[-1] : '';
    like($last, qr/\btext:almanac\b/, 'AC18: continuity-off-check.sh last line mentions text:almanac');
}
sub _payload_bash_18 {
    my (%o) = @_;
    my $p = { hook_event_name => 'PreToolUse', tool_name => 'Bash', tool_input => { command => $o{cmd} } };
    $p->{session_id}  = $o{session_id}  if exists $o{session_id};
    $p->{agent_id}    = $o{agent_id}    if exists $o{agent_id};
    $p->{tool_use_id} = $o{tool_use_id} if exists $o{tool_use_id};
    $p->{cwd}         = $o{cwd}         if exists $o{cwd};
    return $p;
}
sub _tw_18       { my ($p, %env) = @_; return GuardHarness::run_module('ContinuityOffCheck', $p, env => \%env) }
sub _tickets_18  { my ($st) = @_; return sort(bsd_glob("$st/tickets/*/*.json")) }

# Shape 1: a direct almanac-bug.pl invocation.
{
    local %ENV = %ENV;
    GuardHarness::fresh_state();
    my $ST = BpHook::state_dir();
    my @argv = ('set-status', 'BUG1', '--to', 'triaging', '--project', '/p');
    my $cmd  = q{perl /x/almanac-bug.pl } . join(' ', @argv);
    my $res  = _tw_18(_payload_bash_18(cmd => $cmd, session_id => 'ASESS', tool_use_id => 'T1', cwd => '/proj'));
    is($res->{rc}, 0, 'AC18: direct almanac-bug.pl set-status --to triaging -> rc 0');
    my @tf = _tickets_18($ST);
    is(scalar(@tf), 1, 'AC18: exactly one ticket file (direct shape)');
    my $t = BpHook::take_ticket('almanac-bug', \@argv);
    is(ref($t), 'HASH', 'AC18: take_ticket(almanac-bug, ...) returns a HASH (direct shape)');
    is(ref($t) eq 'HASH' ? $t->{session_id} : 'unreachable', 'ASESS', 'AC18: session_id ASESS (direct shape)');
}

# Shape 2: through the almanac.pl dispatcher ("bug set-status ...").
{
    local %ENV = %ENV;
    GuardHarness::fresh_state();
    my $ST = BpHook::state_dir();
    my @full_argv   = ('bug', 'set-status', 'BUG2', '--to', 'triaging', '--project', '/p');
    my @expect_argv = @full_argv[1 .. $#full_argv];
    my $cmd = q{perl "/x/plugins/almanac/scripts/almanac.pl" } . join(' ', @full_argv);
    my $res = _tw_18(_payload_bash_18(cmd => $cmd, session_id => 'BSESS', agent_id => 'BAG', tool_use_id => 'T1', cwd => '/proj'));
    is($res->{rc}, 0, 'AC18: dispatcher almanac.pl bug set-status --to triaging -> rc 0');
    my @tf = _tickets_18($ST);
    is(scalar(@tf), 1, 'AC18: exactly one ticket file (dispatcher shape)');
    my $t = BpHook::take_ticket('almanac-bug', \@expect_argv);
    is(ref($t), 'HASH', 'AC18: take_ticket(almanac-bug, ...) returns a HASH (dispatcher shape)');
    is(ref($t) eq 'HASH' ? $t->{session_id} : 'unreachable', 'BSESS', 'AC18: session_id BSESS (dispatcher shape)');
    is(ref($t) eq 'HASH' ? $t->{agent_id}   : 'unreachable', 'BAG',   'AC18: agent_id BAG (dispatcher shape)');
}

# No ticket for `almanac bug list` or `almanac todo create`.
{
    local %ENV = %ENV;
    GuardHarness::fresh_state();
    my $ST = BpHook::state_dir();
    for my $c (
        q{perl "/x/plugins/almanac/scripts/almanac.pl" bug list},
        q{perl "/x/plugins/almanac/scripts/almanac.pl" todo create --title "x"},
    ) {
        _tw_18(_payload_bash_18(cmd => $c, session_id => 'CSESS', tool_use_id => 'T1', cwd => '/proj'));
    }
    my @tf = _tickets_18($ST);
    is(scalar(@tf), 0, 'AC18: no ticket for bug list / todo create');
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
