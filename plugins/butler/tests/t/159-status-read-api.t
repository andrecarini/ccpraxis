#!/usr/bin/env perl
# t/159-status-read-api.t — immutable oracle for BpState.pm, the s01-status-read-api
# package (spec: .ccpraxis-local-data/blueprints/butler-and-dashboard-overhaul/
# specs/s01-status-read-api-spec.md).
#
# `plugins/butler/scripts/BpState.pm` does not exist yet -> the require below
# fails, caught with eval (house pattern, t/98-write-guard-primitive.t), so
# every BpState:: call dies with "Undefined subroutine" -- the RIGHT failure
# reason for a not-yet-built module. Every assertion in this file is written
# against §3's numbered "Observable behaviors" and the driver's ruling that
# PKG_ALL is EIGHT values (pending running converging reviewing done blocked
# parked dropped), not seven — see spec §1 and the package's attempt log.
#
# This file is immutable ground truth for the implementer that follows.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use File::Find qw(find);

my $SCRIPT = "$Bin/../../scripts/BpState.pm";
my $LOADED = do {
    local $@;
    eval { require $SCRIPT };
    !$@;
};
my $REQUIRE_ERROR = $@;

# ── fixture helpers (house pattern, plugins/butler/tests/t/97-lifecycle-reconcile.t:39-135) ──
sub write_file {
    my ($path, $content) = @_;
    my $dir = $path;
    $dir =~ s{[^/\\]+\z}{};
    make_path($dir) if length($dir) && !-d $dir;
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

# A well-formed ledger: `---`-delimited frontmatter + a status line (or none,
# for the "no status: key" fixture).
sub ledger_text {
    my ($pkg, $status_line) = @_;
    my $fm = "package: $pkg\n";
    $fm .= "$status_line\n" if defined $status_line;
    $fm .= "last_updated: 2026-01-01T00:00Z\n";
    return "---\n$fm---\n\n# Package $pkg\n\n## Next action\n\nNone.\n";
}

sub write_ledger {
    my ($bpdir, $pkg, $status_line) = @_;
    write_file("$bpdir/packages/$pkg.md", ledger_text($pkg, $status_line));
}

sub write_marker {
    my ($bpdir, $content) = @_;
    write_file("$bpdir/runs/.orchestrator", $content);
}

# A blueprint.md with the real shape: a FENCED metadata block, not frontmatter
# (bp-lifecycle.pl:530-541 / spec §2.4). `$status` is the raw authored field.
sub blueprint_md_fenced {
    my ($status) = @_;
    return <<"MD";
# Test Blueprint

```
blueprint: test
created: 2026-01-01
status: $status        # drafting | audited | running | done | archived
```

## Objective

Test fixture.
MD
}

sub write_blueprint_md {
    my ($bpdir, $status) = @_;
    write_file("$bpdir/blueprint.md", blueprint_md_fenced($status));
}

sub bpdir { return tempdir(CLEANUP => 1); }

# Recursive mtime snapshot, `File::Find` (never `glob` — a real landmine class
# on this machine, spec §5/§2, driver instructions).
sub mtime_snapshot {
    my ($root) = @_;
    my %snap;
    return %snap unless -d $root;
    find(sub {
        return unless -f $File::Find::name;
        $snap{$File::Find::name} = (stat($File::Find::name))[9];
    }, $root);
    return %snap;
}

# ═════════════════════════════════════════════════════════════════════════
# DC1/DC2 — module loads, all five functions exist with documented names
# ═════════════════════════════════════════════════════════════════════════
ok($LOADED, 'DC1/DC2: BpState.pm requires cleanly as package BpState')
    or diag("require died with: $REQUIRE_ERROR");
ok(defined &BpState::package_status,       'DC2: BpState::package_status is defined');
ok(defined &BpState::all_package_statuses, 'DC2: BpState::all_package_statuses is defined');
ok(defined &BpState::orchestrator_pid,     'DC2: BpState::orchestrator_pid is defined');
ok(defined &BpState::run_is_live,          'DC2: BpState::run_is_live is defined');
ok(defined &BpState::blueprint_lifecycle,  'DC2: BpState::blueprint_lifecycle is defined');

# ═════════════════════════════════════════════════════════════════════════
# DC1 — purity, grep-verifiable against the module's own source (AC1)
# ═════════════════════════════════════════════════════════════════════════
{
    my $src = -f $SCRIPT ? slurp($SCRIPT) : undef;
    ok(defined $src, 'DC1: BpState.pm source is readable')
        or diag('BpState.pm does not exist on disk yet');

    my %banned = (
        'die'       => qr/\bdie\b/,
        'system('   => qr/\bsystem\s*\(/,
        'backtick'  => qr/`/,
        'exec'      => qr/\bexec\b/,
        'fork'      => qr/\bfork\b/,
        'kill('     => qr/\bkill\s*\(/,
        'time('     => qr/\btime\s*\(/,
        'gmtime('   => qr/\bgmtime\s*\(/,
        'localtime(' => qr/\blocaltime\s*\(/,
        'glob('     => qr/\bglob\s*\(/,
    );
    for my $label (sort keys %banned) {
        my $found = defined($src) ? ($src =~ $banned{$label}) : 1;
        ok(!$found, "DC1: BpState.pm source contains no '$label'");
    }
}
{
    # DC1: perl -c compiles cleanly (checks:perl-compile). Compiling the
    # TARGET file only — never launcher.pl/bp-orchestrator.pl.
    my ($ofh, $out) = tempfile('t98-compileXXXXXX', TMPDIR => 1); close $ofh;
    SKIP: {
        skip 'BpState.pm absent, nothing to compile-check', 1 unless -f $SCRIPT;
        open my $saved_out, '>&', \*STDOUT or die "dup: $!";
        open my $saved_err, '>&', \*STDERR or die "dup: $!";
        open(STDOUT, '>', $out) or die "redirect: $!";
        open(STDERR, '>&', \*STDOUT) or die "redirect err: $!";
        my $rc = system($^X, '-c', $SCRIPT);
        open(STDOUT, '>&', $saved_out); close $saved_out;
        open(STDERR, '>&', $saved_err); close $saved_err;
        is($rc, 0, 'DC1: perl -c BpState.pm exits 0') or diag(slurp($out) // '');
    }
    unlink $out;
}

# ═════════════════════════════════════════════════════════════════════════
# §3 behaviors 1-3 — package_status: all 8 PKG_ALL words, mixed case, decoration
# (driver ruling: EIGHT statuses, "converging" included — not the criterion's
#  literal "seven". A package_status that could only ever return 'pending' for
#  everything is defeated below by asserting the DISTINCT expected word each
#  time, not merely "is defined"/"ne pending".)
# ═════════════════════════════════════════════════════════════════════════
{
    my @PKG_ALL = qw(pending running converging reviewing done blocked parked dropped);
    for my $status (@PKG_ALL) {
        my $dir = bpdir();
        my $pkg = "pkg-$status";
        write_ledger($dir, $pkg, "status: $status");
        my $got = eval { BpState::package_status($dir, $pkg) };
        is($got, $status, "behavior1/PKG_ALL: status:$status ledger -> '$status'");
    }
}
{
    my $dir = bpdir();
    write_ledger($dir, 'p', 'status: Converging');
    my $got = eval { BpState::package_status($dir, 'p') };
    is($got, 'converging', 'behavior2: mixed-case "Converging" normalises to converging');
}
{
    my $dir = bpdir();
    write_ledger($dir, 'p', "status: \x{2705} done");
    my $got = eval { BpState::package_status($dir, 'p') };
    is($got, 'done', 'behavior3: table-style decoration "<glyph> done" normalises to done');
}

# ═════════════════════════════════════════════════════════════════════════
# §3 behaviors 4-8 — package_status: missing / empty / malformed -> 'pending'
# (each fixture is independently confirmed to produce a NON-pending value for
#  a well-formed sibling ledger in the same directory, so a package_status
#  that just returns 'pending' unconditionally cannot pass this whole file —
#  see the loop above, run first, for that contrast.)
# ═════════════════════════════════════════════════════════════════════════
{
    my $dir = bpdir();
    make_path("$dir/packages");
    my $got = eval { BpState::package_status($dir, 'never-written') };
    is($got, 'pending', 'behavior4: missing packages/<pkg>.md -> pending');
}
{
    my $dir = bpdir();
    write_file("$dir/packages/empty.md", '');
    my $got = eval { BpState::package_status($dir, 'empty') };
    is($got, 'pending', 'behavior5: zero-byte ledger -> pending');
}
{
    my $dir = bpdir();
    write_file("$dir/packages/noFm.md", "# Package noFm\n\nJust prose, no frontmatter block at all.\n");
    my $got = eval { BpState::package_status($dir, 'noFm') };
    is($got, 'pending', 'behavior6: no ---delimited frontmatter block -> pending');
}
{
    my $dir = bpdir();
    write_ledger($dir, 'noKey', undef);   # frontmatter present, no status: line
    my $got = eval { BpState::package_status($dir, 'noKey') };
    is($got, 'pending', 'behavior7: frontmatter present but no status: key -> pending');
}
{
    my $dir = bpdir();
    write_ledger($dir, 'garbled', 'status: frobnicated');
    my $got = eval { BpState::package_status($dir, 'garbled') };
    is($got, 'pending', 'behavior8: status: frobnicated (unrecognised free text) -> pending');
}

# ═════════════════════════════════════════════════════════════════════════
# §5 edge cases worth a fixture — CRLF, UTF-8 BOM, status-line-outside-block
# ═════════════════════════════════════════════════════════════════════════
{
    my $dir = bpdir();
    write_file("$dir/packages/crlf.md",
        "---\r\npackage: crlf\r\nstatus: running\r\nlast_updated: 2026-01-01T00:00Z\r\n---\r\n\r\n# Package crlf\r\n");
    my $got = eval { BpState::package_status($dir, 'crlf') };
    is($got, 'running', 'edge: CRLF line endings in frontmatter still parse to running');
}
{
    my $dir = bpdir();
    write_file("$dir/packages/bom.md",
        "\xEF\xBB\xBF---\npackage: bom\nstatus: running\n---\n\n# Package bom\n");
    my $got = eval { BpState::package_status($dir, 'bom') };
    is($got, 'pending', 'edge: UTF-8 BOM before the first --- hides the frontmatter -> pending, not a crash');
}
{
    my $dir = bpdir();
    write_file("$dir/packages/outside.md",
        "---\npackage: outside\nstatus: running\n---\n\n# Package outside\n\n## Next action\n\nstatus: done -- do not let a whole-file regex trip on this line.\n");
    my $got = eval { BpState::package_status($dir, 'outside') };
    is($got, 'running',
       'edge: a status:-looking line OUTSIDE the frontmatter block is ignored (fm_get scans only the first --- block)');
}

# ═════════════════════════════════════════════════════════════════════════
# §3 behaviors 9-10 — .lock adjacency: direct read unaffected; enumeration excludes it
# (defeats an all_package_statuses that returns {} unconditionally: this
#  fixture asserts a non-empty, exact-membership hash.)
# ═════════════════════════════════════════════════════════════════════════
{
    my $dir = bpdir();
    write_ledger($dir, 'locked', 'status: running');
    write_file("$dir/packages/locked.md.lock", 'transient flock artefact, not a ledger');

    my $direct = eval { BpState::package_status($dir, 'locked') };
    is($direct, 'running',
       'behavior9: package_status called directly still reads the real ledger, unaffected by the .lock file');

    my $all = eval { BpState::all_package_statuses($dir) };
    is(ref($all), 'HASH', 'behavior9: all_package_statuses returns a hashref')
        or diag('all_package_statuses did not return a HASH ref');
    SKIP: {
        skip 'not a hashref, cannot inspect membership', 2 unless ref($all) eq 'HASH';
        is(scalar(keys %$all), 1, 'behavior9: exactly one entry (the .lock contributes none)');
        ok(!exists $all->{'locked.md'}, 'behavior9: no key derived from the .lock filename itself');
    }
}
{
    my $dir = bpdir();
    write_ledger($dir, 'a', 'status: done');
    write_ledger($dir, 'b', 'status: running');
    write_ledger($dir, 'c', 'status: blocked');
    write_file("$dir/packages/a.md.lock", 'junk');

    my $all = eval { BpState::all_package_statuses($dir) };
    is(ref($all), 'HASH', 'behavior10: all_package_statuses returns a hashref for 3 ledgers + 1 lock');
    SKIP: {
        skip 'not a hashref, cannot inspect membership', 4 unless ref($all) eq 'HASH';
        is(scalar(keys %$all), 3, 'behavior10: 3 real ledgers + 1 .lock -> 3-entry hash, not 4 and not 0');   # shape-lint: intentional — $all is derived from a tempdir THIS test builds three lines above (write_ledger a/b/c plus one a.md.lock), so the count asserts this package's own .lock-exclusion behaviour, not the shape of a shared artifact no later package may extend. A floor cannot express it: the defect being guarded is counting FOUR (the .lock leaking in), and cmp_ok(>=3) passes in exactly that case.
        is($all->{a}, 'done',    'behavior10: key "a" carries its own ledger status (done)');
        is($all->{b}, 'running', 'behavior10: key "b" carries its own ledger status (running)');
        is($all->{c}, 'blocked', 'behavior10: key "c" carries its own ledger status (blocked)');
    }
}

# ═════════════════════════════════════════════════════════════════════════
# §3 behaviors 11-12 — all_package_statuses: packages/ absent / empty -> {}
# ═════════════════════════════════════════════════════════════════════════
{
    my $dir = bpdir();   # packages/ never created
    my $all = eval { BpState::all_package_statuses($dir) };
    is_deeply($all, {}, 'behavior11: packages/ does not exist -> {}');
}
{
    my $dir = bpdir();
    make_path("$dir/packages");
    my $all = eval { BpState::all_package_statuses($dir) };
    is_deeply($all, {}, 'behavior12: packages/ exists and is empty -> {}');
}

# ═════════════════════════════════════════════════════════════════════════
# §5 edge case — a directory named `<pkg>.md` inside packages/ is skipped (-f check)
# ═════════════════════════════════════════════════════════════════════════
{
    my $dir = bpdir();
    write_ledger($dir, 'real', 'status: running');
    make_path("$dir/packages/odd.md");   # a DIRECTORY, not a file
    my $all = eval { BpState::all_package_statuses($dir) };
    is(ref($all), 'HASH', 'edge: directory-named-like-a-ledger case returns a hashref');
    SKIP: {
        skip 'not a hashref', 2 unless ref($all) eq 'HASH';
        is(scalar(keys %$all), 1, 'edge: the directory entry contributes no key');
        ok(!exists $all->{odd}, 'edge: "odd" is not present (the -f guard skipped the directory)');
    }
}

# ═════════════════════════════════════════════════════════════════════════
# §5 edge case — path containing spaces and non-ASCII characters
# ═════════════════════════════════════════════════════════════════════════
{
    my $root = tempdir(CLEANUP => 1);
    my $dir  = "$root/space dir Andr\x{e9}";
    make_path($dir);
    write_ledger($dir, 'p', 'status: running');
    my $got = eval { BpState::package_status($dir, 'p') };
    is($got, 'running', 'edge: a $bpdir path containing spaces and non-ASCII resolves normally');
    my $all = eval { BpState::all_package_statuses($dir) };
    is(ref($all), 'HASH', 'edge: all_package_statuses also works under a spaced/non-ASCII path');
}

# ═════════════════════════════════════════════════════════════════════════
# §3 behaviors 13-17 — orchestrator_pid
# ═════════════════════════════════════════════════════════════════════════
{
    my $dir = bpdir();
    my $got = eval { BpState::orchestrator_pid($dir) };
    is($got, undef, 'behavior13: runs/.orchestrator absent -> undef');
}
{
    my $dir = bpdir();
    write_marker($dir, "12345\n");
    my $got = eval { BpState::orchestrator_pid($dir) };
    is($got, 12345, 'behavior14: marker "12345\n" -> 12345');
}
{
    my $dir = bpdir();
    write_marker($dir, "abc");
    my $got = eval { BpState::orchestrator_pid($dir) };
    is($got, undef, 'behavior15: marker "abc" -> undef');
}
{
    my $dir = bpdir();
    write_marker($dir, ('1' x 4200));   # >4096 bytes, all-digit so length is the ONLY disqualifier
    my $got = eval { BpState::orchestrator_pid($dir) };
    is($got, undef, 'behavior16: marker content >4096 bytes -> undef (length check, not numeric)');
}
{
    my $dir = bpdir();
    write_marker($dir, "0");
    my $got = eval { BpState::orchestrator_pid($dir) };
    is($got, undef, 'behavior17: marker "0" -> undef (pid must be > 0)');
}

# ═════════════════════════════════════════════════════════════════════════
# §3 behaviors 18-22 — run_is_live
# (each $alive_fn is a counting closure so we can assert it was/was not
#  actually invoked, defeating a run_is_live that ignores $alive_fn entirely.)
# ═════════════════════════════════════════════════════════════════════════
{
    my $dir = bpdir();   # no marker at all
    my $calls = 0;
    my $probe = sub { $calls++; return 1; };
    my $got = eval { BpState::run_is_live($dir, $probe) };
    is($got, 0, 'behavior18: marker absent -> 0');
    is($calls, 0, 'behavior18: $alive_fn is never invoked when there is no marker');
}
{
    my $dir = bpdir();
    write_marker($dir, "4242\n");
    my @seen;
    my $probe = sub { my ($pid) = @_; push @seen, $pid; return 1; };
    my $got = eval { BpState::run_is_live($dir, $probe) };
    is($got, 1, 'behavior19: valid marker + $alive_fn true -> 1');
    is_deeply(\@seen, [4242], 'behavior19: $alive_fn was invoked exactly once, with the parsed pid');
}
{
    my $dir = bpdir();
    write_marker($dir, "4242\n");
    my @seen;
    my $probe = sub { my ($pid) = @_; push @seen, $pid; return 0; };
    my $got = eval { BpState::run_is_live($dir, $probe) };
    is($got, 0, 'behavior20: valid marker + $alive_fn false -> 0');
    is_deeply(\@seen, [4242], 'behavior20: $alive_fn was still invoked (not short-circuited by outcome)');
}
{
    my $dir = bpdir();
    write_marker($dir, "not-a-pid");
    my $calls = 0;
    my $probe = sub { $calls++; return 1; };
    my $got = eval { BpState::run_is_live($dir, $probe) };
    is($got, 0, 'behavior21: unparsable marker content -> 0');
    is($calls, 0, 'behavior21: $alive_fn is never invoked when the marker cannot be parsed');
}
{
    my $dir = bpdir();
    write_marker($dir, "4242\n");
    my $got = eval { BpState::run_is_live($dir, undef) };
    is($got, 0, 'behavior22: $alive_fn undef (not a coderef) -> 0, no crash');
    my $err = $@;
    ok(1, 'behavior22: reached past the call'); # presence of this line proves no fatal exit
}
{
    my $dir = bpdir();
    write_marker($dir, "4242\n");
    my $got = eval { BpState::run_is_live($dir, 'not-a-coderef-scalar') };
    is($got, 0, 'edge: $alive_fn is a plain scalar (not undef, still not a coderef) -> 0, no crash');
}

# ═════════════════════════════════════════════════════════════════════════
# §3 behaviors 23-32 and §2.4's explicit precedence — blueprint_lifecycle
# ═════════════════════════════════════════════════════════════════════════

# behavior 23: live beats every authored value, tested against three of them,
# so "regardless of the authored field" is actually exercised, not assumed.
for my $authored (qw(drafting audited archived)) {
    my $dir = bpdir();
    write_blueprint_md($dir, $authored);
    write_marker($dir, "$$\n");   # our own pid: genuinely alive
    my $probe = sub { 1 };
    my $got = eval { BpState::blueprint_lifecycle($dir, $probe) };
    is($got, 'running', "behavior23: live run + authored '$authored' -> running (live wins)");
}

# behavior 24 / precedence: not live, authored archived -> archived.
{
    my $dir = bpdir();
    write_blueprint_md($dir, 'archived');
    my $probe = sub { 0 };
    my $got = eval { BpState::blueprint_lifecycle($dir, $probe) };
    is($got, 'archived', 'behavior24: not live, authored archived -> archived');
}

# precedence, stated explicitly in §2.4: archived beats the delivered
# computation. All packages delivered AND authored archived -> still archived,
# never re-derived to done.
{
    my $dir = bpdir();
    write_blueprint_md($dir, 'archived');
    write_ledger($dir, 'a', 'status: done');
    write_ledger($dir, 'b', 'status: dropped');
    my $probe = sub { 0 };
    my $got = eval { BpState::blueprint_lifecycle($dir, $probe) };
    is($got, 'archived',
       'precedence: not live, authored archived, ALL packages delivered -> still archived, not re-derived to done');
}

# behavior 25: not live, authored audited, all delivered, >=1 package -> done.
{
    my $dir = bpdir();
    write_blueprint_md($dir, 'audited');
    write_ledger($dir, 'a', 'status: done');
    write_ledger($dir, 'b', 'status: dropped');
    my $probe = sub { 0 };
    my $got = eval { BpState::blueprint_lifecycle($dir, $probe) };
    is($got, 'done', 'behavior25: not live, authored audited, all delivered -> done');
}

# behavior 26: authored 'running' (stale, pre-s04) + all delivered -> done too.
{
    my $dir = bpdir();
    write_blueprint_md($dir, 'running');
    write_ledger($dir, 'a', 'status: done');
    my $probe = sub { 0 };
    my $got = eval { BpState::blueprint_lifecycle($dir, $probe) };
    is($got, 'done', 'behavior26: not live, authored running (stale), all delivered -> done (ADVANCEABLE gate accepts running too)');
}

# behavior 27: authored drafting + all delivered -> drafting, NEVER done. This
# is the case that most directly defeats an implementation that only checks
# "all delivered" without also gating on the authored value.
{
    my $dir = bpdir();
    write_blueprint_md($dir, 'drafting');
    write_ledger($dir, 'a', 'status: done');
    write_ledger($dir, 'b', 'status: dropped');
    my $probe = sub { 0 };
    my $got = eval { BpState::blueprint_lifecycle($dir, $probe) };
    is($got, 'drafting', 'behavior27: not live, authored drafting, all delivered -> drafting (ADVANCEABLE gate excludes drafting)');
}

# behavior 28: authored audited, one package still running -> audited (not done).
{
    my $dir = bpdir();
    write_blueprint_md($dir, 'audited');
    write_ledger($dir, 'a', 'status: done');
    write_ledger($dir, 'b', 'status: running');
    my $probe = sub { 0 };
    my $got = eval { BpState::blueprint_lifecycle($dir, $probe) };
    is($got, 'audited', 'behavior28: not live, authored audited, one package still running -> audited');
}

# behavior 29: zero packages, authored audited -> audited (all-delivered requires count > 0).
{
    my $dir = bpdir();
    write_blueprint_md($dir, 'audited');
    make_path("$dir/packages");   # exists, empty
    my $probe = sub { 0 };
    my $got = eval { BpState::blueprint_lifecycle($dir, $probe) };
    is($got, 'audited', 'behavior29: zero packages, authored audited -> audited, never done');
}

# behavior 30: all packages parked, authored audited -> audited (parked is not delivered).
{
    my $dir = bpdir();
    write_blueprint_md($dir, 'audited');
    write_ledger($dir, 'a', 'status: parked');
    write_ledger($dir, 'b', 'status: parked');
    my $probe = sub { 0 };
    my $got = eval { BpState::blueprint_lifecycle($dir, $probe) };
    is($got, 'audited', 'behavior30: all packages parked, authored audited -> audited, not done');
}

# behavior 31: blueprint.md missing entirely -> drafting.
{
    my $dir = bpdir();   # no blueprint.md at all
    my $probe = sub { 0 };
    my $got = eval { BpState::blueprint_lifecycle($dir, $probe) };
    is($got, 'drafting', 'behavior31: blueprint.md missing entirely -> drafting');
}

# behavior 32: blueprint.md present, unparsable (no fenced block / no status: line) -> drafting.
{
    my $dir = bpdir();
    write_file("$dir/blueprint.md", "# Test Blueprint\n\nNo fenced meta block anywhere in this file.\n");
    my $probe = sub { 0 };
    my $got = eval { BpState::blueprint_lifecycle($dir, $probe) };
    is($got, 'drafting', 'behavior32a: blueprint.md with no fenced block at all -> drafting');
}
{
    my $dir = bpdir();
    write_file("$dir/blueprint.md", "# Test Blueprint\n\n```\nblueprint: test\ncreated: 2026-01-01\n```\n");
    my $probe = sub { 0 };
    my $got = eval { BpState::blueprint_lifecycle($dir, $probe) };
    is($got, 'drafting', 'behavior32b: blueprint.md with a fenced block but no status: line -> drafting');
}

# ═════════════════════════════════════════════════════════════════════════
# §5 — nonexistent $bpdir entirely: every function still returns its
# documented well-typed default, none dies.
# ═════════════════════════════════════════════════════════════════════════
{
    my $root = tempdir(CLEANUP => 1);
    my $bogus = "$root/never-created-xyz";
    ok(!-e $bogus, 'sanity: the bogus $bpdir really does not exist');

    my ($s, $died1) = do { local $@; my $v = eval { BpState::package_status($bogus, 'anything') }; ($v, $@) };
    is($s, 'pending', 'edge: package_status on a nonexistent $bpdir -> pending');

    my $all = eval { BpState::all_package_statuses($bogus) };
    is_deeply($all, {}, 'edge: all_package_statuses on a nonexistent $bpdir -> {}');

    my $pid = eval { BpState::orchestrator_pid($bogus) };
    is($pid, undef, 'edge: orchestrator_pid on a nonexistent $bpdir -> undef');

    my $live = eval { BpState::run_is_live($bogus, sub { 1 }) };
    is($live, 0, 'edge: run_is_live on a nonexistent $bpdir -> 0');

    my $lc = eval { BpState::blueprint_lifecycle($bogus, sub { 1 }) };
    is($lc, 'drafting', 'edge: blueprint_lifecycle on a nonexistent $bpdir -> drafting');
}

# ═════════════════════════════════════════════════════════════════════════
# §3 behavior 33 / DC6 — no call under test writes ANYTHING under $bpdir.
# The mechanical statement of "this module is a reader". mtimes of every
# file under a fully-populated fixture are snapshotted before and after a
# battery of calls (covering all five functions, multiple $alive_fn
# outcomes, and repeated calls) and must be byte-identical, and the set of
# files present must not change either.
# ═════════════════════════════════════════════════════════════════════════
{
    my $dir = bpdir();
    write_ledger($dir, 'a', 'status: done');
    write_ledger($dir, 'b', 'status: running');
    write_ledger($dir, 'c', 'status: converging');
    write_file("$dir/packages/a.md.lock", 'transient lock junk');
    write_marker($dir, "$$\n");
    write_blueprint_md($dir, 'audited');

    my %before = mtime_snapshot($dir);
    ok(scalar(keys %before) >= 5, 'mtime fixture: sanity, at least 5 files exist before any call');

    eval { BpState::package_status($dir, 'a') };
    eval { BpState::package_status($dir, 'nonexistent') };
    eval { BpState::all_package_statuses($dir) };
    eval { BpState::orchestrator_pid($dir) };
    eval { BpState::run_is_live($dir, sub { 1 }) };
    eval { BpState::run_is_live($dir, sub { 0 }) };
    eval { BpState::run_is_live($dir, undef) };
    eval { BpState::blueprint_lifecycle($dir, sub { 1 }) };
    eval { BpState::blueprint_lifecycle($dir, sub { 0 }) };
    # call everything a second time -- a reconcile-on-read side effect
    # (bp-status.sh's landmine, spec §1.2 row bp-status.sh:40-48) would tend
    # to show up more readily on a repeat pass.
    eval { BpState::all_package_statuses($dir) };
    eval { BpState::blueprint_lifecycle($dir, sub { 0 }) };

    my %after = mtime_snapshot($dir);

    is_deeply([sort keys %after], [sort keys %before],
        'behavior33/DC6: the exact same set of files exists after every call (nothing created, nothing removed)');
    is_deeply(\%after, \%before,
        'behavior33/DC6: no file under $bpdir changed mtime as a result of any BpState call');
}

done_testing();
