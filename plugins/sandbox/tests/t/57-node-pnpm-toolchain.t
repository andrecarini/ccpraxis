#!/usr/bin/env perl
# Oracle for b38-node-pnpm-toolchain (blueprint sandbox-butler-overhaul).
#
# IMMUTABLE ORACLE: written from the spec BEFORE the implementation exists.
# Do not weaken these assertions to make a future implementation's life
# easier; a criterion this file cannot honestly test is reported, not faked.
#
# Spec: .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/specs/b38-node-pnpm-toolchain-spec.md
# Test slot is 57, NOT 55 -- spec section 1.7 records the collision with the
# pre-existing 55-minimize-evidence.t and the corrected slot.
#
# NEVER build an image or start a container here. Containerfile content is
# asserted as TEXT ONLY, following the precedent in t/42-refuse-in-place.t
# (source-grep without spawning). D7 is the sole exception: it runs the
# REAL `pnpm` binary already installed in this sandbox against a File::Temp
# scratch directory -- never the real project, never a container.
#
# Criterion mapping (spec section 3):
#   D1 : Node/pnpm exactly pinned, no latest/lts/bare-major floating ref
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
# D1 -- exact version pins, no floating reference
# =====================================================================
{
    # Pre-existing lines that legitimately mention "node"/"pnpm"-adjacent
    # tokens and must NOT be mistaken for the new toolchain block.
    my %preexisting = map { $_ => 1 } (
        "ENV npm_config_ignore_scripts=true\n",
        'ENV NODE_OPTIONS="--dns-result-order=ipv4first"' . "\n",
    );

    my @relevant = grep { (/\bnode\b/i || /\bpnpm\b/i) && !$preexisting{$_} } @ccode_lines;

    my $has_node_pin = grep { /\bv24\.18\.0\b/ } @relevant;
    my $has_pnpm_pin = grep { /\b11\.17\.0\b/ } @relevant;

    ok($has_node_pin, 'D1a: Containerfile pins Node to exact v24.18.0 in the added toolchain block')
        or diag('no line mentioning node/pnpm (outside the pre-existing env lines) contains "v24.18.0"');
    ok($has_pnpm_pin, 'D1b: Containerfile pins pnpm to exact 11.17.0 in the added toolchain block')
        or diag('no line mentioning node/pnpm (outside the pre-existing env lines) contains "11.17.0"');

    # Comment lines are EXCLUDED (coordinator fix at the step-4 gate). D1c is about
    # what the image actually installs — a floating reference in a RUN/ENV directive.
    # The implementation's comment block legitimately explains *why* `latest` was
    # rejected ("11.18.0/dist-tag latest (5d) were both too new"), and flagging that
    # prose as a floating reference is a false positive that would pressure the
    # implementer to delete the very rationale a future maintainer needs.
    my @floating_hits;
    for my $line (grep { !/^\s*#/ } @relevant) {
        push @floating_hits, $line if $line =~ /\b(?:latest|lts)\b/i;
        push @floating_hits, $line if $line =~ /(?:\bnode[:@]|NODE_VERSION\s*=\s*)24(?!\.\d)/i;
        # `\@` MUST be escaped (coordinator fix). Written as `pnpm@11`, Perl
        # interpolates `@11` as a non-existent (empty) array, silently collapsing the
        # pattern to /\bpnpm(?!\.\d)/ — which matches ANY line containing "pnpm" not
        # followed by ".<digit>", and so flagged the correctly-pinned
        # `npm install -g pnpm@11.17.0` as a floating reference. Same class as the
        # \Q...$?...\E interpolation trap fixed in t/67: an unescaped sigil silently
        # changes what the regex means, and the test still "works" — wrongly.
        push @floating_hits, $line if $line =~ /\bpnpm\@11(?!\.\d)/i;
    }
    is(scalar(@floating_hits), 0,
       'D1c: no `latest`, `lts`, or bare-major floating reference appears in the added Node/pnpm block')
        or diag("floating-reference hits:\n  " . join("  ", @floating_hits));
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
