#!/usr/bin/env perl
# platform: host
# Oracle for blueprint hook-continuity-remake, package
# 37-promote-drops-retired-keys (scripts/promote.pl's settings merge).
# Derived ONLY from the package ledger's Scope and Done criteria
# (.ccpraxis-local-data/blueprints/hook-continuity-remake/packages/
# 37-promote-drops-retired-keys.md) and Decision 125 -- scripts/promote.pl's
# own compute_units/historical_canon_set implementation is not consulted
# while writing this file. Today's promote.pl entirely skips an only_left
# unit (`next if $rel eq 'identical' || $rel eq 'only_left';` before any
# report line or historical lookup exists for that relation), so every
# removal assertion below is expected to fail on "nothing was removed" --
# never on a fixture bug of this file's own making.
#
# DC -> block mapping (grep "DCn:" for every assertion of a criterion):
#   DC1 a key an earlier payload version set to the SAME value, later
#       dropped, is removed on apply and listed on dry-run without writing
#   DC2 the same shape, but the installed value has since changed locally --
#       kept, exactly as today
#   DC3 a key no payload version ever had -- kept, exactly as today
#   DC4 a nested key (env.X) follows the identical removal rule
#   DC5 a .backup-preferences.json keep preference for the unit wins over
#       removal
#   DC6 the backup is written before the removing write (backup bytes equal
#       the PRE-run live content, including the key that is about to be
#       dropped)
#
# Every promote.pl invocation below passes --clone/--live/--home explicitly.
# Nothing here ever touches the real ~/.claude or the real live install --
# every git operation runs against a throwaway clone/live repo pair created
# by new_fixture() below, exactly as its sibling global-config oracle does.
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
# new_fixture(): a throwaway clone repo with a real commit history for the
# payload path, and a throwaway live repo cloned from it (so the live repo's
# own git log carries the same history promote.pl reads for
# historical_canon_set), plus a throwaway fixture home. Scratch lives OUTSIDE
# this repo, under HostCaps' consolidated scratch root.
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

# ===========================================================================
# DC1: a key an earlier payload version set to the SAME value, then dropped,
# is removed on apply and listed on dry-run without writing.
# ===========================================================================
{
    my $payload_v1 = { retired => 'GONE_VALUE', other => 'x' };
    my $payload_v2 = { other => 'x' }; # retired dropped in the current payload
    my $live_settings = { retired => 'GONE_VALUE', other => 'x' }; # matches v1's value exactly

    my $f = new_fixture(clone_commits => [
        [ { 'global-config/settings.json' => canon_json($payload_v1) }, 'settings v1 (has retired)' ],
        [ { 'global-config/settings.json' => canon_json($payload_v2) }, 'settings v2 (retired dropped)' ],
    ]);
    write_bytes("$f->{home}/.claude/settings.json", canon_json($live_settings));
    my $pre_bytes = read_bytes("$f->{home}/.claude/settings.json");

    my $r = run_promote($f);
    is($r->{exit}, 0, 'DC1 (apply): exit 0') or diag($r->{out} . $r->{err});
    like($r->{out}, qr/^settings: updated \(1 changes\)/m, 'DC1 (apply): settings summary counts the removal')
        or diag($r->{out});
    like($r->{out}, qr/removed retired/, 'DC1 (apply): report line names the removed key') or diag($r->{out});

    my $bytes = read_bytes("$f->{home}/.claude/settings.json");
    my $result = decode_bytes_json($bytes);
    ok(ref($result) eq 'HASH', 'DC1 (apply): resulting settings.json parses as an object') or diag($bytes // 'undef');
    if (ref($result) eq 'HASH') {
        ok(!exists $result->{retired}, 'DC1 (apply): retired is gone from the written settings.json');
        is($result->{other}, 'x', 'DC1 (apply): the untouched sibling key survives');
    }

    # DC6: the backup precedes the removing write -- its settings.json is
    # byte-equal to the file BEFORE this run, i.e. it still has "retired".
    my @ts_dirs = glob("$f->{home}/.claude/.promotion-backups/*");
    ok(scalar(@ts_dirs) >= 1, 'DC6: a backup directory was created before the write');
    my $backup_bytes = @ts_dirs ? read_bytes("$ts_dirs[0]/settings.json") : undef;
    ok(defined $backup_bytes && $backup_bytes eq $pre_bytes,
        'DC6: the backed-up settings.json is byte-equal to the pre-run content (retired still present)')
        or diag('backup: ' . (defined $backup_bytes ? $backup_bytes : 'undef') . ' pre: ' . $pre_bytes);
}
{
    my $payload_v1 = { retired => 'GONE_VALUE', other => 'x' };
    my $payload_v2 = { other => 'x' };
    my $live_settings = { retired => 'GONE_VALUE', other => 'x' };

    my $f = new_fixture(clone_commits => [
        [ { 'global-config/settings.json' => canon_json($payload_v1) }, 'settings v1 (has retired)' ],
        [ { 'global-config/settings.json' => canon_json($payload_v2) }, 'settings v2 (retired dropped)' ],
    ]);
    write_bytes("$f->{home}/.claude/settings.json", canon_json($live_settings));
    my $pre_bytes = read_bytes("$f->{home}/.claude/settings.json");

    my $r = run_promote($f, '--dry-run');
    is($r->{exit}, 0, 'DC1 (dry-run): exit 0') or diag($r->{out} . $r->{err});
    like($r->{out}, qr/^settings: would-update \(1 changes\)/m, 'DC1 (dry-run): summary says would-update (1 changes)')
        or diag($r->{out});
    like($r->{out}, qr/removed retired/, 'DC1 (dry-run): report line names the removal that would happen')
        or diag($r->{out});

    my $post_bytes = read_bytes("$f->{home}/.claude/settings.json");
    ok(defined $post_bytes && $post_bytes eq $pre_bytes, 'DC1 (dry-run): settings.json is byte-unchanged');
    ok(!-d "$f->{home}/.claude/.promotion-backups", 'DC1 (dry-run): no backup directory was created');
}

# ===========================================================================
# DC2 / DC3: an only_left unit that would NOT match any historical payload
# value stays kept, exactly as it is today -- silently, with no report line
# and no effect on the change count. DC2 covers a key whose live value
# diverged from what the payload once had; DC3 covers a key no payload
# version ever carried at all.
# ===========================================================================
{
    my $payload_v1 = { retired_changed => 'V1', other => 'x' };
    my $payload_v2 = { other => 'x' }; # retired_changed dropped
    my $live_settings = {
        retired_changed => 'DIFFERENT', # DC2: never equalled this value in payload history
        user_local_only => 'ABC',       # DC3: never existed in any payload version
        other            => 'x',
    };

    my $f = new_fixture(clone_commits => [
        [ { 'global-config/settings.json' => canon_json($payload_v1) }, 'settings v1' ],
        [ { 'global-config/settings.json' => canon_json($payload_v2) }, 'settings v2' ],
    ]);
    write_bytes("$f->{home}/.claude/settings.json", canon_json($live_settings));

    my $r = run_promote($f);
    is($r->{exit}, 0, 'DC2/DC3: exit 0') or diag($r->{out} . $r->{err});
    like($r->{out}, qr/^settings: unchanged/m, 'DC2/DC3: settings summary reports unchanged (nothing removed)')
        or diag($r->{out});
    unlike($r->{out}, qr/retired_changed/, 'DC2: no report line mentions retired_changed at all');
    unlike($r->{out}, qr/user_local_only/, 'DC3: no report line mentions user_local_only at all');

    my $bytes = read_bytes("$f->{home}/.claude/settings.json");
    my $result = decode_bytes_json($bytes);
    ok(ref($result) eq 'HASH', 'DC2/DC3: resulting settings.json parses as an object') or diag($bytes // 'undef');
    if (ref($result) eq 'HASH') {
        is($result->{retired_changed}, 'DIFFERENT', 'DC2: the diverged-value key keeps its live value, unremoved');
        is($result->{user_local_only}, 'ABC', 'DC3: the never-in-payload key keeps its live value, unremoved');
    }
}

# ===========================================================================
# DC4: a nested key (env.X) follows the identical removal rule.
# ===========================================================================
{
    my $payload_v1 = { env => { RETIRED_ENV => 'v1val', OTHER_ENV => 'keep' } };
    my $payload_v2 = { env => { OTHER_ENV => 'keep' } }; # RETIRED_ENV dropped
    my $live_settings = { env => { RETIRED_ENV => 'v1val', OTHER_ENV => 'keep' } };

    my $f = new_fixture(clone_commits => [
        [ { 'global-config/settings.json' => canon_json($payload_v1) }, 'settings v1 (env.RETIRED_ENV present)' ],
        [ { 'global-config/settings.json' => canon_json($payload_v2) }, 'settings v2 (env.RETIRED_ENV dropped)' ],
    ]);
    write_bytes("$f->{home}/.claude/settings.json", canon_json($live_settings));

    my $r = run_promote($f);
    is($r->{exit}, 0, 'DC4: exit 0') or diag($r->{out} . $r->{err});
    like($r->{out}, qr/^settings: updated \(1 changes\)/m, 'DC4: settings summary counts the nested removal')
        or diag($r->{out});
    like($r->{out}, qr/removed env\.RETIRED_ENV/, 'DC4: report line names the nested removed key')
        or diag($r->{out});

    my $bytes = read_bytes("$f->{home}/.claude/settings.json");
    my $result = decode_bytes_json($bytes);
    ok(ref($result) eq 'HASH' && ref($result->{env}) eq 'HASH', 'DC4: resulting env unit is a hash')
        or diag($bytes // 'undef');
    if (ref($result) eq 'HASH' && ref($result->{env}) eq 'HASH') {
        ok(!exists $result->{env}{RETIRED_ENV}, 'DC4: env.RETIRED_ENV is gone from the written settings.json');
        is($result->{env}{OTHER_ENV}, 'keep', 'DC4: the sibling nested key survives untouched');
    }
}

# ===========================================================================
# DC5: a .backup-preferences.json keep preference for the unit wins over
# removal -- the same left-only vocabulary the VALID_ACTION table already
# reserves for only_left units.
# ===========================================================================
{
    my $payload_v1 = { retired => 'GONE_VALUE', other => 'x' };
    my $payload_v2 = { other => 'x' };
    my $live_settings = { retired => 'GONE_VALUE', other => 'x' };

    my $f = new_fixture(clone_commits => [
        [ { 'global-config/settings.json' => canon_json($payload_v1) }, 'settings v1' ],
        [ { 'global-config/settings.json' => canon_json($payload_v2) }, 'settings v2' ],
    ]);
    write_bytes("$f->{home}/.claude/settings.json", canon_json($live_settings));

    my $prefs = { live_vs_repo => { retired => { category => 'only_left', action => 'left-only' } } };
    write_bytes("$f->{live}/.backup-preferences.json", canon_json($prefs));

    # The ledger mandates the OUTCOME ("a keep preference ... wins") and the
    # wording for a removal report line, but not a specific report-line
    # wording for a preference-blocked only_left unit -- so this test pins
    # the observable outcome only, never an invented phrase.
    my $r = run_promote($f);
    is($r->{exit}, 0, 'DC5: exit 0') or diag($r->{out} . $r->{err});
    unlike($r->{out}, qr/removed retired/, 'DC5: the preferred key is never reported as removed');
    like($r->{out}, qr/^settings: unchanged/m, 'DC5: settings summary reports unchanged (the removal was blocked)')
        or diag($r->{out});

    my $bytes = read_bytes("$f->{home}/.claude/settings.json");
    my $result = decode_bytes_json($bytes);
    ok(ref($result) eq 'HASH', 'DC5: resulting settings.json parses as an object') or diag($bytes // 'undef');
    is($result->{retired}, 'GONE_VALUE', 'DC5: the preferred key keeps its live value, unremoved')
        if ref($result) eq 'HASH';
}

done_testing();
