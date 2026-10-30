#!/usr/bin/env perl
# platform: any
#
# ~/.claude/CLAUDE.md through the export phase, end to end with the REAL
# sync-export.pl and GlobalClaudeMd.pm (scripts/backup.pl ->
# Backup::Run::execute -> scripts/backup/Export.pm).
#
# Regression for bug report 20260922-211416-1b92 (still guarded): the live
# ~/.claude/CLAUDE.md must be paired with the payload, global-config/
# CLAUDE.md, never with the repo's own root CLAUDE.md (ccpraxis's project
# instructions, an unrelated file that shares the basename). The fixture
# carries both, so a basename-only pairing has something wrong to reach for.
#
# 2026-10-30: ~/.claude/CLAUDE.md is BUILT by promote.pl for each host from
# the live install's payload (the shared file plus CLAUDE.windows.md or
# CLAUDE.macos.md, GlobalClaudeMd.pm). So:
#   - a regular file equal to that build is in sync -- no symlink expected,
#     no question asked, on a host with a part of its own too;
#   - a hand edit cannot be exported (a line carries no record of which part
#     it belongs to): it becomes a claude_md_drift question naming the
#     lines, with no "use the live version" choice at all;
#   - the comparison is with the LIVE install's payload, never the dev
#     clone's, which may carry edits that are not promoted yet.
#
# This file is a trimmed, self-contained harness (temproot/make_machine/
# write_text/read_text from StewardTest) rather than an extension of
# backup-export.t, whose header declares it deliberately BLIND to Export.pm.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use lib "$Bin/../../scripts";
use File::Path qw(make_path);
use File::Temp qw(tempfile);
use JSON::PP;
use StewardTest qw(ok is like unlike diag done_testing temproot make_machine write_text read_text);
use GlobalClaudeMd ();

my $EXPORT_SRC    = "$Bin/../../../../scripts/backup/Export.pm";
my $BACKUP_SCRIPT = "$Bin/../../../../scripts/backup.pl";
my $SCRIPTS       = "$Bin/../../scripts";

ok(-f $EXPORT_SRC,    'scripts/backup/Export.pm exists on disk');
ok(-f $BACKUP_SCRIPT, 'scripts/backup.pl exists on disk');

# ---------------------------------------------------------------------------
# Path helpers (CLAUDE.md MSYS2 landmine: hand-translate POSIX paths before
# handing them to a NATIVE binary; never rely on ambient MSYS2_ARG_CONV_EXCL).
# ---------------------------------------------------------------------------
sub _native_path {
    my ($p) = @_;
    return $p unless defined $p;
    (my $q = $p) =~ s{\\}{/}g;
    $q =~ s{^/([A-Za-z])/}{\u$1:/};
    return $q;
}

sub _git_env {
    my ($home) = @_;
    return (
        HOME                => $home,
        USERPROFILE         => $home,
        GIT_CONFIG_GLOBAL   => "$home/.gitconfig",
        GIT_CONFIG_SYSTEM   => '/dev/null',
        GIT_TERMINAL_PROMPT => '0',
        GIT_AUTHOR_NAME     => 'Pairing Test',
        GIT_AUTHOR_EMAIL    => 'pairing-test@example.invalid',
        GIT_COMMITTER_NAME  => 'Pairing Test',
        GIT_COMMITTER_EMAIL => 'pairing-test@example.invalid',
    );
}

sub _git {
    my ($home, $dir, @args) = @_;
    my %genv = _git_env($home);
    local @ENV{ keys %genv } = values %genv;
    my @translated = map { (defined $_ && /^\//) ? _native_path($_) : $_ } @args;
    my $rc = system('git', '-C', _native_path($dir), @translated);
    die "git -C $dir @args failed: exit $rc\n" if $rc != 0;
    return 1;
}

sub _stub_wrap {
    my ($body) = @_;
    return "#!/usr/bin/env perl\nuse strict;\nuse warnings;\n" . $body;
}

# Everything the export runs after U2 is stubbed to a quiet success; the
# scenario is about U1/U2 (the real sync-export.pl and the decision).
my $STUB_HELPERS_BODY = <<'PERL';
print '{"status":"merged","live":"x","repo":"y","merge_rule":"preference-aware-live-wins-preserve-repo-only","preferences_file":null,"preferences_applied":[],"preferences_ignored":[],"skip_keys_unmatched":[]}';
exit 0;
PERL

my $GIT_STUB_PL = <<'PERL';
#!/usr/bin/env perl
use strict; use warnings;
my $rc = system('git', @ARGV);
if ($rc == -1) { print STDERR "git-stub: cannot exec git\n"; exit 127; }
exit($rc >> 8);
PERL

my $GIT_STUB_CMD = <<'CMD';
@echo off
perl "%~dp0git-stub.pl" %*
exit /b %ERRORLEVEL%
CMD

sub write_git_stub {
    my ($scratch) = @_;
    write_text("$scratch/git-stub.pl", $GIT_STUB_PL);
    write_text("$scratch/git-stub.cmd", $GIT_STUB_CMD);
    unless ($^O eq q{MSWin32} || $^O eq q{cygwin} || $^O eq q{msys}) {
        chmod 0755, "$scratch/git-stub.pl";
        return "$scratch/git-stub.pl";
    }
    return "$scratch/git-stub.cmd";
}

sub write_state_raw {
    my ($path, $data) = @_;
    write_text($path, JSON::PP->new->canonical->pretty->encode($data));
}

# setup_root -- the promote.pl topology: a dev clone with the payload
# committed (shared CLAUDE.md and both platform parts), the live install
# cloned from it carrying the REAL sync-export.pl and its modules, and the
# preflight's ready export_target seeded.
sub setup_root {
    my $scratch = temproot();
    my $home    = make_machine($scratch, 'host');
    my $clone   = "$scratch/devclone";
    my $ccpx    = "$home/.claude/ccpraxis";
    make_path($clone, "$home/.claude");

    _git($home, $clone, 'init', '-q');
    write_text("$clone/.gitignore", ".backup-preferences.json\n*.pre-merge.*\n");
    write_text("$clone/CLAUDE.md", "# ccpraxis project instructions\nunrelated to the user's global config\n");
    write_text("$clone/global-config/CLAUDE.md", "# Global Instructions\nthe real payload counterpart\n");
    write_text("$clone/global-config/CLAUDE.windows.md", "# Windows\nwindows-only rule\n");
    write_text("$clone/global-config/CLAUDE.macos.md", "# macOS\nmacos-only rule\n");
    write_text("$clone/global-config/settings.json", "{}\n");
    write_text("$clone/global-config/known_marketplaces.json", "{}\n");
    write_text("$clone/plugins/sandbox/container/settings.json", "{}\n");
    for my $name (qw(sync-export.pl json-diff.pl DevClone.pm GlobalClaudeMd.pm MachineLocalSettings.pm)) {
        write_text("$clone/plugins/steward/scripts/$name", read_text("$SCRIPTS/$name"));
    }
    write_text("$clone/plugins/steward/scripts/ccpraxis-helpers.pl", _stub_wrap($STUB_HELPERS_BODY));
    write_text("$clone/plugins/steward/scripts/filter-diff.pl",
        _stub_wrap("{ local \$/; my \$x = <STDIN>; }\nprint '{\"status\":\"identical\",\"auto_applied\":[],\"needs_decision\":{\"only_left\":{},\"only_right\":{},\"diverged\":{}},\"has_undecided\":false}';\nexit 0;\n"));
    write_text("$clone/plugins/steward/scripts/sensitive-check.pl", _stub_wrap("print \"No sensitive data found.\\n\"; exit 0;\n"));
    _git($home, $clone, 'add', '-A');
    _git($home, $clone, 'commit', '-q', '-m', 'initial fixture commit');

    my %genv = _git_env($home);
    {
        local @ENV{ keys %genv } = values %genv;
        system('git', 'clone', '-q', _native_path($clone), _native_path($ccpx)) == 0 or die "clone failed\n";
    }
    write_text("$home/.claude/settings.json", "{}\n");

    my $phase_dir = "$scratch/phases";
    make_path($phase_dir);
    write_text("$phase_dir/Export.pm", read_text($EXPORT_SRC));
    my $git_stub = write_git_stub($scratch);

    my $state_path = "$scratch/state/run.json";
    my $now = time;
    write_state_raw($state_path, {
        format => 1, run_id => 'abcdefabcdef0123', started_at => $now, updated_at => $now, status => 'running',
        phase_order => ['export'], phase_index => 0,
        phases => {
            export    => { status => 'pending', started_at => undef, completed_at => undef, error => undef, items => {}, scratch => {} },
            preflight => { status => 'complete', started_at => $now, completed_at => $now, error => undef, scratch => {}, items => {
                export_target    => { at => $now, data => { ready => 1, live_root => $ccpx, dev_clone => $clone } },
                settings_outcome => { at => $now, data => { skip_keys => [], preferences_saved => [], answers => {} } },
            } },
        },
        token_seq => 0, consumed_seq => 0, pending => undef, answers => {}, notes => [],
    });

    return {
        scratch    => $scratch,
        home       => $home,
        ccpx       => $ccpx,
        clone      => $clone,
        phase_dir  => $phase_dir,
        git_stub   => $git_stub,
        state_path => $state_path,
    };
}

sub _spawn {
    my ($env_overrides, @args) = @_;
    my %env = %$env_overrides;
    local @ENV{ keys %env } = values %env;

    my ($efh, $ename) = tempfile(UNLINK => 1);
    close $efh;
    open(my $saved_stderr, '>&', \*STDERR) or die "cannot dup STDERR: $!";
    open(STDERR, '>', $ename) or die "cannot redirect STDERR to $ename: $!";

    my $out = '';
    my $exit = -1;
    my $pid = open(my $fh, '-|', $^X, $BACKUP_SCRIPT, @args);
    if ($pid) {
        local $/;
        $out = <$fh>;
        $out = '' unless defined $out;
        close $fh;
        $exit = $? >> 8;
    }

    open(STDERR, '>&', $saved_stderr) or warn "cannot restore STDERR: $!";
    close $saved_stderr;

    my $err = read_text($ename);
    $err = '' unless defined $err;
    unlink $ename;

    my $json = eval { decode_json($out) };
    return { out => $out, err => $err, exit => $exit, json => $json };
}

sub run_backup {
    my ($r, $extra_env, @args) = @_;
    my %env = (
        _git_env($r->{home}),
        BACKUP_RUN_STATE => $r->{state_path},
        BACKUP_PHASE_DIR => $r->{phase_dir},
        BACKUP_GIT_BIN   => $r->{git_stub},
        %{ $extra_env // {} },
    );
    return _spawn(\%env, 'run', @args);
}

sub decisions_of      { my ($resp) = @_; return @{ $resp->{json}{decisions} // [] }; }
sub decisions_of_kind { my ($resp, $kind) = @_; return grep { ($_->{kind} // '') eq $kind } decisions_of($resp); }
sub state_of          { my ($r) = @_; my $raw = read_text($r->{state_path}); return defined $raw ? eval { decode_json($raw) } : undef; }

# ---------------------------------------------------------------------------
# A -- in sync: ~/.claude/CLAUDE.md is exactly the build of the live payload
# for this host (shared file plus this host's part, where it has one).
# ---------------------------------------------------------------------------
{
    my $r = setup_root();
    my $build = GlobalClaudeMd::render_from_dir($r->{ccpx});
    write_text("$r->{home}/.claude/CLAUDE.md", $build);
    if (defined GlobalClaudeMd::host_part_relpath()) {
        like($build, qr/-only rule\n\z/, '(setup) A: this host has a part, and the build carries it');
    }
    my $resp = run_backup($r, {});
    ok(!(decisions_of_kind($resp, 'claude_md_drift')), 'A: an in-sync CLAUDE.md asks nothing')
        or diag($resp->{out} . $resp->{err});
    ok(!(decisions_of_kind($resp, 'file_conflict')), 'A: ...and is not a file conflict either');
    my $state = state_of($r);
    my ($item) = grep { ($_->{file} // '') eq 'CLAUDE.md' } @{ ($state // {})->{phases}{export}{items}{file_status}{data} // [] };
    is(($item // {})->{status}, 'identical', 'A: sync-export reports it identical: a regular file, no symlink expected');
    is(($item // {})->{repo_file}, 'global-config/CLAUDE.md', 'A: paired with global-config/CLAUDE.md, never the repo-root CLAUDE.md');
}

# ---------------------------------------------------------------------------
# B -- a hand edit: reported with its lines, never exportable.
# ---------------------------------------------------------------------------
{
    my $r = setup_root();
    my $build = GlobalClaudeMd::render_from_dir($r->{ccpx});
    (my $edited = $build) =~ s/the real payload counterpart\n/the real payload counterpart\na rule typed into the live file\n/;
    write_text("$r->{home}/.claude/CLAUDE.md", $edited);
    # A payload edit sitting in the dev clone, not promoted: the comparison
    # must not use it.
    write_text("$r->{clone}/global-config/CLAUDE.md", "# Global Instructions\nthe real payload counterpart\na rule typed into the live file\n");

    my $resp = run_backup($r, {});
    is($resp->{exit}, 10, 'B: a hand-edited CLAUDE.md pauses the run') or diag($resp->{out} . $resp->{err});
    my @cm = decisions_of_kind($resp, 'claude_md_drift');
    is(scalar(@cm), 1, 'B: exactly one claude_md_drift decision');
    ok(!(decisions_of_kind($resp, 'file_conflict')), 'B: no file_conflict (CLAUDE.md is never copied into the repo)');
    my $d = $cm[0] // {};
    my %cid = map { $_->{id} => 1 } @{ $d->{choices} // [] };
    ok(!$cid{use_live}, 'B: there is no use_live choice');
    ok($cid{rerender} && $cid{leave}, 'B: the choices are rerender and leave');
    like(($d->{detail} // ''), qr/L3: a rule typed into the live file/, 'B: the detail names the hand-edited line and its number');
    like(($d->{detail} // ''), qr/dev clone's global-config\/CLAUDE\.md/, 'B: ...and says it must be folded into the dev clone');
    unlike(($d->{detail} // ''), qr/ccpraxis project instructions/, 'B: the repo-root CLAUDE.md is never what it is compared with');
    is(read_text("$r->{clone}/global-config/CLAUDE.md"),
        "# Global Instructions\nthe real payload counterpart\na rule typed into the live file\n",
        'B: nothing was written into the dev clone\'s CLAUDE.md');
}

done_testing();
