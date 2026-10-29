#!/usr/bin/env perl
# platform: any
#
# Regression for bug report 20260922-211416-1b92: the export phase's
# file_conflict decision must pair the live copy of a repo-owned file with
# ITS OWN repo counterpart -- never with an unrelated file that merely
# shares a basename at a different root.
#
# CLAUDE.md is the concrete case that exposed this: the live symlinked item
# is ~/.claude/CLAUDE.md, and its real repo counterpart is
# global-config/CLAUDE.md -- NOT the repo's own root CLAUDE.md (ccpraxis's
# project-instructions file, a completely unrelated document). Before the
# fix, scripts/backup/Export.pm's _do_file_conflicts reconstructed the repo
# side purely as "$root/$file" using sync-export.pl's live-relative 'file'
# field, so it silently paired live's CLAUDE.md against the repo ROOT
# CLAUDE.md instead. This scenario drives the real dispatcher end to end
# (scripts/backup.pl -> Backup::Run::execute -> the real
# scripts/backup/Export.pm), stubbing only sync-export.pl's own output (via
# STUB_SYNC_JSON) so no other wrapped script needs to run before the pause.
#
# This file is a trimmed, self-contained harness (temproot/make_machine/
# write_text/read_text from StewardTest; the rest copied down from
# t/backup-export.t's own scaffold) rather than an extension of that file,
# because that file's own header declares itself deliberately BLIND to
# Export.pm's implementation -- a constraint this regression test does not
# want to inherit, since it exists precisely because it read Export.pm.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Path qw(make_path);
use File::Temp qw(tempfile);
use JSON::PP;
use StewardTest qw(ok is like unlike diag done_testing temproot make_machine write_text read_text);

my $EXPORT_SRC    = "$Bin/../../../../scripts/backup/Export.pm";
my $BACKUP_SCRIPT = "$Bin/../../../../scripts/backup.pl";

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

# Only sync-export.pl needs stubbing: U1 (file_status) is the only wrapped
# script Export.pm runs before U2 (file_conflicts) produces the pause this
# scenario is about.
sub _stub_wrap {
    my ($body) = @_;
    return "#!/usr/bin/env perl\nuse strict;\nuse warnings;\n" . $body;
}

my $STUB_SYNC_BODY = <<'PERL';
my $json = defined $ENV{STUB_SYNC_JSON} ? $ENV{STUB_SYNC_JSON} : '[]';
print $json;
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
    # Off Windows a .cmd file is not executable at all (the shell reads
    # "@echo off" as a command and every git verb fails), so the wrapper is
    # the perl script itself, run through its shebang.
    unless ($^O eq q{MSWin32} || $^O eq q{cygwin} || $^O eq q{msys}) {
        chmod 0755, "$scratch/git-stub.pl";
        return "$scratch/git-stub.pl";
    }
    return "$scratch/git-stub.cmd";
}

sub copy_export_into {
    my ($phase_dir) = @_;
    make_path($phase_dir);
    write_text("$phase_dir/Export.pm", read_text($EXPORT_SRC));
}

# setup_root -- one throwaway "machine": a temp HOME containing
# <home>/.claude/ccpraxis as a real git repo. The fixture deliberately
# creates BOTH a repo-root CLAUDE.md (ccpraxis's own unrelated
# project-instructions file) and a global-config/CLAUDE.md (the file that
# actually pairs with the live copy), so a basename-only pairing bug has
# something wrong to reach for.
sub setup_root {
    my $scratch = temproot();
    my $home    = make_machine($scratch, 'host');
    my $ccpx    = "$home/.claude/ccpraxis";
    make_path($ccpx);

    _git($home, $ccpx, 'init', '-q');

    write_text("$ccpx/CLAUDE.md", "# ccpraxis project instructions\nunrelated to the user's global config\n");
    write_text("$ccpx/global-config/CLAUDE.md", "# Global Instructions\nthe real repo counterpart\n");
    write_text("$ccpx/global-config/settings.json", "{}\n");
    write_text("$ccpx/global-config/known_marketplaces.json", "{}\n");
    write_text("$home/.claude/settings.json", "{}\n");
    write_text("$ccpx/plugins/sandbox/container/settings.json", "{}\n");
    write_text("$home/.claude/CLAUDE.md", "# Global Instructions\nlive copy, edited by the user\n");

    write_text("$ccpx/plugins/steward/scripts/sync-export.pl",      _stub_wrap($STUB_SYNC_BODY));
    write_text("$ccpx/plugins/steward/scripts/ccpraxis-helpers.pl", _stub_wrap("exit 0;\n"));
    write_text("$ccpx/plugins/steward/scripts/json-diff.pl",        _stub_wrap("exit 0;\n"));
    write_text("$ccpx/plugins/steward/scripts/filter-diff.pl",      _stub_wrap("exit 0;\n"));
    write_text("$ccpx/plugins/steward/scripts/save-preference.pl",  _stub_wrap("exit 0;\n"));
    write_text("$ccpx/plugins/steward/scripts/sensitive-check.pl",  _stub_wrap("print \"No sensitive data found.\\n\"; exit 0;\n"));

    _git($home, $ccpx, 'add', '-A');
    _git($home, $ccpx, 'commit', '-q', '-m', 'initial fixture commit');

    my $phase_dir = "$scratch/phases";
    copy_export_into($phase_dir);
    my $git_stub = write_git_stub($scratch);

    return {
        scratch    => $scratch,
        home       => $home,
        ccpx       => $ccpx,
        phase_dir  => $phase_dir,
        git_stub   => $git_stub,
        state_path => "$scratch/state/run.json",
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

# ---------------------------------------------------------------------------
# The scenario: sync-export.pl reports CLAUDE.md as not_linked (mirroring
# its real check_symlink('CLAUDE.md') output), carrying the repo_file field
# that names the actual repo-relative counterpart -- global-config/CLAUDE.md,
# never the repo root.
# ---------------------------------------------------------------------------
{
    my $r = setup_root();
    my $sync_json = encode_json([
        { file => 'CLAUDE.md', repo_file => 'global-config/CLAUDE.md', status => 'not_linked', note => 'copy differs from repo' },
    ]);
    my $resp = run_backup($r, { STUB_SYNC_JSON => $sync_json });
    is($resp->{exit}, 10, 'a not_linked CLAUDE.md pauses the run for a file_conflict decision')
        or diag($resp->{out} . $resp->{err});

    my @fc = decisions_of_kind($resp, 'file_conflict');
    is(scalar(@fc), 1, 'exactly one file_conflict decision is produced') or diag($resp->{out});
    my $d = $fc[0];
    if (defined $d) {
        like(($d->{data}{repo_path} // ''), qr/global-config[\/\\]CLAUDE\.md$/,
            'the decision pairs live CLAUDE.md with repo global-config/CLAUDE.md, not the repo root');
        is($d->{data}{repo_text}, "# Global Instructions\nthe real repo counterpart\n",
            'repo_text is global-config/CLAUDE.md\'s content, not the repo root CLAUDE.md\'s content');
        is($d->{data}{live_text}, "# Global Instructions\nlive copy, edited by the user\n",
            'live_text is the live ~/.claude/CLAUDE.md content');
    } else {
        ok(0, "$_") for (
            'the decision pairs live CLAUDE.md with repo global-config/CLAUDE.md, not the repo root',
            'repo_text is global-config/CLAUDE.md\'s content, not the repo root CLAUDE.md\'s content',
            'live_text is the live ~/.claude/CLAUDE.md content',
        );
    }
}

done_testing();
