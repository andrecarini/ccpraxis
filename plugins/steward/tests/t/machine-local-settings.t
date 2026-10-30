#!/usr/bin/env perl
# platform: any
# Machine-local settings values (plugins/steward/scripts/MachineLocalSettings.pm)
# and the three places that honour them: scripts/promote.pl (payload -> live),
# ccpraxis-helpers.pl settings-export-merge (live -> payload) and json-diff.pl
# --host-live (live vs payload, as the backup preflight compares them).
#
# WHY. global-config/settings.json is shared by the Windows host and a Mac. It
# used to carry the Windows host's absolute ccpraxis-local marketplace path
# (C:/Users/André/.claude/ccpraxis/plugins), so a first Mac promote installed a
# path that cannot resolve and a Mac backup would have exported the Mac path
# back, breaking Windows. It also carried env.CLAUDE_CODE_USE_POWERSHELL_TOOL,
# which Claude Code checks for truthiness on every platform: promoting the
# Windows "1" onto a Mac offers a PowerShell tool with no pwsh behind it, and a
# Mac backup must not delete it from the Windows host's payload either.
#
# Windows behaviour is pinned in-process (local $^O = 'msys'): the expanded
# path must be byte-identical to the literal the payload used to carry, and
# nothing is platform-foreign there. Everything that spawns a script runs on
# THIS host and asserts the host's own rule.
#
# HERMETIC: every HOME, clone and live install below is a throwaway tempdir;
# promote.pl always gets --clone/--live/--home explicitly.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use JSON::PP;
use Encode ();

binmode Test::More->builder->output,         q{:encoding(UTF-8)};
binmode Test::More->builder->failure_output, q{:encoding(UTF-8)};

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
my $ROOT    = "$Bin/../../../..";
my $PROMOTE = "$ROOT/scripts/promote.pl";
my $HELPERS = "$S/ccpraxis-helpers.pl";
my $JSONDIFF = "$S/json-diff.pl";

use lib "$Bin/../../scripts";
require_ok('MachineLocalSettings') or BAIL_OUT('MachineLocalSettings.pm does not load');

my $TOKEN   = MachineLocalSettings::LIVE_ROOT_TOKEN();
my $PS      = 'CLAUDE_CODE_USE_POWERSHELL_TOOL';
my $ANDRE_B = "Andr\xc3\xa9";                                # UTF-8 bytes, as MSYS hands HOME over
my $ANDRE_C = Encode::decode('UTF-8', $ANDRE_B);            # characters, as decode_json yields
my $IS_WIN  = MachineLocalSettings::is_windows_host();

is($TOKEN, '${CCPRAXIS_LIVE}', 'the live-root token is ${CCPRAXIS_LIVE}');

sub mp_settings {
    my ($path, %extra) = @_;
    return {
        extraKnownMarketplaces => {
            'ccpraxis-local' => { source => { source => 'directory', path => $path } },
            'notion-plugin-marketplace' => { source => { source => 'github', repo => 'makenotion/claude-code-notion-plugin' } },
        },
        %extra,
    };
}
sub mp_path { return $_[0]{extraKnownMarketplaces}{'ccpraxis-local'}{source}{path}; }

# ---------------------------------------------------------------------------
# 1. The payload itself carries the token, not a machine's path.
# ---------------------------------------------------------------------------
{
    open my $fh, '<:raw', "$ROOT/global-config/settings.json" or die $!;
    my $payload = decode_json(do { local $/; <$fh> });
    is(mp_path($payload), "$TOKEN/plugins",
        'payload: extraKnownMarketplaces.ccpraxis-local.source.path is ${CCPRAXIS_LIVE}/plugins');
    is($payload->{env}{$PS}, '1', 'payload: the Windows-only PowerShell switch is still shipped for Windows hosts');
}

# ---------------------------------------------------------------------------
# 2. Windows, in-process: expansion reproduces the old literal byte for byte,
#    collapse folds every spelling of it back, nothing is platform-foreign.
# ---------------------------------------------------------------------------
{
    local $^O = 'msys';
    my $old_literal = "C:/Users/$ANDRE_C/.claude/ccpraxis/plugins";
    my $s = mp_settings("$TOKEN/plugins");
    is(MachineLocalSettings::expand_live_root($s, "/c/Users/$ANDRE_B/.claude/ccpraxis"), 1, 'windows: one value expanded');
    is(mp_path($s), $old_literal, 'windows: /c/Users/André/... expands to exactly the C:/ literal the payload used to carry');
    is(JSON::PP->new->utf8->canonical->encode($s->{extraKnownMarketplaces}{'ccpraxis-local'}),
       JSON::PP->new->utf8->canonical->encode({ source => { source => 'directory', path => $old_literal } }),
       'windows: the expanded entry encodes to the same bytes as before');

    my $s2 = mp_settings("$TOKEN/plugins");
    MachineLocalSettings::expand_live_root($s2, "C:\\Users\\$ANDRE_B\\.claude\\ccpraxis");
    is(mp_path($s2), $old_literal, 'windows: a backslash USERPROFILE form expands to the same literal');

    for my $spelling ($old_literal, "c:/users/\L$ANDRE_C\E/.claude/ccpraxis/plugins", "C:\\Users\\$ANDRE_C\\.claude\\ccpraxis\\plugins") {
        my $l = mp_settings($spelling);
        is(MachineLocalSettings::collapse_live_root($l, "/c/Users/$ANDRE_B/.claude/ccpraxis"), 1, "windows: collapse matches '$spelling'");
        is(mp_path($l), "$TOKEN/plugins", 'windows: ...and folds it back to the token');
    }
    my $other = mp_settings('D:/elsewhere/plugins');
    is(MachineLocalSettings::collapse_live_root($other, "/c/Users/$ANDRE_B/.claude/ccpraxis"), 0,
        'windows: a path outside the live root is a genuine value and is NOT collapsed');
    is_deeply([MachineLocalSettings::foreign_platform_keys()], [], 'windows: no platform-only key is foreign');
    my $env = { env => { $PS => '1', OTHER => 'x' } };
    is_deeply(MachineLocalSettings::strip_foreign_platform_keys($env), {}, 'windows: strip removes nothing');
    is($env->{env}{$PS}, '1', 'windows: the PowerShell switch survives');
}

# ---------------------------------------------------------------------------
# 3. macOS / Linux, in-process.
# ---------------------------------------------------------------------------
for my $os (qw(darwin linux)) {
    local $^O = $os;
    my $s = mp_settings("$TOKEN/plugins");
    MachineLocalSettings::expand_live_root($s, '/Users/someone/.claude/ccpraxis');
    is(mp_path($s), '/Users/someone/.claude/ccpraxis/plugins', "$os: the token expands to this machine's live root");
    my $l = mp_settings('/Users/someone/.claude/ccpraxis/plugins');
    MachineLocalSettings::collapse_live_root($l, '/Users/someone/.claude/ccpraxis');
    is(mp_path($l), "$TOKEN/plugins", "$os: this machine's own path folds back to the token");
    my $win = mp_settings("C:/Users/$ANDRE_C/.claude/ccpraxis/plugins");
    is(MachineLocalSettings::collapse_live_root($win, '/Users/someone/.claude/ccpraxis'), 0,
        "$os: another machine's literal path is left alone");
    is_deeply([MachineLocalSettings::foreign_platform_keys()], ["env.$PS"], "$os: the PowerShell switch is foreign");
    my $env = { env => { $PS => '0', OTHER => 'x' } };
    my $saved = MachineLocalSettings::strip_foreign_platform_keys($env);
    is_deeply($saved, { "env.$PS" => '0' }, "$os: strip hands back what it removed");
    ok(!exists $env->{env}{$PS} && $env->{env}{OTHER} eq 'x', "$os: strip removes only the foreign key");
    my $merged = { env => { $PS => '1', OTHER => 'y' } };
    MachineLocalSettings::restore_foreign_platform_keys($merged, $saved);
    is($merged->{env}{$PS}, '0', "$os: restore puts the saved value back over whatever the merge did");
    MachineLocalSettings::restore_foreign_platform_keys($merged, {});
    ok(!exists $merged->{env}{$PS}, "$os: restore with nothing saved removes the key");
}
# ---------------------------------------------------------------------------
# 3b. Platform-only hook registrations (the Windows-only guards).
# ---------------------------------------------------------------------------
{
    my $nul  = { matcher => 'Bash', hooks => [ { type => 'command', command => 'f="$HOME/.claude/ccpraxis/scripts/hooks/block-nul-redirect.pl"; [ -f "$f" ] || exit 0; exec perl "$f"' } ] };
    my $ps1  = { matcher => 'Edit|Write', hooks => [ { type => 'command', command => 'exec perl "C:\\Users\\x\\.claude\\ccpraxis\\scripts\\hooks\\block-nonascii-ps1.pl"' } ] };
    my $mine = { matcher => 'Bash', hooks => [ { type => 'command', command => 'exec perl /x/my-own-guard.pl' } ] };
    my $mixed = { matcher => 'Bash', hooks => [ $nul->{hooks}[0], $mine->{hooks}[0] ] };
    my $reap = { hooks => [ { type => 'command', command => 'exec perl "$HOME/.claude/ccpraxis/scripts/hooks/reap-orphans-hook.pl"' } ] };
    my $mk = sub { return { hooks => { PreToolUse => [ map { +{ %$_ } } @_ ], SessionStart => [ { %$reap } ] } } };
    my $canon = sub { JSON::PP->new->canonical->encode($_[0]) };

    {
        local $^O = 'msys';
        my $s = $mk->($nul, $mine, $ps1);
        my $before = $canon->($s);
        is_deeply(MachineLocalSettings::strip_foreign_platform_keys($s), {}, 'windows: the Windows-only guards are not foreign');
        is($canon->($s), $before, 'windows: strip leaves every hook in place');
    }
    for my $os (qw(darwin linux)) {
        local $^O = $os;
        my $s = $mk->($nul, $mine, $ps1);
        my $orig = $canon->($s);
        my $saved = MachineLocalSettings::strip_foreign_platform_keys($s);
        is(scalar(@{ $s->{hooks}{PreToolUse} }), 1, "$os: both Windows-only guard groups are stripped");
        is($s->{hooks}{PreToolUse}[0]{hooks}[0]{command}, 'exec perl /x/my-own-guard.pl', "$os: an unrelated hook group stays");
        is(scalar(@{ $s->{hooks}{SessionStart} }), 1, "$os: other events are untouched");
        MachineLocalSettings::restore_foreign_platform_keys($s, $saved);
        is($canon->($s), $orig, "$os: strip then restore is the identity (positions kept)");

        my $only = $mk->($nul, $ps1);
        my $saved2 = MachineLocalSettings::strip_foreign_platform_keys($only);
        ok(!exists $only->{hooks}{PreToolUse}, "$os: an event left with no groups is removed");
        my $merged = { hooks => { SessionStart => [ { %$reap } ] } };
        MachineLocalSettings::restore_foreign_platform_keys($merged, $saved2);
        is(scalar(@{ $merged->{hooks}{PreToolUse} }), 2, "$os: restore recreates the event with the saved groups");

        my $live = $mk->($nul, $mine);
        MachineLocalSettings::restore_foreign_platform_keys($live, {});
        is(scalar(@{ $live->{hooks}{PreToolUse} }), 1, "$os: restore with nothing saved drops a foreign group the merge left");

        my $m = { hooks => { PreToolUse => [ { %$mixed } ] } };
        is_deeply(MachineLocalSettings::strip_foreign_platform_keys($m), {}, "$os: a group mixing a guard with another hook is left alone");
    }
}

{
    local $^O = 'darwin';
    my $tok_only = { extraKnownMarketplaces => { x => { source => { source => 'github', path => "$TOKEN/plugins" } } } };
    MachineLocalSettings::expand_live_root($tok_only, '/Users/someone/.claude/ccpraxis');
    is($tok_only->{extraKnownMarketplaces}{x}{source}{path}, "$TOKEN/plugins",
        'only directory-source marketplace paths are expanded');
}

# ---------------------------------------------------------------------------
# helpers for the spawned scenarios
# ---------------------------------------------------------------------------
sub write_file {
    my ($path, $content) = @_;
    make_path(dirname($path));
    open my $fh, '>:raw', $path or die "write $path: $!";
    print {$fh} $content;
    close $fh;
}
sub read_file {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}
sub write_json_file { write_file($_[0], JSON::PP->new->utf8->canonical->pretty->encode($_[1])); }
sub read_json_file  { my $c = read_file($_[0]); return defined $c ? decode_json($c) : undef; }

sub run_cmd {
    my ($env, @cmd) = @_;
    local @ENV{ keys %$env } = values %$env;
    my $tmp = File::Temp->new;
    my $pid = open(my $fh, '-|') // die "fork: $!";
    if (!$pid) {
        open(STDERR, '>', $tmp->filename) or die;
        exec(@cmd) or die "exec $cmd[0]: $!";
    }
    local $/;
    my $out = <$fh> // '';
    close $fh;
    my $rc = $? >> 8;
    return ($rc, $out, read_file($tmp->filename) // '');
}

my %GITENV = (
    GIT_CONFIG_NOSYSTEM => '1',
    GIT_TERMINAL_PROMPT => '0',
    GIT_AUTHOR_NAME     => 'MLS Test', GIT_AUTHOR_EMAIL    => 'mls@example.invalid',
    GIT_COMMITTER_NAME  => 'MLS Test', GIT_COMMITTER_EMAIL => 'mls@example.invalid',
);
sub git {
    my ($dir, @args) = @_;
    my ($rc, $out, $err) = run_cmd(\%GITENV, 'git', '-c', 'core.autocrlf=false', '-C', $dir, @args);
    die "git @args in $dir failed: $err" if $rc;
    return $out;
}

my $NUL_GROUP  = { matcher => 'Bash', hooks => [ { type => 'command', command => 'f="$HOME/.claude/ccpraxis/scripts/hooks/block-nul-redirect.pl"; [ -f "$f" ] || exit 0; exec perl "$f"' } ] };
my $REAP_GROUP = { matcher => '', hooks => [ { type => 'command', command => 'f="$HOME/.claude/ccpraxis/scripts/hooks/reap-orphans-hook.pl"; [ -f "$f" ] || exit 0; exec perl "$f"' } ] };
my $PAYLOAD_V2 = mp_settings("$TOKEN/plugins", env => { $PS => '1', KEEP => '1' }, theme => 'dark',
    hooks => { PreToolUse => [ $NUL_GROUP ], SessionStart => [ $REAP_GROUP ] });

# A clone whose main carries an OLD payload (the Windows literal) and then the
# current one (the token), cloned --no-hardlinks into <home>/.claude/ccpraxis.
sub new_promote_fixture {
    my (%o) = @_;
    my $root = tempdir(CLEANUP => 1);
    $GITENV{GIT_CONFIG_GLOBAL} = "$root/empty.gitconfig";
    write_file($GITENV{GIT_CONFIG_GLOBAL}, '');
    my $clone = "$root/clone";
    make_path($clone);
    git($clone, 'init', '-q');
    git($clone, 'symbolic-ref', 'HEAD', 'refs/heads/main');
    write_json_file("$clone/global-config/settings.json",
        mp_settings("C:/Users/$ANDRE_C/.claude/ccpraxis/plugins", env => { $PS => '1', KEEP => '1' }, theme => 'dark'));
    git($clone, 'add', '-A');
    git($clone, 'commit', '-q', '-m', 'old payload: literal Windows path');
    write_json_file("$clone/global-config/settings.json", $PAYLOAD_V2);
    git($clone, 'add', '-A');
    git($clone, 'commit', '-q', '-m', 'payload: ${CCPRAXIS_LIVE}');
    my $home = "$root/home";
    make_path("$home/.claude");
    my $live = "$home/.claude/ccpraxis";
    my ($rc, undef, $err) = run_cmd(\%GITENV, 'git', 'clone', '-q', '--no-hardlinks', $clone, $live);
    die "clone: $err" if $rc;
    write_json_file("$home/.claude/settings.json", $o{live_settings} // {});
    return { root => $root, clone => $clone, home => $home, live => $live };
}
sub promote {
    my ($f, @extra) = @_;
    return run_cmd(\%GITENV, $^X, $PROMOTE, '--clone', $f->{clone}, '--live', $f->{live}, '--home', $f->{home}, @extra);
}

# ---------------------------------------------------------------------------
# 4. promote.pl on THIS host.
# ---------------------------------------------------------------------------
SKIP: {
    skip 'git is not available', 1 unless (run_cmd({}, 'git', '--version'))[0] == 0;

    # 4a. first promote into a fresh live settings.json
    my $f = new_promote_fixture(live_settings => { theme => 'dark' });
    my ($expect_root) = MachineLocalSettings::live_root_spellings($f->{live});
    my ($rc, $out, $err) = promote($f);
    is($rc, 0, 'promote: first run exits 0') or diag("$out\n$err");
    my $live = read_json_file("$f->{home}/.claude/settings.json");
    is(mp_path($live), "$expect_root/plugins", 'promote: the marketplace path is this live install\'s own plugins dir');
    unlike(read_file("$f->{home}/.claude/settings.json"), qr/CCPRAXIS_LIVE/, 'promote: the token never reaches the live file');
    if ($IS_WIN) {
        is($live->{env}{$PS}, '1', 'promote (windows host): the PowerShell switch is added');
    } else {
        ok(!exists $live->{env}{$PS}, 'promote (non-windows host): the PowerShell switch is NOT added');
    }
    is($live->{env}{KEEP}, '1', 'promote: the rest of env arrives normally');
    if ($IS_WIN) {
        is(scalar(@{ $live->{hooks}{PreToolUse} // [] }), 1, 'promote (windows host): the Windows-only NUL guard is registered');
    } else {
        ok(!exists $live->{hooks}{PreToolUse}, 'promote (non-windows host): the Windows-only NUL guard is NOT registered');
    }
    is(scalar(@{ $live->{hooks}{SessionStart} // [] }), 1, 'promote: a hook for every host arrives normally');

    # 4b. second promote is a no-op
    my $before = read_file("$f->{home}/.claude/settings.json");
    ($rc, $out, $err) = promote($f);
    is($rc, 0, 'promote: second run exits 0') or diag("$out\n$err");
    like($out, qr/^merge: up-to-date$/m, 'promote: second run has nothing to merge');
    like($out, qr/^settings: unchanged$/m, 'promote: second run leaves settings unchanged');
    is(read_file("$f->{home}/.claude/settings.json"), $before, 'promote: second run rewrites nothing');

    # 4c. a live value equal to an OLD payload value (the Windows literal) is
    #     updated like any other value the payload once had.
    my $g = new_promote_fixture(live_settings => mp_settings("C:/Users/$ANDRE_C/.claude/ccpraxis/plugins"));
    ($rc, $out, $err) = promote($g);
    is($rc, 0, 'promote: run over a stale literal exits 0') or diag("$out\n$err");
    my ($g_root) = MachineLocalSettings::live_root_spellings($g->{live});
    my $gl = read_json_file("$g->{home}/.claude/settings.json");
    if ($IS_WIN) {
        pass('promote (windows host): the old literal is already this host\'s path');
    } else {
        is(mp_path($gl), "$g_root/plugins", 'promote (non-windows host): the old Windows literal is replaced by this machine\'s path');
    }

    # 4d. a foreign platform-only key in live is never touched by promote.
    unless ($IS_WIN) {
        for my $v ('0', '1') {
            my $h = new_promote_fixture(live_settings => { env => { $PS => $v } });
            ($rc, $out, $err) = promote($h);
            is($rc, 0, "promote: live $PS=$v exits 0") or diag("$out\n$err");
            is(read_json_file("$h->{home}/.claude/settings.json")->{env}{$PS}, $v,
                "promote (non-windows host): a live $PS=$v is left exactly as it was");
        }
    }

    # 4e. dry-run agrees with apply.
    my $d = new_promote_fixture(live_settings => { theme => 'dark' });
    ($rc, $out, $err) = promote($d, '--dry-run');
    is($rc, 0, 'promote --dry-run exits 0') or diag("$out\n$err");
    like($out, qr/^\s+added extraKnownMarketplaces\b/m, 'promote --dry-run: reports the marketplace entry it would add');
    unlike($out, qr/added env\.\Q$PS\E/, 'promote --dry-run: never proposes a foreign platform-only key') unless $IS_WIN;
}

# ---------------------------------------------------------------------------
# 5. settings-export-merge on THIS host: this machine's path goes back as the
#    token; a foreign platform-only key in the payload is kept exactly.
# ---------------------------------------------------------------------------
{
    my $home = tempdir(CLEANUP => 1);
    my $live_root = "$home/.claude/ccpraxis";
    make_path("$live_root/global-config");
    my ($root_spelling) = MachineLocalSettings::live_root_spellings($live_root);
    write_json_file("$home/.claude/settings.json",
        mp_settings("$root_spelling/plugins", env => { KEEP => '2', ($IS_WIN ? ($PS => '1') : ($PS => '0')) }));
    write_json_file("$live_root/global-config/settings.json", $PAYLOAD_V2);
    my ($rc, $out, $err) = run_cmd({ HOME => $home, USERPROFILE => $home }, $^X, $HELPERS, 'settings-export-merge');
    is($rc, 0, 'export-merge: exits 0') or diag("$out\n$err");
    my $repo = read_json_file("$live_root/global-config/settings.json");
    is(mp_path($repo), "$TOKEN/plugins", 'export-merge: this machine\'s live path is exported as the token, never literally');
    is($repo->{env}{KEEP}, '2', 'export-merge: an ordinary live value still wins');
    is($repo->{env}{$PS}, '1', $IS_WIN
        ? 'export-merge (windows host): the PowerShell switch syncs normally'
        : 'export-merge (non-windows host): a live "0" does not overwrite the Windows-only "1"');

    # live WITHOUT the foreign key must not delete it from the payload either.
    unless ($IS_WIN) {
        write_json_file("$home/.claude/settings.json", mp_settings("$root_spelling/plugins", env => { KEEP => '2' }));
        ($rc, $out, $err) = run_cmd({ HOME => $home, USERPROFILE => $home }, $^X, $HELPERS, 'settings-export-merge');
        is($rc, 0, 'export-merge: second run exits 0') or diag("$out\n$err");
        is(read_json_file("$live_root/global-config/settings.json")->{env}{$PS}, '1',
            'export-merge (non-windows host): a live file without the key never deletes it from the payload');
    }
}

# ---------------------------------------------------------------------------
# 6. json-diff.pl --host-live: an in-sync machine shows no difference.
# ---------------------------------------------------------------------------
{
    my $dir = tempdir(CLEANUP => 1);
    my $live_root = "$dir/live";
    make_path($live_root);
    my ($root_spelling) = MachineLocalSettings::live_root_spellings($live_root);
    my %env = (KEEP => '1', ($IS_WIN ? ($PS => '1') : ()));
    # In sync = what promote installs on this host: the Windows-only guard
    # only on Windows, the every-host hook everywhere.
    my %hooks = (SessionStart => [ $REAP_GROUP ], ($IS_WIN ? (PreToolUse => [ $NUL_GROUP ]) : ()));
    write_json_file("$dir/live.json", mp_settings("$root_spelling/plugins", env => \%env, theme => 'dark', hooks => \%hooks));
    write_json_file("$dir/payload.json", $PAYLOAD_V2);

    my ($rc, $out) = run_cmd({}, $^X, $JSONDIFF, "$dir/live.json", "$dir/payload.json");
    is($rc, 1, 'json-diff without --host-live: the machine-local values show as differences (non-vacuity)');
    ($rc, $out) = run_cmd({}, $^X, $JSONDIFF, '--host-live', $live_root, "$dir/live.json", "$dir/payload.json");
    is($rc, 0, 'json-diff --host-live: an in-sync machine compares identical') or diag($out);

    # a genuinely different path is still reported, with the payload side
    # expanded (so a "use the repo value" answer writes a real path).
    write_json_file("$dir/live2.json", mp_settings('/somewhere/else/plugins', env => \%env, theme => 'dark', hooks => \%hooks));
    ($rc, $out) = run_cmd({}, $^X, $JSONDIFF, '--host-live', $live_root, "$dir/live2.json", "$dir/payload.json");
    is($rc, 1, 'json-diff --host-live: a different live path is still a difference');
    my $j = eval { decode_json($out) } // {};
    my $right = $j->{diverged}{'extraKnownMarketplaces.ccpraxis-local'}{right} // {};
    is(($right->{source} // {})->{path}, "$root_spelling/plugins",
        'json-diff --host-live: the payload side of that difference is the expanded path, never the token');
}

done_testing();
