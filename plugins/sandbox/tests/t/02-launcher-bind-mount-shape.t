#!/usr/bin/env perl
# Pins the launcher's post-refactor mount layout: /root/.claude is a
# host bind of <project>/.ccpraxis-local-data/claude-home ($CLAUDE_DATA),
# not a volume. /root/.claude.json is NOT a single-file bind: the global
# config lives at /root/.claude/.claude.json, an ordinary file inside the
# /root/.claude dir bind, reached via CLAUDE_CONFIG_DIR=/root/.claude (an
# uninterpolated -e literal on `podman create`) so atomic temp+rename
# writes succeed there (s01 probe-01 Case A/B; spec 02-implement-config-
# safety-spec.md B1/B6/B7). statusline.pl is the only ro bind remaining
# inside /root/.claude/. No CLAUDE_DATA_VOLUME references survive.
#
# TWO TIERS:
#
# 1. Source-text tier (unchanged in spirit from the original file): slurps
#    launcher.pl + MountSpec.pm CONCATENATED, because the claude-home
#    create-args block now lives in MountSpec::claude_home_create_args,
#    not inline in launcher.pl (spec sec 2.1). All 18 original assertion
#    texts/regexes stay verbatim; only the /root/.claude.json single-file
#    bind assertion inverts from like to unlike.
#
# 2. Structural-guard tier (spec sec 2.1, s01 row 11): asserts over the
#    GENERATED arg list, not source text — MountSpec::claude_home_create_args
#    -> convert_v_to_mount -> MountSpec::parse_create_args ->
#    MountSpec::audit_claude_home. Those four subs (claude_home_create_args,
#    parse_create_args, parse_inspect_lines, audit_claude_home) do not exist
#    yet as of this writing: this file is written spec-first, ahead of the
#    MountSpec.pm implementation, so every assertion in tier 2 is EXPECTED
#    to fail right now with a diagnostic naming the missing sub. Tier 1's
#    17 untouched assertions keep passing; the inverted .claude.json
#    assertion in tier 1 (and the two new source-text assertions B6/B7 at
#    the bottom) also legitimately fail right now, because launcher.pl
#    still contains the old single-file bind and no CLAUDE_CONFIG_DIR -e
#    literal yet. That is not a bug in this test — it is the oracle.
#
# This file must run with NO container runtime present and must not
# `use TestSandbox` (B36).

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use File::Temp qw(tempdir tempfile);
use MountSpec qw(winify_path v_to_mount convert_v_to_mount);

plan tests => 50;

my $launcher      = "$Bin/../../scripts/launcher.pl";
my $mountspec_pm  = "$Bin/../../scripts/MountSpec.pm";
ok(-f $launcher, 'launcher.pl present') or BAIL_OUT;
ok(-f $mountspec_pm, 'MountSpec.pm present') or BAIL_OUT;

sub _slurp {
    my ($path) = @_;
    open my $fh, '<', $path or BAIL_OUT("open $path: $!");
    local $/;
    return <$fh>;
}

# Mandatory two-file slurp mitigation (spec sec 2.1): the claude-home
# block's literal mount strings moved into MountSpec.pm, so a source-text
# tier reading only launcher.pl would go blind to them.
my $src = _slurp($launcher) . "\n" . _slurp($mountspec_pm);

# ---------------------------------------------------------------------
# Tier 1: source-text assertions (18 original, texts/regexes verbatim).
# ---------------------------------------------------------------------

# 1. /root/.claude is bound from ${CLAUDE_DATA} (.ccpraxis-local-data/claude-home).
like($src, qr{'-v',\s*"\$\{CLAUDE_DATA\}:/root/\.claude"}m,
     '/root/.claude is a host bind mount of claude-home');

# 2. .launcher overlays the claude-home bind as RO. Defense-in-depth:
# a compromised in-container process can't fake backpack-trusted-hash,
# corrupt the snapshot files, or scribble on launcher metadata.
like($src, qr{'-v',\s*"\$\{LAUNCHER_DIR\}:/root/\.claude/\.launcher:ro"}m,
     '.launcher is overlaid as RO over /root/.claude/.launcher');

# 3. .credentials.json is NO LONGER a single-file bind (Fix 1). It lives at
# claude-home/.credentials.json and rides the ${CLAUDE_DATA} dir bind as a
# real file, so atomic temp+rename writes (how Claude Code / butler persist
# an OAuth refresh) succeed — a single-file bind rejected rename-over-mount
# (EBUSY) and the refreshed token could never be saved.
like($src, qr{\$SANDBOX_CREDENTIALS_FILE\s*=\s*"\$CLAUDE_DATA/\.credentials\.json"}m,
     'sandbox creds path is claude-home/.credentials.json (rides the RW dir bind)');
unlike($src, qr{:/root/\.claude/\.credentials\.json"}m,
       'no single-file bind onto /root/.claude/.credentials.json (rename-safe dir bind instead)');

# 4. /root/.claude.json is NOT a single-file bind (B34): same shape decision
# as .credentials.json above — INVERTED from the original `like`. Same
# regex, verbatim, per spec sec 2.1 ("only the one at :43 inverts").
unlike($src, qr{'-v',\s*"\$\{CLAUDE_DATA\}/\.claude\.json:/root/\.claude\.json"}m,
       'no single-file bind onto /root/.claude.json');

# 5. statusline.pl ro bind is still there.
like($src, qr{statusline\.pl:/root/\.claude/statusline\.pl:ro}m,
     'statusline.pl ro bind survives');

# 6. No CLAUDE_DATA_VOLUME variable or function references survive.
unlike($src, qr/CLAUDE_DATA_VOLUME/,
       'no CLAUDE_DATA_VOLUME references remain');

# 7. No volume-management helpers survive.
unlike($src, qr/ensure_claude_data_volume|seed_claude_data_volume|rescue_volume_to_host|sync_claude_data_volume|apply_blueprints_to_volume/,
       'volume helpers (ensure/seed/rescue/sync/apply_to_volume) are gone');

# --- Fix 2: two-tier plugin store (COPY model — host plugins copied in, never mounted) ---

# 8. installed_plugins.json is a REAL RW file under claude-home/plugins/ (Fix 2),
# no longer a single-file RO bind — Claude Code rewrites it on in-container install.
like($src, qr{\$MATERIALIZED_PLUGINS_FILE\s*=\s*"\$CLAUDE_DATA/plugins/installed_plugins\.json"}m,
     'installed_plugins.json materializes to claude-home/plugins/ (real RW file)');
unlike($src, qr{:/root/\.claude/plugins/installed_plugins\.json:ro},
       'no single-file RO bind onto installed_plugins.json');

# 9. The host plugin dirs are COPIED in, NOT mounted: no cache/ mount and no
# blanket marketplaces/ mount (the host is never mounted into the container).
unlike($src, qr{\$HOST_PLUGINS_DIR/cache:/root/\.claude/plugins/cache}m,
       'plugins/cache is NOT mounted (copied into claude-home instead)');
unlike($src, qr{\$HOST_PLUGINS_DIR/marketplaces:/root/\.claude/plugins/marketplaces:}m,
       'no blanket plugins/marketplaces mount (copied into claude-home instead)');

# 10. No overlay (`:O`) mounts anywhere, and the overlay/volume helper is gone.
unlike($src, qr{:O,upperdir=}, 'no :O overlay mounts remain');
unlike($src, qr/ensure_plugin_overlay/, 'ensure_plugin_overlay helper is gone (no volume)');

# 11. The copy model: sync_copy_plan reconcile + the copy-plan manifests.
like($src, qr/sub sync_copy_plan/m,
     'sync_copy_plan reconcile helper present (copy model)');
like($src, qr/\$PLUGINS_COPY_MANIFEST\s*=\s*"\$LAUNCHER_DIR/m,
     'plugins copy-plan manifest lives in .launcher/ (RO in container — control protected)');

# 12. Directory-source marketplaces (ccpraxis-local) stay a LIVE read-only bind.
like($src, qr{\$\{host_path\}:\$\{container_path\}:ro}m,
     'directory-source marketplaces keep their live read-only bind');

# ---------------------------------------------------------------------
# Tier 2: structural guard over the GENERATED arg list (B1-B11, B17).
# claude_home_create_args / parse_create_args / parse_inspect_lines /
# audit_claude_home are new MountSpec.pm exports that do not exist yet.
# Every block below is guarded with MountSpec->can(...) so a missing sub
# is a clean per-assertion `fail()` naming it, never a compile/runtime
# abort that would take the rest of this file down with it.
# ---------------------------------------------------------------------

sub _missing_subs {
    my @required = @_;
    return join(', ', map { "MountSpec::$_" }
                       grep { !MountSpec->can($_) } @required);
}

my $HAVE_BUILDER = !!MountSpec->can('claude_home_create_args');
my $HAVE_PARSE   = !!MountSpec->can('parse_create_args');
my $HAVE_AUDIT   = !!MountSpec->can('audit_claude_home');
my $HAVE_INSPECT = !!MountSpec->can('parse_inspect_lines');
my $HAVE_PIPELINE = $HAVE_BUILDER && $HAVE_PARSE && $HAVE_AUDIT;

# Real temp paths, so the auditor's default `is_file` predicate (`-f`)
# classifies sources the way it will in production. Cleaned up
# automatically: tempdir/tempfile CLEANUP/UNLINK => 1 removes them at
# process exit.
my $claude_data  = tempdir(CLEANUP => 1);
my $launcher_dir = "$claude_data/.launcher";
mkdir $launcher_dir or BAIL_OUT("mkdir $launcher_dir: $!");
my ($sfh, $statusline) = tempfile(SUFFIX => '.pl', UNLINK => 1);
print {$sfh} "#!/usr/bin/env perl\n1;\n";
close $sfh;

# A real file source for B8's positive control (an added writable
# single-file bind under /root/.claude/).
my $foo_json = "$claude_data/foo.json";
open my $ffh, '>', $foo_json or BAIL_OUT("write $foo_json: $!");
print {$ffh} "{}\n";
close $ffh;

# A real file source for B9's "existing source" sub-case.
my $existing_claude_json = "$claude_data/existing.claude.json";
open my $ejfh, '>', $existing_claude_json or BAIL_OUT("write $existing_claude_json: $!");
print {$ejfh} qq({"marker":"pre-existing"}\n);
close $ejfh;

sub _pipeline {
    my @raw_args = @_;
    my @converted = convert_v_to_mount(@raw_args);
    my $parsed = MountSpec::parse_create_args(\@converted);
    my @violations = MountSpec::audit_claude_home($parsed);
    return ($parsed, \@violations);
}

# --- B1/AC1: exact ordered arg list; no element contains /root/.claude.json ---
if ($HAVE_BUILDER) {
    my @args_a = eval { MountSpec::claude_home_create_args(
        claude_data  => '/H/claude-home',
        launcher_dir => '/H/claude-home/.launcher',
        statusline   => '/H/s.pl',
    ) };
    if ($@) {
        fail("B1/AC1: claude_home_create_args died unexpectedly: $@") for 1 .. 2;
    } else {
        my @expected = (
            '-e', 'CLAUDE_CONFIG_DIR=/root/.claude',
            '-v', '/H/claude-home:/root/.claude',
            '-v', '/H/claude-home/.launcher:/root/.claude/.launcher:ro',
            '-v', '/H/s.pl:/root/.claude/statusline.pl:ro',
        );
        is_deeply(\@args_a, \@expected,
            'B1/AC1: claude_home_create_args returns the exact ordered arg list');
        ok(!(grep { index($_, '/root/.claude.json') >= 0 } @args_a),
            'B1/AC1: no element of claude_home_create_args contains /root/.claude.json');
    }
} else {
    fail('B1/AC1: claude_home_create_args (' . _missing_subs('claude_home_create_args') . ' not implemented yet)') for 1 .. 2;
}

# --- B2: dies with a message naming the missing/empty option ---
if ($HAVE_BUILDER) {
    my %valid = (
        claude_data  => '/H/claude-home',
        launcher_dir => '/H/claude-home/.launcher',
        statusline   => '/H/s.pl',
    );
    for my $opt (qw(claude_data launcher_dir statusline)) {
        for my $case (
            ['missing', sub { my %h = %valid; delete $h{$opt}; return %h }],
            ['empty',   sub { my %h = %valid; $h{$opt} = '';   return %h }],
        ) {
            my ($label, $mutate) = @$case;
            my %args = $mutate->();
            eval { MountSpec::claude_home_create_args(%args) };
            like($@ // '', qr/\Q$opt\E/i,
                "B2: claude_home_create_args dies naming '$opt' when it is $label");
        }
    }
} else {
    fail('B2: claude_home_create_args (' . _missing_subs('claude_home_create_args') . ' not implemented yet)') for 1 .. 6;
}

# --- B3/B4/B5 (AC2/AC3/AC7): compliant block through the full pipeline ---
if ($HAVE_PIPELINE) {
    my @base_args = eval { MountSpec::claude_home_create_args(
        claude_data  => $claude_data,
        launcher_dir => $launcher_dir,
        statusline   => $statusline,
    ) };
    if ($@ || !@base_args) {
        fail("B3/B4/B5: claude_home_create_args died building the base block: $@") for 1 .. 6;
    } else {
        my ($parsed, $viol) = _pipeline(@base_args);

        is(scalar(@$viol), 0,
            'B3/AC2: compliant claude-home block yields zero audit violations')
            or diag(explain($viol));

        my $env_vals = $parsed->{env}{CLAUDE_CONFIG_DIR} // [];
        is(scalar(@$env_vals), 1,
            'B4/AC3: exactly one CLAUDE_CONFIG_DIR key in the parsed env');
        is(($env_vals->[0] // '(undef)'), '/root/.claude',
            'B4/AC3: CLAUDE_CONFIG_DIR value is exactly /root/.claude');

        my ($claude_mount) = grep { $_->{target} eq '/root/.claude' } @{ $parsed->{mounts} };
        ok($claude_mount
            && $claude_mount->{type} eq 'bind'
            && $claude_mount->{source} eq $claude_data
            && !$claude_mount->{readonly},
            'B5/AC7: /root/.claude bind is type=bind, source=claude_data, NOT readonly')
            or diag(explain($claude_mount));

        my ($launcher_mount) = grep { $_->{target} eq '/root/.claude/.launcher' } @{ $parsed->{mounts} };
        ok($launcher_mount && $launcher_mount->{readonly},
            'B5: /root/.claude/.launcher mount is readonly')
            or diag(explain($launcher_mount));

        my ($statusline_mount) = grep { $_->{target} eq '/root/.claude/statusline.pl' } @{ $parsed->{mounts} };
        ok($statusline_mount && $statusline_mount->{readonly},
            'B5: /root/.claude/statusline.pl mount is readonly')
            or diag(explain($statusline_mount));
    }
} else {
    fail('B3/B4/B5: pipeline (' . _missing_subs(qw(claude_home_create_args parse_create_args audit_claude_home)) . ' not implemented yet)') for 1 .. 6;
}

# --- B8 (AC6, positive control): extra writable single-file bind under /root/.claude ---
if ($HAVE_PIPELINE) {
    my @base_args = eval { MountSpec::claude_home_create_args(
        claude_data  => $claude_data,
        launcher_dir => $launcher_dir,
        statusline   => $statusline,
    ) };
    if ($@ || !@base_args) {
        fail("B8: claude_home_create_args died building the base block: $@") for 1 .. 2;
    } else {
        my @args_d = (@base_args, '-v', "$foo_json:/root/.claude/foo.json");
        my ($parsed_d, $viol_d) = _pipeline(@args_d);
        is(scalar(@$viol_d), 1,
            'B8/AC6: extra writable file bind under /root/.claude yields exactly one violation')
            or diag(explain($viol_d));
        is((($viol_d->[0] // {})->{code} // '(none)'), 'writable_single_file_bind',
            'B8/AC6: that violation is coded writable_single_file_bind');
    }
} else {
    fail('B8: pipeline (' . _missing_subs(qw(claude_home_create_args parse_create_args audit_claude_home)) . ' not implemented yet)') for 1 .. 2;
}

# --- B9 (AC6, positive control): mount destined at /root/.claude.json, source existing or not ---
if ($HAVE_PARSE && $HAVE_AUDIT) {
    for my $case (
        { label => 'nonexistent source', json => "$claude_data/does-not-exist.json" },
        { label => 'existing source',    json => $existing_claude_json },
    ) {
        my @args_e = ('-v', "$case->{json}:/root/.claude.json");
        my ($parsed_e, $viol_e) = _pipeline(@args_e);
        ok((grep { $_->{code} eq 'claude_json_mount' } @$viol_e),
            "B9/AC6: -v .../.claude.json ($case->{label}) yields claude_json_mount violation")
            or diag(explain($viol_e));
    }
} else {
    fail('B9: (' . _missing_subs(qw(parse_create_args audit_claude_home)) . ' not implemented yet)') for 1 .. 2;
}

# --- B10 (AC3, positive controls): CLAUDE_CONFIG_DIR duplicate / wrong / missing ---
if ($HAVE_PARSE && $HAVE_AUDIT) {
    my @compliant_mount = ('-v', "$claude_data:/root/.claude");
    my %cases = (
        duplicate            => [ @compliant_mount, '-e', 'CLAUDE_CONFIG_DIR=/root/.claude',
                                                      '-e', 'CLAUDE_CONFIG_DIR=/root/.claude' ],
        wrong_trailing_slash => [ @compliant_mount, '-e', 'CLAUDE_CONFIG_DIR=/root/.claude/' ],
        wrong_empty          => [ @compliant_mount, '-e', 'CLAUDE_CONFIG_DIR=' ],
        missing              => [ @compliant_mount ],
    );
    my %expect_code = (
        duplicate            => 'config_dir_env_duplicate',
        wrong_trailing_slash => 'config_dir_env_wrong',
        wrong_empty          => 'config_dir_env_wrong',
        missing              => 'config_dir_env_missing',
    );
    for my $case (sort keys %cases) {
        my ($parsed_f, $viol_f) = _pipeline(@{ $cases{$case} });
        ok((grep { $_->{code} eq $expect_code{$case} } @$viol_f),
            "B10/AC3: CLAUDE_CONFIG_DIR case '$case' yields $expect_code{$case}")
            or diag(explain($viol_f));
    }
} else {
    fail('B10: (' . _missing_subs(qw(parse_create_args audit_claude_home)) . ' not implemented yet)') for 1 .. 4;
}

# --- B11 (AC6, negative control): :ro single-file bind onto statusline.pl -> no violation ---
if ($HAVE_PARSE && $HAVE_AUDIT) {
    my @args_g = ('-v', "$statusline:/root/.claude/statusline.pl:ro");
    my ($parsed_g, $viol_g) = _pipeline(@args_g);
    ok(!(grep { $_->{code} eq 'writable_single_file_bind' } @$viol_g),
        'B11/AC6: :ro single-file bind onto /root/.claude/statusline.pl yields no writable_single_file_bind violation')
        or diag(explain($viol_g));
} else {
    fail('B11: (' . _missing_subs(qw(parse_create_args audit_claude_home)) . ' not implemented yet)') for 1 .. 1;
}

# --- B17 (AC8): parse_inspect_lines + audit_claude_home over canned podman-inspect lines ---
if ($HAVE_INSPECT && $HAVE_AUDIT) {
    my @old_lines = (
        "MOUNT bind $claude_data /root/.claude true",
        "MOUNT bind $launcher_dir /root/.claude/.launcher false",
        "MOUNT bind $claude_data/.claude.json /root/.claude.json true",
        "MOUNT bind $statusline /root/.claude/statusline.pl false",
    );
    my $parsed_old = MountSpec::parse_inspect_lines(\@old_lines);
    my @viol_old = MountSpec::audit_claude_home($parsed_old);
    is_deeply([ sort map { $_->{code} } @viol_old ],
               [ sort qw(claude_json_mount config_dir_env_missing) ],
               'B17/AC8: old-shape inspect lines yield claude_json_mount + config_dir_env_missing')
        or diag(explain(\@viol_old));

    my @new_lines = (
        "MOUNT bind $claude_data /root/.claude true",
        "MOUNT bind $launcher_dir /root/.claude/.launcher false",
        "MOUNT bind $statusline /root/.claude/statusline.pl false",
        "ENV CLAUDE_CONFIG_DIR=/root/.claude",
    );
    my $parsed_new = MountSpec::parse_inspect_lines(\@new_lines);
    my @viol_new = MountSpec::audit_claude_home($parsed_new);
    is(scalar(@viol_new), 0,
        'B17/AC8: new-shape inspect lines yield no violations')
        or diag(explain(\@viol_new));
} else {
    fail('B17/AC8: (' . _missing_subs(qw(parse_inspect_lines audit_claude_home)) . ' not implemented yet)') for 1 .. 2;
}

# ---------------------------------------------------------------------
# Source-text tier, widened (B6, B7 / AC4): counts over the SAME
# concatenated $src used by tier 1. These are plain regexes, not
# guarded — they currently fail honestly because launcher.pl hasn't
# been changed yet (old bind still present, no -e literal yet).
# ---------------------------------------------------------------------

# B6/AC4: the substring ":/root/.claude.json" occurs zero times across
# launcher.pl + MountSpec.pm.
my $claude_json_bind_occurrences = () = $src =~ /:\/root\/\.claude\.json/g;
is($claude_json_bind_occurrences, 0,
    'B6/AC4: the substring ":/root/.claude.json" occurs nowhere in launcher.pl + MountSpec.pm');

# B7/AC4: '-e', 'CLAUDE_CONFIG_DIR=/root/.claude' occurs exactly once,
# single-quoted (uninterpolated), no `$` in the value.
my $config_dir_e_occurrences = () = $src =~ /'-e',\s*'CLAUDE_CONFIG_DIR=\/root\/\.claude'/g;
is($config_dir_e_occurrences, 1,
    "B7/AC4: '-e', 'CLAUDE_CONFIG_DIR=/root/.claude' (single-quoted literal) appears exactly once");

# ---------------------------------------------------------------------
# Row-22 wiring tier (B12, B18 / AC9-AC11). The shape check's BEHAVIOUR
# (reap a stopped mismatched container, refuse a running one) needs a real
# container runtime and so cannot be exercised here — that half is host-only
# and is recorded as a known coverage gap. What IS checkable in-container is
# the wiring, and the wiring is where the s01 §4 sequencing hazard lives:
# a check that runs too late, or that routes through the DECLINABLE staleness
# prompt, silently leaves every existing sandbox on the old bug-carrying shape.
# ---------------------------------------------------------------------

# B12/AC9: the shape check exists and is CALLED before the launcher branches
# on container existence. A call placed after the first `_container_exists`
# would route a reaped container down the ATTACH path with no port block.
ok($src =~ /sub\s+enforce_container_config_shape\b/,
    'B12/AC9: enforce_container_config_shape() is defined');
# Positions are computed over a COMMENT-STRIPPED copy. Matching raw $src is
# tautological: `# enforce_container_config_shape($name) -> void` is a comment
# at launcher.pl:1188, so the regex would find prose and pass even if the real
# call were deleted outright. (Caught by redteam-08 finding M1 against an
# earlier version of this assertion.)
my $code = $src;
$code =~ s/^[ \t]*#.*$//mg;
my ($enforce_call_pos)  = $code =~ /(?<!sub )(?=enforce_container_config_shape\s*\()/ ? $-[0] : undef;
my ($first_exists_pos)  = $code =~ /(?=if\s*\(\s*!\s*_container_exists)/     ? $-[0] : undef;
ok(defined $enforce_call_pos && defined $first_exists_pos
   && $enforce_call_pos < $first_exists_pos,
    'B12/AC10: enforce_container_config_shape() is invoked BEFORE the first `if (! _container_exists(...))` branch');

# B18/AC11: the check must never be routed through prompt_stale_action —
# that prompt defaults to "continue" and returns "continue" on EOF in every
# non-interactive launch, which would make the fix declinable by accident.
my ($enforce_body) = $src =~ /sub\s+enforce_container_config_shape\b(.*?)\n\}/s;
$enforce_body = '' unless defined $enforce_body;
ok(length($enforce_body) && $enforce_body !~ /prompt_stale_action|\@STALE_REASONS/,
    'B18/AC11: the shape check has a body and never routes through the declinable staleness prompt');

# B12/AC10 (redteam H1): "before the create-vs-attach branch" is NOT sufficient.
# launcher.pl has an EARLY dispatch that sends an already-running container
# straight into enter_dashboard(), which calls ensure_claude_json_onboarded()
# — a function that can rename() over the shared host config. A shape check
# placed only further down is dead code on that path, and renaming the host
# config while an OLD-shape container is still attached is exactly the s01 §4
# ghost-inode data loss (the container keeps following the unlinked inode).
# So the check must also precede the dashboard fast path.
my ($dashboard_call_pos) = $code =~ /(?=enter_dashboard\s*\(\s*\)\s*;)/ ? $-[0] : undef;
ok(defined $enforce_call_pos && defined $dashboard_call_pos
   && $enforce_call_pos < $dashboard_call_pos,
    'B12/AC10: the shape check runs BEFORE the early-dispatch enter_dashboard() fast path (redteam H1)');
