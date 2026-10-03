#!/usr/bin/env perl
# platform: windows
# 08-blueprint-parks — immutable oracle for the "a parked blueprint says so in
# its own blueprint.md" package (where-things-go blueprint). Derived ONLY from
# .ccpraxis-local-data/blueprints/where-things-go/specs/08-blueprint-parks-spec.md
# -- never from any implementation of bp-drive-next.pl/bp-blueprint.pl/BpState.pm.
#
# Coverage here: AC4 (B16/B17/B18/B19, migration), AC5 (static: parks.json is
# named only inside bp-drive-next.pl's _migrate_parks_json, nowhere else
# outside tests/), AC6 (B6, park --needs-operator files one inbox item),
# AC7 (B7/B9/B10, unparking closes the item), AC8 (B8, a close failure exits 4
# and leaves blueprint.md untouched), AC13's B21 half (set-meta's parked-
# specific refusals), AC14 (template + refusal message list parked), and
# B14/AC11 (bp-status.sh shows parked).
#
# None of this exists yet on the current tree: bp-drive-next.pl has no
# _migrate_parks_json, BpState doesn't know 'parked', bp-blueprint.pl's
# set-meta has no --reason and no inbox-closing hook. Every assertion below is
# expected to fail for that reason -- absence of implementation, not a defect
# in this oracle.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path remove_tree);
use File::Find ();
use File::Spec ();
use Cwd qw(abs_path);
use Encode qw(decode);

# Decision 29: never let a test touch the operator's real vault. Pinned
# BEFORE almanac-inbox.pl is required (AC15).
my $FAKE_HOME = tempdir(CLEANUP => 1);
$ENV{HOME}        = $FAKE_HOME;
$ENV{USERPROFILE} = $FAKE_HOME;
$ENV{ALMANAC_HOME} = $FAKE_HOME;

my $SCRIPTS        = "$Bin/../../scripts";
my $DRIVE          = "$SCRIPTS/bp-drive-next.pl";
my $BLUEPRINT      = "$SCRIPTS/bp-blueprint.pl";
my $STATUS_SH      = "$SCRIPTS/bp-status.sh";
my $BPSTATE        = "$SCRIPTS/BpState.pm";
my $RUNSTATE       = "$Bin/../../../sandbox/scripts/RunState.pm";
my $INBOX_SCRIPT   = "$Bin/../../../almanac/scripts/almanac-inbox.pl";
my $TEMPLATE       = "$Bin/../../../blueprint/templates/blueprint.md";
my $PLUGINS_ROOT   = abs_path("$Bin/../../..");

ok(-f $DRIVE,     'bp-drive-next.pl exists') or BAIL_OUT('nothing to test');
ok(-f $BLUEPRINT, 'bp-blueprint.pl exists')  or BAIL_OUT('nothing to test');

my $LOADED = do { local $@; eval { require $DRIVE }; !$@ };
ok($LOADED, 'bp-drive-next.pl loads as BpDrive') or diag($@);

require $INBOX_SCRIPT;   # Almanac::Inbox

my $J   = JSON::PP->new->canonical;
my $JU  = JSON::PP->new->utf8->canonical;
my $NOW = 1_830_297_600;

# ═══════════════════════════════════════════════════════════════════════════
# Scaffolding
# ═══════════════════════════════════════════════════════════════════════════

# Pre-implementation, a chain of calls that assumes an earlier step worked
# (e.g. "read the item park --needs-operator just filed") can die outright
# once that earlier step silently did nothing (no item at all). A die here
# must fail ONE assertion and let every later, independent section still run
# -- never abort the whole file (fleet-inbox-bridge.t's own house pattern).
sub run_group {
    my ($label, $code) = @_;
    my $ok = eval { $code->(); 1 };
    fail("$label -- group errored (expected pre-implementation cascade, not an oracle bug): $@") unless $ok;
}

sub write_file {
    my ($path, $content) = @_;
    my $d = $path; $d =~ s{[\\/][^\\/]+\z}{};
    make_path($d) unless -d $d;
    open my $fh, '>:raw', $path or die "write $path: $!";
    print $fh $content;
    close $fh;
}

sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

sub write_json      { my ($p, $d) = @_; write_file($p, $J->encode($d)); }
sub write_json_utf8 { my ($p, $d) = @_; write_file($p, $JU->encode($d)); }

sub read_json {
    my ($path) = @_;
    my $c = slurp($path);
    return undef unless defined $c;
    return eval { $J->decode($c) };
}

# A project <P> with <P>/.ccpraxis-local-data/blueprints/<name>/, matching
# spec §2.2's "<root>/.ccpraxis-local-data/blueprints/<bp>" shape (needed for
# the inbox-closing hook's project-root derivation).
sub make_bp_dir {
    my ($proj, $name, %o) = @_;
    my $bp = "$proj/.ccpraxis-local-data/blueprints/$name";
    make_path("$bp/packages");
    my $fence = '';
    if (defined $o{status}) {
        $fence = "```\nstatus: $o{status}\n";
        $fence .= "parked_reason: $o{reason}\n" if defined $o{reason};
        $fence .= "```\n\n";
    }
    my $md = "# $name\n\n$fence" . "## Package status\n\n"
           . "| pkg | deliverable | depends_on | model | status |\n"
           . "|-----|-------------|------------|-------|--------|\n";
    for my $p (@{ $o{packages} || [] }) {
        $md .= "| $p->{key} | thing | — | sonnet | $p->{status} |\n";
    }
    write_file("$bp/blueprint.md", $md);
    for my $p (@{ $o{packages} || [] }) {
        write_file("$bp/packages/$p->{key}.md",
            "---\npackage: $p->{key}\nblueprint: $name\nstatus: $p->{status}\n"
          . "model: sonnet\nmax_turns: 80\nwrite_set: x/\ntest_paths: x/\n"
          . "last_updated: 2028-01-01T00:00:00Z\n---\n\n# $p->{key}\n");
    }
    return $bp;
}

# Append a fenced block to a blueprint.md that currently has none (B17 repair
# step), or to add a second independent fence is never needed here -- every
# fixture that needs a fence gets one from make_bp_dir at creation time.
sub write_bp_status_fence {
    my ($bp_dir, $status, $reason) = @_;
    open my $fh, '>>:raw', "$bp_dir/blueprint.md" or die "append fence: $!";
    print $fh "\n```\nstatus: $status\n";
    print $fh "parked_reason: $reason\n" if defined $reason;
    print $fh "```\n";
    close $fh;
}

sub bp_status_of {
    my ($file) = @_;
    my $c = slurp($file) // '';
    return '' unless $c =~ /^```\s*\n((?:.*\n)*?)^```\s*$/m;
    my $b = $1;
    return '' unless $b =~ /^status:[ \t]*([^\n#]*)/m;
    my $v = $1; $v =~ s/\s+\z//; return $v;
}

sub bp_field_of {
    my ($file, $field) = @_;
    my $c = slurp($file) // '';
    return undef unless $c =~ /^```\s*\n((?:.*\n)*?)^```\s*$/m;
    my $b = $1;
    my $fq = quotemeta $field;
    return undef unless $b =~ /^$fq:[ \t]*([^\n#]*)/m;
    my $v = $1; $v =~ s/\s+\z//; return $v;
}

# ── bp-drive-next.pl (in-process), the drive-next.t idiom ──────────────────
sub run_director {
    my ($argv, $opts) = @_;
    $opts //= {};
    $opts->{now}                  //= sub { $NOW };
    $opts->{verdict}              //= sub { { action => 'ok' } };
    $opts->{spawn}                //= sub { };
    $opts->{kill_pid}             //= sub { };
    $opts->{powershell_available} //= sub { 0 };
    BpDrive::run($argv, $opts);
}

sub capture_run {
    my ($argv, $opts) = @_;
    my ($ofh, $opath) = tempfile('bp08-outXXXXXX', TMPDIR => 1); close $ofh;
    my ($efh, $epath) = tempfile('bp08-errXXXXXX', TMPDIR => 1); close $efh;
    open my $oldout, '>&STDOUT' or die "dup STDOUT: $!";
    open my $olderr, '>&STDERR' or die "dup STDERR: $!";
    open STDOUT, '>:raw', $opath or do { open STDOUT, '>&', $oldout; die "reopen STDOUT: $!" };
    open STDERR, '>:raw', $epath or do { open STDERR, '>&', $olderr; die "reopen STDERR: $!" };
    $| = 1;
    my $rc  = eval { run_director($argv, $opts) };
    my $err = $@;
    open STDOUT, '>&', $oldout or die "restore STDOUT: $!"; close $oldout;
    open STDERR, '>&', $olderr or die "restore STDERR: $!"; close $olderr;
    my $out  = slurp($opath) // '';
    my $eout = slurp($epath) // '';
    unlink $opath, $epath;
    die $err if $err;
    return ($rc, $out, $eout);
}

# ── bp-blueprint.pl (real subprocess), the lifecycle-derived.t idiom ───────
sub run_bp_blueprint {
    my (@args) = @_;
    my ($ofh, $otmp) = tempfile('bp08-bp-outXXXXXX', TMPDIR => 1); close $ofh;
    my ($efh, $etmp) = tempfile('bp08-bp-errXXXXXX', TMPDIR => 1); close $efh;
    open(my $so, '>&', \*STDOUT) or die "dup out: $!";
    open(my $se, '>&', \*STDERR) or die "dup err: $!";
    open(STDOUT, '>', $otmp) or die "redirect out: $!";
    open(STDERR, '>', $etmp) or die "redirect err: $!";
    my $rc = system($^X, $BLUEPRINT, @args);
    open(STDOUT, '>&', $so); open(STDERR, '>&', $se);
    close $so; close $se;
    my $out = slurp($otmp) // ''; unlink $otmp;
    my $err = slurp($etmp) // ''; unlink $etmp;
    return (($rc == -1 ? -1 : $rc >> 8), $out, $err);
}

# ── bp-status.sh (real bash subprocess), the status-recognition.t idiom ────
sub run_status {
    my ($data_dir, $arg) = @_;
    my ($ofh, $opath) = tempfile('bp08-st-outXXXXXX', TMPDIR => 1); close $ofh;
    my ($efh, $epath) = tempfile('bp08-st-errXXXXXX', TMPDIR => 1); close $efh;
    (my $script_fwd = $STATUS_SH) =~ s{\\}{/}g;
    local %ENV = %ENV;
    $ENV{CCPRAXIS_DATA_DIR} = $data_dir;
    $ENV{SCRIPTPATH} = $script_fwd;
    $ENV{OUTF} = $opath;
    $ENV{ERRF} = $epath;
    my @args = defined $arg ? ($arg) : ();
    open(my $f, '-|', 'bash', '-c', 'bash "$SCRIPTPATH" "$@" >"$OUTF" 2>"$ERRF"', 'h', @args)
        or die "bash: $!";
    my $discard = do { local $/; <$f> }; close $f;
    my $rc = $? >> 8;
    return ($rc, slurp($opath) // '', slurp($epath) // '');
}

# ═══════════════════════════════════════════════════════════════════════════
# AC4 (DC2) — B16: a fixture parks.json migrates idempotently and is removed.
# ═══════════════════════════════════════════════════════════════════════════
{
    my $proj = tempdir(CLEANUP => 1); $proj =~ s{\\}{/}g;
    my $data = "$proj/.ccpraxis-local-data";
    my $bp_a = make_bp_dir($proj, 'A', status => 'audited', packages => [{key=>'p1', status=>'pending'}]);
    my $bp_b = make_bp_dir($proj, 'B', status => 'parked', reason => 'already parked');
    # C is listed but has no directory on disk at all.
    make_path("$data/.drive-solo");
    write_json("$data/.drive-solo/order.json", { order => ['A'], recorded_at => $NOW });

    my $em_dash_reason = "stale \x{2014} superseded";   # byte-exact UTF-8 round-trip (E6)
    write_json_utf8("$data/.drive-solo/parks.json", [
        { blueprint => 'A', reason => $em_dash_reason, at => $NOW },
        { blueprint => 'B', reason => 'ignored, already parked', at => $NOW },
        { blueprint => 'C', reason => 'ghost, not on disk', at => $NOW },
        'not-a-hash-element',
    ]);
    my $b_before = slurp("$bp_b/blueprint.md");

    my ($rc, $out, $err) = capture_run(['next', '--scope', 'A'], { data_dir => $data });
    is($rc, 0, 'B16: the call exits 0 after migrating');
    is(bp_status_of("$bp_a/blueprint.md"), 'parked', 'B16: A is parked');
    my $a_reason = bp_field_of("$bp_a/blueprint.md", 'parked_reason');
    is(decode('UTF-8', $a_reason), $em_dash_reason, 'B16: A\'s reason survives byte-exact, including the em dash');
    is(slurp("$bp_b/blueprint.md"), $b_before, 'B16: B (already parked) is left byte-identical');
    ok(!-d "$data/blueprints/C", 'B16: C never gets a directory created for it');
    ok(!-e "$data/.drive-solo/parks.json", 'B16: parks.json is gone');
    my $run_md = slurp("$data/.drive-solo/run.md") // '';
    like($run_md, qr/PARKS-MIGRATED/, 'B16: run.md records PARKS-MIGRATED');

    # A second call writes nothing further and logs no further PARKS-MIGRATED.
    my $a_after_1 = slurp("$bp_a/blueprint.md");
    my ($rc2, $out2) = capture_run(['next', '--scope', 'A'], { data_dir => $data });
    is($rc2, 0, 'B16: second call exits 0');
    is(slurp("$bp_a/blueprint.md"), $a_after_1, 'B16: A is unchanged by the second call');
    my @migrated_lines = ((slurp("$data/.drive-solo/run.md") // '') =~ /PARKS-MIGRATED/g);
    is(scalar(@migrated_lines), 1, 'B16: PARKS-MIGRATED is logged exactly once, ever');
}

# ═══════════════════════════════════════════════════════════════════════════
# AC4 (DC2) — B17: migration failure (no fenced status: line) fails closed.
# ═══════════════════════════════════════════════════════════════════════════
{
    my $proj = tempdir(CLEANUP => 1); $proj =~ s{\\}{/}g;
    my $data = "$proj/.ccpraxis-local-data";
    my $bp_ok  = make_bp_dir($proj, 'OK',  status => 'audited', packages => [{key=>'p1', status=>'pending'}]);
    my $bp_bad = make_bp_dir($proj, 'BAD', status => undef,     packages => [{key=>'p1', status=>'pending'}]);
    make_path("$data/.drive-solo");
    write_json("$data/.drive-solo/order.json", { order => ['OK', 'BAD'], recorded_at => $NOW });
    write_json("$data/.drive-solo/parks.json", [
        { blueprint => 'OK',  reason => 'fine' },
        { blueprint => 'BAD', reason => 'no fence to write into' },
    ]);

    my ($rc, $out, $err) = capture_run(['next', '--scope', 'all'], { data_dir => $data });
    is($rc, 2, 'B17: migration failure returns 2');
    is($out, '', 'B17: STDOUT is empty');
    like($err, qr/BAD/, 'B17: STDERR names the failing blueprint');
    ok(-e "$data/.drive-solo/parks.json", 'B17: parks.json is left untouched on failure');
    is(bp_status_of("$bp_ok/blueprint.md"), 'parked', 'B17: the already-succeeded entry (OK) stays parked');

    # Repair BAD and retry -- idempotent, OK is not re-logged, BAD completes.
    write_bp_status_fence($bp_bad, 'audited');
    my ($rc2, $out2, $err2) = capture_run(['next', '--scope', 'all'], { data_dir => $data });
    is($rc2, 0, 'B17: after repair, the retry completes the migration');
    is(bp_status_of("$bp_bad/blueprint.md"), 'parked', 'B17: BAD is now parked too');
    ok(!-e "$data/.drive-solo/parks.json", 'B17: parks.json is finally removed');
}

# ═══════════════════════════════════════════════════════════════════════════
# AC4 (DC2) — B18: a corrupt parks.json is moved aside, never blocks the call.
# ═══════════════════════════════════════════════════════════════════════════
{
    my $proj = tempdir(CLEANUP => 1); $proj =~ s{\\}{/}g;
    my $data = "$proj/.ccpraxis-local-data";
    my $bp = make_bp_dir($proj, 'X', status => 'audited', packages => [{key=>'p1', status=>'pending'}]);
    make_path("$data/.drive-solo");
    write_json("$data/.drive-solo/order.json", { order => ['X'], recorded_at => $NOW });
    write_file("$data/.drive-solo/parks.json", "{ this is not valid json at all ");

    my ($rc, $out, $err) = capture_run(['next', '--scope', 'all'], { data_dir => $data });
    is($rc, 0, 'B18: a corrupt (unparsable) parks.json does not fail the call');
    ok(!-e "$data/.drive-solo/parks.json", 'B18: the corrupt file no longer sits at the original name');
    my @corrupt = glob("$data/.drive-solo/parks.json.corrupt-*");
    is(scalar(@corrupt), 1, 'B18: moved aside to parks.json.corrupt-<epoch>');
    my $run_md = slurp("$data/.drive-solo/run.md") // '';
    like($run_md, qr/WARN PARKS-MIGRATE:.*moved aside/, 'B18: a WARN line is logged');
    is(bp_status_of("$bp/blueprint.md"), 'audited', 'B18: no blueprint is parked as a result');
}
{
    # Syntactically valid JSON that is not an array -- the OTHER corrupt shape.
    my $proj = tempdir(CLEANUP => 1); $proj =~ s{\\}{/}g;
    my $data = "$proj/.ccpraxis-local-data";
    make_bp_dir($proj, 'X2', status => 'audited', packages => [{key=>'p1', status=>'pending'}]);
    make_path("$data/.drive-solo");
    write_json("$data/.drive-solo/order.json", { order => ['X2'], recorded_at => $NOW });
    write_json("$data/.drive-solo/parks.json", { not => 'an array' });

    my ($rc, $out, $err) = capture_run(['next', '--scope', 'all'], { data_dir => $data });
    is($rc, 0, 'B18(not-an-array): valid JSON that is not an array also does not fail the call');
    ok(!-e "$data/.drive-solo/parks.json", 'B18(not-an-array): moved aside too');
}

# ═══════════════════════════════════════════════════════════════════════════
# AC4 (DC2) — B19: a missing parks.json leaves everything as-is, logs nothing.
# ═══════════════════════════════════════════════════════════════════════════
{
    my $proj = tempdir(CLEANUP => 1); $proj =~ s{\\}{/}g;
    my $data = "$proj/.ccpraxis-local-data";
    make_bp_dir($proj, 'Y', status => 'audited', packages => [{key=>'p1', status=>'pending'}]);
    make_path("$data/.drive-solo");
    write_json("$data/.drive-solo/order.json", { order => ['Y'], recorded_at => $NOW });
    ok(!-e "$data/.drive-solo/parks.json", 'B19 precondition: no parks.json exists');

    my ($rc, $out, $err) = capture_run(['next', '--scope', 'all'], { data_dir => $data });
    is($rc, 0, 'B19: exits 0 with no parks.json');
    my $run_md = slurp("$data/.drive-solo/run.md") // '';
    unlike($run_md, qr/PARKS-MIGRAT/, 'B19: nothing about migration is logged');
}

# ═══════════════════════════════════════════════════════════════════════════
# AC5 — static: parks.json is named only inside bp-drive-next.pl's
# _migrate_parks_json, nowhere else outside tests/; bp-status.sh, RunState.pm
# and BpState.pm name no 'parks' at all.
# ═══════════════════════════════════════════════════════════════════════════
{
    my @hits;
    File::Find::find({ wanted => sub {
        return unless -f $_;
        my $rel = File::Spec->abs2rel($File::Find::name, $PLUGINS_ROOT);
        $rel =~ s{\\}{/}g;
        return if $rel =~ m{(^|/)tests/};
        my $c = slurp($File::Find::name) // '';
        push @hits, $rel if $c =~ /parks\.json/;
    }, no_chdir => 1 }, $PLUGINS_ROOT);
    is_deeply([sort @hits], ['butler/scripts/bp-drive-next.pl'],
        'AC5: parks.json is named only in bp-drive-next.pl outside tests/');
}
{
    my $src = slurp($DRIVE) // '';
    my $total = () = ($src =~ /parks\.json/g);
    my $sub_at = index($src, 'sub _migrate_parks_json');
    ok($sub_at >= 0, 'AC5: bp-drive-next.pl defines sub _migrate_parks_json');
    my $in_sub = 0;
    if ($sub_at >= 0) {
        my $brace = index($src, '{', $sub_at);
        if ($brace >= 0) {
            my $depth = 0; my $i = $brace; my $len = length($src);
            for (; $i < $len; $i++) {
                my $c = substr($src, $i, 1);
                if    ($c eq '{') { $depth++ }
                elsif ($c eq '}') { $depth--; last if $depth == 0 }
            }
            my $block = substr($src, $brace, $i - $brace + 1);
            $in_sub = () = ($block =~ /parks\.json/g);
        }
    }
    is($in_sub, $total, 'AC5: every parks.json occurrence lies inside _migrate_parks_json\'s body');
}
{
    for my $f ($STATUS_SH, $BPSTATE, $RUNSTATE) {
        SKIP: {
            skip "$f not found", 1 unless -f $f;
            my $c = slurp($f) // '';
            unlike($c, qr/parks/i, "AC5: " . (File::Spec->abs2rel($f, $PLUGINS_ROOT) =~ s{\\}{/}gr) . " contains no 'parks' at all");
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# AC6 — B6: park --needs-operator files exactly one inbox item; plain park
# files none and never creates the inbox store.
# ═══════════════════════════════════════════════════════════════════════════
run_group('B6', sub {
    my $P = tempdir(CLEANUP => 1); $P =~ s{\\}{/}g;
    my $data = "$P/.ccpraxis-local-data";
    my $bp = make_bp_dir($P, 'needs-op', status => 'audited', packages => [{key=>'p1', status=>'pending'}]);

    my ($rc) = capture_run(['park', 'needs-op', '--needs-operator', 'operator must decide'], { data_dir => $data });
    is($rc, 0, 'B6: park --needs-operator exits 0');
    is(bp_status_of("$bp/blueprint.md"), 'parked', 'B6: blueprint is parked');

    my @items = @{ Almanac::Inbox::list_items(root => $P) };
    is(scalar(@items), 1, 'B6: exactly one inbox item filed');
    is($items[0]{fields}{link}, 'needs-op', 'B6: the item links to the blueprint (bare <bp>)');
    is($items[0]{fields}{status}, 'unanswered', 'B6: the item starts unanswered');
    like($items[0]{fields}{title}, qr/^Blueprint needs-op parked: operator must decide/,
        'B6: the title starts "Blueprint <bp> parked: <reason>"');

    my ($rc2) = capture_run(['park', 'needs-op', '--needs-operator', 'operator must decide'], { data_dir => $data });
    is($rc2, 0, 'B6: repeating park --needs-operator exits 0 (already parked -- no second write)');
    my @items2 = @{ Almanac::Inbox::list_items(root => $P) };
    is(scalar(@items2), 1, 'B6: still exactly one inbox item (no duplicate filed)');
});
{
    my $P = tempdir(CLEANUP => 1); $P =~ s{\\}{/}g;
    my $data = "$P/.ccpraxis-local-data";
    make_bp_dir($P, 'plain', status => 'audited', packages => [{key=>'p1', status=>'pending'}]);
    my ($rc) = capture_run(['park', 'plain', 'just because'], { data_dir => $data });
    is($rc, 0, 'B6: plain park exits 0');
    ok(!-d "$data/almanac/inbox", 'B6: a plain park never creates the inbox store');
}

# ═══════════════════════════════════════════════════════════════════════════
# AC7 — B7/B9/B10: unparking closes the park's item (CAS to answered); a
# second status write is a no-op; an operator-answered item is left alone; a
# park item for A is never closed by unparking B, and a title mismatch never
# closes either.
# ═══════════════════════════════════════════════════════════════════════════
run_group('B7/B9', sub {
    my $P = tempdir(CLEANUP => 1); $P =~ s{\\}{/}g;
    my $data = "$P/.ccpraxis-local-data";
    my $bp = make_bp_dir($P, 'bp-close', status => 'audited', packages => [{key=>'p1', status=>'pending'}]);
    my ($rc0) = capture_run(['park', 'bp-close', '--needs-operator', 'needs a human'], { data_dir => $data });
    is($rc0, 0, 'B7 setup: park --needs-operator exits 0');
    my @items0 = @{ Almanac::Inbox::list_items(root => $P) };
    is(scalar(@items0), 1, 'B7 setup: exactly one item filed');
    my $item_id = $items0[0]{id};

    my ($rc1, $o1, $e1) = run_bp_blueprint('set-meta', '--file', "$bp/blueprint.md",
        '--field', 'status', '--value', 'audited');
    is($rc1, 0, 'B7: unpark (set-meta --value audited) exits 0') or diag($e1);
    is(bp_status_of("$bp/blueprint.md"), 'audited', 'B7: blueprint.md now says audited');
    ok(!defined bp_field_of("$bp/blueprint.md", 'parked_reason'), 'B7: parked_reason removed');

    my $after = Almanac::Inbox::read_item($item_id, root => $P);
    is($after->{fields}{status}, 'answered', 'B7: the park item is now answered');
    ok(exists $after->{fields}{closed_at}, 'B7: closed_at present');
    like($after->{fields}{closed_reason}, qr/parked.*audited/is, 'B7: closed_reason names the new status');
    like($after->{fields}{closed_reason}, qr/needs a human/, 'B7: closed_reason carries the park reason');
    is($after->{fields}{closed_by}, 'bp-blueprint.pl set-meta', 'B7: closed_by names the writer');

    # B9: a second, unrelated status write after the item is already closed.
    my $rev_before = $after->{rev};
    my ($rc2) = run_bp_blueprint('set-meta', '--file', "$bp/blueprint.md", '--field', 'status', '--value', 'drafting');
    is($rc2, 0, 'B9: a later status write (blueprint already non-parked) exits 0');
    my $still = Almanac::Inbox::read_item($item_id, root => $P);
    is($still->{rev}, $rev_before, 'B9: the already-closed item is untouched by a later, unrelated status write');
});
{
    # B9 (operator-answered variant): an item already answered by a human
    # (status answered, NO closed_at) is never modified by the unpark.
    my $P = tempdir(CLEANUP => 1); $P =~ s{\\}{/}g;
    my $data = "$P/.ccpraxis-local-data";
    my $bp = make_bp_dir($P, 'bp-op', status => 'parked', reason => 'awaiting word');
    my $item = Almanac::Inbox::file(root => $P, title => 'Blueprint bp-op parked: awaiting word', link => 'bp-op');
    my $store = Almanac::Inbox::open_inbox(root => $P);
    $store->update($item->{id}, expect => { rev => $item->{rev}, fields => $item->{fields} },
                    set => { status => 'answered' });
    my $answered = Almanac::Inbox::read_item($item->{id}, root => $P);
    ok(!exists $answered->{fields}{closed_at}, 'B9 precondition: operator-answered item carries no closed_at');

    my ($rc) = run_bp_blueprint('set-meta', '--file', "$bp/blueprint.md", '--field', 'status', '--value', 'audited');
    is($rc, 0, 'B9: unpark over an operator-answered item exits 0');
    my $after = Almanac::Inbox::read_item($item->{id}, root => $P);
    is($after->{rev}, $answered->{rev}, 'B9: an operator-answered item (no closed_at) is left completely alone');
    ok(!exists $after->{fields}{closed_at}, 'B9: ...still no closed_at');
}
{
    # B10: a park item for A is never closed by unparking B; a same-link item
    # whose title does not match the park-item shape is never closed either.
    my $P = tempdir(CLEANUP => 1); $P =~ s{\\}{/}g;
    my $data = "$P/.ccpraxis-local-data";
    my $bpA = make_bp_dir($P, 'A', status => 'parked', reason => 'a reason');
    my $bpB = make_bp_dir($P, 'B', status => 'parked', reason => 'b reason');
    my $itemA        = Almanac::Inbox::file(root => $P, title => 'Blueprint A parked: a reason', link => 'A');
    my $itemMismatch = Almanac::Inbox::file(root => $P, title => 'Something else entirely',      link => 'B');

    my ($rc) = run_bp_blueprint('set-meta', '--file', "$bpB/blueprint.md", '--field', 'status', '--value', 'audited');
    is($rc, 0, 'B10: unparking B exits 0');

    my $afterA = Almanac::Inbox::read_item($itemA->{id}, root => $P);
    is($afterA->{fields}{status}, 'unanswered', "B10: A's park item is untouched by unparking B");
    my $afterMismatch = Almanac::Inbox::read_item($itemMismatch->{id}, root => $P);
    is($afterMismatch->{fields}{status}, 'unanswered',
        'B10: a same-link item whose title does not match "Blueprint <bp> parked:" is never closed');
}

# ═══════════════════════════════════════════════════════════════════════════
# AC8 — B8: a close failure (half_migrated inbox) exits 4 and leaves
# blueprint.md byte-identical; a retry after the cause is fixed succeeds.
# ═══════════════════════════════════════════════════════════════════════════
{
    my $P = tempdir(CLEANUP => 1); $P =~ s{\\}{/}g;
    my $data = "$P/.ccpraxis-local-data";
    my $bp = make_bp_dir($P, 'bp-fail', status => 'parked', reason => 'blocked');
    make_path("$data/almanac/decision");   # legacy dir
    make_path("$data/almanac/inbox");      # target dir -- BOTH exist => half_migrated
    my $before = slurp("$bp/blueprint.md");

    my ($rc, $out, $err) = run_bp_blueprint('set-meta', '--file', "$bp/blueprint.md",
        '--field', 'status', '--value', 'audited');
    is($rc, 4, 'B8: unpark exits 4 when the inbox cannot be closed (half_migrated)');
    is(slurp("$bp/blueprint.md"), $before, 'B8: blueprint.md is byte-identical on failure');
    like($err, qr/inbox/i, 'B8: stderr names the inbox');

    remove_tree("$data/almanac/decision");
    my ($rc2) = run_bp_blueprint('set-meta', '--file', "$bp/blueprint.md",
        '--field', 'status', '--value', 'audited');
    is($rc2, 0, 'B8: a retry after the cause is fixed succeeds');
    is(bp_status_of("$bp/blueprint.md"), 'audited', 'B8: the blueprint is now unparked');
}

# ═══════════════════════════════════════════════════════════════════════════
# AC13 (B21) — set-meta's parked-specific refusals, each leaving the file
# byte-identical.
# ═══════════════════════════════════════════════════════════════════════════
{
    my $P = tempdir(CLEANUP => 1); $P =~ s{\\}{/}g;
    my $bp = make_bp_dir($P, 'meta-refuse', status => 'audited');
    my $file = "$bp/blueprint.md";
    my $before = slurp($file);

    my ($rc1) = run_bp_blueprint('set-meta', '--file', $file, '--field', 'status', '--value', 'parked');
    is($rc1, 3, 'B21: --value parked without --reason exits 3');
    is(slurp($file), $before, 'B21: file untouched');

    my ($rc2) = run_bp_blueprint('set-meta', '--file', $file, '--field', 'status',
        '--value', 'audited', '--reason', 'nope');
    is($rc2, 3, 'B21: --reason with a non-parked value exits 3');
    is(slurp($file), $before, 'B21: file untouched');

    my ($rc3) = run_bp_blueprint('set-meta', '--file', $file, '--field', 'parked_reason', '--value', 'x');
    is($rc3, 3, 'B21: --field parked_reason always refuses');
    is(slurp($file), $before, 'B21: file untouched');
}

# ═══════════════════════════════════════════════════════════════════════════
# AC14 — the template lists parked; bp-blueprint.pl's refusal message lists
# drafting, audited, parked, archived.
# ═══════════════════════════════════════════════════════════════════════════
{
    my $tmpl = slurp($TEMPLATE);
    ok(defined $tmpl, 'AC14: blueprint template exists') or diag("expected $TEMPLATE");
    like($tmpl, qr/status:\s*drafting\s+#.*\bparked\b/, 'AC14: the template lists parked in the status comment')
        if defined $tmpl;
}
{
    my $P = tempdir(CLEANUP => 1); $P =~ s{\\}{/}g;
    my $bp = make_bp_dir($P, 'refusal-msg', status => 'audited');
    my (undef, undef, $err) = run_bp_blueprint('set-meta', '--file', "$bp/blueprint.md",
        '--field', 'status', '--value', 'running');
    like($err, qr/\bdrafting\b/, 'AC14: refusal message lists drafting');
    like($err, qr/\baudited\b/,  'AC14: refusal message lists audited');
    like($err, qr/\bparked\b/,   'AC14: refusal message lists parked');
    like($err, qr/\barchived\b/, 'AC14: refusal message lists archived');
}

# ═══════════════════════════════════════════════════════════════════════════
# AC11 — B14: bp-status.sh prints "(blueprint status: parked)", with or
# without a live marker.
# ═══════════════════════════════════════════════════════════════════════════
{
    my $P = tempdir(CLEANUP => 1); $P =~ s{\\}{/}g;
    my $data = "$P/.ccpraxis-local-data";
    make_bp_dir($P, 'shown-parked', status => 'parked', reason => 'waiting',
        packages => [{key=>'p1', status=>'pending'}]);
    my ($rc, $out, $err) = run_status($data, 'shown-parked');
    like($out, qr/blueprint status: parked/, 'AC11 (B14): bp-status.sh shows parked');
}
{
    my $P = tempdir(CLEANUP => 1); $P =~ s{\\}{/}g;
    my $data = "$P/.ccpraxis-local-data";
    my $bp = make_bp_dir($P, 'shown-parked-live', status => 'parked', reason => 'waiting',
        packages => [{key=>'p1', status=>'pending'}]);
    make_path("$bp/runs");
    write_file("$bp/runs/.orchestrator", "$$\n");
    my ($rc, $out, $err) = run_status($data, 'shown-parked-live');
    like($out, qr/blueprint status: parked/, 'AC11 (B14): still shows parked with a live marker present');
}

# ═══════════════════════════════════════════════════════════════════════════
# REGRESSION (review-1 MF-1 / red-team-1 M3) — set-meta's status: rewrite
# must be confined to the FIRST FENCED metadata block. A prose line reading
# "status: ..." ABOVE the fence must never be the line that gets rewritten,
# and the fenced status must actually flip to parked.
# ═══════════════════════════════════════════════════════════════════════════
require $BPSTATE unless defined &BpState::norm_bp_status;
run_group('MF-1/M3', sub {
    my $P = tempdir(CLEANUP => 1); $P =~ s{\\}{/}g;
    my $data = "$P/.ccpraxis-local-data";
    my $bp = "$data/blueprints/fence-scope";
    make_path("$bp/packages");
    # A prose line that textually matches /^status:/ ABOVE the real fence.
    # The old buggy rewrite (no /g, no fence anchor) hits this line first
    # because it is a `^status:`-anchored match earlier in the file than the
    # fenced one.
    write_file("$bp/blueprint.md",
        "# fence-scope\n\n"
      . "status: see the table below\n\n"
      . "```\nstatus: audited\n```\n\n"
      . "## Package status\n\n"
      . "| pkg | deliverable | depends_on | model | status |\n"
      . "|-----|-------------|------------|-------|--------|\n");
    my $before_prose = 'status: see the table below';

    my ($rc, $out, $err) = capture_run(['park', 'fence-scope', 'why hold'], { data_dir => $data });
    is($rc, 0, 'MF-1/M3: park exits 0');

    is(bp_status_of("$bp/blueprint.md"), 'parked',
        'MF-1/M3: the FENCED status actually becomes parked (not the prose line)');

    my $content = slurp("$bp/blueprint.md") // '';
    like($content, qr/\Q$before_prose\E/,
        'MF-1/M3: the prose line above the fence is left untouched by the rewrite');

    my $alive_no = sub { 0 };
    is(BpState::blueprint_lifecycle($bp, $alive_no), 'parked',
        'MF-1/M3: BpState::blueprint_lifecycle agrees the blueprint is parked');
});

# ═══════════════════════════════════════════════════════════════════════════
# REGRESSION (red-team-1 M1) — park (and the migration) must refuse a
# blueprint name that escapes the blueprints/ tree through "..", rather than
# writing status: parked into whatever file it resolves to.
# ═══════════════════════════════════════════════════════════════════════════
{
    my $proj = tempdir(CLEANUP => 1); $proj =~ s{\\}{/}g;
    my $data = "$proj/.ccpraxis-local-data";
    make_path("$data/blueprints");
    # The victim lives OUTSIDE the data root entirely -- $data/blueprints/../../victim
    # resolves to $proj/victim, exactly the red-team's reproduction.
    make_path("$proj/victim");
    write_file("$proj/victim/blueprint.md", "# victim\n\n```\nstatus: audited\n```\n");
    my $victim_before = slurp("$proj/victim/blueprint.md");

    my ($rc, $out, $err) = capture_run(['park', '../../victim', 'pwned'], { data_dir => $data });
    isnt($rc, 0, 'M1: park with a path-traversal name is refused (non-zero exit)');
    is(slurp("$proj/victim/blueprint.md"), $victim_before,
        'M1: the file outside the data root is byte-identical -- never written');
    ok(!-e "$data/.drive-solo/run.md" || (slurp("$data/.drive-solo/run.md") // '') !~ /victim/,
        'M1: no PARK log line names the escaped path');
}

# ═══════════════════════════════════════════════════════════════════════════
# REGRESSION (red-team-1 M2) — a parks.json that is syntactically valid JSON
# but holds a non-UTF-8 byte in a reason string must still migrate: the
# entry is parked (byte-preserved reason), and the file is not moved aside
# as corrupt for THIS reason alone.
# ═══════════════════════════════════════════════════════════════════════════
run_group('M2', sub {
    my $proj = tempdir(CLEANUP => 1); $proj =~ s{\\}{/}g;
    my $data = "$proj/.ccpraxis-local-data";
    my $bp = make_bp_dir($proj, 'm2-bp', status => 'audited', packages => [{key=>'p1', status=>'pending'}]);
    make_path("$data/.drive-solo");
    write_json("$data/.drive-solo/order.json", { order => ['m2-bp'], recorded_at => $NOW });

    # A raw CP1252 byte (0xE9, "e-acute") embedded in an otherwise-valid JSON
    # array -- valid bytes-on-disk JSON, invalid as strict UTF-8.
    my $raw_reason = "caf\xE9 hold";
    my $raw_json = qq{[{"blueprint":"m2-bp","reason":"$raw_reason","at":$NOW}]};
    write_file("$data/.drive-solo/parks.json", $raw_json);

    my ($rc, $out, $err) = capture_run(['next', '--scope', 'all'], { data_dir => $data });
    is($rc, 0, 'M2: the call still exits 0');
    is(bp_status_of("$bp/blueprint.md"), 'parked',
        'M2: the entry IS migrated despite the non-UTF-8 byte -- not silently dropped');
    is(bp_field_of("$bp/blueprint.md", 'parked_reason'), $raw_reason,
        'M2: the reason survives byte-exact (not re-encoded, not mangled)');
    my @corrupt = glob("$data/.drive-solo/parks.json.corrupt-*");
    is(scalar(@corrupt), 0,
        'M2: parks.json is NOT moved aside as corrupt for a non-UTF-8-but-valid-JSON reason alone');
});

# ═══════════════════════════════════════════════════════════════════════════
# REGRESSION (red-team-1 L7) — BpState, RunState and bp-blueprint.pl's
# pre-write check must all agree on a hand-edited, non-canonical fenced
# status value (here: a trailing period). The project's normaliser is
# BpState::norm_bp_status (s/[^a-z]+/ /g then trim); RunState and the
# set-meta pre-write check must reach the same verdict.
# ═══════════════════════════════════════════════════════════════════════════
require $RUNSTATE unless defined &RunState::_bp_authored_parked;
run_group('L7', sub {
    my $P = tempdir(CLEANUP => 1); $P =~ s{\\}{/}g;
    my $data = "$P/.ccpraxis-local-data";
    my $bp = make_bp_dir($P, 'l7-bp', status => 'parked.', reason => 'hand-edited trailing period');

    is(BpState::norm_bp_status(BpState::bp_meta_get("$bp/blueprint.md", 'status')), 'parked',
        'L7: BpState::norm_bp_status normalises "parked." to parked');

    is(RunState::_bp_authored_parked($bp), 1,
        'L7: RunState::_bp_authored_parked agrees "parked." is parked');

    # The third reader: bp-blueprint.pl's pre-write check (set-meta's unpark
    # hook), exercised indirectly -- an open park item must close when the
    # blueprint leaves a hand-edited "parked." status, exactly as it would
    # for a clean "parked".
    my $item = Almanac::Inbox::file(root => $P, title => 'Blueprint l7-bp parked: hand-edited trailing period', link => 'l7-bp');
    my ($rc) = run_bp_blueprint('set-meta', '--file', "$bp/blueprint.md", '--field', 'status', '--value', 'audited');
    is($rc, 0, 'L7: unparking a "parked." blueprint exits 0');
    is(bp_status_of("$bp/blueprint.md"), 'audited', 'L7: the fenced status is now audited');

    my $after = Almanac::Inbox::read_item($item->{id}, root => $P);
    is($after->{fields}{status}, 'answered',
        'L7: the pre-write check also recognises "parked." -- the open park item is closed');
});

done_testing();
