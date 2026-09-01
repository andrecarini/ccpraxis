#!/usr/bin/env perl
# 12-fresh-register-commits.t — a fresh registration's FIRST commit must
# actually store the files, and must not poison the cache if it does not.
#
# Bug report 20260901-025445-d667. Registering the ccpraxis dev clone
# (4405 files), the first commit-and-push returned `committed_and_pushed` while
# rolling back all 4405 push ops. Nothing was committed: the vault held 201 MB
# of unrenamed *.vault-sync.tmp staging, invisible to `git status` because that
# pattern is in the vault's own .gitignore, and `git ls-files` showed only
# metadata.json.
#
# The SECOND sync then staged `delete_local` for every file — 4405 deletions,
# zero pushes — because the cache had recorded the files as synced even though
# the push ops rolled back. local == cache + vault absent reads as "deleted
# upstream". It reported `status: synced` while staging the deletion of every
# bug report, blueprint and correction note in the project.
#
# Two claims, and the second is the one that turns a failed backup into data
# loss:
#   AC1  a fresh registration's first commit actually commits its files
#   AC2  after a sync, the next sync does not want to DELETE anything local
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Encode ();
use JSON::PP;
use StewardTest qw(ok is run_vs temproot make_machine init_remote write_text done_testing diag);

# staged_actions($home, $slug) -> { push => N, pull => N, delete_local => N, ... }
#
# READ THE JOURNAL, NOT `applied`. The response's `applied` field is a COUNT, not
# an op list, so `grep { $_->{action} eq 'delete_local' } @$applied` matches
# nothing whether or not the bug is present — every case below built on it was
# passing vacuously, in the one test whose whole subject is data loss.
#
# The ops log is the same source the rename pass acts on, and reading it here is
# exactly what caught two live projects staging the deletion of files that only
# existed locally (klink's CLAUDE.md among them). Call it AFTER sync-project and
# BEFORE commit-and-push.
sub staged_actions {
    my ($home, $slug) = @_;
    my $path = "$home/.claude/claude-code-vault/projects/$slug/.sync-journal.ops.jsonl";
    my %by;
    if (open my $fh, '<:raw', $path) {
        while (my $line = <$fh>) {
            next unless $line =~ /\n\z/ && $line =~ /\S/;
            my $o = eval { JSON::PP->new->utf8->decode($line) } or next;
            next unless ref $o eq 'HASH' && defined $o->{id};
            $by{ $o->{id} } = { %{ $by{ $o->{id} } || {} }, %$o };   # later line wins
        }
        close $fh;
    }
    my %n;
    $n{ $_->{action} // '?' }++ for values %by;
    return \%n;
}

my $root   = temproot();
my $remote = init_remote($root);
my $home   = make_machine($root, 'home1');
my $proj   = "$root/proj"; mkdir $proj or die;
run_vs($home, 'init', '--url', $remote);

# Content shaped like the real case: a CLAUDE.md plus a data root holding
# several kinds of tracked material.
write_text("$proj/CLAUDE.md", "# proj\n");
write_text("$proj/.ccpraxis-local-data/bug-reports/2026-a.md", "---\nid: a\n---\nbody a\n");
write_text("$proj/.ccpraxis-local-data/bug-reports/2026-b.md", "---\nid: b\n---\nbody b\n");
write_text("$proj/.ccpraxis-local-data/corrections/c1.md", "correction one\n");
write_text("$proj/.ccpraxis-local-data/blueprints/bp1/blueprint.md", "# bp1\n");
write_text("$proj/.ccpraxis-local-data/blueprints/bp1/packages/01-x.md", "# pkg\n");

my $files = join ',', 'CLAUDE.md',
    '.ccpraxis-local-data/bug-reports',
    '.ccpraxis-local-data/corrections',
    '.ccpraxis-local-data/blueprints';

my $reg = run_vs($home, 'register', '--fresh', '--cwd', $proj, '--slug', 'proj', '--files', $files);
is($reg->{json} && $reg->{json}{status}, 'registered_fresh', 'registered fresh') or diag($reg->{out});

# ---------------------------------------------------------------------------
# AC1 — the first commit stores the files.
# ---------------------------------------------------------------------------
my $s1 = run_vs($home, 'sync-project', '--slug', 'proj');
is($s1->{json} && $s1->{json}{status}, 'synced', 'AC1: first sync-project succeeded') or diag($s1->{out});

my $c1 = run_vs($home, 'commit-and-push', '--slug', 'proj', '--session-id', ($s1->{json}{session_id} // ''));
is($c1->{json} && $c1->{json}{status}, 'committed_and_pushed', 'AC1: first commit-and-push succeeded')
    or diag($c1->{out});

# THE ROLLBACK COUNT IS THE ASSERTION. The live failure reported success with
# every op rolled back, so "status was committed_and_pushed" proves nothing on
# its own.
my @rb = @{ ($c1->{json} && $c1->{json}{rolled_back_during_sync}) || [] };
is(scalar @rb, 0, 'AC1: NOTHING was rolled back on a fresh first commit')
    or diag("rolled back: " . join(', ', map { ($_->{path} // '?') . ' (' . ($_->{reason} // '?') . ')' } @rb[0 .. ($#rb > 4 ? 4 : $#rb)]));

# And the content is really in the vault, tracked by git — not sitting as
# unrenamed staging that git ignores.
my $vfiles = run_vs($home, 'vault-files', '--slug', 'proj');
my @paths = map { ref $_ ? ($_->{path} // '') : $_ } @{ ($vfiles->{json} && $vfiles->{json}{files}) || [] };
ok(scalar(@paths) >= 5, 'AC1: the vault reports the tracked files (got ' . scalar(@paths) . ')')
    or diag($vfiles->{out});
ok((grep { m{bug-reports/2026-a\.md} } @paths), 'AC1: a bug report actually reached the vault');

# ---------------------------------------------------------------------------
# AC2 — THE DATA-LOSS CLAIM. A second sync, with nothing changed locally, must
# not want to delete local files.
# ---------------------------------------------------------------------------
my $s2 = run_vs($home, 'sync-project', '--slug', 'proj');
is($s2->{json} && $s2->{json}{status}, 'synced', 'AC2: second sync-project succeeded') or diag($s2->{out});

my $act2 = staged_actions($home, 'proj');
is($act2->{delete_local} // 0, 0, 'AC2: the second sync stages NO delete_local ops')
    or diag("staged: " . join(', ', map { "$_=$act2->{$_}" } sort keys %$act2));

# The local files are still there, whatever the ops said.
run_vs($home, 'commit-and-push', '--slug', 'proj', '--session-id', ($s2->{json}{session_id} // ''));
ok(-f "$proj/.ccpraxis-local-data/bug-reports/2026-a.md", 'AC2: the local bug report survived a second sync');
ok(-f "$proj/.ccpraxis-local-data/corrections/c1.md",     'AC2: the local correction survived');
ok(-f "$proj/.ccpraxis-local-data/blueprints/bp1/blueprint.md", 'AC2: the local blueprint survived');

# ---------------------------------------------------------------------------
# AC3 — A ROLLED-BACK PUSH MUST NOT LEAVE A CACHE ENTRY BEHIND.
#
# This is the mechanism of the data loss, tested directly rather than through
# the (still unidentified) trigger that made 4405 pushes roll back.
#
# A push rolls back when its source changes between staging and rename. So:
# stage a sync, then modify the source before commit-and-push. The push rolls
# back for a legitimate reason — and the question is whether its cache op rolls
# back with it.
#
# If it does not, the cache claims a sync that never reached the vault, and the
# NEXT sync reads local == cache + vault-absent as "deleted upstream" and stages
# delete_local. That is how a failed backup becomes deleted work.
#
# THE FIRST VERSION OF THIS CASE WAS VACUOUS, and the way it failed is worth
# recording. It made the push roll back by MODIFYING the source after staging —
# which also makes cache != local, so the next sync reads "local changed", pushes
# again, and never reaches the delete path. It passed with the fix disabled.
#
# The real incident had cache == local with the vault EMPTY: nothing had changed
# locally, the pushes simply never landed. So the reproduction has to make the
# push fail for a reason UNRELATED to the source content — here by removing the
# staged vault-side tmps, which triggers the tmp-missing rollback while the cache
# ops still carry the current content.
{
    my $victim = "$proj/.ccpraxis-local-data/bug-reports/2026-c.md";
    write_text($victim, "---\nid: c\n---\noriginal\n");

    my $s3 = run_vs($home, 'sync-project', '--slug', 'proj');
    is($s3->{json} && $s3->{json}{status}, 'synced', 'AC3: staged a sync containing the new file') or diag($s3->{out});

    # NON-VACUITY GUARD FOR staged_actions ITSELF. A helper that silently returned
    # an empty hash — wrong path, changed journal filename, a decode that throws —
    # would make every `delete_local == 0` assertion in this file pass forever
    # while reporting nothing. That is precisely the failure mode being replaced,
    # so the reader must be proven to see a staged op it MUST see: a brand-new
    # file was just written, so a push is staged here by construction.
    my $act3 = staged_actions($home, 'proj');
    ok(($act3->{push} // 0) >= 1,
        'AC3: staged_actions actually reads the journal (sees the new file\'s push)')
        or diag("staged: " . join(', ', map { "$_=$act3->{$_}" } sort keys %$act3)
                . " -- if empty, the reader is broken and every delete_local check here is vacuous");

    # Remove the staged vault-side tmps: the pushes now fail for a reason that
    # has nothing to do with the local file, exactly as in the live incident.
    my $vfiles_dir = "$home/.claude/claude-code-vault/projects/proj/files";
    my @tmps;
    if (opendir my $dh, "$vfiles_dir/.ccpraxis-local-data/bug-reports") {
        push @tmps, "$vfiles_dir/.ccpraxis-local-data/bug-reports/$_"
            for grep { /\.vault-sync\.tmp\z/ } readdir $dh;
        closedir $dh;
    }
    ok(scalar(@tmps) > 0, 'AC3: fixture — staged push tmps exist to remove');
    unlink $_ for @tmps;

    my $c3 = run_vs($home, 'commit-and-push', '--slug', 'proj', '--session-id', ($s3->{json}{session_id} // ''));
    my @rb3 = @{ ($c3->{json} && $c3->{json}{rolled_back_during_sync}) || [] };
    ok(scalar(@rb3) > 0, 'AC3: those pushes rolled back') or diag(substr($c3->{out}, 0, 300));

    # THE ASSERTION THAT MATTERS: the next sync must not want to delete it.
    my $s4 = run_vs($home, 'sync-project', '--slug', 'proj');
    my $act4 = staged_actions($home, 'proj');
    is($act4->{delete_local} // 0, 0, 'AC3: the sync after a rolled-back push stages NO delete_local')
        or diag("staged: " . join(', ', map { "$_=$act4->{$_}" } sort keys %$act4));

    run_vs($home, 'commit-and-push', '--slug', 'proj', '--session-id', ($s4->{json}{session_id} // ''));
    ok(-f $victim, 'AC3: the file whose push rolled back still exists locally');
}

# ---------------------------------------------------------------------------
# AC4 — THE SYNC'S OWN STAGING FILES ARE NOT CONTENT.
#
# Root cause of 20260901-025445-d667. The inventory walk enumerated
# `*.vault-sync.tmp` as ordinary tracked files. An interrupted sync leaves those
# behind, so the next sync staged them AGAIN as
# `x.vault-sync.tmp.vault-sync.tmp`, adding 15 characters every run.
#
# Measured on the real clone: 4403 stray tmps locally and a staged vault path of
# 259 characters, one below Windows' 260-char MAX_PATH. Past it the tmp cannot
# be created, `-f $op->{tmp_path}` is false, and every push rolls back with
# tmp_missing -- 8822 of 8822. That is what made a backup report success while
# storing nothing.
#
# The compounding is what makes it dangerous: each failed sync makes the next
# one worse.
# ---------------------------------------------------------------------------
{
    my $stray = "$proj/.ccpraxis-local-data/bug-reports/leftover.md.vault-sync.tmp";
    write_text($stray, "debris from an interrupted sync\n");

    my $s5 = run_vs($home, 'sync-project', '--slug', 'proj');
    is($s5->{json} && $s5->{json}{status}, 'synced', 'AC4: sync runs with stray staging files present')
        or diag(substr($s5->{out}, 0, 300));

    run_vs($home, 'commit-and-push', '--slug', 'proj', '--session-id', ($s5->{json}{session_id} // ''));

    # ASSERT ON THE VAULT, NOT ON `applied`. The first version of this case
    # grepped $s5->{json}{applied} for a tmp path -- but `applied` is a COUNT,
    # not an op list, so the grep matched nothing whether or not the bug was
    # present, and the case passed with the fix disabled. (The same mistake made
    # AC2's delete_local check pass while a file was being deleted.) What the
    # bug actually produces is observable on disk: the sync's own staging file
    # committed into the vault as though it were content.
    my $vf = run_vs($home, 'vault-files', '--slug', 'proj');
    my @vpaths = map { ref $_ ? ($_->{path} // '') : $_ }
                 @{ ($vf->{json} && $vf->{json}{files}) || [] };
    my @tmp_in_vault = grep { /\Qvault-sync.tmp\E/ } @vpaths;
    is(scalar @tmp_in_vault, 0,
        'AC4: no staging file is stored in the vault as content')
        or diag("in vault: " . join(', ', @tmp_in_vault[0 .. ($#tmp_in_vault > 4 ? 4 : $#tmp_in_vault)]));

    # The real file beside it still synced, so AC4 is not passing by the sync
    # having simply done nothing.
    ok((grep { m{bug-reports/2026-a\.md} } @vpaths),
        'AC4 non-vacuity: ordinary content in the same directory still reached the vault');
}

# ---------------------------------------------------------------------------
# AC5 — A NON-ASCII PATH MUST SURVIVE THE JOURNAL ROUND-TRIP.
#
# The ACTUAL root cause of 20260901-025445-d667, found only after the tmp-filter
# fix above failed to change the outcome. AC4 was a real bug and made every run
# worse, but it was not what broke the backup.
#
# sync-project and commit-and-push are SEPARATE PROCESSES that hand each other
# file paths through the ops journal. The journal's log half was read with a bare
# `JSON::PP->new->decode`, which returns utf8-FLAGGED strings. A path through
# `André` came back as the characters `Ã©`, perl re-encoded that on the way to
# Windows, and the resulting path did not exist -- so `-f $op->{tmp_path}` was
# false for EVERY push, all 4414 rolled back with tmp_missing, and the backup
# reported success having stored nothing. The files were on disk the entire
# time; `ls` found them and `-f` did not.
#
# read_json() had re-encoded to bytes since it was written. The append-only log
# was added later and skipped that step, so the two halves of one journal
# disagreed about what a filename was.
#
# WHY THE SUITE STAYED GREEN THROUGH ALL OF IT: temproot() resolves to
# /c/Users/Public — pure ASCII. Every path this suite has ever tested round-trips
# byte-identically whether or not the flag is set. The real vault lives under
# `André`. So the bug was unreachable from the tests by construction, and no
# amount of running them harder would have found it.
#
# Hence a non-ASCII FILENAME rather than a non-ASCII root: it reproduces the
# fault wherever the test root happens to live.
#
# The first attempt at this fix used `->decode` + re-encode, which DOUBLE-encoded
# (bytes read as Latin-1, then encoded again) and left the failure identical.
# `->utf8->decode` is what makes the pair symmetric with the writer.
# ---------------------------------------------------------------------------
{
    # Raw UTF-8 bytes, deliberately not `use utf8` — this is how a filename
    # actually reaches the sync.
    my $accented = "caf\x{c3}\x{a9}-r\x{c3}\x{a9}sum\x{c3}\x{a9}.md";
    my $rel = ".ccpraxis-local-data/bug-reports/$accented";
    write_text("$proj/$rel", "---\nid: accented\n---\nnon-ascii filename\n");

    my $s6 = run_vs($home, 'sync-project', '--slug', 'proj');
    is($s6->{json} && $s6->{json}{status}, 'synced', 'AC5: sync staged the non-ASCII path')
        or diag(substr($s6->{out}, 0, 300));

    my $c6 = run_vs($home, 'commit-and-push', '--slug', 'proj',
                    '--session-id', ($s6->{json}{session_id} // ''));

    # THE ASSERTION. With the flag bug present this is 2 (push + cache) and the
    # status is rolled_back_nothing_stored.
    my @rb6 = @{ ($c6->{json} && $c6->{json}{rolled_back_during_sync}) || [] };
    is(scalar @rb6, 0, 'AC5: the non-ASCII push did NOT roll back')
        or diag("status=" . (($c6->{json} && $c6->{json}{status}) // '?') . "; rolled back: "
                . join(', ', map { ($_->{path} // '?') . ' (' . ($_->{reason} // '?') . ')' } @rb6));

    # And it is really in the vault, byte-identically — a path that round-tripped
    # through the wrong encoding would either be absent or present under a
    # mangled name, and both fail this.
    my $vf6 = run_vs($home, 'vault-files', '--slug', 'proj');
    # StewardTest::run_vs parses with decode_json, so reported paths come back as
    # utf8-FLAGGED characters while $rel is raw bytes. Compare in one encoding or
    # the case fails on the harness rather than on the product. (That the parse
    # succeeded at all is itself evidence the product emitted valid UTF-8.)
    my @vp6 = map { my $p = ref $_ ? ($_->{path} // '') : $_;
                    utf8::is_utf8($p) ? Encode::encode('UTF-8', $p) : $p }
              @{ ($vf6->{json} && $vf6->{json}{files}) || [] };
    # scalar(), NOT a bare grep. `ok((grep {...}), 'name')` passes the MATCHES as
    # a list, so on zero matches the name string slides into the truth slot and
    # the case passes vacuously with an empty name — which is exactly what it did
    # on first run here, hiding a real mismatch.
    ok(scalar(grep { $_ eq $rel } @vp6),
        'AC5: the non-ASCII filename reached the vault with its bytes intact')
        or diag("vault has: " . join(', ', grep { /bug-reports/ } @vp6));

    ok(-f "$proj/$rel", 'AC5: and the local file still exists');
}

# ---------------------------------------------------------------------------
# AC6 — A POISONED CACHE MUST NOT BECOME A DELETION.
#
# Bug report 20260901-050537-63e0. d667's fix stops NEW poisoning; it does
# nothing about a cache already poisoned by a sync that ran before it. Two
# registered projects on this machine were in exactly that state, between them
# staging the deletion of 7 files that existed ONLY locally — klink's own
# CLAUDE.md among them. A routine backup would have deleted all seven.
#
# The condition, reproduced directly: cache says synced, the vault has no copy,
# the local file is present and unchanged. classify() sees cache == local with
# the vault absent and reads it as "deleted upstream".
#
# It is not. A path the vault has NEVER held cannot have been deleted from it,
# and git history is what distinguishes the two cases — `git ls-files` cannot,
# because a genuinely-deleted file is absent from the current tree too.
# ---------------------------------------------------------------------------
{
    my $orphan = "$proj/.ccpraxis-local-data/bug-reports/never-pushed.md";
    write_text($orphan, "---\nid: orphan\n---\nonly ever existed locally\n");

    # Sync it so a CACHE entry is written, then remove it from the vault side
    # WITHOUT going through git — the state a rolled-back push leaves behind:
    # the cache believes it landed, the vault never received it.
    my $s7 = run_vs($home, 'sync-project', '--slug', 'proj');
    run_vs($home, 'commit-and-push', '--slug', 'proj', '--session-id', ($s7->{json}{session_id} // ''));

    my $vault_copy = "$home/.claude/claude-code-vault/projects/proj/files/"
                   . ".ccpraxis-local-data/bug-reports/never-pushed.md";
    ok(-f $vault_copy, 'AC6: fixture — the file reached the vault before we strand the cache');

    # Removing a COMMITTED vault file out of band is not the poisoned state — it
    # is vault drift, and the tool refuses rather than guessing. Asserted here
    # because it is the defence that stands between a corrupted vault tree and a
    # sync that acts on it; discovered by writing this case expecting `synced`.
    unlink $vault_copy;
    my $s8 = run_vs($home, 'sync-project', '--slug', 'proj');
    is($s8->{json} && $s8->{json}{status}, 'drift',
       'AC6: an out-of-band vault deletion is caught as drift, not acted on')
        or diag(substr($s8->{out}, 0, 300));

    # Put it back so the run can continue past the drift guard.
    write_text($vault_copy, "---\nid: orphan\n---\nonly ever existed locally\n");

    # And the path-never-in-the-vault case: a brand-new local file with a cache
    # entry forged for it. This is the poisoned state proper.
    my $forged = ".ccpraxis-local-data/bug-reports/forged-cache.md";
    write_text("$proj/$forged", "---\nid: forged\n---\nnever pushed anywhere\n");
    my $cache_file = "$proj/.ccpraxis-local-data/backup-cache/$forged";
    write_text($cache_file, "---\nid: forged\n---\nnever pushed anywhere\n");

    my $s9 = run_vs($home, 'sync-project', '--slug', 'proj');
    is($s9->{json} && $s9->{json}{status}, 'synced', 'AC6: sync ran with the forged cache entry')
        or diag(substr($s9->{out}, 0, 300));

    my $dels9 = ($s9->{json} && $s9->{json}{deletes_local}) || [];
    ok(!(grep { $_ eq $forged } @$dels9),
        'AC6: a path the vault NEVER held is not staged for local deletion')
        or diag("staged for deletion: " . join(', ', @$dels9));

    # The destructive ops must be visible by name, not merely absent. `applied`
    # is a count and `auto_applied` is every op flattened together, so the one
    # thing that destroys user data was reachable only by filtering a list that
    # nobody filtered — two tests and one live backup flow all walked past it.
    my $acts9 = ($s9->{json} && $s9->{json}{action_counts}) || {};
    is(scalar(@$dels9), ($acts9->{delete_local} // 0),
        'AC6: deletes_local and action_counts agree — a deletion cannot be staged invisibly');

    # Non-vacuity: the sync did real work, so "no deletions" is not "no ops".
    ok(scalar(keys %$acts9) > 0, 'AC6 non-vacuity: the sync staged something to report')
        or diag('action_counts was empty');

    run_vs($home, 'commit-and-push', '--slug', 'proj', '--session-id', ($s9->{json}{session_id} // ''));
    ok(-f "$proj/$forged", 'AC6: and the local file survived the sync');
}

done_testing();
