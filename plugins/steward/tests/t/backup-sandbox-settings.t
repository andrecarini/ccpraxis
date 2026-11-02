#!/usr/bin/env perl
# platform: host
# /steward:backup's third preference pair: the dev clone's sandbox preset
# (plugins/sandbox/container/settings.json) against each sandbox's own
# settings.json (scripts/backup/Export.pm U5b/U6b, decision kind
# sandbox_settings_key).
#
# WHY. A sandbox's settings start as the preset and are merged with it on
# every container create, but nothing carried a sandbox's own changes back to
# the dev clone: a setting worth having everywhere stayed in one sandbox. The
# export phase now asks, per registered sandbox and per unit the SANDBOX
# changed: put it into the preset (committed with the export), keep it in
# that sandbox (once, or remembered for that project only), or revert that
# sandbox to the preset's value (its file, after a backup, and nothing else).
#
# Driven end to end through scripts/backup.pl with only the export phase in
# BACKUP_PHASE_DIR, in a throwaway HOME with a throwaway dev clone and live
# install (a clone of it). The real json-diff.pl, filter-diff.pl,
# save-preference.pl, DevClone.pm and the sandbox modules run; sync-export.pl,
# ccpraxis-helpers.pl and sensitive-check.pl are stubs, and promote.pl is a
# stand-in that fast-forwards the live install. The machine's sandbox list is
# written with the real SandboxRegistry.pm, as the launcher would.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Test::More;
use File::Path qw(make_path remove_tree);
use File::Temp qw(tempfile);
use JSON::PP;
use StewardTest qw(temproot make_machine write_text read_text);

my $REPO     = "$Bin/../../../..";
my $EXPORT   = "$REPO/scripts/backup/Export.pm";
my $BACKUP   = "$REPO/scripts/backup.pl";
my $STEWARD  = "$REPO/plugins/steward/scripts";
my $SANDBOX  = "$REPO/plugins/sandbox/scripts";

use lib "$Bin/../../../sandbox/scripts";
require SandboxRegistry;

my $J = JSON::PP->new->utf8->canonical->pretty;
sub jtext { return $J->encode($_[0]) }
sub jread { my $t = read_text($_[0]); return defined $t ? JSON::PP->new->utf8->decode($t) : undef }

sub _native_path { my ($p) = @_; (my $q = $p) =~ s{\\}{/}g; $q =~ s{^/([A-Za-z])/}{\u$1:/}; return $q; }

sub genv {
    my ($home) = @_;
    return (HOME => $home, USERPROFILE => $home, GIT_CONFIG_GLOBAL => "$home/.gitconfig",
            GIT_CONFIG_SYSTEM => '/dev/null', GIT_TERMINAL_PROMPT => '0');
}

sub git {
    my ($home, $dir, @args) = @_;
    my %e = genv($home);
    local @ENV{ keys %e } = values %e;
    system('git', '-C', _native_path($dir), @args) == 0 or die "git -C $dir @args failed\n";
}

sub git_out {
    my ($home, $dir, @args) = @_;
    my %e = genv($home);
    local @ENV{ keys %e } = values %e;
    open(my $fh, '-|', 'git', '-C', _native_path($dir), @args) or die "git: $!";
    local $/;
    my $o = <$fh> // '';
    close $fh;
    return $o;
}

sub stub { return "#!/usr/bin/env perl\nuse strict;\nuse warnings;\n$_[0]" }

# The preset, and the global payload equal to it, so the global-vs-container
# pair (U5/U6) has nothing to ask and only the sandbox pair is under test.
my $PRESET = { theme => 'dark', model => 'opus', env => { A => '1' }, keep => 1 };

sub setup {
    my $scratch = temproot();
    my $home    = make_machine($scratch, 'host');
    my $live    = "$home/.claude/ccpraxis";
    my $clone   = "$scratch/devclone";
    make_path($clone, "$home/.claude");
    git($home, $clone, 'init', '-q');
    write_text("$clone/.gitignore", ".backup-preferences.json\n");
    write_text("$clone/README.md", "# fixture\n");
    write_text("$clone/global-config/settings.json", jtext($PRESET));
    write_text("$clone/global-config/known_marketplaces.json", "{}\n");
    write_text("$clone/plugins/sandbox/container/settings.json", jtext($PRESET));
    for my $m (qw(json-diff.pl filter-diff.pl save-preference.pl DevClone.pm MachineLocalSettings.pm SettingsUnits.pm)) {
        write_text("$clone/plugins/steward/scripts/$m", read_text("$STEWARD/$m"));
    }
    for my $m (qw(SandboxIdentity.pm SandboxRegistry.pm SandboxSettings.pm HostPlatform.pm)) {
        write_text("$clone/plugins/sandbox/scripts/$m", read_text("$SANDBOX/$m"));
    }
    write_text("$clone/plugins/steward/scripts/sync-export.pl", stub("print '[]';\n"));
    write_text("$clone/plugins/steward/scripts/sensitive-check.pl", stub("print \"No sensitive data found.\\n\";\n"));
    write_text("$clone/plugins/steward/scripts/ccpraxis-helpers.pl",
        stub("print '{\"status\":\"error\",\"error\":{\"message\":\"unexpected call\"}}'; exit 3;\n"));
    # Stand-in promote.pl: fast-forward the live install to the clone's main.
    write_text("$clone/scripts/promote.pl", stub(<<'PL'));
my %a = @ARGV;
my ($clone, $live) = @a{'--clone', '--live'};
system('git', '-C', $live, 'pull', '-q', '--ff-only', $clone, 'main') == 0 or exit 2;
print "promote: stand-in fast-forward\n";
exit 0;
PL
    git($home, $clone, 'add', '-A');
    git($home, $clone, 'commit', '-q', '-m', 'fixture');
    {
        my %e = genv($home);
        local @ENV{ keys %e } = values %e;
        system('git', 'clone', '-q', _native_path($clone), _native_path($live)) == 0 or die "clone failed\n";
    }
    my $phases = "$scratch/phases";
    make_path($phases);
    write_text("$phases/Export.pm", read_text($EXPORT));
    return { scratch => $scratch, home => $home, live => $live, clone => $clone, phases => $phases,
             state => "$scratch/state/run.json", registry => SandboxRegistry::registry_path("$home/.claude") };
}

# One sandboxed project: its settings.json and the preset it was last given.
sub sandbox {
    my ($f, $name, %o) = @_;
    my $p = "$f->{scratch}/$name";
    my $ch = SandboxRegistry::claude_home_for($p);
    make_path("$ch/.launcher");
    write_text("$ch/settings.json", jtext($o{settings}));
    write_text("$ch/.launcher/container-settings.json", jtext($o{base})) if $o{base};
    my $r = SandboxRegistry::register(registry => $f->{registry}, project_path => $p,
                                      launcher => $o{launcher} // 'claude-sandbox', container => "claude-$name");
    die "register $name: $r->{error}" if $r->{error};
    return { path => $p, id => $r->{id}, settings => "$ch/settings.json", launcher_dir => "$ch/.launcher" };
}

sub seed_state {
    my ($f) = @_;
    my $now = time;
    write_text($f->{state}, JSON::PP->new->canonical->pretty->encode({
        format => 1, run_id => 'abcdefabcdefabcd', started_at => $now, updated_at => $now, status => 'running',
        phase_order => ['export'], phase_index => 0,
        phases => {
            export => { status => 'pending', items => {}, scratch => {} },
            preflight => { status => 'complete', items => {
                export_target    => { at => $now, data => { ready => 1, live_root => $f->{live}, dev_clone => $f->{clone} } },
                settings_outcome => { at => $now, data => { skip_keys => [], answers => {}, preferences_saved => [] } },
            }, scratch => {} },
        },
        token_seq => 0, consumed_seq => 0, pending => undef, answers => {}, notes => [],
    }));
}

sub backup {
    my ($f, @args) = @_;
    my %env = (genv($f->{home}), BACKUP_RUN_STATE => $f->{state}, BACKUP_PHASE_DIR => $f->{phases});
    local @ENV{ keys %env } = values %env;
    my ($efh, $ename) = tempfile(UNLINK => 1);
    close $efh;
    open(my $saved, '>&', \*STDERR) or die;
    open(STDERR, '>', $ename) or die;
    open(my $fh, '-|', $^X, $BACKUP, 'run', '--json', @args) or die "spawn: $!";
    my $out = do { local $/; <$fh> } // '';
    close $fh;
    my $exit = $? >> 8;
    open(STDERR, '>&', $saved) or die;
    my $err = read_text($ename) // '';
    my $json = eval { JSON::PP->new->decode($out) };
    return { exit => $exit, json => $json, out => $out, err => $err };
}

sub state_of { return jread($_[0]{state}) }
sub sandbox_decisions { my ($r) = @_; return grep { ($_->{kind} // '') eq 'sandbox_settings_key' } @{ $r->{json}{decisions} // [] } }
sub notes { my ($f, $key) = @_; return map { $_->{value} } grep { ($_->{key} // '') eq $key } @{ (state_of($f) // {})->{notes} // [] } }

# ===========================================================================
my $f = setup();

# alpha changed theme and added env.B; it still has the model the preset gave
# it last time (the preset has moved on to opus since: its next merge takes it).
my $alpha = sandbox($f, 'alpha',
    base     => { theme => 'dark', model => 'sonnet', env => { A => '1' }, keep => 1 },
    settings => { theme => 'light', model => 'sonnet', env => { A => '1', B => 'mine' }, keep => 1 });
# beta removed keep and added beta_only, which it already chose to keep.
my $beta = sandbox($f, 'beta',
    base     => $PRESET,
    settings => { theme => 'dark', model => 'opus', env => { A => '1' }, beta_only => JSON::PP::true });
# gamma added the same env.B as alpha.
my $gamma = sandbox($f, 'gamma',
    base     => $PRESET,
    settings => { %$PRESET, env => { A => '1', B => 'mine' } });
# a project that is gone, and a fork's sandbox (its own preset; not ours)
my $gone = sandbox($f, 'gone', base => $PRESET, settings => { %$PRESET, x => 1 });
my $fork = sandbox($f, 'forked', base => $PRESET, settings => { %$PRESET, forkOnly => 1 }, launcher => 'some-fork');
# Gone after it was registered (a removed checkout, an unplugged drive): the
# reader never prunes, so the backup meets it and skips it.
remove_tree($gone->{path});

write_text("$f->{live}/.backup-preferences.json", JSON::PP->new->canonical->pretty->encode({
    "container_vs_sandbox:$beta->{id}" => { beta_only => { category => 'only_left', action => 'left-only' } },
}));
my $alpha_before = read_text($alpha->{settings});
my $beta_before  = read_text($beta->{settings});
my $gamma_before = read_text($gamma->{settings});

seed_state($f);
my $r1 = backup($f);
is($r1->{exit}, 10, 'round 1: the run pauses for decisions') or diag($r1->{out} . $r1->{err});
my @d = sandbox_decisions($r1);
my %by = map { ("$_->{data}{project_id}/$_->{data}{key}" => $_) } @d;
is_deeply([ sort keys %by ], [ sort("$alpha->{id}/env.B", "$alpha->{id}/theme", "$beta->{id}/keep", "$gamma->{id}/env.B") ],
    'round 1: one decision per unit a sandbox changed -- the preset-moved-on model, the remembered beta_only, the gone project and the fork are not asked');
my $dt = $by{"$alpha->{id}/theme"};
like($dt->{id}, qr/\Aexport\.sandbox\.\Q$alpha->{id}\E\./, 'decision ids carry the project id');
is($dt->{data}{relation}, 'diverged', 'alpha theme: diverged');
is($dt->{data}{sandbox_value}, 'light', 'alpha theme: the sandbox value is in data');
is($dt->{data}{preset_value}, 'dark', 'alpha theme: the preset value is in data');
is_deeply([ map { $_->{id} } @{ $dt->{choices} } ], [qw(to_preset keep_in_sandbox keep_in_sandbox_remember revert_sandbox)],
    'the four choices');
is($by{"$beta->{id}/keep"}{data}{relation}, 'only_right', 'beta keep: removed in the sandbox, still in the preset');
like($by{"$beta->{id}/keep"}{choices}[0]{label}, qr/Remove it from the dev clone's sandbox preset/,
    'beta keep: "to the preset" means removing it there');

my $diff = state_of($f)->{phases}{export}{items}{sandbox_diff}{data};
my ($pa) = grep { $_->{id} eq $alpha->{id} } @{ $diff->{projects} };
is_deeply($pa->{pending_merge}, ['model'], 'alpha: the unit only the preset changed is left to the next merge, not asked');
my ($pb) = grep { $_->{id} eq $beta->{id} } @{ $diff->{projects} };
is_deeply([ map { $_->{key} } @{ $pb->{auto_applied} } ], ['beta_only'], "beta: its saved preference answered beta_only");
my ($pg) = grep { $_->{id} eq $gone->{id} } @{ $diff->{projects} };
like($pg->{skipped} // '', qr/not reachable/, 'the gone project is skipped');
ok(!grep({ $_->{id} eq $fork->{id} } @{ $diff->{projects} }), "the fork's sandbox is not compared with ccpraxis's preset");
my ($skipped_note) = notes($f, 'sandbox_settings_skipped_projects');
ok($skipped_note && grep({ ($_->{project} // '') eq $gone->{path} } @$skipped_note), 'the skip is noted');

my $r2 = backup($f, '--resume', $r1->{json}{resume_token},
    '--answer', "$by{\"$alpha->{id}/theme\"}{id}=to_preset",
    '--answer', "$by{\"$alpha->{id}/env.B\"}{id}=keep_in_sandbox_remember",
    '--answer', "$by{\"$beta->{id}/keep\"}{id}=revert_sandbox",
    '--answer', "$by{\"$gamma->{id}/env.B\"}{id}=keep_in_sandbox");
is($r2->{exit}, 0, 'round 1: the run completes') or diag($r2->{out} . $r2->{err});

# to_preset: written into the dev clone's preset and committed, nothing else
my $preset_now = jread("$f->{clone}/plugins/sandbox/container/settings.json");
is_deeply($preset_now, { %$PRESET, theme => 'light' }, 'to_preset: the sandbox value is in the dev clone preset, nothing else changed');
my $files = git_out($f->{home}, $f->{clone}, 'show', '--name-only', '--format=%s', 'HEAD');
like($files, qr/\Abackup: sync ccpraxis config \(1 file\(s\)\)\n\nplugins\/sandbox\/container\/settings\.json\n\z/,
    'to_preset: the export commit carries the preset and only the preset');
is(git_out($f->{home}, $f->{clone}, 'status', '--porcelain'), '', 'the dev clone is clean after the commit');

# revert: beta's file only, after a backup
my $beta_now = jread($beta->{settings});
is_deeply($beta_now, { theme => 'dark', model => 'opus', env => { A => '1' }, beta_only => JSON::PP::true, keep => 1 },
    "revert: beta gets the preset's keep back and keeps beta_only");
my ($stamp) = grep { !/^\./ } do { opendir my $dh, "$beta->{launcher_dir}/backups" or die; readdir $dh };
is(read_text("$beta->{launcher_dir}/backups/$stamp/settings.json"), $beta_before, "revert: beta's old file is backed up first");
is(read_text($alpha->{settings}), $alpha_before, "alpha's settings.json is untouched (to_preset and remember write no sandbox)");
is(read_text($gamma->{settings}), $gamma_before, "gamma's settings.json is untouched (keep once)");

# remember: per project
my $prefs = jread("$f->{live}/.backup-preferences.json");
is_deeply($prefs->{"container_vs_sandbox:$alpha->{id}"}, { 'env.B' => { category => 'only_left', action => 'left-only' } },
    "keep-remember: saved in alpha's own scope");
ok(!exists $prefs->{"container_vs_sandbox:$gamma->{id}"}, 'keep once: nothing saved for gamma');
is_deeply([ sort keys %{ $prefs->{"container_vs_sandbox:$beta->{id}"} } ], ['beta_only'], "beta's scope is unchanged");
my $out = state_of($f)->{phases}{export}{items}{sandbox_outcome}{data};
is_deeply($out->{wrote}, ['plugins/sandbox/container/settings.json'], 'sandbox_outcome.wrote names only the preset');

# ===========================================================================
# round 2: the remembered answer resolves alpha's env.B without a decision;
# gamma's identical env.B is still asked (the preference is alpha's alone).
# The global payload follows the preset's new theme first, so the
# global-vs-container pair has nothing to ask.
write_text("$f->{clone}/global-config/settings.json", jtext({ %$PRESET, theme => 'light' }));
git($f->{home}, $f->{clone}, 'commit', '-q', '-am', 'global theme follows the preset');
seed_state($f);
my $r3 = backup($f);
is($r3->{exit}, 10, 'round 2: pauses once more') or diag($r3->{out} . $r3->{err});
my @d3 = sandbox_decisions($r3);
is_deeply([ map { "$_->{data}{project_id}/$_->{data}{key}" } @d3 ], [ "$gamma->{id}/env.B" ],
    "round 2: only gamma's env.B is asked; alpha's is answered by its preference, theme now matches the preset, beta's keep is back");
my $diff3 = state_of($f)->{phases}{export}{items}{sandbox_diff}{data};
my ($pa3) = grep { $_->{id} eq $alpha->{id} } @{ $diff3->{projects} };
is_deeply([ map { $_->{key} } @{ $pa3->{auto_applied} } ], ['env.B'], "round 2: alpha's env.B auto-applied from its preference");

# a revert of gamma's env.B removes only that sub-key
my $r4 = backup($f, '--resume', $r3->{json}{resume_token}, '--answer', "$d3[0]{id}=revert_sandbox");
is($r4->{exit}, 0, 'round 2: completes') or diag($r4->{out} . $r4->{err});
is_deeply(jread($gamma->{settings}), $PRESET, "revert of an only-in-sandbox sub-key removes just env.B");
is(git_out($f->{home}, $f->{clone}, 'log', '--format=%s', '-1'), "global theme follows the preset\n",
    'round 2: a revert commits nothing');

# ===========================================================================
# two sandboxes sending one unit to the preset with different values: nothing
# is written for it, and the run says so (with a non-ASCII value on the way).
{
    my $g = setup();
    my $one = sandbox($g, 'one', base => $PRESET, settings => { %$PRESET, theme => "Andr\x{e9}" });
    my $two = sandbox($g, 'two', base => $PRESET, settings => { %$PRESET, theme => 'solarized', extra => "caf\x{e9}" });
    seed_state($g);
    my $a = backup($g);
    is($a->{exit}, 10, 'conflict: pauses') or diag($a->{out} . $a->{err});
    my @dd = sandbox_decisions($a);
    is(scalar(@dd), 3, 'conflict: three decisions (theme twice, extra once)');
    my ($t1) = grep { $_->{data}{project_id} eq $one->{id} && $_->{data}{key} eq 'theme' } @dd;
    is($t1->{data}{sandbox_value}, "Andr\xc3\xa9", 'conflict: a non-ASCII value reaches the decision as UTF-8');
    my $b = backup($g, '--resume', $a->{json}{resume_token}, map { ('--answer', "$_->{id}=to_preset") } @dd);
    is($b->{exit}, 20, 'conflict: the run completes with a failure') or diag($b->{out} . $b->{err});
    my $preset = jread("$g->{clone}/plugins/sandbox/container/settings.json");
    is($preset->{theme}, 'dark', 'conflict: the contested unit is not written');
    is($preset->{extra}, "caf\x{e9}", 'conflict: the uncontested unit is, encoded once');
    like(join(' ', map { $_->{error} // '' } @{ $b->{json}{phases} // [] }), qr/'theme' was sent to the preset from 2 sandboxes with different values/,
        'conflict: the failure names the unit');
    my $out = state_of($g)->{phases}{export}{items}{sandbox_outcome}{data};
    is_deeply([ map { $_->{key} } @{ $out->{refused} } ], ['theme'], 'conflict: sandbox_outcome lists it as refused');
}

done_testing();
