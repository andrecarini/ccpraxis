#!/usr/bin/env perl
# b12-ledger-write-integrity oracle. Derived ONLY from
# .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/specs/b12-ledger-write-integrity-spec.md
# §2 (contracts), §3 (behaviours B1..B26), §4 (AC-1..AC-39) and §5 (edge cases E1..E12).
#
# WRITTEN BLIND TO ANY IMPLEMENTATION. plugins/butler/hooks/ledger-guard.sh does not exist at the
# time this file was authored, and hooks.json carries no ledger-guard entry. Every AC assertion
# below must therefore fail on MISSING BEHAVIOUR (the hook binary is absent -> bash exits 127 with
# a "No such file or directory" message), never on a perl/harness bug of this file. The handful of
# assertions labelled FIXTURE-SANITY: are deliberate harness self-checks and are expected to pass
# even with the hook absent -- they are the evidence that the red below is attributable to the
# missing hook and not to broken scaffolding.
#
# HARNESS RULES (carried over from the spec §4.3 and from the drained step-3 run, not re-derived):
#   * %CLEAN_ENV strips EVERY ambient BP_*. This suite is run BY coordinator sessions that export
#     BP_LEDGER/BP_DIR/BP_PROJECT_ROOT; an inherited value silently turns AC-1 ("inert outside a
#     coordinator session") into a FALSE PASS.
#   * run_hook writes the payload to a temp file and runs `timeout 60 bash "$HOOK" < payload 2>&1`.
#     Invoking via `bash` (never by executing the file directly) means a missing exec bit cannot
#     produce a false red.
#   * done_testing(), NOT a hand-counted `plan tests => N`. A hardcoded plan count is exactly what
#     makes 62-repeat-guard.t brittle (:39) and is half of the blocker this package already carries.
#   * ALL fixtures are SYNTHESIZED under File::Temp. No live ledger under
#     .ccpraxis-local-data/blueprints/*/packages/ is read, and above all none is written -- those
#     are live orchestration state for a running fleet.
#   * Output is captured via a temp file / pipe, never by reopening STDOUT onto an in-memory scalar
#     (Git-for-Windows perl fails there with "Bad file descriptor"; project CLAUDE.md landmine).
#   * Never shell out to rg: ripgrep is .gitignore-aware and returns a FALSE CLEAN for anything
#     under .ccpraxis-local-data/.
#
# NO `use utf8` HERE, DELIBERATELY. Non-ASCII literals below (em dash, ellipsis) are byte strings,
# so JSON::PP emits them as the raw UTF-8 bytes a real ledger carries, and the guard sees bytes --
# matching spec §2.4 ("all regexes are byte regexes") and E12.
#
# RULED DEVIATIONS (settled by the coordinator; recorded here, not re-litigated):
#   * AC-38 ("this file exits 0 with zero not ok") is self-referential and untestable from inside
#     this file. The coordinator judges it. There is deliberately no AC-38 block below.
#   * AC-23: with a CONSTANT new_string and the prefix/\b section patterns of §2.4, a one-of-two
#     context break is reachable only via the frontmatter. The block below therefore breaks the
#     frontmatter `status:` value rather than a `## Outputs` heading. The two BINDING assertions
#     (replace_all=true -> RC 2, byte-identical payload with replace_all=false -> RC 0) are
#     unaffected.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP;

(my $HOOKS = "$Bin/../../hooks") =~ s{\\}{/}g;
my $HOOK      = "$HOOKS/ledger-guard.sh";
my $HOOKSJSON = "$HOOKS/hooks.json";
my $SELFTEST_T = "$Bin/14-hooks-selftest.t";

my $J    = JSON::PP->new->canonical;
my $ROOT = tempdir(CLEANUP => 1);
my $pn   = 0;
my $bpn  = 0;

my $have_jq = do { my $o = `bash -c 'command -v jq' 2>/dev/null`; $o =~ /\S/ ? 1 : 0 };

sub fwd { (my $p = shift) =~ s{\\}{/}g; $p }

# A hook test must control the hook's environment COMPLETELY (62-repeat-guard.t:54-58).
my %CLEAN_ENV = map { ($_ => $ENV{$_}) } grep { !/^BP_/ } keys %ENV;

sub realpath_m {
    my ($p) = @_;
    local %ENV = (%CLEAN_ENV, P => $p);
    open(my $f, '-|', 'bash', '-c', 'realpath -m "$P"') or die "bash: $!";
    my $o = do { local $/; <$f> }; close $f; $o =~ s/\s+\z//; return $o;
}

diag("subject under test: $HOOK "
     . (-e $HOOK
        ? "(present)"
        : "(ABSENT -- every AC assertion below is expected to fail on MISSING BEHAVIOUR)"));

# =====================================================================================
# Scaffolding
# =====================================================================================

sub write_file {
    my ($path, $bytes) = @_;
    open my $w, '>', $path or die "write $path: $!";
    binmode $w;
    print $w $bytes;
    close $w;
}

sub read_file {
    my ($path) = @_;
    open my $r, '<', $path or die "read $path: $!";
    binmode $r;
    my $c = do { local $/; <$r> }; close $r;
    return defined $c ? $c : '';
}

# A blueprint dir + a separate project root, both realpath-normalised.
sub mk_bp {
    my $n = ++$bpn;
    my $d = "$ROOT/bp$n";
    mkdir $d or die "mkdir $d: $!";
    mkdir "$d/$_" or die "mkdir $d/$_: $!" for qw(packages reports specs runs);
    my $p = "$ROOT/proj$n";
    mkdir $p or die "mkdir $p: $!";
    mkdir "$p/src" or die "mkdir $p/src: $!";
    return (realpath_m(fwd($d)), realpath_m(fwd($p)));
}

sub env_for {
    my ($bp, $proj) = @_;
    return (BP_DIR         => $bp,
            BP_PROJECT_ROOT=> $proj,
            BP_LEDGER      => "$bp/packages/fixture-pkg.md",
            BP_PACKAGE     => 'fixture-pkg');
}

sub ledger_path { my ($bp) = @_; return "$bp/packages/fixture-pkg.md" }

# payload -> temp file -> `timeout 60 bash "$HOOK" < payload 2>&1`; returns (rc, combined output).
# `timeout` is a safety net only: no assertion below depends on it, but a hook that hangs must not
# hang this suite. Exit 124 would mean the bound was hit.
sub run_hook {
    my ($payload, %env) = @_;
    my $pf = "$ROOT/payload." . (++$pn) . ".json";
    write_file($pf, $payload);
    local %ENV = (%CLEAN_ENV, %env, HOOKPATH => fwd($HOOK), PFILE => fwd($pf));
    open(my $f, '-|', 'bash', '-c', 'timeout 60 bash "$HOOKPATH" < "$PFILE" 2>&1') or die "bash: $!";
    binmode $f;
    my $o = do { local $/; <$f> }; close $f;
    return ($? >> 8, defined $o ? $o : '');
}

# --- payload builders ---------------------------------------------------------------
sub jtrue  { return JSON::PP::true }
sub jfalse { return JSON::PP::false }

sub pl_write {
    my ($path, $content) = @_;
    return $J->encode({ tool_name => 'Write', cwd => '/project',
                        tool_input => { file_path => $path, content => $content } });
}
sub pl_write_raw {   # for the "content absent / wrong type" cases
    my ($path, %ti) = @_;
    return $J->encode({ tool_name => 'Write', cwd => '/project',
                        tool_input => { file_path => $path, %ti } });
}
sub pl_edit {
    my ($path, $old, $new, $replace_all) = @_;
    return $J->encode({ tool_name => 'Edit', cwd => '/project',
                        tool_input => { file_path => $path, old_string => $old,
                                        new_string => $new,
                                        replace_all => ($replace_all ? jtrue() : jfalse()) } });
}
sub pl_multiedit {
    my ($path, $edits) = @_;   # $edits: arrayref (or scalar/undef for the malformed cases)
    my %ti = (file_path => $path);
    $ti{edits} = $edits if defined $edits;
    return $J->encode({ tool_name => 'MultiEdit', cwd => '/project', tool_input => \%ti });
}

# --- fixture text helpers -----------------------------------------------------------
sub to_lines   { my @l = split /\n/, $_[0], -1; pop @l; return @l }   # content always ends in \n
sub from_lines { return join("\n", @_) . "\n" }

sub drop_line {                       # remove the FIRST line exactly equal to $text
    my ($s, $text) = @_;
    my @l = to_lines($s);
    for my $i (0 .. $#l) { if ($l[$i] eq $text) { splice(@l, $i, 1); return from_lines(@l) } }
    die "drop_line: no line exactly equal to '$text' in the fixture";
}
sub sub_line {                        # replace the FIRST line exactly equal to $from with $to
    my ($s, $from, $to) = @_;
    my @l = to_lines($s);
    for my $i (0 .. $#l) { if ($l[$i] eq $from) { $l[$i] = $to; return from_lines(@l) } }
    die "sub_line: no line exactly equal to '$from' in the fixture";
}
sub insert_line_at {                  # $text becomes line $n (1-based)
    my ($s, $n, $text) = @_;
    my @l = to_lines($s);
    die "insert_line_at: fixture has only " . scalar(@l) . " lines, cannot insert at $n"
        if $n < 1 || $n > @l + 1;
    splice(@l, $n - 1, 0, $text);
    return from_lines(@l);
}
sub inject_byte_at_line {             # put $byte in the middle of line $n (1-based)
    my ($s, $n, $byte) = @_;
    my @l = to_lines($s);
    die "inject_byte_at_line: fixture has only " . scalar(@l) . " lines, cannot inject at $n"
        if $n < 1 || $n > @l;
    my $mid = int(length($l[$n - 1]) / 2);
    substr($l[$n - 1], $mid, 0) = $byte;
    return from_lines(@l);
}
sub count_occ {
    my ($hay, $needle) = @_;
    return 0 if !length $needle;
    my ($n, $pos) = (0, 0);
    while ((my $i = index($hay, $needle, $pos)) >= 0) { $n++; $pos = $i + length($needle) }
    return $n;
}
sub apply_once {
    my ($hay, $old, $new) = @_;
    my $i = index($hay, $old);
    die "apply_once: old_string not found" if $i < 0;
    substr($hay, $i, length($old)) = $new;
    return $hay;
}

# --- the known-good fixture (spec §4.3: 11-line frontmatter, real section headings, and NEVER a
#     bare `## Escalation`; 30/32 of the live corpus spell it `## Escalation (when status:
#     blocked)`). Padded past 200 lines so AC-15's line-200 insertion is a real body position, as
#     real ledgers are 300-500 lines. Line 12 is a non-blank body line so AC-5's "NUL inside line
#     12" is meaningful.
my $ESC_HEADING = '## Escalation (when status: blocked)';

sub kg {
    my (%o) = @_;
    my $status = defined $o{status} ? $o{status} : 'running';
    my @L;
    push @L, '---';                                                                    #  1
    push @L, 'package: fixture-pkg';                                                   #  2
    push @L, 'blueprint: sandbox-butler-overhaul';                                     #  3
    push @L, "status: $status";                                                        #  4
    push @L, 'model: opus';                                                            #  5
    push @L, 'max_turns: 90';                                                          #  6
    push @L, 'write_set: plugins/butler/hooks/ledger-guard.sh:plugins/butler/hooks/hooks.json'; # 7
    push @L, 'test_paths: plugins/butler/tests/t/64-ledger-guard.t';                   #  8
    push @L, 'mandated_means: []';                                                     #  9
    push @L, 'last_updated: 2026-07-29T19:22:00Z';                                     # 10
    push @L, '---';                                                                    # 11
    push @L, '# Package fixture-pkg — synthesized ledger fixture for 64-ledger-guard.t'; # 12
    push @L, '';                                                                       # 13
    push @L, '> **Medical chart, not a diary.** Update BEFORE risky steps and AFTER every result.'; # 14
    push @L, '';                                                                       # 15
    push @L, '## Scope';                                                               # 16
    push @L, '';                                                                       # 17
    push @L, 'A synthesized, byte-realistic stand-in for a package ledger.';           # 18
    push @L, '';                                                                       # 19
    push @L, '## Next action';                                                         # 20
    push @L, '';                                                                       # 21
    push @L, 'Dispatch the implementer for ledger-guard.sh.';                          # 22
    push @L, '';                                                                       # 23
    push @L, '## Pipeline';                                                            # 24
    push @L, '';                                                                       # 25
    push @L, '- [x] 1. Scout';                                                         # 26
    push @L, '- [x] 2. Spec';                                                          # 27
    push @L, '- [ ] 3. Tests written from spec';                                       # 28
    push @L, '';                                                                       # 29
    push @L, '## Decisions & attempt log';                                             # 30
    push @L, '';                                                                       # 31
    for my $i (1 .. 180) {                                                             # 32..211
        push @L, sprintf('- 2026-07-29T19:%02d:00Z — attempt-log filler entry %03d, kept so the fixture is byte-realistic in length.', $i % 60, $i);
    }
    push @L, '';                                                                       # 212
    push @L, '## Outputs';                                                             # 213
    push @L, '';                                                                       # 214
    push @L, '- fixture artifact -- present';                                          # 215
    push @L, '';                                                                       # 216
    push @L, $ESC_HEADING;                                                             # 217
    push @L, '';                                                                       # 218
    push @L, '_(none)_';                                                               # 219
    return from_lines(@L);
}

my @HEADINGS = ('## Next action', '## Decisions & attempt log', '## Pipeline', '## Outputs', $ESC_HEADING);
my @STATUSES = qw(pending running converging reviewing done blocked parked);

# NUL-bearing content used by every "this would be blocked if it were in scope" assertion.
sub nul_ledger { return inject_byte_at_line(kg(), 12, "\x00") }

# PATH containing every executable on the ambient PATH EXCEPT $name (62-repeat-guard.t:392-410).
sub path_without {
    my ($name) = @_;
    my $d = "$ROOT/no-$name-bin";
    return fwd($d) if -d $d;
    mkdir $d or die "mkdir $d: $!";
    my %seen;
    for my $dir (split(/:/, ($CLEAN_ENV{PATH} // '')), '/usr/bin', '/bin', '/usr/local/bin') {
        next unless length $dir && -d $dir;
        opendir(my $dh, $dir) or next;
        for my $f (readdir $dh) {
            next if $f eq $name || $f =~ /^\./;
            next if $seen{$f}++;
            my $src = "$dir/$f";
            next unless -f $src && -x $src;
            symlink($src, "$d/$f");
        }
        closedir $dh;
    }
    return fwd($d);
}

sub nonblank_lines { return grep { /\S/ } split /\n/, $_[0] }

# =====================================================================================
# FIXTURE SANITY -- these must pass with or without the hook. They are what proves the
# red below is "hook missing", not "harness broken".
# =====================================================================================
{
    my $kgc = kg();
    my @l = to_lines($kgc);
    ok(scalar(@l) >= 200, 'FIXTURE-SANITY: known-good fixture is >= 200 lines (AC-15 inserts at line 200)');
    is($l[0], '---', 'FIXTURE-SANITY: fixture line 1 is the opening frontmatter delimiter');
    is($l[10], '---', 'FIXTURE-SANITY: fixture line 11 is the closing frontmatter delimiter');
    ok(length($l[11]) > 8, 'FIXTURE-SANITY: fixture line 12 is a non-blank body line (AC-5 injects there)');
    unlike($kgc, qr/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/,
           'FIXTURE-SANITY: known-good fixture carries no control byte');
    unlike($kgc, qr/\r/, 'FIXTURE-SANITY: known-good fixture is LF-only');
    like($kgc, qr/\A---\s*\n(.*?)\n---/s, "FIXTURE-SANITY: fixture matches ledger_fm's own frontmatter regex");
    is(count_occ($kgc, "\n## Escalation"), 1, 'FIXTURE-SANITY: exactly one Escalation heading, and it is the suffixed corpus form');
    unlike($kgc, qr/^## Escalation$/m, 'FIXTURE-SANITY: the fixture never carries a BARE "## Escalation" (30/32 of the live corpus is suffixed)');
    for my $u ('status: running', 'last_updated: 2026-07-29T19:22:00Z',
               'Dispatch the implementer for ledger-guard.sh.',
               '- fixture artifact -- present', '_(none)_', '## Pipeline', '## Next action') {
        is(count_occ($kgc, $u), 1, "FIXTURE-SANITY: '$u' occurs exactly once in the fixture (Edit fixtures rely on uniqueness)");
    }
    is(count_occ($kgc, "\n---\n"), 1, 'FIXTURE-SANITY: only the closing "---" is an interior delimiter line');
    # jq ships in the sandbox container, not on the Windows host. Every
    # hook-behaviour group below already SKIPs without it; this line used to be
    # the one place that turned its absence into a failure. That is a false
    # signal in the worst direction -- it reads as "ledger-guard.sh is broken"
    # when the truth is "ledger-guard.sh was never exercised here". A skip says
    # the second thing, which is what actually happened.
    SKIP: {
        skip 'jq is not installed on this host -- the hook-behaviour groups below are NOT exercised', 1
            unless $have_jq;
        pass('FIXTURE-SANITY: jq is available on this host (hook-behaviour groups will run)');
    }
}

# =====================================================================================
# AC-36 [file] hooks.json registration. Needs no jq and no hook process: it is a pure
# structural oracle over the file. Blocks 1-3 / PostToolUse / Stop must be unchanged.
# =====================================================================================
{
    my $raw = eval { read_file($HOOKSJSON) };
    ok(defined $raw && length $raw, 'AC-36: hooks.json is readable and non-empty') or diag($@ // '');
    my $H = eval { $J->decode($raw // '') };
    ok(defined $H, 'AC-36: hooks.json parses as valid JSON') or diag("parse error: $@");

    my $cmd_of = sub { my $f = shift; return qq(bash "\${CLAUDE_PLUGIN_ROOT}/hooks/$f") };
    my $pre = ($H && $H->{hooks}{PreToolUse}) // [];
    # RELAXED 2026-08-03 (b15-wait-shape-and-pipe-guards, operator-approved).
    #   OLD: is(scalar(@$pre), 4, 'AC-36: PreToolUse still has exactly 4 blocks');
    #   NEW: the >= form below.
    # Same reasoning as the sibling relax in t/62-repeat-guard.t. b12's own
    # registration remains pinned exactly by the assertions immediately below —
    # block 0's command list is_deeply [gate-shutdown, guard-writes, ledger-guard]
    # IN THAT ORDER, and block 0 has exactly 3 entries — so a missing, renamed or
    # reordered ledger-guard.sh still fails. Only the prohibition on appending a
    # NEW block is lifted.
    cmp_ok(scalar(@$pre), '>=', 4, 'AC-36: PreToolUse still has at least the 4 pre-b15 blocks (later packages may append)');

    my $b0 = $pre->[0] // {};
    is($b0->{matcher}, 'Edit|Write|MultiEdit|NotebookEdit', 'AC-36: block 0 matcher is Edit|Write|MultiEdit|NotebookEdit');
    is_deeply([ map { $_->{command} } @{ $b0->{hooks} // [] } ],
              [ $cmd_of->('gate-shutdown.sh'), $cmd_of->('guard-writes.sh'), $cmd_of->('ledger-guard.sh') ],
              'AC-36: block 0 command list is exactly [gate-shutdown.sh, guard-writes.sh, ledger-guard.sh] IN THAT ORDER');
    my $n = 0;
    for my $h (@{ $b0->{hooks} // [] }) {
        $n++;
        ok(defined($h->{type}) && $h->{type} eq 'command'
           && defined($h->{timeout}) && $h->{timeout} == 15
           && defined($h->{command}) && $h->{command} =~ m{^bash "\$\{CLAUDE_PLUGIN_ROOT\}/hooks/[a-z-]+\.sh"$},
           "AC-36: block 0 entry #$n has type=command, timeout=15 and the house command shape");
    }
    is(scalar(@{ $b0->{hooks} // [] }), 3, 'AC-36: block 0 has exactly 3 hook entries');

    my $b1 = $pre->[1] // {};
    is($b1->{matcher}, 'Bash', 'AC-36: block 1 matcher unchanged');
    # b46 (drive-loop dead-man's switch, 559379c) deliberately appended
    # mark-wakeup.sh to the Bash and Task blocks: it must see every tool call
    # that could schedule a wake-up. The claim -- b12 appended only to its own
    # block 0 -- is untouched, and ledger-guard.sh appearing here still fails.
    is_deeply([ map { $_->{command} } @{ $b1->{hooks} // [] } ],
              [ $cmd_of->('guard-bash.sh'), $cmd_of->('mark-wakeup.sh') ],
              'AC-36: block 1 command list unchanged');
    my $b2 = $pre->[2] // {};
    is($b2->{matcher}, 'Task', 'AC-36: block 2 matcher unchanged');
    is_deeply([ map { $_->{command} } @{ $b2->{hooks} // [] } ],
              [ $cmd_of->('gate-shutdown.sh'), $cmd_of->('track-dispatch.sh'), $cmd_of->('mark-wakeup.sh') ],
              'AC-36: block 2 command list unchanged, in order');
    my $b3 = $pre->[3] // {};
    ok(!exists $b3->{matcher}, 'AC-36: block 3 (b10 repeat-guard) still has NO matcher key');
    is_deeply([ map { $_->{command} } @{ $b3->{hooks} // [] } ], [ $cmd_of->('repeat-guard.sh') ],
              'AC-36: block 3 command list unchanged');

    my $post = ($H && $H->{hooks}{PostToolUse}) // [];
    is(scalar(@$post), 1, 'AC-36: PostToolUse still has exactly one block');
    is($post->[0]{matcher}, 'Task', 'AC-36: PostToolUse matcher unchanged');
    is_deeply([ map { $_->{command} } @{ $post->[0]{hooks} // [] } ], [ $cmd_of->('log-dispatch.sh') ],
              'AC-36: PostToolUse hook list unchanged');
    my $stop = ($H && $H->{hooks}{Stop}) // [];
    is(scalar(@$stop), 1, 'AC-36: Stop still has exactly one block');
    ok(!exists $stop->[0]{matcher}, 'AC-36: Stop block still has no matcher key');
    is_deeply([ map { $_->{command} } @{ $stop->[0]{hooks} // [] } ],
              [ $cmd_of->('gate-stop.sh'), $cmd_of->('gate-drive-loop.sh') ],
              'AC-36: Stop hook list unchanged');

    ok(-e $HOOK,  'AC-36: plugins/butler/hooks/ledger-guard.sh exists');
    ok(-s $HOOK,  'AC-36: plugins/butler/hooks/ledger-guard.sh is non-empty');
}

# =====================================================================================
# AC-37 [file] 14-hooks-selftest.t stays green. Needs no jq. Captured through a pipe so the
# child's TAP never pollutes this file's stream. (Per spec §6-E5 this gates nothing -- that
# suite never opens hooks.json -- but it is a stated done criterion, so it is asserted.)
# =====================================================================================
{
    my $out14 = do {
        local %ENV = %CLEAN_ENV;
        `perl "$SELFTEST_T" 2>&1`;
    };
    my $rc14 = $? >> 8;
    is($rc14, 0, 'AC-37: perl plugins/butler/tests/t/14-hooks-selftest.t exits 0');
    my $notok = () = ($out14 // '') =~ /^not ok /mg;
    is($notok, 0, 'AC-37: 14-hooks-selftest.t emits zero "not ok" lines');
}

# =====================================================================================
# Every remaining group drives the hook process, which requires jq to be PRESENT (spec §2.2:
# bp_hook_require_jq sits immediately after the gate, so without jq every ledger write is M9).
# One SKIP keeps this file useful on the jq-less Git-for-Windows host, mirroring
# 62-repeat-guard.t:388-390. AC-31 (jq scrubbed from PATH) lives INSIDE it only because it
# still needs the hook to run at all.
# =====================================================================================
SKIP: {
    skip "jq is not available on this host; every hook-behaviour group needs it present to reach anything past bp_hook_require_jq", 1
        unless $have_jq;

    # =================================================================================
    # AC-1 [gate] inert outside a coordinator session -- one required var missing at a time.
    # %CLEAN_ENV above is what makes this a real assertion rather than a false pass.
    # =================================================================================
    {
        my @cases = (
            ['BP_LEDGER unset',        sub { my %e = @_; delete $e{BP_LEDGER};       %e }],
            ['BP_LEDGER empty',        sub { my %e = @_; $e{BP_LEDGER} = '';         %e }],
            ['BP_DIR unset',           sub { my %e = @_; delete $e{BP_DIR};          %e }],
            ['BP_PROJECT_ROOT unset',  sub { my %e = @_; delete $e{BP_PROJECT_ROOT}; %e }],
        );
        for my $c (@cases) {
            my ($label, $mut) = @$c;
            my ($bp, $proj) = mk_bp();
            my %env = $mut->(env_for($bp, $proj));
            my ($rc, $out) = run_hook(pl_write(ledger_path($bp), nul_ledger()), %env);
            is($rc,  0,  "AC-1 ($label): a NUL-bearing Write at a would-be ledger path -> RC 0");
            is($out, '', "AC-1 ($label): combined stdout+stderr is empty");
        }
    }

    # =================================================================================
    # AC-2 [scope] non-ledger targets pass through untouched even when grossly corrupt.
    # =================================================================================
    {
        my ($bp, $proj) = mk_bp();
        my %env = env_for($bp, $proj);
        my @targets = (
            "$bp/reports/r.md", "$bp/specs/s.md", "$bp/runs/x.md",
            "$bp/packages/p.txt", "$bp/notes.md", "$proj/src/x.md", '/tmp/x.md',
        );
        for my $t (@targets) {
            my ($rc, $out) = run_hook(pl_write($t, nul_ledger()), %env);
            is($rc,  0,  "AC-2: NUL-bearing Write at $t (not a ledger target) -> RC 0");
            is($out, '', "AC-2: NUL-bearing Write at $t emits nothing");
        }
    }

    # =================================================================================
    # AC-3 [scope] a payload with no path cannot be a ledger write.
    # =================================================================================
    {
        my ($bp, $proj) = mk_bp();
        my %env = env_for($bp, $proj);
        my @cases = (
            ['no file_path/notebook_path',
             $J->encode({ tool_name => 'Write', tool_input => { content => nul_ledger() } })],
            ['empty JSON object', '{}'],
            ['empty stdin',       ''],
            ['non-JSON stdin',    'this is not json at all'],
        );
        for my $c (@cases) {
            my ($label, $payload) = @$c;
            my ($rc, $out) = run_hook($payload, %env);
            is($rc,  0,  "AC-3 ($label): RC 0");
            is($out, '', "AC-3 ($label): emits nothing");
        }
    }

    # =================================================================================
    # AC-4 [scope] a RELATIVE file_path resolved against .cwd reaches the guard.
    # =================================================================================
    {
        my ($bp, $proj) = mk_bp();
        my %env = env_for($bp, $proj);
        my $payload = $J->encode({ tool_name => 'Write', cwd => $bp,
                                   tool_input => { file_path => 'packages/p.md',
                                                   content => nul_ledger() } });
        my ($rc, $out) = run_hook($payload, %env);
        is($rc, 2, 'AC-4: relative file_path "packages/p.md" with .cwd=$BP_DIR resolves to a ledger target -> RC 2');
        like($out, qr/LEDGER-GUARD:/,   'AC-4: message carries the LEDGER-GUARD: prefix');
        like($out, qr/control byte/,    'AC-4: message names the violation class (control byte)');
        like($out, qr/0x00/,            'AC-4: message names the offending byte as 0x00');
        like($out, qr/\Q$bp\E\/packages\/p\.md/, 'AC-4: message names the RESOLVED absolute path');
    }

    # =================================================================================
    # AC-5 [V1] a literal NUL inside line 12 -> M1 naming the byte, the line and the path.
    # =================================================================================
    {
        my ($bp, $proj) = mk_bp();
        my %env = env_for($bp, $proj);
        my $lp = ledger_path($bp);
        my ($rc, $out) = run_hook(pl_write($lp, inject_byte_at_line(kg(), 12, "\x00")), %env);
        is($rc, 2, 'AC-5: Write of the known-good ledger with a literal NUL inside line 12 -> RC 2');
        like($out, qr/LEDGER-GUARD:/, 'AC-5: message carries the LEDGER-GUARD: prefix');
        like($out, qr/control byte/,  'AC-5: message says "control byte"');
        like($out, qr/0x00/,          'AC-5: message names the byte as 0x00 (uppercase, two digits)');
        like($out, qr/line 12\b/,     'AC-5: message names the 1-based line number 12');
        like($out, qr/\Q$lp\E/,       'AC-5: message names the absolute target path');
    }

    # =================================================================================
    # AC-6 [V1] the whole forbidden set, one byte at a time. NOTE \x7F (DEL) is INCLUDED --
    # the spec's [CORRECTION] over the package text, matching bp-orchestrator.pl:506.
    # =================================================================================
    {
        my ($bp, $proj) = mk_bp();
        my %env = env_for($bp, $proj);
        my $lp = ledger_path($bp);
        for my $b (0x01, 0x08, 0x0B, 0x0C, 0x0E, 0x1B, 0x1F, 0x7F) {
            my $hex = sprintf('0x%02X', $b);
            my $content = inject_byte_at_line(kg(), 18, chr($b));
            my ($rc, $out) = run_hook(pl_write($lp, $content), %env);
            is($rc, 2, "AC-6: control byte $hex in the resulting content -> RC 2");
            like($out, qr/\Q$hex\E/, "AC-6: message names the byte as $hex (uppercase two-digit hex)");
        }
    }

    # =================================================================================
    # AC-7 [V1] tabs, LF and CRLF are NOT control-byte violations. CRLF must not be a false
    # positive: \s* in the frontmatter regex absorbs the \r, and \b holds before it.
    # =================================================================================
    {
        my ($bp, $proj) = mk_bp();
        my %env = env_for($bp, $proj);
        my $lp = ledger_path($bp);

        my $tabbed = sub_line(kg(), 'A synthesized, byte-realistic stand-in for a package ledger.',
                                    "A synthesized,\tbyte-realistic\tstand-in for a package ledger.");
        (my $crlf = kg()) =~ s/\n/\r\n/g;

        my @cases = (['unmodified', kg()], ['tab inside a body line', $tabbed], ['every LF converted to CRLF', $crlf]);
        for my $c (@cases) {
            my ($label, $content) = @$c;
            my ($rc, $out) = run_hook(pl_write($lp, $content), %env);
            is($rc,  0,  "AC-7 ($label): RC 0");
            is($out, '', "AC-7 ($label): emits nothing");
        }
    }

    # =================================================================================
    # AC-8 [V1] a ledger DESCRIBING an escape sequence as text is allowed. This is the exact
    # mistake behind the originating incident: the correct spelling must be permitted.
    # =================================================================================
    {
        my ($bp, $proj) = mk_bp();
        my %env = env_for($bp, $proj);
        # The u-escape is assembled via chr(92) so that THIS source file never itself carries the
        # literal control byte it is asserting about (the originating incident, in miniature).
        my $esc = '_fold_key joins segments with "\x00" (spelled ' . chr(92) . 'u0000 here)';
        unlike($esc, qr/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/,
               'FIXTURE-SANITY: the AC-8 body line is pure ASCII text, not a literal control byte');
        my $content = insert_line_at(kg(), 19, $esc);
        my ($rc, $out) = run_hook(pl_write(ledger_path($bp), $content), %env);
        is($rc,  0,  'AC-8: a body line SPELLING the escape as ASCII text -> RC 0 (no literal control byte)');
        is($out, '', 'AC-8: emits nothing');
    }

    # =================================================================================
    # AC-9 [V1] line numbering, and "first offending byte by offset wins".
    # =================================================================================
    {
        my ($bp, $proj) = mk_bp();
        my %env = env_for($bp, $proj);
        my $lp = ledger_path($bp);

        my ($rc1, $out1) = run_hook(pl_write($lp, "\x00" . kg()), %env);
        is($rc1, 2, 'AC-9: a NUL as the very first byte -> RC 2');
        like($out1, qr/0x00/,     'AC-9: names the byte as 0x00');
        like($out1, qr/line 1\b/, 'AC-9: a NUL at byte 0 reports line 1');

        my $both = inject_byte_at_line(inject_byte_at_line(kg(), 9, "\x00"), 3, "\x1B");
        my ($rc2, $out2) = run_hook(pl_write($lp, $both), %env);
        is($rc2, 2, 'AC-9: \x1B on line 3 AND NUL on line 9 -> RC 2');
        is(scalar(nonblank_lines($out2)), 1, 'AC-9: exactly one diagnostic line is emitted');
        like($out2, qr/0x1B/,     'AC-9: names 0x1B (the lowest-offset offender), not the later NUL');
        like($out2, qr/line 3\b/, 'AC-9: names line 3');
        unlike($out2, qr/0x00/,   'AC-9: does NOT name the later 0x00');
    }

    # =================================================================================
    # AC-10 [V2] anything before the opening --- breaks ledger_fm's /\A---\s*\n/ anchor.
    # =================================================================================
    {
        my ($bp, $proj) = mk_bp();
        my %env = env_for($bp, $proj);
        my $lp = ledger_path($bp);
        my @cases = (
            ['a leading blank line', "\n" . kg()],
            ['a leading "# title" line', "# title\n" . kg()],
            ['a leading UTF-8 BOM', "\xEF\xBB\xBF" . kg()],
        );
        for my $c (@cases) {
            my ($label, $content) = @$c;
            my ($rc, $out) = run_hook(pl_write($lp, $content), %env);
            is($rc, 2, "AC-10 ($label): RC 2");
            like($out, qr/frontmatter/, "AC-10 ($label): message names the frontmatter violation");
        }
    }

    # =================================================================================
    # AC-11 [V2] a deleted closing delimiter.
    # =================================================================================
    {
        my ($bp, $proj) = mk_bp();
        my %env = env_for($bp, $proj);
        my $content = drop_line(drop_line(kg(), '---'), '---');   # drop opening, then closing
        $content = "---\n" . $content;                            # put the OPENING back only
        my ($rc, $out) = run_hook(pl_write(ledger_path($bp), $content), %env);
        is($rc, 2, 'AC-11: the closing "---" deleted -> RC 2');
        like($out, qr/LEDGER-GUARD:/, 'AC-11: message carries the LEDGER-GUARD: prefix');
        like($out, qr/frontmatter/,   'AC-11: message names the frontmatter violation');
    }

    # =================================================================================
    # AC-12 [V3] each required key, then two at once in ONE message.
    # =================================================================================
    {
        my ($bp, $proj) = mk_bp();
        my %env = env_for($bp, $proj);
        my $lp = ledger_path($bp);
        my %fm_line = (
            package      => 'package: fixture-pkg',
            blueprint    => 'blueprint: sandbox-butler-overhaul',
            status       => 'status: running',
            write_set    => 'write_set: plugins/butler/hooks/ledger-guard.sh:plugins/butler/hooks/hooks.json',
            last_updated => 'last_updated: 2026-07-29T19:22:00Z',
        );
        for my $k (qw(package blueprint status write_set last_updated)) {
            my $content = drop_line(kg(), $fm_line{$k});
            my ($rc, $out) = run_hook(pl_write($lp, $content), %env);
            is($rc, 2, "AC-12: frontmatter key '$k' deleted -> RC 2");
            like($out, qr/frontmatter key/, "AC-12: '$k' missing -> message says \"frontmatter key\"");
            like($out, qr/\Q$k\E/,          "AC-12: '$k' missing -> message names '$k'");
        }
        my $two = drop_line(drop_line(kg(), $fm_line{blueprint}), $fm_line{last_updated});
        my ($rc2, $out2) = run_hook(pl_write($lp, $two), %env);
        is($rc2, 2, 'AC-12: two keys deleted at once -> RC 2');
        is(scalar(nonblank_lines($out2)), 1, 'AC-12: two missing keys produce exactly ONE message');
        like($out2, qr/blueprint/,    'AC-12: the single message names "blueprint"');
        like($out2, qr/last_updated/, 'AC-12: the single message names "last_updated"');
    }

    # =================================================================================
    # AC-13 [V4] a status outside the protocol set, and the empty-value case.
    # =================================================================================
    {
        my ($bp, $proj) = mk_bp();
        my %env = env_for($bp, $proj);
        my $lp = ledger_path($bp);

        my ($rc, $out) = run_hook(pl_write($lp, kg(status => 'frobnicated')), %env);
        is($rc, 2, 'AC-13: status: frobnicated -> RC 2');
        like($out, qr/LEDGER-GUARD:/, 'AC-13: message carries the LEDGER-GUARD: prefix');
        like($out, qr/"frobnicated"/, 'AC-13: message quotes the offending value as "frobnicated"');
        like($out, qr/\bstatus\b/,    'AC-13: message names the status key');
        for my $s (@STATUSES) {
            like($out, qr/\b\Q$s\E\b/, "AC-13: message lists the allowed value '$s'");
        }

        my $empty = sub_line(kg(), 'status: running', 'status:');
        my ($rc2, $out2) = run_hook(pl_write($lp, $empty), %env);
        is($rc2, 2, 'AC-13: "status:" with an empty value -> RC 2');
        like($out2, qr/\bstatus\b/, 'AC-13: empty-status message names the status key');
        like($out2, qr/\bpending\b/ , 'AC-13: empty-status message is M4 (it lists the allowed values)');
        like($out2, qr/\bconverging\b/, 'AC-13: empty-status message lists "converging"');
    }

    # =================================================================================
    # AC-14 [V4] all seven protocol statuses pass. `converging` is ledger-only.
    # =================================================================================
    {
        my ($bp, $proj) = mk_bp();
        my %env = env_for($bp, $proj);
        my $lp = ledger_path($bp);
        for my $s (@STATUSES) {
            my ($rc, $out) = run_hook(pl_write($lp, kg(status => $s)), %env);
            is($rc,  0,  "AC-14: status: $s -> RC 0");
            is($out, '', "AC-14: status: $s emits nothing");
        }
    }

    # =================================================================================
    # AC-15 [V2/V3] two false-positive controls drawn from the real corpus.
    #   (a) a body-level "---" horizontal rule far below a valid frontmatter is harmless
    #       (q01-protected-roots.md:446 is a real such line) -- .*? is non-greedy.
    #   (b) a body line starting "package:" must NOT satisfy the frontmatter key check
    #       (b13-deterministic-ledger-api.md:42 is a real such line).
    # =================================================================================
    {
        my ($bp, $proj) = mk_bp();
        my %env = env_for($bp, $proj);
        my $lp = ledger_path($bp);

        my $hr = insert_line_at(kg(), 200, '--- ');
        my ($rc1, $out1) = run_hook(pl_write($lp, $hr), %env);
        is($rc1,  0,  'AC-15a: a body-level "--- " horizontal rule at line 200 -> RC 0');
        is($out1, '', 'AC-15a: emits nothing');

        my $body_key = insert_line_at(drop_line(kg(), 'package: fixture-pkg'), 42,
                                      'package: b13-deterministic-ledger-api');
        my ($rc2, $out2) = run_hook(pl_write($lp, $body_key), %env);
        is($rc2, 2, 'AC-15b: frontmatter package: deleted, a body line "package: ..." added -> RC 2');
        like($out2, qr/frontmatter key/, 'AC-15b: message says "frontmatter key"');
        like($out2, qr/\bpackage\b/,     'AC-15b: message names "package" (a BODY line must not satisfy the key)');
    }

    # =================================================================================
    # AC-16 [V5] each required section heading, then two at once in ONE message.
    # =================================================================================
    {
        my ($bp, $proj) = mk_bp();
        my %env = env_for($bp, $proj);
        my $lp = ledger_path($bp);
        # Canonical names as they appear in the M5 enumeration (Escalation is named bare there,
        # even though the corpus heading carries a suffix -- see AC-17/AC-18).
        my %canon = ($ESC_HEADING => '## Escalation');
        for my $h (@HEADINGS) {
            my $content = drop_line(kg(), $h);
            my $name = $canon{$h} // $h;
            my ($rc, $out) = run_hook(pl_write($lp, $content), %env);
            is($rc, 2, "AC-16: '$h' deleted -> RC 2");
            like($out, qr/section/,      "AC-16: '$h' missing -> message says \"section\"");
            like($out, qr/\Q$name\E/,    "AC-16: '$h' missing -> message names '$name'");
        }
        my $two = drop_line(drop_line(kg(), '## Pipeline'), '## Outputs');
        my ($rc2, $out2) = run_hook(pl_write($lp, $two), %env);
        is($rc2, 2, 'AC-16: two headings deleted at once -> RC 2');
        is(scalar(nonblank_lines($out2)), 1, 'AC-16: two missing headings produce exactly ONE message');
        like($out2, qr/\Q## Pipeline\E/, 'AC-16: the single message names "## Pipeline"');
        like($out2, qr/\Q## Outputs\E/,  'AC-16: the single message names "## Outputs"');
    }

    # =================================================================================
    # AC-17 [V5] *** HIGHEST RISK IN THE PACKAGE ***
    # The Escalation pattern is ^##\s+Escalation\b -- a PREFIX, never an exact string.
    # 30/32 live ledgers spell it "## Escalation (when status: blocked)". An exact check
    # rejects the entire corpus INCLUDING EVERY PARK-WRITE, leaving a stopping coordinator
    # with no legal move at all (AC-34). Both real suffixed forms must be ACCEPTED.
    # =================================================================================
    {
        my ($bp, $proj) = mk_bp();
        my %env = env_for($bp, $proj);
        my $lp = ledger_path($bp);

        my ($rc1, $out1) = run_hook(pl_write($lp, kg()), %env);   # fixture is the suffixed form
        is($rc1,  0,  'AC-17: "## Escalation (when status: blocked)" satisfies the Escalation requirement -> RC 0');
        is($out1, '', 'AC-17: emits nothing');

        my $resolved = sub_line(kg(), $ESC_HEADING,
                                '## Escalation (RESOLVED 2026-07-29T00:10Z — kept for the h…)');
        my ($rc2, $out2) = run_hook(pl_write($lp, $resolved), %env);
        is($rc2,  0,  'AC-17: the real s06 form "## Escalation (RESOLVED …)" is accepted -> RC 0');
        is($out2, '', 'AC-17: emits nothing');
    }

    # =================================================================================
    # AC-18 [V5] the \b after "Escalation" is what makes the PLURAL heading not satisfy the
    # requirement on its own (b02:201 is a real such line).
    # =================================================================================
    {
        my ($bp, $proj) = mk_bp();
        my %env = env_for($bp, $proj);
        my $content = sub_line(kg(), $ESC_HEADING,
                               "## Escalations raised BY the spec (outside this package's scope)");
        my ($rc, $out) = run_hook(pl_write(ledger_path($bp), $content), %env);
        is($rc, 2, 'AC-18: "## Escalations raised BY ..." (plural) is the ONLY Escalation-ish heading -> RC 2');
        like($out, qr/section/,               'AC-18: message says "section"');
        like($out, qr/\Q## Escalation\E/,     'AC-18: message names the missing "## Escalation" section');
    }

    # =================================================================================
    # AC-19 [V5] presence-only: NO uniqueness constraint anywhere. s05-responsive-layout.md
    # really carries five "## Next action" headings (L71,82,98,109,122).
    # =================================================================================
    {
        my ($bp, $proj) = mk_bp();
        my %env = env_for($bp, $proj);
        my $content = kg();
        $content = insert_line_at($content, $_, '## Next action') for (160, 140, 120, 100);
        is(count_occ($content, "\n## Next action\n"), 5,
           'FIXTURE-SANITY: the AC-19 fixture really carries five "## Next action" headings');
        my ($rc, $out) = run_hook(pl_write(ledger_path($bp), $content), %env);
        is($rc,  0,  'AC-19: five "## Next action" headings -> RC 0 (presence-only, no uniqueness check)');
        is($out, '', 'AC-19: emits nothing');
    }

    # =================================================================================
    # AC-20 [reconstruction/Write] the on-disk state is IRRELEVANT to Write.
    # =================================================================================
    {
        my ($bp, $proj) = mk_bp();
        my %env = env_for($bp, $proj);
        my $lp = ledger_path($bp);
        write_file($lp, nul_ledger());          # corrupt on disk
        my ($rc, $out) = run_hook(pl_write($lp, kg()), %env);
        is($rc,  0,  'AC-20: clean Write over a NUL-bearing on-disk ledger -> RC 0 (content IS the result)');
        is($out, '', 'AC-20: emits nothing');
    }

    # =================================================================================
    # AC-21 [reconstruction/Edit] THE SPLICE TEST -- the assertion a new_string-only scanner
    # cannot pass. Each new_string below is individually innocent.
    # =================================================================================
    {
        my ($bp, $proj) = mk_bp();
        my %env = env_for($bp, $proj);
        my $lp = ledger_path($bp);
        write_file($lp, kg());

        # (a) old_string spans the "## Next action" heading; new_string omits it and contains
        #     no heading text and no control byte.
        my $old_a = "## Next action\n\nDispatch the implementer for ledger-guard.sh.\n";
        my $new_a = "Dispatch the implementer for ledger-guard.sh.\n";
        is(count_occ(kg(), $old_a), 1, 'FIXTURE-SANITY: AC-21a old_string occurs exactly once on disk');
        unlike($new_a, qr/\Q## Next action\E/, 'FIXTURE-SANITY: AC-21a new_string contains no heading text');
        my ($rc_a, $out_a) = run_hook(pl_edit($lp, $old_a, $new_a, 0), %env);
        is($rc_a, 2, 'AC-21a: an Edit whose splice DELETES the "## Next action" heading -> RC 2');
        like($out_a, qr/section/,             'AC-21a: message says "section"');
        like($out_a, qr/\Q## Next action\E/,  'AC-21a: message names "## Next action"');

        # (b) new_string ends with a lone \x1B -- a corruption that only exists post-splice.
        my $old_b = '- fixture artifact -- present';
        my ($rc_b, $out_b) = run_hook(pl_edit($lp, $old_b, $old_b . "\x1B", 0), %env);
        is($rc_b, 2, 'AC-21b: an Edit whose new_string ends with a lone \x1B -> RC 2');
        like($out_b, qr/control byte/, 'AC-21b: message says "control byte"');
        like($out_b, qr/0x1B/,         'AC-21b: message names 0x1B');

        # (c) an Edit that removes the frontmatter's closing "---".
        my $old_c = "last_updated: 2026-07-29T19:22:00Z\n---\n";
        my $new_c = "last_updated: 2026-07-29T19:22:00Z\n";
        is(count_occ(kg(), $old_c), 1, 'FIXTURE-SANITY: AC-21c old_string occurs exactly once on disk');
        my ($rc_c, $out_c) = run_hook(pl_edit($lp, $old_c, $new_c, 0), %env);
        is($rc_c, 2, 'AC-21c: an Edit that deletes the closing "---" -> RC 2');
        like($out_c, qr/frontmatter/, 'AC-21c: message names the frontmatter violation');
    }

    # =================================================================================
    # AC-22 [reconstruction/Edit] the ordinary status transition is allowed.
    # =================================================================================
    {
        my ($bp, $proj) = mk_bp();
        my %env = env_for($bp, $proj);
        my $lp = ledger_path($bp);
        write_file($lp, kg());
        my ($rc, $out) = run_hook(pl_edit($lp, 'status: running', 'status: done', 0), %env);
        is($rc,  0,  'AC-22: Edit "status: running" -> "status: done", replace_all=false -> RC 0');
        is($out, '', 'AC-22: emits nothing');
    }

    # =================================================================================
    # AC-23 [reconstruction/Edit] replace_all is honoured.
    # RULED DEVIATION (recorded, not re-litigated): with a CONSTANT new_string and the §2.4
    # prefix/\b section patterns, a one-of-two context break is reachable only through the
    # frontmatter, so the second occurrence of XX sits on the `status:` line rather than on a
    # heading. The two BINDING assertions are unchanged: replace_all=true -> RC 2, and the
    # byte-identical payload with replace_all=false -> RC 0 (n>1 and not replace_all is the
    # deliberate ALLOW of AC-24 -- the real Edit would itself error, so no bytes land).
    # =================================================================================
    {
        my ($bp, $proj) = mk_bp();
        my %env = env_for($bp, $proj);
        my $lp = ledger_path($bp);
        my $disk = sub_line(sub_line(kg(), 'status: running', 'status: XXrunning'),
                            '- fixture artifact -- present', '- fixture artifact XX -- present');
        is(count_occ($disk, 'XX'), 2, 'FIXTURE-SANITY: the AC-23 on-disk ledger carries the token XX exactly twice');
        write_file($lp, $disk);

        my ($rc_t, $out_t) = run_hook(pl_edit($lp, 'XX', 'bogus-', 1), %env);
        is($rc_t, 2, 'AC-23: replace_all=true, where replacing BOTH occurrences introduces the violation -> RC 2');
        like($out_t, qr/LEDGER-GUARD:/, 'AC-23: the replace_all=true block carries the LEDGER-GUARD: prefix');

        my ($rc_f, $out_f) = run_hook(pl_edit($lp, 'XX', 'bogus-', 0), %env);
        is($rc_f,  0,  'AC-23: the same payload with replace_all=false -> RC 0 (ambiguous; the real Edit errors)');
        is($out_f, '', 'AC-23: the replace_all=false case emits nothing');
    }

    # =================================================================================
    # AC-24 [reconstruction/Edit] THE DELIBERATE ALLOW-SIDE OF FAIL-CLOSED. In all three the
    # real Edit tool errors and NO BYTES REACH DISK, so blocking would be a pure false
    # positive costing a coordinator turn and emitting a diagnostic about a splice that can
    # never happen. Fail-closed means "no unvalidated bytes reach the ledger", not "exit 2
    # whenever uncertain".
    # =================================================================================
    {
        my ($bp, $proj) = mk_bp();
        my %env = env_for($bp, $proj);
        my $lp = ledger_path($bp);
        write_file($lp, kg());

        my ($rc_a, $out_a) = run_hook(pl_edit("$bp/packages/does-not-exist.md", 'x', 'y', 0), %env);
        is($rc_a,  0,  'AC-24a: Edit at a NONEXISTENT ledger path -> RC 0');
        is($out_a, '', 'AC-24a: emits nothing');

        my ($rc_b, $out_b) = run_hook(pl_edit($lp, 'this string is not anywhere in the fixture', 'y', 0), %env);
        is($rc_b,  0,  'AC-24b: Edit whose old_string does not occur in the file -> RC 0');
        is($out_b, '', 'AC-24b: emits nothing');

        my $twice = insert_line_at(kg(), 100, '- fixture artifact -- present');
        write_file($lp, $twice);
        is(count_occ($twice, '- fixture artifact -- present'), 2,
           'FIXTURE-SANITY: the AC-24c on-disk ledger carries the old_string exactly twice');
        my ($rc_c, $out_c) = run_hook(pl_edit($lp, '- fixture artifact -- present', 'x', 0), %env);
        is($rc_c,  0,  'AC-24c: Edit whose old_string occurs twice with replace_all=false -> RC 0 (ambiguous)');
        is($out_c, '', 'AC-24c: emits nothing');
    }

    # =================================================================================
    # AC-25 [M6] an empty old_string is un-reconstructable -> BLOCK.
    # =================================================================================
    {
        my ($bp, $proj) = mk_bp();
        my %env = env_for($bp, $proj);
        my $lp = ledger_path($bp);
        write_file($lp, kg());
        my ($rc, $out) = run_hook(pl_edit($lp, '', 'anything', 0), %env);
        is($rc, 2, 'AC-25: Edit with old_string="" at a ledger target -> RC 2');
        like($out, qr/LEDGER-GUARD:/,      'AC-25: message carries the LEDGER-GUARD: prefix');
        like($out, qr/cannot reconstruct/, 'AC-25: message says "cannot reconstruct"');
        like($out, qr/empty old_string/,   'AC-25: message gives the fixed reason "empty old_string"');
    }

    # =================================================================================
    # AC-26 [M6] a Write payload without a string "content".
    # =================================================================================
    {
        my ($bp, $proj) = mk_bp();
        my %env = env_for($bp, $proj);
        my $lp = ledger_path($bp);
        my @cases = (
            ['content absent',        pl_write_raw($lp)],
            ['content is a number',   pl_write_raw($lp, content => 42)],
            ['content is an object',  pl_write_raw($lp, content => { a => 1 })],
        );
        for my $c (@cases) {
            my ($label, $payload) = @$c;
            my ($rc, $out) = run_hook($payload, %env);
            is($rc, 2, "AC-26 ($label): RC 2");
            like($out, qr/cannot reconstruct/, "AC-26 ($label): message says \"cannot reconstruct\"");
        }
    }

    # =================================================================================
    # AC-27 [reconstruction/MultiEdit]
    # *** THESE TWO ASSERTIONS REST ON AN UNVERIFIED ASSUMPTION (spec §2.5, §6-E6). ***
    # Zero MultiEdit PreToolUse payloads exist anywhere on disk in this project, so the
    # "edits apply sequentially against a progressively-modified buffer" semantic is ASSUMED,
    # not established. Both sub-cases are built so that edit 2's old_string exists ONLY after
    # edit 1 has been applied -- i.e. they fail if the guard validates edits independently.
    # Settled only by a captured real MultiEdit payload or current Claude Code documentation.
    # =================================================================================
    {
        my ($bp, $proj) = mk_bp();
        my %env = env_for($bp, $proj);
        my $lp = ledger_path($bp);
        write_file($lp, kg());

        my $edits_ok = [
            { old_string => 'Dispatch the implementer for ledger-guard.sh.', new_string => 'SENTINEL-A', replace_all => jfalse() },
            { old_string => 'SENTINEL-A', new_string => 'Dispatch the implementer, take two.',           replace_all => jfalse() },
        ];
        is(count_occ(kg(), 'SENTINEL-A'), 0, 'FIXTURE-SANITY: AC-27a edit 2 old_string exists ONLY after edit 1 is applied');
        my ($rc_a, $out_a) = run_hook(pl_multiedit($lp, $edits_ok), %env);
        is($rc_a,  0,  'AC-27a: sequential MultiEdit whose FINAL buffer is well-formed -> RC 0 [UNVERIFIED ASSUMPTION]');
        is($out_a, '', 'AC-27a: emits nothing [UNVERIFIED ASSUMPTION]');

        my $edits_bad = [
            { old_string => "## Pipeline\n", new_string => "SENTINEL-B\n", replace_all => jfalse() },
            { old_string => "SENTINEL-B\n",  new_string => '',             replace_all => jfalse() },
        ];
        is(count_occ(kg(), 'SENTINEL-B'), 0, 'FIXTURE-SANITY: AC-27b edit 2 old_string exists ONLY after edit 1 is applied');
        my ($rc_b, $out_b) = run_hook(pl_multiedit($lp, $edits_bad), %env);
        is($rc_b, 2, 'AC-27b: sequential MultiEdit whose FINAL buffer drops "## Pipeline" -> RC 2 [UNVERIFIED ASSUMPTION]');
        like($out_b, qr/section/,           'AC-27b: message says "section"');
        like($out_b, qr/\Q## Pipeline\E/,   'AC-27b: message names "## Pipeline"');
    }

    # =================================================================================
    # AC-28 [M6] a MultiEdit payload that does not carry what reconstruction needs.
    # =================================================================================
    {
        my ($bp, $proj) = mk_bp();
        my %env = env_for($bp, $proj);
        my $lp = ledger_path($bp);
        write_file($lp, kg());
        my @cases = (
            ['edits absent',                    pl_multiedit($lp, undef)],
            ['edits is a string',               $J->encode({ tool_name => 'MultiEdit', tool_input => { file_path => $lp, edits => 'x' } })],
            ['edits is an empty array',         pl_multiedit($lp, [])],
            ['an element lacks old_string',     pl_multiedit($lp, [ { new_string => 'y' } ])],
            ['an element has old_string ""',    pl_multiedit($lp, [ { old_string => '', new_string => 'y' } ])],
        );
        for my $c (@cases) {
            my ($label, $payload) = @$c;
            my ($rc, $out) = run_hook($payload, %env);
            is($rc, 2, "AC-28 ($label): RC 2");
            like($out, qr/cannot reconstruct/, "AC-28 ($label): message says \"cannot reconstruct\"");
        }
    }

    # =================================================================================
    # AC-29 [M8] NotebookEdit can never target a markdown ledger.
    # =================================================================================
    {
        my ($bp, $proj) = mk_bp();
        my %env = env_for($bp, $proj);
        my $ledger_payload = $J->encode({ tool_name => 'NotebookEdit', cwd => '/project',
                                          tool_input => { notebook_path => ledger_path($bp),
                                                          new_source => 'x' } });
        my ($rc, $out) = run_hook($ledger_payload, %env);
        is($rc, 2, 'AC-29: NotebookEdit with notebook_path at a ledger target -> RC 2');
        like($out, qr/LEDGER-GUARD:/, 'AC-29: message carries the LEDGER-GUARD: prefix');
        like($out, qr/NotebookEdit/,  'AC-29: message names NotebookEdit');

        my $report_payload = $J->encode({ tool_name => 'NotebookEdit', cwd => '/project',
                                          tool_input => { notebook_path => "$bp/reports/r.md",
                                                          new_source => 'x' } });
        my ($rc2, $out2) = run_hook($report_payload, %env);
        is($rc2,  0,  'AC-29: NotebookEdit under $BP_DIR/reports/ -> RC 0 (out of scope)');
        is($out2, '', 'AC-29: the out-of-scope NotebookEdit emits nothing');
    }

    # =================================================================================
    # AC-30 [M6] an unrecognised or absent tool_name at a ledger target.
    # =================================================================================
    {
        my ($bp, $proj) = mk_bp();
        my %env = env_for($bp, $proj);
        my $lp = ledger_path($bp);
        my @cases = (
            ['tool_name absent',    $J->encode({ cwd => '/project', tool_input => { file_path => $lp, content => kg() } })],
            ['tool_name "Bash"',    $J->encode({ tool_name => 'Bash', cwd => '/project', tool_input => { file_path => $lp, content => kg() } })],
        );
        for my $c (@cases) {
            my ($label, $payload) = @$c;
            my ($rc, $out) = run_hook($payload, %env);
            is($rc, 2, "AC-30 ($label) at a ledger target: RC 2");
            like($out, qr/cannot reconstruct/, "AC-30 ($label): message says \"cannot reconstruct\"");
        }
    }

    # =================================================================================
    # AC-31 [M9] fail-CLOSED with jq missing from PATH. M9's text is verbatim lib.sh:18 --
    # emitted by bp_hook_require_jq, never reimplemented.
    # =================================================================================
    {
        my ($bp, $proj) = mk_bp();
        my %env = env_for($bp, $proj);
        $env{PATH} = path_without('jq');
        my ($rc, $out) = run_hook(pl_write(ledger_path($bp), kg()), %env);
        is($rc, 2, 'AC-31: ledger target with jq scrubbed from PATH -> RC 2 (fail-closed)');
        like($out, qr/jq is required but missing/, 'AC-31: message is bp_hook_require_jq\'s verbatim text');
    }

    # =================================================================================
    # AC-32 [M10] fail-CLOSED with perl missing from PATH.
    # =================================================================================
    {
        my ($bp, $proj) = mk_bp();
        my %env = env_for($bp, $proj);
        $env{PATH} = path_without('perl');
        my ($rc, $out) = run_hook(pl_write(ledger_path($bp), kg()), %env);
        is($rc, 2, 'AC-32: ledger target with perl scrubbed from PATH -> RC 2 (fail-closed)');
        like($out, qr/LEDGER-GUARD:/,  'AC-32: message carries the LEDGER-GUARD: prefix');
        like($out, qr/perl is required/, 'AC-32: message says "perl is required"');
    }

    # =================================================================================
    # AC-33 [M7] the target exists but cannot be read as bytes (a directory at that path).
    # =================================================================================
    {
        my ($bp, $proj) = mk_bp();
        my %env = env_for($bp, $proj);
        my $lp = "$bp/packages/p.md";
        mkdir $lp or die "mkdir $lp: $!";
        my ($rc, $out) = run_hook(pl_edit($lp, 'a', 'b', 0), %env);
        is($rc, 2, 'AC-33: Edit whose target is a DIRECTORY at $BP_DIR/packages/p.md -> RC 2');
        like($out, qr/LEDGER-GUARD:/, 'AC-33: message carries the LEDGER-GUARD: prefix');
        like($out, qr/cannot read/,   'AC-33: message says "cannot read"');
    }

    # =================================================================================
    # AC-34 *** NON-NEGOTIABLE *** the graceful-stop park-write MUST be allowed.
    # Under a stop, bp_gate_verdict denies Task and every worksite edit, and gate-stop.sh
    # refuses to end the session until the park-write lands. A guard that rejects it leaves a
    # stopping coordinator with NO LEGAL MOVE and traps the session. All three stop flavours,
    # each as the SEQUENCE of Edit payloads a stopping coordinator actually emits (the disk is
    # advanced between steps, exactly as the real tool would), AND as the whole-file Write.
    # =================================================================================
    sub run_park_sequence {
        my ($label, @edits) = @_;
        my ($bp, $proj) = mk_bp();
        my %env = env_for($bp, $proj);
        my $lp  = ledger_path($bp);
        my $cur = kg();
        write_file($lp, $cur);
        my $i = 0;
        for my $e (@edits) {
            $i++;
            my ($old, $new) = @$e;
            is(count_occ($cur, $old), 1,
               "FIXTURE-SANITY: park-write [$label] edit $i old_string occurs exactly once on disk");
            my ($rc, $out) = run_hook(pl_edit($lp, $old, $new, 0), %env);
            is($rc,  0,  "AC-34 [$label]: park-write Edit $i -> RC 0 (a stopping coordinator MUST have a legal move)");
            is($out, '', "AC-34 [$label]: park-write Edit $i emits nothing");
            $cur = apply_once($cur, $old, $new);
            write_file($lp, $cur);
        }
        my ($rc2, $out2) = run_hook(pl_write($lp, $cur), %env);
        is($rc2,  0,  "AC-34 [$label]: the SAME park-write in whole-file Write form -> RC 0");
        is($out2, '', "AC-34 [$label]: whole-file park Write emits nothing");
    }

    # (a) graceful-shutdown-all: running -> parked, last_updated refreshed, Next action
    #     rewritten, Outputs body completed.
    run_park_sequence('a: graceful-shutdown-all, status: parked',
        ['status: running', 'status: parked'],
        ['last_updated: 2026-07-29T19:22:00Z', 'last_updated: 2026-07-29T20:05:00Z'],
        ['Dispatch the implementer for ledger-guard.sh.',
         "PARKED on a graceful shutdown-all. On resume: dispatch the implementer for ledger-guard.sh;\nsteps 1-2 are COMPLETE and verified from disk -- do not redo them."],
        ['- fixture artifact -- present',
         "- fixture artifact -- present\n- ledger-guard.sh -- NOT WRITTEN (step 4 not started)"],
    );

    # (b) usage pause: status DELIBERATELY left non-terminal (running), so the orchestrator
    #     relaunches. Setting parked/done here would strand the package.
    run_park_sequence('b: usage pause, status left running (non-terminal)',
        ['last_updated: 2026-07-29T19:22:00Z', 'last_updated: 2026-07-29T20:05:00Z'],
        ['Dispatch the implementer for ledger-guard.sh.',
         "PAUSED on runs/.paused (usage), auto-resume expected. Status is intentionally still\nrunning, not parked -- do not \"fix\" it to a terminal value or the orchestrator will never\nrelaunch this package."],
    );

    # (c) force-stop / blocked: running -> blocked, Escalation body filled in.
    run_park_sequence('c: force-stop, status: blocked with Escalation filled',
        ['status: running', 'status: blocked'],
        ['_(none)_',
         "Blocked on a scope decision: the hooks.json registration turns a done sibling's suite red.\nNeeds the orchestrator to extend the write set or record why the divergence is acceptable."],
        ['Dispatch the implementer for ledger-guard.sh.',
         'BLOCKED -- see the Escalation section. No forward move without an orchestrator ruling.'],
    );

    # =================================================================================
    # AC-35 [false-positive baseline] the regression control for the whole suite. The live
    # 32-ledger corpus is clean on all five checks; if the byte-realistic fixture ever blocks,
    # the guard is wrong about what a real ledger looks like.
    # =================================================================================
    {
        my ($bp, $proj) = mk_bp();
        my %env = env_for($bp, $proj);
        my ($rc, $out) = run_hook(pl_write(ledger_path($bp), kg()), %env);
        is($rc,  0,  'AC-35: Write of the byte-realistic known-good fixture VERBATIM -> RC 0');
        is($out, '', 'AC-35: the baseline write emits absolutely nothing (stdout and stderr both empty)');
    }

    # =================================================================================
    # AC-39 [determinism] validation order V1 -> V2 -> V3 -> V4 -> V5, first failing class
    # wins, EXACTLY ONE stderr line. Six payloads, one cascade, fully deterministic.
    # =================================================================================
    {
        my ($bp, $proj) = mk_bp();
        my %env = env_for($bp, $proj);
        my $lp = ledger_path($bp);

        my $p6 = kg();                                                   # all five classes clean
        my $p5 = $p6; $p5 = drop_line($p5, $_) for @HEADINGS;             # + no headings
        my $p4 = sub_line($p5, 'status: running', 'status: frobnicated'); # + bad status
        my $p3 = drop_line(drop_line($p4, 'package: fixture-pkg'),
                           'write_set: plugins/butler/hooks/ledger-guard.sh:plugins/butler/hooks/hooks.json'); # + missing keys
        my $p2 = drop_line(drop_line($p3, '---'), '---');                 # + no frontmatter block
        my $p1 = inject_byte_at_line($p2, 3, "\x00");                     # + a control byte

        my ($rc1, $out1) = run_hook(pl_write($lp, $p1), %env);
        is($rc1, 2, 'AC-39: all five classes violated -> RC 2');
        is(scalar(nonblank_lines($out1)), 1, 'AC-39: all five classes violated -> exactly ONE stderr line');
        like($out1, qr/control byte/, 'AC-39: V1 wins over V2..V5 (M1)');

        my ($rc2, $out2) = run_hook(pl_write($lp, $p2), %env);
        is($rc2, 2, 'AC-39: NUL removed -> RC 2');
        is(scalar(nonblank_lines($out2)), 1, 'AC-39: NUL removed -> exactly ONE stderr line');
        like($out2, qr/frontmatter/,      'AC-39: V2 now wins (M2)');
        unlike($out2, qr/control byte/,   'AC-39: M2, not M1');
        unlike($out2, qr/frontmatter key/,'AC-39: M2, not M3');

        my ($rc3, $out3) = run_hook(pl_write($lp, $p3), %env);
        is($rc3, 2, 'AC-39: frontmatter delimiters restored -> RC 2');
        is(scalar(nonblank_lines($out3)), 1, 'AC-39: delimiters restored -> exactly ONE stderr line');
        like($out3, qr/frontmatter key/, 'AC-39: V3 now wins (M3)');
        like($out3, qr/\bpackage\b/,     'AC-39: M3 names the missing key "package"');
        like($out3, qr/\bwrite_set\b/,   'AC-39: M3 names the missing key "write_set"');

        my ($rc4, $out4) = run_hook(pl_write($lp, $p4), %env);
        is($rc4, 2, 'AC-39: keys restored -> RC 2');
        is(scalar(nonblank_lines($out4)), 1, 'AC-39: keys restored -> exactly ONE stderr line');
        like($out4, qr/"frobnicated"/,    'AC-39: V4 now wins (M4), quoting the offending value');
        unlike($out4, qr/frontmatter key/,'AC-39: M4, not M3');

        my ($rc5, $out5) = run_hook(pl_write($lp, $p5), %env);
        is($rc5, 2, 'AC-39: status fixed -> RC 2');
        is(scalar(nonblank_lines($out5)), 1, 'AC-39: status fixed -> exactly ONE stderr line');
        like($out5, qr/section/, 'AC-39: V5 now wins (M5)');
        like($out5, qr/\Q## Next action\E/, 'AC-39: M5 names "## Next action"');

        my ($rc6, $out6) = run_hook(pl_write($lp, $p6), %env);
        is($rc6,  0,  'AC-39: headings fixed -> RC 0, the cascade terminates cleanly');
        is($out6, '', 'AC-39: the fully-repaired content emits nothing');
    }
}

done_testing();
