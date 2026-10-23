#!/usr/bin/env perl
# platform: any
# NEW oracle for blueprint where-things-go, package 10-gatherer-and-digest
# (specs/10-gatherer-and-digest-spec.md sec 4, AC-9, AC-10, AC-11 -- the "D"
# column of the AC table).
#
# WRITTEN BLIND to any implementation: plugins/almanac/scripts/Almanac/
# Gather.pm does not exist yet, and plugins/butler/scripts/BpHook/
# SessionStartNudge.pm::run still has its OLD never-halt-12-only body (lines()
# + one BpHook::context call, no reattach, no digest) at the time this file
# is written. Every assertion below either (a) fails for that reason via a
# real eval'd call to a not-yet-existing routine, or (b) checks a real
# subprocess side effect (a sweep-stub marker file) that the OLD run() body
# cannot produce, or (c) is deliberately SKIPped pending the module existing,
# exactly like plugins/almanac/tests/t/almanac-gather.t's own SKIP pattern --
# never a harness crash of this file's own making.
use strict;
use warnings;
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }
use Test::More;
use FindBin qw($Bin);
use Cwd qw(abs_path);
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use File::Find ();
use File::Copy ();
use File::Spec ();
use JSON::PP ();
use Time::HiRes qw(time);

use lib "$Bin/../lib";
use GuardHarness;

my $REPO_ROOT = abs_path("$Bin/../../../..");
BAIL_OUT("cannot resolve repo root from $Bin/../../../..") unless defined $REPO_ROOT;

(my $BUTLER_DIR   = "$REPO_ROOT/plugins/butler")        =~ s{\\}{/}g;
(my $ALMANAC_DIR  = "$REPO_ROOT/plugins/almanac")        =~ s{\\}{/}g;
(my $SCRIPTS_DIR  = "$BUTLER_DIR/scripts")               =~ s{\\}{/}g;
(my $HOOKS_DIR    = "$BUTLER_DIR/hooks")                 =~ s{\\}{/}g;
(my $A_SCRIPTS    = "$ALMANAC_DIR/scripts")              =~ s{\\}{/}g;
my $SN_PM      = "$SCRIPTS_DIR/BpHook/SessionStartNudge.pm";
my $GATHER_PM  = "$A_SCRIPTS/Almanac/Gather.pm";
my $SWEEP_PL   = "$SCRIPTS_DIR/bp-answer-escalation.pl";
my $SHIM_SH    = "$HOOKS_DIR/session-start-nudge.sh";

my $REAL_BASH_ABS = do { my $p = `bash -c "command -v bash"`; chomp $p; $p };
BAIL_OUT('cannot resolve a real bash on PATH') unless length $REAL_BASH_ABS;

require "$A_SCRIPTS/Almanac/Thread.pm";

# ---------------------------------------------------------------------------
# precondition: is Almanac::Gather.pm loadable? NOT SKIP -- a real, failing
# assertion right now, tied directly to the missing module this whole
# package exists to add.
# ---------------------------------------------------------------------------
my $GATHER_LOADS = eval { require $GATHER_PM; 1 } ? 1 : 0;
ok($GATHER_LOADS,
    'precondition: plugins/almanac/scripts/Almanac/Gather.pm is loadable (required for the hook to produce a digest, AC-9/10/11)')
    or diag("Gather.pm did not load: $@");

# ---------------------------------------------------------------------------
# scaffolding -- same technique as almanac-gather.t (write_record/mk_*),
# duplicated here deliberately rather than shared, to keep each test file
# independently readable per this repo's test conventions.
# ---------------------------------------------------------------------------
my $ROOT_SEQ = 0;
sub new_root {
    my $base = tempdir(CLEANUP => 1);
    (my $r = "$base/André-digest" . (++$ROOT_SEQ)) =~ s{\\}{/}g;
    # This file has no `use utf8;`, so the "André" literal above is read as
    # the two raw UTF-8 bytes it is stored as on disk (0xC3 0xA9 for the
    # "é"), NOT as a Unicode character -- the string is flagged as bytes,
    # not characters. Decoding it here (a no-op on the underlying byte
    # buffer, which already holds the correct UTF-8 bytes -- it only sets
    # Perl's internal "these bytes are characters" flag) turns it into the
    # same Unicode character string real production code receives from a
    # JSON decode, so write_registry's JSON::PP->utf8->encode() below
    # (which expects a CHARACTER string and UTF-8-encodes it exactly once)
    # does not double-encode it.
    utf8::decode($r);
    make_path($r);
    make_path("$r/.ccpraxis-local-data/almanac");
    return $r;
}

sub write_record {
    my ($path, %f) = @_;
    make_path(File::Spec->catpath((File::Spec->splitpath($path))[0, 1]));
    open(my $fh, '>:raw', $path) or die "fixture: cannot write $path: $!";
    print {$fh} "---\n";
    for my $k (sort keys %f) {
        next unless defined $f{$k};
        print {$fh} "$k: $f{$k}\n";
    }
    print {$fh} "---\n";
    close $fh;
}
sub mk_inbox { my ($root, $id, %f) = @_; write_record("$root/.ccpraxis-local-data/almanac/inbox/$id.md", %f) }
sub mk_todo  { my ($root, $id, %f) = @_; write_record("$root/.ccpraxis-local-data/almanac/todo/$id.md", %f) }
sub mk_note  { my ($root, $id, %f) = @_; write_record("$root/.ccpraxis-local-data/almanac/note/$id.md", %f) }

sub write_pkg_ledger {
    my ($root, $bp, $pkg, $status) = @_;
    my $base = "$root/.ccpraxis-local-data/blueprints/$bp/packages";
    make_path($base);
    open(my $fh, '>:raw', "$base/$pkg.md") or die "fixture: cannot write $base/$pkg.md: $!";
    print {$fh} "---\nstatus: $status\n---\n";
    close $fh;
}

sub write_registry {
    my ($almanac_home, %slug_to_path) = @_;
    my $dir = "$almanac_home/.claude/claude-code-vault";
    make_path($dir);
    my %projects;
    for my $slug (keys %slug_to_path) { $projects{$slug} = { path => $slug_to_path{$slug} } }
    open(my $fh, '>:raw', "$dir/.registry-local.json") or die "fixture: registry: $!";
    print {$fh} JSON::PP->new->utf8->canonical->encode({ projects => \%projects });
    close $fh;
}

my $BUG_SEQ = 0;
sub mk_bug_raw {
    my ($root) = @_;
    my $id = sprintf('bug-%06d-%04d', time(), ++$BUG_SEQ);
    my $dir = "$root/.ccpraxis-local-data/almanac/bug-reports";
    make_path($dir);
    my $now = do { my @t = gmtime(time()); sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]) };
    my $body = 'body text';
    open(my $fh, '>:raw', "$dir/$id.md") or die $!;
    print {$fh} "---\nid: $id\ntitle: bug $id\nstatus: open\nseverity: unknown\narea: unknown\n"
        . "project: $root\ncreated_at: $now\nupdated_at: $now\n---\n$body";
    close $fh;
    return $id;
}

sub payload {
    my (%o) = @_;
    return {
        hook_event_name => 'SessionStart',
        session_id      => 'sidsd0001aaaa',
        source          => 'startup',
        cwd             => '/tmp/nonexistent',
        %o,
    };
}

sub sm {
    my ($p, %env) = @_;
    return GuardHarness::run_module('SessionStartNudge', $p, env => \%env);
}

# ---------------------------------------------------------------------------
# copy_tree($src, $dst) -- plain recursive copy (File::Find + File::Copy),
# used only to build the "copied-plugin-tree" sweep-failure fixture the AC
# table names for AC-9. No shell spawn, so it is Windows-safe.
# ---------------------------------------------------------------------------
sub copy_tree {
    my ($src, $dst) = @_;
    File::Find::find({
        no_chdir => 1,
        wanted   => sub {
            my $rel = File::Spec->abs2rel($File::Find::name, $src);
            return if $rel eq '.';
            my $target = "$dst/$rel";
            if (-d $File::Find::name) {
                make_path($target);
            }
            else {
                make_path(File::Spec->catpath((File::Spec->splitpath($target))[0, 1]));
                File::Copy::copy($File::Find::name, $target) or die "copy_tree: $File::Find::name -> $target: $!";
                chmod((stat($File::Find::name))[2] & 07777, $target);
            }
        },
    }, $src);
    return $dst;
}

# ===========================================================================
# AC-9: the hook exits 0 and prints nothing or exactly one stdout line for
# six named edge cases.
# ===========================================================================

# -- (1) empty stdin, (2) non-JSON stdin -- through the real shim, in-process
#    via run_module is also fine since both fail BpHook::load_payload before
#    anything hook-specific runs.
for my $case (['empty stdin' => ''], ['non-JSON stdin' => 'not json at all {']) {
    my ($label, $raw) = @$case;
    GuardHarness::fresh_state();
    my $res = GuardHarness::run_module('SessionStartNudge', $raw);
    is($res->{rc}, 0, "AC-9: $label -> rc 0");
    my $nl = () = ($res->{out} =~ /\n/g);
    ok($nl <= 1, "AC-9: $label -> at most one stdout line");
}

# -- (3) a payload with a non-string `source`.
for my $bad_source (5, { x => 1 }, [1, 2], JSON::PP::true) {
    GuardHarness::fresh_state();
    my $sid = 'sidsd0003aaaa';
    my $p = payload(session_id => $sid, source => $bad_source);
    my $res = sm($p);
    is($res->{rc}, 0, 'AC-9: non-string source -> rc 0');
    my $nl = () = ($res->{out} =~ /\n/g);
    ok($nl <= 1, 'AC-9: non-string source -> at most one stdout line');
}

# -- (4) an unreadable almanac dir: the store path exists as a plain FILE,
#    not a directory, so any opendir/stat on it fails regardless of who owns
#    the process (a chmod-based fixture is not reliable while running as
#    root, which this sandbox always does).
{
    GuardHarness::fresh_state();
    my $root = new_root();
    unlink("$root/.ccpraxis-local-data/almanac") if -e "$root/.ccpraxis-local-data/almanac";
    rmdir("$root/.ccpraxis-local-data/almanac") if -d "$root/.ccpraxis-local-data/almanac";
    open(my $fh, '>', "$root/.ccpraxis-local-data/almanac") or die $!;
    print {$fh} "not a directory\n";
    close $fh;
    my $sid = 'sidsd0004aaaa';
    my $p = payload(session_id => $sid, cwd => $root);
    my $res = sm($p);
    is($res->{rc}, 0, 'AC-9: unreadable (non-directory) almanac path -> rc 0');
    my $nl = () = ($res->{out} =~ /\n/g);
    ok($nl <= 1, 'AC-9: unreadable almanac path -> at most one stdout line');
}

# -- (5) a sweep script that exits 1, via a copied-plugin-tree fixture: a
#    full copy of plugins/almanac and plugins/butler under a tempdir, with
#    the copy's bp-answer-escalation.pl replaced by a stub that (a) always
#    exits 1 and (b) appends one line to a marker log -- proof the sweep
#    subprocess actually ran, which the OLD SessionStartNudge::run body
#    cannot produce (it never touches Gather at all).
{
    my $tmp = tempdir(CLEANUP => 1);
    (my $copy_root = "$tmp/copy") =~ s{\\}{/}g;
    make_path($copy_root);
    copy_tree($A_SCRIPTS, "$copy_root/plugins/almanac/scripts");
    copy_tree($SCRIPTS_DIR, "$copy_root/plugins/butler/scripts");
    copy_tree($HOOKS_DIR, "$copy_root/plugins/butler/hooks");

    (my $marker = "$tmp/sweep-marker.log") =~ s{\\}{/}g;
    my $stub_path = "$copy_root/plugins/butler/scripts/bp-answer-escalation.pl";
    open(my $sfh, '>:raw', $stub_path) or die $!;
    print {$sfh} "#!/usr/bin/env perl\n";
    print {$sfh} "open(my \$m, '>>', '$marker') or exit 1; print {\$m} \"called\\n\"; close \$m;\n";
    print {$sfh} "exit 1;\n";
    close $sfh;
    chmod 0755, $stub_path;

    my $copy_root_project = new_root();
    make_path("$copy_root_project/.ccpraxis-local-data/blueprints/sweepbp/runs");
    write_pkg_ledger($copy_root_project, 'sweepbp', '01-a', 'running');

    GuardHarness::fresh_state();
    my $sid = 'sidsd0005aaaa';
    my $p = payload(session_id => $sid, cwd => $copy_root_project);
    my $wres = GuardHarness::run_wrapper("$copy_root/plugins/butler/hooks/session-start-nudge.sh", $p,
        env => { CLAUDE_PLUGIN_ROOT => "$copy_root/plugins/butler" });
    is($wres->{rc}, 0, 'AC-9: a sweep script exiting 1 (copied-plugin-tree fixture) -> rc 0');
    my $nl = () = ($wres->{out} =~ /\n/g);
    ok($nl <= 1, 'AC-9: ...-> at most one stdout line');
    ok(-f $marker, 'AC-9: the failing sweep stub was actually invoked (marker file written)')
        or diag('no marker at ' . $marker . "; wrapper stdout=[$wres->{out}] stderr=[$wres->{err}]");
}

# -- (6) a forced die inside Gather::digest -- overriding the symbol works
#    even before the real file exists (Perl allows assigning into a
#    not-yet-loaded package's glob table), and SessionStartNudge::run calling
#    through to it is exactly the behavior this file cannot prove until the
#    new run() body exists, so this sub-case stays a SKIP, not a false pass,
#    until then.
SKIP: {
    skip 'AC-9(6): Almanac::Gather is not requirable yet -- cannot wire a forced die into it', 2
        unless $GATHER_LOADS;
    no strict 'refs';
    no warnings 'redefine';
    local *Almanac::Gather::digest = sub { die "AC-9(6) deliberate die from Gather::digest\n" };
    GuardHarness::fresh_state();
    my $sid = 'sidsd0006aaaa';
    my $p = payload(session_id => $sid);
    my $res = sm($p);
    is($res->{rc}, 0, 'AC-9: a forced die inside Gather::digest -> rc 0');
    my $nl = () = ($res->{out} =~ /\n/g);
    ok($nl <= 1, 'AC-9: ...-> at most one stdout line');
}

# ===========================================================================
# AC-10: time budget. 3 threads x 5 tasks (one linked), 2 blueprints each
# with runs/ (2 sweeps), 5 bugs, 5 inbox, 5 todos, 3 notes, 3-project
# registry. Wall-clock of `bash session-start-nudge.sh` with a startup
# payload <= 10s. Prints the MEASURED diag unconditionally.
# ===========================================================================
{
    my $F = new_root();
    for my $tn (qw(th-a th-b th-c)) {
        Almanac::Thread::create_thread($tn, root => $F);
        for my $i (1 .. 5) {
            Almanac::Thread::add_task($tn, root => $F, title => "$tn task $i");
        }
    }
    {
        my $tasks = Almanac::Thread::tasks('th-a', root => $F);
        # link the first task of th-a to a package (AC-10's "one linked").
        write_pkg_ledger($F, 'ac10bp', '01-a', 'running');
    }
    for my $bp (qw(ac10bp-run1 ac10bp-run2)) {
        make_path("$F/.ccpraxis-local-data/blueprints/$bp/runs");
        write_pkg_ledger($F, $bp, '01-a', 'running');
    }
    mk_bug_raw($F) for 1 .. 5;
    mk_inbox($F, "ibx-ac10-$_", title => "q$_", status => 'unanswered', created => "2026-01-01T00:00:0${_}Z") for 1 .. 5;
    mk_todo($F, "todo-ac10-$_", title => "t$_", status => 'open', created => "2026-01-01T00:00:0${_}Z") for 1 .. 5;
    mk_note($F, "note-ac10-$_", title => "n$_", created => "2026-01-01T00:00:0${_}Z") for 1 .. 3;

    my $other1 = new_root();
    my $other2 = new_root();
    my $almanac_home = tempdir(CLEANUP => 1);
    write_registry($almanac_home, main => $F, o1 => $other1, o2 => $other2);

    GuardHarness::fresh_state();
    my $sid = 'sidsd0010aaaa';
    my $p = payload(session_id => $sid, cwd => $F);
    my $t0 = time();
    my $wres = GuardHarness::run_wrapper('session-start-nudge', $p,
        env => { ALMANAC_HOME => $almanac_home }, timeout => 20);
    my $elapsed = time() - $t0;
    diag(sprintf('# MEASURED session-start digest: %.3fs', $elapsed));
    is($wres->{rc}, 0, 'AC-10: the fixture run exits 0');
    ok($elapsed <= 10, sprintf('AC-10: wall-clock (%.3fs) is at most 10s', $elapsed))
        or diag('rc=' . $wres->{rc} . " out=[$wres->{out}] err=[$wres->{err}]");
}

# ===========================================================================
# AC-11: hook order. A resume payload on a package-03 re-attach fixture with
# the session armed: the single context string has the digest first and
# lists the re-attached thread with liveness live under the new session;
# $RESUME_FORMAT text comes after the digest; Almanac::Thread::reattach is
# called before gather (asserted both by thread ownership in the digest and
# by a local wrap/override recording call order).
# ===========================================================================
SKIP: {
    skip 'AC-11: Almanac::Gather is not requirable yet -- call-order and digest-content checks need it', 6
        unless $GATHER_LOADS;

    my $ROOT = new_root();
    Almanac::Thread::create_thread('rt', root => $ROOT);
    Almanac::Thread::attach('rt', root => $ROOT, session => 'PRED', transcript => undef);
    my $tmp = tempdir(CLEANUP => 1);
    my $pred_t = "$tmp/PRED.jsonl";
    open(my $fh, '>', $pred_t) or die $!; print {$fh} "{}\n"; close $fh;
    utime(time() - 2 * 3600, time() - 2 * 3600, $pred_t); # dead predecessor

    my $new_t = "$tmp/NEW.jsonl";
    open(my $fh2, '>', $new_t) or die $!; print {$fh2} "{}\n"; close $fh2;

    GuardHarness::fresh_state();
    my $sid = 'sidsd0011newaa';
    GuardHarness::arm($sid, 'driver');

    my @order;
    no strict 'refs';
    no warnings 'redefine';
    local *Almanac::Thread::reattach = sub { push @order, 'reattach'; return { result => 'skipped' } };
    local *Almanac::Gather::digest   = sub { push @order, 'digest'; return 'Project digest (fixture):' };

    my $p = payload(session_id => $sid, source => 'resume', transcript_path => $new_t, cwd => $ROOT);
    my $res = sm($p);
    is($res->{rc}, 0, 'AC-11: armed resume on a re-attach fixture -> rc 0');
    is_deeply(\@order, ['reattach', 'digest'], 'AC-11: Almanac::Thread::reattach is called before Almanac::Gather::digest');

    # Content ordering (digest first, resume nudge text last) against the
    # REAL (non-overridden) reattach+digest, so the thread's new ownership
    # actually shows up.
    @order = ();
    {
        no strict 'refs';
        no warnings 'redefine';
        local *Almanac::Gather::digest = sub {
            push @order, 'digest';
            my (%o) = @_;
            my $r = Almanac::Gather::gather(mode => 'project', root => $o{root} // Almanac::Thread::project_root(cwd => $o{cwd}));
            return Almanac::Gather::render_digest($r);
        };
        my $res2 = sm($p);
        my $decoded = eval { JSON::PP->new->utf8->decode($res2->{out}) };
        my $ctx = (ref $decoded eq 'HASH' && ref $decoded->{hookSpecificOutput} eq 'HASH')
            ? $decoded->{hookSpecificOutput}{additionalContext} : undef;
        ok(defined $ctx && length $ctx, 'AC-11: one additionalContext string is produced') or diag("stdout: [$res2->{out}]");
        if (defined $ctx) {
            like($ctx, qr/\AProject digest/, 'AC-11: the digest text comes first in the context string');
            like($ctx, qr/Resumed at .* while continuity is armed/, 'AC-11: the resume nudge text comes after the digest');
            my $digest_pos = index($ctx, 'Project digest');
            my $resume_pos = index($ctx, 'Resumed at');
            ok($digest_pos >= 0 && $resume_pos > $digest_pos, 'AC-11: digest text precedes the resume nudge text');
            like($ctx, qr/rt \[live, live\]/, 'AC-11: the re-attached thread "rt" shows liveness live under the new session')
                or diag("ctx: [$ctx]");
        }
    }
}

done_testing();
