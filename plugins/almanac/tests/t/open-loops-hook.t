#!/usr/bin/env perl
# platform: any
# Tests for the open-loops PreCompact/SessionStart pair
# (hooks/open-loops-gate.sh -> scripts/almanac-open-loops.pl).
#
# Covers: transcript extraction (boundary, skipped parts, size cap); todos
# filed with their tags and fields, exact-title dedup, "closed" ids completed
# only when they are this session's open loops; the summary instructions on
# stdout; fail-open on garbage, nonzero exit, timeout and a missing claude;
# the recursion guard, the fleet no-op and the operator opt-out; SessionStart
# for source "compact" (and nothing for any other source), with truncation
# under the 10,000-character limit; the hooks.json registration.
#
# `claude` is a stub on PATH (a perl script) that records its argv, stdin,
# environment and pid, and answers per OL_STUB_MODE. HOME, USERPROFILE and
# ALMANAC_HOME point at a temp dir and the project is a temp dir, so the
# operator's vault and real todos are never touched; every hook run goes
# through the LIVE hooks.json command string, under bash.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd ();
use JSON::PP ();
use Time::HiRes ();

(my $ALM = Cwd::abs_path("$Bin/../..") // "$Bin/../..") =~ s{\\}{/}g;
my $HOOKS_JSON = "$ALM/hooks/hooks.json";
my $SCRIPT     = "$ALM/scripts/almanac-open-loops.pl";
my $GATE       = "$ALM/hooks/open-loops-gate.sh";
my $TODO_PL    = "$ALM/scripts/almanac-todo.pl";

my $SID   = 'abcd1234-5678-4abc-9def-001122334455';
my $STAG  = 'session-abcd1234';
my $SID2  = 'ffff0000-1111-4222-8333-444455556666';

sub slurp {
    my ($p) = @_;
    return undef unless defined $p && -f $p;
    open my $fh, '<:raw', $p or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

sub spew {
    my ($p, $c) = @_;
    open my $fh, '>:raw', $p or die "cannot write $p: $!";
    print {$fh} $c;
    close $fh;
}

# ---------------------------------------------------------------------------
# fixture: home, project, stub claude
# ---------------------------------------------------------------------------
my $ROOT = tempdir(CLEANUP => 1);
$ROOT =~ s{\\}{/}g;
my $HOME = "$ROOT/home";
my $PROJ = "$ROOT/proj";
my $STUB = "$ROOT/stub";       # holds the stub `claude`
my $SLOG = "$ROOT/stublog";    # where the stub records what it saw
my $NOCL = "$ROOT/noclaude";   # a PATH entry with no claude in it
make_path($HOME, "$PROJ/.ccpraxis-local-data", "$PROJ/.git", $STUB, $SLOG, $NOCL);

spew("$STUB/claude", <<'STUB');
#!/usr/bin/env perl
use strict;
use warnings;
my $d = $ENV{OL_STUB_DIR} or exit 99;
open my $a, '>:raw', "$d/argv" or exit 98;
print {$a} join("\0", @ARGV);
close $a;
open my $e, '>:raw', "$d/env" or exit 98;
print {$e} 'marker=' . ($ENV{CCPRAXIS_OPEN_LOOPS_EXTRACTOR} // '') . "\n";
print {$e} 'plugin_root=' . (defined $ENV{CLAUDE_PLUGIN_ROOT} ? 'set' : 'unset') . "\n";
close $e;
binmode STDIN, ':raw';
my $in = do { local $/; <STDIN> };
open my $s, '>:raw', "$d/stdin" or exit 98;
print {$s} (defined $in ? $in : '');
close $s;
open my $p, '>', "$d/pid" or exit 98;
print {$p} $$;
close $p;
my $mode = $ENV{OL_STUB_MODE} // 'ok';
if ($mode eq 'sleep')   { sleep 60; exit 0 }
if ($mode eq 'fail')    { print STDERR "stub failure\n"; exit 3 }
if ($mode eq 'garbage') { print "this is not json {{{"; exit 0 }
open my $r, '<:raw', "$d/result" or exit 97;
local $/;
binmode STDOUT, ':raw';
print <$r>;
exit 0;
STUB
chmod 0755, "$STUB/claude";

# stub_result(\%obj) -- what the stub prints: a claude --output-format json
# envelope whose "result" text holds the extractor's JSON (wrapped in a line
# of prose, which the parser must tolerate).
sub stub_result {
    my ($obj) = @_;
    my $inner = JSON::PP->new->canonical->encode($obj);
    my $env = { type => 'result', subtype => 'success', is_error => JSON::PP::false(),
                result => "Here you go:\n$inner\n" };
    spew("$SLOG/result", JSON::PP->new->utf8->canonical->encode($env));
}

sub clear_stub_log { unlink glob("$SLOG/{argv,env,stdin,pid}") }

# ---------------------------------------------------------------------------
# transcript fixture
# ---------------------------------------------------------------------------
sub jl { JSON::PP->new->utf8->canonical->encode($_[0]) . "\n" }

sub write_transcript {
    my ($path, @extra) = @_;
    my $t = '';
    $t .= jl({ type => 'user', message => { role => 'user', content => 'PRE-BOUNDARY question: what about X?' } });
    $t .= jl({ type => 'system', subtype => 'compact_boundary', content => 'Conversation compacted' });
    $t .= jl({ type => 'user', isCompactSummary => JSON::PP::true(), isVisibleInTranscriptOnly => JSON::PP::true(),
               message => { role => 'user', content => "This session is being continued from a previous conversation that ran out of context.\n\nSummary:\nSUMMARY-BODY the operator wanted Y." } });
    $t .= jl({ type => 'user', message => { role => 'user', content => 'Can you also add a --dry-run flag to the exporter? OPERATOR-ONE' } });
    $t .= jl({ type => 'assistant', message => { role => 'assistant', content => [
               { type => 'thinking', thinking => 'SECRET-THINKING' },
               { type => 'text', text => 'Shall I also update the docs? ASSISTANT-OFFER' },
               { type => 'tool_use', id => 'tu1', name => 'Bash', input => { command => 'TOOL-USE-NOISE' } } ] } });
    $t .= jl({ type => 'user', toolUseResult => { stdout => 'x' }, message => { role => 'user', content => [
               { type => 'tool_result', tool_use_id => 'tu1', content => 'TOOL-RESULT-NOISE' } ] } });
    $t .= jl({ type => 'user', isMeta => JSON::PP::true(), message => { role => 'user', content => 'META-NOISE' } });
    $t .= jl({ type => 'user', message => { role => 'user', content => '<command-name>/foo</command-name> COMMAND-NOISE' } });
    $t .= jl({ type => 'user', message => { role => 'user', content => 'x <task-notification>TASK-NOISE</task-notification>' } });
    $t .= jl({ type => 'user', message => { role => 'user', content => '[Subagent hand-back] HANDBACK-NOISE' } });
    $t .= jl({ type => 'user', isSidechain => JSON::PP::true(), message => { role => 'user', content => 'SIDECHAIN-NOISE' } });
    $t .= jl({ type => 'user', message => { role => 'user', content => [
               { type => 'text', text => 'Operator follow-up: what is the timeout? OPERATOR-TWO' } ] } });
    $t .= $_ for @extra;
    spew($path, $t);
}

my $TRANSCRIPT = "$ROOT/transcript.jsonl";
write_transcript($TRANSCRIPT);

# ---------------------------------------------------------------------------
# running things
# ---------------------------------------------------------------------------
sub hook_command {
    my ($event) = @_;
    my $cfg = eval { JSON::PP->new->decode(slurp($HOOKS_JSON) // '') };
    return '' unless ref $cfg eq 'HASH';
    for my $blk (@{ $cfg->{hooks}{$event} || [] }) {
        for my $hk (@{ $blk->{hooks} || [] }) {
            return $hk->{command} if ($hk->{command} // '') =~ /open-loops-gate\.sh/;
        }
    }
    return '';
}

sub base_env {
    my %e = (
        HOME => $HOME, USERPROFILE => $HOME, ALMANAC_HOME => $HOME,
        OL_STUB_DIR => $SLOG, OL_STUB_MODE => 'ok',
        PATH => "$STUB:" . ($ENV{PATH} // ''),
        CLAUDE_PLUGIN_ROOT => $ALM,
    );
    return %e;
}

# run_hook($event, \%payload, %env_overrides) -> { rc, out, err, secs }
# An override of undef deletes the variable.
sub run_hook {
    my ($event, $payload, %over) = @_;
    my $cmd = hook_command($event);
    my $dir = tempdir(CLEANUP => 1);
    spew("$dir/run.sh", "#!/usr/bin/env bash\n$cmd\n");
    spew("$dir/in.json", ref $payload ? JSON::PP->new->utf8->encode($payload) : $payload);
    local %ENV = %ENV;
    delete $ENV{$_} for grep { /^(?:BP_|CLAUDE_|ALMANAC_|CCPRAXIS_OPEN_LOOPS)/ } keys %ENV;
    my %e = (base_env(), %over);
    for my $k (keys %e) {
        if (defined $e{$k}) { $ENV{$k} = $e{$k} } else { delete $ENV{$k} }
    }
    my $t0 = Time::HiRes::time();
    system(qq{bash "$dir/run.sh" < "$dir/in.json" > "$dir/out" 2> "$dir/err"});
    my $rc = $? >> 8;
    return { rc => $rc, out => slurp("$dir/out") // '', err => slurp("$dir/err") // '',
             secs => Time::HiRes::time() - $t0 };
}

sub precompact_payload {
    my (%kv) = @_;
    return { session_id => $kv{sid} // $SID, transcript_path => $kv{transcript} // $TRANSCRIPT,
             cwd => $kv{cwd} // $PROJ, hook_event_name => 'PreCompact', trigger => 'auto',
             custom_instructions => '' };
}

sub start_payload {
    my (%kv) = @_;
    return { session_id => $kv{sid} // $SID, transcript_path => $TRANSCRIPT, cwd => $PROJ,
             hook_event_name => 'SessionStart', source => $kv{source} // 'compact' };
}

# todos() -> [ fields... ] of the temp project, via the CLI.
sub todos {
    local %ENV = %ENV;
    delete $ENV{$_} for grep { /^(?:BP_|CLAUDE_|ALMANAC_)/ } keys %ENV;
    $ENV{HOME} = $HOME; $ENV{USERPROFILE} = $HOME; $ENV{ALMANAC_HOME} = $HOME;
    my $out = `"$^X" "$TODO_PL" list --json --root "$PROJ" 2>/dev/null`;
    my $l = eval { JSON::PP->new->utf8->decode($out) };
    return ref $l eq 'ARRAY' ? $l : [];
}

sub create_todo {
    my ($title, $tags, @set) = @_;
    local %ENV = %ENV;
    delete $ENV{$_} for grep { /^(?:BP_|CLAUDE_|ALMANAC_)/ } keys %ENV;
    $ENV{HOME} = $HOME; $ENV{USERPROFILE} = $HOME; $ENV{ALMANAC_HOME} = $HOME;
    my @args = ($^X, $TODO_PL, 'create', '--root', $PROJ, '--title', $title, '--tags', $tags,
                map { ('--set', $_) } @set);
    my $tmp = "$ROOT/create.out";
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        open STDOUT, '>', $tmp; open STDERR, '>', '/dev/null';
        exec { $args[0] } @args;
        exit 127;
    }
    waitpid($pid, 0);
    my ($id) = (slurp($tmp) // '') =~ /^id: (\S+)/m;
    return $id;
}

sub loops_of {
    my ($tag, $status) = @_;
    return [ grep { ($_->{tags} // '') =~ /(?:^|,)open-loop(?:,|$)/
                    && ($_->{tags} // '') =~ /(?:^|,)\Q$tag\E(?:,|$)/
                    && (!defined $status || ($_->{status} // '') eq $status) } @{ todos() } ];
}

sub log_text { slurp("$HOME/.claude/almanac-state/open-loops/open-loops.log") // '' }

sub assert_fail_open {
    my ($r, $label) = @_;
    is($r->{rc}, 0, "$label: exit 0");
    unlike($r->{out}, qr/"decision"|\bblock\b/i, "$label: no block decision on stdout");
}

# ===========================================================================
# registration
# ===========================================================================
{
    my $cfg = eval { JSON::PP->new->decode(slurp($HOOKS_JSON)) };
    ok(ref $cfg eq 'HASH', 'hooks.json decodes');
    my ($pc) = @{ $cfg->{hooks}{PreCompact} || [] };
    my $pch = $pc ? $pc->{hooks}[0] : {};
    like($pch->{command} // '', qr/\$\{CLAUDE_PLUGIN_ROOT\}\/hooks\/open-loops-gate\.sh/, 'PreCompact runs the gate via ${CLAUDE_PLUGIN_ROOT}');
    like($pch->{command} // '', qr/\Aunset BASH_ENV ; .*\|\| exit 0 ; exec env -u SHELLOPTS bash "\$f"\z/, 'PreCompact uses the plugin wrapper pattern');
    cmp_ok($pch->{timeout} // 0, '>', 240, 'PreCompact timeout exceeds the extractor bound of 240 s');
    my ($ss) = grep { ($_->{hooks}[0]{command} // '') =~ /open-loops-gate/ } @{ $cfg->{hooks}{SessionStart} || [] };
    ok($ss, 'SessionStart registers the gate');
    is($ss->{matcher} // '', 'compact', 'SessionStart is matched to source compact');
    is(system('bash', '-n', $GATE), 0, 'the gate parses under bash -n');
    # Code only: comments may (and do) explain why neither appears.
    (my $src = slurp($SCRIPT) // '') =~ s/(?:^|\s)#.*$//mg;
    unlike($src, qr/"decision"|\bexit\s*\(?\s*2\b|\breturn\s+2\b/, 'the script never prints a decision and never exits 2');
}

# ===========================================================================
# transcript extraction
# ===========================================================================
{
    my $text = `"$^X" "$SCRIPT" transcript-text "$TRANSCRIPT"`;
    like($text, qr/SUMMARY-BODY/, 'extract: the latest compaction summary is included');
    like($text, qr/OPERATOR-ONE/, 'extract: operator string content');
    like($text, qr/OPERATOR-TWO/, 'extract: operator text part');
    like($text, qr/ASSISTANT-OFFER/, 'extract: assistant text part');
    for my $noise (qw(PRE-BOUNDARY SECRET-THINKING TOOL-USE-NOISE TOOL-RESULT-NOISE META-NOISE
                      COMMAND-NOISE TASK-NOISE HANDBACK-NOISE SIDECHAIN-NOISE)) {
        unlike($text, qr/\Q$noise\E/, "extract: $noise is skipped");
    }
    ok(index($text, 'SUMMARY-BODY') < index($text, 'OPERATOR-ONE'), 'extract: the summary comes first');
}

# size cap: ~600 KB after the boundary keeps the newest part, under 400 KB
{
    my $big = "$ROOT/big.jsonl";
    my @extra;
    for my $i (0 .. 299) {
        my $who = $i % 2 ? 'assistant' : 'user';
        my $content = sprintf('MSG-%04d ', $i) . ('lorem ipsum ' x 170);
        push @extra, jl({ type => $who, message => { role => $who,
            content => $who eq 'user' ? $content : [ { type => 'text', text => $content } ] } });
    }
    write_transcript($big, @extra);
    cmp_ok(-s $big, '>', 550_000, 'size cap: the fixture is over the cap');
    my $text = `"$^X" "$SCRIPT" transcript-text "$big"`;
    cmp_ok(length($text), '<=', 400 * 1024, 'size cap: the text is at most 400 KB');
    cmp_ok(length($text), '>', 300 * 1024, 'size cap: the cap is used, not wasted');
    like($text, qr/MSG-0299/, 'size cap: the newest message is kept');
    unlike($text, qr/MSG-0000 /, 'size cap: the oldest message is dropped');
    like($text, qr/SUMMARY-BODY/, 'size cap: the summary is still included');
    like($text, qr/older messages omitted/, 'size cap: the omission is marked');

    clear_stub_log();
    stub_result({ open => [], closed => [] });
    my $r = run_hook('PreCompact', precompact_payload(sid => 'cafe0000-0000-4000-8000-000000000000', transcript => $big));
    is($r->{rc}, 0, 'size cap: hook exits 0 on a large transcript');
    my $in = slurp("$SLOG/stdin") // '';
    cmp_ok(length($in), '<=', 400 * 1024 + 8192, 'size cap: the extractor prompt stays within cap plus instructions');
    like($in, qr/MSG-0299/, 'size cap: the extractor sees the newest message');
}

# ===========================================================================
# PreCompact, first run: files the loops
# ===========================================================================
my ($id_q, $id_o);
{
    clear_stub_log();
    stub_result({
        open => [
            { title => 'Add a --dry-run flag to the exporter', kind => 'request',
              quote => 'Can you also add a --dry-run flag to the exporter?', why_open => 'not implemented yet' },
            { title => 'Offer: update the docs', kind => 'offer',
              quote => 'Shall I also update the docs?', why_open => 'operator never answered' },
            { title => 'Add a --dry-run flag to the exporter', kind => 'request',
              quote => 'duplicate', why_open => 'same title twice' },
        ],
        closed => [ 'no-such-id' ],
    });
    my $r = run_hook('PreCompact', precompact_payload());
    is($r->{rc}, 0, 'first run: exit 0');
    my $loops = loops_of($STAG, 'open');
    is(scalar(@$loops), 2, 'first run: two loops filed (the exact-title duplicate skipped)') or diag(explain(todos()), $r->{err}, log_text());
    my %by = map { $_->{title} => $_ } @$loops;
    my $q = $by{'Open loop: Add a --dry-run flag to the exporter'};
    my $o = $by{'Open loop: Offer: update the docs'};
    ok($q && $o, 'first run: titles carry the "Open loop: " prefix');
    $id_q = $q->{id}; $id_o = $o->{id};
    is($q->{loop_kind}, 'request', 'first run: kind stored');
    is($q->{loop_quote}, 'Can you also add a --dry-run flag to the exporter?', 'first run: quote stored');
    is($q->{session}, $SID, 'first run: full session id stored');
    like($q->{tags}, qr/\Aopen-loop,\Q$STAG\E\z/, 'first run: tags open-loop and session-<8>');

    like($r->{out}, qr/\ACarry these open items into the summary verbatim, with their todo ids/, 'first run: stdout instructs the summary');
    like($r->{out}, qr/\Q$id_q\E/, 'first run: stdout names the first id');
    like($r->{out}, qr/\Q$id_o\E/, 'first run: stdout names the second id');
    unlike($r->{out}, qr/"decision"/, 'first run: no decision JSON');

    my @argv = split /\0/, (slurp("$SLOG/argv") // ''), -1;
    is($argv[0], '-p', 'claude: -p first');
    my $a = join ' ', map { length $_ ? $_ : "''" } @argv;
    like($a, qr/--model sonnet/, 'claude: --model sonnet');
    like($a, qr/--max-turns [1-5]\b/, 'claude: a small --max-turns');
    like($a, qr/--output-format json/, 'claude: --output-format json');
    like($a, qr/--tools ''/, 'claude: no tools');
    like($a, qr/--strict-mcp-config/, 'claude: --strict-mcp-config');
    my $env = slurp("$SLOG/env") // '';
    like($env, qr/^marker=1$/m, 'claude: runs with CCPRAXIS_OPEN_LOOPS_EXTRACTOR=1');
    like($env, qr/^plugin_root=unset$/m, 'claude: the parent CLAUDE_PLUGIN_ROOT is not inherited');
    my $in = slurp("$SLOG/stdin") // '';
    like($in, qr/EXISTING OPEN LOOPS:\n\(none\)/, 'claude: prompt says there are no existing loops');
    like($in, qr/OPERATOR-TWO/, 'claude: prompt carries the transcript text');
    like($in, qr/"open":\[/, 'claude: prompt names the JSON shape');
    like(log_text(), qr/precompact .*ok: filed 2/, 'first run: one log line');
}

# ===========================================================================
# PreCompact, second run: dedup, closing, scoping of "closed"
# ===========================================================================
{
    my $other = create_todo('Open loop: another session', "open-loop,session-ffff0000");
    my $plain = create_todo('An ordinary todo', 'misc');
    ok($other && $plain, 'second run: fixtures created');
    clear_stub_log();
    stub_result({
        open => [
            { title => 'Offer: update the docs', kind => 'offer', quote => 'again', why_open => 'dup of existing' },
            { title => 'Answer: what is the timeout?', kind => 'question',
              quote => 'what is the timeout?', why_open => 'unanswered' },
        ],
        closed => [ $id_q, $other, $plain ],
    });
    my $r = run_hook('PreCompact', precompact_payload());
    is($r->{rc}, 0, 'second run: exit 0');
    my $in = slurp("$SLOG/stdin") // '';
    like($in, qr/\Q$id_q\E/, 'second run: the extractor is shown existing loop ids');
    my %st = map { $_->{id} => $_->{status} } @{ todos() };
    is($st{$id_q}, 'done', 'second run: a closed id of this session is completed');
    is($st{$id_o}, 'open', 'second run: an unmentioned loop stays open');
    is($st{$other}, 'open', "second run: another session's loop is never completed");
    is($st{$plain}, 'open', 'second run: a non-open-loop todo is never completed');
    my $loops = loops_of($STAG, 'open');
    is(scalar(@$loops), 2, 'second run: existing title not refiled, one new loop');
    my @titles = sort map { $_->{title} } @$loops;
    is_deeply(\@titles, ['Open loop: Answer: what is the timeout?', 'Open loop: Offer: update the docs'], 'second run: the right two loops are open');
    unlike($r->{out}, qr/\Q$id_q\E/, 'second run: a closed loop is not in the instructions');
    like($r->{out}, qr/\Q$id_o\E/, 'second run: an open loop is in the instructions');
}

# ===========================================================================
# fail-open variants
# ===========================================================================
{
    my $n_before = scalar @{ todos() };
    for my $mode (qw(garbage fail)) {
        clear_stub_log();
        my $r = run_hook('PreCompact', precompact_payload(), OL_STUB_MODE => $mode);
        assert_fail_open($r, "fail-open ($mode)");
        ok(-f "$SLOG/argv", "fail-open ($mode): the stub ran");
        like($r->{out}, qr/Carry these open items/, "fail-open ($mode): already-filed loops are still listed");
        is(scalar @{ todos() }, $n_before, "fail-open ($mode): nothing filed");
        like(log_text(), qr/precompact .*extractor: /, "fail-open ($mode): logged");
    }

    clear_stub_log();
    my $r = run_hook('PreCompact', precompact_payload(), OL_STUB_MODE => 'sleep', CCPRAXIS_OPEN_LOOPS_TIMEOUT => 2);
    assert_fail_open($r, 'fail-open (timeout)');
    cmp_ok($r->{secs}, '<', 20, 'fail-open (timeout): bounded by the extractor timeout');
    my $pid = slurp("$SLOG/pid");
    ok(defined $pid && $pid =~ /^\d+$/, 'fail-open (timeout): stub recorded its pid');
    ok(!kill(0, $pid), 'fail-open (timeout): the extractor was killed') if defined $pid && $pid =~ /^\d+$/;
    like(log_text(), qr/timeout after 2s/, 'fail-open (timeout): logged');
    is(scalar @{ todos() }, $n_before, 'fail-open (timeout): nothing filed');

    clear_stub_log();
    my $no_claude_path = "$NOCL:/usr/bin:/bin";
    SKIP: {
        my $found = grep { -e "$_/claude" || -e "$_/claude.exe" } split /:/, $no_claude_path;
        skip 'a claude exists in /usr/bin or /bin', 4 if $found;
        my $r2 = run_hook('PreCompact', precompact_payload(), PATH => $no_claude_path);
        assert_fail_open($r2, 'fail-open (no claude)');
        ok(!-f "$SLOG/argv", 'fail-open (no claude): no stub ran');
        like(log_text(), qr/claude not found on PATH/, 'fail-open (no claude): logged');
    }

    my $r3 = run_hook('PreCompact', '{not json');
    assert_fail_open($r3, 'fail-open (bad payload)');
    is($r3->{out}, '', 'fail-open (bad payload): no output');

    my $r4 = run_hook('PreCompact', precompact_payload(transcript => "$ROOT/missing.jsonl"));
    assert_fail_open($r4, 'fail-open (missing transcript)');
    like($r4->{out}, qr/\ACarry these open items/, 'fail-open (missing transcript): the loops already filed are still listed');
    like(log_text(), qr/precompact .*error: transcript not found/, 'fail-open (missing transcript): logged');
}

# ===========================================================================
# guards: recursion, fleet, opt-out
# ===========================================================================
for my $case (
    [ 'recursion guard', CCPRAXIS_OPEN_LOOPS_EXTRACTOR => 1 ],
    [ 'fleet (BP_LEDGER)', BP_LEDGER => "$ROOT/ledger.md" ],
    [ 'fleet (BP_ROLE)', BP_ROLE => 'worker' ],
    [ 'opt-out', CCPRAXIS_OPEN_LOOPS => 'off' ],
) {
    my ($label, %env) = @$case;
    clear_stub_log();
    my $r = run_hook('PreCompact', precompact_payload(), %env);
    is($r->{rc}, 0, "$label: exit 0");
    is($r->{out}, '', "$label: no output");
    ok(!-f "$SLOG/argv", "$label: the extractor is not launched");
    my $s = run_hook('SessionStart', start_payload(), %env);
    is($s->{out}, '', "$label: SessionStart is silent too");
}

# ===========================================================================
# SessionStart
# ===========================================================================
{
    my $r = run_hook('SessionStart', start_payload());
    is($r->{rc}, 0, 'SessionStart compact: exit 0');
    my $d = eval { JSON::PP->new->utf8->decode($r->{out}) };
    ok(ref $d eq 'HASH', 'SessionStart compact: stdout is JSON') or diag($r->{out}, $r->{err});
    my $h = ref $d eq 'HASH' ? $d->{hookSpecificOutput} : {};
    is($h->{hookEventName}, 'SessionStart', 'SessionStart compact: hookEventName');
    my $ctx = $h->{additionalContext} // '';
    like($ctx, qr/\AOpen loops carried over from before compaction\. Close each with `almanac todo complete <id>` when answered or done; raise any still unresolved with the operator\./,
         'SessionStart compact: the guidance line');
    like($ctx, qr/\Q$id_o\E.*Offer: update the docs.*"Shall I also update the docs\?"/, 'SessionStart compact: id, title and quote');
    unlike($ctx, qr/\Q$id_q\E/, 'SessionStart compact: a completed loop is not listed');

    for my $src (qw(startup resume clear)) {
        my $o = run_hook('SessionStart', start_payload(source => $src));
        is($o->{rc}, 0, "SessionStart $src: exit 0");
        is($o->{out}, '', "SessionStart $src: no output");
    }
    my $none = run_hook('SessionStart', start_payload(sid => 'beef0000-0000-4000-8000-000000000000'));
    is($none->{out}, '', 'SessionStart compact: nothing for a session with no loops');
}

# a non-ASCII project path (C:\Users\André\... on the operator's host):
# built from UTF-8 bytes, which every host accepts as a file name
{
    my $np = "$ROOT/proj-Andr\xc3\xa9";
    make_path("$np/.git");
    clear_stub_log();
    stub_result({ open => [ { title => "Caf\x{e9} question", kind => 'question',
                              quote => "pourquoi caf\x{e9}?", why_open => 'unanswered' } ], closed => [] });
    my $sid = 'eeee0000-0000-4000-8000-000000000000';
    my $r = run_hook('PreCompact', precompact_payload(sid => $sid, cwd => do { my $c = $np; utf8::decode($c); $c }));
    is($r->{rc}, 0, 'non-ASCII project: exit 0');
    my @files = glob("$np/.ccpraxis-local-data/almanac/todo/*.md");
    is(scalar(@files), 1, 'non-ASCII project: the todo lands in that project') or diag($r->{err}, log_text());
    my $body = @files ? slurp($files[0]) // '' : '';
    like($body, qr/title: Open loop: Caf\xc3\xa9 question/, 'non-ASCII project: the title is UTF-8, encoded once');
    like($r->{out}, qr/Caf\xc3\xa9 question/, 'non-ASCII project: instructions are UTF-8, encoded once');
}

# truncation under the 10,000-character limit
{
    my $sid = 'dddd0000-0000-4000-8000-000000000000';
    my $tag = 'session-dddd0000';
    for my $i (1 .. 24) {
        create_todo(sprintf('Open loop: long item %02d ', $i) . ('t' x 150), "open-loop,$tag",
                    'loop_kind=question', 'loop_quote=' . ('q' x 290));
    }
    my $r = run_hook('SessionStart', start_payload(sid => $sid));
    my $d = eval { JSON::PP->new->utf8->decode($r->{out}) };
    my $ctx = ref $d eq 'HASH' ? $d->{hookSpecificOutput}{additionalContext} // '' : '';
    cmp_ok(length($ctx), '<', 10_000, 'truncation: additionalContext under 10,000 characters');
    like($ctx, qr/\.\.\. and (\d+) more/, 'truncation: the remainder is counted');
    my ($more) = $ctx =~ /\.\.\. and (\d+) more/;
    my $shown = () = $ctx =~ /^- \[/mg;
    is(($more // 0) + $shown, 24, 'truncation: shown plus counted equals the total');
}

done_testing();
