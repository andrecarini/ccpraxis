#!/usr/bin/env perl
# platform: any
# MountSpec-side oracle for the global-counts read-only mount (blueprint
# almanac-records, package 19-global-counts-snapshot). See
# .ccpraxis-local-data/blueprints/almanac-records/specs/19-global-counts-
# snapshot-spec.md sections 2.5, 3, 4 (AC14-AC22).
#
# AC14-AC19 are pure MountSpec structural checks and always run. AC20-AC21
# need a REAL container and are wrapped in a single SKIP: block, following
# plugins/sandbox/tests/t/test-harness-orphan-reaping.t's convention of
# detecting the container CLI BEFORE `require TestSandbox` -- TestSandbox.pm
# dies (not skips) at load with no CLI on PATH, so probing for a CLI first
# and gating the require behind that is what turns a hard die into a clean
# `# SKIP` for the rest of this suite (AC22). This file never spawns
# launcher.pl (checked by the final self-scan below) and never runs the
# rest of the suite's assertions only if the whole-file plan would have to
# be skip_all -- since AC14-AC19 have nothing to do with a container, a
# whole-file skip_all (which is a hard exit) is the wrong tool here; a
# lexically-scoped SKIP: block is.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use lib "$Bin/../lib";
use Test::More;
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use JSON::PP ();
use MountSpec qw(winify_path v_to_mount convert_v_to_mount
    claude_home_create_args parse_create_args audit_claude_home);

my $ISO_RE = qr/^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$/;

# ---------------------------------------------------------------------------
# scaffolding
# ---------------------------------------------------------------------------
sub mkdir_p { my ($d) = @_; make_path($d) unless -d $d; return; }

sub slurp_raw {
    my ($p) = @_;
    return undef unless defined $p && -f $p;
    open my $fh, '<:raw', $p or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

sub slurp_text {
    my ($p) = @_;
    return undef unless defined $p && -f $p;
    open my $fh, '<', $p or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

sub write_raw {
    my ($p, $bytes) = @_;
    open my $fh, '>:raw', $p or die "fixture: cannot write $p: $!";
    print {$fh} (defined $bytes ? $bytes : '');
    close $fh;
    return;
}

# capture_stderr($coderef) -> (\@return_values, $eval_error, $stderr_text)
#
# Redirects STDERR to a REAL File::Temp file for the duration of the call --
# never to an in-memory scalar filehandle, which fails on this host with
# "Bad file descriptor" (CLAUDE.md-documented landmine).
sub capture_stderr {
    my ($code) = @_;
    my (undef, $tmp) = tempfile();
    open(my $save_err, '>&', \*STDERR) or die "fixture: cannot dup STDERR: $!";
    open(STDERR, '>', $tmp) or die "fixture: cannot redirect STDERR: $!";
    my @ret = eval { $code->() };
    my $died = $@;
    open(STDERR, '>&', $save_err) or die "fixture: cannot restore STDERR: $!";
    close $save_err;
    my $captured = slurp_text($tmp);
    unlink $tmp;
    return (\@ret, $died, defined($captured) ? $captured : '');
}

my $claude_data  = tempdir(CLEANUP => 1);
$claude_data =~ s{\\}{/}g;
my $launcher_dir = "$claude_data/.launcher";
mkdir_p($launcher_dir);
my (undef, $statusline) = tempfile(SUFFIX => '.pl');
write_raw($statusline, "#!/usr/bin/env perl\n1;\n");

my @expected_base = (
    '-e', 'CLAUDE_CONFIG_DIR=/root/.claude',
    '-v', "$claude_data:/root/.claude",
    '-v', "$launcher_dir:/root/.claude/.launcher:ro",
    '-v', "$statusline:/root/.claude/statusline.pl:ro",
);

# ---------------------------------------------------------------------------
# AC14 (DC-d, no regression): absent global_counts is byte-identical to
# today; an empty-string global_counts dies naming the option.
# ---------------------------------------------------------------------------
{
    my @base = eval { MountSpec::claude_home_create_args(
        claude_data => $claude_data, launcher_dir => $launcher_dir, statusline => $statusline) };
    is_deeply(\@base, \@expected_base,
        'AC14: without global_counts, output equals the current 8-element list exactly')
        or diag("error: " . ($@ // '(none)'));

    eval { MountSpec::claude_home_create_args(
        claude_data => $claude_data, launcher_dir => $launcher_dir, statusline => $statusline,
        global_counts => '') };
    like($@ // '', qr/global_counts/, 'AC14: global_counts=>"" dies with a message naming global_counts');
}

# ---------------------------------------------------------------------------
# AC15 (DC-c, DC-d): global_counts=>P, P absent, parent exists -- seeded and
# appended as the last pair.
# ---------------------------------------------------------------------------
my $gc_path = "$claude_data/almanac-global-counts.json";
{
    ok(!-e $gc_path, 'AC15 setup: P does not exist before the call');

    my @withgc = eval { MountSpec::claude_home_create_args(
        claude_data => $claude_data, launcher_dir => $launcher_dir, statusline => $statusline,
        global_counts => $gc_path) };

    if (@withgc >= 2) {
        my @tail = @withgc[-2, -1];
        is_deeply(\@tail, ['-v', "$gc_path:/root/.claude/almanac-global-counts.json:ro"],
            'AC15: the last two elements are the global_counts ro bind pair');
        my @preceding = @withgc[0 .. $#withgc - 2];
        is_deeply(\@preceding, \@expected_base,
            'AC15: the preceding elements equal AC14\'s 8-element base list');
    } else {
        fail("AC15: $_") for 1 .. 2;
        diag("claude_home_create_args error: " . ($@ // '(none)') . "; got: " . scalar(@withgc) . " elements");
    }

    ok(-f $gc_path, 'AC15: P now exists as a plain file') or diag("no such file: $gc_path");

    my $bytes = slurp_raw($gc_path);
    if (defined $bytes) {
        like($bytes, qr/\n\z/, 'AC15: P ends in a trailing newline');
        my $body_only = substr($bytes, 0, length($bytes) - 1);
        unlike($body_only, qr/\n\z/, 'AC15: exactly one trailing newline, not two');

        my $decoded = eval { JSON::PP->new->decode($bytes) };
        if (ref($decoded) eq 'HASH') {
            is_deeply([ sort keys %$decoded ], [ sort qw(generated_at note schema todo) ],
                'AC15: P decodes to exactly the section-2.2 key set');
            is($decoded->{schema}, 1, 'AC15: P\'s schema is 1');
            like($decoded->{generated_at} // '', $ISO_RE, 'AC15: P\'s generated_at matches the ISO pattern');
            is_deeply($decoded->{note}, { total => 0 }, 'AC15: P\'s note block is the zero seed');
            is_deeply($decoded->{todo}, { done => 0, open => 0, total => 0 }, 'AC15: P\'s todo block is the zero seed');
        } else {
            fail('AC15: P decodes to exactly the section-2.2 key set');
            fail('AC15: P\'s schema is 1');
            fail('AC15: P\'s generated_at matches the ISO pattern');
            fail('AC15: P\'s note block is the zero seed');
            fail('AC15: P\'s todo block is the zero seed');
            diag("decode error: " . ($@ // '(none)'));
        }
    } else {
        fail("AC15: $_") for 1 .. 6;
    }
}

# ---------------------------------------------------------------------------
# AC16 (DC-d): through convert_v_to_mount -> parse_create_args, the new
# mount is type=bind, readonly, targets the fixed container path, and
# audit_claude_home reports zero violations. On Windows the source is drive
# form.
#
# The drive-form sub-check needs a global_counts PATH that is ALREADY a
# genuine Windows drive-letter path (winify_path is a documented no-op on
# one -- MountSpec.pm's own winify_path only rewrites a bare single-letter
# POSIX "/c/..." form to "C:/...", and passes an already-"C:/..." string
# through unchanged). This used to anchor under $ENV{HOME} on the theory
# that Git-for-Windows always sets HOME to a /c/... path -- but
# scripts/run-tests.pl's per-file sandbox (package 21-test-sandbox,
# Decision 120(c)/package 36) deliberately anchors the sandboxed HOME at a
# SHORT path under MSYS's own internal /tmp (its own header: "the shorter
# MSYS /tmp alias _short_tmp_base() prefers for HOME"), which is not a
# drive mount at all -- exactly the "winify_path is then a correct no-op"
# failure this comment used to warn about, now actually hit. TEMP/TMP,
# unlike HOME, are DELIBERATELY kept as a genuine Windows drive-letter path
# by that same sandbox (its own header: "a file in this suite needs
# $ENV{TEMP} itself to stay a genuine Windows drive-letter path"), so this
# fixture anchors there instead -- independent of HOME, and correct both
# under the runner's sandbox and a bare `perl this.t` run.
my $native_temp_ac16 = $ENV{TEMP} // $ENV{TMP};
my $ac16_base = (defined $native_temp_ac16 && length $native_temp_ac16)
    ? tempdir(DIR => $native_temp_ac16, CLEANUP => 1)
    : tempdir(CLEANUP => 1);
$ac16_base =~ s{\\}{/}g;
my $gc_path_ac16 = "$ac16_base/almanac-global-counts.json";
{
    my @withgc = eval { MountSpec::claude_home_create_args(
        claude_data => $claude_data, launcher_dir => $launcher_dir, statusline => $statusline,
        global_counts => $gc_path_ac16) };
    my @converted = eval { convert_v_to_mount(@withgc) };
    my $parsed = eval { MountSpec::parse_create_args(\@converted) };

    if (ref($parsed) eq 'HASH') {
        my ($m) = grep { defined($_->{target}) && $_->{target} eq '/root/.claude/almanac-global-counts.json' }
                       @{ $parsed->{mounts} || [] };
        ok($m, 'AC16: a parsed mount targets /root/.claude/almanac-global-counts.json') or diag(explain($parsed));
        if ($m) {
            is($m->{type}, 'bind', 'AC16: that mount is type bind');
            is($m->{readonly}, 1, 'AC16: that mount is readonly');
            if ($MountSpec::WINDOWS_FAMILY) {
                like($m->{source} // '', qr{^[A-Za-z]:/}, 'AC16: on Windows the source is in drive form (X:/...)');
            }
        } else {
            fail('AC16: that mount is type bind');
            fail('AC16: that mount is readonly');
        }
        my @viol = eval { MountSpec::audit_claude_home($parsed) };
        is(scalar(@viol), 0, 'AC16: audit_claude_home returns zero violations') or diag(explain(\@viol));
    } else {
        fail("AC16: $_") for 1 .. 3;
        diag("pipeline error: " . ($@ // '(none)'));
    }
}

# ---------------------------------------------------------------------------
# AC17 (DC-c): pre-existing P with custom bytes is untouched, pair still
# emitted.
# ---------------------------------------------------------------------------
{
    my $gc_existing = "$claude_data/pre-existing-global-counts.json";
    write_raw($gc_existing, "custom bytes, not a valid snapshot at all\n");
    my $before = slurp_raw($gc_existing);

    my @args = eval { MountSpec::claude_home_create_args(
        claude_data => $claude_data, launcher_dir => $launcher_dir, statusline => $statusline,
        global_counts => $gc_existing) };

    if (@args >= 2) {
        my @tail = @args[-2, -1];
        is_deeply(\@tail, ['-v', "$gc_existing:/root/.claude/almanac-global-counts.json:ro"],
            'AC17: the pair is still emitted for a pre-existing P');
    } else {
        fail('AC17: the pair is still emitted for a pre-existing P');
        diag("error: " . ($@ // '(none)'));
    }
    is(slurp_raw($gc_existing), $before, 'AC17: the pre-existing P\'s bytes are identical after the call');
}

# ---------------------------------------------------------------------------
# AC18 (DC-c, DC-g): P is a directory, or contains a claude-code-vault
# segment -- pair omitted, exactly one STDERR line, no die, nothing created
# for vault_path.
# ---------------------------------------------------------------------------
{
    my $dir_p = "$claude_data/global-counts-is-a-dir";
    mkdir_p($dir_p);

    my ($ret, $died, $stderr) = capture_stderr(sub {
        return MountSpec::claude_home_create_args(
            claude_data => $claude_data, launcher_dir => $launcher_dir, statusline => $statusline,
            global_counts => $dir_p);
    });
    ok(!length($died), 'AC18 (directory): claude_home_create_args does not die') or diag($died);
    is_deeply($ret, [ \@expected_base ]->[0], 'AC18 (directory): the pair is omitted (output equals the base block)')
        if !length($died);
    fail('AC18 (directory): the pair is omitted (output equals the base block)') if length($died);
    my @lines = grep { length } split /\n/, $stderr;
    is(scalar(@lines), 1, 'AC18 (directory): exactly one STDERR line') or diag($stderr);
    like($stderr, qr/^MountSpec: global counts snapshot not mounted \(not_a_file\): \Q$dir_p\E$/m,
        'AC18 (directory): that line names not_a_file and the path');

    my $vault_p = "$claude_data/claude-code-vault/almanac-global-counts.json";
    ok(!-e $vault_p, 'AC18 (vault_path) setup: P does not exist before the call');

    my ($ret2, $died2, $stderr2) = capture_stderr(sub {
        return MountSpec::claude_home_create_args(
            claude_data => $claude_data, launcher_dir => $launcher_dir, statusline => $statusline,
            global_counts => $vault_p);
    });
    ok(!length($died2), 'AC18 (vault_path): claude_home_create_args does not die') or diag($died2);
    is_deeply($ret2, [ \@expected_base ]->[0], 'AC18 (vault_path): the pair is omitted')
        if !length($died2);
    fail('AC18 (vault_path): the pair is omitted') if length($died2);
    my @lines2 = grep { length } split /\n/, $stderr2;
    is(scalar(@lines2), 1, 'AC18 (vault_path): exactly one STDERR line') or diag($stderr2);
    like($stderr2, qr/^MountSpec: global counts snapshot not mounted \(vault_path\): \Q$vault_p\E$/m,
        'AC18 (vault_path): that line names vault_path and the path');
    ok(!-e $vault_p, 'AC18 (vault_path): nothing is created on disk');
}

# ---------------------------------------------------------------------------
# COPY (podman-machine narrowing, 2026-10-30). On macOS the podman machine
# shares no part of ~/.claude, so the launcher passes global_counts_copy_dir
# (PodmanMachine::container_files_dir, a read-only machine share) and the
# container binds a COPY from there. The snapshot's own path, writer and lock
# files stay in ~/.claude, untouched. undef = every other host: bound in place.
# ---------------------------------------------------------------------------
{
    my $home  = tempdir(CLEANUP => 1);
    my $src   = "$home/claude/almanac-global-counts.json";
    my $share = "$home/cache/ccpraxis/container-files";
    mkdir_p("$home/claude");
    my $bytes = qq({"generated_at":"2030-01-01T00:00:00Z","note":{"total":3},"schema":1,"todo":{"done":1,"open":2,"total":3}}\n);
    write_raw($src, $bytes);
    write_raw("$src.lock", '');
    my @src_stat = stat($src);

    my @args = eval { MountSpec::claude_home_create_args(
        claude_data => $claude_data, launcher_dir => $launcher_dir, statusline => $statusline,
        global_counts => $src, global_counts_copy_dir => $share) };
    is_deeply([ @args[-2, -1] ], ['-v', "$share/almanac-global-counts.json:/root/.claude/almanac-global-counts.json:ro"],
        'COPY: with global_counts_copy_dir, the read-only bind is of the copy in that folder')
        or diag("error: " . ($@ // '(none)'));
    ok(-d $share, 'COPY: the copy folder is created when missing');
    is(slurp_raw("$share/almanac-global-counts.json"), $bytes, 'COPY: the copy holds the snapshot\'s bytes');
    is(slurp_raw($src), $bytes, 'COPY: the snapshot itself is unchanged');
    is((stat($src))[1], $src_stat[1], 'COPY: ...and is the same file (same inode: nothing renamed over it)');
    opendir(my $dh, $share) or die;
    my @in_share = sort grep { !/^\.\.?\z/ } readdir $dh;
    closedir $dh;
    is_deeply(\@in_share, ['almanac-global-counts.json'],
        'COPY: the share folder holds only the copy (no lock file, no leftover temp file)');

    # A second create, or the launcher's refresh before a container start,
    # replaces the copy whole (rename), so a reader never sees half a file.
    my $ino1 = (stat("$share/almanac-global-counts.json"))[1];
    (my $bytes2 = $bytes) =~ s/"total":3\}/"total":4}/;
    write_raw($src, $bytes2);
    my ($ok, $reason, $copy) = MountSpec::stage_global_counts_copy($src, $share);
    ok($ok, 'COPY: stage_global_counts_copy refreshes an existing copy') or diag($reason);
    is($copy, "$share/almanac-global-counts.json", 'COPY: ...returning the copy\'s path');
    is(slurp_raw($copy), $bytes2, 'COPY: ...with the new bytes');
    isnt((stat($copy))[1], $ino1, 'COPY: ...as a new file renamed into place, not a rewrite in place');

    my @direct = eval { MountSpec::claude_home_create_args(
        claude_data => $claude_data, launcher_dir => $launcher_dir, statusline => $statusline,
        global_counts => $src, global_counts_copy_dir => undef) };
    is_deeply([ @direct[-2, -1] ], ['-v', "$src:/root/.claude/almanac-global-counts.json:ro"],
        'COPY: global_counts_copy_dir => undef (Windows, Linux) binds the snapshot in place, as before');
    eval { MountSpec::claude_home_create_args(
        claude_data => $claude_data, launcher_dir => $launcher_dir, statusline => $statusline,
        global_counts => $src, global_counts_copy_dir => '') };
    like($@ // '', qr/global_counts_copy_dir/, 'COPY: an empty copy dir dies naming the option');

    my ($vok, $vreason) = MountSpec::stage_global_counts_copy($src, "$home/claude-code-vault/x");
    ok(!$vok && $vreason eq 'vault_path', 'COPY: a copy folder under a claude-code-vault segment is refused');
    ok(!-e "$home/claude-code-vault", 'COPY: ...and nothing is created there');
    write_raw($src, 'x' x 70000);
    my ($bok, $breason) = MountSpec::stage_global_counts_copy($src, $share);
    ok(!$bok && $breason eq 'too_large', 'COPY: a source far over the snapshot budget is not copied');
    is(slurp_raw($copy), $bytes2, 'COPY: ...and the previous copy is left as it was');

    # A failed copy falls back to NO bind (the container shows no counters),
    # never to binding ~/.claude, which the machine does not share.
    my ($r, $died, $stderr) = capture_stderr(sub { MountSpec::claude_home_create_args(
        claude_data => $claude_data, launcher_dir => $launcher_dir, statusline => $statusline,
        global_counts => $src, global_counts_copy_dir => $share) });
    is(scalar(@$r), scalar(@expected_base), 'COPY: when the copy fails, the global-counts pair is omitted')
        or diag(explain($r));
    like($stderr, qr/global counts snapshot not mounted \(too_large\)/, 'COPY: ...and the reason is logged');
}

# ---------------------------------------------------------------------------
# AC19 (DC-d, DC-g): launcher.pl's single call site, by source text. The
# launcher is never executed.
# ---------------------------------------------------------------------------
{
    my $launcher_src = slurp_text("$Bin/../../scripts/launcher.pl");
    ok(defined $launcher_src, 'AC19 setup: launcher.pl is readable') or BAIL_OUT('launcher.pl missing');

    like($launcher_src, qr/global_counts\s*=>\s*"\$\{CLAUDE_HOST_CONFIG\}\/almanac-global-counts\.json"/,
        'AC19: launcher.pl passes global_counts => "${CLAUDE_HOST_CONFIG}/almanac-global-counts.json"');

    like($launcher_src, qr/my \$CONTAINER_FILES_DIR = PodmanMachine::container_files_dir\(\);/,
        'COPY: launcher.pl takes the copy folder from PodmanMachine::container_files_dir (undef off macOS)');
    like($launcher_src, qr/MountSpec::stage_global_counts_copy\(\$src, \$CONTAINER_FILES_DIR\)/,
        'COPY: launcher.pl refreshes the copy (before the container start), with the same helper');
    if ($launcher_src =~ /(MountSpec::claude_home_create_args\s*\([^;]*?\)\s*;)/s) {
        my $call = $1;
        like($call, qr/global_counts_copy_dir\s*=>\s*\$CONTAINER_FILES_DIR/,
            'COPY: the create call passes global_counts_copy_dir => $CONTAINER_FILES_DIR');
        unlike($call, qr/claude-code-vault/, 'AC19: the literal claude-code-vault does not occur in that call');
    } else {
        fail('AC19: located the claude_home_create_args call site to check for claude-code-vault');
    }
}

# ---------------------------------------------------------------------------
# AC20/AC21 (DC-e, B11 freshness). REAL container. Skipped cleanly (never
# passed as a false green) when no container CLI is on PATH OR is on PATH
# but not REACHABLE (AC22's exact wording) -- e.g. podman.exe present but
# its machine/daemon stopped, which fails `<cli> info` fast (connection
# refused) while `<cli> --version` alone still reports success (it only
# inspects the binary, never dials the daemon). Both checks run BEFORE
# `require TestSandbox` so its die-at-load-with-no-CLI never fires here,
# and the reachability probe is bounded (`timeout 10 ...`) so a wedged
# daemon cannot hang this file instead of skipping it.
# ---------------------------------------------------------------------------
my ($HAVE_CLI, $CLI_UNAVAILABLE_REASON);
{
    my $cli_bin;
    for my $c ($^O =~ /^(MSWin32|cygwin|msys)$/ ? ('docker.exe', 'podman.exe') : ('docker', 'podman')) {
        if (system("$c --version > /dev/null 2>&1") == 0) { $cli_bin = $c; last }
    }
    if (!defined $cli_bin) {
        $CLI_UNAVAILABLE_REASON = 'no container CLI on PATH (docker/podman)';
    } else {
        my $rc = system("timeout 10 $cli_bin info > /dev/null 2>&1");
        if ($rc == 0) {
            $HAVE_CLI = 1;
        } else {
            $CLI_UNAVAILABLE_REASON = "$cli_bin is on PATH but not reachable "
                . "('$cli_bin info' failed or timed out, rc=" . ($rc >> 8) . ") -- "
                . "e.g. the machine/daemon is stopped";
        }
    }
}

SKIP: {
    skip("$CLI_UNAVAILABLE_REASON -- AC20/AC21 need a real, reachable container runtime "
       . "(TestSandbox.pm dies at load without one)", 9)
        unless $HAVE_CLI;

    require TestSandbox;
    TestSandbox->import(qw(podman_run_capture create_probe_container new_temp_dir probe_image));

    # A fresh, container-scoped set of paths (TestSandbox's own scratch-root
    # convention), independent of the host-only paths used by AC14-AC19
    # above.
    my $claude_data_c  = TestSandbox::new_temp_dir();
    my $launcher_dir_c = "$claude_data_c/.launcher";
    mkdir_p($launcher_dir_c);
    my $statusline_c = "$claude_data_c/statusline.pl";
    write_raw($statusline_c, "#!/usr/bin/env perl\n1;\n");
    my $gc_c = "$claude_data_c/almanac-global-counts.json";

    my @args_c = eval { MountSpec::claude_home_create_args(
        claude_data => $claude_data_c, launcher_dir => $launcher_dir_c, statusline => $statusline_c,
        global_counts => $gc_c) };

    if (!@args_c) {
        fail("AC20/AC21: $_") for 1 .. 9;
        diag("claude_home_create_args error: " . ($@ // '(none)'));
        last SKIP;
    }

    my $c = eval { TestSandbox::create_probe_container(mounts => \@args_c) };
    ok(defined $c, 'AC20: a probe container was created from the MountSpec block') or diag($@);

    if (!defined $c) {
        fail("AC20/AC21: $_") for 1 .. 8;
        last SKIP;
    }

    my ($rc_w, $out_w) = TestSandbox::podman_run_capture('exec', $c, 'sh', '-c',
        'echo x > /root/.claude/almanac-global-counts.json');
    isnt($rc_w, 0, 'AC20: a write inside the container to the mounted path fails') or diag($out_w);
    like($out_w, qr/read-only/i, 'AC20: the failure names a read-only filesystem') or diag($out_w);

    my $host_bytes_before = slurp_raw($gc_c);
    my (undef, $out_cat) = TestSandbox::podman_run_capture('exec', $c, 'cat', '/root/.claude/almanac-global-counts.json');
    is($out_cat, $host_bytes_before, "AC20: cat inside the container returns P's bytes") or diag($out_cat);

    my $host_bytes_after = slurp_raw($gc_c);
    is($host_bytes_after, $host_bytes_before, 'AC20: the host file bytes are unchanged after the failed write');

    # AC21: host-side temp+rename rewrite, then a restart, then re-read.
    my $new_bytes = qq({"generated_at":"2030-01-01T00:00:00Z","note":{"total":9},"schema":1,)
                  . qq("todo":{"done":1,"open":1,"total":2}}\n);
    my $tmp = "$gc_c.tmp.$$";
    write_raw($tmp, $new_bytes);
    my $renamed = rename($tmp, $gc_c);
    ok($renamed, 'AC21: a host-side temp+rename over P succeeds') or diag("rename failed: $!");

    my ($rc_before_restart, $out_before_restart) =
        TestSandbox::podman_run_capture('exec', $c, 'cat', '/root/.claude/almanac-global-counts.json');
    diag('AC21 (not asserted, recorded per spec): container cat WITHOUT a restart returned '
       . ($out_before_restart eq $new_bytes ? 'the NEW bytes' : 'the OLD bytes')
       . " (rc=$rc_before_restart)");

    my ($rc_restart) = TestSandbox::podman_run_capture('restart', $c);
    is($rc_restart, 0, 'AC21: podman restart of the probe container exits 0');

    my (undef, $out_cat2) = TestSandbox::podman_run_capture('exec', $c, 'cat', '/root/.claude/almanac-global-counts.json');
    is($out_cat2, $new_bytes, 'AC21: after restart, the container cat returns the newly-renamed bytes')
        or diag($out_cat2);
}

# ---------------------------------------------------------------------------
# AC22 (suite rules): this file never spawns launcher.pl.
# ---------------------------------------------------------------------------
{
    open(my $fh, '<', $0) or die "fixture: cannot reread self ($0): $!";
    local $/;
    my $self_src = <$fh>;
    close $fh;
    ok(defined($self_src) && $self_src !~ /system\([^)]*launcher\.pl/ && $self_src !~ /exec\([^)]*launcher\.pl/,
        'AC22: this test file never spawns launcher.pl');
}

done_testing();
