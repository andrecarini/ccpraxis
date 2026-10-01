#!/usr/bin/env perl
# platform: any
# ORACLE for blueprint tooling-fixes, package 14-bug-tamper-check-always,
# specs/14-bug-tamper-check-always-spec.md sec 3-4 (AC1-AC16, Decision 31 hole
# 3 of 3): every almanac-bug.pl verb must verify the digest of each frozen
# report it touches or lists, BEFORE doing anything else with it. The four
# mutating verbs (set-status, takeover, append, update) refuse a tampered
# report with a loud TAMPERED message and write nothing; list/collect still
# show a tampered report (exit 0) but flag it with a column-0
# "!! TAMPERED: <id> ..." summary line, even when --status would otherwise
# have excluded its row; verify keeps its existing exit-2 behavior.
#
# WRITTEN BLIND TO THE IMPLEMENTATION: at the time this file is written,
# almanac-bug.pl only checks tampering on an explicit `verify` call and inside
# list/collect's loop AFTER the --status filter has already dropped excluded
# rows; none of update/append/set-status/takeover call AlmanacBug::verify at
# all, and `set-status <id> --to open` on a tampered triaging report DELETES
# its content_sha256 (the laundering bug this package closes). Every
# assertion below that depends on the automatic tamper check is EXPECTED TO
# FAIL (red) until this package lands -- that is the point of a
# failing-first oracle, not a bug in this file.
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
# AC16 hygiene: snapshot the REAL ~/.claude/butler-state and the real repo's
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
# Isolated environment: fresh tempdirs for everything, one fresh PROJECT
# tempdir per scenario (spec sec 4.1 note: "a tampered report from one block
# cannot affect another's list assertions").
# ---------------------------------------------------------------------------
my $HOME = tempdir(CLEANUP => 1);
my $CFG  = tempdir(CLEANUP => 1);   # CLAUDE_CONFIG_DIR
my $BSD  = tempdir(CLEANUP => 1);   # BUTLER_STATE_DIR
for ($HOME, $CFG, $BSD) { s{\\}{/}g }

$ENV{HOME}              = $HOME;
$ENV{USERPROFILE}       = $HOME;
$ENV{ALMANAC_HOME}      = $HOME;
$ENV{CLAUDE_CONFIG_DIR} = $CFG;
$ENV{BUTLER_STATE_DIR}  = $BSD;
delete $ENV{CCPRAXIS_DATA_DIR};
delete $ENV{CLAUDE_PROJECT_DIR};

sub new_project {
    my $p = tempdir(CLEANUP => 1);
    $p =~ s{\\}{/}g;
    return $p;
}

sub run {
    my (@args) = @_;
    my $cmd = qq{ALMANAC_HOME="$HOME" HOME="$HOME" USERPROFILE="$HOME" }
            . qq{CLAUDE_CONFIG_DIR="$CFG" BUTLER_STATE_DIR="$BSD" perl "$A" }
            . join(' ', @args) . ' 2>&1';
    my $out = `$cmd`;
    return ($? >> 8, $out // '');
}
sub slurp_raw {
    my ($p) = @_;
    open my $f, '<:raw', $p or return undef;
    local $/; my $t = <$f>;
    close $f;
    return $t;
}
sub field_of {
    my ($p, $k) = @_;
    my $t = slurp_raw($p);
    return undef unless defined $t;
    return $t =~ /^\Q$k\E:\s*(.*)$/m ? $1 : undef;
}

# tamper_body($path) -- write straight past the script and the hook, the way
# a determined Bash call would: append bytes after the frontmatter, changing
# the body without touching the recorded content_sha256 field at all.
sub tamper_body {
    my ($path) = @_;
    open my $fh, '>>:raw', $path or die "fixture: cannot append to $path: $!";
    print {$fh} "\ntampered-out-of-band-byte\n";
    close $fh;
}

# ---------------------------------------------------------------------------
# Ticket minting, exactly as bug-state-machine.t / bug-triage-claim.t do: the
# ticket's argv must equal EXACTLY the argv the almanac-bug.pl subprocess
# receives (BpHook keys a ticket on sha1(name, argv)).
# ---------------------------------------------------------------------------
my $TICKET_SEQ = 0;
sub ensure_transcript {
    my ($session) = @_;
    my $dir = "$CFG/projects/p";
    make_path($dir) unless -d $dir;
    my $path = "$dir/$session.jsonl";
    unless (-f $path) {
        open my $fh, '>', $path or die "fixture: cannot write transcript $path: $!";
        print {$fh} "{}\n";
        close $fh;
    }
    return $path;
}
sub mint_ticket_raw {
    my ($session, $agent, $transcript, $proj, @argv) = @_;
    local $ENV{BUTLER_STATE_DIR} = $BSD;
    my $ok = BpHook::write_ticket(
        { session_id => $session, tool_use_id => 'T' . (++$TICKET_SEQ),
          (defined $agent ? (agent_id => $agent) : ()),
          transcript_path => $transcript, cwd => $proj },
        'almanac-bug', [ @argv ]);
    die "fixture: could not write ticket for (@argv)\n" unless $ok;
    return;
}
sub mint_ticket {
    my ($session, $agent, $proj, @argv) = @_;
    return mint_ticket_raw($session, $agent, ensure_transcript($session), $proj, @argv);
}
# run_as($session, $agent_or_undef, $proj, @args) -- mints a ticket for
# EXACTLY @args, then spawns almanac-bug.pl with that same argv.
sub run_as {
    my ($session, $agent, $proj, @args) = @_;
    mint_ticket($session, $agent, $proj, @args);
    return run(@args);
}

sub file_report {
    my ($proj, $title, $body) = @_;
    my (undef, $o) = run('file', '--project', $proj, '--title', qq{"$title"}, '--body', qq{"$body"});
    chomp(my $path = $o);
    my ($id) = $path =~ m{/([^/]+)\.md$};
    die "fixture: 'file' did not produce a report path/id (got: $o)\n" unless defined $id;
    return ($path, $id);
}
# freeze_report($proj, $session, $title, $body) -> ($path, $id, $digest):
# files a report and moves it open -> triaging as $session (a valid hook
# ticket), returning the recorded content_sha256.
sub freeze_report {
    my ($proj, $session, $title, $body) = @_;
    my ($path, $id) = file_report($proj, $title, $body);
    my ($rc) = run_as($session, undef, $proj, 'set-status', $id, '--project', $proj, '--to', 'triaging');
    die "fixture: freeze failed for $id (rc=$rc)\n" if $rc != 0;
    my $digest = field_of($path, 'content_sha256');
    die "fixture: no content_sha256 recorded for $id after freezing\n" unless defined $digest && length $digest;
    return ($path, $id, $digest);
}

# =============================================================================
# AC1, AC2, AC3 -- B1/B2: set-status refuses a tampered report no matter who
# is asking or whether they have a ticket at all; the tamper check precedes
# every identity/claimant check; the --to open laundering path is closed.
# =============================================================================
{
    my $proj = new_project();
    my ($path, $id, $digest) = freeze_report($proj, 'CLAIM1', 'ac1 tampered triaging', 'original body for ac1');
    tamper_body($path);
    my $bytes_before = slurp_raw($path);

    # AC1: the claimant, WITH a valid ticket, is still refused.
    my ($rc1, $out1) = run_as('CLAIM1', undef, $proj, 'set-status', $id, '--project', $proj, '--to', 'taken');
    is($rc1, 2, 'AC1: claimant set-status --to taken on a tampered report exits 2');
    like($out1, qr/refused/, 'AC1: ...STDERR says refused');
    like($out1, qr/TAMPERED/, 'AC1: ...and TAMPERED');
    like($out1, qr/\Q$id\E/, 'AC1: ...naming the report id');
    is(slurp_raw($path), $bytes_before, 'AC1: the report file is byte-identical after the refusal');

    # AC2: a NON-claimant, with a valid ticket of their own, sees TAMPERED
    # rather than "claimed by session ...".
    my ($rc2, $out2) = run_as('NOTCLAIM1', undef, $proj, 'set-status', $id, '--project', $proj, '--to', 'taken');
    is($rc2, 2, 'AC2: non-claimant set-status on the tampered report also exits 2');
    like($out2, qr/TAMPERED/, 'AC2: ...TAMPERED, not the claimant check');
    unlike($out2, qr/claimed by session/, 'AC2: ...the claimant-mismatch message never fires');

    # AC2: with NO ticket at all, still TAMPERED rather than "no hook ticket".
    my ($rc3, $out3) = run('set-status', $id, '--project', $proj, '--to', 'taken');
    is($rc3, 2, 'AC2: ticketless set-status on the tampered report also exits 2');
    like($out3, qr/TAMPERED/, 'AC2: ...TAMPERED, not the identity check');
    unlike($out3, qr/no hook ticket/, 'AC2: ...the "no hook ticket" message never fires');

    is(slurp_raw($path), $bytes_before, 'AC2: still byte-identical after both further refusals');

    # AC3: the laundering path -- the claimant cannot move a tampered
    # triaging report to open and have content_sha256 silently cleared.
    my ($rc_open, $out_open) = run_as('CLAIM1', undef, $proj, 'set-status', $id, '--project', $proj, '--to', 'open');
    is($rc_open, 2, 'AC3: claimant set-status --to open on a tampered report exits 2');
    like($out_open, qr/TAMPERED/, 'AC3: ...TAMPERED');
    is(field_of($path, 'content_sha256'), $digest,
       'AC3: content_sha256 is NOT cleared by the refused --to open (the laundering path is closed)');
    is(field_of($path, 'status'), 'triaging', 'AC3: status is still triaging after the refusal');
    is(slurp_raw($path), $bytes_before, 'AC3: file byte-identical after the --to open refusal too');
}

# =============================================================================
# AC4 -- B3: a tampered `taken` report refuses both --to resolved and
# --to declined.
# =============================================================================
{
    my $proj = new_project();
    my ($path, $id) = freeze_report($proj, 'CLAIM4', 'ac4 tampered taken', 'original body for ac4');
    my ($rc_take) = run_as('CLAIM4', undef, $proj, 'set-status', $id, '--project', $proj, '--to', 'taken');
    is($rc_take, 0, 'AC4 setup: claimant takes the still-intact report');
    tamper_body($path);
    my $bytes_before = slurp_raw($path);

    for my $to (qw(resolved declined)) {
        my ($rc, $out) = run('set-status', $id, '--project', $proj, '--to', $to);
        is($rc, 2, "AC4: set-status --to $to on a tampered taken report exits 2");
        like($out, qr/TAMPERED/, "AC4: ...TAMPERED ($to)");
        like($out, qr/\Q$id\E/, "AC4: ...naming the id ($to)");
    }
    is(slurp_raw($path), $bytes_before, 'AC4: file byte-identical after both refusals');
}

# =============================================================================
# AC5 -- B4: takeover of a tampered stale-claim report (stale by transcript:
# claimed with a transcript path whose root exists but whose file was
# deleted) is refused as TAMPERED. Control: the identical setup without
# tampering lets takeover succeed.
# =============================================================================
{
    my $proj = new_project();

    # Control: no tampering -- takeover of the stale claim must succeed.
    {
        my ($path, $id) = file_report($proj, 'ac5 control stale claim', 'body for ac5 control');
        my $transcript = ensure_transcript('STALE5CTRL');
        mint_ticket_raw('STALE5CTRL', undef, $transcript, $proj,
            'set-status', $id, '--project', $proj, '--to', 'triaging');
        my ($rc_claim) = run('set-status', $id, '--project', $proj, '--to', 'triaging');
        is($rc_claim, 0, 'AC5 control setup: claimed with a (soon to vanish) transcript');
        unlink $transcript or die "fixture: cannot unlink $transcript: $!";
        ok(!-f $transcript, 'AC5 control setup: the transcript file is gone; its root remains');

        my ($rc, $out) = run_as('OTHER5CTRL', undef, $proj, 'takeover', $id, '--project', $proj);
        is($rc, 0, 'AC5 control: takeover of a stale, NON-tampered claim succeeds') or diag $out;
    }

    # Tampered: the same setup, but the body is tampered -- takeover refuses.
    {
        my ($path, $id) = file_report($proj, 'ac5 tampered stale claim', 'body for ac5 tampered');
        my $transcript = ensure_transcript('STALE5');
        mint_ticket_raw('STALE5', undef, $transcript, $proj,
            'set-status', $id, '--project', $proj, '--to', 'triaging');
        my ($rc_claim) = run('set-status', $id, '--project', $proj, '--to', 'triaging');
        is($rc_claim, 0, 'AC5 setup: claimed with a (soon to vanish) transcript');
        unlink $transcript or die "fixture: cannot unlink $transcript: $!";
        tamper_body($path);
        my $bytes_before = slurp_raw($path);

        my ($rc, $out) = run_as('OTHER5', undef, $proj, 'takeover', $id, '--project', $proj);
        is($rc, 2, 'AC5: takeover of a tampered stale-claim report exits 2');
        like($out, qr/TAMPERED/, 'AC5: ...TAMPERED');
        like($out, qr/\Q$id\E/, 'AC5: ...naming the id');
        is(slurp_raw($path), $bytes_before, 'AC5: file byte-identical (claimant fields not rewritten)');
    }
}

# =============================================================================
# AC6, AC7 -- B5/B6: update --replace and append both refuse a tampered
# frozen report with TAMPERED, pre-empting the "frozen" refusal entirely.
# =============================================================================
{
    my $proj = new_project();
    my ($path, $id) = freeze_report($proj, 'CLAIM6', 'ac6 tampered frozen', 'original body for ac6');
    tamper_body($path);
    my $bytes_before = slurp_raw($path);
    my ($rc, $out) = run('update', $id, '--project', $proj, '--body', '"replacement text"', '--replace');
    is($rc, 2, 'AC6: update --replace on a tampered frozen report exits 2');
    like($out, qr/TAMPERED/, 'AC6: ...TAMPERED');
    like($out, qr/\Q$id\E/, 'AC6: ...naming the id');
    unlike($out, qr/frozen from/, 'AC6: the tamper refusal pre-empts the freeze refusal wording');
    is(slurp_raw($path), $bytes_before, 'AC6: file byte-identical');
}
{
    my $proj = new_project();
    my ($path, $id) = freeze_report($proj, 'CLAIM7', 'ac7 tampered frozen', 'original body for ac7');
    tamper_body($path);
    my $bytes_before = slurp_raw($path);
    my ($rc, $out) = run('append', $id, '--project', $proj, '--body', '"more text"');
    is($rc, 2, 'AC7: append on a tampered frozen report exits 2');
    like($out, qr/TAMPERED/, 'AC7: ...TAMPERED');
    like($out, qr/\Q$id\E/, 'AC7: ...naming the id');
    is(slurp_raw($path), $bytes_before, 'AC7: file byte-identical');
}

# =============================================================================
# AC8 -- B7 controls: intact/clean reports behave exactly as before this
# package; no false TAMPERED anywhere.
# =============================================================================
{
    my $proj = new_project();

    my (undef, $id_a) = freeze_report($proj, 'CLAIM8', 'ac8 intact frozen', 'body a');
    my ($rc_a, $out_a) = run_as('CLAIM8', undef, $proj, 'set-status', $id_a, '--project', $proj, '--to', 'taken');
    is($rc_a, 0, 'AC8: intact frozen report, claimant set-status --to taken still succeeds') or diag $out_a;

    my (undef, $id_b) = file_report($proj, 'ac8 open report', 'body b');
    my ($rc_b, $out_b) = run('append', $id_b, '--project', $proj, '--body', '"more"');
    is($rc_b, 0, 'AC8: append on an open report still succeeds') or diag $out_b;

    my (undef, $id_c) = freeze_report($proj, 'CLAIM8C', 'ac8 intact frozen update', 'body c');
    my ($rc_c, $out_c) = run('update', $id_c, '--project', $proj, '--body', '"x"');
    isnt($rc_c, 0, 'AC8: update on an intact frozen report still refuses');
    like($out_c, qr/frozen/i, 'AC8: ...for the ordinary reason');
    unlike($out_c, qr/TAMPERED/, 'AC8: ...and NOT TAMPERED (no false positive)');
}

# =============================================================================
# AC9 -- B8: `file` in a project that already contains a tampered report
# still succeeds; it touches no existing report, so its output never says
# TAMPERED.
# =============================================================================
{
    my $proj = new_project();
    my ($path) = freeze_report($proj, 'CLAIM9', 'ac9 tampered neighbour', 'body');
    tamper_body($path);
    my ($rc, $out) = run('file', '--project', $proj, '--title', '"ac9 new report"',
                         '--severity', 'low', '--area', 'sandbox', '--body', '"fresh body"');
    is($rc, 0, 'AC9: file still succeeds in a project containing a tampered report');
    unlike($out, qr/TAMPERED/, 'AC9: ...and its output never mentions TAMPERED (it touches nothing existing)');
}

# =============================================================================
# AC10, AC11, AC12, AC13 -- B9/B10/B11: list/collect exit 0, show the
# tampered row AND a column-0 summary line after the footer, even when
# --status would have excluded the row; --json carries integrity but no
# extra text.
# =============================================================================
{
    my $proj = new_project();
    my ($path, $id) = freeze_report($proj, 'CLAIM10', 'ac10 tampered for listing', 'original body for ac10');
    tamper_body($path);

    # AC10
    my ($rc_l, $out_l) = run('list', '--project', $proj);
    is($rc_l, 0, 'AC10: list exits 0 with a tampered report present');
    like($out_l, qr/ac10 tampered for listing/, 'AC10: the tampered report row is shown');
    like($out_l, qr/^  !! TAMPERED: body digest/m, 'AC10: the indented per-row integrity line is shown');
    like($out_l, qr/^!! TAMPERED: \Q$id\E\b/m, 'AC10: a column-0 TAMPERED summary line names the report');
    {
        my $footer_pos = index($out_l, 'report(s)');
        my $summary_pos = ($out_l =~ /^!! TAMPERED: \Q$id\E\b/m) ? $-[0] : -1;
        ok($footer_pos >= 0, 'AC10: sanity -- the report(s) footer is present at all');
        ok($summary_pos >= 0 && $summary_pos > $footer_pos,
           'AC10: the column-0 summary line comes after the report(s) footer');
    }

    # AC11: collect, isolated ALMANAC_HOME with no registry, same project.
    my $HOME11 = tempdir(CLEANUP => 1);
    $HOME11 =~ s{\\}{/}g;
    my $cmd11 = qq{ALMANAC_HOME="$HOME11" perl "$A" collect --project "$proj" 2>&1};
    my $out_c = `$cmd11`;
    my $rc_c = $? >> 8;
    is($rc_c, 0, 'AC11: collect (isolated ALMANAC_HOME, no registry) exits 0');
    like($out_c, qr/^!! TAMPERED: \Q$id\E\b/m, 'AC11: collect also prints the column-0 summary line');

    # AC12: list --json, stdout+stderr merged, decodes as an array, carries
    # integrity, and nothing extra.
    my ($rc_j, $out_j) = run('list', '--project', $proj, '--json');
    is($rc_j, 0, 'AC12: list --json exits 0');
    my $parsed = eval { JSON::PP->new->decode($out_j) };
    ok(ref $parsed eq 'ARRAY', 'AC12: list --json decodes as an array') or diag $out_j;
    SKIP: {
        skip 'AC12: decode failed', 2 unless ref $parsed eq 'ARRAY';
        my ($row) = grep { ($_->{id} // '') eq $id } @$parsed;
        ok(defined $row, 'AC12: tampered row present in list --json output')
            or diag "AC12: id $id missing from --json output: $out_j";
        SKIP: {
            skip 'AC12: tampered row not found (failed above)', 1 unless defined $row;
            like($row->{integrity}, qr/^TAMPERED: /,
                 "AC12: the tampered row's integrity matches ^TAMPERED: ");
        }
    }

    # AC13: --status open excludes the (triaging) tampered row, but the
    # column-0 summary line still surfaces -- this is the exact reordering
    # fix (the check used to run only AFTER the --status filter).
    my ($rc_o, $out_o) = run('list', '--project', $proj, '--status', 'open');
    is($rc_o, 0, 'AC13: list --status open exits 0');
    unlike($out_o, qr/ac10 tampered for listing/, 'AC13: the tampered (triaging) report row is absent');
    like($out_o, qr/^!! TAMPERED: \Q$id\E\b/m, 'AC13: ...but the column-0 summary line is still present');
}

# =============================================================================
# AC14 -- B12: no false positives. A project with only an open report and an
# intact frozen report shows no TAMPERED anywhere.
# =============================================================================
{
    my $proj = new_project();
    file_report($proj, 'ac14 open report', 'body open');
    freeze_report($proj, 'CLAIM14', 'ac14 intact frozen report', 'body frozen');
    my ($rc, $out) = run('list', '--project', $proj);
    is($rc, 0, 'AC14: list exits 0 with no tampering present');
    unlike($out, qr/^!! TAMPERED/m, 'AC14: no column-0 TAMPERED line');
    unlike($out, qr/TAMPERED/, 'AC14: no TAMPERED anywhere in the output');
}

# =============================================================================
# AC16 hygiene: this file never touched the REAL machine state.
# =============================================================================
{
    my $after_butler = snapshot_dir($REAL_BUTLER_STATE);
    my $after_bugs   = snapshot_dir($REAL_BUG_REPORTS);
    is_deeply($after_butler, $HYGIENE_BEFORE_BUTLER,
        'AC16: the real ~/.claude/butler-state is untouched by this file');
    is_deeply($after_bugs, $HYGIENE_BEFORE_BUGS,
        'AC16: the real repo .ccpraxis-local-data/bug-reports is untouched by this file');
}

done_testing();
