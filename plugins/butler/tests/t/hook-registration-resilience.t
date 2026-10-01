#!/usr/bin/env perl
# platform: any
# NEW oracle for batch B of blueprint hook-continuity-remake, package
# 16-cutover (specs/16-cutover-spec.md sec 2.2/2.3/2.4, acceptance
# B-5..B-10). Covers the parts of batch B that hooks-json-route-registration.t
# and h01-settings-registration.t (structural, decode-only) do not: the
# flattened hooks/ directory's file set/mode, and the real subprocess
# resilience of every registration command's sec 2.2 template -- run exactly
# as bash -c the way Claude Code itself would invoke it.
#
# B-6/B-8/B-9/B-10 run against the REAL, TRACKED plugins/butler/hooks/ and
# .claude/settings.json (read-only -- this file never writes to either).
# B-7's three corruption scenarios build their own throwaway tempdir mirror
# of the sec 2.4 layout (sourced from the already-real hooks/next/ and
# hooks/next/guards/ content) and corrupt files only inside that mirror,
# never the tracked tree.
#
# Every subprocess is bounded by the real "timeout" utility, given an empty
# or fixture-controlled stdin (never inherited from this process), and run
# with BUTLER_STATE_DIR/CCPRAXIS_DATA_DIR/HOME pointed at a fresh File::Temp
# tempdir with every BP_*/CCPRAXIS_*/CLAUDE_* var cleared first. Nothing here
# spawns claude, podman, launcher.pl or another .t file.
#
# RIGHT NOW (before batch B lands): B-5 is red (hooks/ still carries the old
# 20-ish files plus a next/ subdirectory, and six sec-2.4 files are missing
# at the top level); B-6's total-command-count assertion is red (hooks.json +
# settings.json register far more than 18 commands today); B-8's non-vacuity
# deny is red (stop-gate.sh does not exist at the real, top-level hooks/ path
# yet, so the registration fails OPEN instead of denying). That is the
# correct shape of red for an oracle written from the spec.

use strict;
use warnings;
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }
use Test::More;
use FindBin qw($Bin);
use Cwd qw(abs_path);
use File::Temp qw(tempdir tempfile);
use File::Copy qw(copy);
use File::Path qw(make_path);
use JSON::PP ();

use lib "$Bin/../lib";
use GuardHarness ();

my $REPO   = abs_path("$Bin/../../../..");
BAIL_OUT('cannot resolve repo root') unless defined $REPO;
(my $BUTLER = "$REPO/plugins/butler") =~ s{\\}{/}g;
(my $HOOKS  = "$BUTLER/hooks")        =~ s{\\}{/}g;
my $SETTINGS   = "$REPO/.claude/settings.json";
my $HOOKS_JSON = "$HOOKS/hooks.json";

my $REAL_BASH_ABS = do { my $p = `bash -c "command -v bash"`; chomp $p; $p };
BAIL_OUT('cannot resolve a real bash on PATH') unless length $REAL_BASH_ABS;
my $REAL_TIMEOUT_ABS = do { my $p = `bash -c "command -v timeout"`; chomp $p; $p };
BAIL_OUT('cannot resolve a real timeout utility on PATH') unless length $REAL_TIMEOUT_ABS;

sub read_bytes { GuardHarness::read_bytes(@_) }

sub read_json {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return (undef, '', "cannot open $path: $!");
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $doc = eval { JSON::PP->new->utf8->decode($raw) };
    return ($doc, $raw, $@);
}

# ===========================================================================
# B-5: hooks/ contains exactly the sec 2.4 files, no subdirectory; every .sh
# there passes bash -n and is mode 100755 in `git ls-files -s`; no file
# under hooks/ contains "hooks/next".
# ===========================================================================
{
    my @EXPECT_FILES = qw(
        arm-on-entry.sh bind-dispatch.sh context-ceiling.sh continuity-off-check.sh
        denial-breaker.sh
        gate-shutdown.sh guard-ask-operator.sh guard-bash.sh guard-blueprint-write.sh
        guard-fork.sh guard-git-mutations.sh guard-writes.sh hooks.json ledger-guard.sh
        record-denial.sh record-prompt.sh
        run-hook.sh stop-gate.sh track-dispatch.sh wait-shape-guard.sh
    );
    is(scalar(@EXPECT_FILES), 20, 'sanity: this file\'s own sec 2.4 fixture list has 20 entries (never-halt 06 adds record-prompt.sh, record-denial.sh; never-halt 07 adds denial-breaker.sh)');

    opendir(my $dh, $HOOKS) or BAIL_OUT("cannot opendir $HOOKS: $!");
    my (@actual_files, @subdirs);
    for my $entry (readdir $dh) {
        next if $entry eq '.' || $entry eq '..';
        my $full = "$HOOKS/$entry";
        if (-d $full) { push @subdirs, $entry; next }
        push @actual_files, $entry;
    }
    closedir $dh;

    is_deeply([ sort @actual_files ], [ sort @EXPECT_FILES ],
       'B5a: hooks/ contains exactly the sec 2.4 files (no more, no fewer)')
        or diag('actual: ' . join(', ', sort @actual_files));
    is(scalar(@subdirs), 0, 'B5b: hooks/ has no subdirectory')
        or diag('found subdirectories: ' . join(', ', @subdirs));

    my @present = grep { -f "$HOOKS/$_" } @EXPECT_FILES;
    my @bad_syntax;
    my @bad_mode;
    my @mentions_next;
    for my $f (@present) {
        next unless $f =~ /\.sh\z/;
        my $path = "$HOOKS/$f";
        system($REAL_BASH_ABS, '-n', $path);
        my $rc = ($? == -1) ? -1 : ($? >> 8);
        push @bad_syntax, $f if $rc != 0;

        my $lsmode = `cd "$REPO" 2>/dev/null && git ls-files -s -- "plugins/butler/hooks/$f" 2>/dev/null`;
        if ($lsmode =~ /^(\d+)\s/) {
            push @bad_mode, "$f($1)" unless $1 eq '100755';
        } else {
            push @bad_mode, "$f(untracked)";
        }

        push @mentions_next, $f if index(read_bytes($path), 'hooks/next') >= 0;
    }
    is(scalar(@bad_syntax), 0, 'B5c: every present sec 2.4 .sh file passes bash -n')
        or diag('bash -n failed on: ' . join(', ', @bad_syntax));
    is(scalar(@bad_mode), 0, 'B5d: every present sec 2.4 .sh file is mode 100755 in git ls-files -s')
        or diag('wrong/missing mode: ' . join(', ', @bad_mode));
    is(scalar(@mentions_next), 0, 'B5e: no present sec 2.4 file under hooks/ mentions hooks/next')
        or diag('mentions hooks/next: ' . join(', ', @mentions_next));
}

# ---------------------------------------------------------------------------
# run_registered_command($cmd, %overrides) -- $cmd is a full registration
# command string (as decoded from hooks.json/settings.json), run through a
# hermetic bash subprocess: every BP_*/CCPRAXIS_*/CLAUDE_* var cleared first,
# then %overrides applied (a key with value undef stays unset). Empty stdin
# unless $overrides{__stdin} is given. Bounded by the real timeout utility.
# Returns { rc, out, err }.
# ---------------------------------------------------------------------------
sub run_registered_command {
    my ($cmd, %overrides) = @_;
    my $stdin_content = delete $overrides{__stdin};

    local %ENV = %ENV;
    delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
    $ENV{CCPRAXIS_NO_WAKELOCK} = 1;

    my $t = tempdir(CLEANUP => 1);
    (my $tt = $t) =~ s{\\}{/}g;
    make_path("$tt/home");
    $ENV{BUTLER_STATE_DIR}  = "$tt/state";
    $ENV{CCPRAXIS_DATA_DIR} = "$tt/data";
    $ENV{HOME}        = "$tt/home";
    $ENV{USERPROFILE} = "$tt/home";
    for my $k (keys %overrides) {
        if (defined $overrides{$k}) { $ENV{$k} = $overrides{$k} } else { delete $ENV{$k} }
    }

    # Invoked exactly as Claude Code invokes a registered hook command:
    # `bash -c "<command>"`, no intermediate script FILE -- so $0 in the
    # OUTERMOST shell is "bash" (never a ".sh" path), matching the sec 2.2
    # note that the registration shell itself has already sourced BASH_ENV
    # once before the command runs (B-9 asserts against a SECOND sourcing,
    # by anything the command itself execs, not this unavoidable first one).
    my $stdin_path = "$tt/stdin";
    open(my $sfh, '>:raw', $stdin_path) or die "write $stdin_path: $!";
    print {$sfh} (defined $stdin_content ? $stdin_content : '');
    close $sfh;

    my (undef, $out_path) = tempfile();
    my (undef, $err_path) = tempfile();

    open(local *OLDIN,  '<&', \*STDIN)  or die "dup STDIN: $!";
    open(local *OLDOUT, '>&', \*STDOUT) or die "dup STDOUT: $!";
    open(local *OLDERR, '>&', \*STDERR) or die "dup STDERR: $!";
    open(STDIN,  '<:raw', $stdin_path) or die "redirect STDIN: $!";
    open(STDOUT, '>:raw', $out_path)   or die "redirect STDOUT: $!";
    open(STDERR, '>:raw', $err_path)   or die "redirect STDERR: $!";

    system($REAL_TIMEOUT_ABS, 15, $REAL_BASH_ABS, '-c', $cmd);
    my $rc = ($? == -1) ? -1 : ($? >> 8);

    open(STDIN,  '<&', \*OLDIN)  or die "restore STDIN: $!";
    open(STDOUT, '>&', \*OLDOUT) or die "restore STDOUT: $!";
    open(STDERR, '>&', \*OLDERR) or die "restore STDERR: $!";

    my $out = read_bytes($out_path);
    my $err = read_bytes($err_path);
    unlink $out_path, $err_path;
    return { rc => $rc, out => $out, err => $err };
}

sub all_registered_commands {
    my ($doc, $label) = @_;
    my @out;
    return @out unless ref $doc eq 'HASH' && ref $doc->{hooks} eq 'HASH';
    for my $event (sort keys %{ $doc->{hooks} }) {
        for my $group (@{ $doc->{hooks}{$event} // [] }) {
            next unless ref $group eq 'HASH';
            my $matcher = defined $group->{matcher} ? $group->{matcher} : '(none)';
            for my $h (@{ $group->{hooks} // [] }) {
                next unless ref $h eq 'HASH';
                push @out, { event => $event, matcher => $matcher, command => ($h->{command} // ''), source => $label };
            }
        }
    }
    return @out;
}

# ===========================================================================
# B-6: Decision 38, run for real. Each of the (eventually 19) registered
# commands, run via bash -c with an empty stdin and a hermetic env, exits 0
# or 2, never 127, within 15s.
# ===========================================================================
{
    my ($hooksjson, undef, $herr) = read_json($HOOKS_JSON);
    my ($settings,  undef, $serr) = read_json($SETTINGS);
    ok(ref $hooksjson eq 'HASH', 'B6 precondition: hooks.json parses') or diag($herr // '');
    ok(ref $settings  eq 'HASH', 'B6 precondition: settings.json parses') or diag($serr // '');

    my @combined = (
        all_registered_commands($hooksjson, 'hooks.json'),
        all_registered_commands($settings,  'settings.json'),
    );
    is(scalar(@combined), 25,
       'B6a: exactly 25 commands are registered in total across hooks.json + settings.json (never-halt 06 adds 2, never-halt 07 adds 4: PreToolUse/PostToolUse/PostToolUseFailure/SessionStart denial-breaker.sh)')
        or diag('found ' . scalar(@combined) . ' registered commands');

    my (@bad_127, @bad_rc, @slow);
    for my $c (@combined) {
        next unless length $c->{command};
        my %env = $c->{source} eq 'hooks.json'
            ? (CLAUDE_PLUGIN_ROOT => $BUTLER)
            : (CLAUDE_PROJECT_DIR => $REPO);
        my $t0 = time();
        my $res = run_registered_command($c->{command}, %env);
        my $elapsed = time() - $t0;
        my $label = "$c->{source} $c->{event}/$c->{matcher}: $c->{command}";
        push @bad_127, $label if $res->{rc} == 127;
        push @bad_rc,  $label if $res->{rc} != 0 && $res->{rc} != 2;
        push @slow,    $label if $elapsed > 15;
    }
    is(scalar(@bad_127), 0, 'B6b: no registered command exits 127')
        or diag(join("\n", @bad_127));
    is(scalar(@bad_rc), 0, 'B6c: every registered command exits 0 or 2 (Decision 38)')
        or diag(join("\n", @bad_rc));
    is(scalar(@slow), 0, 'B6d: every registered command completes within 15s')
        or diag(join("\n", @slow));
}

# ---------------------------------------------------------------------------
# build_temp_mirror() -- a throwaway <root>/plugins/butler/hooks/ mirror of
# the sec 2.4 flattened layout, sourced from the ALREADY REAL hooks/next/
# and hooks/next/guards/ files (these exist today; only their final PATH is
# what batch B has not yet applied). Returns $root.
# ---------------------------------------------------------------------------
sub build_temp_mirror {
    my $root = tempdir(CLEANUP => 1);
    (my $r = $root) =~ s{\\}{/}g;
    my $dst = "$r/plugins/butler/hooks";
    make_path($dst);

    my %SRC = (
        'arm-on-entry.sh'          => "$HOOKS/next/arm-on-entry.sh",
        'bind-dispatch.sh'         => "$HOOKS/next/bind-dispatch.sh",
        'context-ceiling.sh'       => "$HOOKS/next/guards/context-ceiling.sh",
        'continuity-off-check.sh'  => "$HOOKS/next/continuity-off-check.sh",
        'gate-shutdown.sh'         => "$HOOKS/next/guards/gate-shutdown.sh",
        'guard-ask-operator.sh'    => "$HOOKS/next/guards/guard-ask-operator.sh",
        'guard-bash.sh'            => "$HOOKS/next/guards/guard-bash.sh",
        'guard-blueprint-write.sh' => "$HOOKS/next/guards/guard-blueprint-write.sh",
        'guard-git-mutations.sh'   => "$HOOKS/next/guards/guard-git-mutations.sh",
        'guard-writes.sh'          => "$HOOKS/next/guard-writes.sh",
        'ledger-guard.sh'          => "$HOOKS/next/ledger-guard.sh",
        'run-hook.sh'              => "$HOOKS/next/run-hook.sh",
        'stop-gate.sh'             => "$HOOKS/next/stop-gate.sh",
        'track-dispatch.sh'        => "$HOOKS/next/guards/track-dispatch.sh",
        'wait-shape-guard.sh'      => "$HOOKS/next/guards/wait-shape-guard.sh",
    );
    for my $name (sort keys %SRC) {
        my $src = -f "$HOOKS/$name" ? "$HOOKS/$name" : $SRC{$name};   # post-B layout first
        next unless -f $src;
        copy($src, "$dst/$name") or die "copy $src -> $dst/$name: $!";
        chmod 0755, "$dst/$name";
    }
    return $r;
}

sub hooksjson_template {
    my ($file, $args) = @_;
    $args //= '';
    return qq{unset BASH_ENV ; f="\${CLAUDE_PLUGIN_ROOT}/hooks/$file" ; w="\${CLAUDE_PLUGIN_ROOT}/hooks/run-hook.sh" ; [ -f "\$f" ] && [ -f "\$w" ] || exit 0 ; bash -n "\$f" 2>/dev/null && bash -n "\$w" 2>/dev/null || exit 0 ; exec env -u SHELLOPTS bash "\$f"$args};
}

sub settings_template {
    my ($file, $args) = @_;
    $args //= '';
    return qq{unset BASH_ENV ; f="\$CLAUDE_PROJECT_DIR/plugins/butler/hooks/$file" ; w="\$CLAUDE_PROJECT_DIR/plugins/butler/hooks/run-hook.sh" ; [ -f "\$f" ] && [ -f "\$w" ] || exit 0 ; bash -n "\$f" 2>/dev/null && bash -n "\$w" 2>/dev/null || exit 0 ; exec env -u SHELLOPTS bash "\$f"$args};
}

# ===========================================================================
# B-7: RT-M1, in a temp plugin root mirror. Each scenario's precondition
# (bash -n fails on the corrupted file) is checked before trusting the
# outcome.
# ===========================================================================
{
    my $stop_cmd = hooksjson_template('stop-gate.sh', '');

    # ---------------------------------------------------------------------
    # _truncate_near_half($path) -- cuts $path to ~half its own byte length,
    # walking the cut point backward in small steps (bounded) until bash -n
    # actually rejects the result. A plain byte-half of run-hook.sh can land
    # inside a comment block, which is still syntactically valid bash (RT-M1
    # requires the PRECONDITION to genuinely fail, not merely "close to
    # half") -- so this is "first half" made precise enough to be a real
    # syntax error rather than a coincidentally-valid prefix.
    # ---------------------------------------------------------------------
    sub _truncate_near_half {
        my ($path) = @_;
        my $bytes = read_bytes($path);
        my $half = int(length($bytes) / 2);
        my $off = $half;
        while ($off > 0) {
            open(my $fh, '>:raw', $path) or die "truncate $path: $!";
            print {$fh} substr($bytes, 0, $off);
            close $fh;
            system($REAL_BASH_ABS, '-n', $path);
            my $rc = ($? == -1) ? -1 : ($? >> 8);
            return ($off, $rc) if $rc != 0;
            $off -= 20;
        }
        return ($off, 0);
    }

    # (a) run-hook.sh is its own first half.
    {
        my $root = build_temp_mirror();
        my $rh = "$root/plugins/butler/hooks/run-hook.sh";
        my (undef, $precondition_rc) = _truncate_near_half($rh);
        isnt($precondition_rc, 0, 'B7a precondition: bash -n fails on a run-hook.sh truncated to ~half its own length')
            or diag('no truncation point near half of run-hook.sh produced a syntax error');

        my $res = run_registered_command($stop_cmd, CLAUDE_PLUGIN_ROOT => "$root/plugins/butler");
        is($res->{rc}, 0, 'B7a: stop-gate.sh registration exits 0 when run-hook.sh is truncated to its own first half');
        is($res->{out}, '', 'B7a: ...with empty stdout');
    }

    # (b) stop-gate.sh truncated inside a quoted string.
    {
        my $root = build_temp_mirror();
        my $sg = "$root/plugins/butler/hooks/stop-gate.sh";
        my $bytes = read_bytes($sg);
        my $needle = q{"$d/run-hook.sh"};
        my $idx = index($bytes, $needle);
        BAIL_OUT("B7b: cannot find $needle in stop-gate.sh to truncate inside") if $idx < 0;
        # cut off the closing quote, leaving the string literal unterminated
        my $cut = $idx + length($needle) - 1;
        open(my $fh, '>:raw', $sg) or die "truncate $sg: $!";
        print {$fh} substr($bytes, 0, $cut);
        close $fh;
        system($REAL_BASH_ABS, '-n', $sg);
        my $precondition_rc = ($? == -1) ? -1 : ($? >> 8);
        isnt($precondition_rc, 0, 'B7b precondition: bash -n fails on a stop-gate.sh truncated inside a quoted string');

        my $res = run_registered_command($stop_cmd, CLAUDE_PLUGIN_ROOT => "$root/plugins/butler");
        is($res->{rc}, 0, 'B7b: stop-gate.sh registration exits 0 when stop-gate.sh is truncated inside a quoted string');
        is($res->{out}, '', 'B7b: ...with empty stdout');
    }

    # (c) run-hook.sh absent.
    {
        my $root = build_temp_mirror();
        my $rh = "$root/plugins/butler/hooks/run-hook.sh";
        unlink $rh or die "unlink $rh: $!";
        ok(!-f $rh, 'B7c precondition: run-hook.sh is absent from the mirror');

        my $res = run_registered_command($stop_cmd, CLAUDE_PLUGIN_ROOT => "$root/plugins/butler");
        is($res->{rc}, 0, 'B7c: stop-gate.sh registration exits 0 when run-hook.sh is absent');
        is($res->{out}, '', 'B7c: ...with empty stdout');
    }

    # Same three scenarios for the settings.json command
    # (guard-git-mutations.sh) with a "git stash" payload on stdin.
    my $settings_cmd = settings_template('guard-git-mutations.sh', '');
    my $stash_payload = JSON::PP->new->encode({ tool_input => { command => 'git stash' } });

    # (a')
    {
        my $root = build_temp_mirror();
        my $rh = "$root/plugins/butler/hooks/run-hook.sh";
        my (undef, $precondition_rc) = _truncate_near_half($rh);
        isnt($precondition_rc, 0, 'B7a-settings precondition: bash -n fails on a run-hook.sh truncated to ~half its own length');

        my $res = run_registered_command($settings_cmd, CLAUDE_PROJECT_DIR => $root, __stdin => $stash_payload);
        is($res->{rc}, 0, 'B7a-settings: guard-git-mutations.sh registration exits 0 when run-hook.sh is truncated, even with a git-stash payload');
        is($res->{out}, '', 'B7a-settings: ...with empty stdout');
    }

    # (b')
    {
        my $root = build_temp_mirror();
        my $ggm = "$root/plugins/butler/hooks/guard-git-mutations.sh";
        my $bytes = read_bytes($ggm);
        my $needle = q{"$d/run-hook.sh"};
        my $idx = index($bytes, $needle);
        BAIL_OUT("B7b-settings: cannot find $needle in guard-git-mutations.sh to truncate inside") if $idx < 0;
        my $cut = $idx + length($needle) - 1;
        open(my $fh, '>:raw', $ggm) or die "truncate $ggm: $!";
        print {$fh} substr($bytes, 0, $cut);
        close $fh;
        system($REAL_BASH_ABS, '-n', $ggm);
        my $precondition_rc = ($? == -1) ? -1 : ($? >> 8);
        isnt($precondition_rc, 0, 'B7b-settings precondition: bash -n fails on a guard-git-mutations.sh truncated inside a quoted string');

        my $res = run_registered_command($settings_cmd, CLAUDE_PROJECT_DIR => $root, __stdin => $stash_payload);
        is($res->{rc}, 0, 'B7b-settings: guard-git-mutations.sh registration exits 0 when guard-git-mutations.sh is truncated inside a quoted string, even with a git-stash payload');
        is($res->{out}, '', 'B7b-settings: ...with empty stdout');
    }

    # (c')
    {
        my $root = build_temp_mirror();
        my $rh = "$root/plugins/butler/hooks/run-hook.sh";
        unlink $rh or die "unlink $rh: $!";

        my $res = run_registered_command($settings_cmd, CLAUDE_PROJECT_DIR => $root, __stdin => $stash_payload);
        is($res->{rc}, 0, 'B7c-settings: guard-git-mutations.sh registration exits 0 when run-hook.sh is absent, even with a git-stash payload');
        is($res->{out}, '', 'B7c-settings: ...with empty stdout');
    }
}

# ===========================================================================
# B-8: non-vacuity, against the REAL plugin root and REAL repo.
# ===========================================================================
{
    my $stop_cmd = hooksjson_template('stop-gate.sh', '');
    my $sid = 'resbdb8';
    my $state_root = GuardHarness::fresh_state();
    GuardHarness::arm($sid, 'driver');
    my $payload = JSON::PP->new->encode({ session_id => $sid, hook_event_name => 'Stop', stop_hook_active => JSON::PP::false() });

    my $res = run_registered_command($stop_cmd,
        CLAUDE_PLUGIN_ROOT  => $BUTLER,
        BUTLER_STATE_DIR    => $state_root,
        __stdin             => $payload,
    );
    is($res->{rc}, 2,
       'B8a: with the real plugin root and an armed session with no holder, the stop-gate.sh registration on a Stop payload exits 2')
        or diag("rc=$res->{rc} out=[$res->{out}] err=[$res->{err}]");
    like($res->{err}, qr/butler-hold/,
       'B8b: ...and stderr names butler-hold');

    my $settings_cmd = settings_template('guard-git-mutations.sh', '');
    my $stash_payload  = JSON::PP->new->encode({ tool_input => { command => 'git stash' } });
    my $list_payload   = JSON::PP->new->encode({ tool_input => { command => 'git stash list' } });

    my $res_deny = run_registered_command($settings_cmd, CLAUDE_PROJECT_DIR => $REPO, __stdin => $stash_payload);
    is($res_deny->{rc}, 2, 'B8c: with the real repo, the settings command on a git-stash payload exits 2');

    my $res_allow = run_registered_command($settings_cmd, CLAUDE_PROJECT_DIR => $REPO, __stdin => $list_payload);
    is($res_allow->{rc}, 0, 'B8d: ...and on git-stash-list exits 0');
}

# ===========================================================================
# B-9: RT-L7 -- inherited BASH_ENV is never sourced, inherited SHELLOPTS is
# never applied, through the deny path of B-8.
# ===========================================================================
{
    my $stop_cmd = hooksjson_template('stop-gate.sh', '');
    my $sid = 'resbdb9';
    my $state_root = GuardHarness::fresh_state();
    GuardHarness::arm($sid, 'driver');
    my $payload = JSON::PP->new->encode({ session_id => $sid, hook_event_name => 'Stop', stop_hook_active => JSON::PP::false() });

    my $t = tempdir(CLEANUP => 1);
    (my $tt = $t) =~ s{\\}{/}g;
    my $bash_env_file = "$tt/bash_env.sh";
    my $log_file = "$tt/bash_env.log";
    open(my $fh, '>', $bash_env_file) or die $!;
    print {$fh} "echo \"\$0\" >> \"$log_file\"\n";
    close $fh;

    my $res = run_registered_command($stop_cmd,
        CLAUDE_PLUGIN_ROOT  => $BUTLER,
        BUTLER_STATE_DIR    => $state_root,
        BASH_ENV            => $bash_env_file,
        __stdin             => $payload,
    );
    is($res->{rc}, 2, 'B9a: the B8 deny case still exits 2 with BASH_ENV set to an appending log');
    my @log_lines = -f $log_file ? do { open(my $lfh, '<', $log_file); my @l = <$lfh>; close $lfh; @l } : ();
    my @sh_lines = grep { /\.sh\s*\z/ } @log_lines;
    is(scalar(@sh_lines), 0, 'B9b: ...and no BASH_ENV log line ends in .sh (it was never sourced by the hook\'s bash)')
        or diag('log: ' . join('', @log_lines));

    my $state_root2 = GuardHarness::fresh_state();
    GuardHarness::arm($sid, 'driver');
    my $res2 = run_registered_command($stop_cmd,
        CLAUDE_PLUGIN_ROOT  => $BUTLER,
        BUTLER_STATE_DIR    => $state_root2,
        SHELLOPTS           => 'xtrace',
        __stdin             => $payload,
    );
    is($res2->{rc}, 2, 'B9c: the B8 deny case still exits 2 with SHELLOPTS=xtrace exported');
    unlike($res2->{err}, qr/^\++ (?:d|module)=/m,
       'B9d: ...and stderr has no xtrace line for this wrapper\'s own $d/$module (inherited SHELLOPTS not applied to the hook\'s bash)');
}

# ===========================================================================
# B-10: a non-applying Stop (no BP_LEDGER, not armed) through the full
# stop-gate.sh registration string launches 0 perl (PATH shim).
# ===========================================================================
{
    my $stop_cmd = hooksjson_template('stop-gate.sh', '');
    my $shim = tempdir(CLEANUP => 1);
    my $log = "$shim/shim.log";
    for my $name (qw(bash perl)) {
        my $real = ($name eq 'bash') ? $REAL_BASH_ABS : do { my $p = `bash -c "command -v perl"`; chomp $p; $p };
        open(my $sfh, '>', "$shim/$name") or die $!;
        print {$sfh} "#!$REAL_BASH_ABS\n";
        print {$sfh} "printf '%s\\n' '$name' >> \"$log\"\n";
        print {$sfh} "exec \"$real\" \"\$\@\"\n";
        close $sfh;
        chmod 0755, "$shim/$name";
    }
    my $sid = 'resb10x';
    my $state_root = GuardHarness::fresh_state();  # nothing armed for $sid
    my $payload = JSON::PP->new->encode({ session_id => $sid, hook_event_name => 'Stop', stop_hook_active => JSON::PP::false() });

    my $res = run_registered_command($stop_cmd,
        CLAUDE_PLUGIN_ROOT  => $BUTLER,
        BUTLER_STATE_DIR    => $state_root,
        PATH                => "$shim:$ENV{PATH}",
        __stdin             => $payload,
    );
    is($res->{rc}, 0, 'B10a: a non-applying Stop through the full stop-gate.sh registration string exits 0');
    my @perl_lines = -f $log ? do { open(my $lfh, '<', $log); my @l = grep { /^perl$/ } <$lfh>; close $lfh; @l } : ();
    is(scalar(@perl_lines), 0, 'B10b: ...and launches 0 perl');
}

# ===========================================================================
# B-12 (Decision 81): Claude Code on Windows runs a hook command whose FIRST
# whitespace-delimited token ends in `.sh` as a script via bash. The first
# cut of the guarded form began with f="<root>/hooks/x.sh", so the harness ran
# `bash f=C:/.../x.sh` ("No such file or directory"), the rest of the line saw
# $f unset and exited 0, and every registration was silently inert. Measured
# from this repo's own session transcripts (hook_success stderr), 2026-09-25.
# No registered command may start with a token ending in .sh.
# ===========================================================================
{
    my @cmds;
    for my $file ($HOOKS_JSON, $SETTINGS) {
        open my $fh, '<:raw', $file or die "$file: $!";
        my $d = JSON::PP->new->decode(do { local $/; <$fh> });
        for my $ev (keys %{ $d->{hooks} || {} }) {
            for my $g (@{ $d->{hooks}{$ev} }) {
                push @cmds, map { $_->{command} } @{ $g->{hooks} || [] };
            }
        }
    }
    ok(scalar(@cmds) >= 18, 'B-12: found the registered commands (' . scalar(@cmds) . ')');
    my @bad = grep { my ($t) = /^\s*(\S+)/; defined $t && $t =~ /\.sh"?\z/ } @cmds;
    is(scalar(@bad), 0, 'B-12: no registered command starts with a token ending in .sh')
        or diag("starts with a .sh token: $_") for @bad;
    ok(!(grep { !/^unset BASH_ENV ; / } @cmds), 'B-12: every registered command starts with "unset BASH_ENV ; "');
}

done_testing();
