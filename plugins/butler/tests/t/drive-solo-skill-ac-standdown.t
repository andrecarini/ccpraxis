#!/usr/bin/env perl
# platform: any
# ORACLE for package 11-ac-loss-clean-suspend-cycle (blueprint tooling-backlog),
# AC-17 of .ccpraxis-local-data/blueprints/tooling-backlog/specs/
# 11-ac-loss-clean-suspend-cycle-spec.md sec 2.10: the drive-solo SKILL.md
# rows documenting the holder's ACLOSS exit, the ac-stand-down action, the
# woken-while-stood-down case, and the monitor-exit/re-arm resume path --
# plus the non-regression requirement that the existing
# <!-- continuity:begin -->...<!-- continuity:end --> block stays
# byte-identical.
#
# None of sec 2.10's new rows exist in SKILL.md yet. Every content
# assertion below is written to fail legibly against today's file (the
# action table has no `ac-stand-down` row, the holder-ACLOSS row, the
# "Woken while stood down" row, or the monitor-exit row at all) rather than
# crash -- this file never requires() or spawns anything.
#
# Written BLIND to any implementation file: derived only from spec sec 2.10
# (the five numbered rows) and the CURRENT on-disk continuity:begin/end
# block, captured here as the immutable non-regression fixture (spec: "Do
# not touch the continuity:begin/end block").
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

my $SKILL = "$Bin/../../skills/drive-solo/SKILL.md"; $SKILL =~ s{\\}{/}g;

sub slurp {
    my ($p) = @_;
    open my $fh, '<:raw', $p or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

ok(-f $SKILL, 'precondition: drive-solo/SKILL.md exists on disk');
my $src = slurp($SKILL);
ok(defined $src, 'precondition: SKILL.md is readable') or BAIL_OUT('cannot read SKILL.md at all');
$src //= '';

# ===========================================================================
# Non-regression fixture: the EXACT continuity:begin/end block as it reads
# on disk at the time this oracle was written (2026-10-03, pre-package-11).
# This byte sequence must still be found, unchanged, after the package adds
# its new action-table rows elsewhere in the file.
#
# Amended 2026-10-22 (bug 20261012-033139-8c07): the stand-down and resume
# commands moved from the action-table rows INTO this block, because
# continuity-prose-budget.t rule O requires every continuity command to live
# inside it (one source for the wording). The two last lines are that move,
# not drift; the rows now point here.
# ===========================================================================
my $CONTINUITY_BLOCK = <<'BLOCK';
<!-- continuity:begin -->
First step, before Preflight: `butler-continuity on --role driver --new-thread <name> --goal '<what this run is for>'`, or `--thread <name>` (same `--goal`) in place of `--new-thread` to resume this run's handed-off thread (`almanac thread list` shows it). Arms the session onto that thread and clears an earlier off; after a new session id, the first director call re-arms it.
Then `almanac thread add-packages <name> <blueprint> [<blueprint> ...]` for each blueprint in scope (for `all`, each blueprint when its first `run-package` arrives); at `done`, archive the thread if it is done (see the `done` row).
Every dispatch prompt carries one line `Ledger: .ccpraxis-local-data/blueprints/<blueprint>/packages/<package>.md` (the `blueprint` and `package` of `run-package`, data-dir-relative).
With more than one package in flight, a dispatch without exactly one such line naming an in-flight package is denied, and the denial lists the valid lines.
Never dispatch with `subagent_type: fork`; launch a fresh subagent with a self-contained prompt instead.
Before a turn ends with background workers or a pause running: `butler-hold <id> [<id> ...]` with `run_in_background: true` only when `butler-continuity status` shows `holder: none`; while one is already running, run `butler-hold <new id>` in the foreground instead, which extends it and returns at once.
When the holder exits, act on its report and hold again for ids still running.
At `done`, at `pause-long`, or when the operator says stop: `butler-continuity off --reason '<what is done>'`.
A denied stop prints commands carrying a stop token; run them as printed.
On `ac-stand-down`, step (c): `butler-continuity off --reason 'AC power lost: stood down until AC returns'`; if it refuses because a thread task is `doing`, set that task `pending` and run it again. Never `butler-hold` the AC monitor: continuity is off.
When the AC monitor exits 0 or 2: `butler-continuity on --thread <your thread> --role driver --goal '<what this run is for>'`, then `next`.
<!-- continuity:end -->
BLOCK
# Normalize line endings before comparing (the fixture above is LF-only).
(my $src_lf = $src) =~ s/\r\n/\n/g;
like($src_lf, qr/\Q$CONTINUITY_BLOCK\E/,
    'AC-17 non-regression: the continuity:begin/end block is byte-identical to before this package');

# ===========================================================================
# AC-17: the new action-table rows (sec 2.10, items 1-4; item 5 -- "Monitor
# exits 3" -- checked separately below).
# ===========================================================================
like($src, qr/ACLOSS/, 'AC-17: SKILL.md mentions the holder-printed ACLOSS line (exit 4 case)');
like($src, qr/\bac-stand-down\b/, 'AC-17: SKILL.md names the ac-stand-down action');
like($src, qr/bp-ac-watch\.pl/, 'AC-17: SKILL.md names the bp-ac-watch.pl script');
like($src, qr/run_in_background/, 'AC-17: SKILL.md says to start the monitor with run_in_background');
like($src, qr/butler-continuity off\s*--reason/, 'AC-17: SKILL.md documents the butler-continuity off --reason step');
like($src, qr/\bTaskStop\b/, 'AC-17: SKILL.md mentions TaskStop in the context of AC stand-down (the "do not" instruction)');
like($src, qr/\bDo not\b.*\bTaskStop\b|TaskStop\b.*\bDo not\b/s,
    'AC-17: SKILL.md instructs NOT to TaskStop workers during stand-down');
like($src, qr/butler-continuity on\s*--thread/, 'AC-17: SKILL.md documents the re-arm (butler-continuity on --thread) step on resume');
like($src, qr/\bnext\b/, 'AC-17: SKILL.md mentions calling next as part of the resume sequence');

# "Woken while stood down" / monitor status check (item 3).
like($src, qr/\bstanding-down\b/, 'AC-17: SKILL.md names the standing-down phase');
like($src, qr/\bmonitoring\b/, 'AC-17: SKILL.md names the monitoring phase');

# "Monitor exits 3" (item 5): another monitor already live.
like($src, qr/exits? 3/, 'AC-17: SKILL.md documents the monitor-exits-3 (another monitor live) case');

done_testing();
