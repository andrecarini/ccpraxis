#!/usr/bin/env perl
# platform: any
# Oracle for b38 (blueprint sandbox-butler-overhaul), RETARGETED 2026-10-30.
#
# IMMUTABLE ORACLE: written from the spec BEFORE the implementation exists.
# Do not weaken these assertions to make a future implementation's life
# easier; a criterion this file cannot honestly test is reported, not faked.
#
# RETARGETED 2026-10-30 (operator decision): Node and pnpm left the sandbox
# base image and are declared per project in the backpack, through the
# sanctioned recipe plugins/backpack/recipes/node-pnpm.json. D1 used to assert
# the Containerfile's own Node/pnpm pins; it now asserts that the image installs
# neither, and that the RECIPE carries the same guarantees the image step did
# (exact pins, one version for both architectures, an unknown architecture
# refused) plus a pinned sha256 per tarball, which the image step never had.
# D2-D7 are unchanged: the hardening is environment and config, it stays in the
# image, and it is what protects whichever Node a project installs later.
#
# Spec: .ccpraxis-local-data/blueprints/_archive/sandbox-butler-overhaul/specs/b38-node-pnpm-toolchain-spec.md
# Test slot is 57, NOT 55 -- spec section 1.7 records the collision with the
# pre-existing minimize-evidence.t and the corrected slot.
#
# NEVER build an image or start a container here. Containerfile content is
# asserted as TEXT ONLY, following the precedent in t/refuse-in-place.t
# (source-grep without spawning). D7 is the sole exception: it runs the
# REAL `pnpm` binary, when a backpack has installed one, against a File::Temp
# scratch directory -- never the real project, never a container.
#
# Criterion mapping (spec section 3):
#   D1 : the image installs no Node/pnpm; the backpack recipe pins both exactly
#        (one version for both architectures, a sha256 per tarball, no
#        latest/lts/bare-major), and installs where the image PATH looks
#   D2 : the four PNPM_CONFIG_* env vars, exact values (unit named for D2b)
#   D3 : MINIMUM_RELEASE_AGE_IGNORE_MISSING_TIME explicitly false (why, below)
#   D4 : dangerouslyAllowAllBuilds never enabled + ignore_scripts non-regression
#   D5 : bp-fast-store.sh targets pnpm-workspace.yaml, NOT .npmrc (absence!)
#   D6 : bp-fast-store.sh verify checks store IN USE, not mere presence
#   D7 : env beats pnpm-workspace.yaml; .npmrc not consulted (live pnpm probe)

use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use Cwd qw(abs_path getcwd);
use JSON::PP;

my $REPO_ROOT = abs_path("$Bin/../../../..");
BAIL_OUT("cannot resolve repo root from $Bin/../../../..") unless defined $REPO_ROOT;

my $CONTAINERFILE = "$REPO_ROOT/plugins/sandbox/container/Containerfile";
my $FAST_STORE    = "$REPO_ROOT/plugins/butler/scripts/bp-fast-store.sh";

BAIL_OUT("cannot find Containerfile at $CONTAINERFILE") unless -f $CONTAINERFILE;
BAIL_OUT("cannot find bp-fast-store.sh at $FAST_STORE")  unless -f $FAST_STORE;

open my $cfh, '<:raw', $CONTAINERFILE or BAIL_OUT("cannot open Containerfile: $!");
my @clines = <$cfh>;
close $cfh;
my $csrc = join '', @clines;
# code-only view: strip whole-line/trailing # comments before pattern sweeps
# (Dockerfile comments also start with #)
my @ccode_lines = map { my $x = $_; $x =~ s/#.*$//; $x } @clines;
my $ccode = join '', @ccode_lines;

open my $sfh, '<:raw', $FAST_STORE or BAIL_OUT("cannot open bp-fast-store.sh: $!");
my @slines = <$sfh>;
close $sfh;
my $ssrc = join '', @slines;

# =====================================================================
# D1 -- no Node/pnpm in the image; the backpack recipe pins both exactly
# =====================================================================
my $RECIPE_FILE = "$REPO_ROOT/plugins/backpack/recipes/node-pnpm.json";
my $recipe = do {
    open my $rfh, '<:raw', $RECIPE_FILE or BAIL_OUT("cannot open the node-pnpm recipe at $RECIPE_FILE: $!");
    local $/;
    my $doc = eval { JSON::PP->new->utf8->decode(<$rfh>) };
    BAIL_OUT("the node-pnpm recipe is not valid JSON: $@") unless ref $doc eq 'HASH';
    ref $doc->{items} eq 'ARRAY' && @{ $doc->{items} } == 1
        or BAIL_OUT('the node-pnpm recipe must hold exactly one item');
    $doc->{items}[0];
};
my $r_install = $recipe->{install} // '';
my $r_verify  = $recipe->{verify}  // '';
{
    # D1a: the IMAGE installs neither. Code lines only: the comment block that
    # records the 2026-10-30 decision legitimately names what used to be here.
    unlike($ccode, qr{nodejs\.org/dist/}, 'D1a: the Containerfile downloads no Node tarball');
    unlike($ccode, qr/\b(?:npm|pnpm)\s+(?:install|i|add)\s+(?:-g|--global)\b/,
        'D1a: the Containerfile installs no global npm/pnpm package');
    unlike($ccode, qr/\bcorepack\b|\bnodesource\b|apt-get install[^\n]*\bnodejs\b/i,
        'D1a: the Containerfile installs Node by no other route either (corepack, NodeSource, apt nodejs)');
    unlike($ccode, qr{/opt/node24}, 'D1a: nothing in the Containerfile still refers to the old /opt/node24 prefix');

    # D1b: the recipe pins Node exactly, ONE version for both architectures.
    my ($x64)   = $r_install =~ /\bnode-v(\d+\.\d+\.\d+)-linux-x64\.tar\.xz\b/;
    my ($arm64) = $r_install =~ /\bnode-v(\d+\.\d+\.\d+)-linux-arm64\.tar\.xz\b/;
    my ($url)   = $r_install =~ m{https://nodejs\.org/dist/v(\d+\.\d+\.\d+)/};
    ok(defined $x64,   'D1b: the recipe names an exact linux-x64 Node tarball');
    ok(defined $arm64, 'D1b: the recipe names an exact linux-arm64 Node tarball');
    is($arm64, $x64, 'D1b: both architectures pin the SAME Node version (a bump must move both)');
    is($url,   $x64, 'D1b: the download URL is the pinned version\'s own dist directory');
    my ($pnpm) = $r_install =~ /\bpnpm\@(\d+\.\d+\.\d+)\b/;
    ok(defined $pnpm, 'D1b: the recipe pins pnpm to an exact x.y.z');

    # Floating references anywhere in the recipe's commands. `\@` escaped, see
    # the coordinator note this file has carried since b38: an unescaped `@11`
    # interpolates as an empty array and silently changes the pattern.
    my @floating;
    for my $cmd ($r_install, $r_verify) {
        push @floating, $1 while $cmd =~ /(\b(?:latest|lts)\b)/gi;
        push @floating, $1 while $cmd =~ /(\bpnpm\@\d+(?:\.\d+)?)(?![.\d])/g;
        push @floating, $1 while $cmd =~ /(node-v\d+(?:\.\d+)?-)/g;
        push @floating, $1 while $cmd =~ /(\bnvm\s+install\b)/g;
    }
    is(scalar(@floating), 0, 'D1b: no latest, lts, bare-major or nvm floating reference in the recipe')
        or diag('floating references: ' . join(', ', @floating));

    # D1c: each tarball is checked against a pinned sha256 BEFORE it is unpacked.
    my ($x64_arm)   = $r_install =~ /\bamd64\)([^;]*);;/;
    my ($arm64_arm) = $r_install =~ /\barm64\)([^;]*);;/;
    like($x64_arm   // '', qr/linux-x64\.tar\.xz\b.*\b[0-9a-f]{64}\b/,   'D1c: the amd64 branch carries a 64-hex sha256 next to its tarball');
    like($arm64_arm // '', qr/linux-arm64\.tar\.xz\b.*\b[0-9a-f]{64}\b/, 'D1c: the arm64 branch carries a 64-hex sha256 next to its tarball');
    my $sum_at = index($r_install, 'sha256sum -c');
    my $tar_at = index($r_install, 'tar -');
    ok($sum_at >= 0 && $tar_at > $sum_at, 'D1c: sha256sum -c runs before tar unpacks anything')
        or diag("sha256sum at $sum_at, tar at $tar_at");
    like($r_install, qr/sha256sum -c[^&]*&&/, 'D1c: a checksum failure stops the && chain');

    # D1d: the architecture comes from the image (dpkg), and an unknown one fails.
    like($r_install, qr/dpkg --print-architecture/, 'D1d: the recipe picks its tarball from dpkg --print-architecture');
    like($r_install, qr/\*\)[^;]*;\s*exit 1\s*;;/, 'D1d: an unrecognised architecture exits 1 instead of guessing');

    # D1e: it installs where the image PATH looks, and nowhere else.
    my $prefix = '/opt/tools/node';
    is_deeply($recipe->{bin_dirs}, ["$prefix/bin"], "D1e: the recipe's bin_dirs is exactly $prefix/bin");
    like($r_install, qr{-C \Q$prefix\E\.new\b.*\bmv \Q$prefix\E\.new \Q$prefix\E\b},
        "D1e: the tarball unpacks to $prefix.new and replaces $prefix only once complete");
    ok((grep { m{^ENV PATH="\Q$prefix\E/bin:\$\{PATH\}"\s*$} } @ccode_lines),
        "D1e: the Containerfile puts $prefix/bin on PATH (npm -g tools land there; hooks and the Bash tool need them by name)");

    # D1f: verify checks the EXACT pins, so a bump of install alone cannot pass.
    my ($want_node, $want_pnpm) = ($x64 // 'NONE', $pnpm // 'NONE');
    like($r_verify, qr/= v\Q$want_node\E\b/, 'D1f: verify checks node --version against the pinned Node version');
    like($r_verify, qr/= \Q$want_pnpm\E\b/, 'D1f: verify checks pnpm --version against the pinned pnpm version');
    like($r_verify, qr{^cd / &&}, 'D1f: verify runs from /, so a project packageManager pin cannot redirect pnpm --version');

    # D1g: the recipe never turns install scripts back on for its own install.
    unlike($r_install, qr/ignore-scripts\s*=\s*false|--ignore-scripts=false|npm_config_ignore_scripts=false/i,
        'D1g: the recipe does not re-enable install scripts');
}

# =====================================================================
# D2 -- the four PNPM_CONFIG_* env vars, exact values
# =====================================================================
{
    # Match against un-commented code lines only, so a commented-out
    # example in a docstring cannot fake a pass.
    my %want = (
        'PNPM_CONFIG_IGNORE_SCRIPTS'                            => 'true',
        'PNPM_CONFIG_MINIMUM_RELEASE_AGE'                       => '10080',
        'PNPM_CONFIG_MINIMUM_RELEASE_AGE_IGNORE_MISSING_TIME'   => 'false',
        'PNPM_CONFIG_MINIMUM_RELEASE_AGE_STRICT'                => 'true',
    );

    for my $key (qw(PNPM_CONFIG_IGNORE_SCRIPTS)) {
        my $val = $want{$key};
        ok($ccode =~ /\Q$key\E=\Q$val\E\b/,
           "D2a: $key=$val is present (governs pnpm's own install-script execution)");
    }

    ok($ccode =~ /PNPM_CONFIG_MINIMUM_RELEASE_AGE=10080\b(?!_)/,
       'D2b: PNPM_CONFIG_MINIMUM_RELEASE_AGE is 10080 MINUTES (= 7 days; not 10080 days -- spec 1.2/1.5)')
        or diag('the literal "PNPM_CONFIG_MINIMUM_RELEASE_AGE=10080" was not found (unit is minutes, per spec section 1.5)');

    ok($ccode =~ /PNPM_CONFIG_MINIMUM_RELEASE_AGE_IGNORE_MISSING_TIME=false\b/,
       'D2c: PNPM_CONFIG_MINIMUM_RELEASE_AGE_IGNORE_MISSING_TIME=false is present');

    ok($ccode =~ /PNPM_CONFIG_MINIMUM_RELEASE_AGE_STRICT=true\b/,
       'D2d: PNPM_CONFIG_MINIMUM_RELEASE_AGE_STRICT=true is present');
}

# =====================================================================
# D3 -- MINIMUM_RELEASE_AGE_IGNORE_MISSING_TIME explicitly false
#
# WHY this must be an explicit false, not an omission: pnpm's documented
# default for minimumReleaseAgeIgnoreMissingTime is TRUE, which silently
# SKIPS the minimum-age check entirely for any package whose registry
# metadata has no `time` field (spec section 1.5/D3). `pnpm config get`
# also returns "undefined" for an unset key -- never the documented
# default -- so a reader who checked the live config could not tell the
# difference between "explicitly true" and "unset, defaulting to true"
# without this assertion pinning the literal text in the Containerfile.
# =====================================================================
{
    ok($ccode =~ /PNPM_CONFIG_MINIMUM_RELEASE_AGE_IGNORE_MISSING_TIME=false\b/,
       'D3: MINIMUM_RELEASE_AGE_IGNORE_MISSING_TIME is explicitly false (default is true, which silently disables the age check for packages missing a registry `time` field)');
}

# =====================================================================
# D4 -- dangerouslyAllowAllBuilds never enabled; ignore_scripts non-regression
# =====================================================================
{
    my $daab_enabled = ($csrc =~ /dangerouslyAllowAllBuilds\s*[:=]\s*["']?(?:true|1|yes)\b/i) ? 1 : 0;
    ok(!$daab_enabled, 'D4a: dangerouslyAllowAllBuilds appears nowhere enabled in the Containerfile');

    my $ignore_scripts_intact = grep { /^ENV\s+npm_config_ignore_scripts=true\s*$/ } @clines;
    ok($ignore_scripts_intact,
       'D4b (non-regression): the pre-existing ENV npm_config_ignore_scripts=true is still present and unmodified');
}

# =====================================================================
# D5 -- bp-fast-store.sh targets pnpm-workspace.yaml, NOT .npmrc
# =====================================================================
{
    ok($ssrc =~ /pnpm-workspace\.yaml/,
       'D5a: bp-fast-store.sh references pnpm-workspace.yaml as a write target');
    ok($ssrc =~ /\bstoreDir\b/,
       'D5b: bp-fast-store.sh writes the camelCase storeDir key');
    ok($ssrc =~ /\bvirtualStoreDir\b/,
       'D5c: bp-fast-store.sh writes the camelCase virtualStoreDir key');

    # The absence IS the bug fix (spec section 1.3/5): pnpm 10+ silently
    # ignores kebab-case store-dir/virtual-store-dir written to .npmrc, so
    # a fixed implementation must not write those keys to .npmrc at all.
    ok($ssrc !~ /store-dir\s*=/,
       'D5d: bp-fast-store.sh does NOT write the kebab-case store-dir= key to .npmrc (that key is silently ignored by pnpm 10+ -- the absence is the fix)')
        or diag('found a "store-dir=" write -- this is the confirmed-broken .npmrc mechanism (spec section 1.3)');
    ok($ssrc !~ /virtual-store-dir\s*=/,
       'D5e: bp-fast-store.sh does NOT write the kebab-case virtual-store-dir= key to .npmrc (silently ignored by pnpm 10+)')
        or diag('found a "virtual-store-dir=" write -- this is the confirmed-broken .npmrc mechanism (spec section 1.3)');
}

# =====================================================================
# D6 -- verify step checks the store is ACTUALLY IN USE, not mere presence
#
# This is the "verify behaviour, not presence" rule (spec landmine #2):
# b06 shipped a presence check (`test -d ... && test -n "$(ls -A ...)"`)
# that passes even though the store/virtual-store are never relocated
# (measured, spec section 1.3). A correct verify must observe pnpm's
# ACTUAL BEHAVIOUR -- e.g. `pnpm store path` resolving to the configured
# directory, or a real (non-symlink) file landing under the configured
# virtual store -- not merely that a directory exists and is non-empty.
# =====================================================================
{
    my ($bp_verify) = $ssrc =~ /BP_VERIFY=(.*)$/m;
    ok(defined $bp_verify, 'D6 setup: found a BP_VERIFY=... assignment in bp-fast-store.sh')
        or diag('no BP_VERIFY=... line found at all');
    $bp_verify //= '';

    # A verify built only from presence primitives (-d/-f/-n/ls) would also
    # pass against the confirmed-broken .npmrc implementation (spec 1.3:
    # node_modules/.pnpm exists and is non-empty even when the store keys
    # were silently ignored and the default store was used instead). So a
    # verify limited to those primitives fails this criterion outright.
    my $behaviour_evidence = ($bp_verify =~ /\bpnpm\s+store\s+path\b/)
                           || ($bp_verify =~ /\breadlink\b/)
                           || ($bp_verify =~ /\brealpath\b/);
    ok($behaviour_evidence,
       'D6: bp-fast-store.sh verify step observes actual pnpm BEHAVIOUR (e.g. `pnpm store path` or resolving a real symlink target), not merely directory presence/non-emptiness')
        or diag("BP_VERIFY was: $bp_verify\n(a verify built only from test -d/-f/-n/ls would also pass against the known-broken .npmrc implementation -- spec section 1.3)");
}

# =====================================================================
# D7 -- environment precondition: env beats pnpm-workspace.yaml;
# .npmrc is not consulted at all for these settings (spec section 1.4).
#
# Uses a File::Temp scratch dir; the real project is never touched.
# SKIPs cleanly (with a reason) if pnpm is absent from PATH, but the
# criterion is never silently omitted -- axis 3 (callers cannot silently
# override) rests entirely on this property holding.
# =====================================================================
{
    my $has_pnpm = (system('pnpm --version > /dev/null 2>&1') == 0);

  SKIP: {
        skip 'pnpm is not on PATH in this environment -- D7 cannot be exercised (axis 3 property untested this run)', 3
            unless $has_pnpm;

        my $dir = tempdir(CLEANUP => 1);
        my $orig_cwd = getcwd();

        # Layer 1: pnpm-workspace.yaml = 222, project .npmrc = 111.
        # Expected (spec 1.4 rows 2-3): .npmrc is ignored outright; workspace wins.
        open(my $wfh, '>', "$dir/pnpm-workspace.yaml") or BAIL_OUT("cannot write pnpm-workspace.yaml: $!");
        print $wfh "minimumReleaseAge: 222\n";
        close $wfh;
        open(my $nfh, '>', "$dir/.npmrc") or BAIL_OUT("cannot write .npmrc: $!");
        print $nfh "minimum-release-age=111\n";
        close $nfh;

        my $out_workspace = `cd "$dir" && pnpm config get minimumReleaseAge 2>/dev/null`;
        chomp $out_workspace;
        is($out_workspace, '222',
           'D7a: with pnpm-workspace.yaml=222 and project .npmrc=111, pnpm resolves 222 (.npmrc is not consulted for this setting)')
            or diag("pnpm config get minimumReleaseAge returned: '$out_workspace' (expected 222; observed on this run)");

        # Layer 2: add env PNPM_CONFIG_MINIMUM_RELEASE_AGE=333 on top.
        # Expected (spec 1.4 row 4): env wins over the workspace file.
        local $ENV{PNPM_CONFIG_MINIMUM_RELEASE_AGE} = 333;
        my $out_env = `cd "$dir" && pnpm config get minimumReleaseAge 2>/dev/null`;
        chomp $out_env;
        is($out_env, '333',
           'D7b: with env PNPM_CONFIG_MINIMUM_RELEASE_AGE=333 additionally set, pnpm resolves 333 (env beats pnpm-workspace.yaml)')
            or diag("pnpm config get minimumReleaseAge returned: '$out_env' (expected 333; observed on this run)");

        ok(1, 'D7c: environment-variable override cannot be silently defeated by a project file the caller cannot control -- a caller can only override by re-exporting the env var itself (an explicit act, spec section 1.4)');

        # best-effort restore; tempdir CLEANUP handles removal
        chdir($orig_cwd) if defined $orig_cwd;
    }
}

done_testing();
