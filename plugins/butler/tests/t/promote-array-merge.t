#!/usr/bin/env perl
# platform: host
# Oracle for blueprint tooling-fixes, package 09 (scripts/promote.pl).
# Derived from .ccpraxis-local-data/blueprints/tooling-fixes/specs/
# 09-promote-array-merge-spec.md (AC-1..AC-18), Decision 26, AND Decision 27
# (blueprint.md) which OVERRIDES the spec's 2.3/2.4 wherever they conflict:
# promotion never widens the operator's permissions beyond what THIS
# promotion itself ships. A change that NARROWS (removing an allow entry,
# adding a deny/ask entry) is judged against the payload's whole history, as
# the spec says. A change that WIDENS (adding an allow entry, removing a
# deny/ask entry) happens only for an entry this promotion itself changed:
# a three-way merge against the payload at the live install's pre-merge HEAD
# (the "baseline"). No baseline payload -> allow additions treat baseline as
# empty (everything current is "new"); deny/ask removals remove nothing. Any
# preference recorded for an array unit (skip-always, left-only, right-only)
# leaves the unit untouched WHATEVER its current relation, printing its own
# kept-pref line (red-team M1, M2).
#
# scripts/promote.pl is consulted only to confirm it exists for the AC-18
# compile check; its merge logic is never read while writing this file.
#
# Fixture shape and helpers are copied from the sibling oracle
# promote-syncs-global-config.t (same blueprint family), including its
# clone_extra_commit()/live_extra_commit() pattern for committing to the
# clone AFTER live has already been cloned from it -- exactly what's needed
# to give live a pre-merge HEAD (the baseline) that differs from the payload
# currently being promoted. Every promote.pl call passes
# --clone/--live/--home explicitly; nothing here ever touches the real
# ~/.claude, the live install, or spawns another .t file, the launcher,
# podman or claude.
#
# AC / red-team / review -> block mapping (grep the tag for every assertion):
#   AC-1  retired entry removed + new entry added (narrowing removal, widening
#         addition against the pre-merge-HEAD baseline)
#   AC-2  exact report lines + summary + exit 0
#   AC-3  order preserved (kept order; additions appended in payload order)
#   AC-4  stale-but-clean live array goes through the same merge
#   AC-5  deny and ask behave like allow/each other, each with their own lines
#         (deny addition = narrowing; ask removal = widening against baseline)
#   AC-6  idempotence: second apply is unchanged, no new backup, kept-local
#   AC-7  dry-run: same lines, would-update, no write, no backup dir
#   AC-8  backup: exactly one, byte-equal to pre-run file
#   AC-9  hand re-added retired entry removed (narrowing); skip-always pref
#         keeps it
#   AC-10 duplicates handled per the stated algorithm
#   AC-11 non-string element / non-array live value -> whole-value path
#         (incl. the missing kept-local assertion, review NIT N1)
#   AC-12 only_left (ask): partial removal, key deleted, untouched-no-line
#         (removal is widening, gated on the baseline)
#   AC-13 only_right (deny): added whole, one line per entry (narrowing,
#         plus the missing no-whole-unit-line assertion, review NIT N2)
#   AC-14 other string arrays (additionalDirectories) untouched
#   AC-15 / NB-1: no baseline payload (fresh install) -> allow additions
#         treat baseline as empty, everything current is "new"
#   AC-16 covered inline: every scenario above asserts exit 0
#   AC-17 sibling oracles pass unmodified -- NOT run from here (house rule:
#         never spawn another .t file); run separately by the harness
#   AC-18 perl -c scripts/promote.pl exits 0
#   NB-2  no baseline payload -> deny/ask widening removal removes nothing
#   M1    red-team MUST: skip-always pref pins an only_left unit (deny), not
#         just diverged
#   M2    red-team MUST: right-only pref pins a diverged unit (allow), not
#         just only_right
#   PREF  the full pref x relation matrix: every pref kind pins every
#         relation (review S3 + red-team M1/M2 combined)
#   S1    red-team SHOULD: an allow entry the operator deleted stays deleted
#         across two promotions; an entry new in THIS promotion is added
#   S2    red-team SHOULD: a deny entry equal to one dropped in an EARLIER
#         promotion is kept; one dropped by THIS promotion is removed
#   NUM   review S1 / red-team S3: JSON numbers are not strings -> whole-value
#         path, no entry lines (live side and payload side)
#   N1    red-team NIT: live/payload settings.json is a JSON non-object
#         (null/[]/"x") -> settings: error, exit 2, nothing written
#   N2    red-team NIT: a symlinked settings.json is preserved (as the
#         CLAUDE.md branch already is, per the sibling oracle's own working
#         fixture on this host), guarded by a symlink-capability probe
#   NONASCII / REORDER: review NIT N3 -- a non-ASCII entry round-trips with
#         no double encoding; a pure reorder is `changes == 0`, no report
#         line, nothing written
#   review S2: every guarded content assertion is preceded by an explicit
#         shape ok() and is itself unconditional (no more silent
#         `if ref(...)` skips that could pass vacuously)
#   S4 (red-team, write_bytes_atomic print/close failure): NOT covered here.
#         See the note at the end of this file for why.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use HostCaps ();
use Test::More;
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Temp qw(tempdir tempfile);
use JSON::PP;
use Data::Dumper;

my $ROOT    = "$Bin/../../../..";
my $PROMOTE = "$ROOT/scripts/promote.pl";

# ---------------------------------------------------------------------------
# byte-level file helpers -- no decode/re-encode anywhere in this file.
# ---------------------------------------------------------------------------
sub write_bytes {
    my ($path, $content) = @_;
    make_path(dirname($path));
    open my $fh, '>:raw', $path or die "write $path: $!";
    print {$fh} $content;
    close $fh;
}
sub read_bytes {
    my ($path) = @_;
    return undef unless -f $path;
    open my $fh, '<:raw', $path or die "read $path: $!";
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

# ---------------------------------------------------------------------------
# path + git helpers. Forward-slash Windows form only (C:/...), hand
# translated -- never relying on ambient MSYS2 argv conversion. Every git
# call is list-form, hermetic (own GIT_CONFIG_GLOBAL, GIT_CONFIG_NOSYSTEM=1,
# explicit author/committer, -c core.autocrlf=false).
# ---------------------------------------------------------------------------
sub to_gp {
    my ($p) = @_;
    return $p unless defined $p;
    (my $q = $p) =~ s{\\}{/}g;
    return $q;
}

sub env_git {
    my ($f) = @_;
    return (
        GIT_CONFIG_GLOBAL   => $f->{gitconfig},
        GIT_CONFIG_NOSYSTEM => '1',
        GIT_TERMINAL_PROMPT => '0',
        GIT_AUTHOR_NAME     => 'Promote Test',
        GIT_AUTHOR_EMAIL    => 'promote-test@example.invalid',
        GIT_COMMITTER_NAME  => 'Promote Test',
        GIT_COMMITTER_EMAIL => 'promote-test@example.invalid',
    );
}

sub git_run {
    my ($f, $dir, @args) = @_;
    my %e = env_git($f);
    local @ENV{ keys %e } = values %e;
    my $rc = system('git', '-c', 'core.autocrlf=false', '-C', to_gp($dir), @args);
    return $rc == -1 ? -1 : ($rc >> 8);
}

sub git_clone {
    my ($f, $src, $dest) = @_;
    my %e = env_git($f);
    local @ENV{ keys %e } = values %e;
    my $rc = system('git', '-c', 'core.autocrlf=false', 'clone', '-q', '--no-hardlinks', to_gp($src), to_gp($dest));
    return $rc == 0;
}

# ---------------------------------------------------------------------------
# fixture builder -- same shape as promote-syncs-global-config.t's
# new_fixture(). Scratch lives OUTSIDE this repo, under HostCaps' scratch
# root. clone_commits are committed to the clone BEFORE it is cloned into
# live, so they (and only they) become live's pre-merge HEAD -- i.e. the
# "baseline" payload for Decision 27's widening three-way merge.
# clone_extra_commit() (below, same name/shape as the sibling oracle) commits
# to the clone AFTER that point, so the clone runs ahead of live: exactly
# what a real "there's a new payload to promote" run looks like, and the
# only way to make the baseline differ from the current payload.
# ---------------------------------------------------------------------------
sub new_fixture {
    my (%opts) = @_;
    my $root = tempdir(HostCaps::tempdir_args(), CLEANUP => 1);
    my $f = { root => $root, gitconfig => "$root/empty.gitconfig" };
    write_bytes($f->{gitconfig}, '');

    my $clone = "$root/clone-repo";
    make_path($clone);
    git_run($f, $clone, 'init', '-q');
    git_run($f, $clone, 'symbolic-ref', 'HEAD', 'refs/heads/main');
    $f->{clone} = $clone;

    my @commits = @{ $opts{clone_commits} // [ [ { 'README.md' => "# clone fixture\n" }, 'seed' ] ] };
    for my $c (@commits) {
        my ($files, $msg) = @$c;
        for my $rel (sort keys %$files) { write_bytes("$clone/$rel", $files->{$rel}); }
        git_run($f, $clone, 'add', '-A');
        git_run($f, $clone, 'commit', '-q', '-m', $msg);
    }

    my $home = "$root/home";
    make_path("$home/.claude");
    $f->{home} = $home;

    my $live = "$home/.claude/ccpraxis";
    git_clone($f, $clone, $live) or die "git clone into live fixture failed";
    $f->{live} = $live;

    return $f;
}

sub clone_extra_commit {
    my ($f, $files, $msg) = @_;
    for my $rel (sort keys %$files) { write_bytes("$f->{clone}/$rel", $files->{$rel}); }
    git_run($f, $f->{clone}, 'add', '-A');
    git_run($f, $f->{clone}, 'commit', '-q', '-m', $msg);
}

# ---------------------------------------------------------------------------
# promote.pl spawner. stderr captured through a real File::Temp file, never
# an in-memory scalar reopen (Git-for-Windows "Bad file descriptor" trap).
# ---------------------------------------------------------------------------
sub _spawn {
    my ($f, @args) = @_;
    my %e = env_git($f);
    local @ENV{ keys %e } = values %e;

    my ($efh, $ename) = tempfile(UNLINK => 1);
    close $efh;
    open(my $saved_err, '>&', \*STDERR) or die "cannot dup STDERR: $!";
    open(STDERR, '>', $ename) or die "cannot redirect STDERR to $ename: $!";

    my $out  = '';
    my $exit = -1;
    my $pid  = open(my $fh, '-|', $^X, $PROMOTE, @args);
    if ($pid) {
        local $/;
        $out = <$fh>;
        $out = '' unless defined $out;
        close $fh;
        $exit = $? >> 8;
    }

    open(STDERR, '>&', $saved_err) or warn "cannot restore STDERR: $!";
    close $saved_err;
    my $err = read_bytes($ename);
    $err = '' unless defined $err;
    unlink $ename;

    return { out => $out, err => $err, exit => $exit };
}

sub run_promote {
    my ($f, @extra) = @_;
    return _spawn($f, '--clone', $f->{clone}, '--live', $f->{live}, '--home', $f->{home}, @extra);
}

sub canon_json {
    my ($data) = @_;
    return JSON::PP->new->canonical->utf8->encode($data);
}

sub decode_bytes_json {
    my ($bytes) = @_;
    return undef unless defined $bytes;
    my $d = eval { decode_json($bytes) };
    return $d;
}

# review S2: an explicit shape assertion BEFORE any guarded content
# assertion, so a regression that breaks the shape fails loudly here instead
# of silently skipping the assertion that was supposed to pin the AC.
sub assert_shape {
    my ($result, $label) = @_;
    my $shape_ok = ref($result) eq 'HASH' && ref($result->{permissions}) eq 'HASH';
    ok($shape_ok, "$label: settings.json parses with a permissions object")
        or diag(defined $result ? Dumper($result) : 'result is undef');
    return $shape_ok;
}

# Exact report line for one array-unit entry, per spec S2.6: two spaces,
# removed|added, space, unit name, " entry ", the JSON-string encoding of
# the entry (allow_nonref, "/" not escaped).
sub entry_line {
    my ($verb, $unit, $entry) = @_;
    my $enc = JSON::PP->new->utf8->allow_nonref->encode($entry);
    return "  $verb $unit entry $enc";
}
sub entry_line_re {
    my ($verb, $unit, $entry) = @_;
    my $line = entry_line($verb, $unit, $entry);
    return qr/^\Q$line\E$/m;
}

# realistic entries reused across scenarios, incl. one with spaces, "*",
# "(", "=" per AC-2's instruction.
my $R  = 'Bash(BP_VALIDATE_LEDGER=* perl scripts/run-tests.pl *)'; # retired
my $N  = 'Bash(rm -rf *)';                                          # new
my $A  = 'Bash(git status)';
my $B  = 'Bash(npm test)';
my $X  = 'Bash(operator-own-command)';

# ===========================================================================
# AC-1 / AC-2 / AC-8: Behavior 1. Baseline (pre-merge HEAD) v1 allow
# [A,B,R]; current payload v2 allow [A,B,N]; live allow [X,R,A,B] -> live
# allow becomes [X,A,B,N]. R's removal is narrowing (judged against the
# whole payload history, unaffected by Decision 27); N's addition is
# widening (gated on the baseline, which is v1 here and lacks N).
# ===========================================================================
{
    my $payload_v1 = { permissions => { allow => [ $A, $B, $R ] } };
    my $payload_v2 = { permissions => { allow => [ $A, $B, $N ] } };
    my $live_settings = { permissions => { allow => [ $X, $R, $A, $B ] } };

    my $f = new_fixture(clone_commits => [
        [ { 'global-config/settings.json' => canon_json($payload_v1) }, 'settings v1 (baseline)' ],
    ]);
    clone_extra_commit($f, { 'global-config/settings.json' => canon_json($payload_v2) }, 'settings v2 (current)');
    write_bytes("$f->{home}/.claude/settings.json", canon_json($live_settings));
    my $pre_bytes = read_bytes("$f->{home}/.claude/settings.json");

    my $r = run_promote($f);
    is($r->{exit}, 0, 'AC-1/AC-16: exit 0 on the retired-entry scenario') or diag($r->{out} . $r->{err});

    my $bytes = read_bytes("$f->{home}/.claude/settings.json");
    my $result = decode_bytes_json($bytes);
    assert_shape($result, 'AC-1');
    is_deeply($result->{permissions}{allow}, [ $X, $A, $B, $N ], 'AC-1: live permissions.allow becomes [X,A,B,N]; R is absent');

    my $removed_line = entry_line('removed', 'permissions.allow', $R);
    my $added_line   = entry_line('added',   'permissions.allow', $N);
    like($r->{out}, qr/^\Q$removed_line\E$/m, 'AC-2: exact removed-entry report line') or diag($r->{out});
    like($r->{out}, qr/^\Q$added_line\E$/m,   'AC-2: exact added-entry report line') or diag($r->{out});
    ok(index($r->{out}, $removed_line) < index($r->{out}, $added_line), 'AC-2: removed line precedes added line');
    like($r->{out}, qr/^settings: updated \(2 changes\)/m, 'AC-2: summary says settings: updated (2 changes)')
        or diag($r->{out});

    my @ts_dirs = glob("$f->{home}/.claude/.promotion-backups/*");
    is(scalar(@ts_dirs), 1, 'AC-8: exactly one backup timestamp directory') or diag(join(',', @ts_dirs));
    my $backup_bytes = @ts_dirs ? read_bytes("$ts_dirs[0]/settings.json") : undef;
    ok(defined $backup_bytes && $backup_bytes eq $pre_bytes, 'AC-8: backed-up settings.json is byte-equal to the pre-run file');

    # ---------------------------------------------------------------------
    # AC-6: idempotence. Running promote again reports unchanged, writes
    # nothing new, creates no additional backup dir, and prints kept-local
    # permissions.allow (X is never in the payload history). The second
    # run's own pre-merge HEAD is now v2 (== the current payload, since run
    # 1 already pulled it), so its baseline == its payload: no more entries
    # can look "new".
    # ---------------------------------------------------------------------
    my $post_run1_bytes = read_bytes("$f->{home}/.claude/settings.json");
    my $r2 = run_promote($f);
    is($r2->{exit}, 0, 'AC-6: exit 0 on the second (idempotent) run') or diag($r2->{out} . $r2->{err});
    like($r2->{out}, qr/^settings: unchanged/m, 'AC-6: second run reports settings: unchanged') or diag($r2->{out});
    like($r2->{out}, qr/^  kept-local permissions\.allow$/m, 'AC-6: second run prints kept-local permissions.allow')
        or diag($r2->{out});
    unlike($r2->{out}, qr/\bentry\b/, 'AC-6: second run has no removed/added entry lines');
    my @ts_dirs2 = glob("$f->{home}/.claude/.promotion-backups/*");
    is(scalar(@ts_dirs2), 1, 'AC-6: no new backup directory was created by the second run');
    my $post_run2_bytes = read_bytes("$f->{home}/.claude/settings.json");
    is($post_run2_bytes, $post_run1_bytes, 'AC-6: live settings.json bytes are unchanged by the second run');
}

# ===========================================================================
# AC-7: dry-run of the same scenario. Same entry lines, would-update (2
# changes), live bytes unchanged, no backup dir, exit 0. Dry-run never pulls,
# so live's HEAD (and thus the baseline) stays at v1 throughout.
# ===========================================================================
{
    my $payload_v1 = { permissions => { allow => [ $A, $B, $R ] } };
    my $payload_v2 = { permissions => { allow => [ $A, $B, $N ] } };
    my $live_settings = { permissions => { allow => [ $X, $R, $A, $B ] } };

    my $f = new_fixture(clone_commits => [
        [ { 'global-config/settings.json' => canon_json($payload_v1) }, 'settings v1 (baseline)' ],
    ]);
    clone_extra_commit($f, { 'global-config/settings.json' => canon_json($payload_v2) }, 'settings v2 (current)');
    write_bytes("$f->{home}/.claude/settings.json", canon_json($live_settings));
    my $pre_bytes = read_bytes("$f->{home}/.claude/settings.json");

    my $r = run_promote($f, '--dry-run');
    is($r->{exit}, 0, 'AC-7/AC-16: dry-run exit 0') or diag($r->{out} . $r->{err});
    my $removed_line = entry_line('removed', 'permissions.allow', $R);
    my $added_line   = entry_line('added',   'permissions.allow', $N);
    like($r->{out}, qr/^\Q$removed_line\E$/m, 'AC-7: dry-run prints the exact removed-entry line') or diag($r->{out});
    like($r->{out}, qr/^\Q$added_line\E$/m,   'AC-7: dry-run prints the exact added-entry line') or diag($r->{out});
    like($r->{out}, qr/^settings: would-update \(2 changes\)/m, 'AC-7: summary says would-update (2 changes)')
        or diag($r->{out});

    my $post_bytes = read_bytes("$f->{home}/.claude/settings.json");
    is($post_bytes, $pre_bytes, 'AC-7: live settings.json is byte-unchanged after dry-run');
    ok(!-d "$f->{home}/.claude/.promotion-backups", 'AC-7: no .promotion-backups directory created by dry-run');
}

# ===========================================================================
# AC-3: order preserved. Kept entries retain live order (checked via AC-1's
# [X,A,B,N] result above -- X,A,B keep their live relative order). Additions
# are appended in payload order: baseline v1 allow [A], current v2 allow
# [N2,A,N1], live allow [A] -> live allow becomes [A,N2,N1] (N2 and N1 are
# both absent from the baseline, so both qualify as widening additions).
# ===========================================================================
{
    my $N1 = 'Bash(one-new-thing)';
    my $N2 = 'Bash(another-new-thing)';
    my $payload_v1 = { permissions => { allow => [ $A ] } };
    my $payload_v2 = { permissions => { allow => [ $N2, $A, $N1 ] } };
    my $live_settings = { permissions => { allow => [ $A ] } };

    my $f = new_fixture(clone_commits => [
        [ { 'global-config/settings.json' => canon_json($payload_v1) }, 'settings v1 (baseline)' ],
    ]);
    clone_extra_commit($f, { 'global-config/settings.json' => canon_json($payload_v2) }, 'settings v2 (current)');
    write_bytes("$f->{home}/.claude/settings.json", canon_json($live_settings));

    my $r = run_promote($f);
    is($r->{exit}, 0, 'AC-3/AC-16: exit 0 on the append-order scenario') or diag($r->{out} . $r->{err});
    my $result = decode_bytes_json(read_bytes("$f->{home}/.claude/settings.json"));
    assert_shape($result, 'AC-3');
    is_deeply($result->{permissions}{allow}, [ $A, $N2, $N1 ], 'AC-3: additions are appended in payload order');
}

# ===========================================================================
# AC-4: stale-but-clean live array. Live allow equals the baseline v1
# exactly [A,B,R] -> result [A,B,N], entry lines present, no whole-unit
# "updated permissions.allow" line (that shape never applies to array
# units).
# ===========================================================================
{
    my $payload_v1 = { permissions => { allow => [ $A, $B, $R ] } };
    my $payload_v2 = { permissions => { allow => [ $A, $B, $N ] } };
    my $live_settings = { permissions => { allow => [ $A, $B, $R ] } }; # == v1 (the baseline) exactly

    my $f = new_fixture(clone_commits => [
        [ { 'global-config/settings.json' => canon_json($payload_v1) }, 'settings v1 (baseline)' ],
    ]);
    clone_extra_commit($f, { 'global-config/settings.json' => canon_json($payload_v2) }, 'settings v2 (current)');
    write_bytes("$f->{home}/.claude/settings.json", canon_json($live_settings));

    my $r = run_promote($f);
    is($r->{exit}, 0, 'AC-4/AC-16: exit 0 on the stale-but-clean scenario') or diag($r->{out} . $r->{err});
    my $result = decode_bytes_json(read_bytes("$f->{home}/.claude/settings.json"));
    assert_shape($result, 'AC-4');
    is_deeply($result->{permissions}{allow}, [ $A, $B, $N ], 'AC-4: stale-but-clean live array is merged to [A,B,N]');
    like($r->{out}, entry_line_re('removed', 'permissions.allow', $R), 'AC-4: removed entry line present') or diag($r->{out});
    like($r->{out}, entry_line_re('added',   'permissions.allow', $N), 'AC-4: added entry line present') or diag($r->{out});
    unlike($r->{out}, qr/^  updated permissions\.allow$/m, 'AC-4: no whole-unit "updated permissions.allow" line');
}

# ===========================================================================
# AC-5: deny and ask behave like allow/each other, each as its own unit
# with its own lines, in the same run. Deny's addition and ask's addition
# are narrowing (unaffected by the baseline); ask's removal is widening
# (gated on the baseline v1, which is where R_ask lived).
# ===========================================================================
{
    my $R_deny = 'Bash(rm -f *.log)';
    my $N_deny = 'Bash(chmod 600 *)';
    my $R_ask  = 'Bash(curl *)';
    my $N_ask  = 'Bash(wget *)';

    my $payload_v1 = { permissions => {
        deny => [ $A, $R_deny ],
        ask  => [ $B, $R_ask ],
    } };
    my $payload_v2 = { permissions => {
        deny => [ $A, $N_deny ],
        ask  => [ $B, $N_ask ],
    } };
    my $live_settings = { permissions => {
        deny => [ $X, $R_deny, $A ],
        ask  => [ $X, $R_ask, $B ],
    } };

    my $f = new_fixture(clone_commits => [
        [ { 'global-config/settings.json' => canon_json($payload_v1) }, 'settings v1 (baseline)' ],
    ]);
    clone_extra_commit($f, { 'global-config/settings.json' => canon_json($payload_v2) }, 'settings v2 (current)');
    write_bytes("$f->{home}/.claude/settings.json", canon_json($live_settings));

    my $r = run_promote($f);
    is($r->{exit}, 0, 'AC-5/AC-16: exit 0 across deny and ask') or diag($r->{out} . $r->{err});
    my $result = decode_bytes_json(read_bytes("$f->{home}/.claude/settings.json"));
    if (assert_shape($result, 'AC-5')) {
        is_deeply($result->{permissions}{deny}, [ $X, $A, $N_deny ], 'AC-5: permissions.deny merged correctly (addition is narrowing)');
        is_deeply($result->{permissions}{ask},  [ $X, $B, $N_ask ],  'AC-5: permissions.ask merged correctly (removal is widening, gated on baseline)');
    }
    like($r->{out}, entry_line_re('removed', 'permissions.deny', $R_deny), 'AC-5: removed permissions.deny entry line') or diag($r->{out});
    like($r->{out}, entry_line_re('added',   'permissions.deny', $N_deny), 'AC-5: added permissions.deny entry line') or diag($r->{out});
    like($r->{out}, entry_line_re('removed', 'permissions.ask',  $R_ask),  'AC-5: removed permissions.ask entry line') or diag($r->{out});
    like($r->{out}, entry_line_re('added',   'permissions.ask',  $N_ask),  'AC-5: added permissions.ask entry line') or diag($r->{out});
}

# ===========================================================================
# AC-9: hand re-added retired entry. Live allow [A,B,N,R] where the operator
# re-added R by hand after v2 dropped it -> R removed and reported (this is
# a narrowing removal, judged against the whole history, unaffected by the
# baseline). With a skip-always preference on permissions.allow, it stays
# and kept-pref is printed instead.
# ===========================================================================
{
    my $payload_v1 = { permissions => { allow => [ $A, $B, $R ] } };
    my $payload_v2 = { permissions => { allow => [ $A, $B, $N ] } };
    my $live_settings = { permissions => { allow => [ $A, $B, $N, $R ] } };

    my $f = new_fixture(clone_commits => [
        [ { 'global-config/settings.json' => canon_json($payload_v1) }, 'settings v1 (baseline)' ],
    ]);
    clone_extra_commit($f, { 'global-config/settings.json' => canon_json($payload_v2) }, 'settings v2 (current)');
    write_bytes("$f->{home}/.claude/settings.json", canon_json($live_settings));

    my $r = run_promote($f);
    is($r->{exit}, 0, 'AC-9/AC-16: exit 0 on the hand-re-added scenario') or diag($r->{out} . $r->{err});
    my $result = decode_bytes_json(read_bytes("$f->{home}/.claude/settings.json"));
    assert_shape($result, 'AC-9');
    is_deeply($result->{permissions}{allow}, [ $A, $B, $N ], 'AC-9: hand re-added R is removed');
    like($r->{out}, entry_line_re('removed', 'permissions.allow', $R), 'AC-9: removed entry line for the re-added R') or diag($r->{out});
}
{
    my $payload_v1 = { permissions => { allow => [ $A, $B, $R ] } };
    my $payload_v2 = { permissions => { allow => [ $A, $B, $N ] } };
    my $live_settings = { permissions => { allow => [ $A, $B, $N, $R ] } };

    my $f = new_fixture(clone_commits => [
        [ { 'global-config/settings.json' => canon_json($payload_v1) }, 'settings v1 (baseline)' ],
    ]);
    clone_extra_commit($f, { 'global-config/settings.json' => canon_json($payload_v2) }, 'settings v2 (current)');
    write_bytes("$f->{home}/.claude/settings.json", canon_json($live_settings));
    my $prefs = { live_vs_repo => { 'permissions.allow' => { category => 'diverged', action => 'skip-always' } } };
    write_bytes("$f->{live}/.backup-preferences.json", canon_json($prefs));

    my $r = run_promote($f);
    is($r->{exit}, 0, 'AC-9 (skip-always)/AC-16: exit 0') or diag($r->{out} . $r->{err});
    my $result = decode_bytes_json(read_bytes("$f->{home}/.claude/settings.json"));
    assert_shape($result, 'AC-9 (skip-always)');
    is_deeply($result->{permissions}{allow}, [ $A, $B, $N, $R ], 'AC-9 (skip-always): live permissions.allow is untouched, R survives');
    like($r->{out}, qr/^  kept-pref permissions\.allow \(skip-always\)$/m, 'AC-9 (skip-always): kept-pref line printed')
        or diag($r->{out});
    unlike($r->{out}, qr/\bentry\b/, 'AC-9 (skip-always): no removed/added entry lines');
}

# ===========================================================================
# AC-10: duplicates. Baseline v1 allow=[A,R]; current v2 allow=[A,N,N]; live
# allow=[R,A,R,X,X] -> result [A,X,X,N]; exactly one removed line, one added
# line; changes = 2. R's removal is narrowing; N's addition is widening
# (N is absent from the baseline v1).
# ===========================================================================
{
    my $payload_v1 = { permissions => { allow => [ $A, $R ] } };
    my $payload_v2 = { permissions => { allow => [ $A, $N, $N ] } };
    my $live_settings = { permissions => { allow => [ $R, $A, $R, $X, $X ] } };

    my $f = new_fixture(clone_commits => [
        [ { 'global-config/settings.json' => canon_json($payload_v1) }, 'settings v1 (baseline)' ],
    ]);
    clone_extra_commit($f, { 'global-config/settings.json' => canon_json($payload_v2) }, 'settings v2 (current)');
    write_bytes("$f->{home}/.claude/settings.json", canon_json($live_settings));

    my $r = run_promote($f);
    is($r->{exit}, 0, 'AC-10/AC-16: exit 0 on the duplicates scenario') or diag($r->{out} . $r->{err});
    my $result = decode_bytes_json(read_bytes("$f->{home}/.claude/settings.json"));
    assert_shape($result, 'AC-10');
    is_deeply($result->{permissions}{allow}, [ $A, $X, $X, $N ], 'AC-10: duplicates merged to [A,X,X,N]');
    my @removed_hits = ($r->{out} =~ /^  removed permissions\.allow entry /mg);
    my @added_hits   = ($r->{out} =~ /^  added permissions\.allow entry /mg);
    is(scalar(@removed_hits), 1, 'AC-10: exactly one removed-entry line') or diag($r->{out});
    is(scalar(@added_hits), 1, 'AC-10: exactly one added-entry line') or diag($r->{out});
    like($r->{out}, qr/^settings: updated \(2 changes\)/m, 'AC-10: summary says (2 changes)') or diag($r->{out});
}

# ===========================================================================
# AC-11: non-string element / non-array live value -> whole-value path,
# kept-local, no entry lines, value unchanged by this unit. (review NIT N1:
# this block previously omitted the kept-local assertion for the non-array
# case; it's added here.)
# ===========================================================================
{
    my $payload_v1 = { permissions => { allow => [ $A ] } };
    my $payload_v2 = { permissions => { allow => [ $A, $B ] } };
    my $live_settings = { permissions => { allow => [ $X, { k => 1 } ] } };

    my $f = new_fixture(clone_commits => [
        [ { 'global-config/settings.json' => canon_json($payload_v1) }, 'settings v1 (baseline)' ],
    ]);
    clone_extra_commit($f, { 'global-config/settings.json' => canon_json($payload_v2) }, 'settings v2 (current)');
    write_bytes("$f->{home}/.claude/settings.json", canon_json($live_settings));

    my $r = run_promote($f);
    is($r->{exit}, 0, 'AC-11 (non-string element)/AC-16: exit 0') or diag($r->{out} . $r->{err});
    my $result = decode_bytes_json(read_bytes("$f->{home}/.claude/settings.json"));
    assert_shape($result, 'AC-11 (non-string element)');
    is_deeply($result->{permissions}{allow}, [ $X, { k => 1 } ], 'AC-11 (non-string element): live array is unchanged');
    like($r->{out}, qr/^  kept-local permissions\.allow$/m, 'AC-11 (non-string element): kept-local line printed') or diag($r->{out});
    unlike($r->{out}, qr/permissions\.allow entry/, 'AC-11 (non-string element): no entry lines');
}
{
    my $payload_v1 = { permissions => { allow => [ $A ] } };
    my $payload_v2 = { permissions => { allow => [ $A, $B ] } };
    my $live_settings = { permissions => { allow => 'X' } }; # scalar, not an array

    my $f = new_fixture(clone_commits => [
        [ { 'global-config/settings.json' => canon_json($payload_v1) }, 'settings v1 (baseline)' ],
    ]);
    clone_extra_commit($f, { 'global-config/settings.json' => canon_json($payload_v2) }, 'settings v2 (current)');
    write_bytes("$f->{home}/.claude/settings.json", canon_json($live_settings));

    my $r = run_promote($f);
    is($r->{exit}, 0, 'AC-11 (non-array live value)/AC-16: exit 0') or diag($r->{out} . $r->{err});
    my $result = decode_bytes_json(read_bytes("$f->{home}/.claude/settings.json"));
    assert_shape($result, 'AC-11 (non-array live value)');
    is($result->{permissions}{allow}, 'X', 'AC-11 (non-array live value): unchanged (whole-value kept-local path)');
    unlike($r->{out}, qr/permissions\.allow entry/, 'AC-11 (non-array live value): no entry lines');
    # review NIT N1's fix, applied to the sibling non-array case too: a
    # non-array live value is still an existing, diverged whole-value unit,
    # so it should also report kept-local rather than silence.
    like($r->{out}, qr/^  kept-local permissions\.allow$/m, 'AC-11 (non-array live value): kept-local line printed')
        or diag($r->{out});
}

# ===========================================================================
# AC-12: the three only_left cases for permissions.ask. Baseline v1 ask=[R];
# current payload v2 has no ask key at all. Ask's removal is WIDENING under
# Decision 27, so it is gated on the baseline (v1, which has R) rather than
# the whole history.
#   (a) live ask [R,X] -> [X], one removed line
#   (b) live ask [R]   -> key deleted, one removed line (+ no whole-unit line,
#       review NIT N2)
#   (c) live ask [X]   -> untouched, no line
# ===========================================================================
{
    my $payload_v1 = { permissions => { ask => [ $R ] } };
    my $payload_v2 = { permissions => { } }; # ask dropped entirely
    my $live_settings = { permissions => { ask => [ $R, $X ] } };

    my $f = new_fixture(clone_commits => [
        [ { 'global-config/settings.json' => canon_json($payload_v1) }, 'settings v1 (baseline)' ],
    ]);
    clone_extra_commit($f, { 'global-config/settings.json' => canon_json($payload_v2) }, 'settings v2 (current)');
    write_bytes("$f->{home}/.claude/settings.json", canon_json($live_settings));

    my $r = run_promote($f);
    is($r->{exit}, 0, 'AC-12 (a)/AC-16: exit 0') or diag($r->{out} . $r->{err});
    my $result = decode_bytes_json(read_bytes("$f->{home}/.claude/settings.json"));
    assert_shape($result, 'AC-12 (a)');
    is_deeply($result->{permissions}{ask}, [ $X ], 'AC-12 (a): only_left partial removal leaves [X]');
    like($r->{out}, entry_line_re('removed', 'permissions.ask', $R), 'AC-12 (a): removed entry line') or diag($r->{out});
}
{
    my $payload_v1 = { permissions => { ask => [ $R ] } };
    my $payload_v2 = { permissions => { } };
    my $live_settings = { permissions => { ask => [ $R ] } };

    my $f = new_fixture(clone_commits => [
        [ { 'global-config/settings.json' => canon_json($payload_v1) }, 'settings v1 (baseline)' ],
    ]);
    clone_extra_commit($f, { 'global-config/settings.json' => canon_json($payload_v2) }, 'settings v2 (current)');
    write_bytes("$f->{home}/.claude/settings.json", canon_json($live_settings));

    my $r = run_promote($f);
    is($r->{exit}, 0, 'AC-12 (b)/AC-16: exit 0') or diag($r->{out} . $r->{err});
    my $result = decode_bytes_json(read_bytes("$f->{home}/.claude/settings.json"));
    if (assert_shape($result, 'AC-12 (b)')) {
        ok(!exists $result->{permissions}{ask}, 'AC-12 (b): only_left full removal deletes the ask key');
    }
    like($r->{out}, entry_line_re('removed', 'permissions.ask', $R), 'AC-12 (b): removed entry line') or diag($r->{out});
    unlike($r->{out}, qr/^  removed permissions\.ask$/m, 'AC-12 (b) / review NIT N2: no whole-unit "removed permissions.ask" line');
}
{
    my $payload_v1 = { permissions => { ask => [ $R ] } };
    my $payload_v2 = { permissions => { } };
    my $live_settings = { permissions => { ask => [ $X ] } };

    my $f = new_fixture(clone_commits => [
        [ { 'global-config/settings.json' => canon_json($payload_v1) }, 'settings v1 (baseline)' ],
    ]);
    clone_extra_commit($f, { 'global-config/settings.json' => canon_json($payload_v2) }, 'settings v2 (current)');
    write_bytes("$f->{home}/.claude/settings.json", canon_json($live_settings));

    my $r = run_promote($f);
    is($r->{exit}, 0, 'AC-12 (c)/AC-16: exit 0') or diag($r->{out} . $r->{err});
    my $result = decode_bytes_json(read_bytes("$f->{home}/.claude/settings.json"));
    assert_shape($result, 'AC-12 (c)');
    is_deeply($result->{permissions}{ask}, [ $X ], 'AC-12 (c): untouched, nothing retired');
    unlike($r->{out}, qr/permissions\.ask/, 'AC-12 (c): no report line mentions permissions.ask at all');
}

# ===========================================================================
# AC-13: only_right. v2 deny [D1,D2], live has permissions but no deny key
# -> live deny becomes [D1,D2]; one added line per entry, in payload order.
# Deny's addition is narrowing, unaffected by the baseline. Also asserts the
# missing "no whole-unit line" case (review NIT N2).
# ===========================================================================
{
    my $D1 = 'Bash(shutdown *)';
    my $D2 = 'Bash(format *)';
    my $payload_v1 = { permissions => { } };
    my $payload_v2 = { permissions => { deny => [ $D1, $D2 ] } };
    my $live_settings = { permissions => { } }; # present, no deny key

    my $f = new_fixture(clone_commits => [
        [ { 'global-config/settings.json' => canon_json($payload_v1) }, 'settings v1 (baseline)' ],
    ]);
    clone_extra_commit($f, { 'global-config/settings.json' => canon_json($payload_v2) }, 'settings v2 (current)');
    write_bytes("$f->{home}/.claude/settings.json", canon_json($live_settings));

    my $r = run_promote($f);
    is($r->{exit}, 0, 'AC-13/AC-16: exit 0 on the only_right scenario') or diag($r->{out} . $r->{err});
    my $result = decode_bytes_json(read_bytes("$f->{home}/.claude/settings.json"));
    assert_shape($result, 'AC-13');
    is_deeply($result->{permissions}{deny}, [ $D1, $D2 ], 'AC-13: only_right deny is added whole, in payload order');
    like($r->{out}, entry_line_re('added', 'permissions.deny', $D1), 'AC-13: added entry line for D1') or diag($r->{out});
    like($r->{out}, entry_line_re('added', 'permissions.deny', $D2), 'AC-13: added entry line for D2') or diag($r->{out});
    ok(index($r->{out}, entry_line('added', 'permissions.deny', $D1)) < index($r->{out}, entry_line('added', 'permissions.deny', $D2)),
        'AC-13: D1 line precedes D2 line (payload order)');
    unlike($r->{out}, qr/^  added permissions\.deny$/m, 'AC-13 / review NIT N2: no whole-unit "added permissions.deny" line');
}

# ===========================================================================
# AC-14: other string arrays keep whole-value behaviour. A drifted
# permissions.additionalDirectories is NOT an array unit (K not in
# allow/deny/ask) -- kept-local, no entry lines, value unchanged.
# ===========================================================================
{
    my $old_path = 'C:/old/operator/path';
    my $new_path = 'C:/new/payload/path';
    my $payload_v1 = { permissions => { additionalDirectories => [ $old_path ] } };
    my $payload_v2 = { permissions => { additionalDirectories => [ $new_path ] } };
    my $live_settings = { permissions => { additionalDirectories => [ $old_path, 'C:/operator/only/path' ] } };

    my $f = new_fixture(clone_commits => [
        [ { 'global-config/settings.json' => canon_json($payload_v1) }, 'settings v1 (baseline)' ],
    ]);
    clone_extra_commit($f, { 'global-config/settings.json' => canon_json($payload_v2) }, 'settings v2 (current)');
    write_bytes("$f->{home}/.claude/settings.json", canon_json($live_settings));

    my $r = run_promote($f);
    is($r->{exit}, 0, 'AC-14/AC-16: exit 0 on the additionalDirectories scenario') or diag($r->{out} . $r->{err});
    my $result = decode_bytes_json(read_bytes("$f->{home}/.claude/settings.json"));
    assert_shape($result, 'AC-14');
    is_deeply($result->{permissions}{additionalDirectories}, [ $old_path, 'C:/operator/only/path' ],
        'AC-14: additionalDirectories keeps today\'s whole-value (kept-local) behaviour, unchanged');
    unlike($r->{out}, qr/additionalDirectories entry/, 'AC-14: no entry lines for additionalDirectories');
}

# ===========================================================================
# AC-15 / NB-1: no baseline payload (fresh install: live's pre-merge HEAD
# has no settings.json at all). Decision 27: allow additions then treat the
# baseline as empty, so every current-payload entry counts as "new". Live
# [X,Z], current payload [A] -> result [X,Z,A]; no removed line (there is
# only one payload version, so nothing can be "in H and not in P" either).
# ===========================================================================
{
    my $payload_v1 = { permissions => { allow => [ $A ] } }; # the only payload version; committed
                                                               # AFTER live is cloned from the seed,
                                                               # so live's pre-merge HEAD has no
                                                               # settings.json at all (no baseline).
    my $live_settings = { permissions => { allow => [ $X, 'Bash(operator-Z)' ] } };

    my $f = new_fixture(clone_commits => [
        [ { 'README.md' => "# clone fixture (no settings.json yet)\n" }, 'seed, no baseline' ],
    ]);
    clone_extra_commit($f, { 'global-config/settings.json' => canon_json($payload_v1) }, 'settings (single commit, current)');
    write_bytes("$f->{home}/.claude/settings.json", canon_json($live_settings));

    my $r = run_promote($f);
    is($r->{exit}, 0, 'AC-15/AC-16: exit 0 on the single-commit/no-baseline scenario') or diag($r->{out} . $r->{err});
    my $result = decode_bytes_json(read_bytes("$f->{home}/.claude/settings.json"));
    assert_shape($result, 'AC-15');
    is_deeply($result->{permissions}{allow}, [ $X, 'Bash(operator-Z)', $A ], 'AC-15/NB-1: result is [X,Z,A]; A is added because the baseline is empty');
    unlike($r->{out}, qr/^  removed permissions\.allow/m, 'AC-15: no removed line when H == P');
    like($r->{out}, entry_line_re('added', 'permissions.allow', $A), 'AC-15: added entry line for A') or diag($r->{out});
}

# ===========================================================================
# NB-2: no baseline payload -> deny/ask WIDENING removal removes nothing
# (Decision 27: "deny/ask removals remove nothing" when there is no baseline
# payload). Live already carries an ask entry that no current payload
# version has; since live's pre-merge HEAD has no settings.json at all
# (no baseline), that entry is NOT removed, unlike AC-12(a)'s case where a
# baseline does exist and does contain it.
# ===========================================================================
{
    my $R_hist = 'Bash(curl *)'; # present in NEITHER the (nonexistent) baseline NOR the current payload
    my $payload_v1 = { permissions => { } }; # current payload: no ask key
    my $live_settings = { permissions => { ask => [ $R_hist, $X ] } };

    my $f = new_fixture(clone_commits => [
        [ { 'README.md' => "# clone fixture (no settings.json yet)\n" }, 'seed, no baseline' ],
    ]);
    clone_extra_commit($f, { 'global-config/settings.json' => canon_json($payload_v1) }, 'settings (single commit, current)');
    write_bytes("$f->{home}/.claude/settings.json", canon_json($live_settings));

    my $r = run_promote($f);
    is($r->{exit}, 0, 'NB-2/AC-16: exit 0 on the no-baseline ask-removal scenario') or diag($r->{out} . $r->{err});
    my $result = decode_bytes_json(read_bytes("$f->{home}/.claude/settings.json"));
    assert_shape($result, 'NB-2');
    is_deeply($result->{permissions}{ask}, [ $R_hist, $X ], 'NB-2: with no baseline payload, nothing is removed from ask');
    unlike($r->{out}, qr/permissions\.ask/, 'NB-2: no report line mentions permissions.ask at all');
}

# ===========================================================================
# S1 (red-team SHOULD): an allow entry the operator deleted by hand stays
# deleted across two promotions; an entry new in THIS promotion is added.
#   run 1: baseline empty (fresh install) -> both A and "git push" ship and
#          get added (narrow/widen distinction doesn't matter with an empty
#          baseline: everything is "new").
#   (operator deletes "git push" by hand)
#   run 2: baseline == v1 (== [A, git push], from run 1's payload, now
#          live's pre-merge HEAD) -> "git push" is IN the baseline, so it is
#          not re-added (stays deleted); N is NOT in the baseline, so it IS
#          added.
# ===========================================================================
{
    my $GP = 'Bash(git push *)';
    my $payload_v1 = { permissions => { allow => [ $A, $GP ] } };

    my $f = new_fixture(clone_commits => [
        [ { 'README.md' => "# clone fixture (no settings.json yet)\n" }, 'seed, no baseline' ],
    ]);
    clone_extra_commit($f, { 'global-config/settings.json' => canon_json($payload_v1) }, 'v1: A and git-push ship');
    write_bytes("$f->{home}/.claude/settings.json", canon_json({ permissions => { allow => [] } }));

    my $r1 = run_promote($f);
    is($r1->{exit}, 0, 'S1 run 1: exit 0') or diag($r1->{out} . $r1->{err});
    my $result1 = decode_bytes_json(read_bytes("$f->{home}/.claude/settings.json"));
    assert_shape($result1, 'S1 run 1');
    is_deeply($result1->{permissions}{allow}, [ $A, $GP ], 'S1 run 1: both A and git-push are added (empty baseline)');

    # The operator deletes "git push" by hand.
    write_bytes("$f->{home}/.claude/settings.json", canon_json({ permissions => { allow => [ $A ] } }));

    my $N_new = 'Bash(a-brand-new-thing)';
    my $payload_v2 = { permissions => { allow => [ $A, $GP, $N_new ] } }; # payload still ships git-push, plus N_new
    clone_extra_commit($f, { 'global-config/settings.json' => canon_json($payload_v2) }, 'v2: still ships git-push, adds N_new');

    my $r2 = run_promote($f);
    is($r2->{exit}, 0, 'S1 run 2: exit 0') or diag($r2->{out} . $r2->{err});
    my $result2 = decode_bytes_json(read_bytes("$f->{home}/.claude/settings.json"));
    assert_shape($result2, 'S1 run 2');
    is_deeply($result2->{permissions}{allow}, [ $A, $N_new ], 'S1 run 2: git-push stays deleted; N_new (new since baseline v1) is added');
    unlike($r2->{out}, qr/\Q$GP\E/, 'S1 run 2: no report line mentions the operator-deleted git-push entry at all');
    like($r2->{out}, entry_line_re('added', 'permissions.allow', $N_new), 'S1 run 2: added entry line for N_new') or diag($r2->{out});
}

# ===========================================================================
# S2 (red-team SHOULD): a deny entry equal to one dropped in an EARLIER
# promotion is kept; one dropped by THIS promotion is removed.
#   run 1: baseline empty -> D_old and D_mid both ship and get added
#          (deny addition is narrowing, unaffected by baseline anyway).
#   run 2: baseline == v0 ([D_old,D_mid]); current v1 == [D_mid] -> D_old is
#          IN the baseline and OUT of current -> removed THIS promotion.
#   (operator re-adds D_old by hand, "reviving" an entry dropped in an
#    earlier promotion)
#   run 3: baseline == v1 ([D_mid], does NOT contain D_old); current v2 ==
#          [] -> D_mid is IN the baseline and OUT of current -> removed. But
#          D_old is NOT in the baseline (it was already gone by v1), so it
#          is NOT eligible for removal and stays -- "dropped in an earlier
#          promotion" cannot be retroactively enforced by a later one.
# ===========================================================================
{
    my $D_old = 'Bash(git push --force *)';
    my $D_mid = 'Bash(rm -f *.log)';
    my $payload_v0 = { permissions => { deny => [ $D_old, $D_mid ] } };

    my $f = new_fixture(clone_commits => [
        [ { 'README.md' => "# clone fixture (no settings.json yet)\n" }, 'seed, no baseline' ],
    ]);
    clone_extra_commit($f, { 'global-config/settings.json' => canon_json($payload_v0) }, 'v0: D_old and D_mid ship');
    write_bytes("$f->{home}/.claude/settings.json", canon_json({ permissions => { deny => [ $X ] } }));

    my $r1 = run_promote($f);
    is($r1->{exit}, 0, 'S2 run 1: exit 0') or diag($r1->{out} . $r1->{err});
    my $result1 = decode_bytes_json(read_bytes("$f->{home}/.claude/settings.json"));
    assert_shape($result1, 'S2 run 1');
    is_deeply($result1->{permissions}{deny}, [ $X, $D_old, $D_mid ], 'S2 run 1: both deny entries ship and are added');

    my $payload_v1 = { permissions => { deny => [ $D_mid ] } }; # drops D_old ("earlier" promotion, from run 3's view)
    clone_extra_commit($f, { 'global-config/settings.json' => canon_json($payload_v1) }, 'v1: drops D_old');

    my $r2 = run_promote($f);
    is($r2->{exit}, 0, 'S2 run 2: exit 0') or diag($r2->{out} . $r2->{err});
    my $result2 = decode_bytes_json(read_bytes("$f->{home}/.claude/settings.json"));
    assert_shape($result2, 'S2 run 2');
    is_deeply($result2->{permissions}{deny}, [ $X, $D_mid ], 'S2 run 2: D_old is removed (dropped THIS promotion, baseline v0 had it)');
    like($r2->{out}, entry_line_re('removed', 'permissions.deny', $D_old), 'S2 run 2: removed entry line for D_old') or diag($r2->{out});

    # The operator re-adds D_old by hand -- an entry equal to one dropped in
    # an EARLIER promotion (the v0 -> v1 transition, relative to run 3).
    write_bytes("$f->{home}/.claude/settings.json", canon_json({ permissions => { deny => [ $X, $D_mid, $D_old ] } }));

    my $payload_v2 = { permissions => { deny => [] } }; # THIS promotion drops D_mid; D_old was never here
    clone_extra_commit($f, { 'global-config/settings.json' => canon_json($payload_v2) }, 'v2: drops D_mid too');

    my $r3 = run_promote($f);
    is($r3->{exit}, 0, 'S2 run 3: exit 0') or diag($r3->{out} . $r3->{err});
    my $result3 = decode_bytes_json(read_bytes("$f->{home}/.claude/settings.json"));
    assert_shape($result3, 'S2 run 3');
    is_deeply($result3->{permissions}{deny}, [ $X, $D_old ],
        'S2 run 3: D_mid removed (baseline v1 had it, dropped THIS promotion); D_old kept (baseline v1 never had it -- dropped in an earlier promotion, not this one)');
    like($r3->{out}, entry_line_re('removed', 'permissions.deny', $D_mid), 'S2 run 3: removed entry line for D_mid') or diag($r3->{out});
    unlike($r3->{out}, qr/\Q$D_old\E/, 'S2 run 3: no report line at all mentions D_old (it is simply kept, not "removed")');
}

# ===========================================================================
# PREF (review S3 + red-team M1/M2): the full pref x relation matrix. Every
# recorded preference on an array unit pins it untouched, printing its own
# kept-pref line, no matter what relation the merge would otherwise have
# computed this run. M1 is the (skip-always, only_left) row; M2 is the
# (right-only, diverged) row. The rest fill in "every pref kind pins every
# relation".
# ===========================================================================
{
    my @cases = (
        # [ pref_category, pref_action, relation, unit ]
        [ 'diverged',   'skip-always', 'only_left',  'deny' ],  # M1 exact
        [ 'diverged',   'skip-always', 'only_right', 'ask'  ],  # skip-always pins only_right too
        [ 'only_right', 'right-only',  'diverged',   'allow' ], # M2 exact
        [ 'only_right', 'right-only',  'only_left',  'deny'  ], # right-only pins only_left too
        [ 'only_left',  'left-only',   'only_left',  'ask'   ], # review S3(a): left-only's own relation
        [ 'only_left',  'left-only',   'diverged',   'allow' ], # left-only pins diverged too
        [ 'only_right', 'right-only',  'only_right', 'deny'  ], # review S3(b): right-only's own relation
        [ 'only_left',  'left-only',   'only_right', 'ask'   ], # left-only pins only_right too
    );

    for my $c (@cases) {
        my ($pref_category, $pref_action, $relation, $unit) = @$c;
        my $key = "permissions.$unit";
        my ($v1, $v2, $live_settings);
        if ($relation eq 'diverged') {
            $v1 = { permissions => { $unit => [ $A ] } };
            $v2 = { permissions => { $unit => [ $A, $B ] } };
            $live_settings = { permissions => { $unit => [ $X ] } };
        } elsif ($relation eq 'only_left') {
            $v1 = { permissions => { $unit => [ $A ] } };
            $v2 = { permissions => { } };
            $live_settings = { permissions => { $unit => [ $A, $X ] } };
        } else { # only_right
            $v1 = { permissions => { } };
            $v2 = { permissions => { $unit => [ $A ] } };
            $live_settings = { permissions => { } };
        }

        my $f = new_fixture(clone_commits => [
            [ { 'global-config/settings.json' => canon_json($v1) }, 'v1 (baseline)' ],
        ]);
        clone_extra_commit($f, { 'global-config/settings.json' => canon_json($v2) }, 'v2 (current)');
        write_bytes("$f->{home}/.claude/settings.json", canon_json($live_settings));
        my $prefs = { live_vs_repo => { $key => { category => $pref_category, action => $pref_action } } };
        write_bytes("$f->{live}/.backup-preferences.json", canon_json($prefs));
        my $pre_bytes = read_bytes("$f->{home}/.claude/settings.json");

        my $label = "PREF ($pref_action pref, $relation relation, $unit)";
        my $r = run_promote($f);
        is($r->{exit}, 0, "$label: exit 0") or diag($r->{out} . $r->{err});
        my $post_bytes = read_bytes("$f->{home}/.claude/settings.json");
        is($post_bytes, $pre_bytes, "$label: live settings.json is byte-unchanged (unit fully untouched)");
        like($r->{out}, qr/^  kept-pref \Q$key\E \(\Q$pref_action\E\)$/m, "$label: kept-pref line printed with the pref's own action")
            or diag($r->{out});
        unlike($r->{out}, qr/\Q$key\E entry/, "$label: no removed/added entry lines for $key");
        unlike($r->{out}, qr/^  (?:added|removed|updated) \Q$key\E$/m, "$label: no whole-unit added/removed/updated line for $key");
    }
}

# ===========================================================================
# NUM (review S1 / red-team S3): JSON numbers are not JSON strings (spec
# 2.1 item 3). An array containing a number on either side is NOT an array
# unit -- it takes the whole-value path (kept-local), never entry lines.
# ===========================================================================
{
    # (a) number on the LIVE side.
    my $payload_v1 = { permissions => { allow => [ $A ] } };
    my $payload_v2 = { permissions => { allow => [ $A, $B ] } };
    my $live_settings = { permissions => { allow => [ $X, 5 ] } }; # 5 is a JSON number, not a string

    my $f = new_fixture(clone_commits => [
        [ { 'global-config/settings.json' => canon_json($payload_v1) }, 'v1 (baseline)' ],
    ]);
    clone_extra_commit($f, { 'global-config/settings.json' => canon_json($payload_v2) }, 'v2 (current)');
    write_bytes("$f->{home}/.claude/settings.json", canon_json($live_settings));

    my $r = run_promote($f);
    is($r->{exit}, 0, 'NUM (live-side number): exit 0') or diag($r->{out} . $r->{err});
    my $result = decode_bytes_json(read_bytes("$f->{home}/.claude/settings.json"));
    assert_shape($result, 'NUM (live-side number)');
    is_deeply($result->{permissions}{allow}, [ $X, 5 ], 'NUM (live-side number): live array unchanged (whole-value path)');
    like($r->{out}, qr/^  kept-local permissions\.allow$/m, 'NUM (live-side number): kept-local line printed') or diag($r->{out});
    unlike($r->{out}, qr/permissions\.allow entry/, 'NUM (live-side number): no entry lines');
}
{
    # (b) number on the PAYLOAD side.
    my $payload_v1 = { permissions => { allow => [ $A ] } };
    my $payload_v2 = { permissions => { allow => [ $A, 5 ] } }; # 5 is a JSON number, not a string
    my $live_settings = { permissions => { allow => [ $X ] } };

    my $f = new_fixture(clone_commits => [
        [ { 'global-config/settings.json' => canon_json($payload_v1) }, 'v1 (baseline)' ],
    ]);
    clone_extra_commit($f, { 'global-config/settings.json' => canon_json($payload_v2) }, 'v2 (current)');
    write_bytes("$f->{home}/.claude/settings.json", canon_json($live_settings));

    my $r = run_promote($f);
    is($r->{exit}, 0, 'NUM (payload-side number): exit 0') or diag($r->{out} . $r->{err});
    my $result = decode_bytes_json(read_bytes("$f->{home}/.claude/settings.json"));
    assert_shape($result, 'NUM (payload-side number)');
    is_deeply($result->{permissions}{allow}, [ $X ], 'NUM (payload-side number): live array unchanged (whole-value path)');
    like($r->{out}, qr/^  kept-local permissions\.allow$/m, 'NUM (payload-side number): kept-local line printed') or diag($r->{out});
    unlike($r->{out}, qr/permissions\.allow entry/, 'NUM (payload-side number): no entry lines');
}

# ===========================================================================
# NONASCII (review NIT N3): a non-ASCII entry round-trips with no double
# encoding, in both the live array and the report line's UTF-8 bytes.
# Kept as a pure narrowing removal (no addition involved) so it exercises
# only the UTF-8 path, not the baseline logic.
# ===========================================================================
{
    my $R_nonascii = "Bash(ls /c/Users/Andr\x{e9})"; # Andre with an eacute
    my $payload_v1 = { permissions => { allow => [ $A, $R_nonascii ] } };
    my $payload_v2 = { permissions => { allow => [ $A ] } };
    # A is already live (it's in the baseline v1 payload), so nothing is added here.
    my $live_settings = { permissions => { allow => [ $X, $A, $R_nonascii ] } };

    my $f = new_fixture(clone_commits => [
        [ { 'global-config/settings.json' => canon_json($payload_v1) }, 'v1 (baseline)' ],
    ]);
    clone_extra_commit($f, { 'global-config/settings.json' => canon_json($payload_v2) }, 'v2 (current)');
    write_bytes("$f->{home}/.claude/settings.json", canon_json($live_settings));

    my $r = run_promote($f);
    is($r->{exit}, 0, 'NONASCII: exit 0') or diag($r->{out} . $r->{err});
    my $result = decode_bytes_json(read_bytes("$f->{home}/.claude/settings.json"));
    assert_shape($result, 'NONASCII');
    is_deeply($result->{permissions}{allow}, [ $X, $A ], 'NONASCII: the non-ASCII entry is removed, X and A survive');
    like($r->{out}, entry_line_re('removed', 'permissions.allow', $R_nonascii),
        'NONASCII: the exact UTF-8-encoded removed-entry line appears (no double encoding)') or diag($r->{out});
    # Guard against the double-encoding failure mode directly: the mangled
    # 0xC3 0x83 lead-byte pair (re-encoding already-UTF-8 bytes) must not
    # appear anywhere in the report.
    unlike($r->{out}, qr/\xC3\x83/, 'NONASCII: no double-encoded byte pair appears anywhere in the report');
}

# ===========================================================================
# REORDER (review NIT N3): a pure payload reorder with no set change is
# changes == 0 -- no report line, nothing written, settings: unchanged.
# ===========================================================================
{
    my $payload_v1 = { permissions => { allow => [ $A, $B ] } };
    my $payload_v2 = { permissions => { allow => [ $B, $A ] } }; # reordered only, same elements
    my $live_settings = { permissions => { allow => [ $A, $B ] } }; # equals v1's order exactly

    my $f = new_fixture(clone_commits => [
        [ { 'global-config/settings.json' => canon_json($payload_v1) }, 'v1 (baseline)' ],
    ]);
    clone_extra_commit($f, { 'global-config/settings.json' => canon_json($payload_v2) }, 'v2 (current, reordered)');
    write_bytes("$f->{home}/.claude/settings.json", canon_json($live_settings));
    my $pre_bytes = read_bytes("$f->{home}/.claude/settings.json");

    my $r = run_promote($f);
    is($r->{exit}, 0, 'REORDER: exit 0') or diag($r->{out} . $r->{err});
    my $post_bytes = read_bytes("$f->{home}/.claude/settings.json");
    is($post_bytes, $pre_bytes, 'REORDER: live settings.json is byte-unchanged (changes == 0)');
    like($r->{out}, qr/^settings: unchanged/m, 'REORDER: settings: unchanged') or diag($r->{out});
    unlike($r->{out}, qr/permissions\.allow/, 'REORDER: no report line at all mentions permissions.allow');
    ok(!-d "$f->{home}/.claude/.promotion-backups", 'REORDER: no backup directory created');
}

# ===========================================================================
# N1 (red-team NIT): a live or payload settings.json that decodes to valid
# JSON but is NOT a JSON object (null, [], "x") -> settings: error, exit 2,
# nothing written. Distinct from promote-syncs-global-config.t's AC-11
# (malformed/unparseable JSON syntax); these are syntactically valid JSON.
# ===========================================================================
for my $bad_json (qw(null [] "x")) {
    # (a) the LIVE settings.json is the bad value.
    {
        my $f = new_fixture(clone_commits => [
            [ { 'global-config/settings.json' => canon_json({ permissions => { allow => [ $A ] } }) }, 'settings' ],
        ]);
        write_bytes("$f->{home}/.claude/settings.json", $bad_json);
        my $pre_bytes = read_bytes("$f->{home}/.claude/settings.json");

        my $r = run_promote($f);
        is($r->{exit}, 2, "N1 (live=$bad_json): exit 2") or diag($r->{out} . $r->{err});
        like($r->{out}, qr/^settings: error/m, "N1 (live=$bad_json): report says settings: error") or diag($r->{out});
        my $post_bytes = read_bytes("$f->{home}/.claude/settings.json");
        is($post_bytes, $pre_bytes, "N1 (live=$bad_json): live settings.json is byte-unchanged");
        ok(!-d "$f->{home}/.claude/.promotion-backups", "N1 (live=$bad_json): no backup directory created");
    }
    # (b) the PAYLOAD settings.json is the bad value.
    {
        my $f = new_fixture(clone_commits => [
            [ { 'global-config/settings.json' => $bad_json }, 'settings' ],
        ]);
        write_bytes("$f->{home}/.claude/settings.json", canon_json({ permissions => { allow => [ $X ] } }));
        my $pre_bytes = read_bytes("$f->{home}/.claude/settings.json");

        my $r = run_promote($f);
        is($r->{exit}, 2, "N1 (payload=$bad_json): exit 2") or diag($r->{out} . $r->{err});
        like($r->{out}, qr/^settings: error/m, "N1 (payload=$bad_json): report says settings: error") or diag($r->{out});
        my $post_bytes = read_bytes("$f->{home}/.claude/settings.json");
        is($post_bytes, $pre_bytes, "N1 (payload=$bad_json): live settings.json is byte-unchanged");
        ok(!-d "$f->{home}/.claude/.promotion-backups", "N1 (payload=$bad_json): no backup directory created");
    }
}

# ===========================================================================
# N2 (red-team NIT): a symlinked settings.json is preserved (handled like
# the CLAUDE.md branch), not silently replaced by a regular file. Guarded by
# the same symlink-capability probe the sibling oracle
# (promote-syncs-global-config.t AC-8 "linked" case) already uses; that
# probe is confirmed working on this host (symlink() succeeds), so this
# case is exercised rather than skipped.
# ===========================================================================
SKIP: {
    my $probe_dir = tempdir(HostCaps::tempdir_args(), CLEANUP => 1);
    my $symlink_works = eval {
        symlink("$probe_dir/target", "$probe_dir/link") or die;
        1;
    } ? 1 : 0;
    skip 'N2: symlink() is not supported on this host', 1 unless $symlink_works;

    my $payload_v1 = { permissions => { allow => [ $A, $R ] } };
    my $payload_v2 = { permissions => { allow => [ $A ] } }; # R retired (narrowing only)
    my $live_settings = { permissions => { allow => [ $X, $R ] } };

    my $f = new_fixture(clone_commits => [
        [ { 'global-config/settings.json' => canon_json($payload_v1) }, 'v1 (baseline)' ],
    ]);
    clone_extra_commit($f, { 'global-config/settings.json' => canon_json($payload_v2) }, 'v2 (current)');

    # Point home's settings.json at a real target file via a symlink,
    # exactly as the sibling oracle does for CLAUDE.md.
    my $target = "$f->{root}/settings-target.json";
    write_bytes($target, canon_json($live_settings));
    unlink "$f->{home}/.claude/settings.json" if -e "$f->{home}/.claude/settings.json";
    my $ok_link = eval {
        symlink($target, "$f->{home}/.claude/settings.json") or die;
        1;
    } ? 1 : 0;
    skip 'N2: could not create the symlink fixture', 1 unless $ok_link;

    my $r = run_promote($f);
    is($r->{exit}, 0, 'N2: exit 0 with a symlinked settings.json') or diag($r->{out} . $r->{err});
    ok(-l "$f->{home}/.claude/settings.json", 'N2: settings.json is still a symlink after promote (not replaced by a regular file)');
    my $target_bytes = read_bytes($target);
    my $target_result = decode_bytes_json($target_bytes);
    if (assert_shape($target_result, 'N2')) {
        is_deeply($target_result->{permissions}{allow}, [ $X ], 'N2: the merge was written THROUGH the symlink, to its target');
    }
}

# ===========================================================================
# AC-18: perl -c is clean on scripts/promote.pl (read-only compile check;
# this file's write set never includes scripts/promote.pl).
# ===========================================================================
{
    if (-f $PROMOTE) {
        my ($efh, $ename) = tempfile(UNLINK => 1);
        close $efh;
        open(my $saved_err, '>&', \*STDERR) or die "cannot dup STDERR: $!";
        open(STDERR, '>', $ename) or die "cannot redirect STDERR: $!";
        my $rc = system($^X, '-c', $PROMOTE);
        open(STDERR, '>&', $saved_err) or warn "cannot restore STDERR: $!";
        close $saved_err;
        my $err = read_bytes($ename) // '';
        unlink $ename;
        ok($rc == 0, 'AC-18: perl -c exits 0 for scripts/promote.pl') or diag($err);
    } else {
        ok(0, 'AC-18: perl -c exits 0 for scripts/promote.pl (file not found)');
    }
}

# ---------------------------------------------------------------------------
# NOT TESTED: red-team S4 (write_bytes_atomic ignores print/close failures on
# a truncated write, e.g. disk full or an AV lock). Reliably forcing a
# print/close failure -- as opposed to an earlier, different failure such as
# "cannot open the temp file at all" -- needs either a filesystem quota, a
# full disk, or another OS-level fault injection this test-writer cannot
# construct hermetically and portably on this Windows host from fixtures
# alone (making the target directory read-only does not reliably reproduce
# a *partial* write on Windows, and would risk asserting the wrong failure
# mode). Reported as untestable-as-specified rather than faked with a
# guessed mechanism.
# ---------------------------------------------------------------------------

done_testing();
