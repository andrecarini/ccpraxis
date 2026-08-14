#!/usr/bin/env perl
# Oracle for p02-container-ssh-host-keys (blueprint butler-and-dashboard-overhaul).
#
# IMMUTABLE ORACLE: written from the spec BEFORE the implementation exists.
# Do not weaken these assertions to make a future implementation's life
# easier; a criterion this file cannot honestly test is reported, not faked.
#
# Spec: .ccpraxis-local-data/blueprints/butler-and-dashboard-overhaul/specs/p02-container-ssh-host-keys-spec.md
#
# NEVER run `podman build`, NEVER spawn launcher.pl/bootstrap.pl (repo CLAUDE.md,
# following the precedent at t/42-refuse-in-place.t and t/57-node-pnpm-toolchain.t).
# The oracle instead extracts the exact shell text between two fixed sentinel
# comments in the Containerfile (spec 2.1) and EXECUTES it via `bash -c` against
# stub `curl`/`jq` (Perl + core JSON::PP -- no host jq/python, per hard limits),
# in a File::Temp scratch dir standing in for /etc/ssh. The real Containerfile
# and the real /etc/ssh are never touched.
#
# A bare grep for "the Containerfile contains a curl/jq line" proves nothing
# about whether keys actually land in the image -- that failure mode (testing
# a STRING instead of a BEHAVIOUR) is exactly what this blueprint's oracle
# defects have repeatedly been. AC1-AC5 and the second-guard mechanism test
# are behaviour tests: real exit codes, real file content, from really running
# the extracted shell logic.
#
# Criterion mapping (spec section 4, package done criteria in parens):
#   AC1 : happy path -> exit 0, correct known-hosts content        (done 3, 7a)
#   AC2 : no network -> non-zero exit, no artifact                 (done 4, 7b)
#   AC3 : rate-limited (HTTP 403 proxy) -> same shape as AC2        (done 4, 7b)
#   AC4 : 200 with empty ssh_keys array -> jq -e fails, no artifact (done 4, 7b)
#   AC5 : 200 with missing ssh_keys key -> same as AC4              (done 4, 7b)
#   AC6m: the `[ -s ... ]` second guard is not dead code -- a synthetic
#         "filter typo" case (length check passes, -r mapping emits zero
#         bytes) still aborts.                                      (done 4, 7b)
#   AC6 : CRITERION 2 IS A HARD PROHIBITION -- no StrictHostKeyChecking=no,
#         no accept-new, no unattended ssh-keyscan in the NEW step.  (done 2)
#   AC7 : provenance -- literal fetch URL and write destination.    (done 3)
#   AC8 : launcher.pl's two pre-existing GIT_SSH_COMMAND arms (incl. the
#         bootstrap-consistent StrictHostKeyChecking=no on the deploy-key
#         arm, which the architect ruled STAYS) are byte-identical to their
#         pre-change text -- this package must not touch them.      (done 5)
#   AC9 : the provenance comment states the GitHub-only scope decision
#         in text, discoverable from the Containerfile itself.       (done 6)
#   AC10: suite-wide green -- process-level, not encoded here (see report).
#         (done 8)
#
# UNTESTABLE IN THIS SUITE, per spec section 4's own statement: done criterion
# 1 (a live SSH clone actually succeeding) needs a real `podman build` and a
# running container, both forbidden here. Covered by decomposition (AC1 proves
# the artifact; the live `ssh -G github.com` read captured in the scout report
# proves the image's ssh reads that artifact unconditionally) plus a documented
# manual post-implementation check -- see report.

use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use Cwd qw(abs_path);

my $REPO_ROOT = abs_path("$Bin/../../../..");
BAIL_OUT("cannot resolve repo root from $Bin/../../../..") unless defined $REPO_ROOT;

my $CONTAINERFILE = "$REPO_ROOT/plugins/sandbox/container/Containerfile";
my $LAUNCHER       = "$REPO_ROOT/plugins/sandbox/scripts/launcher.pl";

BAIL_OUT("cannot find Containerfile at $CONTAINERFILE") unless -f $CONTAINERFILE;
BAIL_OUT("cannot find launcher.pl at $LAUNCHER")         unless -f $LAUNCHER;

open my $cfh, '<:raw', $CONTAINERFILE or BAIL_OUT("cannot open Containerfile: $!");
my $csrc = do { local $/; <$cfh> };
close $cfh;

open my $lfh, '<:raw', $LAUNCHER or BAIL_OUT("cannot open launcher.pl: $!");
my $lsrc = do { local $/; <$lfh> };
close $lfh;

# =====================================================================
# Extraction: the sentinel-bounded block is a CONTRACT (spec 2.1) --
# fixed literal text the implementer must not reword.
# =====================================================================
my $BEGIN_SENTINEL = '# === BEGIN p02-ssh-host-keys fetch ===';
my $END_SENTINEL   = '# === END p02-ssh-host-keys fetch ===';

my ($block) = $csrc =~ /\Q$BEGIN_SENTINEL\E\n(.*?)\Q$END_SENTINEL\E/s;
BAIL_OUT("sentinel-bounded block not found in Containerfile -- expected "
        . "'$BEGIN_SENTINEL' ... '$END_SENTINEL'; the new fetch step does not "
        . "exist yet or uses different sentinel text")
    unless defined $block;

my @block_lines = split /\n/, $block;
my @code_lines  = grep { !/^\s*#/ } @block_lines;
while (@code_lines && $code_lines[-1] =~ /^\s*$/) { pop @code_lines }

BAIL_OUT("sentinel-bounded block contains no RUN line -- extraction yielded "
        . "nothing to execute:\n$block")
    unless @code_lines && $code_lines[0] =~ /^\s*RUN\b/;

my $run_text = join("\n", @code_lines);
$run_text =~ s/^\s*RUN\s+//s;

# =====================================================================
# AC6 -- CRITERION 2 IS A HARD PROHIBITION.
# Scoped to the NEW sentinel-bounded block ONLY, not the whole Containerfile
# or launcher.pl -- bootstrap.pl:645 and launcher.pl:3069 carry a PRE-EXISTING
# StrictHostKeyChecking=no on the deploy-key path that the architect ruled
# STAYS (it is remote-host-agnostic and serves non-GitHub deploy-key flows
# this package does not cover). Asserting file-wide would fail against a
# correct implementation.
# =====================================================================
{
    ok($block !~ /StrictHostKeyChecking\s*=?\s*no\b/i,
       'AC6a: the new sentinel-bounded step does not set StrictHostKeyChecking=no')
        or diag("found StrictHostKeyChecking=no inside the new block:\n$block");

    ok($block !~ /StrictHostKeyChecking\s*=?\s*accept-new/i,
       'AC6b: the new sentinel-bounded step does not set StrictHostKeyChecking=accept-new')
        or diag("found StrictHostKeyChecking accept-new inside the new block:\n$block");

    ok($block !~ /ssh-keyscan/i,
       'AC6c: the new sentinel-bounded step does not invoke ssh-keyscan (unattended TOFU is a forbidden mechanism)')
        or diag("found ssh-keyscan inside the new block:\n$block");
}

# =====================================================================
# AC7 -- provenance: literal fetch URL (https, not http) and literal
# write destination.
# =====================================================================
{
    ok(index($run_text, 'https://api.github.com/meta') >= 0,
       'AC7a: fetch URL is literally https://api.github.com/meta')
        or diag("extracted RUN body was:\n$run_text");

    ok(index($run_text, 'http://api.github.com/meta') < 0,
       'AC7b: fetch URL is NOT plain http:// (TLS is the authentication mechanism per done criterion 3)');

    ok(index($run_text, '/etc/ssh/ssh_known_hosts') >= 0,
       'AC7c: write destination is literally /etc/ssh/ssh_known_hosts')
        or diag("extracted RUN body was:\n$run_text");

    ok(index($run_text, '/root/.ssh/known_hosts') < 0,
       'AC7d: write destination is NOT /root/.ssh/known_hosts (per-user known_hosts was explicitly ruled out)');

    ok(index($run_text, 'ssh_known_hosts2') < 0,
       'AC7e: ssh_known_hosts2 is not written (legacy, absence is not an error -- spec section 5)');
}

# =====================================================================
# AC9 -- the provenance comment states the GitHub-only scope decision in
# text, discoverable from the Containerfile itself (done criterion 6).
# Implementer is free to word this; we require SOME recognizable scoping
# statement, not exact wording.
# =====================================================================
{
    my $scope_stated = $block =~ /(github[\s-]only|only\s+github|scoped?\s+(?:to\s+)?github|non-github|other\s+(?:ssh\s+)?hosts?)/i;
    ok($scope_stated,
       'AC9: the provenance comment (inside or adjacent to the sentinel block) states the fix is scoped to GitHub only')
        or diag("no scope-statement pattern found in the sentinel-bounded block:\n$block");
}

# =====================================================================
# AC8 -- non-regression: the two pre-existing GIT_SSH_COMMAND conditional
# arms in launcher.pl are byte-identical to their pre-change text. This
# package adds no new env-var-based mechanism and does not touch these.
# Text captured live from launcher.pl at spec-writing time (was
# :3066-3070 at scout time; line numbers may drift, text must not).
# =====================================================================
my @expected_launcher_lines = (
    'if (-f "$CLAUDE_DATA/git-ssh-command.sh") {',
    q{    push @EXTRA_ENV, '-e', 'GIT_SSH_COMMAND=/root/.claude/git-ssh-command.sh';},
    '} elsif (-f "$PROJECT_PATH/deploy_key") {',
    q{    push @EXTRA_ENV, '-e', 'GIT_SSH_COMMAND=ssh -i /project/deploy_key -o StrictHostKeyChecking=no';},
);

for my $i (0 .. $#expected_launcher_lines) {
    my $line = $expected_launcher_lines[$i];
    ok(index($lsrc, $line) >= 0,
       "AC8." . ($i + 1) . ": launcher.pl still contains, byte-identical, the pre-existing arm line: $line")
        or diag("launcher.pl no longer contains this exact line -- AC8 requires this package leave "
              . "the two GIT_SSH_COMMAND arms untouched (spec section 1, ruling)");
}

# =====================================================================
# Behaviour harness: stub curl/jq, execute the extracted shell body for
# real, assert exit code + file content per scenario (spec 2.3).
# =====================================================================
my $stub_dir = tempdir(CLEANUP => 1);

open my $curl_fh, '>', "$stub_dir/curl" or BAIL_OUT("cannot write stub curl: $!");
print $curl_fh <<'STUBCURL';
#!/usr/bin/env perl
# Stub curl for t/80-ssh-host-keys.t. Parses -o TARGET from argv. On
# TEST_CURL_FAIL, produces no output and a non-zero exit -- the harness's
# single representation of BOTH "no network" and real curl -f's collapse
# of any HTTP >=400 (incl. GitHub's 403 rate limit) into that same shape.
# Otherwise copies the scenario fixture's bytes to TARGET and exits 0.
use strict;
use warnings;
my @args = @ARGV;
my $out;
for (my $i = 0; $i < @args; $i++) {
    if ($args[$i] eq '-o') { $out = $args[$i + 1]; last; }
}
if ($ENV{TEST_CURL_FAIL}) {
    exit 22;
}
my $fixture = $ENV{TEST_CURL_FIXTURE};
die "stub curl: TEST_CURL_FIXTURE not set and TEST_CURL_FAIL not set\n"
    unless defined $fixture && length $fixture;
open my $in, '<', $fixture or die "stub curl: cannot read fixture $fixture: $!\n";
local $/;
my $body = <$in>;
close $in;
die "stub curl: no -o target parsed from argv (@args)\n" unless defined $out;
open my $ofh, '>', $out or die "stub curl: cannot write $out: $!\n";
print $ofh $body;
close $ofh;
exit 0;
STUBCURL
close $curl_fh;
chmod 0755, "$stub_dir/curl";

open my $jq_fh, '>', "$stub_dir/jq" or BAIL_OUT("cannot write stub jq: $!");
print $jq_fh <<'STUBJQ';
#!/usr/bin/env perl
# Stub jq for t/80-ssh-host-keys.t. Implements EXACTLY the two invocation
# shapes the spec's contract (2.1) fixes: the length-check (-e) and the
# github.com-prefix mapping (-r). Any other call shape exits 99 -- the
# driving test treats 99 as a reserved "unrecognized jq call shape" signal
# and BAIL_OUTs, per spec 2.3's "fail loud on a filter change without a
# matching test update" requirement.
use strict;
use warnings;
use JSON::PP;
my @args = @ARGV;

sub load_keys {
    my ($file) = @_;
    open my $fh, '<', $file or return [];
    local $/;
    my $body = <$fh>;
    close $fh;
    my $data = eval { decode_json($body) };
    return [] unless ref $data eq 'HASH';
    return ref $data->{ssh_keys} eq 'ARRAY' ? $data->{ssh_keys} : [];
}

my $VALIDATED_R_FILTER =
    '(.ssh_keys // []) as $all | ($all | map(select((test("\n") or test("\r")) | not)) '
  . '| map(select(test("^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521) [A-Za-z0-9+/=]+$")))) '
  . 'as $valid | if ($valid | length) != ($all | length) then error("p02: an ssh_keys entry failed key-shape validation") '
  . 'else $valid[] end | "github.com,ssh.github.com,[ssh.github.com]:443 " + .';

if (@args >= 3 && $args[0] eq '-e' && $args[1] eq '(.ssh_keys // []) | length > 0') {
    my $keys = load_keys($args[2]);
    exit(@$keys > 0 ? 0 : 1);
}
elsif (@args >= 3 && $args[0] eq '-r' && $args[1] eq $VALIDATED_R_FILTER) {
    my $keys = load_keys($args[2]);
    if ($ENV{TEST_JQ_FORCE_EMPTY_R}) {
        # Synthetic "filter typo" simulation, per the spec's OWN framing
        # (2.1: "guarding against a jq -r that runs but emits nothing, e.g.
        # a filter typo that produces zero lines despite -e having passed").
        # With the exact fixed filter in the contract this cannot arise from
        # any real GitHub response (see report / infeasibility note below);
        # this flag exists solely to exercise the shell chain's [ -s ... ]
        # guard mechanism in isolation.
        exit 0;
    }
    # Real jq semantics (fix-batch step 7, findings F1/F2): validate EVERY
    # element -- no embedded newline/CR, and shape matches a known key type
    # token followed by a base64 blob and nothing else -- BEFORE emitting
    # any output at all. If the validated count differs from the input
    # count, jq's error() aborts the whole filter with no partial output
    # (exit 5), matching real jq's behaviour for a top-level error().
    my @valid = grep {
        my $k = $_;
        (index($k, "\n") < 0 && index($k, "\r") < 0)
            && $k =~ /^(?:ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521) [A-Za-z0-9+\/=]+$/
    } @$keys;
    if (scalar(@valid) != scalar(@$keys)) {
        print STDERR "p02: an ssh_keys entry failed key-shape validation\n";
        exit 5;
    }
    for my $k (@valid) {
        print "github.com,ssh.github.com,[ssh.github.com]:443 " . $k . "\n";
    }
    exit 0;
}
else {
    print STDERR "UNRECOGNIZED_JQ_CALL: @args\n";
    exit 99;
}
STUBJQ
close $jq_fh;
chmod 0755, "$stub_dir/jq";

# run_scenario: substitutes the real /etc/ssh + /tmp paths for scratch-dir
# ones (spec 2.3.4 -- MUST NOT touch the host's real /etc/ssh), runs the
# (optionally guard-mutated) extracted body via `bash -c`, returns exit code
# and known-hosts file content (undef if never created).
sub run_scenario {
    my (%o) = @_;
    my $scratch      = tempdir(CLEANUP => 1);
    my $known_hosts  = "$scratch/ssh_known_hosts";
    my $tmp_json     = "$scratch/gh-meta.json";
    my $body         = $o{run_text} // $run_text;

    if ($o{preseed}) {
        open my $pfh, '>', $known_hosts or BAIL_OUT("cannot preseed known_hosts: $!");
        print $pfh $o{preseed};
        close $pfh;
    }

    (my $cmd = $body) =~ s{/etc/ssh/ssh_known_hosts}{$known_hosts}g;
    $cmd =~ s{/tmp/gh-meta\.json}{$tmp_json}g;

    local $ENV{PATH}                 = "$stub_dir:$ENV{PATH}";
    local $ENV{TEST_CURL_FIXTURE}    = $o{fixture} // '';
    local $ENV{TEST_CURL_FAIL}       = $o{fail} ? '1' : '';
    local $ENV{TEST_JQ_FORCE_EMPTY_R} = $o{force_empty_r} ? '1' : '';

    my $raw_rc = system('bash', '-c', $cmd);
    BAIL_OUT("stub jq saw a call shape it does not recognize -- the Containerfile's "
            . "jq filter text changed without a matching test update (spec 2.3)")
        if $raw_rc != -1 && ($raw_rc >> 8) == 99;

    my $rc = $raw_rc == -1 ? -1 : ($raw_rc >> 8);
    my $content;
    if (-f $known_hosts) {
        open my $fh, '<', $known_hosts or BAIL_OUT("cannot read scenario known_hosts: $!");
        local $/;
        $content = <$fh>;
    }
    return ($rc, $content);
}

# --- fixtures -----------------------------------------------------------
my $fixdir = tempdir(CLEANUP => 1);

sub write_fixture {
    my ($name, $json) = @_;
    my $path = "$fixdir/$name.json";
    open my $fh, '>', $path or BAIL_OUT("cannot write fixture $name: $!");
    print $fh $json;
    close $fh;
    return $path;
}

# Models the real endpoint's shape: ssh_keys plus unrelated fields the
# filter must ignore (reviewer checklist item 5 -- read against a real
# api.github.com/meta sample by eye before merging).
my $fixture_happy = write_fixture('happy', <<'JSON');
{
  "verifiable_password_authentication": false,
  "ssh_key_fingerprints": {"SHA256_ED25519": "unrelated"},
  "hooks": ["192.30.252.0/22"],
  "ssh_keys": [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl",
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk=",
    "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg="
  ]
}
JSON

my $fixture_empty_array = write_fixture('empty_array', '{"ssh_keys": []}');
my $fixture_missing_key = write_fixture('missing_key', '{"verifiable_password_authentication": false}');

# =====================================================================
# AC1 -- happy path.
# =====================================================================
{
    my ($rc, $content) = run_scenario(fixture => $fixture_happy);
    is($rc, 0, 'AC1a: valid GitHub /meta response -> extracted fetch logic exits 0')
        or diag("expected exit 0, got $rc");
    ok(defined $content && length $content,
       'AC1b: known-hosts artifact is non-empty')
        or diag('known-hosts file was ' . (defined $content ? 'empty' : 'never created'));

    my @lines = defined $content ? split(/\n/, $content) : ();
    is(scalar(@lines), 3, 'AC1c: known-hosts line count equals the fixture ssh_keys array length (3)');

    # AC1d -- AMENDED by driver authorisation (fix-batch step 7, finding F3).
    # Was: /^github\.com (keytype) (key)$/ -- one hostname only. GitHub's
    # port-443 workaround (`ssh -p 443 git@ssh.github.com`, used on networks
    # blocking outbound 22) presents the SAME keys under `ssh.github.com` and
    # `[ssh.github.com]:443`, so a github.com-only file reproduced the exact
    # reported symptom for those users. The amendment REQUIRES all three
    # patterns, so it is strictly stronger than what it replaced -- and AC1c
    # above still pins one line per fetched key, because a comma-separated
    # known_hosts pattern list covers all three hosts on a single line.
    my @bad = grep { !/^github\.com,ssh\.github\.com,\[ssh\.github\.com\]:443 (ssh-ed25519|ssh-rsa|ecdsa-sha2-\S+) \S+$/ } @lines;
    is(scalar(@bad), 0,
       'AC1d: every known-hosts line matches "github.com,ssh.github.com,[ssh.github.com]:443 <keytype> <key>"')
        or diag("non-matching lines:\n" . join("\n", @bad));
}

# =====================================================================
# AC2 -- no network.
# =====================================================================
{
    my ($rc, $content) = run_scenario(fail => 1);
    isnt($rc, 0, 'AC2a: curl failure (no network) -> extracted fetch logic exits non-zero')
        or diag("expected non-zero exit, got $rc");
    ok(!defined $content,
       'AC2b: no known-hosts artifact is produced when curl fails before any write')
        or diag('known-hosts file unexpectedly exists with content: ' . ($content // ''));

    # Additional coverage of spec behaviour 2's "never overwritten with
    # empty content" clause: a stale pre-existing file survives byte-identical.
    my ($rc2, $content2) = run_scenario(fail => 1, preseed => "github.com STALE-MARKER\n");
    isnt($rc2, 0, 'AC2c: curl failure still exits non-zero when a stale known-hosts file pre-exists');
    is($content2, "github.com STALE-MARKER\n",
       'AC2d: a pre-existing known-hosts file is left byte-identical (never truncated/overwritten) on curl failure');
}

# =====================================================================
# AC3 -- rate-limited (HTTP 403). curl -f collapses this into the exact
# same empty-output/non-zero-exit shape as AC2 -- not a distinguishable
# code path (spec behaviour 3). Distinguished only at the fixture-authoring
# level: this scenario documents intent, not a different stub behaviour.
# =====================================================================
{
    my ($rc, $content) = run_scenario(fail => 1);
    isnt($rc, 0, 'AC3a: rate-limited response (simulated via curl -f collapse) -> non-zero exit')
        or diag("expected non-zero exit, got $rc");
    ok(!defined $content,
       'AC3b: no known-hosts artifact is produced on a rate-limited response');
}

# =====================================================================
# AC4 -- 200 with empty ssh_keys array.
# =====================================================================
{
    my ($rc, $content) = run_scenario(fixture => $fixture_empty_array);
    isnt($rc, 0, 'AC4a: empty ssh_keys array -> jq -e length check fails -> non-zero exit')
        or diag("expected non-zero exit, got $rc");
    ok(!defined $content,
       'AC4b: no non-empty known-hosts artifact results from an empty ssh_keys array')
        or diag('known-hosts file unexpectedly exists with content: ' . ($content // ''));
}

# =====================================================================
# AC5 -- 200 with missing ssh_keys key entirely.
# =====================================================================
{
    my ($rc, $content) = run_scenario(fixture => $fixture_missing_key);
    isnt($rc, 0, 'AC5a: missing ssh_keys key -> "// []" normalizes to empty -> jq -e fails -> non-zero exit')
        or diag("expected non-zero exit, got $rc");
    ok(!defined $content,
       'AC5b: no non-empty known-hosts artifact results from a missing ssh_keys key')
        or diag('known-hosts file unexpectedly exists with content: ' . ($content // ''));
}

# =====================================================================
# AC11 -- fix-batch step 7, finding F1 (HIGH, red-team): a blank-string
# ssh_keys entry ({"ssh_keys":[""]}) previously passed EVERY guard --
# `jq -e length>0` (the array has 1 element), the write ("github.com " + ""
# is still a non-empty string), and the old `[ -s ... ]` byte-count check
# (12 bytes) -- and shipped a keyless "github.com " line: a build that
# reports success and looks healthy while /etc/ssh/ssh_known_hosts has NO
# usable entry for github.com, reproducing the exact original defect behind
# a green build. This is the case the PRIOR version of this file's comment
# (formerly here) found and reasoned out of scope as "a content-shape gap
# outside the guards' contract, not this AC's target" -- that reasoning is
# what let the defect ship (red-team report, HIGH #1). Replaced with a real
# assertion: this exercises the shape-validation guard added to the jq -r
# filter itself (fix-batch step 7), which rejects an entry that doesn't
# match a known key-type token + base64 blob, aborting the WHOLE chain
# (jq error() -> no partial output) rather than silently emitting a
# keyless line. Confirmed this assertion goes RED against the pre-fix
# filter (manual revert-and-rerun during implementation; see fix-batch
# report) -- it is not vacuous.
# =====================================================================
{
    my $fixture_blank_key = write_fixture('blank_key', '{"ssh_keys": [""]}');
    my ($rc, $content) = run_scenario(fixture => $fixture_blank_key);
    isnt($rc, 0,
         'AC11a: a blank-string ssh_keys entry fails validation -> extracted fetch logic exits non-zero (F1)')
        or diag("expected non-zero exit, got $rc");
    ok(!defined $content || $content eq '',
       'AC11b: no keyless "github.com " line survives -- the chain aborts before/without a usable write (F1)')
        or diag('known-hosts file unexpectedly non-empty: ' . ($content // ''));
}

# =====================================================================
# AC12 -- fix-batch step 7, finding F2 (HIGH, red-team): an ssh_keys entry
# containing an embedded newline injects extra, un-prefixed lines into the
# known-hosts file via jq -r's raw-string output -- verified live by the
# red-team against real jq to inject a `*` wildcard and an
# `@cert-authority *` marker, escalating trust from github.com to any SSH
# host the container ever contacts, contradicting the "SCOPE: GitHub only"
# provenance comment. Exercises the same shape-validation guard as AC11
# (the newline check runs before the shape regex, per the Containerfile
# comment: `^`/`$` anchor to LINE boundaries in jq's regex engine, not
# string boundaries, so an anchored shape check alone would NOT catch a
# mid-string newline -- this fixture specifically has a shape-valid PREFIX
# before the injected newline, so it only fails if the newline is checked
# explicitly). Confirmed RED against the pre-fix filter during
# implementation (see fix-batch report).
# =====================================================================
{
    my $fixture_newline_injection = write_fixture('newline_injection',
        '{"ssh_keys": ["ssh-ed25519 AAAAVALIDLOOKINGPREFIX\n* ssh-rsa AAAAINJECTEDWILDCARDKEY\n@cert-authority * ssh-rsa AAAAINJECTEDCAKEY"]}');
    my ($rc, $content) = run_scenario(fixture => $fixture_newline_injection);
    isnt($rc, 0,
         'AC12a: an ssh_keys entry with an embedded newline fails validation -> non-zero exit (F2)')
        or diag("expected non-zero exit, got $rc");
    ok(!defined $content || $content eq '',
       'AC12b: no injected wildcard/@cert-authority line reaches the known-hosts file (F2)')
        or diag('known-hosts file unexpectedly non-empty: ' . ($content // ''));
    if (defined $content) {
        unlike($content, qr/^\*\s/m,
            'AC12c: no bare wildcard host pattern ("* ...") appears in the known-hosts file');
        unlike($content, qr/\@cert-authority/,
            'AC12d: no @cert-authority marker appears in the known-hosts file');
    }
}

# =====================================================================
# AC13 -- fix-batch step 7, findings F1/F2's stated method: "compare the
# count of accepted elements against the total and abort when they differ,
# so a partially-bad response fails loudly instead of silently shipping
# fewer keys -- a filter that merely drops bad elements would re-create F1
# in a quieter form." Mixed fixture: one well-formed key, one malformed
# entry. Asserts the WHOLE response is refused -- the good key is NOT
# shipped alone -- proving the guard is a count comparison, not a
# `select()`-only filter that would silently ship 1-of-2 keys.
# =====================================================================
{
    my $fixture_mixed = write_fixture('mixed_good_bad',
        '{"ssh_keys": ["ssh-ed25519 AAAAGOODKEYMATERIAL", "* ssh-rsa AAAABADCAKEY"]}');
    my ($rc, $content) = run_scenario(fixture => $fixture_mixed);
    isnt($rc, 0,
         'AC13a: a mixed good/malformed ssh_keys array fails validation -> non-zero exit')
        or diag("expected non-zero exit, got $rc");
    ok(!defined $content || $content eq '',
       'AC13b: the well-formed key is NOT shipped alone -- a partially-bad response is refused entirely, not silently thinned')
        or diag('known-hosts file unexpectedly non-empty: ' . ($content // ''));
}

# =====================================================================
# AC6m -- the `[ -s ... ]` second guard is not dead code.
#
# Pre-fix-batch, this AC's own INFEASIBILITY NOTE observed that with the
# THEN-current unvalidated filter, {"ssh_keys":[""]} passed both -e and the
# write, producing a non-empty "github.com " file -- a real gap, now closed
# by the F1 shape-validation guard added above (see AC11): a blank entry no
# longer reaches [ -s ... ] as a false-non-empty pass, it is rejected
# earlier, by jq's error(), with no output at all. That guard is exercised
# by AC11/AC12/AC13. This AC still separately proves the `[ -s ... ]` guard
# itself is not dead code for its OWN narrower purpose (a would-be filter
# regression that passes shape validation for every element yet still
# emits zero bytes, e.g. a future refactor bug) via the synthetic
# TEST_JQ_FORCE_EMPTY_R stub flag, modelling EXACTLY the failure mode the
# Containerfile's own inline comment names for this
# guard (2.1: "a filter typo that produces zero lines despite -e having
# passed on a differently-shaped check") -- a non-empty, legitimate-looking
# fixture where -e correctly passes, but the -r step (simulating a filter
# regression) writes nothing. This is not a claim about a real GitHub
# response shape; it is a direct test of the shell chain's guard mechanism.
# =====================================================================
{
    my ($rc, $content) = run_scenario(fixture => $fixture_happy, force_empty_r => 1);
    isnt($rc, 0,
         'AC6m-a: [ -s ... ] guard aborts when -e passes but the write step (simulated filter typo) emits zero bytes')
        or diag("expected non-zero exit, got $rc");
    ok(!defined $content || $content eq '',
       'AC6m-b: no non-empty known-hosts artifact survives the simulated filter-typo case')
        or diag('known-hosts file unexpectedly non-empty: ' . ($content // ''));
}

done_testing();
