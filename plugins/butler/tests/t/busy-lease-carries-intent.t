#!/usr/bin/env perl
# platform: any
# ORACLE for package 05-intent-in-busy-lease (blueprint wake-and-pause-consolidation), per
# .ccpraxis-local-data/blueprints/wake-and-pause-consolidation/specs/05-intent-in-busy-lease-spec.md.
#
# The orchestrator's busy-lease touch writes its want_awake result into the lease as one JSON
# line (BpAwakeIntent::lease_line, BpOrch::touch_busy); the launcher's probe reads that content
# in the same `sh -c`, only after `stat` succeeds (KeepAwake::split_lease_probe_output /
# parse_lease_intent), and carries reason/until into the probe result and the keepawake_decision
# log line. Written BLIND to the implementation: BpAwakeIntent::lease_line, the new
# touch_busy($path,\%intent) shape, and KeepAwake's four new pure functions do not exist in
# TODAY's code -- every assertion below is taken from the spec, not from reading the post-package
# bodies. Never BAIL_OUT on a missing sub: callers are eval-wrapped so a hard Perl "Undefined
# subroutine" becomes a failing assertion, not a dead test file (house rule, awake-intent-
# decision.t).
#
# AC1  B1/B2: touch_busy writes valid JSON (5 keys, awake==1, v==1, written_at==mtime), mtime in
#      [before,after], no temp file left
# AC2  B4: a falsy/absent intent never touches the file (create or content/mtime)
# AC3  B3/B6: BpAwakeIntent::lease_line is pure; undef for awake 0 / non-HASH / bad written_at;
#      until numeric/null encoding
# AC4  B5: a forced write failure still returns 1 and refreshes mtime, content untouched; an
#      absent path is created empty (today's fallback, verbatim)
# AC5  structural: exactly two touch_busy( call-site statements in bp-orchestrator.pl, each the
#      new shape, neither gated by a bare ->{awake} outside want_awake(
# AC6  B7/B8/B9/B10: _busy_lease_probe (extracted + fake podman) parses the new separator/content
# AC7  the fake's log shows the exact new sh -c argument
# AC8  B11: the inner script, run by a real local sh, matches today's stat-alone behaviour for a
#      missing file and separator-then-content for a present one
# AC9  KeepAwake::split_lease_probe_output / parse_lease_intent, every input in B8
# AC10 regression only (recorded as validation commands, not reproduced): busy-lease-path-
#      conversion.t, lease-unreadable-not-absent.t
# AC11 B12: intent_log_fields; structural: the keepawake_decision log_ev hash and the lease_probe
#      gather carry the new fields
# AC12 B13: DC4 new-launcher-reads-old-orchestrator-lease compatibility, via on_probe
# AC13 DC4 new-orchestrator-write read by old mtime-only readers (heartbeat.sh, today's launcher
#      stat-only read)
# AC14 regression, recorded as validation commands (see report), not reproduced here
use strict;
use warnings;
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir tempfile);
use File::Spec;
use JSON::PP ();

(my $BUTLER_SCRIPTS  = "$Bin/../../scripts") =~ s{\\}{/}g;
(my $SANDBOX_SCRIPTS = "$Bin/../../../sandbox/scripts") =~ s{\\}{/}g;

use lib "$Bin/../../../sandbox/scripts";
use KeepAwake ();

require "$BUTLER_SCRIPTS/bp-orchestrator.pl";

sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    return <$fh>;
}

# code_lines: shared house helper (awake-intent-decision.t) -- strips POD/__END__/comments so
# structural regexes never trip on a line that only MENTIONS the thing it is checking for.
sub code_lines {
    my ($src) = @_;
    return '' unless defined $src;
    my @lines = split /\n/, $src;
    my @out;
    my $in_pod = 0;
    for my $line (@lines) {
        last if $line =~ /^__(?:END|DATA)__\s*$/;
        if (!$in_pod && $line =~ /^=[a-zA-Z]/) { $in_pod = 1; next }
        if ($in_pod) { $in_pod = 0 if $line =~ /^=cut\b/; next }
        next if $line =~ /^\s*#/;
        (my $l = $line) =~ s/\s#(?:\s|$).*$//;
        push @out, $l;
    }
    return join("\n", @out);
}

sub statement_containing {
    my ($code, $marker) = @_;
    my @out;
    while ($code =~ /$marker/g) {
        my $mstart = $-[0];
        my $line_start = rindex($code, "\n", $mstart);
        $line_start = ($line_start == -1) ? 0 : $line_start + 1;
        my $semi = index($code, ';', $mstart);
        next if $semi == -1;
        push @out, substr($code, $line_start, $semi - $line_start + 1);
    }
    return @out;
}

# Eval-wrapped callers: a sub that does not exist yet must fail an assertion, not crash the file.
sub call_lease_line  { my ($i, $w) = @_; local $@; my $r = eval { BpAwakeIntent::lease_line($i, $w) }; return $r }
sub call_touch_busy   { my ($p, $i) = @_; local $@; my $r = eval { BpOrch::touch_busy($p, $i) }; diag("touch_busy died: $@") if $@; return $r }
sub call_sep          { local $@; my $r = eval { KeepAwake::lease_intent_sep() }; return $r }
sub call_split        { my ($raw) = @_; local $@; my @r = eval { KeepAwake::split_lease_probe_output($raw) }; return $@ ? () : @r }
sub call_parse        { my ($c) = @_; local $@; my $r = eval { KeepAwake::parse_lease_intent($c) }; return $r }
sub call_log_fields   { my ($p) = @_; local $@; my @r = eval { KeepAwake::intent_log_fields($p) }; return $@ ? () : @r }

# ====================================================================================================
# AC1 (B1, B2) -- touch_busy writes valid JSON and refreshes mtime.
# ====================================================================================================
{
    my $dir = tempdir(CLEANUP => 1);
    my $path = "$dir/busy";
    ok(!-e $path, 'AC1 precondition: the lease does not exist yet');

    my $before = time;
    my $rv = call_touch_busy($path, { awake => 1, reason => 'running', until => undef });
    my $after = time;
    is($rv, 1, 'AC1/B1: touch_busy on a missing path in an existing dir returns 1');
    ok(-e $path, 'AC1/B1: the lease now exists');

    my @lines = do { my $t = slurp($path) // ''; split /\n/, $t };
    is(scalar(@lines), 1, 'AC1/B1: the lease contains exactly one line')
        or diag('content: ' . (slurp($path) // '(unreadable)'));

    my $decoded = eval { JSON::PP->new->decode($lines[0] // '') };
    ok(ref($decoded) eq 'HASH', 'AC1/B1: the line decodes to a JSON object') or diag("decode error: $@; line: " . ($lines[0] // '(none)'));
    if (ref($decoded) eq 'HASH') {
        is_deeply([ sort keys %$decoded ], [ sort qw(v awake reason until written_at) ],
            'AC1/B1: exactly the five keys v/awake/reason/until/written_at');
        is($decoded->{v}, 1, 'AC1/B1: v == 1');
        is($decoded->{awake}, 1, 'AC1/B1: awake == 1');
        is($decoded->{reason}, 'running', 'AC1/B1: reason carried through');
        is($decoded->{until}, undef, 'AC1/B1: until == null for undef');
        ok(defined $decoded->{written_at} && $decoded->{written_at} =~ /\A\d+\z/,
            'AC1/B1: written_at is a plain integer');
        my @st = stat($path);
        is($st[9], $decoded->{written_at}, 'AC1/B1: mtime == written_at');
        ok($st[9] >= $before && $st[9] <= $after, 'AC1/B1: mtime falls within [before,after] of the call');
    }
    ok(!-e "$path.tmp.$$", 'AC1/B1: no stray temp file is left behind');

    # B2: an EXISTING lease (old-format content, mtime in the past) is replaced, not appended.
    utime(time - 1000, time - 1000, $path);
    open my $fh, '>', $path or die $!; print $fh "old garbage, not json\n"; close $fh;
    my $before2 = time;
    my $rv2 = call_touch_busy($path, { awake => 1, reason => 'outstanding', until => undef });
    my $after2 = time;
    is($rv2, 1, 'AC1/B2: touch_busy on an existing lease returns 1');
    my $content2 = slurp($path) // '';
    my @lines2 = split /\n/, $content2;
    is(scalar(@lines2), 1, 'AC1/B2: the old content is REPLACED, not appended to');
    my $decoded2 = eval { JSON::PP->new->decode($lines2[0] // '') };
    ok(ref($decoded2) eq 'HASH' && ($decoded2->{reason} // '') eq 'outstanding',
        'AC1/B2: the new content reflects the new intent') or diag("got: " . ($lines2[0] // '(none)'));
    my @st2 = stat($path);
    ok($st2[9] >= $before2 && $st2[9] <= $after2, 'AC1/B2: mtime refreshed to now, not the old 1000s-past value');
}

# ====================================================================================================
# AC2 (B4) -- a falsy/absent intent never touches the lease.
# ====================================================================================================
{
    my $dir = tempdir(CLEANUP => 1);
    my $missing = "$dir/absent";
    for my $bad ({ awake => 0, reason => 'idle' }, undef, {}) {
        my $label = !defined($bad) ? 'undef' : (ref($bad) eq 'HASH' && !keys(%$bad) ? '{}' : 'awake=>0');
        my $rv = call_touch_busy($missing, $bad);
        is($rv, 0, "AC2/B4: touch_busy($label) returns 0");
        ok(!-e $missing, "AC2/B4: touch_busy($label) never creates the file");
    }

    my $existing = "$dir/present";
    open my $fh, '>', $existing or die $!; print $fh "existing content X"; close $fh;
    my $past = time - 1000;
    utime($past, $past, $existing);
    my @before_st = stat($existing);
    for my $bad ({ awake => 0, reason => 'idle' }, undef, {}) {
        my $rv = call_touch_busy($existing, $bad);
        is($rv, 0, 'AC2/B4: falsy intent on an existing lease returns 0');
        is(slurp($existing), 'existing content X', 'AC2/B4: ... and its content is byte-identical afterwards');
        my @st = stat($existing);
        is($st[9], $before_st[9], 'AC2/B4: ... and its mtime is second-identical afterwards');
    }
}

# ====================================================================================================
# AC3 (B3, B6) -- BpAwakeIntent::lease_line is pure.
# ====================================================================================================
{
    is(call_lease_line({ awake => 0 }, 1_700_000_000), undef, 'AC3/B6: awake=>0 -> undef');
    is(call_lease_line('x', 1_700_000_000), undef, 'AC3/B6: a non-HASH intent -> undef');
    is(call_lease_line([], 1_700_000_000), undef, 'AC3/B6: an arrayref intent -> undef');
    for my $bad_wa (undef, 'now', [], '1.5', -1, '12x') {
        my $label = !defined($bad_wa) ? 'undef' : (ref($bad_wa) ? 'ref' : "'$bad_wa'");
        is(call_lease_line({ awake => 1, reason => 'running' }, $bad_wa), undef,
            "AC3/B6: a non-integer written_at ($label) -> undef");
    }

    my $line = call_lease_line({ awake => 1, reason => 'pause-pending', until => 1_793_600_000 }, 1_700_000_000);
    ok(defined $line, 'AC3/B3: a valid intent produces a line') or diag('lease_line returned undef');
    if (defined $line) {
        like($line, qr/\n\z/, 'AC3: the line ends with a newline');
        my $d = eval { JSON::PP->new->decode($line) };
        ok(ref($d) eq 'HASH', 'AC3/B3: the line decodes to a JSON object') or diag("decode error: $@");
        if (ref($d) eq 'HASH') {
            is($d->{until}, 1_793_600_000, 'AC3/B3: a numeric until is written as that JSON number');
            is($d->{awake}, 1, 'AC3/B3: awake is the literal 1');
            is($d->{v}, 1, 'AC3/B3: v is 1');
        }
    }

    my $line2 = call_lease_line({ awake => 1, reason => 'pause-pending', until => 'junk' }, 1_700_000_000);
    ok(defined $line2, 'AC3/B3: a junk until still produces a line (it is not a disqualifier)');
    if (defined $line2) {
        my $d2 = eval { JSON::PP->new->decode($line2) };
        is(ref($d2) eq 'HASH' ? $d2->{until} : 'DECODE-FAILED', undef,
            'AC3/B3: a non-numeric until is written as null');
    }

    # B6: awake is always exactly 1, whatever truthy value ->{awake} held.
    for my $truthy (1, 2, 'yes', -1) {
        my $l = call_lease_line({ awake => $truthy, reason => 'running' }, 1_700_000_000);
        ok(defined $l, "AC3/B6: awake=>$truthy still produces a line");
        next unless defined $l;
        my $d = eval { JSON::PP->new->decode($l) };
        is(ref($d) eq 'HASH' ? $d->{awake} : 'DECODE-FAILED', 1,
            "AC3/B6: awake=>$truthy encodes as the literal 1, never the truthy value itself");
    }

    # Missing/empty reason falls back to 'unknown'.
    my $l3 = call_lease_line({ awake => 1 }, 1_700_000_000);
    if (defined $l3) {
        my $d3 = eval { JSON::PP->new->decode($l3) };
        is(ref($d3) eq 'HASH' ? $d3->{reason} : 'DECODE-FAILED', 'unknown',
            'AC3: a missing reason falls back to the string "unknown"');
    } else {
        fail('AC3: a missing reason still produces a line (fell back to "unknown")');
    }
}

# ====================================================================================================
# AC4 (B5) -- write-failure fallback.
# ====================================================================================================
{
    my $dir = tempdir(CLEANUP => 1);
    my $path = "$dir/busy";
    open my $fh, '>', $path or die $!; print $fh 'content X'; close $fh;
    my $past = time - 1000;
    utime($past, $past, $path);

    my $tmp_name = "$path.tmp.$$";
    mkdir($tmp_name) or die "cannot pre-create directory at $tmp_name: $!";

    my $before = time;
    my $rv = call_touch_busy($path, { awake => 1, reason => 'running', until => undef });
    my $after = time;
    is($rv, 1, 'AC4/B5: touch_busy still returns 1 when the temp rename target is blocked');
    is(slurp($path), 'content X', 'AC4/B5: the original content is untouched');
    my @st = stat($path);
    ok($st[9] >= $before && $st[9] <= $after, 'AC4/B5: the mtime is refreshed to now despite the write failure');
    ok(-d $tmp_name, 'AC4/B5: the blocking directory itself is left alone (never rmdir)');
    rmdir($tmp_name) or diag("cleanup: could not rmdir $tmp_name: $!");

    # Same situation, but $path absent: falls back to today's touch (create empty + utime).
    my $path2 = "$dir/busy2";
    my $tmp2 = "$path2.tmp.$$";
    mkdir($tmp2) or die "cannot pre-create directory at $tmp2: $!";
    my $b2 = time;
    my $rv2 = call_touch_busy($path2, { awake => 1, reason => 'running', until => undef });
    my $a2 = time;
    is($rv2, 1, 'AC4/B5: absent path + blocked temp target: still returns 1');
    ok(-e $path2, 'AC4/B5: ... and the lease is created');
    is(slurp($path2), '', 'AC4/B5: ... created EMPTY (the fallback is today\'s touch, not a JSON write)');
    my @st2 = stat($path2);
    ok($st2[9] >= $b2 && $st2[9] <= $a2, 'AC4/B5: ... with a fresh mtime');
    rmdir($tmp2) or diag("cleanup: could not rmdir $tmp2: $!");
}

# ====================================================================================================
# AC5 -- structural: exactly two touch_busy( call sites, the new shape, no bare ->{awake} gate.
# ====================================================================================================
{
    my $orch_src = slurp("$BUTLER_SCRIPTS/bp-orchestrator.pl");
    ok(defined $orch_src, 'AC5: bp-orchestrator.pl is readable');
    my $code = code_lines($orch_src // '');

    my @all_sites = statement_containing($code, qr/\btouch_busy\(/);
    # exclude the sub's own definition line, "sub touch_busy {"
    my @sites = grep { !/\bsub\s+touch_busy\b/ } @all_sites;
    is(scalar(@sites), 2, 'AC5: exactly two touch_busy( call-site statements (excluding the sub itself)')
        or diag('found: ' . join("\n---\n", @sites));

    my $shape_re = qr/touch_busy\(\$t->\{busy_path\},\s*BpAwakeIntent::want_awake\(\{/;
    for my $i (0 .. $#sites) {
        like($sites[$i], $shape_re, "AC5: call site $i matches the new shape");
        like($sites[$i], qr/\}\)\);\s*\z/, "AC5: call site $i ends `}));`");
        # No bare ->{awake} gate remaining OUTSIDE the want_awake( arguments: strip the
        # want_awake(...) argument region and check what's left for a stray ->{awake}.
        (my $stripped = $sites[$i]) =~ s/BpAwakeIntent::want_awake\(\{.*?\}\)//s;
        unlike($stripped, qr/->\{awake\}/, "AC5: call site $i has no ->{awake} gate outside want_awake(");
    }
}

# ====================================================================================================
# Probe extraction scaffolding (AC6/AC7/AC8/AC9) -- never spawns launcher.pl, podman, or a
# container: _busy_lease_probe and _trim_err are extracted by sentinel regex (keepawake-helper-
# revive.t's convention) and eval'ed into a throwaway package driven by a fake podman script.
# ====================================================================================================
my $LAUNCHER_SRC_PATH = "$SANDBOX_SCRIPTS/launcher.pl";
my $LAUNCHER_SRC = slurp($LAUNCHER_SRC_PATH);
ok(defined $LAUNCHER_SRC, 'precondition: launcher.pl is readable') or BAIL_OUT('no launcher.pl to extract from');

my ($probe_sub) = $LAUNCHER_SRC =~ /(sub _busy_lease_probe \{.*?\n\})/s;
my ($trim_sub)  = $LAUNCHER_SRC =~ /(sub _trim_err \{.*?\n\})/s;
ok(defined $probe_sub && defined $trim_sub, 'precondition: _busy_lease_probe and _trim_err are extractable')
    or diag('one or both sentinels did not match -- every AC6-AC9 assertion below will fail for that reason');

my $PROBE_PKG = 'BLProbeTest';
my $eval_ok = eval qq{
    package $PROBE_PKG;
    use strict;
    use warnings;
    our \$PODMAN;
    our \$BUSY_LEASE_PATH = '/tmp/.butler-busy';
    $probe_sub
    $trim_sub
    1;
};
ok($eval_ok, 'precondition: the extracted subs compile standalone') or diag("eval error: $@");

my $FAKE_DIR = tempdir(CLEANUP => 1);
my $FAKE_PODMAN_SCRIPT = "$FAKE_DIR/fake-podman.pl";
{
    open my $fh, '>', $FAKE_PODMAN_SCRIPT or die $!;
    print $fh <<'FAKE';
#!/usr/bin/env perl
use strict;
use warnings;
my @a = @ARGV;
if (@a && $a[0] eq 'exec') {
    my $script = $a[-1];
    if (defined $ENV{FAKE_PODMAN_LOG}) {
        open my $lf, '>>', $ENV{FAKE_PODMAN_LOG} or die $!;
        print $lf "$script\n";
        close $lf;
    }
    if ($script =~ /^stat\b/) {
        print $ENV{FAKE_STAT_OUT} // '';
        exit(defined $ENV{FAKE_STAT_RC} ? $ENV{FAKE_STAT_RC} : 0);
    }
    elsif ($script =~ /^date \+%s/) {
        print $ENV{FAKE_CLOCK} // '';
        exit(0);
    }
    exit(1);
}
elsif (@a && $a[0] eq 'inspect') {
    print $ENV{FAKE_INSPECT_OUT} // '';
    exit(defined $ENV{FAKE_INSPECT_RC} ? $ENV{FAKE_INSPECT_RC} : 0);
}
exit(1);
FAKE
    close $fh;
}
$PROBE_PKG->can('_busy_lease_probe') or diag('precondition: _busy_lease_probe did not install into the test package');
{
    no strict 'refs';
    ${"${PROBE_PKG}::PODMAN"} = qq{"$^X" "$FAKE_PODMAN_SCRIPT"};
}
my $FAKE_LOG = "$FAKE_DIR/log.txt";

# probe_with(%env) -> ($result, $log_text). Clears the log file first so each call's log is its own.
sub probe_with {
    my (%extra_env) = @_;
    unlink $FAKE_LOG if -e $FAKE_LOG;
    local %ENV = (%ENV, FAKE_PODMAN_LOG => $FAKE_LOG, %extra_env);
    delete $ENV{FAKE_STAT_OUT}   unless exists $extra_env{FAKE_STAT_OUT};
    delete $ENV{FAKE_STAT_RC}    unless exists $extra_env{FAKE_STAT_RC};
    delete $ENV{FAKE_CLOCK}      unless exists $extra_env{FAKE_CLOCK};
    delete $ENV{FAKE_INSPECT_OUT} unless exists $extra_env{FAKE_INSPECT_OUT};
    delete $ENV{FAKE_INSPECT_RC}  unless exists $extra_env{FAKE_INSPECT_RC};
    no strict 'refs';
    my $call = "${PROBE_PKG}::_busy_lease_probe";
    my $fn = \&{$call};
    local $@;
    my $r = eval { $fn->('fakecontainer') };
    diag("probe died: $@") if $@;
    my $log = slurp($FAKE_LOG);
    return ($r, (defined $log ? $log : ''));
}

my $SEP = '__BUTLER_BUSY_INTENT__';   # spec 2.4's pinned literal; cross-checked against
                                       # KeepAwake::lease_intent_sep() in AC9 below.
my $LMT  = 1_000_000_000;
my $CNOW = 1_000_000_005;             # age 5

SKIP: {
    # NIT-1 (reviewer): the real count is 23 -- 1 (AC6/B8 empty-content is_deeply) + 1 (AC7
    # exact-string is) + 8 (the garbage loop) + 2 (B8 numeric/null-until lease_line checks) +
    # 1 (B9) + 1 (B10) + 7 (the four B7 sub-blocks: 1+1+2+1+2 assertions) + 2 (AC-SEC2 freshness).
    skip 'precondition failed: cannot drive the extracted probe', 23
        unless $eval_ok && $PROBE_PKG->can('_busy_lease_probe');

    # ------------------------------------------------------------------------------------------
    # AC6/AC7: B8 -- stat succeeds, separator present.
    # ------------------------------------------------------------------------------------------
    {
        my ($r, $log) = probe_with(
            FAKE_STAT_OUT => "$LMT\n${SEP}",
            FAKE_STAT_RC  => 0,
            FAKE_CLOCK    => "$CNOW\n",
        );
        is_deeply($r, { state => 'ok', age => 5 },
            "AC6/B8: empty content (old orchestrator / BpContinuityLease) -> exactly {state=>'ok', age=>5}");

        # MINOR-2 (reviewer) + redteam MAJOR-1's guard: pin the EXACT sh -c argument, not a
        # substring -- a prefix/suffix (e.g. 2>/dev/null after the read) would still pass a
        # `like()`. The guard reads the lease only when it is a regular, non-symlink file, and
        # caps the read at 4097 bytes with `head` instead of streaming it with `cat` (stat runs
        # first, unchanged, so a failed stat still produces today's stderr byte for byte).
        my $expected_sh_c =
            "stat -c %Y /tmp/.butler-busy && printf $SEP && "
          . "{ [ -f /tmp/.butler-busy ] && [ ! -L /tmp/.butler-busy ] && head -c 4097 /tmp/.butler-busy; }";
        is((split /\n/, $log)[0], $expected_sh_c,
            'AC7: the fake saw the exact new sh -c argument (stat && printf SEP && guarded head, not cat)')
            or diag("log was: $log");
    }

    for my $garbage ("not json\n", '{"v":1,"awake":1,"rea', "line1\nline2\n",
                      '{"v":2,"awake":1,"reason":"x","until":null,"written_at":1}',
                      '{"v":1,"awake":0,"reason":"x","until":null,"written_at":1}',
                      '{"v":1,"awake":1,"reason":"rm -rf /","until":null,"written_at":1}',
                      '{"v":1,"awake":1,"reason":"x","until":"soon","written_at":1}',
                      # reviewer MAJOR-1: a genuinely VALID line padded past the 4096-byte cap --
                      # the old 'a' x 4097 fixture here was invalid JSON regardless of the cap.
                      ('{"v":1,"awake":1,"reason":"x","until":null,"written_at":1}' . (' ' x 4100))) {
        my $label = length($garbage) > 40 ? substr($garbage, 0, 20) . '...(' . length($garbage) . ' bytes)' : $garbage;
        $label =~ s/\n/\\n/g;
        my ($r, undef) = probe_with(
            FAKE_STAT_OUT => "$LMT\n${SEP}${garbage}",
            FAKE_STAT_RC  => 0,
            FAKE_CLOCK    => "$CNOW\n",
        );
        is_deeply($r, { state => 'ok', age => 5 },
            "AC6/B8: unusable content ($label) -> exactly {state=>'ok', age=>5}, never a hard failure");
    }

    {
        # AC-SEC2 freshness (abs(mtime - written_at) <= 2): written_at must match the
        # fake stat mtime ($LMT) here, not an arbitrary epoch, or the probe's own
        # freshness guard would (correctly) drop reason/until before this assertion
        # ever got to see them.
        my $line = call_lease_line({ awake => 1, reason => 'pause-pending', until => 1_793_600_000 }, $LMT)
            // qq({"v":1,"awake":1,"reason":"pause-pending","until":1793600000,"written_at":$LMT}\n);
        my ($r, undef) = probe_with(
            FAKE_STAT_OUT => "$LMT\n${SEP}${line}",
            FAKE_STAT_RC  => 0,
            FAKE_CLOCK    => "$CNOW\n",
        );
        is_deeply($r, { state => 'ok', age => 5, reason => 'pause-pending', until => 1_793_600_000 },
            'AC6/B8: a real lease_line with a numeric until -> reason and until both carried');
    }
    {
        # AC-SEC2 freshness: same reasoning -- written_at pinned to $LMT.
        my $line = call_lease_line({ awake => 1, reason => 'running', until => undef }, $LMT)
            // qq({"v":1,"awake":1,"reason":"running","until":null,"written_at":$LMT}\n);
        my ($r, undef) = probe_with(
            FAKE_STAT_OUT => "$LMT\n${SEP}${line}",
            FAKE_STAT_RC  => 0,
            FAKE_CLOCK    => "$CNOW\n",
        );
        is_deeply($r, { state => 'ok', age => 5, reason => 'running' },
            'AC6/B8: until:null -> reason carried, no until key at all');
    }

    # ------------------------------------------------------------------------------------------
    # AC6: B9 -- stat succeeds, cat fails (file removed between stat and cat).
    # ------------------------------------------------------------------------------------------
    {
        my $cat_err = "cat: can't open '/tmp/.butler-busy': No such file or directory\n";
        my ($r, undef) = probe_with(
            FAKE_STAT_OUT => "$LMT\n${SEP}${cat_err}",
            FAKE_STAT_RC  => 1,
            FAKE_CLOCK    => "$CNOW\n",
        );
        is_deeply($r, { state => 'ok', age => 5 },
            'AC6/B9: a cat failure after a successful stat is ok with no intent, never lease-absent');
    }

    # ------------------------------------------------------------------------------------------
    # AC6: B10 -- stat succeeds but produces unparsable output (even with the separator present).
    # ------------------------------------------------------------------------------------------
    {
        my ($r, undef) = probe_with(
            FAKE_STAT_OUT => "garbage\n${SEP}",
            FAKE_STAT_RC  => 0,
            FAKE_CLOCK    => "$CNOW\n",
        );
        is_deeply($r, { state => 'probe-failed', detail => 'unparsable stat output: garbage' },
            'AC6/B10: unparsable stat text (separator present) -> probe-failed, detail is the STAT text only');
    }

    # ------------------------------------------------------------------------------------------
    # AC6: B7 -- stat fails outright (no separator at all): today's classification, unchanged.
    # ------------------------------------------------------------------------------------------
    {
        my ($r, undef) = probe_with(
            FAKE_STAT_OUT => q{stat: cannot statx '/tmp/.butler-busy': No such file or directory},
            FAKE_STAT_RC  => 1,
        );
        is_deeply($r, { state => 'lease-absent' }, 'AC6/B7: GNU coreutils ENOENT phrasing -> lease-absent');
    }
    {
        my ($r, undef) = probe_with(
            FAKE_STAT_OUT => q{stat: can not stat '/tmp/.butler-busy': No such file or directory},
            FAKE_STAT_RC  => 1,
        );
        is_deeply($r, { state => 'lease-absent' }, 'AC6/B7: busybox ENOENT phrasing -> lease-absent');
    }
    {
        my ($r, undef) = probe_with(
            FAKE_STAT_OUT => q{stat: cannot statx 'C:/Users/ANDR~1/AppData/Local/Temp/.butler-busy': No such file or directory},
            FAKE_STAT_RC  => 1,
        );
        is($r->{state}, 'probe-failed', 'AC6/B7: a rewritten path is probe-failed, never lease-absent');
        like($r->{detail}, qr/^lease path was rewritten before podman saw it/,
            'AC6/B7: ... with the measured detail prefix');
    }
    {
        my ($r, undef) = probe_with(
            FAKE_STAT_OUT  => 'Error: fakecontainer is not running',
            FAKE_STAT_RC   => 125,
            FAKE_INSPECT_OUT => "exited\n",
            FAKE_INSPECT_RC  => 0,
        );
        is($r->{state}, 'container-gone', 'AC6/B7: inspect answering exited -> container-gone');
    }
    {
        my ($r, undef) = probe_with(
            FAKE_STAT_OUT  => 'Error: fakecontainer is not running',
            FAKE_STAT_RC   => 125,
            FAKE_INSPECT_OUT => '',
            FAKE_INSPECT_RC  => 1,
        );
        is($r->{state}, 'probe-failed', 'AC6/B7: inspect answering nothing -> probe-failed');
        like($r->{detail}, qr/could not reach podman/, 'AC6/B7: ... with the measured detail');
    }

    # ------------------------------------------------------------------------------------------
    # AC-SEC2 (redteam MINOR-3): reason/until are carried only when the lease's mtime (what
    # `stat` reported) is within 2s of the intent's OWN written_at. BpContinuityLease keeps
    # bumping the mtime of a lease the orchestrator stopped writing, so a stale intent must
    # not keep being reported once the gap exceeds the tolerance.
    # ------------------------------------------------------------------------------------------
    {
        my $written_at = 1_700_000_000;
        my $line = call_lease_line({ awake => 1, reason => 'pause-pending', until => 1_793_600_000 }, $written_at)
            // qq({"v":1,"awake":1,"reason":"pause-pending","until":1793600000,"written_at":$written_at}\n);

        # mtime 3s past written_at: outside the 2s tolerance -> reason/until dropped.
        my ($r_stale, undef) = probe_with(
            FAKE_STAT_OUT => ($written_at + 3) . "\n${SEP}${line}",
            FAKE_STAT_RC  => 0,
            FAKE_CLOCK    => ($written_at + 10) . "\n",
        );
        is_deeply($r_stale, { state => 'ok', age => 7 },
            'AC-SEC2: written_at more than 2s older than the lease mtime -> reason/until dropped (stale intent)');

        # mtime 1s past written_at: within the 2s tolerance -> reason/until kept.
        my ($r_fresh, undef) = probe_with(
            FAKE_STAT_OUT => ($written_at + 1) . "\n${SEP}${line}",
            FAKE_STAT_RC  => 0,
            FAKE_CLOCK    => ($written_at + 10) . "\n",
        );
        is_deeply($r_fresh, { state => 'ok', age => 9, reason => 'pause-pending', until => 1_793_600_000 },
            'AC-SEC2: written_at within 2s of the lease mtime -> reason/until kept (fresh intent)');
    }
}

# ====================================================================================================
# AC9 -- pure KeepAwake functions, every input listed in B8 and the spec's split/parse table.
# ====================================================================================================
{
    is(call_sep(), '__BUTLER_BUSY_INTENT__', 'AC9: KeepAwake::lease_intent_sep() returns the pinned literal');

    my @split1 = call_split("123\n__BUTLER_BUSY_INTENT__hello");
    is_deeply(\@split1, [ "123\n", 'hello' ], 'AC9: split_lease_probe_output: separator present splits stat_out/content');

    my @split2 = call_split('123');
    is_deeply(\@split2, [ '123', undef ], 'AC9: split_lease_probe_output: no separator -> content undef (stat failed)');

    my @split3 = call_split(undef);
    is_deeply(\@split3, [ '', undef ], 'AC9: split_lease_probe_output: undef raw -> stat_out empty, content undef');

    my @split4 = call_split("1\n__BUTLER_BUSY_INTENT__a__BUTLER_BUSY_INTENT__b");
    is_deeply(\@split4, [ "1\n", 'a__BUTLER_BUSY_INTENT__b' ],
        'AC9: a separator appearing twice in content splits at the FIRST occurrence only');

    my @split5 = call_split("123\n__BUTLER_BUSY_INTENT__");
    is_deeply(\@split5, [ "123\n", '' ], 'AC9: separator present with nothing after it -> content is the empty string');

    # parse_lease_intent: every B8 input.
    is(call_parse(undef), undef, 'AC9: parse_lease_intent(undef) -> undef');
    is(call_parse(''), undef, 'AC9: parse_lease_intent("") -> undef');
    is(call_parse("   \n"), undef, 'AC9: parse_lease_intent(whitespace-only) -> undef');
    is(call_parse('not json'), undef, 'AC9: parse_lease_intent(garbage) -> undef');
    is(call_parse('{"v":1,"awake":1,"rea'), undef, 'AC9: parse_lease_intent(truncated JSON) -> undef');
    is(call_parse(qq({"v":1,"awake":1,"reason":"x","until":null,"written_at":1}\nextra line)), undef,
        'AC9: parse_lease_intent(valid object + trailing garbage line) -> undef (JSON::PP rejects it)');
    is(call_parse('{"v":2,"awake":1,"reason":"x","until":null,"written_at":1}'), undef,
        'AC9: parse_lease_intent(v:2) -> undef');
    is(call_parse('{"v":1,"awake":0,"reason":"x","until":null,"written_at":1}'), undef,
        'AC9: parse_lease_intent(awake:0) -> undef');
    is(call_parse('{"v":1,"awake":1,"reason":"rm -rf /","until":null,"written_at":1}'), undef,
        'AC9: parse_lease_intent(bad reason, disallowed chars) -> undef');
    is(call_parse('{"v":1,"awake":1,"reason":"x","until":"soon","written_at":1}'), undef,
        'AC9: parse_lease_intent(bad until "soon") -> undef');
    is(call_parse(('a' x 4097)), undef, 'AC9: parse_lease_intent(>4096 bytes of pure garbage) -> undef (checked before decoding)');

    # reviewer MAJOR-1: the fixture above (and the old one removed from here) are invalid JSON
    # regardless of the cap, so they never proved the cap does anything. Pad a genuinely VALID
    # line past 4096 bytes, plus a just-under control so the padding itself isn't what's rejected.
    my $valid_base  = '{"v":1,"awake":1,"reason":"x","until":null,"written_at":1}';
    my $valid_over  = $valid_base . (' ' x 4100);                              # well over 4096
    my $valid_under = $valid_base . (' ' x (4096 - length($valid_base)));      # exactly 4096
    is(length($valid_over) > 4096, 1, 'AC9 precondition: the oversized control really is over 4096 bytes');
    is(length($valid_under), 4096, 'AC9 precondition: the just-under control is exactly 4096 bytes');
    is(call_parse($valid_over), undef,
        'AC9: a VALID intent line padded past 4096 bytes -> undef (the cap, not a decode failure)');
    is_deeply(call_parse($valid_under), { reason => 'x', until => undef },
        'AC9: the same line padded to exactly 4096 bytes still parses (control: padding alone is not the cause)');

    is_deeply(call_parse('{"v":1,"awake":1,"reason":"pause-pending","until":1793600000,"written_at":1700000000}'),
        { reason => 'pause-pending', until => 1_793_600_000 },
        'AC9: a well-formed intent with a numeric until parses to {reason,until}');
    is_deeply(call_parse('{"v":1,"awake":1,"reason":"running","until":null,"written_at":1700000000}'),
        { reason => 'running', until => undef },
        'AC9: a well-formed intent with until:null parses to {reason, until=>undef}');

    # redteam MAJOR-2: an unbounded digit string turns into Inf via 0+, which JSON::PP then
    # encodes as a bare `Inf` -- invalid JSON -- corrupting the whole sampler snapshot on every
    # round after. A 400-digit until must be rejected outright, never silently become Inf.
    my $huge_until_content = '{"v":1,"awake":1,"reason":"x","until":' . ('1' x 400) . ',"written_at":1}';
    is(call_parse($huge_until_content), undef,
        'AC9-SEC: a 400-digit until is rejected outright (never turns into Inf)');

    # Control: a normal epoch-sized until is still accepted.
    is_deeply(call_parse('{"v":1,"awake":1,"reason":"x","until":1793600000,"written_at":1}'),
        { reason => 'x', until => 1_793_600_000 },
        'AC9-SEC: a normal epoch until is still accepted');
}

# ====================================================================================================
# AC8 (B11) -- the probe's inner script, run by a REAL local sh, matches today's stat-alone
# behaviour for a missing file and separator-then-content for a present one.
# ====================================================================================================
{
    my $have_sh   = do { chomp(my $w = `sh -c 'command -v sh' 2>/dev/null`); $w ? 1 : 0 };
    my $have_stat = do { chomp(my $w = `sh -c 'command -v stat' 2>/dev/null`); $w ? 1 : 0 };
    my $have_head = do { chomp(my $w = `sh -c 'command -v head' 2>/dev/null`); $w ? 1 : 0 };

    SKIP: {
        skip 'sh, stat, or head not on PATH', 4 unless $have_sh && $have_stat && $have_head;

        # AC7/AC-SEC1 pinned the guarded form (stat && printf SEP && { [ -f ] && [ ! -L ] &&
        # head -c 4097 }), not the old unguarded `cat` -- this precondition must look for the
        # same shape AC-SEC1 extracts below, or it is testing a sh -c argument launcher.pl no
        # longer produces and this whole block skips against the current tree.
        my ($inner) = $LAUNCHER_SRC =~
            /sh -c '(stat -c %Y \$BUSY_LEASE_PATH && printf \Q$SEP\E && \{ \[ -f \$BUSY_LEASE_PATH \] && \[ ! -L \$BUSY_LEASE_PATH \] && head -c 4097 \$BUSY_LEASE_PATH; \})'/;
        ok(defined $inner, 'AC8 precondition: the guarded inner script is present in launcher.pl source')
            or diag('the guarded sh -c command (stat && printf SEP && [ -f ] && [ ! -L ] && head -c 4097) was not '
                   . 'found; this is the shape AC7/AC-SEC1 pin and is expected to be missing until implemented');

        SKIP: {
            # NIT-1 (reviewer): the real count is 4 (two is() for the missing-file comparison,
            # one is() and one like() for the present-file comparison).
            skip 'the new inner script is not present in launcher.pl yet', 4 unless defined $inner;

            my $dir = tempdir(CLEANUP => 1);
            my $missing = "$dir/nope";
            my $present = "$dir/present";
            open my $fh, '>', $present or die $!; print $fh 'hello world'; close $fh;

            (my $inner_missing = $inner) =~ s/\$BUSY_LEASE_PATH/$missing/g;
            (my $inner_present = $inner) =~ s/\$BUSY_LEASE_PATH/$present/g;

            my $today_missing_out = `sh -c 'stat -c %Y "$missing"' 2>&1`;
            my $today_missing_rc  = $?;
            my $new_missing_out   = `sh -c '$inner_missing' 2>&1`;
            my $new_missing_rc    = $?;
            is($new_missing_rc, $today_missing_rc, 'AC8/B11: a missing file: exit status matches stat alone');
            is($new_missing_out, $today_missing_out, 'AC8/B11: a missing file: combined output matches stat alone');

            my $new_present_out = `sh -c '$inner_present' 2>&1`;
            my $new_present_rc  = $?;
            is($new_present_rc, 0, 'AC8/B11: a present file: exit status 0');
            like($new_present_out, qr/\A\d+\n\Q$SEP\Ehello world\z/,
                'AC8/B11: a present file: digits, newline, separator, then the file bytes, no trailing newline added');
        }
    }
}

# ====================================================================================================
# AC-SEC1 (redteam MAJOR-1) -- the guard: a lease that is a symlink or a FIFO must never be
# streamed into the host sampler. Proven with a REAL local sh against File::Temp fixtures,
# every check bounded by `timeout` so a regression hangs this test file for a few seconds
# instead of hanging (or OOMing) the host sampler. Never create a FIFO or a symlink outside a
# File::Temp dir.
# ====================================================================================================
{
    my $have_sh      = do { chomp(my $w = `sh -c 'command -v sh' 2>/dev/null`); $w ? 1 : 0 };
    my $have_stat    = do { chomp(my $w = `sh -c 'command -v stat' 2>/dev/null`); $w ? 1 : 0 };
    my $have_timeout = do { chomp(my $w = `sh -c 'command -v timeout' 2>/dev/null`); $w ? 1 : 0 };
    my $have_mkfifo  = do { chomp(my $w = `sh -c 'command -v mkfifo' 2>/dev/null`); $w ? 1 : 0 };
    my $have_ln      = do { chomp(my $w = `sh -c 'command -v ln' 2>/dev/null`); $w ? 1 : 0 };

    SKIP: {
        skip 'sh/stat/timeout/mkfifo/ln not all on PATH', 3
            unless $have_sh && $have_stat && $have_timeout && $have_mkfifo && $have_ln;

        my ($inner_guarded) = $LAUNCHER_SRC =~
            /sh -c '(stat -c %Y \$BUSY_LEASE_PATH && printf \Q$SEP\E && \{ \[ -f \$BUSY_LEASE_PATH \] && \[ ! -L \$BUSY_LEASE_PATH \] && head -c 4097 \$BUSY_LEASE_PATH; \})'/;
        ok(defined $inner_guarded,
            'AC-SEC1 precondition: the guarded inner script (head -c 4097 behind [ -f ] && [ ! -L ]) is present in launcher.pl')
            or diag('redteam MAJOR-1\'s guard was not found; every behavioural check below is '
                   . 'expected to be skipped for that reason until implemented');

        SKIP: {
            skip 'the guarded inner script is not present in launcher.pl yet', 2 unless defined $inner_guarded;

            my $dir = tempdir(CLEANUP => 1);

            # A symlink to an endless device: the unguarded `cat` form streams it forever into
            # the host perl process (measured 9.2GB in 4s by redteam). The guard must never
            # even attempt the read for a symlink.
            my $symlink_path = "$dir/symlease";
            system('ln', '-sf', '/dev/zero', $symlink_path);
            (my $inner_sym = $inner_guarded) =~ s/\$BUSY_LEASE_PATH/$symlink_path/g;
            my $sym_out = `timeout 4 sh -c '$inner_sym' 2>&1`;
            like($sym_out, qr/\A\d+\n\Q$SEP\E\z/,
                'AC-SEC1: a symlinked lease -> stat succeeds, separator printed, NOTHING after it (never follows the link), well inside the timeout');

            # A FIFO: the unguarded `cat` form blocks forever waiting for a writer, hanging the
            # sampler round. The guard's [ -f ] test is false for a FIFO, so the read is never
            # attempted.
            my $fifo_path = "$dir/fifolease";
            system('mkfifo', $fifo_path);
            (my $inner_fifo = $inner_guarded) =~ s/\$BUSY_LEASE_PATH/$fifo_path/g;
            my $fifo_out = `timeout 4 sh -c '$inner_fifo' 2>&1`;
            like($fifo_out, qr/\A\d+\n\Q$SEP\E\z/,
                'AC-SEC1: a FIFO lease -> stat succeeds, separator printed, NOTHING after it (never opens it), well inside the timeout');
        }
    }
}

# ====================================================================================================
# AC11 (B12) -- intent_log_fields, plus structural checks on launcher.pl.
# ====================================================================================================
{
    my @f1 = call_log_fields({ state => 'ok', reason => 'running' });
    is_deeply(\@f1, [ reason => 'running' ], 'AC11/B12: reason only -> (reason=>R)');
    my @f2 = call_log_fields({ state => 'ok', reason => 'running', until => 1_793_600_000 });
    is_deeply(\@f2, [ reason => 'running', until => 1_793_600_000 ], 'AC11/B12: reason+until -> both pairs, in order');
    my @f3 = call_log_fields({ state => 'ok' });
    is_deeply(\@f3, [], 'AC11/B12: neither key -> ()');
    my @f4 = call_log_fields(undef);
    is_deeply(\@f4, [], 'AC11/B12: undef -> ()');
    my @f5 = call_log_fields('x');
    is_deeply(\@f5, [], 'AC11/B12: a non-HASH -> ()');

    my $code = code_lines($LAUNCHER_SRC // '');
    my ($kd_block) = $code =~ /log_ev\('keepawake_decision',\s*(\{.*?\n\s*\}\));/s;
    ok(defined $kd_block, 'AC11 precondition: the keepawake_decision log_ev call is extractable')
        or diag('the log_ev(\'keepawake_decision\', { ... }) call was not found as a single balanced-ish block');
    $kd_block = '' unless defined $kd_block;
    like($kd_block, qr/KeepAwake::intent_log_fields\(\$st->\{lease_probe\}\)/s,
        'AC11: the keepawake_decision log_ev hash includes KeepAwake::intent_log_fields($st->{lease_probe})');
    for my $field (qw(want held busy_age stale probe detail action)) {
        like($kd_block, qr/\b\Q$field\E\b/s,
            "AC11: the keepawake_decision event still names '$field'");
    }
    my ($lp_block) = $code =~ /lease_probe\s*=>\s*(\{(?:[^{}]|(?1))*\})/s;
    ok(defined $lp_block, 'AC11 precondition: the gather\'s lease_probe hash literal is extractable (balanced braces)')
        or diag('lease_probe => { ... } was not found as a balanced-brace hash literal');
    $lp_block = '' unless defined $lp_block;
    like($lp_block, qr/reason\s*=>\s*\$cached_probe_result->\{reason\}/s,
        'AC11: the gather\'s lease_probe hash copies reason from $cached_probe_result');
    like($lp_block, qr/until\s*=>\s*\$cached_probe_result->\{until\}/s,
        'AC11: the gather\'s lease_probe hash copies until from $cached_probe_result');
}

# ====================================================================================================
# AC12 (B13) -- DC4: a new launcher reading an old orchestrator's lease still decides the same.
# ====================================================================================================
SKIP: {
    skip 'precondition failed: cannot drive the extracted probe', 8
        unless $eval_ok && $PROBE_PKG->can('_busy_lease_probe');

    my ($fresh, undef) = probe_with(
        FAKE_STAT_OUT => "$LMT\n${SEP}",
        FAKE_STAT_RC  => 0,
        FAKE_CLOCK    => "$CNOW\n",
    );
    my $ka1 = KeepAwake->new(start => sub { 'h' }, stop => sub { });
    is($ka1->on_probe($fresh, 600, 3), 'start', 'AC12: a fresh empty-content probe -> start');
    ok($ka1->running, 'AC12: ... and the holder is running');

    my ($stale, undef) = probe_with(
        FAKE_STAT_OUT => "$LMT\n${SEP}",
        FAKE_STAT_RC  => 0,
        FAKE_CLOCK    => ($LMT + 601) . "\n",
    );
    my $ka2 = KeepAwake->new(start => sub { 'h' }, stop => sub { });
    is($ka2->on_probe($stale, 600, 3), 'noop', 'AC12: a stale empty-content probe -> noop (never ran)');
    ok(!$ka2->running, 'AC12: ... and the holder is not running');

    # B13: the same action for a bare {state=>'ok',age=>A} and an {... reason,until} shape, every A.
    for my $age (5, 600, 601, -3) {
        my $plain  = { state => 'ok', age => $age };
        my $richer = { state => 'ok', age => $age, reason => 'pause-pending', until => 1_793_600_000 };
        my $ka_a = KeepAwake->new(start => sub { 'h' }, stop => sub { });
        my $ka_b = KeepAwake->new(start => sub { 'h' }, stop => sub { });
        my $act_a = $ka_a->on_probe($plain, 600, 3);
        my $act_b = $ka_b->on_probe($richer, 600, 3);
        is($act_b, $act_a, "AC12/B13: age=$age: on_probe gives the same action with or without reason/until");
    }
}

# ====================================================================================================
# AC13 -- DC4: a new orchestrator's lease is still read correctly by old mtime-only readers.
# ====================================================================================================
{
    my $dir = tempdir(CLEANUP => 1);
    my $lease = "$dir/busy";

    my $rv = call_touch_busy($lease, { awake => 1, reason => 'running', until => undef });
    is($rv, 1, 'AC13 precondition: touch_busy wrote the lease');

    # (a) heartbeat.sh, sourced, exactly reap-decision.t's own pattern.
    my $HB_FILE = "$SANDBOX_SCRIPTS/../container/heartbeat.sh";
    if (-f $HB_FILE) {
        local %ENV = (%ENV, HBFILE => $HB_FILE, BUSY => $lease, HB => 600);
        chomp(my $out = `bash -c 'source "\$HBFILE" >/dev/null 2>&1; busy_fresh \$(date +%s)' 2>&1`);
        is($out, '1', 'AC13(a): heartbeat.sh busy_fresh reads the new lease as fresh (mtime-only)');
    } else {
        fail('AC13(a): container/heartbeat.sh is missing, cannot prove the mtime-only read');
    }

    # (b) today's launcher read, run locally (never spawns launcher.pl/podman).
    my $stat_out = `sh -c 'stat -c %Y "$lease"' 2>&1`;
    my ($age_from_stat) = ($stat_out =~ /^(\d+)/);
    ok(defined $age_from_stat, 'AC13(b) precondition: today\'s stat parse recovers the lease mtime');
    if (defined $age_from_stat) {
        my $now = time;
        my $age = $now - $age_from_stat;
        $age = 0 if $age < 0;
        is(KeepAwake::should_stay_awake($age, 600), 1, 'AC13(b): should_stay_awake(age,600) == 1 for a freshly-touched lease');
        is(KeepAwake->new(start => sub { 'h' }, stop => sub { })->on_probe({ state => 'ok', age => $age }, 600, 3),
            'start', 'AC13(b): on_probe({state=>ok,age},600,3) eq start');
    }
}

done_testing();
