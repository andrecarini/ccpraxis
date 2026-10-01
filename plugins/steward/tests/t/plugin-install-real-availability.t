#!/usr/bin/env perl
# platform: windows
# 17 -- oracle for blueprint tooling-fixes, package
# 17-plugin-install-real-availability.
#
# Spec: .ccpraxis-local-data/blueprints/tooling-fixes/specs/17-plugin-install-real-availability-spec.md
#
# Written BLIND to any implementation: check-plugins.pl's post-fix classification
# logic, Closeout.pm's _plugin_decision wording and SKILL.md's rewritten rows are
# not read. Only the spec (sections 1-6), the SHIPPED check-plugins.pl command-line
# contract (--settings/--installed/--marketplaces, already documented in its own
# usage comment and exercised here only via its OWN stdout), Closeout.pm's existing
# wrapped-script contract (already public via backup-closeout.t's scaffold, which
# this file mirrors per spec 4.3), and StewardTest.pm were read.
#
# AC -> test name mapping (grep "AC<n>:" for every assertion of a given criterion):
#   AC1  review-only (spec section 1.2) -- no test here.
#   AC2  B1: directory-served plugin, no install record -> enabled[], served_in_place
#        true, installed false, missing empty, exit 0.
#   AC3  B2/B3: object-sourced catalog entry / non-directory marketplace -> missing[],
#        exit 1.
#   AC4  B4(a)-(e): degraded catalog/marketplace cases -> missing[], exit 1, stdout
#        still valid JSON.
#   AC5  B5: unregistered marketplace -> missing_marketplaces[], never missing[].
#   AC6  B6: user/managed always count; project/local count only for a matching
#        --project.
#   AC7  B7: same_path matches/non-matches, including non-ASCII and the Windows-only
#        /c/... case.
#   AC8  B8: extra_installed computed over the counting set only.
#   AC9  every per-plugin entry carries a JSON boolean served_in_place.
#   AC10 Closeout B9: directory-served plugin -> no plugin_install decision minted.
#   AC11 Closeout B10: matching-project install record -> no decision (proves
#        Closeout passes --project = pinned cwd).
#   AC12 Closeout B11: really-missing plugin -> exactly one plugin_install decision;
#        id/kind/choice ids/data unchanged; detail and install label match the 2.2
#        template exactly.
#   AC13 Closeout B12: install_plugin follow-up present, unchanged shape.
#   AC14 SKILL.md: new wording present, old "run it/this yourself" framing absent,
#        check-plugins.pl still never named.
#   AC15 static: neither check-plugins.pl nor Closeout.pm spawns a claude binary.
#   AC16 hermetic: real HOME/USERPROFILE never appears in captured stdout/argv.
#   AC17 (covered by the dispatch's own separate runs of backup-closeout.t /
#        backup-driver-core.t / backup-wrapper.t -- not re-asserted here).
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Path qw(make_path);
use File::Temp qw(tempfile);
use JSON::PP;
use Encode qw(decode FB_CROAK);
use StewardTest qw(ok is like unlike diag done_testing temproot make_machine write_text read_text path_exists);

my $CHECK_PLUGINS = "$Bin/../../scripts/check-plugins.pl";
my $CLOSEOUT_SRC  = "$Bin/../../../../scripts/backup/Closeout.pm";
my $BACKUP_SCRIPT = "$Bin/../../../../scripts/backup.pl";
my $SKILL_MD      = "$Bin/../../skills/backup/SKILL.md";

ok(-f $CHECK_PLUGINS, 'plugins/steward/scripts/check-plugins.pl exists on disk')
    or diag('every B1-B8 scenario below will fail for this reason');
ok(-f $CLOSEOUT_SRC, 'scripts/backup/Closeout.pm exists on disk')
    or diag('every Closeout scenario below will fail for this reason');
ok(-f $BACKUP_SCRIPT, 'scripts/backup.pl exists on disk');
ok(-f $SKILL_MD, 'plugins/steward/skills/backup/SKILL.md exists on disk');

my $REAL_HOME        = $ENV{HOME};
my $REAL_USERPROFILE = $ENV{USERPROFILE};

my $EACUTE = "\xC3\xA9";   # raw UTF-8 bytes of e-acute -- never a literal source character (P17 convention)

sub widen_bytes { my ($b) = @_; return decode('UTF-8', $b, FB_CROAK()); }

# ===========================================================================
# wjson -- write a JSON fixture WITHOUT ->utf8 so an embedded raw-UTF-8-byte
# value (e.g. $EACUTE) is written to disk unchanged, matching backup-closeout.t's
# set_fixture discipline (see that file's BYTE/CHARACTER SPACE note).
# ===========================================================================
sub wjson {
    my ($path, $data) = @_;
    write_text($path, JSON::PP->new->canonical->encode($data));
}

sub jtrue  { return JSON::PP::true; }
sub jfalse { return JSON::PP::false; }

# ===========================================================================
# run_check_plugins -- spawns the REAL script directly (spec 4.2), list-form
# argv only, raw-byte values passed straight through, stderr captured via a
# real File::Temp file (never an in-memory scalar).
# ===========================================================================
sub run_check_plugins {
    my (%opts) = @_;
    my @args;
    push @args, '--settings',     $opts{settings}     if defined $opts{settings};
    push @args, '--installed',    $opts{installed}    if defined $opts{installed};
    push @args, '--marketplaces', $opts{marketplaces} if defined $opts{marketplaces};
    push @args, '--project',      $opts{project}      if defined $opts{project};

    local $ENV{MSYS2_ARG_CONV_EXCL} = '*' if $^O =~ /^(MSWin32|cygwin|msys)$/;

    my ($efh, $ename) = tempfile(UNLINK => 1);
    close $efh;
    open(my $saved_stderr, '>&', \*STDERR) or die "cannot dup STDERR: $!";
    open(STDERR, '>', $ename) or die "cannot redirect STDERR: $!";

    my $out  = '';
    my $exit = -1;
    my $ok = open(my $fh, '-|', $^X, $CHECK_PLUGINS, @args);
    if ($ok) {
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

# ===========================================================================
# build_dm_marketplace -- an absolute scratch dir M whose
# M/.claude-plugin/marketplace.json is the directory-source catalog (spec 3's
# M fixture). %opts selects the degraded B4 variants.
# ===========================================================================
sub build_dm_marketplace {
    my (%opts) = @_;
    my $scratch = temproot();
    my $mdir = "$scratch/mkt";
    make_path("$mdir/.claude-plugin");
    if ($opts{omit_catalog}) {
        # B4(b): marketplace.json absent entirely.
    } elsif ($opts{invalid_json}) {
        write_text("$mdir/.claude-plugin/marketplace.json", "{this is not valid json");
    } else {
        my $catalog = $opts{catalog} // { name => 'dm', plugins => [ { name => 'p', source => './p' } ] };
        wjson("$mdir/.claude-plugin/marketplace.json", $catalog);
    }
    return $mdir;
}

sub scratch_file {
    my ($name) = @_;
    my $scratch = temproot();
    return "$scratch/$name";
}

# ===========================================================================
# B1 (AC2): directory-served plugin, no install record -> enabled[],
# served_in_place:true, installed:false, missing empty, exit 0.
# ===========================================================================
{
    my $M = build_dm_marketplace();
    my $settings = scratch_file('settings.json');
    wjson($settings, { enabledPlugins => { 'p@dm' => jtrue() } });
    my $marketplaces = scratch_file('known_marketplaces.json');
    wjson($marketplaces, { dm => { source => { source => 'directory', path => $M } } });

    my $r = run_check_plugins(settings => $settings, marketplaces => $marketplaces);
    is($r->{exit}, 0, 'AC2 (B1): directory-served plugin with no install record -> exit 0') or diag($r->{out} . $r->{err});
    if (ref($r->{json}) eq 'HASH') {
        is(($r->{json}{status} // ''), 'ok', 'AC2 (B1): status is "ok"');
        is(scalar(@{ $r->{json}{missing} // ['x'] }), 0, 'AC2 (B1): missing[] is empty');
        my @enabled = @{ $r->{json}{enabled} // [] };
        is(scalar(@enabled), 1, 'AC2 (B1): enabled[] has exactly one entry');
        if (@enabled) {
            is(($enabled[0]{plugin} // ''), 'p@dm', 'AC2 (B1): enabled[0].plugin eq p@dm');
            ok($enabled[0]{served_in_place} ? 1 : 0, 'AC2 (B1): enabled[0].served_in_place is true');
            ok(!$enabled[0]{installed}, 'AC2 (B1): enabled[0].installed is false (no install record)');
            ok($enabled[0]{marketplace_registered} ? 1 : 0, 'AC2 (B1): enabled[0].marketplace_registered is true');
        } else {
            ok(0, 'AC2 (B1): enabled[0] fields (entry missing)');
            ok(0, 'AC2 (B1): enabled[0] fields (entry missing)');
            ok(0, 'AC2 (B1): enabled[0] fields (entry missing)');
            ok(0, 'AC2 (B1): enabled[0] fields (entry missing)');
        }
        # AC9: the boolean is JSON-typed, not a stringified "true"/"false".
        unlike($r->{out}, qr/"served_in_place":"(?:true|false)"/, 'AC9 (B1): served_in_place is not a quoted string');
        like($r->{out}, qr/"served_in_place":(?:true|false)/, 'AC9 (B1): served_in_place is JSON-encoded as a bare boolean');
    } else {
        ok(0, "AC2 (B1): stdout decodes as JSON ($r->{out})");
    }
}

# ===========================================================================
# B2 (AC3): catalog entry is object-sourced (not a string) -> missing[].
# ===========================================================================
{
    my $M = build_dm_marketplace(catalog => { name => 'dm', plugins => [ { name => 'p', source => { source => 'github', repo => 'o/r' } } ] });
    my $settings = scratch_file('settings.json');
    wjson($settings, { enabledPlugins => { 'p@dm' => jtrue() } });
    my $marketplaces = scratch_file('known_marketplaces.json');
    wjson($marketplaces, { dm => { source => { source => 'directory', path => $M } } });

    my $r = run_check_plugins(settings => $settings, marketplaces => $marketplaces);
    is($r->{exit}, 1, 'AC3 (B2): object-sourced catalog entry -> exit 1') or diag($r->{out} . $r->{err});
    if (ref($r->{json}) eq 'HASH') {
        my @missing = grep { ($_->{plugin} // '') eq 'p@dm' } @{ $r->{json}{missing} // [] };
        is(scalar(@missing), 1, 'AC3 (B2): p@dm is in missing[]');
        ok(!$missing[0]{served_in_place}, 'AC3 (B2): missing entry served_in_place is false') if @missing;
    } else {
        ok(0, "AC3 (B2): stdout decodes as JSON ($r->{out})");
    }
}

# ===========================================================================
# B3 (AC3): marketplace registered as a non-directory source -> missing[].
# ===========================================================================
{
    my $M = build_dm_marketplace();
    my $settings = scratch_file('settings.json');
    wjson($settings, { enabledPlugins => { 'p@dm' => jtrue() } });
    my $marketplaces = scratch_file('known_marketplaces.json');
    wjson($marketplaces, { dm => { source => { source => 'github', repo => 'o/r' }, installLocation => $M } });

    my $r = run_check_plugins(settings => $settings, marketplaces => $marketplaces);
    is($r->{exit}, 1, 'AC3 (B3): non-directory marketplace source -> exit 1') or diag($r->{out} . $r->{err});
    if (ref($r->{json}) eq 'HASH') {
        my @missing = grep { ($_->{plugin} // '') eq 'p@dm' } @{ $r->{json}{missing} // [] };
        is(scalar(@missing), 1, 'AC3 (B3): p@dm is in missing[]');
    } else {
        ok(0, "AC3 (B3): stdout decodes as JSON ($r->{out})");
    }
}

# ===========================================================================
# B4(a)-(e) (AC4): degraded catalog/marketplace cases -> missing[], exit 1,
# stdout still valid JSON, never a die.
# ===========================================================================
{
    my %cases = (
        a_catalog_lacks_plugin => sub { return build_dm_marketplace(catalog => { name => 'dm', plugins => [ { name => 'other', source => './other' } ] }); },
        b_marketplace_json_absent => sub { return build_dm_marketplace(omit_catalog => 1); },
        c_marketplace_json_invalid => sub { return build_dm_marketplace(invalid_json => 1); },
        d_source_path_relative => undef,   # handled specially below (known_marketplaces path, not M)
        e_source_path_missing  => undef,
    );

    for my $case (qw(a_catalog_lacks_plugin b_marketplace_json_absent c_marketplace_json_invalid)) {
        my $M = $cases{$case}->();
        my $settings = scratch_file('settings.json');
        wjson($settings, { enabledPlugins => { 'p@dm' => jtrue() } });
        my $marketplaces = scratch_file('known_marketplaces.json');
        wjson($marketplaces, { dm => { source => { source => 'directory', path => $M } } });

        my $r = run_check_plugins(settings => $settings, marketplaces => $marketplaces);
        is($r->{exit}, 1, "AC4 (B4 $case): exit 1") or diag($r->{out} . $r->{err});
        ok(ref($r->{json}) eq 'HASH', "AC4 (B4 $case): stdout decodes as JSON") or diag($r->{out});
        if (ref($r->{json}) eq 'HASH') {
            my @missing = grep { ($_->{plugin} // '') eq 'p@dm' } @{ $r->{json}{missing} // [] };
            is(scalar(@missing), 1, "AC4 (B4 $case): p\@dm is in missing[]");
        }
    }

    # (d) source.path relative -- not resolved, rule fails.
    {
        my $settings = scratch_file('settings.json');
        wjson($settings, { enabledPlugins => { 'p@dm' => jtrue() } });
        my $marketplaces = scratch_file('known_marketplaces.json');
        wjson($marketplaces, { dm => { source => { source => 'directory', path => 'relative/mkt/path' } } });

        my $r = run_check_plugins(settings => $settings, marketplaces => $marketplaces);
        is($r->{exit}, 1, 'AC4 (B4d source.path relative): exit 1') or diag($r->{out} . $r->{err});
        ok(ref($r->{json}) eq 'HASH', 'AC4 (B4d): stdout decodes as JSON') or diag($r->{out});
        if (ref($r->{json}) eq 'HASH') {
            my @missing = grep { ($_->{plugin} // '') eq 'p@dm' } @{ $r->{json}{missing} // [] };
            is(scalar(@missing), 1, 'AC4 (B4d): p@dm is in missing[]');
        }
    }

    # (e) source.path missing entirely.
    {
        my $settings = scratch_file('settings.json');
        wjson($settings, { enabledPlugins => { 'p@dm' => jtrue() } });
        my $marketplaces = scratch_file('known_marketplaces.json');
        wjson($marketplaces, { dm => { source => { source => 'directory' } } });

        my $r = run_check_plugins(settings => $settings, marketplaces => $marketplaces);
        is($r->{exit}, 1, 'AC4 (B4e source.path missing): exit 1') or diag($r->{out} . $r->{err});
        ok(ref($r->{json}) eq 'HASH', 'AC4 (B4e): stdout decodes as JSON') or diag($r->{out});
        if (ref($r->{json}) eq 'HASH') {
            my @missing = grep { ($_->{plugin} // '') eq 'p@dm' } @{ $r->{json}{missing} // [] };
            is(scalar(@missing), 1, 'AC4 (B4e): p@dm is in missing[]');
        }
    }
}

# ===========================================================================
# B5 (AC5): marketplace not in known_marketplaces -> missing_marketplaces[],
# never missing[]; served_in_place false (regression guard: unchanged today).
# ===========================================================================
{
    my $settings = scratch_file('settings.json');
    wjson($settings, { enabledPlugins => { 'p@dm' => jtrue() } });
    my $marketplaces = scratch_file('known_marketplaces.json');
    wjson($marketplaces, {});   # dm not registered at all

    my $r = run_check_plugins(settings => $settings, marketplaces => $marketplaces);
    is($r->{exit}, 1, 'AC5 (B5): unregistered marketplace -> exit 1') or diag($r->{out} . $r->{err});
    if (ref($r->{json}) eq 'HASH') {
        is(scalar(@{ $r->{json}{missing} // ['x'] }), 0, 'AC5 (B5): missing[] stays empty');
        my @mmp = grep { ($_->{plugin} // '') eq 'p@dm' } @{ $r->{json}{missing_marketplaces} // [] };
        is(scalar(@mmp), 1, 'AC5 (B5): p@dm is in missing_marketplaces[]');
        ok(!$mmp[0]{served_in_place}, 'AC5 (B5): served_in_place is false for an unregistered marketplace') if @mmp;
    } else {
        ok(0, "AC5 (B5): stdout decodes as JSON ($r->{out})");
    }
}

# ===========================================================================
# B6 (AC6): install-record scope rules. A data-driven loop over the spec's
# cases, all against a remote (github-source, never served-in-place)
# marketplace 'gm' so served_in_place can never explain a pass.
# ===========================================================================
{
    my @cases = (
        { name => 'user scope, no --project',                entries => [ { scope => 'user' } ],    project => undef,      expect => 'enabled', installed => 1 },
        { name => 'managed scope, no --project',              entries => [ { scope => 'managed' } ], project => undef,      expect => 'enabled' },
        { name => 'project scope, other project',             entries => [ { scope => 'project', projectPath => 'C:\\Other' } ], project => 'C:/Proj', expect => 'missing', installed => 0 },
        { name => 'project scope, matching project',          entries => [ { scope => 'project', projectPath => 'C:\\Proj' } ],  project => 'C:/Proj', expect => 'enabled' },
        { name => 'local scope, matching project',            entries => [ { scope => 'local',   projectPath => 'C:\\Proj' } ],  project => 'C:/Proj', expect => 'enabled' },
        { name => 'local scope, other project',               entries => [ { scope => 'local',   projectPath => 'C:\\Other' } ], project => 'C:/Proj', expect => 'missing' },
        { name => 'project scope, no --project at all',       entries => [ { scope => 'project', projectPath => 'C:\\Proj' } ],  project => undef,     expect => 'missing' },
        { name => 'entry with no scope key',                  entries => [ { projectPath => 'C:\\Proj' } ],                      project => undef,     expect => 'missing' },
        { name => 'entry with unknown scope "bogus"',         entries => [ { scope => 'bogus' } ],                               project => undef,     expect => 'missing' },
        { name => 'two entries: other-project + user',        entries => [ { scope => 'project', projectPath => 'C:\\Other' }, { scope => 'user' } ], project => 'C:/Proj', expect => 'enabled' },
    );

    for my $c (@cases) {
        my $settings = scratch_file('settings.json');
        wjson($settings, { enabledPlugins => { 'q@gm' => jtrue() } });
        my $marketplaces = scratch_file('known_marketplaces.json');
        wjson($marketplaces, { gm => { source => { source => 'github', repo => 'o/r' } } });
        my $installed = scratch_file('installed_plugins.json');
        wjson($installed, { plugins => { 'q@gm' => $c->{entries} } });

        my %args = (settings => $settings, marketplaces => $marketplaces, installed => $installed);
        $args{project} = $c->{project} if defined $c->{project};
        my $r = run_check_plugins(%args);

        my $expected_exit = ($c->{expect} eq 'enabled') ? 0 : 1;
        is($r->{exit}, $expected_exit, "AC6 (B6 $c->{name}): exit $expected_exit") or diag($r->{out} . $r->{err});
        if (ref($r->{json}) eq 'HASH') {
            my $bucket = $c->{expect} eq 'enabled' ? 'enabled' : 'missing';
            my @found = grep { ($_->{plugin} // '') eq 'q@gm' } @{ $r->{json}{$bucket} // [] };
            is(scalar(@found), 1, "AC6 (B6 $c->{name}): q\@gm is in $bucket\[]");
            if (exists $c->{installed} && @found) {
                is(($found[0]{installed} ? 1 : 0), $c->{installed}, "AC6 (B6 $c->{name}): installed flag matches");
            }
        } else {
            ok(0, "AC6 (B6 $c->{name}): stdout decodes as JSON ($r->{out})");
        }
    }
}

# ===========================================================================
# B7 (AC7): same_path normalisation matches/non-matches.
# ===========================================================================
{
    my $andre_json  = "C:\\Users\\Andr${EACUTE}\\proj";     # JSON-fixture bytes (backslash form)
    my $andre_argv  = "C:/Users/Andr${EACUTE}/proj";         # argv bytes (forward-slash form)

    my @matches = (
        { name => 'trailing backslash vs forward-slash',        json => 'C:\\Proj\\',  argv => 'C:/Proj' },
        { name => 'lowercase drive letter vs uppercase',        json => 'c:\\proj',    argv => 'C:/Proj' },
        { name => 'POSIX trailing slash',                       json => '/srv/proj/',  argv => '/srv/proj' },
        { name => 'non-ASCII path (e-acute)',                   json => $andre_json,   argv => $andre_argv },
    );
    my @nonmatches = (
        { name => 'descendant directory does not match',        json => 'C:\\Proj\\sub', argv => 'C:/Proj' },
        { name => 'POSIX path is case-sensitive',                json => '/srv/Proj',     argv => '/srv/proj' },
    );

    for my $c (@matches, @nonmatches) {
        my $expect_match = (grep { $_ == $c } @matches) ? 1 : 0;
        my $settings = scratch_file('settings.json');
        wjson($settings, { enabledPlugins => { 'q@gm' => jtrue() } });
        my $marketplaces = scratch_file('known_marketplaces.json');
        wjson($marketplaces, { gm => { source => { source => 'github', repo => 'o/r' } } });
        my $installed = scratch_file('installed_plugins.json');
        wjson($installed, { plugins => { 'q@gm' => [ { scope => 'project', projectPath => $c->{json} } ] } });

        my $r = run_check_plugins(settings => $settings, marketplaces => $marketplaces, installed => $installed, project => $c->{argv});
        my $bucket = $expect_match ? 'enabled' : 'missing';
        my $label = $expect_match ? "AC7 (B7 $c->{name}): matches" : "AC7 (B7 $c->{name}): does not match";
        if (ref($r->{json}) eq 'HASH') {
            my @found = grep { ($_->{plugin} // '') eq 'q@gm' } @{ $r->{json}{$bucket} // [] };
            is(scalar(@found), 1, "$label -> q\@gm in $bucket\[]");
        } else {
            ok(0, "$label (stdout: $r->{out})");
        }
    }

    # Windows-only: C:\Proj vs /c/Proj matches only on MSWin32|msys|cygwin.
    if ($^O =~ /^(MSWin32|msys|cygwin)$/) {
        my $settings = scratch_file('settings.json');
        wjson($settings, { enabledPlugins => { 'q@gm' => jtrue() } });
        my $marketplaces = scratch_file('known_marketplaces.json');
        wjson($marketplaces, { gm => { source => { source => 'github', repo => 'o/r' } } });
        my $installed = scratch_file('installed_plugins.json');
        wjson($installed, { plugins => { 'q@gm' => [ { scope => 'project', projectPath => 'C:\\Proj' } ] } });

        my $r = run_check_plugins(settings => $settings, marketplaces => $marketplaces, installed => $installed, project => '/c/Proj');
        if (ref($r->{json}) eq 'HASH') {
            my @found = grep { ($_->{plugin} // '') eq 'q@gm' } @{ $r->{json}{enabled} // [] };
            is(scalar(@found), 1, "AC7 (B7 windows /c/... form): C:\\Proj matches /c/Proj on \$^O=$^O");
        } else {
            ok(0, "AC7 (B7 windows /c/... form) (stdout: $r->{out})");
        }
    }
}

# ===========================================================================
# B8 (AC8): extra_installed computed over the counting set only.
# ===========================================================================
{
    my $settings = scratch_file('settings.json');
    wjson($settings, { enabledPlugins => { 'z@gm' => jtrue() } });   # a filler enabled plugin so enabledPlugins is non-empty
    my $marketplaces = scratch_file('known_marketplaces.json');
    wjson($marketplaces, { gm => { source => { source => 'github', repo => 'o/r' } } });
    my $installed = scratch_file('installed_plugins.json');
    wjson($installed, {
        plugins => {
            'z@gm' => [ { scope => 'user' } ],
            'x@gm' => [ { scope => 'user' } ],
            'y@gm' => [ { scope => 'project', projectPath => 'C:\\Other' } ],
        },
    });

    my $r = run_check_plugins(settings => $settings, marketplaces => $marketplaces, installed => $installed, project => 'C:/Proj');
    is($r->{exit}, 0, 'AC8 (B8): (setup) z@gm counts as installed via user scope -> exit 0') or diag($r->{out} . $r->{err});
    if (ref($r->{json}) eq 'HASH') {
        my @extra = map { $_->{plugin} } @{ $r->{json}{extra_installed} // [] };
        is_deeply_sorted(\@extra, ['x@gm'], 'AC8 (B8): extra_installed lists x@gm only (y@gm does not count -- other project; z@gm is enabled)');
    } else {
        ok(0, "AC8 (B8): stdout decodes as JSON ($r->{out})");
    }
}

sub is_deeply_sorted {
    my ($got, $expected, $name) = @_;
    my @g = sort @$got;
    my @e = sort @$expected;
    my $ok = (scalar(@g) == scalar(@e)) && !(grep { $g[$_] ne $e[$_] } 0 .. $#g);
    ok($ok, $name) or diag('  got: [' . join(',', @g) . "]\n  expected: [" . join(',', @e) . ']');
    return $ok;
}

# ===========================================================================
# AC15 -- static: neither check-plugins.pl nor Closeout.pm spawns a claude
# binary (no list-form or string exec whose program matches /\bclaude(\.exe)?\b/).
# ===========================================================================
{
    for my $pair ([$CHECK_PLUGINS, 'check-plugins.pl'], [$CLOSEOUT_SRC, 'Closeout.pm']) {
        my ($path, $label) = @$pair;
        my $src = -f $path ? (read_text($path) // '') : '';
        ok(length($src) > 0, "AC15: $label source is readable for the static scan") if -f $path;
        unlike($src,
            qr/(?:open\s*\([^;]*?-\|[^;]*?|system\s*\(|qx[\/\{\(\[]|`[^`]*)\s*[^;]*?\bclaude(?:\.exe)?\b/s,
            "AC15: $label contains no spawn of a program matching /\\bclaude(\\.exe)?\\b/");
    }
}

# ===========================================================================
# Closeout integration scaffold -- mirrors backup-closeout.t's scaffold (spec
# 4.3), with one difference: the REAL check-plugins.pl is copied in instead of
# a stub, so this phase's own fixed vs project-scoped install-record logic
# runs for real. vault-sync.pl and claude-binary-backup.pl stay stubbed.
# ===========================================================================
my $GENERIC_STUB_TEMPLATE = <<'PERL';
use strict;
use warnings;
my $SCRIPT_NAME = '___SCRIPT_NAME___';
my $log = $ENV{CLOSEOUT_TEST_LOG};
if (defined $log && length $log) {
    open my $lfh, '>>:raw', $log or die "cannot append to log: $!";
    print {$lfh} "$SCRIPT_NAME @ARGV\n";
    close $lfh;
}
my $cmd = (@ARGV && $ARGV[0] !~ /^--/) ? $ARGV[0] : '';
my $dir = $ENV{CLOSEOUT_TEST_FIXTURE_DIR};
unless (defined $dir && length $dir) {
    print '{"status":"error","error":"closeout test stub: no fixture dir configured"}';
    exit 1;
}
my $key = length($cmd) ? $cmd : $SCRIPT_NAME;
my $resp_file = "$dir/$key.resp";
unless (-f $resp_file) {
    print '{"status":"error","error":"closeout test stub: no fixture for key=' . $key . '"}';
    exit 1;
}
open my $rfh, '<:raw', $resp_file or die "cannot read resp: $!";
local $/; my $body = <$rfh>; close $rfh;
print $body;
exit 0;
PERL

sub _stub_for {
    my ($script_name) = @_;
    (my $t = $GENERIC_STUB_TEMPLATE) =~ s/___SCRIPT_NAME___/$script_name/;
    return $t;
}

sub setup_closeout_root {
    my (%opts) = @_;
    my $scratch = temproot();
    my $home    = make_machine($scratch, 'host');
    my $root    = "$home/.claude/ccpraxis";
    make_path("$root/plugins/steward/scripts");
    make_path("$root/global-config");
    make_path("$home/.claude/plugins");

    write_text("$root/plugins/steward/scripts/vault-sync.pl", _stub_for('vault-sync.pl'));
    write_text("$root/plugins/steward/scripts/claude-binary-backup.pl", _stub_for('claude-binary-backup.pl'));
    write_text("$root/plugins/steward/scripts/check-plugins.pl", read_text($CHECK_PLUGINS));

    my $phase_dir = "$scratch/phases";
    make_path($phase_dir);
    write_text("$phase_dir/Closeout.pm", read_text($CLOSEOUT_SRC));

    my $fixture_dir = "$scratch/fixtures";
    make_path($fixture_dir);

    my $cwd = $opts{cwd} // "$scratch/proj";
    make_path($cwd) unless -d $cwd;

    return {
        scratch => $scratch, home => $home, root => $root, phase_dir => $phase_dir,
        fixture_dir => $fixture_dir, state_path => "$scratch/state/run.json",
        log_path => "$scratch/log.txt", cwd => $cwd,
    };
}

sub set_fixture {
    my ($fx_dir, $name, $data) = @_;
    make_path($fx_dir);
    my $body = ref($data) ? JSON::PP->new->canonical->encode($data) : $data;
    write_text("$fx_dir/$name", $body);
}

sub mk_is_registered {
    my (%o) = @_;
    my $h = { registered => ($o{registered} ? jtrue() : jfalse()), cwd => $o{cwd} };
    $h->{slug} = $o{slug} if exists $o{slug};
    return $h;
}
sub mk_snapshot_list {
    my (%o) = @_;
    return { status => ($o{status} // 'ok'), count => $o{count}, snapshots => ($o{snapshots} // []) };
}

sub _spawn_backup {
    my ($env_overrides, @args) = @_;
    my @keys = keys %$env_overrides;
    local @ENV{@keys};
    for my $k (@keys) {
        if (defined $env_overrides->{$k}) { $ENV{$k} = $env_overrides->{$k}; }
        else { delete $ENV{$k}; }
    }

    my ($efh, $ename) = tempfile(UNLINK => 1);
    close $efh;
    open(my $saved_stderr, '>&', \*STDERR) or die "cannot dup STDERR: $!";
    open(STDERR, '>', $ename) or die "cannot redirect STDERR to $ename: $!";

    my $out  = '';
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

sub closeout_env {
    my ($r, %extra) = @_;
    my %env = (
        HOME                      => $r->{home},
        USERPROFILE               => $r->{home},
        BACKUP_RUN_STATE          => $r->{state_path},
        BACKUP_PHASE_DIR          => $r->{phase_dir},
        CLOSEOUT_TEST_LOG         => $r->{log_path},
        CLOSEOUT_TEST_FIXTURE_DIR => $r->{fixture_dir},
    );
    for my $k (keys %extra) { $env{$k} = $extra{$k}; }
    return \%env;
}

sub run_closeout {
    my ($r, $extra_env, @args) = @_;
    my $env = closeout_env($r, %{ $extra_env // {} });
    my $orig = Cwd::getcwd();
    if (defined $r->{cwd}) {
        chdir($r->{cwd}) or die "cannot chdir to $r->{cwd}: $!";
    }
    my $resp = eval { _spawn_backup($env, 'run', @args) };
    my $err = $@;
    if (defined $r->{cwd}) {
        chdir($orig) or warn "cannot chdir back to $orig: $!";
    }
    die $err if $err;
    return $resp;
}

sub closeout_answer_and_resume {
    my ($r, $resp, %answers) = @_;
    my $token = $resp->{json}{resume_token};
    my @args = ('--resume', $token);
    for my $id (sort keys %answers) { push @args, '--answer', "$id=$answers{$id}"; }
    return run_closeout($r, {}, @args);
}

sub closeout_decisions { my ($resp) = @_; return @{ $resp->{json}{decisions} // [] }; }
sub closeout_report_from_notes {
    my ($notes) = @_;
    my $rep;
    for my $n (@{ $notes // [] }) {
        $rep = $n->{value} if ref($n) eq 'HASH' && (($n->{key} // '') eq 'report');
    }
    return $rep;
}

use Cwd ();

# ===========================================================================
# B9 (AC10): directory-served enabled plugin with no install record ->
# check-plugins missing[] empty -> no plugin_install decision minted; closeout
# does not pause on plugins.
# ===========================================================================
{
    my $r = setup_closeout_root();
    set_fixture($r->{fixture_dir}, 'is-registered.resp', mk_is_registered(registered => 1, slug => 'reg', cwd => $r->{cwd}));
    set_fixture($r->{fixture_dir}, 'list.resp', mk_snapshot_list(status => 'ok', count => 0));

    my $M = build_dm_marketplace();
    wjson("$r->{root}/global-config/settings.json", { enabledPlugins => { 'p@dm' => jtrue() } });
    wjson("$r->{home}/.claude/plugins/known_marketplaces.json", { dm => { source => { source => 'directory', path => $M } } });
    wjson("$r->{home}/.claude/plugins/installed_plugins.json", { plugins => {} });

    my $resp = run_closeout($r, {});
    is($resp->{exit}, 0, 'AC10 (B9): directory-served plugin with no install record -> run completes, no decision') or diag($resp->{out} . $resp->{err});
    is(scalar(closeout_decisions($resp)), 0, 'AC10 (B9): zero decisions') if ref($resp->{json}{decisions}) eq 'ARRAY';
    my $report = closeout_report_from_notes($resp->{json}{notes});
    if (ref($report) eq 'HASH') {
        is(scalar(@{ $report->{plugins}{missing} // ['x'] }), 0, 'AC10 (B9): report.plugins.missing is empty');
        my @plugin_fu = grep { ref($_) eq 'HASH' && (($_->{action} // '') eq 'install_plugin') } @{ $report->{follow_up_actions} // [] };
        is(scalar(@plugin_fu), 0, 'AC10 (B9): zero install_plugin follow-ups');
    } else {
        ok(0, 'AC10 (B9): report present (report missing)');
    }
}

# ===========================================================================
# B10 (AC11): remote-marketplace plugin whose only install record is
# project-scoped with projectPath equal to the run's pinned cwd -> no decision
# (proves Closeout passed --project).
# ===========================================================================
{
    my $r = setup_closeout_root();
    set_fixture($r->{fixture_dir}, 'is-registered.resp', mk_is_registered(registered => 1, slug => 'reg', cwd => $r->{cwd}));
    set_fixture($r->{fixture_dir}, 'list.resp', mk_snapshot_list(status => 'ok', count => 0));

    (my $matching_project_path = $r->{cwd}) =~ s{/}{\\}g;   # spec 4.3: cwd with every / replaced by \

    wjson("$r->{root}/global-config/settings.json", { enabledPlugins => { 'q@gm' => jtrue() } });
    wjson("$r->{home}/.claude/plugins/known_marketplaces.json", { gm => { source => { source => 'github', repo => 'o/r' } } });
    wjson("$r->{home}/.claude/plugins/installed_plugins.json",
        { plugins => { 'q@gm' => [ { scope => 'project', projectPath => $matching_project_path } ] } });

    my $resp = run_closeout($r, {});
    is($resp->{exit}, 0, 'AC11 (B10): matching-project install record -> run completes, no decision') or diag($resp->{out} . $resp->{err});
    is(scalar(closeout_decisions($resp)), 0, 'AC11 (B10): zero decisions (Closeout passed --project = pinned cwd)') if ref($resp->{json}{decisions}) eq 'ARRAY';
}

# ===========================================================================
# B11 (AC12): same plugin, install record for a DIFFERENT project -> exactly
# one plugin_install decision; id/kind/choices/data unchanged; detail and
# install label match the 2.2 template byte for byte.
# ===========================================================================
my ($b11_r, $b11_resp, $b11_decision_id);
{
    my $r = setup_closeout_root();
    set_fixture($r->{fixture_dir}, 'is-registered.resp', mk_is_registered(registered => 1, slug => 'reg', cwd => $r->{cwd}));
    set_fixture($r->{fixture_dir}, 'list.resp', mk_snapshot_list(status => 'ok', count => 0));

    wjson("$r->{root}/global-config/settings.json", { enabledPlugins => { 'q@gm' => jtrue() } });
    wjson("$r->{home}/.claude/plugins/known_marketplaces.json", { gm => { source => { source => 'github', repo => 'o/r' } } });
    wjson("$r->{home}/.claude/plugins/installed_plugins.json",
        { plugins => { 'q@gm' => [ { scope => 'project', projectPath => 'C:\\Some\\Other\\Project' } ] } });

    my $resp = run_closeout($r, {});
    is($resp->{exit}, 10, 'AC12 (B11): really-missing plugin -> run pauses (needs_decision)') or diag($resp->{out} . $resp->{err});
    my @decisions = closeout_decisions($resp);
    is(scalar(@decisions), 1, 'AC12 (B11): exactly one decision');
    if (@decisions) {
        my $d = $decisions[0];
        $b11_decision_id = $d->{id};
        like(($d->{id} // ''), qr/^closeout\.plugin_install\./, 'AC12 (B11): decision id has the closeout.plugin_install.<sanitised key> shape');
        is($d->{kind}, 'plugin_install', 'AC12 (B11): decision kind eq plugin_install');
        is_deeply_sorted([ map { $_->{id} } @{ $d->{choices} // [] } ], ['install', 'skip'], 'AC12 (B11): choices are exactly install/skip');
        is(($d->{data}{plugin} // ''), 'q@gm', 'AC12 (B11): data.plugin unchanged');
        is(($d->{data}{name} // ''), 'q', 'AC12 (B11): data.name unchanged');
        is(($d->{data}{marketplace} // ''), 'gm', 'AC12 (B11): data.marketplace unchanged');
        my $expected_command = '/plugin install q@gm';
        is(($d->{data}{command} // ''), $expected_command, 'AC12 (B11): data.command unchanged');

        my $expected_detail = "Claude Code cannot load 'q\@gm': no installed_plugins.json entry covers user scope or this project, and marketplace 'gm' does not serve it in place from a local directory. Installing it is a Claude Code client action that only you can take; the backup cannot run it. To install, type $expected_command at the Claude Code prompt (it is not a shell command).";
        is(($d->{detail} // ''), $expected_detail, 'AC12 (B11): detail equals the 2.2 template byte for byte');
        isnt(($d->{detail} // ''), $expected_command, 'AC12 (B11): detail ne data.command');
        like(($d->{detail} // ''), qr/only you can take/, 'AC12 (B11): detail contains "only you can take"');
        like(($d->{detail} // ''), qr/Claude Code prompt/, 'AC12 (B11): detail contains "Claude Code prompt"');

        my ($install_choice) = grep { ($_->{id} // '') eq 'install' } @{ $d->{choices} // [] };
        my $expected_label = "Install 'q\@gm' (you type /plugin install at the Claude Code prompt)";
        is(($install_choice->{label} // ''), $expected_label, 'AC12 (B11): install choice label equals the 2.2 template') if $install_choice;
        ok(0, 'AC12 (B11): install choice label equals the 2.2 template (choice missing)') unless $install_choice;
    } else {
        for (1 .. 9) { ok(0, 'AC12 (B11): decision fields (no decision present)'); }
    }
    $b11_r = $r;
    $b11_resp = $resp;
}

sub isnt {
    my ($got, $exp, $name) = @_;
    my $cond = !((defined $got && defined $exp && $got eq $exp) || (!defined $got && !defined $exp));
    ok($cond, $name) or diag("  got: " . (defined $got ? "[$got]" : 'undef'));
    return $cond;
}

# ===========================================================================
# B12 (AC13): answering 'install' on B11 and resuming -> run completes; report
# follow_up_actions holds one install_plugin entry with the unchanged shape.
# ===========================================================================
{
    if (defined $b11_decision_id) {
        my $resp2 = closeout_answer_and_resume($b11_r, $b11_resp, $b11_decision_id => 'install');
        is($resp2->{exit}, 0, 'AC13 (B12): resuming with "install" completes the run') or diag($resp2->{out} . $resp2->{err});
        my $report = closeout_report_from_notes($resp2->{json}{notes});
        if (ref($report) eq 'HASH') {
            my @install_actions = grep { ref($_) eq 'HASH' && (($_->{action} // '') eq 'install_plugin') } @{ $report->{follow_up_actions} // [] };
            is(scalar(@install_actions), 1, 'AC13 (B12): exactly one install_plugin follow-up');
            if (@install_actions) {
                is(($install_actions[0]{plugin} // ''), 'q@gm', 'AC13 (B12): follow-up plugin eq q@gm');
                is(($install_actions[0]{name} // ''), 'q', 'AC13 (B12): follow-up name eq q');
                is(($install_actions[0]{marketplace} // ''), 'gm', 'AC13 (B12): follow-up marketplace eq gm');
                is(($install_actions[0]{command} // ''), '/plugin install q@gm', 'AC13 (B12): follow-up command eq /plugin install q@gm');
            } else {
                for (1 .. 4) { ok(0, 'AC13 (B12): follow-up fields (entry missing)'); }
            }
        } else {
            ok(0, 'AC13 (B12): report present (report missing)');
        }
    } else {
        ok(0, 'AC13 (B12): resuming with "install" completes the run (B11 produced no decision id to answer)');
        for (1 .. 5) { ok(0, 'AC13 (B12): follow-up fields (B11 produced no decision id to answer)'); }
    }
}

# ===========================================================================
# AC14 -- SKILL.md: new wording present, old bare framing absent,
# check-plugins.pl still never named (backup-wrapper.t AC8's constraint, kept
# enforced here too).
# ===========================================================================
{
    my $skill = read_text($SKILL_MD) // '';
    like($skill, qr{\Q/plugin install\E}, 'AC14: SKILL.md plugin_install row mentions /plugin install');
    like($skill, qr/Claude Code prompt/, 'AC14: SKILL.md plugin_install row mentions "Claude Code prompt"');
    like($skill, qr/serve it in place/, 'AC14: SKILL.md plugin_install row mentions "serve it in place"');
    like($skill, qr/\*\*Relay\*\*/, 'AC14: SKILL.md install_plugin bullet still contains "**Relay**"');
    like($skill, qr/no install record for user scope or this project/, 'AC14: SKILL.md install_plugin bullet mentions the new reasoning');
    like($skill, qr/not in a shell/, 'AC14: SKILL.md install_plugin bullet says "not in a shell"');
    unlike($skill, qr/run it yourself/i, 'AC14: SKILL.md does not contain the bare "run it yourself" framing');
    unlike($skill, qr/run this yourself/i, 'AC14: SKILL.md does not contain the bare "run this yourself" framing');
    unlike($skill, qr/\bcheck-plugins\.pl\b/, 'AC14: SKILL.md never names check-plugins.pl');
}

# ===========================================================================
# AC16 -- hermetic: the real HOME/USERPROFILE string never appears in any
# captured stdout from this file's own scenarios.
# ===========================================================================
{
    my @leaks;
    for my $real (grep { defined && length } ($REAL_HOME, $REAL_USERPROFILE)) {
        # Guard against a degenerate real HOME like '/' or 'C:' matching everything.
        next unless length($real) > 3;
        push @leaks, $real if defined($b11_resp->{out}) && index($b11_resp->{out}, $real) >= 0;
    }
    is(scalar(@leaks), 0, 'AC16: the real HOME/USERPROFILE string never appears in captured Closeout stdout')
        or diag(join(', ', @leaks));
}

done_testing();
