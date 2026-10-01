#!/usr/bin/env perl
# platform: any
# Spec: 13-almanac-bash-write-guard (blueprint tooling-fixes). guard-almanac-
# write.sh and hooks.json do NOT have a Bash branch/registration yet at the
# time this file is written -- every assertion below that expects a DENY is
# expected to fail for exactly that reason (missing Bash dispatch), never a
# harness bug in this file. Assertions that expect an ALLOW may already pass
# today, since an unregistered/unhandled Bash tool_name is a no-op allow --
# that overlap with "no regression" is intentional (AC11, AC12, AC14, AC19).
#
# Every fire below runs with HOME, USERPROFILE and ALMANAC_HOME pointed at one
# fresh tempdir for this whole file, and every BP_* variable deleted from the
# child environment (spec sec 4). Only fictional paths (/c/P/..., /c/H/...,
# C:\P\...) are used, and AC20 proves none of them, nor the tempdir, hold
# anything after the run.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir tempfile);
use File::Path ();
use JSON::PP;
use Time::HiRes ();
use Cwd ();

(my $ALM  = "$Bin/../..") =~ s{\\}{/}g;                 # plugins/almanac
(my $H    = "$ALM/hooks") =~ s{\\}{/}g;

my $GUARD      = "$H/guard-almanac-write.sh";
my $HOOKS_JSON = "$H/hooks.json";
ok(-f $GUARD, 'guard-almanac-write.sh exists') or BAIL_OUT('hook missing');

# =============================================================================
# scaffolding
# =============================================================================
sub slurp_raw {
    my ($p) = @_;
    return undef unless defined $p && -f $p;
    open my $fh, '<:raw', $p or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

my $J = JSON::PP->new->canonical->utf8;

my $FRESH_HOME = tempdir(CLEANUP => 1);
$FRESH_HOME =~ s{\\}{/}g;

# fire_payload($guard, $payload_or_raw, %env_overrides) -> ($rc, $out, $err)
# A real bash spawn of $guard, both streams captured to real File::Temp files
# (never an in-memory scalar reopen -- the Windows "Bad file descriptor"
# landmine). HOME/USERPROFILE/ALMANAC_HOME point at one shared fresh tempdir;
# every BP_* var is scrubbed first; %env_overrides is overlaid afterward
# (undef deletes the key) and localized to this call only.
sub fire_payload {
    my ($guard, $payload, %env_overrides) = @_;
    my $raw = ref($payload) ? $J->encode($payload) : $payload;
    my (undef, $tmp) = tempfile('alm-bash-XXXXXX', TMPDIR => 1);
    open(my $fh, '>:raw', $tmp) or die "cannot write $tmp: $!";
    print {$fh} $raw;
    close $fh;
    my $outp = "$tmp.out";
    my $errp = "$tmp.err";

    local %ENV = %ENV;
    delete $ENV{$_} for grep { /^BP_/ } keys %ENV;
    $ENV{HOME}         = $FRESH_HOME;
    $ENV{USERPROFILE}  = $FRESH_HOME;
    $ENV{ALMANAC_HOME} = $FRESH_HOME;
    for my $k (keys %env_overrides) {
        if (defined $env_overrides{$k}) { $ENV{$k} = $env_overrides{$k} }
        else                            { delete $ENV{$k} }
    }

    my $rc  = system(qq{bash "$guard" < "$tmp" > "$outp" 2> "$errp"});
    my $out = slurp_raw($outp) // '';
    my $err = slurp_raw($errp) // '';
    unlink $tmp, $outp, $errp;
    return ($rc >> 8, $out, $err);
}

sub payload_bash {
    my ($cmd, %opts) = @_;
    my %p = (hook_event_name => 'PreToolUse', tool_name => 'Bash', tool_input => { command => $cmd });
    $p{cwd}             = $opts{cwd}             if exists $opts{cwd} && defined $opts{cwd};
    $p{transcript_path} = $opts{transcript_path} if exists $opts{transcript_path};
    $p{description}     = $opts{description}     if exists $opts{description};
    return \%p;
}

sub fire_bash {
    my ($cmd, %opts) = @_;
    my $guard = $opts{guard} // $GUARD;
    my $cwd = exists $opts{cwd} ? $opts{cwd} : '/c/P';
    my %payload_opts;
    $payload_opts{cwd}             = $cwd                      if defined $cwd;
    $payload_opts{transcript_path} = $opts{transcript_path}    if exists $opts{transcript_path};
    $payload_opts{description}     = $opts{description}        if exists $opts{description};
    my $payload = payload_bash($cmd, %payload_opts);
    return fire_payload($guard, $payload, %{ $opts{env} // {} });
}

sub fire_edit {
    my ($path, %opts) = @_;
    my $guard = $opts{guard} // $GUARD;
    my $payload = { hook_event_name => 'PreToolUse', tool_name => 'Edit', tool_input => { file_path => $path } };
    return fire_payload($guard, $payload, %{ $opts{env} // {} });
}

sub assert_deny_bash {
    my ($cmd, $label, %opts) = @_;
    my ($rc, $out, $err) = fire_bash($cmd, %opts);
    is($rc, 2, "$label: exit 2") or diag("rc=$rc out=[$out] err=[$err]");
    like($err, qr/^BLOCKED:/, "$label: stderr starts BLOCKED:") or diag($err);
    return ($rc, $out, $err);
}

sub assert_allow_bash {
    my ($cmd, $label, %opts) = @_;
    my ($rc, $out, $err) = fire_bash($cmd, %opts);
    is($rc, 0, "$label: exit 0") or diag("rc=$rc out=[$out] err=[$err]");
    is($out, '', "$label: stdout empty") or diag($out);
    is($err, '', "$label: stderr empty") or diag($err);
    return ($rc, $out, $err);
}

# Fixture paths from spec section 3.
my $R = '/c/P/.ccpraxis-local-data/bug-reports/20260813-010203-abcd.md';
my $T = '/c/P/.ccpraxis-local-data/almanac/todo/t1.md';
my $V = '/c/H/.claude/claude-code-vault/almanac/note/n1.md';

# =============================================================================
# AC1 (DC1, 2.1) -- hooks.json gains exactly one new PreToolUse entry, matcher
# "Bash", one hook object, type command, timeout 15, exact command string.
# AC2 (DC1, 2.1) -- the Edit|Write|MultiEdit|NotebookEdit entry is untouched.
# =============================================================================
my $G = q{unset BASH_ENV ; f="${CLAUDE_PLUGIN_ROOT}/hooks/guard-almanac-write.sh" ; [ -f "$f" ] || exit 0 ; exec env -u SHELLOPTS bash "$f"};

{
    ok(-f $HOOKS_JSON, 'hooks.json exists') or BAIL_OUT('hooks.json missing');
    my $raw = slurp_raw($HOOKS_JSON);
    my $cfg = defined($raw) ? eval { JSON::PP->new->decode($raw) } : undef;
    ok($cfg, 'AC1/AC2: hooks.json decodes as JSON') or diag($raw ? "decode failed: $@" : 'file unreadable');

    my (@bash_entries, @edit_entries);
    if (ref $cfg eq 'HASH') {
        for my $blk (@{ $cfg->{hooks}{PreToolUse} || [] }) {
            push @bash_entries, $blk if ($blk->{matcher} // '') eq 'Bash';
            push @edit_entries, $blk if ($blk->{matcher} // '') eq 'Edit|Write|MultiEdit|NotebookEdit';
        }
    }

    is(scalar(@bash_entries), 1, 'AC1: exactly one PreToolUse entry has matcher "Bash"');
    if (@bash_entries) {
        my $hooks = $bash_entries[0]{hooks} || [];
        is(scalar(@$hooks), 1, 'AC1: the Bash entry has exactly one hook object');
        if (@$hooks) {
            is($hooks->[0]{type},    'command', 'AC1: hook type is "command"');
            is($hooks->[0]{timeout}, 15,        'AC1: hook timeout is 15');
            is($hooks->[0]{command}, $G,        'AC1: hook command equals the spec string exactly');
        } else {
            fail('AC1: hook type is "command"');
            fail('AC1: hook timeout is 15');
            fail('AC1: hook command equals the spec string exactly');
        }
    } else {
        fail('AC1: the Bash entry has exactly one hook object');
        fail('AC1: hook type is "command"');
        fail('AC1: hook timeout is 15');
        fail('AC1: hook command equals the spec string exactly');
    }

    is(scalar(@edit_entries), 1, 'AC2: exactly one entry has matcher Edit|Write|MultiEdit|NotebookEdit');
    if (@edit_entries) {
        my $hooks = $edit_entries[0]{hooks} || [];
        is(scalar(@$hooks), 1, 'AC2: still exactly one hook object');
        is($hooks->[0]{command}, '${CLAUDE_PLUGIN_ROOT}/hooks/guard-almanac-write.sh',
           'AC2: its command is unchanged (bare form)');
    } else {
        fail('AC2: still exactly one hook object');
        fail('AC2: its command is unchanged (bare form)');
    }
}

# =============================================================================
# AC3 (DC1) -- the registration STRING itself (not just the script) denies,
# run through a real CLAUDE_PLUGIN_ROOT like Claude Code would.
# =============================================================================
{
    my (undef, $script) = tempfile('alm-ac3-XXXXXX', SUFFIX => '.sh', TMPDIR => 1);
    open(my $sfh, '>', $script) or die "cannot write $script: $!";
    print {$sfh} "#!/usr/bin/env bash\n$G\n";
    close $sfh;

    my $payload = payload_bash("echo x > $R", cwd => '/c/P');
    my (undef, $in) = tempfile('alm-ac3-in-XXXXXX', TMPDIR => 1);
    open(my $ifh, '>:raw', $in) or die "cannot write $in: $!";
    print {$ifh} $J->encode($payload);
    close $ifh;

    local %ENV = %ENV;
    delete $ENV{$_} for grep { /^BP_/ } keys %ENV;
    $ENV{CLAUDE_PLUGIN_ROOT} = $ALM;
    $ENV{HOME}               = $FRESH_HOME;
    $ENV{USERPROFILE}        = $FRESH_HOME;
    $ENV{ALMANAC_HOME}       = $FRESH_HOME;

    my $rc = system(qq{bash "$script" < "$in" > /dev/null 2>/dev/null});
    unlink $script, $in;
    is($rc >> 8, 2, 'AC3: firing the AC1 command string via CLAUDE_PLUGIN_ROOT denies behavior 1');
}

# =============================================================================
# AC4/AC5/AC6 (DC1, DC3) -- behaviors 1-10: redirects, sed -i, tee, mv, cp,
# rm, truncate, touch all deny; the denial names the sanctioned verb per
# store; behavior 1's exact-line shape (AC6).
# =============================================================================
{
    my ($rc, $out, $err) = assert_deny_bash("echo x > $R", 'AC4/b1: echo x > R');
    my @lines = split /\n/, $err;
    like($lines[0] // '', qr/Bash \(>\)/, 'AC6: first stderr line contains "Bash (>)"');
    like($err, qr/almanac-bug\.pl update/,     'AC5: bug denial names almanac-bug.pl update');
    like($err, qr/almanac-bug\.pl file/,       'AC5: bug denial names almanac-bug.pl file');
    like($err, qr/almanac-bug\.pl set-status/, 'AC5: bug denial names almanac-bug.pl set-status');
    like($err, qr/20260813-010203-abcd/,       'AC5: bug denial names the id');
    ok((grep { $_ eq "  $R" } @lines), "AC6: a stderr line is exactly '  $R'") or diag($err);
    ok((grep { /^\s*perl <ccpraxis>\/plugins\/almanac\/scripts\/almanac-bug\.pl update 20260813-010203-abcd --body -\s*$/ } @lines),
       'AC6: the update line reads exactly "...update <id> --body -"') or diag($err);
}
{
    my (undef, undef, $err) = assert_deny_bash("echo x >> $T", 'AC4/b2: echo x >> T');
    my @lines = split /\n/, $err;
    like($lines[0] // '', qr/Bash \(>>\)/, 'AC4/b2: first stderr line contains "Bash (>>)"');
    like($err, qr/almanac-todo\.pl/, 'AC5: todo denial names almanac-todo.pl');
    like($err, qr/create \| edit \| complete \| reopen \| delete/, 'AC5: todo denial names its verb list');
    like($err, qr/store type: todo/, 'AC5: todo denial names "store type: todo"');
    like($err, qr/record id:\s*t1/, 'AC5: todo denial names "record id: t1"');
}
{
    assert_deny_bash("sed -i 's/a/b/' $R", 'AC4/b3a: sed -i on R (bug)');
    assert_deny_bash("sed -i.bak -e 's/a/b/' $T", 'AC4/b3b: sed -i.bak -e on T (store)');
}
{
    my (undef, undef, $err) = assert_deny_bash("perl -pi -e 's/a/b/' $V", 'AC4/b4: perl -pi -e on V (note)');
    like($err, qr/almanac-note\.pl/, 'AC5: note denial names almanac-note.pl');
}
{
    assert_deny_bash("echo x | tee $R", 'AC4/b5a: echo x | tee R');
    assert_deny_bash("tee -a $T < /dev/null", 'AC4/b5b: tee -a T < /dev/null');
}
{
    assert_deny_bash("mv /tmp/x.md $T", 'AC4/b6a: mv destination T');
    assert_deny_bash("mv $R /tmp/", 'AC4/b6b: mv source R');
}
{
    assert_deny_bash("cp /tmp/x.md $R", 'AC4/b7a: cp destination R');
    assert_deny_bash('cp /tmp/x.md /c/P/.ccpraxis-local-data/bug-reports/', 'AC4/b7b: cp into bug-reports root (Rule B)');
}
{
    assert_deny_bash("rm $R", 'AC4/b8a: rm R');
    assert_deny_bash("rm -f $T", 'AC4/b8b: rm -f T');
    assert_deny_bash('rm -rf /c/P/.ccpraxis-local-data/bug-reports', 'AC4/b8c: rm -rf bug-reports root (Rule B)');
    my (undef, undef, $err8d) = assert_deny_bash('rm -rf /c/P/.ccpraxis-local-data', 'AC4/b8d: rm -rf container (Rule C, root)');
    like($err8d, qr/almanac-bug\.pl/,  'AC5: root denial names almanac-bug.pl');
    like($err8d, qr/almanac-todo\.pl/, 'AC5: root denial names almanac-todo.pl');
    assert_deny_bash('rm -rf /c/P/.ccpraxis-local-data/*', 'AC4/b8e: rm -rf glob matching bug-reports (Rule B via glob)');
}
{
    assert_deny_bash("truncate -s 0 $R", 'AC4/b9: truncate -s 0 R');
}
{
    my (undef, undef, $err10) = assert_deny_bash('touch /c/P/.ccpraxis-local-data/almanac/decision/d1.md', 'AC4/b10: touch decision');
    like($err10, qr/almanac-decision\.pl/, 'AC5: decision denial names almanac-decision.pl');
    like($err10, qr/file \| answer/,       'AC5: decision denial names its verb list');
}

# =============================================================================
# AC7 (DC3) -- behavior 11: interpreter one-liners.
# =============================================================================
{
    my (undef, undef, $errp) = assert_deny_bash(
        q{python -c "open('/c/P/.ccpraxis-local-data/bug-reports/a.md','w').write('x')"},
        'AC7: python -c bug one-liner');
    my @lines = split /\n/, $errp;
    like($lines[0] // '', qr/python -c/, 'AC7: first stderr line contains "python -c"');

    assert_deny_bash(q{perl -e 'unlink "/c/P/.ccpraxis-local-data/almanac/todo/t1.md"'},
        'AC7: perl -e unlink todo one-liner');

    my (undef, undef, $errn) = assert_deny_bash(
        q{node -e "require('fs').writeFileSync('/c/H/.claude/claude-code-vault/almanac/task/k.md','x')"},
        'AC7: node -e task one-liner');
    like($errn, qr/almanac-task\.pl/, 'AC5: node one-liner denial names almanac-task.pl');
}

# =============================================================================
# AC8 (DC3) -- behavior 12: resolution forms.
# =============================================================================
{
    assert_deny_bash('rm .ccpraxis-local-data/bug-reports/a.md', 'AC8: relative rm, cwd /c/P', cwd => '/c/P');
    assert_deny_bash('rm a.md', 'AC8: relative rm, cwd inside bug-reports (cwd join)',
        cwd => '/c/P/.ccpraxis-local-data/bug-reports');
    assert_deny_bash('rm ~/.claude/claude-code-vault/almanac/todo/x.md', 'AC8: tilde-form rm');
    assert_deny_bash(q{rm "$HOME/.claude/claude-code-vault/almanac/todo/x.md"},
        'AC8: $HOME-based rm (unresolvable, visible store text)');
    assert_deny_bash(q{rm 'C:\P\.ccpraxis-local-data\bug-reports\a.md'}, 'AC8: Windows backslash form rm');
    assert_deny_bash('rm /c/P/CCPRAX~1/bug-reports/a.md', 'AC8: 8.3 short-name form rm');
}

# =============================================================================
# AC9 (DC1, DC3) -- behavior 13: compound commands.
# =============================================================================
{
    assert_deny_bash("true && rm $R", 'AC9: true && rm R');
    assert_deny_bash(qq{bash -c "rm $R"}, 'AC9: bash -c "rm R"');
    assert_deny_bash("(cd /tmp; true); echo x > $T", 'AC9: subshell cd then echo x > T (absolute, cd irrelevant)');
}

# =============================================================================
# AC10 (DC3) -- behavior 14: cd then a relative write, with a marker in the
# same command (Rule E).
# =============================================================================
{
    my (undef, undef, $err14) = assert_deny_bash(
        'cd /c/P/.ccpraxis-local-data/bug-reports && rm a.md',
        'AC10: cd into bug-reports && rm a.md (Rule E)');
    my @lines = split /\n/, $err14;
    like($lines[0] // '', qr/Bash \(cd\)/, 'AC10: first stderr line contains "Bash (cd)"');
    like($err14, qr/would delete, move, or write through a directory that holds bug reports or almanac records/,
        'AC10: the root denial text names the shape');
    ok((grep { $_ eq '  a.md' } @lines), 'AC10: the path field is the relative text "a.md"') or diag($err14);
    like($err14, qr/almanac-bug\.pl \(file \| update \| append \| set-status\)/, 'AC10: names almanac-bug.pl verbs');
    like($err14, qr/almanac-todo\.pl, almanac-note\.pl, almanac-task\.pl, almanac-decision\.pl/,
        'AC10: names the other scripts');
    like($err14, qr/use absolute paths instead of cd/, 'AC10: tells the caller to use absolute paths instead of cd');
}

# =============================================================================
# AC11 (DC3) -- behavior 15: unresolvable targets fail open.
# =============================================================================
{
    assert_allow_bash(q{rm "$D/a.md"}, 'AC11: rm "$D/a.md" (store segment hidden behind a variable)');
    assert_allow_bash('rm .ccpraxis-local-data/$SUB/a.md', 'AC11: rm .ccpraxis-local-data/$SUB/a.md');
}

# =============================================================================
# AC12 (DC2) -- behavior 16: reads are allowed.
# =============================================================================
{
    assert_allow_bash("cat $R", 'AC12: cat R');
    assert_allow_bash('grep -r x /c/P/.ccpraxis-local-data/almanac', 'AC12: grep -r over the almanac store');
    assert_allow_bash("head $T", 'AC12: head T');
    assert_allow_bash('ls /c/P/.ccpraxis-local-data/bug-reports', 'AC12: ls bug-reports dir');
    assert_allow_bash("cp $R /tmp/r.md", 'AC12: cp R /tmp/r.md (store is the copy SOURCE)');
    assert_allow_bash(qq{perl -ne 'print' $R}, 'AC12: perl -ne \'print\' R (read-only one-liner)');
    assert_allow_bash(q{python -c "print(open('/c/P/.ccpraxis-local-data/bug-reports/a.md').read())"},
        'AC12: python -c read-only one-liner');
    assert_allow_bash("cat $R > /tmp/out.md", 'AC12: cat R > /tmp/out.md (redirect target outside any store)');
}

# =============================================================================
# AC13 (DC2) -- behavior 17: sanctioned scripts allowed; heredoc bodies
# invisible; a script invocation that ALSO raw-writes is still denied.
# =============================================================================
{
    assert_allow_bash('perl /c/x/plugins/almanac/scripts/almanac-bug.pl set-status 20260813-010203-abcd --to taken',
        'AC13: sanctioned set-status invocation');

    my $heredoc1 = "perl /c/x/plugins/almanac/scripts/almanac-note.pl edit n1 --content - <<'EOF'\n"
                 . "rm /c/P/.ccpraxis-local-data/bug-reports/a.md\n"
                 . "EOF\n";
    assert_allow_bash($heredoc1, 'AC13: a heredoc body quoting a blocked rm is invisible to both parsers');

    my $heredoc2 = qq{perl /c/x/plugins/almanac/scripts/almanac-bug.pl file --title "x" --body - <<'EOF'\n}
                 . q{python -c "open('/c/P/.ccpraxis-local-data/bug-reports/a.md','w')"} . "\n"
                 . "EOF\n";
    assert_allow_bash($heredoc2, 'AC13: a heredoc body quoting a write one-liner is invisible to both parsers');

    assert_deny_bash("perl /c/x/plugins/almanac/scripts/almanac-bug.pl list > $R",
        'AC13: a sanctioned script invocation that ALSO redirects to R is still denied');
}

# =============================================================================
# AC14 (DC3) -- behavior 18: unrelated commands, including ones mentioning a
# marker, are never denied.
# =============================================================================
{
    assert_allow_bash('git status', 'AC14: git status');
    assert_allow_bash('echo hi > /tmp/x', 'AC14: echo hi > /tmp/x');
    assert_allow_bash('rm -rf /tmp/build', 'AC14: rm -rf /tmp/build');
    assert_allow_bash('sed -i s/a/b/ /c/P/src/x.rs', 'AC14: sed -i on an ordinary source file');
    assert_allow_bash('echo x > /c/P/.ccpraxis-local-data/blueprints/b/ledger.md',
        'AC14: write into blueprints/ (container, not a store)');
    assert_allow_bash('rm /c/P/.ccpraxis-local-data/guidance/g.md', 'AC14: rm a guidance file (not a store)');
    assert_allow_bash('cp x.md /c/P/.ccpraxis-local-data/', 'AC14: cp into the bare container (not a store root)');
    assert_allow_bash('mkdir -p /c/P/.ccpraxis-local-data/almanac/todo', 'AC14: mkdir -p is exempt (fixture setup)');
    assert_allow_bash('rm /c/P/bug-reports/a.md', 'AC14: right name, wrong place (no .ccpraxis-local-data ancestor)');
}

# =============================================================================
# AC15 (DC1 cost) -- prefilter: a marker-free command spawns no perl at all;
# a marker-bearing command does.
# =============================================================================
{
    my $stubdir = tempdir(CLEANUP => 1);
    $stubdir =~ s{\\}{/}g;
    my $sentinel  = "$stubdir/sentinel-marker.txt";
    my $stub_perl = "$stubdir/perl";
    open(my $sfh, '>', $stub_perl) or die "cannot write $stub_perl: $!";
    print {$sfh} "#!/usr/bin/env bash\ntouch \"$sentinel\"\nexit 0\n";
    close $sfh;
    chmod 0755, $stub_perl;

    unlink $sentinel if -e $sentinel;
    my $path_with_stub = "$stubdir:" . ($ENV{PATH} // '');

    fire_bash("echo x > $R", env => { PATH => $path_with_stub });
    my $control_fired = -e $sentinel;
    unlink $sentinel if -e $sentinel;

    SKIP: {
        skip 'AC15: this host does not let a stub "perl" shadow the real one on PATH (control did not fire it)', 1
            unless $control_fired;
        fire_bash('git status', env => { PATH => $path_with_stub });
        ok(!-e $sentinel, 'AC15: a marker-free Bash command spawns no perl process at all');
    }
}

# =============================================================================
# AC16 (DC4) -- butler absent: the guard degrades to rule I only.
# =============================================================================
{
    my $noButlerRoot = tempdir(CLEANUP => 1);
    $noButlerRoot =~ s{\\}{/}g;
    my $almDir = "$noButlerRoot/almanac/hooks";
    File::Path::make_path($almDir);
    my $copy = "$almDir/guard-almanac-write.sh";
    {
        my $bytes = slurp_raw($GUARD);
        open(my $dst, '>:raw', $copy) or die "cannot write $copy: $!";
        print {$dst} $bytes;
        close $dst;
    }
    chmod 0755, $copy;
    ok(!-d "$noButlerRoot/butler", 'AC16 fixture: no ../../butler sibling exists next to the copy');

    assert_allow_bash("sed -i s/a/b/ $R", 'AC16: butler absent -- sed -i on R allows', guard => $copy);
    assert_allow_bash("rm $T", 'AC16: butler absent -- rm T allows', guard => $copy);
    assert_deny_bash(q{python -c "open('/c/P/.ccpraxis-local-data/bug-reports/a.md','w').write('x')"},
        'AC16: butler absent -- the python one-liner still denies (rule I needs no butler)', guard => $copy);
    my ($rc_e) = fire_edit($R, guard => $copy);
    is($rc_e, 2, 'AC16: butler absent -- Edit on R still denies (Edit path never depended on butler)');
}

# =============================================================================
# AC17 (DC4) -- butler present, BP_* removed: the in-repo hook still denies.
# =============================================================================
{
    assert_deny_bash('sed -i s/a/b/ ' . $R,
        'AC17: butler present, every BP_* var removed -- sed -i on R still denies');
}

# =============================================================================
# AC18 (DC4) -- parser canary: hyg_targets's public shape is pinned, so a
# butler-internal rename/refactor fails this test loudly instead of silently
# degrading the guard to AC16's (butler-absent) mode.
# =============================================================================
{
    my $gb = "$H/../../butler/scripts/BpHook/Guards/GuardBash.pm";
    ok(-f $gb, 'AC18 fixture: GuardBash.pm exists at the sibling path the guard will require')
        or BAIL_OUT('GuardBash.pm missing -- cannot run the parser canary');
    my $loaded = eval { require $gb; 1 };
    ok($loaded, 'AC18: GuardBash.pm requires cleanly') or diag("load error: $@");
    ok(defined &BpHook::Guards::GuardBash::hyg_targets, 'AC18: hyg_targets is defined');

    SKIP: {
        skip 'AC18: hyg_targets is not defined, cannot canary its return shape', 3
            unless defined &BpHook::Guards::GuardBash::hyg_targets;
        my @t = eval { BpHook::Guards::GuardBash::hyg_targets('rm /x/y', Time::HiRes::time() + 3) };
        is(scalar(@t), 1, "AC18: hyg_targets('rm /x/y') returns exactly one entry") or diag("error: $@");
        is($t[0]{kind}, 'delete', 'AC18: ...its kind is "delete"') if @t;
        is($t[0]{word}{literal}, '/x/y', 'AC18: ...its word->{literal} is "/x/y"') if @t && ref $t[0]{word} eq 'HASH';
    }
}

# =============================================================================
# AC19 (no regression) -- fail-open on junk Bash payloads.
# =============================================================================
{
    my ($rc1, $out1, $err1) = fire_payload($GUARD,
        '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{}}');
    is($rc1, 0, 'AC19: tool_input {} allows'); is($out1, '', '...stdout empty'); is($err1, '', '...stderr empty');

    my ($rc2, $out2, $err2) = fire_payload($GUARD,
        { hook_event_name => 'PreToolUse', tool_name => 'Bash', tool_input => { command => '' } });
    is($rc2, 0, 'AC19: command "" allows'); is($out2, '', '...stdout empty'); is($err2, '', '...stderr empty');

    my ($rc3, $out3, $err3) = fire_payload($GUARD,
        '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":["rm","R"]}}');
    is($rc3, 0, 'AC19: a non-string command (array) allows'); is($out3, '', '...stdout empty'); is($err3, '', '...stderr empty');

    my ($rc4, $out4, $err4) = fire_payload($GUARD,
        '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"rm /c/P/.ccpraxis-local-data/bug-rep');
    is($rc4, 0, 'AC19: truncated JSON containing a marker allows'); is($out4, '', '...stdout empty'); is($err4, '', '...stderr empty');
}

# =============================================================================
# AC20 -- no trace: the fresh HOME tempdir is still empty, and the fictional
# fixture roots were never created on disk.
# =============================================================================
{
    opendir(my $dh, $FRESH_HOME) or die "cannot open $FRESH_HOME: $!";
    my @entries = grep { $_ ne '.' && $_ ne '..' } readdir($dh);
    closedir $dh;
    is(scalar(@entries), 0, 'AC20: the fresh HOME tempdir is still empty after every fire')
        or diag(join(', ', @entries));

    for my $p ('/c/P', '/c/H') {
        ok(!-e $p, "AC20: the fictional fixture root $p was never created on disk");
    }
}

# =============================================================================
# AC22 (DC5) -- bash -n passes on the guard.
# =============================================================================
{
    my $rc = system(qq{bash -n "$GUARD"});
    is($rc >> 8, 0, 'AC22: bash -n on guard-almanac-write.sh exits 0');
}

# AC21 (DC5, regression on write-guard.t and almanac-write-guard-all-stores.t)
# is verified by running those two files directly, unmodified; it has no
# assertion of its own in this file.

# =============================================================================
# FIX-BATCH 13 regression coverage (post review+red-team, 2026-10-01T02:34:32Z).
# Items 1-10 below pin the ~13 bypass commands the fix-batch closed, plus the
# controls that must stay allowed, so none of them can silently regress.
# =============================================================================

# ---- Item 1 (red-team B2/M1, review M1): interpreter detection must fire
# after an unquoted shell metacharacter boundary, not just whitespace. -------
{
    assert_deny_bash(qq{true;python -c "open('$R','w').write('x')"},
        'FB1a: true;python -c "..." (semicolon-glued interpreter)');
    assert_deny_bash(qq{(python -c "open('$R','w').write('x')")},
        'FB1b: (python -c "...") (paren-wrapped interpreter)');
    assert_deny_bash(qq{echo `perl -e 'unlink "$R"'`},
        'FB1c: backtick-wrapped perl -e \'...\'');
    assert_deny_bash(qq{echo \$(python -c "open('$R','w').write('x')")},
        'FB1d: echo \$(python -c "...") (command-substitution-wrapped interpreter)');
    assert_deny_bash(qq{true|perl -e 'unlink "$R"'},
        'FB1e: true|perl -e \'unlink ...\' (pipe-glued interpreter)');
}

# ---- Item 2 (red-team B1): the cheap prefilter must not be fooled by a
# glob or quote-split store path -- the store LEAF NAME stays intact. -------
{
    assert_deny_bash('rm .ccpraxis-*/bug-reports/a.md', 'FB2a: rm with a glob root (.ccpraxis-*/bug-reports/a.md)');
    assert_deny_bash('rm ".ccpraxis-local-"data/bug-reports/a.md', 'FB2b: rm with a quote-split root literal');
    assert_deny_bash('rm ~/.claude/claude-*-vault/almanac/todo/t.md', 'FB2c: rm with a glob inside claude-*-vault');
}

# ---- Item 3 (review M1 / red-team M1): more interpreter forms. -------------
{
    assert_deny_bash(qq{perl -I lib -e 'unlink "$R"'}, 'FB3a: perl -I lib -e \'...\' (value-taking flag before -e)');
    assert_deny_bash(qq{python3 -c"open('$R','w').write('x')"}, 'FB3b: python3 -c"..." (no space before the quote)');
    assert_deny_bash(qq{powershell -c "Remove-Item $T"}, 'FB3c: powershell -c "Remove-Item ..."');
}

# ---- Item 4 (red-team M2): env -C <store-dir> hides a relative write behind
# a changed effective cwd that GuardBash itself never reports as a cd. ------
{
    assert_deny_bash('env -C .ccpraxis-local-data/bug-reports rm a.md',
        'FB4: env -C .ccpraxis-local-data/bug-reports rm a.md');
}

# ---- Item 5 (red-team M4): cp -r of an EXTERNAL directory whose own name is
# a store leaf, landing its whole contents inside the container. Control:
# copying a plain file into some OTHER subdirectory of the container must
# stay allowed (the destination is not the container root itself, and the
# source names no store leaf). -----------------------------------------------
{
    assert_deny_bash('cp -r /tmp/evil/bug-reports .ccpraxis-local-data/',
        'FB5a: cp -r external .../bug-reports into the container root');
    assert_allow_bash('cp x.md .ccpraxis-local-data/some-other-dir/',
        'FB5b (control): cp a plain file into an unrelated container subdir stays allowed');
}

# ---- Item 6 (review S1): a here-string / arithmetic-shift must not be
# mistaken for a heredoc opener, which would otherwise swallow a LATER line
# (here, a python one-liner write) as a fake heredoc body. ------------------
{
    my $hereStringThenWrite = "cat <<< hi\n" . qq{python -c "open('$R','w').write('x')"};
    assert_deny_bash($hereStringThenWrite,
        'FB6: cat <<< hi (here-string) then a python write on the next line still denies');
}

# ---- Item 7 (review S2): the deny message interpolates the ACTUAL report
# id in the Bash set-status line, never the literal text "$ID". -------------
{
    my (undef, undef, $err7) = assert_deny_bash("rm $R", 'FB7: rm R (bug kind via Bash) carries the set-status line');
    like($err7, qr/set-status 20260813-010203-abcd --to <state>/,
        'FB7: the set-status line interpolates the actual report id');
    unlike($err7, qr/\$ID\b/, 'FB7: the literal text "$ID" never appears in the denial');
}

# ---- Item 8 (review S3, Decision 41): Rule E narrows to the cd's OWN
# target -- a store path merely mentioned elsewhere (a read) must not deny,
# while cd-ing INTO a store or its container, then writing relatively,
# still must. -----------------------------------------------------------------
{
    assert_allow_bash("cd /tmp && echo x > out.txt && cat $R",
        'FB8a: cd /tmp && ... && cat <store-path> allows (store only read, cd target is /tmp)');
    assert_allow_bash("cd build && make > log.txt; ls $T",
        'FB8b: cd build && ... ; ls <store-path> allows (store only read, cd target is build)');
    assert_deny_bash('cd /c/P/.ccpraxis-local-data/almanac/todo && rm a.md',
        'FB8c: cd <store-path> && rm a.md still denies');
    assert_deny_bash('cd /c/P/.ccpraxis-local-data && rm -rf bug-reports',
        'FB8d: cd <container-path> && rm -rf bug-reports still denies');
}

# ---- Item 9 (red-team B1, overlaps item 2): quote-split directory name
# resolving to the real store path. One assertion suffices (FB2b above
# already covers this exact shape). ------------------------------------------
# (covered by FB2b)

# ---- Item 10 (fix-batch note, unresolved at hand-off): does the widened
# prefilter/classifier catch a store-path substring that appears ONLY in the
# payload's top-level `cwd` field, when the CURRENT command text carries no
# marker at all (simulating "a prior Bash call already cd'd here")? Direct,
# isolated test, not inferred from any other assertion.
# =============================================================================
{
    my ($rc10, $out10, $err10) = fire_bash('rm a.md', cwd => '/c/P/.ccpraxis-local-data/bug-reports');
    if ($rc10 == 2) {
        pass('ITEM10 RESOLVED: payload cwd alone (store substring), command text carries no marker -- still denies. '
             . 'The widened Stage 1b prefilter reads cwd too, and the classifier resolves the relative literal '
             . 'against cwd, so this closes item 10 as a non-gap.');
        like($err10, qr/^BLOCKED:/, 'ITEM10: the deny message starts BLOCKED:');
    } else {
        fail("ITEM10 LIVE GAP: payload cwd alone containing a store-path substring, with no marker anywhere in "
             . "the command text, did NOT deny (rc=$rc10, out=[$out10], err=[$err10]). The cwd-persistence "
             . "question from the fix-batch note is UNRESOLVED -- this is a real coverage gap for the driver to "
             . "scope, not something to patch from this test file.");
    }
}

# =============================================================================
# FIX-BATCH 13 ROUND 4 (Decision 43: round 3 shipped these fixes with zero new
# assertions -- assertion count unchanged at 249 -- so every fix in this batch
# must ship pinned here, failing-first against the guard as it stands now.
# =============================================================================

# ---- FB11 (Decision 43, "ordinary-shape, not descoped"): a newline is a
# statement separator just like ';' or '&&' -- a cd on one line and a
# marker-free relative write on a LATER line must still deny. -----------------
{
    assert_deny_bash("set -e\ncd .ccpraxis-local-data/bug-reports\nrm a.md",
        'FB11a: set -e NL cd <container>/bug-reports NL rm a.md (newline-separated cd then write)');
    assert_deny_bash("true\ncd .ccpraxis-local-data/bug-reports\nrm a.md",
        'FB11b: true NL cd <container>/bug-reports NL rm a.md (newline-separated cd then write)');
}

# ---- FB12 (Decision 43; the exact "if cd ...; then rm ...; fi" shape has
# been named twice by red-team -- pinned here by name): if/elif/while/until
# are shell keywords, not commands to skip over when looking for a cd whose
# OWN target is a store path. --------------------------------------------------
{
    assert_deny_bash('if cd .ccpraxis-local-data/bug-reports; then rm a.md; fi',
        'FB12a: if cd <container>/bug-reports; then rm a.md; fi (red-team-named shape, pinned)');
    assert_deny_bash('if false; then true; elif cd .ccpraxis-local-data/bug-reports; then rm a.md; fi',
        'FB12b: if false; then true; elif cd <container>/bug-reports; then rm a.md; fi');
    assert_deny_bash('while cd .ccpraxis-local-data/bug-reports; do rm a.md; break; done',
        'FB12c: while cd <container>/bug-reports; do rm a.md; break; done');
}

# ---- FB13 (Decision 43): a cd target written with Windows backslashes (the
# same fixture root AC8 already uses for a bare rm, as a cd target instead). --
{
    assert_deny_bash(q{cd "C:\P\.ccpraxis-local-data\bug-reports" && rm a.md},
        'FB13: cd "C:\\P\\...\\bug-reports" && rm a.md (backslash-path cd target)');
}

# ---- FB14 (Decision 43 over-deny fix): a path that merely contains the word
# "almanac" as an ordinary directory/file name -- not an actual store under
# .ccpraxis-local-data/ or the vault -- must ALLOW. These are realistic
# look-alikes: plugins/almanac is a source directory, not a record store, and
# ~/.claude/almanac-notes.md is an ordinary file whose name happens to start
# with "almanac", not a directory within the almanac RECORD store. ------------
{
    assert_allow_bash('cd plugins/almanac && touch x',
        'FB14a: cd plugins/almanac && touch x (source dir named almanac, not a store -- must allow)');
    assert_allow_bash('cd ~/.claude && rm almanac-notes.md',
        'FB14b: cd ~/.claude && rm almanac-notes.md (ordinary file merely named almanac-*, not a store path -- must allow)');
}

# ---- FB15 (Decision 43: EFFECTIVE_CWD narrowed to exactly two cases --
# regression pins, both already fixed in round 3; confirm neither regressed
# under this round's other changes). ------------------------------------------
{
    # (a) cross-call persistence: payload cwd is already inside a store, the
    # command text itself carries no cd and no marker at all.
    assert_deny_bash('rm a.md', 'FB15a: rm a.md, payload cwd already inside bug-reports (cross-call persistence, no cd in command text)',
        cwd => '/c/P/.ccpraxis-local-data/bug-reports');

    # (b) a simple, non-nested, non-subshell forward cd chain within one line.
    assert_deny_bash('cd .. && cd .ccpraxis-local-data/bug-reports && rm a.md',
        'FB15b: cd .. && cd <container>/bug-reports && rm a.md (simple forward cd chain, one line, no subshell)',
        cwd => '/c/P/.ccpraxis-local-data/almanac');
}

# =============================================================================
# FIX-BATCH 13 ROUND 5 (review-4 and redteam-4 independently converged on the
# same two MUST-FIXes in resolve_cd_chain; validated on a scratch copy there,
# pinned here failing-first against the guard as it stands now).
# =============================================================================

# ---- MF1 (review-4/redteam-4): a glob or brace cd target that names only the
# container, joined via EFFECTIVE_CWD against a later relative write, must
# still deny. cd_target_is_marker already tolerates glob (FB14), but the
# EFFECTIVE_CWD join classifies with $allow_glob = 0 regardless, so a glob
# segment that came from the cd target never matches the store sequence. ------
{
    assert_deny_bash('cd .ccpraxis-* && rm bug-reports/a.md',
        'MF1a: cd .ccpraxis-* && rm bug-reports/a.md (star-glob cd target joined with relative write)');
    assert_deny_bash("cd .ccpraxis-*\ncd bug-reports\nrm a.md",
        'MF1b: cd .ccpraxis-* NL cd bug-reports NL rm a.md (star-glob cd target, two-step chain)');
    assert_deny_bash('cd .ccpraxis-local-dat? && rm almanac/note/x.md',
        'MF1c: cd .ccpraxis-local-dat? && rm almanac/note/x.md (?-glob cd target)');
    assert_deny_bash('cd .ccpraxis-{local-data,x} && rm bug-reports/a.md',
        'MF1d: cd .ccpraxis-{local-data,x} && rm bug-reports/a.md (brace cd target)');

    # Over-deny guard: a glob cd target that does NOT resolve to the real
    # store must still allow.
    assert_allow_bash('cd plugins/* && rm x.md',
        'MF1e: cd plugins/* && rm x.md (glob cd target unrelated to the store -- must allow)');
}

# ---- MF2 (review-4/redteam-4): resolve_cd_chain (:494) still deletes
# backslashes wholesale (tr/\x27"\\//d), the pre-FB13 behavior. FB13 only
# fixed cd_target_is_marker (:437); a quoted Windows-style cd target used for
# the EFFECTIVE_CWD join still collapses into one run-on segment with no
# separators, so the store sequence never forms. --------------------------------
{
    assert_deny_bash(q{cd "C:\P\.ccpraxis-local-data" && rm bug-reports/a.md},
        'MF2a: cd "C:\\P\\.ccpraxis-local-data" && rm bug-reports/a.md (backslash container cd target joined with relative write)');
    assert_deny_bash(q{cd "C:\P\.ccpraxis-local-data" && rm -rf almanac},
        'MF2b: cd "C:\\P\\.ccpraxis-local-data" && rm -rf almanac (backslash container cd target, rm -rf of almanac)');
    assert_deny_bash(q{cd "C:\P\.ccpraxis-local-data"}
        . qq{\ncd bug-reports\nrm a.md},
        'MF2c: cd "C:\\P\\.ccpraxis-local-data" NL cd bug-reports NL rm a.md (backslash container cd target, two-step chain)');

    # Over-deny guard: a backslash cd target that is NOT the store must still
    # allow.
    assert_allow_bash(q{cd "C:\P\plugins\almanac" && touch x},
        'MF2d: cd "C:\\P\\plugins\\almanac" && touch x (backslash path unrelated to the store -- must allow)');
}

# ---- Decision 43's accepted residual risk is deliberately NOT tested here:
# subshell-scoped cd (e.g. "(cd /tmp); rm a.md"), cd -, pushd/popd, and a
# write placed before a later cd in the same compound command. Properly
# simulating those is writing a small shell interpreter, which the decision
# rules disproportionate for a defense-in-depth guard already backed by
# package 12's ticket identity and package 14's tamper check. No assertion
# should be added for them in future rounds either, absent a new decision.
# =============================================================================

done_testing();
