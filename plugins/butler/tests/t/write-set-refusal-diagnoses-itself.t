#!/usr/bin/env perl
# platform: any
# Report 20260916-175013-34af, remaining half.
#
# bp-ledger.pl's V4b/V4c checks now REFUSE to write a write_set: field carrying
# prose or a Windows drive letter, so the corruption cannot be created through
# the sanctioned path any more. That does nothing for a session already running
# with a corrupt BP_WRITE_SET: guard-writes.sh reads only the env var, nothing
# re-derives it mid-session, and the refusal used to print the RAW colon-joined
# string. A coordinator therefore saw "outside this package's write set" for a
# path plainly listed in its own ledger, diagnosed a SCOPE dispute, and
# escalated for a re-scope it did not need -- the scope was already correct and
# only its serialization was broken. The report's closing line is that a
# self-diagnosing message would have turned a half-session of misdiagnosis into
# a five-second read.
#
# This file asserts the MESSAGE, and asserts that the allow/deny decision is
# unchanged by it. A guard that explains itself better but decides differently
# would be a regression in the direction that matters: guard-writes.sh exists
# because a worker writing outside its scope is how an oracle gets edited.
#
# guard-writes.sh is GATED (bp_hook_gate, the old shared bash guard library) -- it no-ops entirely
# unless BP_LEDGER, BP_DIR and BP_PROJECT_ROOT are ALL set, so every invocation
# below sets all three. A test that forgot one would pass vacuously.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP;
use HostCaps qw(tempdir_args);

(my $HOOKS = "$Bin/../../hooks") =~ s{\\}{/}g;
my $GUARD  = "$HOOKS/guard-writes.sh";

my $have_jq = do { my $o = `bash -c 'command -v jq' 2>/dev/null`; $o =~ /\S/ ? 1 : 0 };
my $J = JSON::PP->new->canonical;

# guard-writes.sh waves through ANYTHING under /tmp/, and a bare tempdir() on
# this host resolves there -- every DENY case would then exit 0 for the wrong
# reason and pass vacuously. Anchor in the ccpraxis scratch root instead.
my $ROOT = tempdir(tempdir_args(), CLEANUP => 1);
sub fwd { (my $p = shift) =~ s{\\}{/}g; $p }

my %CLEAN_ENV = map { ($_ => $ENV{$_}) } grep { !/^BP_/ } keys %ENV;

# The hook's `case "$FP" in /*)` absolute-path test never matches a Windows-form
# path, and `realpath -m` hands "C:/x" back unchanged here. Hand-translate.
sub to_posix {
    my ($p) = @_;
    $p = fwd($p);
    $p =~ s{^([A-Za-z]):(?=/|\z)}{'/' . lc($1)}e;
    return $p;
}

# Git for Windows ships no jq and guard-writes.sh is fail-closed without a JSON
# parser. Drop a minimal stand-in on a shim PATH used only by the hook
# subprocess; when a real jq IS present (the sandbox container) it wins and this
# file exercises the real binary there.
my $JQ_PATH_PREFIX;
unless ($have_jq) {
    my $shim = "$ROOT/jq-shim";
    mkdir $shim or die "mkdir $shim: $!";
    open my $jq, '>', "$shim/jq" or die "open shim jq: $!";
    print $jq <<'PERL';
#!/usr/bin/env perl
use strict; use warnings; use JSON::PP;
binmode(STDIN, ':raw'); binmode(STDOUT, ':raw');
my $expr; for my $a (@ARGV) { next if $a eq '-r'; $expr = $a }
my $raw = do { local $/; <STDIN> };
my $doc = eval { JSON::PP->new->utf8->decode($raw) };
my $result;
if (ref $doc eq 'HASH' && defined $expr) {
    for my $term (split m{\s*//\s*}, $expr) {
        $term =~ s/^\s+|\s+$//g;
        last if $term eq 'empty';
        (my $path = $term) =~ s/^\.//;
        my $v = $doc;
        for my $k (split /\./, $path) {
            $v = (ref $v eq 'HASH') ? $v->{$k} : undef;
            last unless defined $v;
        }
        if (defined $v && !ref($v) && $v ne '') { $result = $v; last }
    }
}
if (defined $result) { utf8::encode($result) if utf8::is_utf8($result); print $result, "\n" }
exit 0;
PERL
    close $jq;
    chmod 0755, "$shim/jq";
    $JQ_PATH_PREFIX = to_posix($shim);
}

my ($pn, $envn) = (0, 0);

sub mk_env {
    my $n = ++$envn;
    my $proj = "$ROOT/proj$n";
    my $bpd  = "$ROOT/bpdir$n";
    mkdir $proj or die "mkdir $proj: $!";
    mkdir $bpd  or die "mkdir $bpd: $!";
    mkdir "$bpd/runs" or die "mkdir $bpd/runs: $!";
    return (to_posix($proj), to_posix($bpd));
}

sub run_guard {
    my ($payload, %env) = @_;
    my $n  = ++$pn;
    my $pf = "$ROOT/payload.$n.json";
    open my $w, '>', $pf or die "open $pf: $!";
    print $w $payload;
    close $w;
    local %ENV = (%CLEAN_ENV, %env, GPATH => fwd($GUARD), PFILE => fwd($pf));
    if (defined $JQ_PATH_PREFIX) {
        $ENV{PATH} = $JQ_PATH_PREFIX . ":" . ($CLEAN_ENV{PATH} // $ENV{PATH} // '/usr/bin:/bin');
    }
    open(my $f, '-|', 'bash', '-c', '"$GPATH" < "$PFILE" 2>&1') or die "bash: $!";
    my $o = do { local $/; <$f> };
    close $f;
    return ($? >> 8, $o);
}

sub edit_payload {
    my ($proj, $rel) = @_;
    return $J->encode({ tool_name => 'Edit', cwd => $proj,
                        tool_input => { file_path => "$proj/$rel" } });
}

# The exact corruption from the report, verbatim in shape: three intended paths,
# an em-dash annotation on the third, and a colon INSIDE that annotation. Split
# on ':' this yields FOUR patterns, the third being
# "scripts/fleet-orchestrator.pl — the orchestrator is in scope for ONE thing only"
# which matches nothing, so the bare path is not in the write set at all.
my $CORRUPT =
    'scripts/JRM/TickHarness.pm'
  . ':scripts/t/52-tick-harness.t'
  . ':scripts/fleet-orchestrator.pl — the orchestrator is in scope for ONE thing only'
  . ': exposing the entry point the harness drives a tick through';

# ---- 1. the decision is unchanged: the annotated path is still DENIED --------
my ($rc_corrupt, $out_corrupt);
{
    my ($proj, $bpd) = mk_env();
    ($rc_corrupt, $out_corrupt) = run_guard(
        edit_payload($proj, 'scripts/fleet-orchestrator.pl'),
        BP_LEDGER => "$bpd/packages/pkg.md", BP_DIR => $bpd, BP_PROJECT_ROOT => $proj,
        BP_PACKAGE => 'pkg', BP_WRITE_SET => $CORRUPT, BP_TEST_PATHS => 'scripts/t/',
    );
    is($rc_corrupt, 2,
       'a corrupt write_set still DENIES the annotated path -- the message changed, the verdict did not')
        or diag("guard output: $out_corrupt");
}

# ---- 2. the refusal lists the parsed patterns, one per line ------------------
like($out_corrupt, qr/^\s+scripts\/JRM\/TickHarness\.pm\s*$/m,
     'refusal lists the first parsed pattern on its own line');
like($out_corrupt, qr/^\s+scripts\/t\/52-tick-harness\.t\s*$/m,
     'refusal lists the second parsed pattern on its own line');

# ---- 3. it says how many patterns the split actually produced ----------------
# FOUR, not the three the author wrote -- which is the whole finding.
like($out_corrupt, qr/4 pattern\(s\) after splitting on ":"/,
     'refusal states the parsed pattern COUNT, so 3-written-4-parsed is visible without counting by eye');

# ---- 4. the corrupt element is marked, and names the report ------------------
like($out_corrupt, qr/contains whitespace: not a path \(report 20260916-175013-34af\)/,
     'the whitespace-bearing element is flagged as not-a-path and cites the report');

# ---- 5. the message distinguishes serialization from a real scope dispute ----
# The report's core harm: the refusal read as "your scope is wrong" when the
# scope was right. A coordinator following the old text escalated for a re-scope
# it did not need.
like($out_corrupt, qr/serialized wrong and the scope is already correct/,
     'refusal offers the serialization reading, not only the scope-dispute reading');
# Since 2026-10-23 the guard unions the ledger's live write_set/test_paths
# into the launch snapshot, so an in-session widening is the recovery.
like($out_corrupt, qr/ledger is re-read on every write: widen it with bp-ledger\.pl widen-write-set/,
     'refusal names the in-session recovery (widen the ledger), not a relaunch');

# ---- 6. no regression: a path genuinely outside scope is still denied --------
{
    my ($proj, $bpd) = mk_env();
    my ($rc, $out) = run_guard(
        edit_payload($proj, 'plugins/other/thing.pl'),
        BP_LEDGER => "$bpd/packages/pkg.md", BP_DIR => $bpd, BP_PROJECT_ROOT => $proj,
        BP_PACKAGE => 'pkg', BP_WRITE_SET => 'plugins/butler/scripts/bp-ledger.pl',
        BP_TEST_PATHS => 'plugins/butler/tests/t/',
    );
    is($rc, 2, 'a genuinely out-of-scope path is still denied')
        or diag("guard output: $out");
    unlike($out, qr/contains whitespace/,
           'a clean write_set is not flagged as corrupt');
}

# ---- 7. no regression: a path inside the write set is still ALLOWED ----------
# The direction that would hurt most. A display change that accidentally denied
# a legitimate write would stall every package it touched.
{
    my ($proj, $bpd) = mk_env();
    my ($rc, $out) = run_guard(
        edit_payload($proj, 'plugins/butler/scripts/bp-ledger.pl'),
        BP_LEDGER => "$bpd/packages/pkg.md", BP_DIR => $bpd, BP_PROJECT_ROOT => $proj,
        BP_PACKAGE => 'pkg', BP_WRITE_SET => 'plugins/butler/scripts/bp-ledger.pl',
        BP_TEST_PATHS => 'plugins/butler/tests/t/',
    );
    is($rc, 0, 'an in-scope write is still allowed')
        or diag("guard output: $out");
}

# ---- 8. an empty test_paths renders without dying ---------------------------
# BP_TEST_PATHS is optional; the old message printed a literal em dash for it.
# The new one runs a splitter over it, so the empty case is worth pinning.
{
    my ($proj, $bpd) = mk_env();
    my ($rc, $out) = run_guard(
        edit_payload($proj, 'nowhere/at/all.pl'),
        BP_LEDGER => "$bpd/packages/pkg.md", BP_DIR => $bpd, BP_PROJECT_ROOT => $proj,
        BP_PACKAGE => 'pkg', BP_WRITE_SET => 'plugins/butler/', BP_TEST_PATHS => '',
    );
    is($rc, 2, 'empty test_paths: still denies');
    like($out, qr/test_paths: \(empty\)/, 'empty test_paths renders as (empty), not as a stray split');
}

done_testing();
