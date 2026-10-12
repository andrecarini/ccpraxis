#!/usr/bin/env perl
# platform: any
# ORACLE for blueprint where-things-go, package 07-bug-lifecycle. Derived
# ONLY from .ccpraxis-local-data/blueprints/where-things-go/specs/
# 07-bug-lifecycle-spec.md sections 2-5 (AC1-AC19) and the package ledger's
# five done criteria -- NOT from reading almanac-bug.pl/almanac-doctor.pl's
# bug-lifecycle code, which this package's write set has not written yet.
# Almanac::PackageLink (package 02-thread-store, already landed) is named
# explicitly by the spec as shared, read-only machinery this package sits on
# top of, and is read here only to confirm fixture shapes, never edited.
#
# WRITTEN BLIND TO THE IMPLEMENTATION: at the time this file is written,
# almanac-bug.pl's state machine is still
# `open -> triaging -> taken -> resolved | declined`, it has no `reconcile`
# verb, no automatic reconcile, no `--package` flag, and almanac-doctor.pl has
# no BAD-LINK/bug or UNMIGRATED-BUG finding. Every assertion below that
# depends on the rename, scheduling, reconcile or migration is EXPECTED TO
# FAIL (red) until package 07-bug-lifecycle lands -- that is the point of a
# failing-first oracle, not a bug in this file.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
my $A = "$S/almanac-bug.pl";
ok(-f $A, 'almanac-bug.pl exists') or BAIL_OUT('script missing');

(my $BUTLER_SCRIPTS = "$Bin/../../../butler/scripts") =~ s{\\}{/}g;
my $BPHOOK_PM = "$BUTLER_SCRIPTS/BpHook.pm";
ok(-f $BPHOOK_PM, 'BpHook.pm exists (needed to mint test tickets)') or BAIL_OUT('BpHook.pm missing');
require $BPHOOK_PM;

(my $ALMANAC_DIR = "$Bin/../..") =~ s{\\}{/}g;

# ---------------------------------------------------------------------------
# Hygiene: snapshot the REAL ~/.claude/butler-state and the real repo's
# .ccpraxis-local-data/bug-reports BEFORE this file touches $ENV{HOME} etc.
# ---------------------------------------------------------------------------
my $REAL_HOME = $ENV{HOME} // $ENV{USERPROFILE} // '';
(my $REAL_BUTLER_STATE = length($REAL_HOME) ? "$REAL_HOME/.claude/butler-state" : '/nonexistent-no-real-home') =~ s{\\}{/}g;
(my $REPO_ROOT = "$Bin/../../../..") =~ s{\\}{/}g;
my $REAL_BUG_REPORTS = "$REPO_ROOT/.ccpraxis-local-data/bug-reports";

sub snapshot_dir {
    my ($dir) = @_;
    return { exists => 0 } unless -d $dir;
    my %info;
    my @stack = ($dir);
    while (my $d = pop @stack) {
        opendir(my $dh, $d) or next;
        for my $e (readdir $dh) {
            next if $e eq '.' || $e eq '..';
            next if $e eq 'continuity';
            my $full = "$d/$e";
            if (-d $full) { push @stack, $full }
            else { $info{$full} = (stat $full)[9] }
        }
        closedir $dh;
    }
    return { exists => 1, files => \%info };
}
my $HYGIENE_BEFORE_BUTLER = snapshot_dir($REAL_BUTLER_STATE);
my $HYGIENE_BEFORE_BUGS   = snapshot_dir($REAL_BUG_REPORTS);

# ---------------------------------------------------------------------------
# Isolated environment: fresh tempdirs for everything.
# ---------------------------------------------------------------------------
my $HOME = tempdir(CLEANUP => 1);
my $CFG  = tempdir(CLEANUP => 1);   # CLAUDE_CONFIG_DIR
my $BSD  = tempdir(CLEANUP => 1);   # BUTLER_STATE_DIR
for ($HOME, $CFG, $BSD) { s{\\}{/}g }

$ENV{HOME}              = $HOME;
$ENV{USERPROFILE}       = $HOME;
$ENV{ALMANAC_HOME}      = $HOME;
$ENV{CLAUDE_CONFIG_DIR} = $CFG;
$ENV{BUTLER_STATE_DIR}  = $BSD;
delete $ENV{CCPRAXIS_DATA_DIR};
delete $ENV{CLAUDE_PROJECT_DIR};

sub new_project { my $p = tempdir(CLEANUP => 1); $p =~ s{\\}{/}g; return $p; }

sub run {
    my (@args) = @_;
    my $cmd = qq{ALMANAC_HOME="$HOME" HOME="$HOME" USERPROFILE="$HOME" }
            . qq{CLAUDE_CONFIG_DIR="$CFG" BUTLER_STATE_DIR="$BSD" perl "$A" }
            . join(' ', @args) . ' 2>&1';
    my $out = `$cmd`;
    return ($? >> 8, $out // '');
}
sub slurp_raw {
    my ($p) = @_;
    open my $f, '<:raw', $p or return undef;
    local $/; my $t = <$f>; close $f;
    return $t;
}
sub body_of {
    my ($p) = @_;
    my $t = slurp_raw($p) // '';
    return $t =~ /\A---\r?\n.*?\r?\n---\r?\n(.*)\z/s ? $1 : '';
}
sub field_of {
    my ($p, $k) = @_;
    my $t = slurp_raw($p);
    return undef unless defined $t;
    return $t =~ /^\Q$k\E:\s*(.*)$/m ? $1 : undef;
}

# ---------------------------------------------------------------------------
# Ticket minting (shared shape with bug-state-machine.t / bug-triage-claim.t):
# a claim's identity comes ONLY from a butler hook ticket, keyed on
# sha1(name, argv). mint_ticket's argv must equal EXACTLY the argv the
# almanac-bug.pl subprocess receives.
# ---------------------------------------------------------------------------
my $TICKET_SEQ = 0;
sub ensure_transcript {
    my ($sid) = @_;
    my $dir = "$CFG/projects/p";
    make_path($dir) unless -d $dir;
    my $path = "$dir/$sid.jsonl";
    unless (-f $path) {
        open my $fh, '>', $path or die "fixture: cannot write transcript $path: $!";
        print {$fh} "{}\n";
        close $fh;
    }
    return $path;
}
sub mint_ticket {
    my ($session, $agent, @argv) = @_;
    my $transcript = ensure_transcript($session);
    local $ENV{BUTLER_STATE_DIR} = $BSD;
    my $ok = BpHook::write_ticket(
        { session_id => $session, tool_use_id => 'T' . (++$TICKET_SEQ),
          (defined $agent ? (agent_id => $agent) : ()),
          transcript_path => $transcript, cwd => undef },
        'almanac-bug', [ @argv ]);
    die "fixture: could not write ticket for (@argv)\n" unless $ok;
    return;
}
sub run_as {
    my ($session, $agent, @args) = @_;
    # run() goes through a shell, which strips one layer of double quotes, so
    # the ticket must be minted against the argv the subprocess RECEIVES --
    # minting against the quoted Perl element made every quoted value
    # (`--note "not reproducible"`) fail with "no hook ticket".
    mint_ticket($session, $agent, map { (my $v = $_) =~ s{\A"(.*)"\z}{$1}s; $v } @args);
    return run(@args);
}

# ---------------------------------------------------------------------------
# AlmanacBug package functions, loaded in-process (no subprocess) for fixture
# building only -- `do $A` executes the script with a defined caller(), so
# its own CLI block never runs.
# ---------------------------------------------------------------------------
{
    local $@;
    do $A;
    diag("loading $A for fixtures failed: $@") if $@;
}

# write_pkg_ledger($root, $bp, $pkg, $status, %opt) -- the minimal frontmatter
# Almanac::PackageLink::resolve reads. opt: archived=>0|1, body=>"...".
sub write_pkg_ledger {
    my ($root, $bp, $pkg, $status, %opt) = @_;
    my $base = $opt{archived}
        ? "$root/.ccpraxis-local-data/blueprints/_archive/$bp/packages"
        : "$root/.ccpraxis-local-data/blueprints/$bp/packages";
    make_path($base);
    open(my $fh, '>:raw', "$base/$pkg.md") or die "fixture: cannot write $base/$pkg.md: $!";
    print {$fh} "---\nstatus: $status\n---\n" . ($opt{body} // '');
    close $fh;
}

# mk_bug_raw($root, %fields) -- a bug report written DIRECTLY (bypassing the
# CLI, which does not yet support most of these states/fields at all), to
# simulate an existing report in a given on-disk shape. Mirrors
# AlmanacBug::_render's @order (spec sec 2.2).
my $BUG_SEQ = 0;
sub mk_bug_raw {
    my ($root, %o) = @_;
    my $id   = $o{id} // (AlmanacBug::new_id() . sprintf('-bl%02d', ++$BUG_SEQ));
    my $now  = AlmanacBug::_iso(time);
    my $body = $o{body} // 'body text';
    my $dir  = AlmanacBug::reports_dir($root);
    make_path($dir) unless -d $dir;
    my $path = "$dir/$id.md";
    my %f = (
        id => $id, title => ($o{title} // 'bug'), status => $o{status},
        severity => 'unknown', area => 'unknown', project => $root,
        created_at => $now, updated_at => $now,
        ($o{no_freeze} ? () : (frozen_at => $now, content_sha256 => AlmanacBug::body_digest($body))),
        (defined $o{taken_at}      ? (taken_at      => $o{taken_at})      : ()),
        (defined $o{package}       ? (package       => $o{package})      : ()),
        (defined $o{package_root}  ? (package_root  => $o{package_root}) : ()),
        (defined $o{scheduled_at}  ? (scheduled_at  => $o{scheduled_at}) : ()),
        (defined $o{fixed_at}      ? (fixed_at      => $o{fixed_at})     : ()),
        (defined $o{fixed_commit}  ? (fixed_commit  => $o{fixed_commit}) : ()),
        (defined $o{migrated_from} ? (migrated_from => $o{migrated_from}): ()),
        (defined $o{resolution}    ? (resolution    => $o{resolution})   : ()),
    );
    my @order = qw(id title status severity area project created_at updated_at frozen_at
                   content_sha256 taken_at package package_root scheduled_at fixed_at
                   fixed_commit migrated_from resolution);
    open my $fh, '>:raw', $path or die "fixture: cannot write $path: $!";
    print {$fh} "---\n" . join("\n", map { defined $f{$_} ? "$_: $f{$_}" : () } @order) . "\n---\n$body";
    close $fh;
    return ($path, $id);
}

# =============================================================================
# DC1 -- transitions: open->triaging->scheduled->fixed|dropped and
# triaging->open all succeed; every other transition is refused; scheduled
# without a valid --package link is refused.
# =============================================================================

# ---- the legal chain, open -> triaging -> scheduled -> dropped ------------
{
    my $PROJ = new_project();
    write_pkg_ledger($PROJ, 'dc1bp', '01-dc1', 'running');

    my (undef, $o) = run('file', '--project', $PROJ, '--title', '"dc1 chain"', '--body', '"b"');
    chomp(my $path = $o);
    my ($id) = $path =~ m{/([^/]+)\.md$};

    is((run_as('DC1S', undef, 'set-status', $id, '--project', $PROJ, '--to', 'triaging'))[0], 0,
       'DC1: open -> triaging succeeds');
    is(field_of($path, 'status'), 'triaging', 'DC1: status is triaging');

    is((run_as('DC1S', undef, 'set-status', $id, '--project', $PROJ, '--to', 'scheduled',
                '--package', 'dc1bp/01-dc1'))[0], 0,
       'DC1: triaging -> scheduled succeeds, by the claimant, with a valid --package');
    is(field_of($path, 'status'), 'scheduled', 'DC1: status is scheduled');
    is(field_of($path, 'package'), 'dc1bp/01-dc1', 'DC1: package link is recorded');
    is(field_of($path, q{package_root}), AlmanacBug::_abs_root($PROJ), 'DC1: package_root is the caller\'s root');
    ok(defined field_of($path, 'scheduled_at'), 'DC1: scheduled_at is recorded');

    my ($rc_d, $out_d) = run('set-status', $id, '--project', $PROJ, '--to', 'dropped', '--note', '"wontfix"');
    is($rc_d, 0, 'DC1: scheduled -> dropped succeeds (no claimant gate once past triaging)') or diag $out_d;
    is(field_of($path, 'status'), 'dropped', 'DC1: status is dropped');
    is(field_of($path, 'resolution'), 'wontfix', 'DC1: the dropped reason is recorded');
}

# ---- triaging -> open hands it back ----------------------------------------
{
    my $PROJ = new_project();
    my (undef, $o) = run('file', '--project', $PROJ, '--title', '"dc1 handback"', '--body', '"b"');
    chomp(my $path = $o);
    my ($id) = $path =~ m{/([^/]+)\.md$};
    run_as('DC1H', undef, 'set-status', $id, '--project', $PROJ, '--to', 'triaging');
    is((run_as('DC1H', undef, 'set-status', $id, '--project', $PROJ, '--to', 'open'))[0], 0,
       'DC1: triaging -> open hands it back, by the claimant');
    is(field_of($path, 'status'), 'open', 'DC1: status is open again');
}

# ---- every other transition is refused -------------------------------------
{
    my $PROJ = new_project();

    # open -> scheduled: refused, file byte-identical.
    my (undef, $o1) = run('file', '--project', $PROJ, '--title', '"dc1 open-sched"', '--body', '"b"');
    chomp(my $p1 = $o1); my ($id1) = $p1 =~ m{/([^/]+)\.md$};
    my $before1 = slurp_raw($p1);
    my ($rc1, $out1) = run('set-status', $id1, '--project', $PROJ, '--to', 'scheduled', '--package', 'x/y');
    isnt($rc1, 0, 'DC1: open -> scheduled is refused');
    like($out1, qr/not a legal transition/, 'DC1: ...not a legal transition');
    is(slurp_raw($p1), $before1, 'DC1: open -> scheduled: file byte-identical after the refusal');

    # scheduled -> triaging: refused (identity gate passes via a minted
    # ticket for THIS exact argv, since --to triaging always requires one;
    # the transition is still illegal regardless).
    my ($p2, undef) = mk_bug_raw($PROJ, status => 'scheduled', package => 'dc1bpX/01-x', package_root => $PROJ);
    my $before2 = slurp_raw($p2);
    my @argv2 = ('set-status', $p2 =~ m{/([^/]+)\.md$}, '--project', $PROJ, '--to', 'triaging');
    mint_ticket('DC1T', undef, @argv2);
    my ($rc2, $out2) = run(@argv2);
    isnt($rc2, 0, 'DC1: scheduled -> triaging is refused');
    like($out2, qr/not a legal transition/, 'DC1: ...not a legal transition');
    is(slurp_raw($p2), $before2, 'DC1: scheduled -> triaging: file byte-identical after the refusal');

    # scheduled -> open: refused.
    my ($p3, undef) = mk_bug_raw($PROJ, status => 'scheduled', package => 'dc1bpX/01-x', package_root => $PROJ);
    my $before3 = slurp_raw($p3);
    my $id3 = $p3 =~ m{/([^/]+)\.md$} && $1;
    my ($rc3, $out3) = run('set-status', $id3, '--project', $PROJ, '--to', 'open');
    isnt($rc3, 0, 'DC1: scheduled -> open is refused');
    like($out3, qr/not a legal transition/, 'DC1: ...not a legal transition');
    is(slurp_raw($p3), $before3, 'DC1: scheduled -> open: file byte-identical after the refusal');

    # scheduled -> scheduled: refused.
    my ($rc4, $out4) = run('set-status', $id3, '--project', $PROJ, '--to', 'scheduled', '--package', 'dc1bpX/01-x');
    isnt($rc4, 0, 'DC1: scheduled -> scheduled is refused');
    like($out4, qr/not a legal transition/, 'DC1: ...not a legal transition');

    # dropped -> anything: refused, terminal.
    my ($p5, undef) = mk_bug_raw($PROJ, status => 'dropped', resolution => 'done with it');
    my $before5 = slurp_raw($p5);
    my $id5 = $p5 =~ m{/([^/]+)\.md$} && $1;
    my ($rc5, $out5) = run('set-status', $id5, '--project', $PROJ, '--to', 'open');
    isnt($rc5, 0, 'DC1: dropped -> open is refused (terminal)');
    like($out5, qr/not a legal transition/, 'DC1: ...not a legal transition');
    is(slurp_raw($p5), $before5, 'DC1: dropped: file byte-identical after the refusal');

    # fixed -> anything: refused, terminal.
    my ($p6, undef) = mk_bug_raw($PROJ, status => 'fixed', package => 'dc1bpX/01-x', package_root => $PROJ);
    my $before6 = slurp_raw($p6);
    my $id6 = $p6 =~ m{/([^/]+)\.md$} && $1;
    my ($rc6, $out6) = run('set-status', $id6, '--project', $PROJ, '--to', 'dropped', '--note', '"x"');
    isnt($rc6, 0, 'DC1: fixed -> dropped is refused (terminal)');
    like($out6, qr/not a legal transition/, 'DC1: ...not a legal transition');
    is(slurp_raw($p6), $before6, 'DC1: fixed: file byte-identical after the refusal');

    # --to fixed BY HAND without --no-package is ALWAYS refused, from any
    # state (AC3): open, and scheduled with an ACTIVE package.
    write_pkg_ledger($PROJ, 'dc1act', '01-act', 'running');
    my ($rc7, $out7) = run('set-status', $id1, '--project', $PROJ, '--to', 'fixed');
    isnt($rc7, 0, 'DC1: --to fixed from open (no --no-package) is refused');
    like($out7, qr/only.*together with --no-package/, 'DC1: ...fixed requires --no-package');
    my ($p8, undef) = mk_bug_raw($PROJ, status => 'scheduled', package => 'dc1act/01-act', package_root => $PROJ);
    my $before8 = slurp_raw($p8);
    my $id8 = $p8 =~ m{/([^/]+)\.md$} && $1;
    my ($rc8, $out8) = run('set-status', $id8, '--project', $PROJ, '--to', 'fixed');
    isnt($rc8, 0, 'DC1: --to fixed from scheduled (no --no-package) is refused');
    like($out8, qr/only.*together with --no-package/, 'DC1: ...fixed requires --no-package');
    is(slurp_raw($p8), $before8, 'DC1: --to fixed: file byte-identical after the refusal');

    # --to fixed --no-package from scheduled (an ACTIVE package) is ALSO
    # refused -- the escape hatch is for triaging only; a scheduled report
    # fixes via reconcile (Decision 66).
    my ($rc9, $out9) = run('set-status', $id8, '--project', $PROJ, '--to', 'fixed', '--no-package',
                            '--note', '"fixed by hand"');
    isnt($rc9, 0, 'DC1: --to fixed --no-package from scheduled is refused');
    like($out9, qr/--no-package only applies from triaging/, 'DC1: ...names the restriction');
    is(slurp_raw($p8), $before8, 'DC1: --to fixed --no-package from scheduled: file byte-identical after the refusal');
}

# ---- Decision 66: triaging -> fixed via --no-package (in-place fix, no package) ----
{
    my $PROJ = new_project();
    my (undef, $o) = run('file', '--project', $PROJ, '--title', '"dc1 no-package fix"', '--body', '"b"');
    chomp(my $path = $o);
    my ($id) = $path =~ m{/([^/]+)\.md$};
    run_as('DC1NP', undef, 'set-status', $id, '--project', $PROJ, '--to', 'triaging');

    # --no-package combined with any --to other than fixed is refused.
    my ($rc_bad, $out_bad) = run('set-status', $id, '--project', $PROJ, '--to', 'open', '--no-package');
    isnt($rc_bad, 0, 'DC1: --no-package with --to other than fixed is refused');
    like($out_bad, qr/--no-package applies only to --to fixed/, 'DC1: ...names the restriction');

    # --to fixed --no-package with no --note is refused. $from is triaging,
    # so this requires identity too (any move OUT of triaging does, not only
    # INTO it) -- run_as, by the same claimant.
    my ($rc_nn, $out_nn) = run_as('DC1NP', undef, 'set-status', $id, '--project', $PROJ, '--to', 'fixed', '--no-package');
    isnt($rc_nn, 0, 'DC1: --to fixed --no-package with no --note is refused');
    like($out_nn, qr/requires\s+--note "<what fixed it>"/, 'DC1: ...names the requirement');
    is(field_of($path, 'status'), 'triaging', 'DC1: still triaging after the refusal');

    # The real thing: triaging -> fixed, --no-package --note, by the claimant.
    # The note is deliberately UNQUOTED, single-token: run()'s backtick shell
    # strips a quoted value's quotes before the subprocess sees it, while the
    # ticket is minted against the literal (quoted) Perl argv element -- the
    # same pre-existing mismatch flagged in bug-triage-claim.t AC11 (and the
    # 07-bug-lifecycle implementer-1 report). Every existing run_as call in
    # this file already avoids quoted values for exactly this reason.
    my ($rc_ok, $out_ok) = run_as('DC1NP', undef, 'set-status', $id, '--project', $PROJ, '--to', 'fixed',
                                   '--no-package', '--note', 'patched-hooks.json-directly');
    is($rc_ok, 0, 'DC1: triaging -> fixed succeeds, by the claimant, with --no-package --note') or diag $out_ok;
    like($out_ok, qr/\(no package -- in-place fix\)/, 'DC1: ...the success line names it an in-place fix');
    is(field_of($path, 'status'), 'fixed', 'DC1: status is fixed');
    is(field_of($path, 'resolution'), 'patched-hooks.json-directly', 'DC1: the fix description is recorded as resolution');
    ok(defined field_of($path, 'fixed_at'), 'DC1: fixed_at is recorded');
    is(field_of($path, 'fixed_without_package'), '1', 'DC1: fixed_without_package marks this as hand-fixed, no package');
    ok(!defined field_of($path, 'package'), 'DC1: no package field is ever written for an in-place fix');

    # fixed is terminal, same as any other fixed report.
    my $before = slurp_raw($path);
    my ($rc_term, $out_term) = run('set-status', $id, '--project', $PROJ, '--to', 'dropped', '--note', '"x"');
    isnt($rc_term, 0, 'DC1: fixed (via --no-package) -> dropped is refused (terminal)');
    is(slurp_raw($path), $before, 'DC1: file byte-identical after the refusal');
}

# ---- scheduled without a valid --package link is refused -------------------
{
    my $PROJ = new_project();
    my (undef, $o) = run('file', '--project', $PROJ, '--title', '"dc1 bad links"', '--body', '"b"');
    chomp(my $path = $o); my ($id) = $path =~ m{/([^/]+)\.md$};
    run_as('DC1BL', undef, 'set-status', $id, '--project', $PROJ, '--to', 'triaging');
    my $before = slurp_raw($path);

    my ($rc_none, $out_none) = run_as('DC1BL', undef, 'set-status', $id, '--project', $PROJ, '--to', 'scheduled');
    isnt($rc_none, 0, 'DC1: scheduled with no --package is refused');
    like($out_none, qr/requires --package <blueprint>\/<package>/, 'DC1: ...names the requirement');
    is(slurp_raw($path), $before, 'DC1: no-package refusal: file byte-identical');

    my ($rc_bad, $out_bad) = run_as('DC1BL', undef, 'set-status', $id, '--project', $PROJ,
                                     '--to', 'scheduled', '--package', 'a/b/c');
    isnt($rc_bad, 0, 'DC1: scheduled with a malformed --package is refused');
    like($out_bad, qr/is not a <blueprint>\/<package> link/, 'DC1: ...names the grammar');
    is(slurp_raw($path), $before, 'DC1: malformed-link refusal: file byte-identical');

    my ($rc_miss, $out_miss) = run_as('DC1BL', undef, 'set-status', $id, '--project', $PROJ,
                                       '--to', 'scheduled', '--package', 'nosuchbp/nosuchpkg');
    isnt($rc_miss, 0, 'DC1: scheduled with a link missing from both locations is refused');
    like($out_miss, qr/resolves to no package ledger under/, 'DC1: ...names the missing ledger');
    is(slurp_raw($path), $before, 'DC1: missing-link refusal: file byte-identical');
}

# =============================================================================
# DC2 -- a scheduled bug whose package ledger turns done becomes fixed on the
# next almanac-bug.pl call, with the package recorded, including when the
# blueprint has moved to blueprints/_archive/<bp>/; parked/dropped/missing
# packages are flagged in list output; missing means absent from BOTH
# locations.
# =============================================================================

# ---- done -> fixed, live blueprint, no commit -------------------------------
{
    my $PROJ = new_project();
    write_pkg_ledger($PROJ, 'dc2bp', '01-dc2', 'done');
    my ($path, undef) = mk_bug_raw($PROJ, status => 'scheduled', package => 'dc2bp/01-dc2', package_root => $PROJ);
    my $id = $path =~ m{/([^/]+)\.md$} && $1;

    my ($rc, $out) = run('list', '--project', $PROJ);
    is($rc, 0, 'DC2: list exits 0') or diag $out;
    is(field_of($path, 'status'), 'fixed', 'DC2: the report is now fixed');
    is(field_of($path, 'package'), 'dc2bp/01-dc2', 'DC2: the package link is kept');
    ok(defined field_of($path, 'fixed_at'), 'DC2: fixed_at is recorded');
    ok(!defined field_of($path, 'fixed_commit'), 'DC2: no fixed_commit (ledger has no Outputs section)');

    my ($rc_j, $out_j) = run('list', '--project', $PROJ, '--json');
    my $rows = eval { JSON::PP->new->decode($out_j) };
    my ($row) = grep { ($_->{id} // '') eq $id } @{ $rows || [] };
    SKIP: {
        skip 'DC2: row not found in list --json', 1 unless $row;
        is($row->{status}, 'fixed', 'DC2: list --json shows the row as fixed');
    }
}

# ---- done -> fixed, blueprint moved to _archive/ ---------------------------
{
    my $PROJ = new_project();
    write_pkg_ledger($PROJ, 'dc2arc', '01-arc', 'done', archived => 1);
    my ($path, undef) = mk_bug_raw($PROJ, status => 'scheduled', package => 'dc2arc/01-arc', package_root => $PROJ);

    run('list', '--project', $PROJ);
    is(field_of($path, 'status'), 'fixed', 'DC2: an archived-blueprint package still fixes the report');
    is(field_of($path, 'package'), 'dc2arc/01-arc', 'DC2: the package link is kept (archived case)');
}

# ---- commit parsing: multiple shas, dedup, order, TBD ignored --------------
{
    my $PROJ = new_project();
    write_pkg_ledger($PROJ, 'dc2cm', '01-cm', 'done', body => <<'OUT');

## Outputs

- commit: ABC1234def
commit: TBD
commit: 9f9f9f9
`commit: abc1234DEF`
OUT
    my ($path, undef) = mk_bug_raw($PROJ, status => 'scheduled', package => 'dc2cm/01-cm', package_root => $PROJ);
    run('list', '--project', $PROJ);
    is(field_of($path, 'status'), 'fixed', 'DC2: commit-parsing fixture also becomes fixed');
    is(field_of($path, 'fixed_commit'), 'abc1234def 9f9f9f9',
       'DC2: fixed_commit is the distinct lowercase shas, in first-appearance order (TBD ignored)');
}

# ---- parked / dropped / missing: flagged, never fixed, byte-identical -----
for my $case (
    [ 'parked',  'dc2pk/01-pk', sub { write_pkg_ledger($_[0], 'dc2pk', '01-pk', 'parked') },
      qr/PACKAGE PARKED: dc2pk\/01-pk is parked/ ],
    [ 'dropped', 'dc2dp/01-dp', sub { write_pkg_ledger($_[0], 'dc2dp', '01-dp', 'dropped') },
      qr/PACKAGE DROPPED: dc2dp\/01-dp was dropped/ ],
    [ 'missing', 'dc2ms/01-ms', sub { },
      qr/PACKAGE MISSING: dc2ms\/01-ms has no ledger/ ],
) {
    my ($name, $link, $setup, $flag_re) = @$case;
    my $PROJ = new_project();
    $setup->($PROJ);
    my ($path, undef) = mk_bug_raw($PROJ, status => 'scheduled', package => $link, package_root => $PROJ);
    my $before = slurp_raw($path);

    my ($rc1, $out1) = run('list', '--project', $PROJ);
    is(field_of($path, 'status'), 'scheduled', "DC2: $name package -- report stays scheduled");
    like($out1, $flag_re, "DC2: $name package -- list shows the flag line");
    is(slurp_raw($path), $before, "DC2: $name package -- file byte-identical after one call");

    run('list', '--project', $PROJ);
    is(slurp_raw($path), $before, "DC2: $name package -- file byte-identical after a SECOND call");

    my (undef, $out_j) = run('list', '--project', $PROJ, '--json');
    my $rows = eval { JSON::PP->new->decode($out_j) };
    my ($row) = grep { ($_->{package} // '') eq $link } @{ $rows || [] };
    SKIP: {
        skip "DC2: $name row not found in --json", 1 unless $row;
        is($row->{package_problem}, $name, "DC2: $name package -- --json carries package_problem");
    }
}

# =============================================================================
# DC3 -- dropped without a reason/note is refused.
# =============================================================================
{
    my $PROJ = new_project();
    my (undef, $o) = run('file', '--project', $PROJ, '--title', '"dc3 no reason"', '--body', '"b"');
    chomp(my $path = $o); my ($id) = $path =~ m{/([^/]+)\.md$};
    my $before = slurp_raw($path);

    my ($rc1, $out1) = run('set-status', $id, '--project', $PROJ, '--to', 'dropped');
    isnt($rc1, 0, 'DC3: dropped with no --note is refused');
    like($out1, qr/requires --note "<reason>"/, 'DC3: ...names the requirement');
    is(slurp_raw($path), $before, 'DC3: no-note refusal: file byte-identical');

    my ($rc2, $out2) = run('set-status', $id, '--project', $PROJ, '--to', 'dropped', '--note', '""');
    isnt($rc2, 0, 'DC3: dropped with an empty --note is refused');
    like($out2, qr/requires --note "<reason>"/, 'DC3: ...names the requirement (empty note)');
    is(slurp_raw($path), $before, 'DC3: empty-note refusal: file byte-identical');
}

# =============================================================================
# DC4 -- fixture reports in taken/resolved/declined migrate per the spec's
# exact grammar, idempotently; an unresolvable taken report stays flagged,
# never guessed.
# =============================================================================

# ---- taken, resolvable NUMBER form, ledger active: migrates to scheduled --
{
    my $PROJ = new_project();
    write_pkg_ledger($PROJ, 'dc4nn', '07-x', 'running');
    my ($path, undef) = mk_bug_raw($PROJ, status => 'taken', taken_at => AlmanacBug::_iso(time),
        resolution => 'Scheduled as dc4nn 07');
    my $id = $path =~ m{/([^/]+)\.md$} && $1;

    run('list', '--project', $PROJ);
    is(field_of($path, 'status'), 'scheduled', 'DC4: taken (NN form) migrates to scheduled');
    is(field_of($path, 'package'), 'dc4nn/07-x', 'DC4: ...with the resolved package link');
    is(field_of($path, q{package_root}), AlmanacBug::_abs_root($PROJ), 'DC4: ...and package_root');
    is(field_of($path, 'migrated_from'), 'taken', 'DC4: ...and migrated_from is taken');
    ok(defined field_of($path, 'content_sha256'), 'DC4: content_sha256 is unchanged (still frozen)');

    my $before2 = slurp_raw($path);
    run('list', '--project', $PROJ);
    is(slurp_raw($path), $before2, 'DC4: idempotent -- a second call changes no byte');
}

# ---- taken, resolvable NUMBER form, ledger DONE: migrates straight to fixed
# in the same call -------------------------------------------------------
{
    my $PROJ = new_project();
    write_pkg_ledger($PROJ, 'dc4nd', '09-y', 'done');
    my ($path, undef) = mk_bug_raw($PROJ, status => 'taken', taken_at => AlmanacBug::_iso(time),
        resolution => 'scheduled as dc4nd/09-y.');  # lowercase + trailing dot, full-link form
    run('list', '--project', $PROJ);
    is(field_of($path, 'status'), 'fixed', 'DC4: taken (full-link form, lowercase, trailing dot) resolves to a DONE ledger and continues straight to fixed');
    is(field_of($path, 'package'), 'dc4nd/09-y', 'DC4: ...with the package link recorded');
    is(field_of($path, 'migrated_from'), 'taken', 'DC4: ...migrated_from is taken');
    ok(defined field_of($path, 'fixed_at'), 'DC4: ...and fixed_at is recorded');
}

# ---- taken, no resolution at all: stays taken, flagged ---------------------
{
    my $PROJ = new_project();
    my ($path, undef) = mk_bug_raw($PROJ, status => 'taken', taken_at => AlmanacBug::_iso(time));
    my $id = $path =~ m{/([^/]+)\.md$} && $1;
    my $before = slurp_raw($path);

    my (undef, $out) = run('list', '--project', $PROJ);
    is(field_of($path, 'status'), 'taken', 'DC4: taken with no resolution stays taken');
    like($out, qr/!! UNMIGRATED: .*its note names no package/, 'DC4: ...list flags it UNMIGRATED');
    is(slurp_raw($path), $before, 'DC4: no-resolution: file byte-identical');

    my (undef, $out_j) = run('list', '--project', $PROJ, '--json');
    my $rows = eval { JSON::PP->new->decode($out_j) };
    my ($row) = grep { ($_->{id} // '') eq $id } @{ $rows || [] };
    SKIP: {
        skip 'DC4: row not found', 1 unless $row;
        like($row->{unmigrated}, qr/its note names no package/, 'DC4: --json carries the unmigrated reason');
    }
}

# ---- taken, ambiguous (two different named packages): stays taken, flagged
{
    my $PROJ = new_project();
    my ($path, undef) = mk_bug_raw($PROJ, status => 'taken', taken_at => AlmanacBug::_iso(time),
        resolution => 'Scheduled as foo/01-a, actually Scheduled as bar/02-b');
    my $before = slurp_raw($path);
    my (undef, $out) = run('list', '--project', $PROJ);
    is(field_of($path, 'status'), 'taken', 'DC4: taken naming two different packages stays taken');
    like($out, qr/!! UNMIGRATED: .*its note names more than one package/, 'DC4: ...flagged as ambiguous');
    is(slurp_raw($path), $before, 'DC4: ambiguous: file byte-identical -- never guessed');
}

# ---- taken, resolvable-looking link that resolves to NO ledger: stays taken
{
    my $PROJ = new_project();
    my ($path, undef) = mk_bug_raw($PROJ, status => 'taken', taken_at => AlmanacBug::_iso(time),
        resolution => 'Scheduled as nosuchbp/01-nope');
    my $before = slurp_raw($path);
    my (undef, $out) = run('list', '--project', $PROJ);
    is(field_of($path, 'status'), 'taken', 'DC4: taken naming an unresolvable link stays taken');
    like($out, qr/!! UNMIGRATED: .*resolves to no package ledger under/, 'DC4: ...flagged as unresolvable');
    is(slurp_raw($path), $before, 'DC4: unresolvable: file byte-identical -- never guessed');
}

# ---- resolved -> fixed; declined (with/without reason) -> dropped ---------
{
    my $PROJ = new_project();
    my ($pr, undef) = mk_bug_raw($PROJ, status => 'resolved', resolution => 'fixed in abc123');
    run('list', '--project', $PROJ);
    is(field_of($pr, 'status'), 'fixed', 'DC4: resolved migrates to fixed');
    is(field_of($pr, 'migrated_from'), 'resolved', 'DC4: ...migrated_from is resolved');
    is(field_of($pr, 'resolution'), 'fixed in abc123', 'DC4: ...resolution is kept as-is');

    my ($pd1, undef) = mk_bug_raw($PROJ, status => 'declined', resolution => 'not ours');
    run('list', '--project', $PROJ);
    is(field_of($pd1, 'status'), 'dropped', 'DC4: declined (with a reason) migrates to dropped');
    is(field_of($pd1, 'migrated_from'), 'declined', 'DC4: ...migrated_from is declined');
    is(field_of($pd1, 'resolution'), 'not ours', 'DC4: ...the reason is carried forward unchanged');

    my ($pd2, undef) = mk_bug_raw($PROJ, status => 'declined');
    run('list', '--project', $PROJ);
    is(field_of($pd2, 'status'), 'dropped', 'DC4: declined (no reason) migrates to dropped');
    is(field_of($pd2, 'resolution'), 'migrated from declined (no reason recorded)',
       'DC4: ...a synthesized reason is recorded');

    # Idempotency across the whole batch in one more call.
    my %before = map { $_ => slurp_raw($_) } ($pr, $pd1, $pd2);
    run('list', '--project', $PROJ);
    for my $p (sort keys %before) {
        is(slurp_raw($p), $before{$p}, "DC4: idempotent -- $p unchanged by a second call");
    }
}

# =============================================================================
# DC5 -- bug-report and bug-triage skills describe the new states.
# =============================================================================
{
    my $TRIAGE_SKILL = "$ALMANAC_DIR/skills/bug-triage/SKILL.md";
    my $REPORT_SKILL = "$ALMANAC_DIR/skills/bug-report/SKILL.md";
    for my $p ($TRIAGE_SKILL, $REPORT_SKILL) {
        SKIP: {
            skip "DC5: $p missing", 1 unless -f $p;
            ok(1, "DC5: $p exists");
        }
    }
    SKIP: {
        skip 'DC5: bug-triage/SKILL.md missing', 8 unless -f $TRIAGE_SKILL;
        open my $fh, '<:raw', $TRIAGE_SKILL or die "cannot read $TRIAGE_SKILL: $!";
        local $/; my $txt = <$fh>; close $fh;
        like($txt, qr/\bscheduled\b/, 'DC5: bug-triage/SKILL.md mentions scheduled');
        like($txt, qr/\bfixed\b/, 'DC5: bug-triage/SKILL.md mentions fixed');
        like($txt, qr/\bdropped\b/, 'DC5: bug-triage/SKILL.md mentions dropped');
        like($txt, qr/--package/, 'DC5: bug-triage/SKILL.md mentions --package');
        like($txt, qr/open\s+->\s+triaging\s+->\s+scheduled\s+->\s+fixed\s*\|\s*dropped/,
            'DC5: bug-triage/SKILL.md has the full lifecycle line');
        unlike($txt, qr/reviewing/i, 'DC5: bug-triage/SKILL.md names no "reviewing" (case-insensitive)');
        unlike($txt, qr/--to\s+taken\b/, 'DC5: bug-triage/SKILL.md has no --to taken');
        unlike($txt, qr/--to\s+resolved\b/, 'DC5: bug-triage/SKILL.md has no --to resolved');
        unlike($txt, qr/--to\s+declined\b/, 'DC5: bug-triage/SKILL.md has no --to declined');
    }
    SKIP: {
        skip 'DC5: bug-report/SKILL.md missing', 6 unless -f $REPORT_SKILL;
        open my $fh, '<:raw', $REPORT_SKILL or die "cannot read $REPORT_SKILL: $!";
        local $/; my $txt = <$fh>; close $fh;
        like($txt, qr/\bscheduled\b/, 'DC5: bug-report/SKILL.md mentions scheduled');
        like($txt, qr/\bfixed\b/, 'DC5: bug-report/SKILL.md mentions fixed');
        like($txt, qr/\bdropped\b/, 'DC5: bug-report/SKILL.md mentions dropped');
        unlike($txt, qr/reviewing/i, 'DC5: bug-report/SKILL.md names no "reviewing" (case-insensitive)');
        unlike($txt, qr/--to\s+taken\b/, 'DC5: bug-report/SKILL.md has no --to taken');
        unlike($txt, qr/--to\s+resolved\b/, 'DC5: bug-report/SKILL.md has no --to resolved');
    }
}

# ---- hygiene: this file never touched the REAL machine state ---------------
{
    my $after_butler = snapshot_dir($REAL_BUTLER_STATE);
    my $after_bugs   = snapshot_dir($REAL_BUG_REPORTS);
    is_deeply($after_butler, $HYGIENE_BEFORE_BUTLER,
        'hygiene: the real ~/.claude/butler-state is untouched by this file');
    is_deeply($after_bugs, $HYGIENE_BEFORE_BUGS,
        'hygiene: the real repo .ccpraxis-local-data/bug-reports is untouched by this file');
}

# ---- a claim's transcript path is written as UTF-8, whatever it contains ----
# The ticket is JSON, decoded to characters; the report is written :raw. A path
# with a non-ASCII character (this machine's C:/Users/André/...) therefore
# landed as a lone Latin-1 byte, and Almanac::Record refused every claimed
# report as "not valid UTF-8" (almanac-record-format.t AC4, 2026-10-12).
{
    require Encode;
    my $PROJ = new_project();
    my (undef, $o) = run('file', '--project', $PROJ, '--title', '"utf8 transcript path"', '--body', '"b"');
    chomp(my $path = $o);
    my ($id) = $path =~ m{/([^/]+)\.md$};

    my $sid = 'UTF8TP';
    my $dir = "$CFG/projects/Andr\x{e9}";
    my $transcript = "$dir/$sid.jsonl";
    my @argv = ('set-status', $id, '--project', $PROJ, '--to', 'triaging');
    {
        local $ENV{BUTLER_STATE_DIR} = $BSD;
        BpHook::write_ticket(
            { session_id => $sid, tool_use_id => 'T' . (++$TICKET_SEQ),
              transcript_path => $transcript, cwd => undef },
            'almanac-bug', [ @argv ]) or die "fixture: could not write ticket\n";
    }
    my ($rc, $out) = run(@argv);
    is($rc, 0, 'UTF8: the claim succeeds') or diag $out;

    my $bytes = slurp_raw($path) // '';
    ok(eval { Encode::decode('UTF-8', $bytes, Encode::FB_CROAK()); 1 },
       'UTF8: the claimed report is valid UTF-8');
    is(field_of($path, 'claimant_transcript_path'), Encode::encode('UTF-8', $transcript),
       'UTF8: claimant_transcript_path is the path, UTF-8 encoded');
}

done_testing();
