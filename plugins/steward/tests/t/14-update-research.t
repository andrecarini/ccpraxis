#!/usr/bin/env perl
# 14-update-research.t — the update research engine and its persistence layer.
#
# WHY THIS EXISTS. /steward:update was a prose protocol that made the agent
# hand-fan eight WebFetches, hand-join two datasets, hand-compute ages and
# hand-classify risk on every single run. Measured on 2026-09-06 it was wrong
# three ways at once: it read GitHub Releases through a prose summarizer that
# returned 5 of 100 releases, its version-string issue query matched every issue
# filed that day, and it re-derived everything each time so declining an update
# cost the same as taking one.
#
# The assertions below pin the properties a script can hold and a protocol
# cannot: correct ordering, cache reuse, offline capability, byte-correct paths,
# an append-only decision log, and a sync that stays inside its own namespace.
#
# Every test runs the REAL script as a subprocess against a temp HOME, with
# --offline and a pre-seeded store. No test here touches the network or the
# operator's actual vault.
#
# AC1  version comparison is numeric, so 2.1.90 sorts below 2.1.219
# AC2  risk is derived from the clock at run time, never read from the store
# AC3  a bundled-runtime crash cluster demotes every version at or above it
# AC4  the recommendation refuses HIGH, NO_CHANGELOG, issue-named and cluster versions
# AC5  --offline produces a full analysis with no network access
# AC6  a store path containing non-ASCII round-trips byte-for-byte
# AC7  decisions.jsonl is append-only and survives re-runs
# AC8  sync commits ONLY its own namespace, never a sibling's work
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP ();
use StewardTest qw(ok is like unlike done_testing diag);

my $SCRIPT = "$Bin/../../scripts/update-research.pl";
ok(-f $SCRIPT, 'precondition: update-research.pl exists') or do { done_testing(); exit };

my $ROOT = tempdir(CLEANUP => 1);

# run($home, @args) -> { json, exit, raw }
#
# HOME is overridden so the script's own store resolution is exercised rather
# than stubbed. USERPROFILE too: home_dir() falls back to it, and on Windows a
# leftover real USERPROFILE would silently point the test at the operator's own
# vault — which is exactly the kind of test that "passes" by measuring the wrong
# machine.
sub run {
    my ($home, @args) = @_;
    local $ENV{HOME}        = $home;
    local $ENV{USERPROFILE} = $home;
    # stderr goes to a FILE, not into stdout. The script's contract is that
    # stdout is one JSON object; git writes its own diagnostics to stderr, and
    # a `2>&1` here merged them into the payload and made the parse fail. The
    # symptom was an assertion about sync's return value failing while sync had
    # in fact succeeded — the harness breaking the thing it was measuring.
    my $errf = "$ROOT/stderr.$$";
    my $cmd  = join ' ', map { "\"$_\"" } ($^X, $SCRIPT, @args);
    my $raw  = `$cmd 2>"$errf"`;
    my $rc   = $? >> 8;
    my $j   = eval { JSON::PP->new->decode($raw) };
    return { json => (ref $j eq 'HASH' ? $j : undef), exit => $rc, raw => $raw };
}

# seed_store($home, $versions, $issues) — write a store the way the script does,
# so --offline has real material to analyse.
sub seed_store {
    my ($home, $versions, $issues) = @_;
    my $dir = "$home/.claude/cache/update-research";
    make_path($dir);
    for my $pair ([ "$dir/versions.json", { schema => 1, versions => $versions } ],
                  [ "$dir/issues.json",   { schema => 1, fetched_at => iso(0), issues => $issues } ]) {
        open my $fh, '>:raw', $pair->[0] or die "seed $pair->[0]: $!";
        print {$fh} JSON::PP->new->canonical(1)->encode($pair->[1]);
        close $fh;
    }
    return $dir;
}

sub iso {
    my ($ago) = @_;
    my @t = gmtime(time - $ago);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5]+1900, $t[4]+1, @t[3,2,1,0]);
}

sub bullets { return [ 'Something changed' ] }

# A fixture spanning every risk band, plus the ordering trap.
sub fixture_versions {
    return {
        '2.1.90'  => { version => '2.1.90',  published_at => iso(90 * 86400), changelog_bullets => bullets() },
        '2.1.219' => { version => '2.1.219', published_at => iso(40 * 86400), changelog_bullets => bullets() },
        '2.1.248' => { version => '2.1.248', published_at => iso(10 * 86400), changelog_bullets => bullets() },
        '2.1.250' => { version => '2.1.250', published_at => iso(9  * 86400), changelog_bullets => bullets() },
        '2.1.251' => { version => '2.1.251', published_at => iso(9  * 86400), changelog_bullets => bullets() },
        '2.1.258' => { version => '2.1.258', published_at => iso(5  * 86400), changelog_bullets => bullets() },
        '2.1.263' => { version => '2.1.263', published_at => iso(3600),       changelog_bullets => bullets() },
        # No changelog_bullets at all: the NO_CHANGELOG band.
        '2.1.264' => { version => '2.1.264', published_at => iso(20 * 86400) },
    };
}

# Two open reports, both fresh, both naming Bun 1.4.1, lowest version 2.1.258.
# TWO is the threshold the script requires: one report is a report, two is a
# pattern, and only a pattern justifies refusing every later version.
sub fixture_issues {
    return {
        92045 => { number => 92045, title => 'Bun 1.4.1 segfault in JSC GC', state => 'open',
                   created_at => iso(2 * 86400), reactions => 0,
                   platforms => ['windows'], versions => ['2.1.260'], runtime => '1.4.1' },
        91914 => { number => 91914, title => 'SIGILL in JSC GC HeapHelper', state => 'open',
                   created_at => iso(3 * 86400), reactions => 0,
                   platforms => ['linux'], versions => ['2.1.258'], runtime => '1.4.1' },
        90802 => { number => 90802, title => 'Large image kills session', state => 'open',
                   created_at => iso(20 * 86400), reactions => 0,
                   platforms => ['windows'], versions => ['2.1.251'], runtime => undef },
    };
}

sub by_version {
    my ($analysis) = @_;
    my %h;
    $h{ $_->{version} } = $_ for @{ $analysis->{candidates} || [] };
    return \%h;
}

# have_git -- a plain guard rather than Test::More's SKIP/skip.
#
# StewardTest exports its own ok/is/like and NOT skip, so a `SKIP: { skip(...) }`
# block dies with "Undefined subroutine &main::skip" on any machine that lacks
# git — the one machine where that branch is the only one that runs. It passed
# here purely because git is installed. An `if` cannot fail that way, and
# done_testing() copes with the varying count.
my $HAVE_GIT;
sub have_git {
    unless (defined $HAVE_GIT) {
        my $v = `git --version 2>&1`;
        $HAVE_GIT = ($? == 0 && ($v // '') =~ /git version/) ? 1 : 0;
        diag('git unavailable — the vault-sync assertions are not running') unless $HAVE_GIT;
    }
    return $HAVE_GIT;
}

# ---------------------------------------------------------------------------
my $home = "$ROOT/h1";
make_path($home);
seed_store($home, fixture_versions(), fixture_issues());

my $r = run($home, 'gather', '--current', '2.1.219', '--offline');
is($r->{exit}, 0, 'gather --offline exits 0') or diag($r->{raw});
my $a = $r->{json};
ok((defined $a && $a->{ok}), 'gather --offline returns ok:true JSON')
    or do { diag($r->{raw}); done_testing(); exit };

# --- AC5: offline really is offline -----------------------------------------
is(($a->{network}{changelog} // ''), 'skipped (offline)', 'AC5 changelog not fetched when offline');
is(($a->{network}{releases}  // ''), 'skipped (offline)', 'AC5 releases not fetched when offline');
is(($a->{network}{issues}    // ''), 'skipped (offline)', 'AC5 issues not fetched when offline');
ok(scalar @{ $a->{candidates} || [] } > 0, 'AC5 liveness: an offline run still produced candidates');

# --- AC1: numeric ordering ---------------------------------------------------
# 2.1.90 is OLDER than 2.1.219 and must not appear as a candidate. A string
# compare puts "2.1.90" above "2.1.219" and would offer a downgrade as an
# upgrade — silently, and only for versions whose patch number crossed 100.
my $seen = by_version($a);
ok(!exists $seen->{'2.1.90'},
   'AC1 2.1.90 is not offered as newer than 2.1.219 (numeric, not string, compare)')
    or diag('  a string compare ranks "2.1.90" above "2.1.219"');
ok(exists $seen->{'2.1.248'}, 'AC1 liveness: a genuinely newer version IS a candidate');

my @order = map { $_->{version} } @{ $a->{candidates} };
my $desc = 1;
for my $i (1 .. $#order) {
    my @x = split /\./, $order[$i - 1];
    my @y = split /\./, $order[$i];
    $desc = 0 if ($x[2] + 0) < ($y[2] + 0) && $x[1] == $y[1];
}
ok($desc, 'AC1 candidates are ordered newest first') or diag('  got: ' . join(', ', @order));

# --- AC2: risk comes from the clock, not the store ---------------------------
is(($seen->{'2.1.263'}{risk} // ''), 'RUNTIME_RISK',
   'AC2/AC3 a 1-hour-old version inside the cluster reads RUNTIME_RISK');
is(($seen->{'2.1.248'}{risk} // ''), 'LOW',   'AC2 a 10-day-old version reads LOW');
ok(!exists $seen->{'2.1.248'}{risk_stored}, 'AC2 no stored risk field is echoed back');

# NO_CHANGELOG is asserted in the cluster-free store below, not here: 2.1.264
# sits ABOVE the cluster floor, so RUNTIME_RISK correctly outranks it. Checking
# it here instead measured the override and called it a changelog bug.

# A version that is new but NOT in a cluster must read HIGH on age alone. The
# fixture's 2.1.263 is both, so this is checked on a store without the cluster.
{
    my $h2 = "$ROOT/h2";
    make_path($h2);
    seed_store($h2, fixture_versions(), {});      # no issues at all -> no cluster
    my $r2 = run($h2, 'gather', '--current', '2.1.219', '--offline');
    my $s2 = by_version($r2->{json} || {});
    is(($s2->{'2.1.263'}{risk} // ''), 'HIGH',
       'AC2 with no cluster, a 1-hour-old version reads HIGH on age alone');
    is(($s2->{'2.1.258'}{risk} // ''), 'MEDIUM',
       'AC2 a 5-day-old version reads MEDIUM');
    is(($s2->{'2.1.264'}{risk} // ''), 'NO_CHANGELOG',
       'AC2 a version with no changelog entry is NO_CHANGELOG regardless of age')
        or diag('  2.1.264 is 20 days old, which would otherwise read LOW');
}

# --- AC3: the cluster demotes everything at or above its floor ---------------
is(scalar @{ $a->{runtime_clusters} || [] }, 1, 'AC3 one runtime cluster was detected');
is(($a->{runtime_clusters}[0]{runtime} // ''), '1.4.1', 'AC3 the cluster names the runtime version');
is(($a->{runtime_clusters}[0]{from_version} // ''), '2.1.258',
   'AC3 the cluster floor is the LOWEST version named across its reports');
is(($seen->{'2.1.258'}{risk} // ''), 'RUNTIME_RISK', 'AC3 the floor version itself is demoted');
isnt_str(($seen->{'2.1.251'}{risk} // ''), 'RUNTIME_RISK',
   'AC3 a version BELOW the floor is not pulled into the cluster');
is(($seen->{'2.1.250'}{risk} // ''), 'LOW',
   'AC3 a below-floor version with no issues stays LOW');

# --- AC9: open reports move the band, they do not merely annotate it --------
# The first cut left the band on age alone, so a version blamed by seventeen
# open segfault reports displayed 'LOW' beside one with none. It was excluded
# from the recommendation, but the operator reads the TABLE.
is(($seen->{'2.1.251'}{risk} // ''), 'MEDIUM',
   'AC9 one open issue lifts an otherwise-LOW version to MEDIUM')
    or diag('  2.1.251 is 9 days old (LOW on age) and named by #90802');
like(join(' ', @{ $seen->{'2.1.251'}{risk_reasons} || [] }), qr/open issue\(s\) blame this version/,
     'AC9 and the reason says so');
{
    my $h9 = "$ROOT/h9";
    make_path($h9);
    my %many;
    # Five separate open reports against one old version.
    for my $n (1 .. 5) {
        $many{ 90000 + $n } = { number => 90000 + $n, title => "crash $n", state => 'open',
                                created_at => iso(20 * 86400), reactions => 0,
                                platforms => ['linux'], versions => ['2.1.248'], runtime => undef };
    }
    seed_store($h9, fixture_versions(), \%many);
    my $r9 = by_version(run($h9, 'gather', '--current', '2.1.219', '--offline')->{json} || {});
    is(($r9->{'2.1.248'}{risk} // ''), 'HIGH',
       'AC9 five open issues lift a 10-day-old version all the way to HIGH');
    isnt_str(($r9->{'2.1.250'}{risk} // ''), 'HIGH',
       'AC9 counter-check: an unblamed version of the same age is not lifted');
}

# One report must not make a cluster — otherwise a single unreproduced crash
# report would veto every release above it.
{
    my $h3 = "$ROOT/h3";
    make_path($h3);
    my $one = { 92045 => (fixture_issues())->{92045} };
    seed_store($h3, fixture_versions(), $one);
    my $r3 = run($h3, 'gather', '--current', '2.1.219', '--offline');
    is(scalar @{ ($r3->{json} || {})->{runtime_clusters} || [] }, 0,
       'AC3 a single report does not form a cluster');
}

# --- AC4: the recommendation ------------------------------------------------
is(($a->{recommendation}{version} // ''), '2.1.250',
   'AC4 recommends the newest LOW version with no open issue naming it')
    or diag('  2.1.251 is the same age but is named by issue #90802; '
          . '2.1.258+ are inside the runtime cluster');
ok(!grep({ $_ eq ($a->{recommendation}{version} // '') } qw(2.1.263 2.1.264 2.1.258)),
   'AC4 never recommends a HIGH, NO_CHANGELOG or clustered version');

# And when nothing qualifies, it must say so rather than pick the least-bad.
{
    my $h4 = "$ROOT/h4";
    make_path($h4);
    seed_store($h4, { '2.1.263' => { version => '2.1.263', published_at => iso(3600),
                                     changelog_bullets => bullets() } }, {});
    my $r4 = run($h4, 'gather', '--current', '2.1.219', '--offline');
    my $rec = ($r4->{json} || {})->{recommendation} || {};
    ok(!defined $rec->{version}, 'AC4 recommends nothing when every candidate is too new');
    like(($rec->{why} // ''), qr/Staying put is defensible/,
         'AC4 and says staying put is defensible instead of picking the least-bad');
}

# --- AC6: non-ASCII store path round-trips ----------------------------------
# The operator's real home is /c/Users/André. The first cut of this script
# emitted "AndrÃ©" because it ->utf8-encoded a path that was already UTF-8
# bytes — the same double-encode that corrupted vault-sync's ops journal.
{
    my $accented = "$ROOT/andr\xc3\xa9-home";     # 'andré' as raw UTF-8 bytes
    make_path($accented);
    seed_store($accented, fixture_versions(), {});
    my $r5 = run($accented, 'status');
    my $store = ($r5->{json} || {})->{store} // '';
    # The needle goes through a VARIABLE, and via index() rather than \Q...\E.
    # Inside \Q the escape processing is itself suppressed, so
    # /\Qandr\xc3\xa9\E/ hunts for the literal characters backslash-x-c-3 and
    # can never match. It fails looking exactly like a real encoding bug, which
    # is how it cost a debugging round here before being pinned in this comment.
    my $needle = "andr\xc3\xa9-home";
    ok(index($store, $needle) >= 0,
       'AC6 a non-ASCII store path is emitted as the same bytes it was given')
        or diag("  got: $store\n  a doubled encode shows up as andrÃ©-home");
    unlike($store, qr/\xc3\x83/, 'AC6 counter-check: no double-encoded sequence in the path');
}

# --- AC7: the decision log is append-only ------------------------------------
{
    my $h6 = "$ROOT/h6";
    make_path($h6);
    seed_store($h6, fixture_versions(), {});

    run($h6, 'record-decision', '--from', '2.1.219', '--to', '2.1.263',
              '--action', 'declined', '--reason', 'first');
    run($h6, 'record-decision', '--from', '2.1.219', '--to', '2.1.250',
              '--action', 'installed', '--reason', 'second');

    my $hist = run($h6, 'history')->{json} || {};
    my @d = @{ $hist->{decisions} || [] };
    is(scalar @d, 2, 'AC7 both decisions were kept');
    is(($d[0]{reason} // ''), 'second', 'AC7 history returns newest first');
    is(($d[1]{reason} // ''), 'first',  'AC7 the earlier decision was not overwritten');
    is(($d[1]{action} // ''), 'declined', 'AC7 the earlier action survives verbatim');

    my $bad = run($h6, 'record-decision', '--to', '2.1.250', '--action', 'nonsense');
    isnt_zero($bad->{exit}, 'AC7 an unknown action is refused rather than recorded');
    is(scalar @{ (run($h6, 'history')->{json} || {})->{decisions} || [] }, 2,
       'AC7 and the refused call appended nothing');
}

sub isnt_zero { my ($v, $n) = @_; ok(($v // 0) != 0, $n) }
sub isnt_str  { my ($got, $bad, $n) = @_; ok((($got // '') ne $bad), $n)
                    or diag("  got '" . ($got // '') . "', which must not equal '$bad'") }

# --- AC8: sync stays inside its own namespace --------------------------------
# The vault also holds projects/ and todos/, each owned by a different script.
# A broad `git add -A` here would sweep a sibling's half-finished work into this
# commit — which is why sync is path-scoped, and why that scoping is pinned.
if (have_git()) {

    my $h7 = "$ROOT/h7";
    my $vault = "$h7/.claude/claude-code-vault";
    make_path("$vault/research/claude-code");
    make_path("$vault/todos");

    # A real bare remote, so `push` is genuinely exercised rather than failing
    # for want of one and leaving the push path untested.
    my $remote = "$ROOT/remote.git";
    system('git', 'init', '--bare', '-q', $remote);
    for my $c (['init','-q'], ['config','user.email','t@example.com'], ['config','user.name','T'],
               ['commit','--allow-empty','-q','-m','base'],
               ['remote','add','origin',$remote],
               ['push','-q','-u','origin','HEAD']) {
        system('git', '-C', $vault, @$c);
    }

    # A sibling's uncommitted file, which must NOT be swept up.
    open my $fh, '>:raw', "$vault/todos/not-mine.md" or die;
    print {$fh} "someone else's work in progress\n";
    close $fh;

    open my $vf, '>:raw', "$vault/research/claude-code/versions.json" or die;
    print {$vf} '{"schema":1,"versions":{}}';
    close $vf;

    my $s = run($h7, 'sync', 'test: research');
    my $sj = $s->{json} || {};
    ok($sj->{ok}, 'AC8 sync reports ok') or diag($s->{raw});
    ok($sj->{pushed}, 'AC8 and actually pushed to the remote') or diag($s->{raw});

    my $tracked = `git -C "$vault" ls-files`;
    like($tracked, qr{research/claude-code/versions\.json},
         'AC8 the research file was committed');
    unlike($tracked, qr{todos/not-mine\.md},
           "AC8 a sibling namespace's uncommitted file was NOT committed")
        or diag('  sync must be path-scoped; a bare `git add -A` would take this');

    # Second sync with nothing new must be a clean no-op, not an empty commit.
    my $again = run($h7, 'sync', 'test: again')->{json} || {};
    ok((!$again->{synced} && ($again->{reason} // '') =~ /no changes/),
       'AC8 a second sync with nothing new commits nothing');
}

# --- AC10: a CLOSED issue stops counting against its version -----------------
#
# The symptom searches filter state:open, so a closed issue simply stops
# appearing in results -- and a record that stops appearing was never updated.
# It kept state:open forever and went on penalising its version indefinitely.
# Measured on the real store before this was fixed: 87 issues held, 72 of which
# had never had their state re-checked since first sight.
{
    my $h10 = "$ROOT/h10";
    make_path($h10);
    my %closed = (
        90001 => { number => 90001, title => 'fixed long ago', state => 'closed',
                   created_at => iso(20 * 86400), reactions => 40,
                   platforms => ['linux'], versions => ['2.1.248'], runtime => undef },
    );
    seed_store($h10, fixture_versions(), \%closed);
    my $s10 = by_version(run($h10, 'gather', '--current', '2.1.219', '--offline')->{json} || {});
    is(scalar @{ $s10->{'2.1.248'}{issues} || [] }, 0,
       'AC10 a closed issue is not listed against its version');
    is(($s10->{'2.1.248'}{risk} // ''), 'LOW',
       'AC10 and does not hold the version above LOW')
        or diag('  a closed issue with 40 reactions must not outrank a fixed bug');

    # The identical record, still open: proves the assertion above turns on
    # state and not on the fixture simply being ignored.
    my $h11 = "$ROOT/h11";
    make_path($h11);
    my %open = ( 90001 => { %{ $closed{90001} }, state => 'open' } );
    seed_store($h11, fixture_versions(), \%open);
    my $s11 = by_version(run($h11, 'gather', '--current', '2.1.219', '--offline')->{json} || {});
    is(scalar @{ $s11->{'2.1.248'}{issues} || [] }, 1,
       'AC10 counter-check: the identical record DOES count while open');
    is(($s11->{'2.1.248'}{risk} // ''), 'HIGH',
       'AC10 counter-check: and lifts the version (40 reactions)');
}

# --- AC11: gather and record-decision sync by themselves ---------------------
# Research that stays on one machine is research the next machine pays for
# again, which is the whole reason the store exists.
if (have_git()) {

    my $h12    = "$ROOT/h12";
    my $vault  = "$h12/.claude/claude-code-vault";
    my $remote = "$ROOT/remote12.git";
    my $dir    = "$vault/research/claude-code";
    make_path($dir);
    system('git', 'init', '--bare', '-q', $remote);
    for my $c (['init','-q'], ['config','user.email','t@example.com'], ['config','user.name','T'],
               ['commit','--allow-empty','-q','-m','base'],
               ['remote','add','origin',$remote], ['push','-q','-u','origin','HEAD']) {
        system('git', '-C', $vault, @$c);
    }
    for my $pair ([ "$dir/versions.json", { schema => 1, versions => fixture_versions() } ],
                  [ "$dir/issues.json",   { schema => 1, fetched_at => iso(0), issues => {} } ]) {
        open my $fh, '>:raw', $pair->[0] or die;
        print {$fh} JSON::PP->new->canonical(1)->encode($pair->[1]);
        close $fh;
    }

    # --offline must NOT sync: nothing new can have arrived, and a run that
    # cannot reach the network should not be reaching for git either.
    my $off = run($h12, 'gather', '--current', '2.1.219', '--offline')->{json} || {};
    ok(!exists $off->{sync}, 'AC11 an offline gather does not attempt a sync');

    my $rd = run($h12, 'record-decision', '--to', '2.1.250', '--action', 'installed',
                        '--reason', 'auto-sync check')->{json} || {};
    ok(($rd->{sync} && $rd->{sync}{synced}), 'AC11 record-decision syncs without being asked')
        or diag(JSON::PP->new->encode($rd->{sync} || {}));

    my $log = `git -C "$vault" log --oneline -- research/claude-code`;
    like($log, qr/record update decision/, 'AC11 and the decision reached a commit');
}

# --- AC12: the shared namespace sync serves ANY vault namespace ---------------
# reports/ and bootstrap-archive/ were untracked in the real vault: usage-audit
# wrote reports for months that nothing ever committed, while its own
# description said it "writes a dated report into the vault".
if (have_git()) {

    my $CLI = "$Bin/../../scripts/vault-namespace-sync.pl";
    ok(-f $CLI, "AC12 vault-namespace-sync.pl exists");

    my $vault  = "$ROOT/v13";
    my $remote = "$ROOT/remote13.git";
    make_path("$vault/reports/usage");
    make_path("$vault/projects/someone-else");
    system('git', 'init', '--bare', '-q', $remote);
    for my $c (['init','-q'], ['config','user.email','t@example.com'], ['config','user.name','T'],
               ['commit','--allow-empty','-q','-m','base'],
               ['remote','add','origin',$remote], ['push','-q','-u','origin','HEAD']) {
        system('git', '-C', $vault, @$c);
    }
    for my $f (["$vault/reports/usage/2026-09-06.md", "# usage\n"],
               ["$vault/projects/someone-else/wip.md", "not mine\n"]) {
        open my $fh, '>:raw', $f->[0] or die;
        print {$fh} $f->[1];
        close $fh;
    }

    my $raw = `"$^X" "$CLI" reports "test: reports" --vault "$vault" 2>"$ROOT/e13"`;
    my $j   = eval { JSON::PP->new->decode($raw) } || {};
    ok($j->{synced}, 'AC12 an arbitrary namespace (reports/) is committed') or diag($raw);

    my $tracked = `git -C "$vault" ls-files`;
    ok(($tracked =~ m{reports/usage/2026-09-06\.md} && $tracked !~ m{projects/someone-else}),
       "AC12 and a different owner's namespace is left alone")
        or diag("  tracked:\n$tracked");
}

done_testing();
