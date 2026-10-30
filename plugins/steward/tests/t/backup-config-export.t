#!/usr/bin/env perl
# platform: host
# /steward:backup's config export, end to end through the real driver
# (scripts/backup.pl -> Preflight.pm + Export.pm) with the REAL wrapped
# scripts (json-diff.pl --host-live, filter-diff.pl, save-preference.pl,
# ccpraxis-helpers.pl settings-export-merge, sync-export.pl), the real shared
# modules and the dev clone's real scripts/promote.pl.
#
# The operator's rule (2026-10-30): nothing goes into the dev clone's payload
# automatically. Every differing settings unit (one-level dotted key) without
# a saved preference is one settings_key question; only the units answered
# "into the payload" (or sent there by a saved preference) are written into
# the dev clone, only that file is committed, and the second promotion makes
# the live install carry the commit. "Back into ~/.claude" changes ~/.claude
# only; "skip" changes nothing anywhere.
#
# Fixture: a throwaway HOME, a dev clone carrying the payload and the scripts,
# the live install cloned from it (promote.pl's own first-run shape).
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Path qw(make_path);
use File::Temp qw(tempfile);
use JSON::PP;
use Test::More;
use StewardTest qw(temproot make_machine write_text read_text);

my $REPO    = "$Bin/../../../..";
my $SCRIPTS = "$Bin/../../scripts";
my $BACKUP  = "$REPO/scripts/backup.pl";

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
    system('git', '-C', _native_path($dir), map { (defined $_ && m{^/}) ? _native_path($_) : $_ } @args) == 0
        or die "git -C $dir @args failed\n";
}

sub git_out {
    my ($home, $dir, @args) = @_;
    my %e = genv($home);
    local @ENV{ keys %e } = values %e;
    open my $fh, '-|', 'git', '-C', _native_path($dir), @args or die;
    local $/;
    my $o = <$fh> // '';
    close $fh;
    $o =~ s/\s+\z//;
    return $o;
}

sub stub { my ($body) = @_; return "#!/usr/bin/env perl\nuse strict;\nuse warnings;\n$body"; }

# fixture(payload => JSON, live => JSON, prefs => JSON?) -> $r
sub fixture {
    my (%o) = @_;
    my $scratch = temproot();
    my $home    = make_machine($scratch, 'host');
    my $clone   = "$scratch/devclone";
    my $live    = "$home/.claude/ccpraxis";
    make_path($clone, "$home/.claude");
    git($home, $clone, 'init', '-q');
    write_text("$clone/.gitignore", ".backup-preferences.json\n*.pre-merge.*\n");
    # Older payload versions first, so promote.pl sees them in the history.
    for my $old (@{ $o{history} // [] }) {
        write_text("$clone/global-config/settings.json", $old);
        git($home, $clone, 'add', '-A');
        git($home, $clone, 'commit', '-q', '-m', 'an older payload');
    }
    write_text("$clone/global-config/settings.json", $o{payload});
    write_text("$clone/global-config/CLAUDE.md", $o{claude_md}) if defined $o{claude_md};
    write_text("$clone/global-config/known_marketplaces.json", "{}\n");
    write_text("$clone/skills/.keep", '');
    for my $name (qw(ccpraxis-helpers.pl sync-export.pl json-diff.pl filter-diff.pl save-preference.pl
                     DevClone.pm MachineLocalSettings.pm GlobalClaudeMd.pm)) {
        write_text("$clone/plugins/steward/scripts/$name", read_text("$SCRIPTS/$name"));
    }
    write_text("$clone/plugins/steward/scripts/sensitive-check.pl", stub("print \"No sensitive data found.\\n\"; exit 0;\n"));
    write_text("$clone/scripts/lint-readme-paths.pl", stub("exit 0;\n"));
    write_text("$clone/scripts/gen-readme-tree.pl", stub("exit 0;\n"));
    write_text("$clone/scripts/promote.pl", read_text("$REPO/scripts/promote.pl"));
    git($home, $clone, 'add', '-A');
    git($home, $clone, 'commit', '-q', '-m', 'fixture');
    {
        my %e = genv($home);
        local @ENV{ keys %e } = values %e;
        system('git', 'clone', '-q', _native_path($clone), _native_path($live)) == 0 or die "clone failed\n";
    }
    write_text("$live/.backup-preferences.json", $o{prefs}) if defined $o{prefs};
    write_text("$home/.claude/settings.json", $o{live});
    write_text("$home/.claude/CLAUDE.md", $o{home_claude_md}) if defined $o{home_claude_md};
    if ($o{ahead}) {
        write_text("$clone/ahead.txt", "developed since the last promotion\n");
        git($home, $clone, 'add', '-A');
        git($home, $clone, 'commit', '-q', '-m', 'development since the last promotion');
    }
    my $phases = "$scratch/phases";
    make_path($phases);
    write_text("$phases/$_.pm", read_text("$REPO/scripts/backup/$_.pm")) for qw(Preflight Export);
    return { home => $home, clone => $clone, live => $live, phases => $phases, state => "$scratch/state/run.json" };
}

sub backup {
    my ($r, @args) = @_;
    my %e = (genv($r->{home}), BACKUP_RUN_STATE => $r->{state}, BACKUP_PHASE_DIR => $r->{phases});
    local @ENV{ keys %e } = values %e;
    my ($efh, $ename) = tempfile(UNLINK => 1);
    close $efh;
    open(my $saved, '>&', \*STDERR) or die;
    open(STDERR, '>', $ename) or die;
    my $out = '';
    if (open(my $fh, '-|', $^X, $BACKUP, 'run', @args)) { local $/; $out = <$fh> // ''; close $fh; }
    my $exit = $? >> 8;
    open(STDERR, '>&', $saved);
    return { exit => $exit, out => $out . (read_text($ename) // ''), json => (eval { decode_json($out) } // {}) };
}

sub answer {
    my ($r, $resp, %a) = @_;
    return backup($r, '--resume', ($resp->{json}{resume_token} // ''), map { ('--answer', "$_=$a{$_}") } sort keys %a);
}

sub decisions { my ($resp) = @_; return @{ $resp->{json}{decisions} // [] }; }
sub json_file { my ($p) = @_; my $raw = read_text($p); return defined $raw ? decode_json($raw) : undef; }
sub commits   { my ($r) = @_; return git_out($r->{home}, $r->{clone}, 'rev-list', '--count', 'HEAD'); }

my $PAYLOAD = qq({"keep":1,"theme":"dark"}\n);
my $LIVE    = qq({"keep":1,"theme":"light"}\n);

# ---------------------------------------------------------------------------
# One differing key, no saved preference: exactly one question, for that key.
# ---------------------------------------------------------------------------
for my $case (
    [ use_live => 'into the payload' ],
    [ use_repo => 'back into ~/.claude' ],
    [ skip     => 'skip' ],
) {
    my ($choice, $label) = @$case;
    my $r = fixture(payload => $PAYLOAD, live => $LIVE);
    my $live_settings_before = read_text("$r->{home}/.claude/settings.json");
    my $payload_before       = read_text("$r->{clone}/global-config/settings.json");
    my $commits_before       = commits($r);
    my $live_head_before     = git_out($r->{home}, $r->{live}, 'rev-parse', 'HEAD');

    my $resp = backup($r);
    is($resp->{exit}, 10, "[$label] the differing key pauses the run") or diag($resp->{out});
    my @d = decisions($resp);
    is(scalar(@d), 1, "[$label] exactly one decision");
    is(($d[0] // {})->{kind}, 'settings_key', "[$label] it is a settings_key question");
    is(($d[0] // {})->{id}, 'preflight.settings.theme', "[$label] ...for the key that differs, and only it");

    my $resp2 = answer($r, $resp, 'preflight.settings.theme' => $choice);
    is($resp2->{exit}, 0, "[$label] the run completes") or diag($resp2->{out});

    if ($choice eq 'use_live') {
        my $payload = json_file("$r->{clone}/global-config/settings.json");
        is($payload->{theme}, 'light', "[$label] the ~/.claude value is in the dev clone's payload");
        is($payload->{keep}, 1, "[$label] ...and nothing else changed there");
        is(commits($r), $commits_before + 1, "[$label] one commit in the dev clone");
        is(git_out($r->{home}, $r->{clone}, 'show', '--name-only', '--format=', 'HEAD'), 'global-config/settings.json',
            "[$label] ...holding only the payload file");
        like(git_out($r->{home}, $r->{clone}, 'log', '-1', '--format=%s'), qr/^backup: sync ccpraxis config \(1 file\(s\)\)$/,
            "[$label] ...with the export subject");
        is(git_out($r->{home}, $r->{live}, 'rev-parse', 'HEAD'), git_out($r->{home}, $r->{clone}, 'rev-parse', 'main'),
            "[$label] the second promotion brought the live install to the dev clone's main");
        is(git_out($r->{home}, $r->{live}, 'status', '--porcelain'), '', "[$label] the live install is clean");
        is(json_file("$r->{home}/.claude/settings.json")->{theme}, 'light', "[$label] ~/.claude keeps its value");
    }
    elsif ($choice eq 'use_repo') {
        is(json_file("$r->{home}/.claude/settings.json")->{theme}, 'dark', "[$label] ~/.claude took the payload's value");
        is(json_file("$r->{home}/.claude/settings.json")->{keep}, 1, "[$label] ...and nothing else changed there");
        is(read_text("$r->{clone}/global-config/settings.json"), $payload_before, "[$label] the payload is byte-for-byte untouched");
        is(commits($r), $commits_before, "[$label] no commit");
        is(git_out($r->{home}, $r->{live}, 'rev-parse', 'HEAD'), $live_head_before, "[$label] the live install did not move");
    }
    else {
        is(read_text("$r->{home}/.claude/settings.json"), $live_settings_before, "[$label] ~/.claude/settings.json is byte-for-byte untouched");
        is(read_text("$r->{clone}/global-config/settings.json"), $payload_before, "[$label] the payload is byte-for-byte untouched");
        is(commits($r), $commits_before, "[$label] no commit");
        is(git_out($r->{home}, $r->{live}, 'rev-parse', 'HEAD'), $live_head_before, "[$label] the live install did not move");
    }
}

# ---------------------------------------------------------------------------
# A saved preference answers the key: no question, nothing changes.
# ---------------------------------------------------------------------------
{
    my $r = fixture(payload => $PAYLOAD, live => $LIVE,
        prefs => qq({"live_vs_repo":{"theme":{"category":"diverged","action":"skip-always"}}}\n));
    my $payload_before = read_text("$r->{clone}/global-config/settings.json");
    my $live_before    = read_text("$r->{home}/.claude/settings.json");
    my $commits_before = commits($r);
    my $resp = backup($r);
    is($resp->{exit}, 0, '[pref] a saved preference resolves the key: no question, the run completes') or diag($resp->{out});
    is(scalar(decisions($resp)), 0, '[pref] no decision');
    is(read_text("$r->{clone}/global-config/settings.json"), $payload_before, '[pref] the payload is untouched');
    is(read_text("$r->{home}/.claude/settings.json"), $live_before, '[pref] ~/.claude is untouched');
    is(commits($r), $commits_before, '[pref] no commit');
}

# ---------------------------------------------------------------------------
# Two differing keys: two independent questions; only what is sent to the
# payload goes there.
# ---------------------------------------------------------------------------
{
    my $r = fixture(payload => $PAYLOAD, live => qq({"keep":1,"theme":"light","newKey":"from live"}\n));
    my $resp = backup($r);
    my %ids = map { $_->{id} => $_ } decisions($resp);
    is(join(',', sort keys %ids), 'preflight.settings.newKey,preflight.settings.theme', '[two] two decisions, one per key');
    is(($ids{'preflight.settings.newKey'} // {})->{data}{relation}, 'only_left', '[two] the live-only key is asked as only_left');
    my $resp2 = answer($r, $resp, 'preflight.settings.theme' => 'use_live', 'preflight.settings.newKey' => 'skip');
    is($resp2->{exit}, 0, '[two] the run completes') or diag($resp2->{out});
    my $payload = json_file("$r->{clone}/global-config/settings.json");
    is($payload->{theme}, 'light', '[two] the key sent to the payload is there');
    ok(!exists $payload->{newKey}, '[two] the skipped key is not');
    is(json_file("$r->{home}/.claude/settings.json")->{newKey}, 'from live', '[two] ...and ~/.claude still has it');
}

# ---------------------------------------------------------------------------
# The two removals: an only_left key removed from ~/.claude, an only_right key
# removed from the payload (sent there as gone).
# ---------------------------------------------------------------------------
{
    my $r = fixture(payload => qq({"keep":1,"payloadOnly":"p"}\n), live => qq({"keep":1,"liveOnly":"l"}\n));
    my $resp = backup($r);
    my %ids = map { $_->{id} => $_ } decisions($resp);
    is(join(',', sort keys %ids), 'preflight.settings.liveOnly,preflight.settings.payloadOnly', '[remove] one decision per one-sided key');
    my %c = map { $_->{id} => 1 } @{ ($ids{'preflight.settings.payloadOnly'} // {})->{choices} // [] };
    ok($c{remove_from_repo} && $c{add_to_live} && $c{skip} && $c{keep_repo_only_remember}, '[remove] a payload-only key offers all four answers');
    my $resp2 = answer($r, $resp, 'preflight.settings.liveOnly' => 'remove_from_live', 'preflight.settings.payloadOnly' => 'remove_from_repo');
    is($resp2->{exit}, 0, '[remove] the run completes') or diag($resp2->{out});
    my $live = json_file("$r->{home}/.claude/settings.json");
    ok(!exists $live->{liveOnly}, '[remove] remove_from_live took the key out of ~/.claude');
    is($live->{keep}, 1, '[remove] ...and only that key');
    my $payload = json_file("$r->{clone}/global-config/settings.json");
    ok(!exists $payload->{payloadOnly}, '[remove] remove_from_repo took the key out of the payload');
    is($payload->{keep}, 1, '[remove] ...and only that key');
    is(git_out($r->{home}, $r->{clone}, 'show', '--name-only', '--format=', 'HEAD'), 'global-config/settings.json',
        '[remove] the removal is committed, alone');
    is(git_out($r->{home}, $r->{live}, 'rev-parse', 'HEAD'), git_out($r->{home}, $r->{clone}, 'rev-parse', 'main'),
        '[remove] and promoted');
    ok(!exists json_file("$r->{home}/.claude/settings.json")->{payloadOnly},
        '[remove] the promotion did not put the removed key back into ~/.claude');
}

# ---------------------------------------------------------------------------
# A skipped key stays as ~/.claude has it through the automatic second
# promotion, even where promote.pl would otherwise update it (the ~/.claude
# value is one the payload once had).
# ---------------------------------------------------------------------------
{
    my $r = fixture(history => [ qq({"keep":1,"theme":"light"}\n) ], payload => $PAYLOAD,
                    live => qq({"keep":1,"theme":"light","newKey":"from live"}\n));
    my $resp = backup($r);
    my %ids = map { $_->{id} => 1 } decisions($resp);
    is(join(',', sort keys %ids), 'preflight.settings.newKey,preflight.settings.theme', '[skip+promote] both keys are asked');
    my $resp2 = answer($r, $resp, 'preflight.settings.theme' => 'skip', 'preflight.settings.newKey' => 'export_to_repo');
    is($resp2->{exit}, 0, '[skip+promote] the run completes') or diag($resp2->{out});
    is(git_out($r->{home}, $r->{live}, 'rev-parse', 'HEAD'), git_out($r->{home}, $r->{clone}, 'rev-parse', 'main'),
        '[skip+promote] the export was committed and promoted');
    is(json_file("$r->{home}/.claude/settings.json")->{theme}, 'light',
        '[skip+promote] the skipped key kept its ~/.claude value through the second promotion');
    my $state = json_file($r->{state});
    my $pac = $state->{phases}{export}{items}{promote_after_commit}{data} // {};
    is(join(',', @{ $pac->{keep_keys} // [] }), 'theme', '[skip+promote] the promotion was told to keep it');
    like($pac->{output} // '', qr/^  kept-local theme \(asked\)$/m, '[skip+promote] ...and promote.pl reported keeping it');
}

# ---------------------------------------------------------------------------
# promote.pl exit 1 AFTER its fast-forward (a hand-edited ~/.claude/CLAUDE.md
# it refuses to overwrite): the live install moved, so the export goes on;
# the refusal lines reach the report, and the CLAUDE.md difference comes
# back as the export's claude_md_drift question.
# ---------------------------------------------------------------------------
{
    my $r = fixture(payload => $PAYLOAD, live => $PAYLOAD, ahead => 1,
                    claude_md => "# shared\nevery host\n", home_claude_md => "# shared\nevery host\na hand edit\n");
    my $resp = backup($r);
    is(((decisions($resp))[0] // {})->{kind}, 'promote_pending', '[refused] the dev clone is ahead: promote_pending');
    my $resp2 = answer($r, $resp, 'preflight.promote_pending' => 'promote');
    my $state = json_file($r->{state});
    my $p = $state->{phases}{preflight}{items}{promotion}{data} // {};
    is($p->{exit}, 1, '[refused] promote.pl exited 1 (it refused ~/.claude/CLAUDE.md)');
    is(git_out($r->{home}, $r->{live}, 'rev-parse', 'HEAD'), git_out($r->{home}, $r->{clone}, 'rev-parse', 'main'),
        '[refused] ...after fast-forwarding the live install');
    ok($p->{ok}, '[refused] the promotion counts as done');
    like(join("\n", @{ $p->{refusals} // [] }), qr/claude-md: refused-local-edit/, '[refused] the refusal lines are kept for the report');
    is($state->{phases}{preflight}{items}{export_target}{data}{ready}, 1, '[refused] the export target is ready');
    is($resp2->{exit}, 10, '[refused] the run goes on to the export') or diag($resp2->{out});
    is(((decisions($resp2))[0] // {})->{kind}, 'claude_md_drift', '[refused] ...which asks about the CLAUDE.md difference');
    ok(!$state->{phases}{preflight}{error}, '[refused] the preflight did not fail over it');
}

done_testing();
