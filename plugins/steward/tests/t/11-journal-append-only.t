#!/usr/bin/env perl
# 11-journal-append-only.t — the sync journal is append-only, and every way that
# could go wrong is pinned here.
#
# WHY THIS EXISTS. journal_record_op used to read the whole journal, push one
# entry, and write the whole thing back — once per staged file. That is O(n^2).
# Measured on a live run (bug report 20260829-222333-2b23), syncing a project
# with 1495 tracked files:
#
#     .sync-journal.json   1,533,881 bytes   1507 ops
#     20 seconds later     1,539,794 bytes   1513 ops     <- SIX files in 20s
#
# ~3.3 seconds per file and rising, because the per-file cost IS the journal's
# current size. The run passed 90 minutes with ~80 more projected, to move
# 107 MB. Small projects hid it completely.
#
# THE SPLIT INTRODUCED A SECOND FILE INSIDE projects/<slug>/, AND THAT ALMOST
# BRICKED SYNC. vault_dirty_files treats any uncommitted file there as DRIFT, and
# the vault's .gitignore — written once by cmd_init — listed only the header. On
# every existing vault the ops log would have read as uncommitted project content
# and sync-project would have REFUSED TO RUN. The steward suite caught it
# immediately; AC5 below is that regression, pinned.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use StewardTest qw(ok is like run_vs temproot make_machine init_remote write_text read_text path_exists done_testing diag);

my $root   = temproot();
my $remote = init_remote($root);
my $home   = make_machine($root, 'home1');
my $proj   = "$root/proj"; mkdir $proj or die;
run_vs($home, 'init', '--url', $remote);

write_text("$proj/CLAUDE.md", "# proj\n");
run_vs($home, 'register', '--fresh', '--cwd', $proj, '--slug', 'proj', '--files', 'CLAUDE.md');

# A few dozen files, so "one op per file" is visible and the header's constancy
# is a real claim rather than an artefact of a single-file project.
my $N = 40;
write_text("$proj/.ccpraxis-local-data/blueprints/bp$_/blueprint.md", "# blueprint $_\n" . ('x' x 200) . "\n")
    for 1 .. $N;
run_vs($home, 'refresh-default-tracked', '--slug', 'proj');

my $vproj    = "$home/.claude/claude-code-vault/projects/proj";
my $header   = "$vproj/.sync-journal.json";
my $ops_log  = "$vproj/.sync-journal.ops.jsonl";

# ---------------------------------------------------------------------------
# AC1 — ops go to the log, and the header does NOT carry them.
# ---------------------------------------------------------------------------
my $sync = run_vs($home, 'sync-project', '--slug', 'proj');
is($sync->{json} && $sync->{json}{status}, 'synced', 'AC1: sync-project succeeded') or diag($sync->{out});

ok(path_exists($ops_log), 'AC1: an append-only ops log was written');
ok(path_exists($header),  'AC1: the header still exists');

my $ops_text = read_text($ops_log) // '';
my @lines = grep { /\S/ } split /\n/, $ops_text;
ok(scalar(@lines) >= $N, "AC1: the log has at least one line per file (got " . scalar(@lines) . " for $N files)");

my $hdr_text = read_text($header) // '';
unlike_ops($hdr_text);
sub unlike_ops {
    my ($t) = @_;
    # The header must not carry an ops ARRAY. Matching on the key alone would be
    # satisfied by the word appearing anywhere, so this looks for the array.
    ok($t !~ /"ops"\s*:\s*\[\s*\{/, 'AC1: the header carries no ops array (they live in the log)');
}

# ---------------------------------------------------------------------------
# AC2 — THE HEADER IS SMALL AND DOES NOT GROW WITH THE FILE COUNT.
#
# This is the structural form of "the sync is linear". The old code's whole cost
# was that this file grew to megabytes and was rewritten per op; if it is still
# small after 40 files, it is not being rewritten with them.
# ---------------------------------------------------------------------------
{
    my $hdr_bytes = length($hdr_text);
    my $log_bytes = length($ops_text);
    ok($hdr_bytes < 2000,
        "AC2: the header stays small regardless of file count ($hdr_bytes bytes)");
    ok($log_bytes > $hdr_bytes,
        "AC2: the ops log is where the volume went ($log_bytes bytes vs $hdr_bytes)");
}

# ---------------------------------------------------------------------------
# AC3 — commit-and-push works off the split journal, and clears BOTH halves.
# A leftover log would be replayed by the next sync as though it were an
# interrupted run.
# ---------------------------------------------------------------------------
{
    my $cp = run_vs($home, 'commit-and-push', '--slug', 'proj');
    is($cp->{json} && $cp->{json}{status}, 'committed_and_pushed',
        'AC3: commit-and-push succeeded against a split journal') or diag($cp->{out});
    ok(!path_exists($header),  'AC3: the header is cleared');
    ok(!path_exists($ops_log), 'AC3: the ops log is cleared too');
}

# ---------------------------------------------------------------------------
# AC4 — A LEGACY WHOLE-FILE JOURNAL IS STILL READABLE.
#
# A journal written by the old code may be sitting on disk from an interrupted
# sync — there is one on this machine right now. journal_reconcile has to replay
# it, so the reader must honour ops inside the header.
# ---------------------------------------------------------------------------
{
    write_text("$proj/CLAUDE.md", "# proj changed\n");
    my $s2 = run_vs($home, 'sync-project', '--slug', 'proj');
    is($s2->{json} && $s2->{json}{status}, 'synced', 'AC4: a second sync staged changes') or diag($s2->{out});

    # Fold the log back into the header, old-format style, and delete the log.
    # Built with the JSON encoder rather than string surgery: the first attempt
    # spliced the array in by hand and the closing brace inside qq{} terminated
    # the delimiter early, which is a fixture bug that would have read as a
    # failure of the code under test.
    my $hdr = JSON::PP->new->decode(read_text($header));
    my @recs = map  { JSON::PP->new->decode($_) }
               grep { /\S/ } split /\n/, (read_text($ops_log) // '');
    $hdr->{ops} = \@recs;
    write_text($header, JSON::PP->new->canonical->pretty->encode($hdr));
    unlink $ops_log;
    ok(!path_exists($ops_log), 'AC4: fixture — the journal is now old-format (ops inside the header)');

    my $cp2 = run_vs($home, 'commit-and-push', '--slug', 'proj');
    is($cp2->{json} && $cp2->{json}{status}, 'committed_and_pushed',
        'AC4: a legacy whole-file journal still commits') or diag($cp2->{out});
}

# ---------------------------------------------------------------------------
# AC5 — THE REGRESSION THAT ALMOST SHIPPED.
#
# Strip the ops-log rule from the vault's .gitignore, exactly as every vault
# created before the split has it, and confirm sync-project does NOT report
# drift — i.e. the migration puts the rule back before anything judges
# cleanliness.
# ---------------------------------------------------------------------------
{
    my $gi_path = "$home/.claude/claude-code-vault/.gitignore";
    my $gi = read_text($gi_path) // '';
    ok(index($gi, '.sync-journal.ops.jsonl') >= 0, 'AC5: precondition — the rule is present');

    my $stripped = join "\n", grep { !/\.sync-journal\.ops\.jsonl/ } split /\n/, $gi;
    write_text($gi_path, "$stripped\n");
    ok(index(read_text($gi_path) // '', '.sync-journal.ops.jsonl') < 0,
        'AC5: fixture — the rule is gone, as on a pre-split vault');

    write_text("$proj/CLAUDE.md", "# proj changed again\n");
    my $s3 = run_vs($home, 'sync-project', '--slug', 'proj');
    is($s3->{json} && $s3->{json}{status}, 'synced',
        'AC5: sync-project still runs on a vault whose .gitignore predates the split')
        or diag($s3->{out});
    ok(index(read_text($gi_path) // '', '.sync-journal.ops.jsonl') >= 0,
        'AC5: ...and the rule was migrated back in');

    run_vs($home, 'commit-and-push', '--slug', 'proj');
}

# ---------------------------------------------------------------------------
# AC6 — A TRUNCATED TRAILING LINE IS SURVIVABLE.
#
# The one failure an append-only log has that a whole-file rewrite does not: a
# crash mid-append leaves a partial line. Every complete line before it must
# still count; refusing to parse would throw away the whole recovery record.
# ---------------------------------------------------------------------------
{
    write_text("$proj/CLAUDE.md", "# truncation probe\n");
    my $s4 = run_vs($home, 'sync-project', '--slug', 'proj');
    is($s4->{json} && $s4->{json}{status}, 'synced', 'AC6: staged a sync to truncate') or diag($s4->{out});

    my $l = read_text($ops_log) // '';
    ok(length($l) > 0, 'AC6: precondition — the log has content');
    # Append a deliberately partial record: no newline, cut mid-object.
    write_text($ops_log, $l . '{"id":"op-999","status":"stag');

    my $cp = run_vs($home, 'commit-and-push', '--slug', 'proj');
    is($cp->{json} && $cp->{json}{status}, 'committed_and_pushed',
        'AC6: a truncated trailing line does not break the journal') or diag($cp->{out});
}

done_testing();
