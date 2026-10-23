#!/usr/bin/env perl
# platform: any
# Oracle for blueprint where-things-go, package 11-sitrep-commands
# (specs/11-sitrep-commands-spec.md sec 4, AC17-AC27 -- the "PT" column of
# the AC table). Covers /pending's cross-project breakdown: pending_report(),
# the pending repo skill's SKILL.md, and the pending CLI's exit contract.
#
# WRITTEN BLIND to any implementation: AlmanacSitrep and the pending repo
# skill's SKILL.md DO NOT EXIST YET at the time this file is written. Every
# AC below is expected to fail red for that reason (a missing file/require),
# never for a harness crash or a fixture defect of this file's own making.
#
# Fixtures reuse plugins/almanac/tests/t/almanac-gather.t's helpers verbatim
# (write_record, mk_inbox, mk_todo, mk_note, write_pkg_ledger,
# write_blueprint_meta, mk_bug_raw, write_registry, new_root's non-ASCII
# decode convention), plus a global-scope record writer for the vault todo/
# note directories (new in this file: global records are not an
# almanac-gather.t fixture shape).
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use File::Spec ();
use Cwd ();
use JSON::PP ();
use Encode qw(decode);
use Digest::SHA qw(sha256_hex);

# ---------------------------------------------------------------------------
# isolation: fixtures only, never the real ~/.claude (blueprint Constraints).
# ---------------------------------------------------------------------------
my $FIX_HOME = tempdir(CLEANUP => 1);
$ENV{HOME}                  = $FIX_HOME;
$ENV{ALMANAC_HOME}          = $FIX_HOME;
$ENV{BUTLER_STATE_DIR}      = $FIX_HOME;
$ENV{CCPRAXIS_DATA_DIR}     = $FIX_HOME;
$ENV{CCPRAXIS_SPEND_NO_FETCH} = 1;
delete $ENV{CLAUDE_PROJECT_DIR};
delete $ENV{USERPROFILE};

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
use lib "$Bin/../../scripts";
(my $BUTLER_S = "$Bin/../../../butler/scripts") =~ s{\\}{/}g;

my $SITREP_PL = "$S/almanac-sitrep.pl";

require "$S/Almanac/Thread.pm";
require "$S/Almanac/PackageLink.pm";
require "$S/Almanac/Store.pm";
require "$S/Almanac/SessionLive.pm";
require "$BUTLER_S/BpState.pm";

my $A = "$S/almanac-bug.pl";
{
    local $@;
    do $A;
    diag("loading $A for fixtures failed: $@") if $@;
}

my $SITREP_LOADS = eval { require $SITREP_PL; 1 } ? 1 : 0;
diag("almanac-sitrep.pl load error: $@") unless $SITREP_LOADS;

# ---------------------------------------------------------------------------
# scaffolding -- copied from almanac-gather.t, plus a global-record writer.
# ---------------------------------------------------------------------------
my $ROOT_SEQ = 0;
sub new_root {
    my ($name) = @_;
    my $base = tempdir(CLEANUP => 1);
    (my $r = "$base/" . ($name // ('André-pending' . (++$ROOT_SEQ)))) =~ s{\\}{/}g;
    utf8::decode($r);
    make_path(_bytes_path($r));
    make_path(_bytes_path("$r/.ccpraxis-local-data/almanac"));
    return $r;
}

sub _bytes_path {
    my ($p) = @_;
    my $b = $p;
    utf8::encode($b) if utf8::is_utf8($b);
    return $b;
}

sub write_record {
    my ($path, %f) = @_;
    $path = _bytes_path($path);
    make_path(File::Spec->catpath((File::Spec->splitpath($path))[0,1]));
    open(my $fh, '>:raw', $path) or die "fixture: cannot write $path: $!";
    print {$fh} "---\n";
    for my $k (sort keys %f) {
        next unless defined $f{$k};
        print {$fh} "$k: $f{$k}\n";
    }
    print {$fh} "---\n";
    close $fh;
}

sub mk_inbox {
    my ($root, $id, %f) = @_;
    write_record("$root/.ccpraxis-local-data/almanac/inbox/$id.md", id => $id, %f);
}
sub mk_todo {
    my ($root, $id, %f) = @_;
    write_record("$root/.ccpraxis-local-data/almanac/todo/$id.md", id => $id, %f);
}
sub mk_note {
    my ($root, $id, %f) = @_;
    write_record("$root/.ccpraxis-local-data/almanac/note/$id.md", id => $id, %f);
}

# mk_global_todo/mk_global_note -- the vault-rooted global scope
# (Almanac::Store's global root: "<home>/.claude/claude-code-vault/almanac").
sub mk_global_todo {
    my ($home, $id, %f) = @_;
    write_record("$home/.claude/claude-code-vault/almanac/todo/$id.md", id => $id, %f);
}
sub mk_global_note {
    my ($home, $id, %f) = @_;
    write_record("$home/.claude/claude-code-vault/almanac/note/$id.md", id => $id, %f);
}

sub write_pkg_ledger {
    my ($root, $bp, $pkg, $status, %opt) = @_;
    my $base = $opt{archived}
        ? "$root/.ccpraxis-local-data/blueprints/_archive/$bp/packages"
        : "$root/.ccpraxis-local-data/blueprints/$bp/packages";
    $base = _bytes_path($base);
    make_path($base);
    open(my $fh, '>:raw', "$base/$pkg.md") or die "fixture: cannot write $base/$pkg.md: $!";
    print {$fh} "---\nstatus: $status\n---\n";
    close $fh;
}

sub write_blueprint_meta {
    my ($root, $bp, %f) = @_;
    my $base = _bytes_path("$root/.ccpraxis-local-data/blueprints/$bp");
    make_path($base);
    open(my $fh, '>:raw', "$base/blueprint.md") or die "fixture: cannot write $base/blueprint.md: $!";
    print {$fh} "---\n";
    print {$fh} "$_: $f{$_}\n" for sort keys %f;
    print {$fh} "---\n";
    close $fh;
}

my $BUG_SEQ = 0;
sub mk_bug_raw {
    my ($root, %o) = @_;
    my $id   = $o{id} // (AlmanacBug::new_id() . sprintf('-pt%02d', ++$BUG_SEQ));
    my $now  = AlmanacBug::_iso(time);
    my $body = $o{body} // 'body text';
    my $dir  = AlmanacBug::reports_dir($root);
    make_path(_bytes_path($dir)) unless -d _bytes_path($dir);
    my $path = "$dir/$id.md";
    my %f = (
        id => $id, title => ($o{title} // 'bug'), status => $o{status},
        severity => ($o{severity} // 'unknown'), area => 'unknown', project => $root,
        created_at => $now, updated_at => $now,
        ($o{no_freeze} ? () : (frozen_at => $now, content_sha256 => AlmanacBug::body_digest($body))),
        (defined $o{package}      ? (package      => $o{package})      : ()),
        (defined $o{package_root} ? (package_root  => $o{package_root}) : ()),
        (defined $o{fixed_at}     ? (fixed_at      => $o{fixed_at})     : ()),
    );
    my @order = qw(id title status severity area project created_at updated_at frozen_at
                   content_sha256 package package_root fixed_at);
    my $bpath = _bytes_path($path);
    open my $fh, '>:raw', $bpath or die "fixture: cannot write $bpath: $!";
    my $out = "---\n" . join("\n", map { defined $f{$_} ? "$_: $f{$_}" : () } @order) . "\n---\n$body";
    utf8::encode($out) if utf8::is_utf8($out);
    print {$fh} $out;
    close $fh;
    return ($path, $id);
}

sub write_registry {
    my ($almanac_home, %slug_to_path) = @_;
    my $dir = "$almanac_home/.claude/claude-code-vault";
    make_path($dir);
    my %projects;
    for my $slug (keys %slug_to_path) {
        $projects{$slug} = { path => $slug_to_path{$slug} };
    }
    open(my $fh, '>:raw', "$dir/.registry-local.json") or die "fixture: registry: $!";
    print {$fh} JSON::PP->new->utf8->canonical->encode({ projects => \%projects });
    close $fh;
}

sub decoded {
    my ($bytes) = @_;
    return defined $bytes ? decode('UTF-8', $bytes) : undef;
}

sub appear_in_order {
    my ($text, @needles) = @_;
    my $pos = -1;
    for my $n (@needles) {
        my $p = index($text, $n, $pos + 1);
        return 0 if $p < 0;
        $pos = $p;
    }
    return 1;
}

sub count_substr {
    my ($text, $needle) = @_;
    my $n = 0;
    my $pos = 0;
    while ((my $p = index($text, $needle, $pos)) >= 0) {
        $n++;
        $pos = $p + 1;
    }
    return $n;
}

# snapshot_tree($root) -- sha256 of every regular file under $root, excluding
# *.lock / *.lock.holder (AC24 explicitly excludes these).
sub snapshot_tree {
    my ($root) = @_;
    my %seen;
    my @stack = (_bytes_path($root));
    while (my $d = pop @stack) {
        opendir(my $dh, $d) or next;
        for my $e (readdir $dh) {
            next if $e eq '.' || $e eq '..';
            my $full = "$d/$e";
            if (-d $full) { push @stack, $full; next }
            next if $e =~ /\.lock\z/ || $e =~ /\.lock\.holder\z/;
            open(my $fh, '<:raw', $full) or next;
            local $/; my $c = <$fh>; close $fh;
            (my $rel = $full) =~ s{\\}{/}g;
            $seen{$rel} = sha256_hex($c // '');
        }
        closedir $dh;
    }
    return \%seen;
}

# ===========================================================================
# Fixture H -- spec sec 5.2's registry of three projects plus a global store.
# ===========================================================================
my $HOME_DIR = $FIX_HOME; # ALMANAC_HOME == HOME == $FIX_HOME, per the isolation block above.

my $P1 = new_root('André-p1');
mk_inbox($P1, 'p1-q1', title => 'ship the dashboard?', status => 'unanswered', created => '2026-01-01T00:00:00Z');
mk_inbox($P1, 'p1-q2', title => 'old', status => 'answered', created => '2026-01-01T00:00:01Z');

write_pkg_ledger($P1, 'bpA', '01-x', 'done');
write_pkg_ledger($P1, 'bpA', '02-y', 'pending');
write_pkg_ledger($P1, 'bpA', '03-z', 'blocked');
write_blueprint_meta($P1, 'bpA', status => 'running');

write_pkg_ledger($P1, 'bpDone', '01-a', 'done');
write_blueprint_meta($P1, 'bpDone', status => 'running');

write_pkg_ledger($P1, 'bpArch', '01', 'pending');
write_blueprint_meta($P1, 'bpArch', status => 'archived');

Almanac::Thread::create_thread('t-open', root => $P1);
Almanac::Thread::add_task('t-open', root => $P1, title => 'task open one');
Almanac::Thread::add_task('t-open', root => $P1, title => 'task done one');
{
    my $tasks = Almanac::Thread::tasks('t-open', root => $P1);
    my ($done_task) = grep { $_->{title} eq 'task done one' } @$tasks;
    Almanac::Thread::set_task_status('t-open', $done_task->{id}, 'done', root => $P1) if $done_task;
}

Almanac::Thread::create_thread('t-finished', root => $P1);
Almanac::Thread::add_task('t-finished', root => $P1, title => 'the only task');
{
    my $tasks = Almanac::Thread::tasks('t-finished', root => $P1);
    Almanac::Thread::set_task_status('t-finished', $tasks->[0]{id}, 'done', root => $P1);
}

mk_todo($P1, 'p1-todo', title => 'p1 todo title', status => 'open', created => '2026-01-01T00:00:00Z');
mk_todo($P1, 'p1-todo-done', title => 'p1 todo done title', status => 'done', created => '2026-01-01T00:00:01Z');
mk_note($P1, 'p1-note', title => 'p1 note title', created => '2026-01-01T00:00:00Z');

mk_bug_raw($P1, status => 'open', title => 'p1 open bug', severity => 'high');
mk_bug_raw($P1, status => 'scheduled', title => 'p1 scheduled bug');
mk_bug_raw($P1, status => 'fixed', title => 'p1 fixed bug', fixed_at => AlmanacBug::_iso(time));

my $P2 = new_root('André-p2');
mk_todo($P2, 'p2-todo', title => 'p2 todo title', status => 'open', created => '2026-01-01T00:00:00Z');
mk_bug_raw($P2, status => 'triaging', title => 'p2 triaging bug');
mk_bug_raw($P2, status => 'dropped', title => 'p2 dropped bug');

my $P3 = new_root('André-p3');
mk_note($P3, 'p3-note', title => 'p3 note title', created => '2026-01-01T00:00:00Z');
mk_todo($P3, 'p3-todo-done', title => 'p3 todo done title', status => 'done', created => '2026-01-01T00:00:00Z');

write_registry($HOME_DIR, p1 => $P1, p2 => $P2, p3 => $P3);

mk_global_todo($HOME_DIR, 'g-todo', title => 'global todo title', status => 'open', created => '2026-01-01T00:00:00Z');
mk_global_todo($HOME_DIR, 'g-todo-done', title => 'global todo done title', status => 'done', created => '2026-01-01T00:00:01Z');
mk_global_note($HOME_DIR, 'g-note', title => 'global note title', created => '2026-01-01T00:00:00Z');

my $P1_BASE = (split m{/}, $P1)[-1];
my $P2_BASE = (split m{/}, $P2)[-1];
my $P3_BASE = (split m{/}, $P3)[-1];

# ===========================================================================
# Case 1 (AC17-AC23): pending_report(surface => 'host').
# ===========================================================================
my $PENDING_TEXT;
SKIP: {
    skip 'AlmanacSitrep not loadable', 1 unless $SITREP_LOADS;
    my $bytes = eval { AlmanacSitrep::pending_report(surface => 'host', home => $HOME_DIR) };
    ok(defined $bytes, 'pending_report(surface=>host) returns defined bytes') or diag("err: $@");
    SKIP: {
        skip 'pending_report died', 30 unless defined $bytes;
        $PENDING_TEXT = decoded($bytes);
        my $text = $PENDING_TEXT;

        # --- Q1/Q2 structure --------------------------------------------------
        like($text, qr/^Pending across 3 registered projects  \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/m,
            'Q1: header is "Pending across 3 registered projects  <generated_at>"');
        ok(appear_in_order($text, '== Inbox ==', '== Blueprints ==', '== Threads ==',
            '== Todos ==', '== Open bugs ==', '== Clear =='),
            'Q2: the six counter-major section headers appear, in order');

        # --- AC17: Inbox --------------------------------------------------------
        ok(appear_in_order($text, '== Inbox ==', "$P1_BASE:", 'p1-q1  ship the dashboard?'),
            'AC17: P1\'s unanswered inbox item is listed under Inbox with its question text');
        unlike($text, qr/\bold\b/, 'AC17: the answered inbox item ("old") never appears');

        # --- AC18: Blueprints ----------------------------------------------------
        ok(appear_in_order($text, '== Blueprints ==', "$P1_BASE:", 'bpA  running  1/3'),
            'AC18: bpA listed as "bpA  running  1/3" under P1');
        like($text, qr/blocked: 03-z/, 'AC18: "blocked: 03-z" line present');
        like($text, qr/pending: 02-y/, 'AC18: "pending: 02-y" line present');
        unlike($text, qr/bpDone/, 'AC18: the fully-done blueprint bpDone is absent');
        unlike($text, qr/bpArch/, 'AC18: the archived blueprint bpArch is absent');

        # --- AC19: Threads ---------------------------------------------------------
        ok(appear_in_order($text, '== Threads ==', 't-open', 'task open one'),
            'AC19: t-open is listed with its open task "task open one"');
        unlike($text, qr/task done one/, 'AC19: a done task\'s title ("task done one") is absent');
        unlike($text, qr/t-finished/, 'AC19: a thread with no open tasks (t-finished) is absent');

        # --- AC20: Todos (host) -----------------------------------------------
        ok(appear_in_order($text, '== Todos ==', 'p1 todo title'), 'AC20: P1\'s open todo is listed');
        like($text, qr/p2 todo title/, 'AC20: P2\'s open todo is listed');
        is(count_substr($text, 'global todo title'), 1,
            'AC20: the global open todo\'s title appears exactly once, under global:');
        unlike($text, qr/p1 todo done title/, 'AC20: a done per-project todo is absent');
        unlike($text, qr/global todo done title/, 'AC20: a done global todo is absent');

        # --- AC21: Open bugs ----------------------------------------------------
        ok(appear_in_order($text, '== Open bugs ==', 'p1 open bug'), 'AC21: P1\'s open bug is listed');
        like($text, qr/\Qp1 open bug\E.*high|high.*\Qp1 open bug\E/, 'AC21: P1\'s open bug shows severity "high"')
            or diag(substr($text, index($text, '== Open bugs =='), 400));
        like($text, qr/p1 scheduled bug/, 'AC21: P1\'s scheduled bug is listed');
        like($text, qr/p2 triaging bug/, 'AC21: P2\'s triaging bug is listed');
        unlike($text, qr/p1 fixed bug/, 'AC21: a fixed bug is absent');
        unlike($text, qr/p2 dropped bug/, 'AC21: a dropped bug is absent');

        # --- AC22: Clear -----------------------------------------------------
        my $clear_block = substr($text, index($text, '== Clear =='));
        like($clear_block, qr/\Q$P3_BASE\E  clear -- nothing pending/,
            'AC22: P3 is named in Clear as "clear -- nothing pending"');
        unlike($clear_block, qr/\Q$P1_BASE\E/, 'AC22: P1 is not named in Clear');
        unlike($clear_block, qr/\Q$P2_BASE\E/, 'AC22: P2 is not named in Clear');

        # --- AC23: notes never listed -------------------------------------------
        unlike($text, qr/p1 note title/, 'AC23: P1\'s note title never appears');
        unlike($text, qr/p3 note title/, 'AC23: P3\'s note title never appears');
        unlike($text, qr/global note title/, 'AC23: the global note\'s title never appears');
    }
}

# ===========================================================================
# Case 2 (AC20 container): global todos degrade with surface => 'container'.
# ===========================================================================
SKIP: {
    skip 'AlmanacSitrep not loadable', 1 unless $SITREP_LOADS;
    my $bytes = eval { AlmanacSitrep::pending_report(surface => 'container', home => $HOME_DIR) };
    ok(defined $bytes, 'pending_report(surface=>container) returns defined bytes') or diag("err: $@");
    SKIP: {
        skip 'pending_report died', 1 unless defined $bytes;
        my $text = decoded($bytes);
        like($text, qr/global: unavailable here \(vault_not_mounted\)/,
            'AC20: surface=>container gives "global: unavailable here (vault_not_mounted)"');
    }
}

# ===========================================================================
# Case 3 (AC24): pending_report never mutates any project's or H's files.
# ===========================================================================
{
    my $before = { P1 => snapshot_tree($P1), P2 => snapshot_tree($P2), P3 => snapshot_tree($P3),
                   H => snapshot_tree($HOME_DIR) };
    SKIP: {
        skip 'AlmanacSitrep not loadable', 1 unless $SITREP_LOADS;
        eval { AlmanacSitrep::pending_report(surface => 'host', home => $HOME_DIR) };
    }
    my $after = { P1 => snapshot_tree($P1), P2 => snapshot_tree($P2), P3 => snapshot_tree($P3),
                  H => snapshot_tree($HOME_DIR) };
    SKIP: {
        skip 'AlmanacSitrep not loadable', 4 unless $SITREP_LOADS;
        is_deeply($after->{P1}, $before->{P1}, 'AC24: P1\'s file tree is byte-identical before/after pending_report');
        is_deeply($after->{P2}, $before->{P2}, 'AC24: P2\'s file tree is byte-identical before/after pending_report');
        is_deeply($after->{P3}, $before->{P3}, 'AC24: P3\'s file tree is byte-identical before/after pending_report');
        is_deeply($after->{H},  $before->{H},  'AC24: H\'s (global store + registry) file tree is byte-identical before/after pending_report');
    }
}

# ===========================================================================
# Case 4 (AC25/AC26): skills/pending/SKILL.md frontmatter + pinned D1 line.
# ===========================================================================
{
    my $skill_path = "$Bin/../../../../skills/pending/SKILL.md";
    ok(-f $skill_path, 'AC25/AC26 precondition: skills/pending/SKILL.md exists')
        or diag('not written yet');
    SKIP: {
        skip 'skills/pending/SKILL.md does not exist yet', 4 unless -f $skill_path;
        open(my $fh, '<:raw', $skill_path) or die;
        local $/;
        my $raw = <$fh>;
        close $fh;
        my $content = decode('UTF-8', $raw);
        my ($fm) = $content =~ /\A---\n(.*?)\n---\n/s;
        ok(defined $fm, 'AC25: SKILL.md has a frontmatter block') or diag($content);
        SKIP: {
            skip 'no frontmatter block', 2 unless defined $fm;
            like($fm, qr/^name:\s*pending\s*$/m, 'AC25: frontmatter has "name: pending"');
            like($fm, qr/^description:\s*\S.+$/m, 'AC25: frontmatter has a non-empty description:');
        }
        my $pinned = q{perl "$(dirname "$(command -v almanac)")/../scripts/almanac-sitrep.pl" pending};
        like($content, qr/```bash\n\Q$pinned\E\n```/, 'AC26: body contains the pinned D1 line inside a ```bash fence');
    }

    my $almanac_bin_dir = "$Bin/../../bin";
    my $path_with_bin = "$almanac_bin_dir:$ENV{PATH}";
    # Through the environment, not interpolated into the command line: a PATH
    # holding a space (C:/Program Files/...) split the assignment, so the probe
    # ran `Files/...` as a command and never found the shim.
    my $found = do { local $ENV{PATH} = $path_with_bin; `bash -c 'command -v almanac'` };
    chomp $found;
    ok(length $found, 'AC26 precondition: "command -v almanac" resolves with PATH prefixed by plugins/almanac/bin');
    SKIP: {
        skip 'almanac shim not found on PATH', 1 unless length $found;
        my $resolved = $found;
        $resolved =~ s{/[^/]+\z}{};
        my $script = "$resolved/../scripts/almanac-sitrep.pl";
        ok(-f $script, 'AC26: dirname(command -v almanac)/../scripts/almanac-sitrep.pl is a file');
    }
}

# ===========================================================================
# Case 5 (AC27): pending CLI exits 0, stdout starts with "Pending across".
# ===========================================================================
{
    ok(-f $SITREP_PL, 'AC27 precondition: almanac-sitrep.pl exists') or diag('not written yet');
    SKIP: {
        skip 'almanac-sitrep.pl does not exist yet', 2 unless -f $SITREP_PL;
        my (undef, $out) = tempfile();
        my (undef, $err) = tempfile();
        my @cmd = ($^X, $SITREP_PL, 'pending');
        my $inner = join(' ', map { qq("$_") } @cmd) . qq( < /dev/null > "$out" 2> "$err");
        {
            local $ENV{HOME} = $HOME_DIR;
            local $ENV{ALMANAC_HOME} = $HOME_DIR;
            system('bash', '-c', $inner);
        }
        my $rc = ($? == -1) ? -1 : ($? >> 8);
        is($rc, 0, 'AC27: "almanac-sitrep.pl pending" (subprocess, HOME at the fixture home) exits 0');
        open(my $ofh, '<:raw', $out) or die;
        local $/; my $stdout = <$ofh>; close $ofh;
        like(decoded($stdout // ''), qr/\APending across/, 'AC27: stdout starts with "Pending across"');
    }
}

done_testing();
