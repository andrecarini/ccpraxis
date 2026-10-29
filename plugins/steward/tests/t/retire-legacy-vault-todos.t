#!/usr/bin/env perl
# platform: any
#
# Blueprint tooling-fixes, package 04-retire-legacy-vault-todos.
# Spec: .ccpraxis-local-data/blueprints/tooling-fixes/specs/04-retire-legacy-vault-todos-spec.md
#
# Written blind to the implementation of vault-sync.pl's cmd_init. It proves,
# on a fixture vault, the ledger's three done criteria:
#   1. a fresh scaffold has no todos/;
#   2. a sync with an existing todos/ neither re-creates, commits nor deletes
#      it (and, once todos/ has been removed upstream, nothing recreates it);
#   3. no script under plugins/ references the vault todos/ path, apart from
#      the migration tool and the two allow-listed comments the spec names.
#
# AC numbering follows spec section 4's table.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Find ();
use File::Basename qw(basename);
use File::Path qw(remove_tree);
use JSON::PP;
use StewardTest qw(
    ok is like unlike diag done_testing
    temproot init_remote make_machine run_vs write_text read_text path_exists
);

my $ROOT = "$Bin/../../../..";

# -e, not -d: in a linked worktree (git worktree add) .git is a FILE.
ok(-e "$ROOT/.git", 'the repo root resolved above this file looks like a git worktree (sanity check)')
    or diag("resolved ROOT=$ROOT");

# ---------------------------------------------------------------------------
# Hermetic git helpers for THIS TEST's own git calls (fixture setup and
# verification -- never what vault-sync.pl itself runs). Spec 4: HOME/
# USERPROFILE = the fake home, GIT_CONFIG_GLOBAL/_SYSTEM set, terminal prompt
# off, MSYS2_ARG_CONV_EXCL deleted with `local %ENV` (StewardTest::_run's own
# convention), and every directory folded from /c/... to C:/... before it
# reaches native git -- the hand-translate side of the MSYS2 argv rule, never
# the "set the env var and hope" side.
# ---------------------------------------------------------------------------
sub native_path {
    my ($p) = @_;
    return $p unless defined $p;
    (my $q = $p) =~ s{\\}{/}g;
    $q =~ s{^/([A-Za-z])/}{\u$1:/};
    return $q;
}

sub git_env_for {
    my ($home) = @_;
    return (
        HOME => $home, USERPROFILE => $home,
        GIT_CONFIG_GLOBAL => "$home/.gitconfig", GIT_CONFIG_SYSTEM => '/dev/null',
        GIT_TERMINAL_PROMPT => '0',
        GIT_AUTHOR_NAME => 'Steward Test', GIT_AUTHOR_EMAIL => 'steward-test@example.invalid',
        GIT_COMMITTER_NAME => 'Steward Test', GIT_COMMITTER_EMAIL => 'steward-test@example.invalid',
    );
}

sub git_ok {
    my ($home, $dir, @args) = @_;
    local %ENV = %ENV;
    delete $ENV{MSYS2_ARG_CONV_EXCL};
    my %genv = git_env_for($home);
    @ENV{ keys %genv } = values %genv;
    my $rc = system('git', '-C', native_path($dir), @args);
    return $rc == 0;
}

sub git_out {
    my ($home, $dir, @args) = @_;
    local %ENV = %ENV;
    delete $ENV{MSYS2_ARG_CONV_EXCL};
    my %genv = git_env_for($home);
    @ENV{ keys %genv } = values %genv;
    my $pid = open my $fh, '-|', 'git', '-C', native_path($dir), @args;
    return '' unless $pid;
    local $/;
    my $out = <$fh>;
    close $fh;
    return defined $out ? $out : '';
}

sub git_ls_tree {
    my ($home, $dir, $ref) = @_;
    my $out = git_out($home, $dir, 'ls-tree', '-r', '--name-only', $ref);
    return sort grep { length } split /\n/, $out;
}

sub rev_parse {
    my ($home, $dir, $ref) = @_;
    my $out = git_out($home, $dir, 'rev-parse', $ref);
    $out =~ s/\s+\z//;
    return $out;
}

# ===========================================================================
# AC1 + AC1b -- B1: init against an EMPTY bare remote.
# ===========================================================================
{
    my $root   = temproot();
    my $remote = init_remote($root);
    my $home   = make_machine($root, 'home1');
    my $vault  = "$home/.claude/claude-code-vault";

    my $init = run_vs($home, 'init', '--url', $remote);
    is($init->{json} && $init->{json}{status}, 'initialized', 'AC1: init against an empty remote exits with status initialized')
        or diag($init->{out});

    ok(!-e "$vault/todos", 'AC1: the fresh vault has no todos/ (file or directory)');

    my @tree = git_ls_tree($home, $remote, 'main');
    is(join(',', @tree), join(',', sort qw(.gitattributes .gitignore README.md)),
        'AC1: the remote main tree lists exactly .gitattributes, .gitignore and README.md')
        or diag('got: ' . join(',', @tree));

    my $subject = git_out($home, $remote, 'log', '-1', '--pretty=%s', 'main');
    $subject =~ s/\s+\z//;
    is($subject, 'Initial vault scaffold (README, .gitignore, .gitattributes)',
        'AC1: the HEAD subject is the new scaffold message');

    my $readme = read_text("$vault/README.md");
    ok(defined($readme) && $readme =~ /^\Q# claude-code-vault\E\n/,
        'AC1: README.md starts with "# claude-code-vault"');
    like($readme // '', qr/Managed by `vault-sync\.pl` in ccpraxis\./,
        'AC1: README.md still credits vault-sync.pl');
    unlike($readme // '', qr/todos/i, 'AC1: README.md does not mention todos, case-insensitive');

    # AC1b -- non-vacuity: the scaffold branch really ran (not skipped).
    ok(-d "$vault/.git", 'AC1b non-vacuity: the fresh vault really has a .git dir');
    my $main_sha = rev_parse($home, $remote, 'main');
    ok(length($main_sha) == 40, 'AC1b non-vacuity: the remote really has a main ref with a real commit')
        or diag("main_sha=[$main_sha]");
}

# ===========================================================================
# AC2a/AC2b/AC2c -- B3: an existing todos/ is inert across every sync verb.
# ===========================================================================
my ($ac2_root, $ac2_remote, $ac2_home, $ac2_vault, $sha_before_sync, $stored_remote);
{
    $ac2_root   = temproot();
    $ac2_remote = init_remote($ac2_root);
    $ac2_home   = make_machine($ac2_root, 'home1');
    $ac2_vault  = "$ac2_home/.claude/claude-code-vault";

    # Fixture step 1: a fresh scaffold with no todos.
    my $init0 = run_vs($ac2_home, 'init', '--url', $ac2_remote);
    is($init0->{json} && $init0->{json}{status}, 'initialized', 'AC2 fixture: initial scaffold succeeded')
        or diag($init0->{out});

    # Fixture step 2: write a pre-04 vault's tracked todos/ content.
    write_text("$ac2_vault/todos/legacy-one.md",         "legacy one\n");
    write_text("$ac2_vault/todos/archive/legacy-two.md", "legacy two\n");
    write_text("$ac2_vault/todos/.gitkeep",              "");

    # Fixture step 3: commit and push it with a `-- todos` pathspec, exactly
    # the discipline the real §7 removal (and VaultNamespace.pm) uses.
    ok(git_ok($ac2_home, $ac2_vault, 'add', '--', 'todos'), 'AC2 fixture: git add -- todos succeeded');
    ok(git_ok($ac2_home, $ac2_vault, 'commit', '-q', '-m', 'fixture: pre-04 tracked todos/', '--', 'todos'),
        'AC2 fixture: git commit -- todos succeeded');
    ok(git_ok($ac2_home, $ac2_vault, 'push', 'origin', 'main'), 'AC2 fixture: git push succeeded');

    # vault-sync.pl's own git_path() rewrites a POSIX /c/... url to Windows
    # C:/... form before handing it to `git clone`, so `git remote get-url
    # origin` reports back that Windows form -- not the POSIX form
    # init_remote() returned. A same-host re-init string-compares --url
    # against the STORED remote (cmd_init's already_initialized branch), so
    # every subsequent init on this machine must pass the form actually
    # stored, or it hits the (unrelated) url-mismatch error path instead of
    # the no-op this fixture needs.
    $stored_remote = git_out($ac2_home, $ac2_vault, 'remote', 'get-url', 'origin');
    $stored_remote =~ s/\s+\z//;
    ok(length($stored_remote) > 0, 'AC2 fixture: recorded the stored origin remote url for same-host re-init calls');

    # Fixture step 4: an untracked legacy file alongside the tracked ones.
    write_text("$ac2_vault/todos/untracked.md", "never added\n");

    # Fixture step 5: record HEAD before any sync verb runs.
    $sha_before_sync = rev_parse($ac2_home, $ac2_vault, 'HEAD');
    ok(length($sha_before_sync) == 40, 'AC2 fixture: recorded a real HEAD sha before syncing')
        or diag("sha_before_sync=[$sha_before_sync]");

    # Fixture step 6: a project to register/sync/commit, so the verbs under
    # test actually do real work (not just no-ops).
    my $proj = "$ac2_root/proj1";
    write_text("$proj/CLAUDE.md", "# proj1\n");

    # Fixture step 7: register --fresh, sync-project, commit-and-push.
    my $reg = run_vs($ac2_home, 'register', '--fresh', '--cwd', $proj, '--slug', 'proj1', '--files', 'CLAUDE.md');
    is($reg->{json} && $reg->{json}{status}, 'registered_fresh', 'AC2 fixture: register --fresh succeeded')
        or diag($reg->{out});
    my $sp = run_vs($ac2_home, 'sync-project', '--slug', 'proj1');
    is($sp->{json} && $sp->{json}{status}, 'synced', 'AC2 fixture: sync-project succeeded') or diag($sp->{out});
    my $cap = run_vs($ac2_home, 'commit-and-push', '--slug', 'proj1', '--session-id', ($sp->{json}{session_id} // ''));
    is($cap->{json} && $cap->{json}{status}, 'committed_and_pushed', 'AC2 fixture: commit-and-push succeeded')
        or diag($cap->{out});

    # Fixture step 8: a notes/ file, then sync-global-almanac, so that verb
    # really commits too (spec's non-vacuity requirement, AC2c).
    write_text("$ac2_vault/notes/n1.md", "a global note\n");
    my $sga = run_vs($ac2_home, 'sync-global-almanac');
    is($sga->{json} && $sga->{json}{status}, 'synced', 'AC2 fixture: sync-global-almanac succeeded')
        or diag($sga->{out});
    ok($sga->{json} && $sga->{json}{committed}, 'AC2 fixture non-vacuity: sync-global-almanac really committed');

    # Fixture step 9: init --url R again -- already initialized, must be a
    # no-op with respect to todos/.
    my $init1 = run_vs($ac2_home, 'init', '--url', $stored_remote);
    is($init1->{json} && $init1->{json}{status}, 'already_initialized', 'AC2 fixture: second init is a no-op')
        or diag($init1->{out});
}

# AC2a -- the tracked todos/ files survive every verb above.
{
    my @ls = git_out($ac2_home, $ac2_vault, 'ls-files', '--', 'todos');
    my @tracked = sort split /\n/, join('', @ls);
    is(join(',', @tracked),
       join(',', sort qw(todos/.gitkeep todos/archive/legacy-two.md todos/legacy-one.md)),
       'AC2a: every tracked todos/* path is still in git ls-files')
        or diag('got: ' . join(',', @tracked));

    my @remote_tree = grep { m{^todos/} } git_ls_tree($ac2_home, $ac2_remote, 'main');
    is(join(',', sort @remote_tree),
       join(',', sort qw(todos/.gitkeep todos/archive/legacy-two.md todos/legacy-one.md)),
       'AC2a: every tracked todos/* path is still in the remote main tree')
        or diag('got: ' . join(',', @remote_tree));

    is(read_text("$ac2_vault/todos/legacy-one.md"), "legacy one\n",
        'AC2a: todos/legacy-one.md is byte-identical on disk');
    is(read_text("$ac2_vault/todos/archive/legacy-two.md"), "legacy two\n",
        'AC2a: todos/archive/legacy-two.md is byte-identical on disk');
}

# AC2b -- no commit made by any of those verbs touches todos/, and the
# untracked file stays untracked.
{
    my $diff = git_out($ac2_home, $ac2_vault, 'diff', '--name-only', $sha_before_sync, 'HEAD', '--', 'todos');
    is($diff, '', 'AC2b: no commit between the recorded HEAD and now touches todos/')
        or diag("diff: $diff");

    ok(-f "$ac2_vault/todos/untracked.md", 'AC2b: todos/untracked.md is still on disk');

    my $status = git_out($ac2_home, $ac2_vault, 'status', '--porcelain', '--', 'todos');
    my @lines = grep { length } split /\n/, $status;
    is(join(',', @lines), '?? todos/untracked.md',
        'AC2b: git status --porcelain -- todos shows only the untracked leftover')
        or diag('got: ' . join(',', @lines));
}

# AC2c -- non-vacuity for AC2b: HEAD actually moved during the run, carrying
# at least one project commit and one global-almanac commit, so "no commit
# touched todos/" is not "no commit happened".
{
    my $sha_after = rev_parse($ac2_home, $ac2_vault, 'HEAD');
    isnt_eq($sha_after, $sha_before_sync, 'AC2c non-vacuity: HEAD moved past the recorded pre-sync sha');

    my $count = git_out($ac2_home, $ac2_vault, 'rev-list', '--count', "$sha_before_sync..HEAD");
    $count =~ s/\s+\z//;
    ok($count >= 2, "AC2c non-vacuity: at least 2 new commits landed (got $count)");

    my $subjects = git_out($ac2_home, $ac2_vault, 'log', '--pretty=%s', "$sha_before_sync..HEAD");
    like($subjects, qr/^Sync global almanac:/m, 'AC2c non-vacuity: a global-almanac commit landed on R');

    my $touched_projects = git_out($ac2_home, $ac2_vault, 'log', '--name-only', '--pretty=format:', "$sha_before_sync..HEAD");
    like($touched_projects, qr{^projects/proj1/}m, 'AC2c non-vacuity: a project commit landed on R');
}

sub isnt_eq {
    my ($got, $unexpected, $name) = @_;
    ok((!defined($got) && !defined($unexpected)) ? 0 : (defined($got) xor defined($unexpected)) ? 1 : ($got ne $unexpected), $name)
        or diag("  got:         " . (defined $got ? "[$got]" : 'undef') . "\n  expected NOT: " . (defined $unexpected ? "[$unexpected]" : 'undef'));
}

# ===========================================================================
# AC2d -- B4: after todos/ is removed upstream, nothing recreates it.
# ===========================================================================
{
    # AC2d step 1: remove todos/ entirely, with the same pathspec-scoped
    # commit discipline the real §7 removal will use.
    ok(git_ok($ac2_home, $ac2_vault, 'rm', '-r', '-q', '--', 'todos'), 'AC2d fixture: git rm -r -- todos succeeded');
    ok(git_ok($ac2_home, $ac2_vault, 'commit', '-q', '-m', 'fixture: retire legacy todos/', '--', 'todos'),
        'AC2d fixture: commit -- todos succeeded');
    ok(git_ok($ac2_home, $ac2_vault, 'push', 'origin', 'main'), 'AC2d fixture: push succeeded');

    # AC2d step 2: drop the untracked leftover too. `git rm -r` only removes
    # TRACKED paths, so it left this untracked file behind and (because of
    # it) the now-otherwise-empty todos/ directory itself; remove_tree finishes
    # the cleanup a real machine with no stray untracked file would already
    # have reached after the commit above.
    remove_tree("$ac2_vault/todos") if -e "$ac2_vault/todos";

    # AC2d step 3: rerun the same verbs on the first machine ...
    my $proj2 = "$ac2_root/proj2";
    write_text("$proj2/CLAUDE.md", "# proj2\n");
    run_vs($ac2_home, 'register', '--fresh', '--cwd', $proj2, '--slug', 'proj2', '--files', 'CLAUDE.md');
    my $sp2 = run_vs($ac2_home, 'sync-project', '--slug', 'proj2');
    run_vs($ac2_home, 'commit-and-push', '--slug', 'proj2', '--session-id', ($sp2->{json}{session_id} // ''));
    write_text("$ac2_vault/notes/n2.md", "another global note\n");
    run_vs($ac2_home, 'sync-global-almanac');
    run_vs($ac2_home, 'init', '--url', $stored_remote);

    # ... plus init on a SECOND fake machine, cloning the now-non-empty remote.
    my $home2  = make_machine($ac2_root, 'home2');
    my $vault2 = "$home2/.claude/claude-code-vault";
    my $init2  = run_vs($home2, 'init', '--url', $ac2_remote);
    is($init2->{json} && $init2->{json}{status}, 'initialized', 'AC2d: init on a second, fresh machine succeeded')
        or diag($init2->{out});

    ok(!-e "$ac2_vault/todos", 'AC2d: no todos entry exists under the first machine\'s vault');
    ok(!-e "$vault2/todos", 'AC2d: no todos entry exists under the second machine\'s vault');

    my @remote_tree_after = grep { m{^todos/} } git_ls_tree($ac2_home, $ac2_remote, 'main');
    is(scalar(@remote_tree_after), 0, 'AC2d: the remote main tree has no path beginning todos/')
        or diag('got: ' . join(',', @remote_tree_after));
}

# ===========================================================================
# AC3 / AC3b / AC3c -- B5: a static source scan of every script file under
# plugins/ for a reference to the vault todos/ path.
# ===========================================================================
{
    # Spec 4 AC3's allow-list: path -> regex the (single) hit line must match.
    my %ALLOW = (
        'plugins/almanac/scripts/almanac-migrate-todos.pl' => qr/.?/s,   # any line
        'plugins/steward/scripts/VaultNamespace.pm'        => qr{todos/ \(legacy, no writer since almanac-records 13\)},
        'plugins/steward/scripts/update-research.pl'       => qr{also holds projects/ and todos/},
        'plugins/sandbox/scripts/ProtectedPaths.pm'        => qr{`/todos`},
    );

    my $pattern = qr{todos/|/todos\b};

    my @visited;
    my @unlisted_hits;
    my %hits_by_path;

    File::Find::find({
        wanted => sub {
            my $full = $File::Find::name;
            my $base = basename($full);
            if (-d $full) {
                if ($base eq 'tests' || $base eq '.git') {
                    $File::Find::prune = 1;
                }
                return;
            }
            return unless -f $full;

            my $name = $base;
            my $is_script_ext = $name =~ /\.(?:pl|pm|sh|ps1|psm1|cmd|bat)\z/i;
            my $has_shebang = 0;
            unless ($is_script_ext) {
                if (open my $fh, '<:raw', $full) {
                    my $head = '';
                    read($fh, $head, 2);
                    close $fh;
                    $has_shebang = ($head eq '#!');
                }
            }
            return unless $is_script_ext || $has_shebang;

            (my $rel = $full) =~ s{^\Q$ROOT\E/}{};
            $rel =~ s{\\}{/}g;
            push @visited, $rel;

            open my $fh, '<:raw', $full or return;
            my $lineno = 0;
            while (my $line = <$fh>) {
                $lineno++;
                next unless $line =~ $pattern;
                $hits_by_path{$rel} ||= [];
                push @{ $hits_by_path{$rel} }, [$lineno, $line];

                my $allow_re = $ALLOW{$rel};
                unless (defined($allow_re) && $line =~ $allow_re) {
                    push @unlisted_hits, "$rel:$lineno: $line";
                }
            }
            close $fh;
        },
        no_chdir => 1,
    }, "$ROOT/plugins");

    is(scalar(@unlisted_hits), 0,
        'AC3: every todos/-path hit under plugins/ is on the spec\'s allow-list, matching its exact line regex')
        or diag(join('', @unlisted_hits));

    # AC3b -- vault-sync.pl itself has no /todos/i match on any line.
    my $vs_src = read_text("$ROOT/plugins/steward/scripts/vault-sync.pl") // '';
    unlike($vs_src, qr/todos/i, 'AC3b: vault-sync.pl contains no /todos/i match anywhere');

    # AC3c -- non-vacuity: the scan really walked vault-sync.pl, and really
    # found the expected hit in the migration tool it is meant to exempt.
    ok((grep { $_ eq 'plugins/steward/scripts/vault-sync.pl' } @visited),
        'AC3c non-vacuity: the scan visited vault-sync.pl');
    ok(exists($hits_by_path{'plugins/almanac/scripts/almanac-migrate-todos.pl'})
        && scalar(@{ $hits_by_path{'plugins/almanac/scripts/almanac-migrate-todos.pl'} }) >= 1,
        'AC3c non-vacuity: the scan found at least one hit in almanac-migrate-todos.pl');
}

done_testing();
