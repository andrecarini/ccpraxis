#!/usr/bin/env perl
# platform: any
# Never-halt package 08 — a read-only signature scan of the installed claude
# binary for the undocumented internals ccpraxis settings quietly rely on
# (the ticklish-whisper timed fallback, the auto-mode denial limits, the
# subagent classifier-abort string, and the disableAgentView/disableWorkflows
# gates). A Claude Code update can rename or drop any of these with no error;
# this suite pins the contract of the checker script, its data file schema,
# the update-skill step that runs it, and the helper dispatch that exposes it
# standalone.
#
# Every scenario below runs the REAL script as a subprocess against small
# fixture files built in a tempdir. No test here reads or scans the operator's
# real claude.exe, and none spawns claude.
#
# AC1  a full fixture (every signature present) -> exit 0, all PRESENT
# AC2  a fixture missing one entry's signatures -> exit 1, that entry CHANGED
# AC3  the denial-limits regex tolerates whitespace, rejects a wrong number
# AC4  a missing/non-file --binary exits 2 with a precise message
# AC5  the binary is opened read-only; the script source never spawns
# AC6  the data file schema is validated (a/shipped, b/violations, c/content)
# AC7  SKILL.md gains a Step 9 between Step 8 and Maintenance
# AC8  update-research.t stays green
# AC9  the chunked scan is correct at every straddle offset, at the lookahead
#      edge case, and refuses an invalid seam
# AC10 PATH resolution, including a non-ASCII directory name
# AC11 the ccpraxis-helpers.pl dispatch mirrors the direct script exactly
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use Storable qw(dclone);
use JSON::PP ();
use Config;
use StewardTest qw(ok is like unlike done_testing diag);

# Resolve an absolute perl interpreter path BEFORE any test overrides PATH
# (AC10 does, deliberately, to a fixture-only directory). $^X can be the
# bare string "perl" on this host (Git-for-Windows perl, $^O eq 'cygwin'),
# and a bare name only resolves via PATH at spawn time -- so once PATH is
# fixture-only, the child shell can't find perl at all (exit 127), and the
# script under test never runs. Resolve once, against the ORIGINAL PATH,
# and reuse that absolute path for every subprocess spawn in this file.
my $PERL_BIN = do {
    my $x = $^X;
    if (File::Spec_is_absolute($x)) {
        $x;
    } elsif ($Config{perlpath} && File::Spec_is_absolute($Config{perlpath}) && -x $Config{perlpath}) {
        $Config{perlpath};
    } else {
        my $found;
        my @exts = ($^O eq 'MSWin32' || $^O eq 'msys' || $^O eq 'cygwin') ? ('', '.exe') : ('');
        DIR: for my $dir (split /;|:/, $ENV{PATH} // '') {
            next unless length $dir;
            for my $ext (@exts) {
                my $cand = "$dir/$x$ext";
                if (-f $cand && -x _) { $found = $cand; last DIR; }
            }
        }
        $found // $x;
    }
};

sub File::Spec_is_absolute {
    my ($p) = @_;
    return $p =~ m{^(?:[A-Za-z]:[\\/]|[\\/])} ? 1 : 0;
}

my $PLUGIN_DIR   = "$Bin/../..";
my $SCRIPT       = "$PLUGIN_DIR/scripts/claude-internals-check.pl";
my $DATA         = "$PLUGIN_DIR/scripts/claude-internals.json";
my $HELPER       = "$PLUGIN_DIR/scripts/ccpraxis-helpers.pl";
my $SKILL        = "$PLUGIN_DIR/skills/update/SKILL.md";
my $ABOUT_SCRIPT = "$SCRIPT.about";
my $ABOUT_DATA   = "$DATA.about";

my $HAVE_SCRIPT = -f $SCRIPT ? 1 : 0;
my $HAVE_DATA   = -f $DATA   ? 1 : 0;
ok($HAVE_SCRIPT, 'precondition: claude-internals-check.pl exists');
ok($HAVE_DATA,   'precondition: claude-internals.json exists');

my $ROOT = tempdir(CLEANUP => 1);

# ---------------------------------------------------------------------------
# The five entries of spec 2.1.2, fully formed. Used as (a) the oracle AC6c
# compares the shipped file against, and (b) the base for building
# self-contained, valid data files for tests that don't specifically exercise
# the shipped file or the "build fixtures from the shipped file" recipe.
my @EXPECTED = (
    { id => 'ticklish-whisper-timed-fallback',
      description => "Auto mode's main-session consecutive-denial prompt auto-denies after a timeout (default 120000 ms) instead of waiting forever.",
      relied_by   => 'global-config/settings.json env.CLAUDE_CODE_TICKLISH_WHISPER=1',
      found_in    => { version => '2.1.282', date => '2026-09-26' },
      signatures  => [
          { type => 'regex',   value => 'CLAUDE_CODE_TICKLISH_WHISPER(?!_)', example => 'Dn.CLAUDE_CODE_TICKLISH_WHISPER;' },
          { type => 'literal', value => 'CLAUDE_CODE_TICKLISH_WHISPER_TIMEOUT_MS' },
          { type => 'literal', value => 'tengu_ticklish_whisper' },
          { type => 'literal', value => 'autoDenyAfterMs' },
      ] },
    { id => 'auto-mode-denial-limits',
      description => 'Auto mode escalates to a blocking prompt after 3 consecutive or 20 total classifier denials.',
      relied_by   => 'never-halt hooks (Decisions 10, 15): BpHook::DenialBreaker trips at $MAX_CONSECUTIVE=2 / $MAX_TOTAL=17, one below these limits ($AUTO_MODE_MAX_CONSECUTIVE / $AUTO_MODE_MAX_TOTAL)',
      found_in    => { version => '2.1.282', date => '2026-09-26' },
      signatures  => [
          { type => 'regex', value => 'maxConsecutive\s*:\s*3\s*,\s*maxTotal\s*:\s*20\b', example => 'maxConsecutive:3,maxTotal:20' },
      ] },
    { id => 'subagent-classifier-abort',
      description => 'A subagent at its denial limit aborts with "too many classifier denials".',
      relied_by   => 'never-halt hooks (Decision 10): subagent abort at the denial limit',
      found_in    => { version => '2.1.282', date => '2026-09-26' },
      signatures  => [ { type => 'literal', value => 'too many classifier denials' } ] },
    { id => 'disable-agent-view-gate',
      description => 'The disableAgentView setting gates the agent view off.',
      relied_by   => 'global-config/settings.json disableAgentView: true',
      found_in    => { version => '2.1.282', date => '2026-09-26' },
      signatures  => [ { type => 'literal', value => "is disabled by the 'disableAgentView' setting" } ] },
    { id => 'disable-workflows-gate',
      description => 'The disableWorkflows setting gates the Workflows feature off.',
      relied_by   => 'global-config/settings.json disableWorkflows: true',
      found_in    => { version => '2.1.282', date => '2026-09-26' },
      signatures  => [ { type => 'regex', value => 'settings\.disableWorkflows\s*===\s*!0', example => 'settings.disableWorkflows===!0' } ] },
    # never-halt package 07 (spec sec 8 C4, Decision 44): three entries the
    # breaker newly relies on, appended after the original five, each with
    # relied_by naming BpHook::DenialBreaker.
    { id => 'auto-mode-safe-allowlist',
      description => 'Auto mode skips the classifier for a tool on its static safe allowlist, logging that it is on the safe allowlist.',
      relied_by   => 'never-halt hooks (Decision 15): BpHook::DenialBreaker\'s @CLASSIFIER_EXEMPT_TOOLS mirrors this allowlist (F3)',
      found_in    => { version => '2.1.282', date => '2026-09-26' },
      signatures  => [ { type => 'literal', value => 'tool is on the safe allowlist' } ] },
    { id => 'bash-rule-trailing-wildcard',
      description => 'A Bash permissions.allow rule body ending " *" also matches the command with that trailing word omitted.',
      relied_by   => 'never-halt hooks (Decision 15): BpHook::DenialBreaker::allow_listed\'s wildcard-matching algorithm (F4)',
      found_in    => { version => '2.1.282', date => '2026-09-26' },
      signatures  => [ { type => 'literal', value => '.endsWith(" .*")' } ] },
    { id => 'post-tool-use-failure-event',
      description => 'PostToolUseFailure fires only after a tool call has started running, never for a permission denial.',
      relied_by   => 'never-halt hooks (Decision 15): BpHook::DenialBreaker registers on PostToolUseFailure to reset its mirror (F5)',
      found_in    => { version => '2.1.282', date => '2026-09-26' },
      signatures  => [ { type => 'literal', value => 'hook_event_name:"PostToolUseFailure"' } ] },
);

# ---------------------------------------------------------------------------
# Helpers

sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return '';
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

sub write_bin {
    my ($path, $bytes) = @_;
    my $dir = dirname($path);
    make_path($dir) unless -d $dir;
    open my $fh, '>:raw', $path or die "write $path: $!";
    print {$fh} $bytes;
    close $fh;
}

sub write_raw_data {
    my ($path, $obj) = @_;
    write_bin($path, JSON::PP->new->canonical->encode($obj));
}

sub write_self_data {
    my ($path, $entries) = @_;
    my $obj = { schema => 1, entries => $entries };
    write_raw_data($path, $obj);
    return $obj;
}

sub read_json_file_raw {
    my ($path) = @_;
    return undef unless -f $path;
    my $raw = slurp($path);
    return eval { JSON::PP->new->decode($raw) };
}

sub sample_of { my ($sig) = @_; return $sig->{type} eq 'literal' ? $sig->{value} : $sig->{example}; }
sub entry_samples { my ($entry) = @_; return map { sample_of($_) } @{ $entry->{signatures} }; }

# Build a fixture byte-string from a list of entries, in order. %opts:
#   exclude_id => an id whose samples are omitted entirely
#   override   => { id => [sample, ...] } replaces that entry's sample list
sub build_fixture {
    my ($entries, %opts) = @_;
    my @parts;
    for my $e (@$entries) {
        next if defined $opts{exclude_id} && $e->{id} eq $opts{exclude_id};
        if ($opts{override} && exists $opts{override}{ $e->{id} }) {
            push @parts, @{ $opts{override}{ $e->{id} } };
        } else {
            push @parts, entry_samples($e);
        }
    }
    my $filler = ('~' x 173) . "\n" . ('#' x 211) . "\n";
    return $filler . join("\0\xff\0", @parts) . $filler;
}

sub arrays_equal {
    my ($a, $b) = @_;
    return 0 unless ref $a eq 'ARRAY' && ref $b eq 'ARRAY';
    return 0 unless @$a == @$b;
    for my $i (0 .. $#$a) {
        return 0 unless defined $a->[$i] && defined $b->[$i] && $a->[$i] eq $b->[$i];
    }
    return 1;
}

my $RUN_N = 0;

# run(args => [...], path => "PATH value", chunk => N, overlap => N, home => dir)
# Spawns the REAL script as a subprocess. HOME/USERPROFILE point at a tempdir
# so the script never reads the operator's own state. stderr goes to a file,
# never merged into stdout, so the JSON parse can't be corrupted by it.
sub run {
    my (%opt) = @_;
    local %ENV = %ENV;
    my $home = $opt{home} // "$ROOT/home";
    make_path($home) unless -d $home;
    $ENV{HOME}        = $home;
    $ENV{USERPROFILE} = $home;
    if (exists $opt{path}) { $ENV{PATH} = $opt{path} }
    if (exists $opt{chunk})   { $ENV{CLAUDE_INTERNALS_CHUNK_BYTES}   = $opt{chunk} }   else { delete $ENV{CLAUDE_INTERNALS_CHUNK_BYTES} }
    if (exists $opt{overlap}) { $ENV{CLAUDE_INTERNALS_OVERLAP_BYTES} = $opt{overlap} } else { delete $ENV{CLAUDE_INTERNALS_OVERLAP_BYTES} }

    $RUN_N++;
    my $errf = "$ROOT/stderr.$RUN_N";
    my @args = @{ $opt{args} // [] };
    my $cmd  = join ' ', map { qq{"$_"} } ($PERL_BIN, $SCRIPT, @args);
    my $raw  = `$cmd 2>"$errf"`;
    my $exit = $? >> 8;
    my $err  = slurp($errf);
    my $json = eval { JSON::PP->new->utf8->decode($raw) };
    return { json => (ref $json eq 'HASH' ? $json : undef), exit => $exit, raw => $raw, stderr => $err };
}

sub run_helper {
    my (@args) = @_;
    $RUN_N++;
    my $errf = "$ROOT/stderr.h.$RUN_N";
    my $cmd  = join ' ', map { qq{"$_"} } ($^X, $HELPER, 'claude-internals', @args);
    my $raw  = `$cmd 2>"$errf"`;
    my $exit = $? >> 8;
    my $json = eval { JSON::PP->new->utf8->decode($raw) };
    return { json => (ref $json eq 'HASH' ? $json : undef), exit => $exit, raw => $raw };
}

# ===========================================================================
# AC1 — a full fixture reports all PRESENT and exits 0.
AC1: {
    unless ($HAVE_SCRIPT && $HAVE_DATA) {
        ok(0, 'AC1: a full fixture exits 0, status ok, every entry PRESENT, changed empty');
        last AC1;
    }
    my $data = read_json_file_raw($DATA);
    unless (ref $data eq 'HASH' && ref $data->{entries} eq 'ARRAY' && @{ $data->{entries} }) {
        ok(0, 'AC1: the shipped data file parses to schema 1 with entries (blocked: it does not)');
        last AC1;
    }
    my @entries = @{ $data->{entries} };
    my $bin = "$ROOT/ac1-full.bin";
    write_bin($bin, build_fixture(\@entries));
    my $r = run(args => [ '--binary', $bin ]);
    is($r->{exit}, 0, 'AC1: full fixture exits 0') or diag($r->{raw} . $r->{stderr});
    is(($r->{json}{status} // ''), 'ok', 'AC1: status is "ok"');
    my $present_ok = $r->{json}
        && ref $r->{json}{entries} eq 'ARRAY'
        && @{ $r->{json}{entries} } == @entries
        && !grep { ($_->{state} // '') ne 'PRESENT' } @{ $r->{json}{entries} };
    ok($present_ok, 'AC1: every entries[].state is PRESENT, one per data-file entry');
    is(scalar(@{ $r->{json}{changed} // ['x'] }), 0, 'AC1: changed[] is empty');
}

# ===========================================================================
# AC2 — a fixture missing one entry's signatures reports that entry CHANGED.
AC2: {
    unless ($HAVE_SCRIPT && $HAVE_DATA) {
        ok(0, 'AC2: omitting subagent-classifier-abort -> exit 1, that entry CHANGED, others PRESENT');
        last AC2;
    }
    my $data = read_json_file_raw($DATA);
    my @entries = ref $data eq 'HASH' && ref $data->{entries} eq 'ARRAY' ? @{ $data->{entries} } : ();
    my ($target) = grep { ($_->{id} // '') eq 'subagent-classifier-abort' } @entries;
    unless ($target) {
        ok(0, 'AC2: the shipped data file has a subagent-classifier-abort entry to omit (blocked)');
        last AC2;
    }
    my $bin = "$ROOT/ac2.bin";
    write_bin($bin, build_fixture(\@entries, exclude_id => 'subagent-classifier-abort'));
    my $r = run(args => [ '--binary', $bin ]);
    is($r->{exit}, 1, 'AC2: fixture missing one entry exits 1') or diag($r->{raw} . $r->{stderr});
    is(($r->{json}{status} // ''), 'changed', 'AC2: status is "changed"');
    my ($e) = grep { ($_->{id} // '') eq 'subagent-classifier-abort' } @{ $r->{json}{entries} // [] };
    ok($e, 'AC2: subagent-classifier-abort appears in entries[]');
    if ($e) {
        is(($e->{state} // ''), 'CHANGED', 'AC2: subagent-classifier-abort is CHANGED');
        ok(arrays_equal($e->{missing} // [], ['too many classifier denials']),
           'AC2: missing lists exactly the absent signature value')
            or diag('  got: ' . JSON::PP->new->canonical->encode($e->{missing} // []));
    }
    my $others_present = !grep { ($_->{id} // '') ne 'subagent-classifier-abort' && ($_->{state} // '') ne 'PRESENT' }
                          @{ $r->{json}{entries} // [] };
    ok($others_present, 'AC2: every other entry is PRESENT');
    is(scalar(@{ $r->{json}{changed} // [] }), 1, 'AC2: changed[] holds exactly one entry');
    is((($r->{json}{changed} // [])->[0]{relied_by} // ''), $target->{relied_by},
       'AC2: changed[0].relied_by equals the data file value');
    like($r->{stderr}, qr/CHANGED subagent-classifier-abort:/, 'AC2: stderr names the CHANGED entry');
}

# ===========================================================================
# AC3 — the denial-limits regex tolerates whitespace, rejects a wrong number.
AC3: {
    unless ($HAVE_SCRIPT && $HAVE_DATA) {
        ok(0, "AC3: denial-limits regex whitespace variant matches ($_)")
            for ('maxConsecutive:3,maxTotal:20', 'maxConsecutive: 3, maxTotal: 20',
                 "maxConsecutive :3,\\n\\tmaxTotal:\\t20");
        ok(0, 'AC3: denial-limits regex rejects maxConsecutive:4,maxTotal:20');
        last AC3;
    }
    my $data = read_json_file_raw($DATA);
    my @entries = ref $data eq 'HASH' && ref $data->{entries} eq 'ARRAY' ? @{ $data->{entries} } : ();
    my ($dl) = grep { ($_->{id} // '') eq 'auto-mode-denial-limits' } @entries;
    unless ($dl) {
        ok(0, 'AC3: the shipped data file has an auto-mode-denial-limits entry (blocked)');
        last AC3;
    }
    my $vc = 0;
    for my $variant (
        [ 'maxConsecutive:3,maxTotal:20',           1 ],
        [ 'maxConsecutive: 3, maxTotal: 20',        1 ],
        [ "maxConsecutive :3,\n\tmaxTotal:\t20",    1 ],
        [ 'maxConsecutive:4,maxTotal:20',           0 ],
    ) {
        my ($text, $should_match) = @$variant;
        $vc++;
        my $bin = "$ROOT/ac3-$vc.bin";
        write_bin($bin, build_fixture(\@entries, override => { $dl->{id} => [$text] }));
        my $r = run(args => [ '--binary', $bin ]);
        if ($should_match) {
            is($r->{exit}, 0, "AC3: denial-limits regex matches variant [$text]") or diag($r->{raw} . $r->{stderr});
        } else {
            is($r->{exit}, 1, "AC3: denial-limits regex rejects [$text]") or diag($r->{raw} . $r->{stderr});
            my ($e) = grep { ($_->{id} // '') eq 'auto-mode-denial-limits' } @{ $r->{json}{entries} // [] };
            is(($e->{state} // '') , 'CHANGED', 'AC3: auto-mode-denial-limits is CHANGED for the rejected variant') if $e;
        }
    }
}

# ===========================================================================
# AC4 — a missing or non-file --binary exits 2 with a precise message.
AC4: {
    unless ($HAVE_SCRIPT) {
        ok(0, 'AC4: a nonexistent --binary path exits 2 with "binary not found: <path>"');
        ok(0, 'AC4: a directory as --binary exits 2 with "binary is not a regular file: <path>"');
        last AC4;
    }
    my $data_path = "$ROOT/ac4-data.json";
    write_self_data($data_path, \@EXPECTED);

    my $missing = "$ROOT/nope-$$.bin";
    my $r = run(args => [ '--binary', $missing, '--data', $data_path ]);
    is($r->{exit}, 2, 'AC4: nonexistent --binary path exits 2');
    is(($r->{json}{status} // ''), 'error', 'AC4: JSON status is "error" for a missing binary');
    like(($r->{json}{error} // ''), qr/binary not found/, 'AC4: error matches /binary not found/');
    ok(index(($r->{json}{error} // ''), $missing) >= 0, 'AC4: error contains the missing path');
    like($r->{stderr}, qr/binary not found/, 'AC4: stderr also carries the message');
    like($r->{stderr}, qr/^claude-internals-check: /, 'AC4: stderr is prefixed "claude-internals-check: "');

    my $dir = "$ROOT/a-directory";
    make_path($dir);
    my $r2 = run(args => [ '--binary', $dir, '--data', $data_path ]);
    is($r2->{exit}, 2, 'AC4: a directory as --binary exits 2');
    like(($r2->{json}{error} // ''), qr/not a regular file/, 'AC4: error matches /not a regular file/');
    ok(index(($r2->{json}{error} // ''), $dir) >= 0, 'AC4: error contains the directory path');

    # NIT7: the --binary=<path> / --data=<path> single-token forms work the
    # same as the two-token forms exercised everywhere else in this file.
    my $full_bin = "$ROOT/ac4-eq.bin";
    my $eq_data  = read_json_file_raw($data_path);
    write_bin($full_bin, build_fixture($eq_data->{entries}));
    my $r3 = run(args => [ "--binary=$full_bin", "--data=$data_path" ]);
    is($r3->{exit}, 0, 'AC4: the --binary=<path> and --data=<path> single-token forms work')
        or diag($r3->{raw} . $r3->{stderr});
}

# ===========================================================================
# AC5 — the binary is opened read-only; the script source never spawns.
AC5: {
    unless ($HAVE_SCRIPT) {
        ok(0, 'AC5: a scanned fixture keeps its size, mtime and bytes unchanged');
        ok(0, 'AC5: the script source contains no process-spawning construct');
        last AC5;
    }
    my $data_path = "$ROOT/ac5-data.json";
    my $obj = write_self_data($data_path, \@EXPECTED);
    my $bin = "$ROOT/ac5.bin";
    write_bin($bin, build_fixture($obj->{entries}));

    my $past = time() - 100000;
    utime($past, $past, $bin) or diag("utime failed: $!");
    my @before = stat($bin);
    my $bytes_before = slurp($bin);

    my $r = run(args => [ '--binary', $bin, '--data', $data_path ]);
    diag($r->{raw} . $r->{stderr}) unless defined $r->{json};

    my @after = stat($bin);
    is($after[7], $before[7], 'AC5: fixture size is unchanged after the run');
    is($after[9], $before[9], 'AC5: fixture mtime is unchanged after the run');
    ok($bytes_before eq slurp($bin), 'AC5: fixture bytes are unchanged after the run');

    my $src = slurp($SCRIPT);
    ok(length($src) > 0, 'AC5: precondition: the script source is readable');
    my $stripped = join "\n", grep { !/^\s*#/ } split /\n/, $src;
    ok($stripped !~ /\bsystem\s*\(/,       'AC5: script source contains no system(...)');
    ok($stripped !~ /\bexec\s*\(/,         'AC5: script source contains no exec(...)');
    ok($stripped !~ /\bqx\b/,              'AC5: script source contains no qx');
    ok($stripped !~ /`/,                   'AC5: script source contains no backtick');
    ok($stripped !~ /\bfork\b/,            'AC5: script source contains no fork');
    ok($stripped !~ /IPC::Open/,           'AC5: script source contains no IPC::Open2/Open3');
    ok($stripped !~ /IPC::Cmd/,            'AC5: script source contains no IPC::Cmd');
    ok($stripped !~ /open\s*\(?[^)\n]*(['"])-\|\1/ && $stripped !~ /open\s*\(?[^)\n]*(['"])\|-\1/,
       'AC5: script source contains no piped open (\'-|\' or \'|-\')');
    # NIT8: also catch the 2-arg form, e.g. open(FH, "cmd |") or open(FH, "| cmd"),
    # which the 3-arg-only '-|'/'|-' check above would miss.
    ok($stripped !~ /open\s*\([^)\n]*['"][^'"\n]*\|\s*['"]/,
       'AC5: script source contains no 2-arg piped open (trailing "cmd |")');
    ok($stripped !~ /open\s*\([^)\n]*['"]\s*\|[^'"\n]*['"]/,
       'AC5: script source contains no 2-arg piped open (leading "| cmd")');
}

# ===========================================================================
# AC6a — the shipped data file self-validates.
AC6a: {
    unless ($HAVE_DATA) {
        ok(0, 'AC6a: the shipped data file validates (id/description/relied_by/signatures, unique ids, regexes match their examples)');
        last AC6a;
    }
    my $data = read_json_file_raw($DATA);
    unless (ref $data eq 'HASH') {
        ok(0, 'AC6a: the shipped data file parses as a JSON object');
        last AC6a;
    }
    is(($data->{schema} // 0), 1, 'AC6a: schema is 1');
    my @entries = ref $data->{entries} eq 'ARRAY' ? @{ $data->{entries} } : ();
    ok(scalar(@entries) > 0, 'AC6a: entries is a non-empty array');

    my %seen_ids;
    my $all_ok = 1;
    for my $e (@entries) {
        my $id = $e->{id} // '';
        $all_ok = 0 unless $id =~ /^[a-z0-9]+(-[a-z0-9]+)*\z/;
        $all_ok = 0 if $seen_ids{$id}++;
        $all_ok = 0 unless length($e->{description} // '');
        $all_ok = 0 unless length($e->{relied_by} // '');
        $all_ok = 0 unless ref $e->{signatures} eq 'ARRAY' && @{ $e->{signatures} };
        for my $s (@{ $e->{signatures} // [] }) {
            my $t = $s->{type} // '';
            if ($t eq 'regex') {
                my $re = eval { qr/$s->{value}/ };
                $all_ok = 0 if $@ || !$re;
                $all_ok = 0 unless defined $s->{example} && length($s->{example});
                $all_ok = 0 if $re && defined $s->{example} && $s->{example} !~ $re;
            } elsif ($t eq 'literal') {
                $all_ok = 0 unless defined $s->{value} && length($s->{value});
            } else {
                $all_ok = 0;
            }
        }
    }
    ok($all_ok, 'AC6a: every entry has a valid id/description/relied_by/signatures; ids unique; every regex compiles and matches its example');
}

# ===========================================================================
# AC6b — a fixture data file with a schema violation exits 2, naming the
# entry (id, or 0-based index when it has none) and the rule it broke.
AC6b: {
    my @labels = ('missing id', 'duplicate id', 'empty description', 'missing relied_by',
                  'empty signatures', 'unknown signature type', 'regex not matching its example', 'lookbehind');
    unless ($HAVE_SCRIPT) {
        ok(0, "AC6b: invalid data file ($_) exits 2 naming the entry and the rule") for @labels;
        last AC6b;
    }

    my $valid_bin = "$ROOT/ac6b-bin.bin";
    write_bin($valid_bin, "irrelevant filler -- data validation happens before the binary is touched\n");

    my %cases = (
        'missing id' => sub {
            my $e = dclone(\@EXPECTED);
            delete $e->[0]{id};
            return ($e, qr/\b0\b/, qr/\bid\b/i);
        },
        'duplicate id' => sub {
            my $e = dclone(\@EXPECTED);
            $e->[1]{id} = $e->[0]{id};
            return ($e, qr/\Q$e->[0]{id}\E/, qr/duplicate/i);
        },
        'empty description' => sub {
            my $e = dclone(\@EXPECTED);
            $e->[2]{description} = '';
            return ($e, qr/\Q$e->[2]{id}\E/, qr/description/i);
        },
        'missing relied_by' => sub {
            my $e = dclone(\@EXPECTED);
            delete $e->[3]{relied_by};
            return ($e, qr/\Q$e->[3]{id}\E/, qr/relied_by/i);
        },
        'empty signatures' => sub {
            my $e = dclone(\@EXPECTED);
            $e->[4]{signatures} = [];
            return ($e, qr/\Q$e->[4]{id}\E/, qr/signature/i);
        },
        'unknown signature type' => sub {
            my $e = dclone(\@EXPECTED);
            $e->[0]{signatures}[0]{type} = 'regexp';
            return ($e, qr/\Q$e->[0]{id}\E/, qr/type/i);
        },
        'regex not matching its example' => sub {
            my $e = dclone(\@EXPECTED);
            $e->[1]{signatures}[0]{example} = 'this text does not contain the pattern';
            return ($e, qr/\Q$e->[1]{id}\E/, qr/example|match/i);
        },
        'lookbehind' => sub {
            my $e = dclone(\@EXPECTED);
            $e->[0]{signatures}[0]{type}    = 'regex';
            $e->[0]{signatures}[0]{value}   = '(?<=X)Y';
            $e->[0]{signatures}[0]{example} = 'XY';
            return ($e, qr/\Q$e->[0]{id}\E/, qr/lookbehind/i);
        },
    );

    my $vc = 0;
    for my $label (@labels) {
        $vc++;
        my ($entries, $name_re, $rule_re) = $cases{$label}->();
        my $path = "$ROOT/ac6b-$vc.json";
        write_self_data($path, $entries);
        my $r = run(args => [ '--binary', $valid_bin, '--data', $path ]);
        is($r->{exit}, 2, "AC6b: invalid data file ($label) exits 2") or diag($r->{raw} . $r->{stderr});
        is(($r->{json}{status} // ''), 'error', "AC6b: invalid data file ($label) reports status error");
        like(($r->{json}{error} // ''), $name_re, "AC6b: invalid data file ($label) names the entry (id or index)");
        like(($r->{json}{error} // ''), $rule_re, "AC6b: invalid data file ($label) names the rule it broke");
    }

    my ($entries) = $cases{'missing relied_by'}->();
    my $path = "$ROOT/ac6b-stderr.json";
    write_self_data($path, $entries);
    my $r = run(args => [ '--binary', $valid_bin, '--data', $path ]);
    like($r->{stderr}, qr/^claude-internals-check: /, 'AC6b: stderr is prefixed "claude-internals-check: " for a data-file error too');
    like($r->{stderr}, qr/relied_by/i, 'AC6b: stderr carries the same message as the stdout JSON error');
}

# ===========================================================================
# AC6c — the shipped file has exactly the eight ids (never-halt 07, spec sec
# 8 C4, adds three to the original five), and their literal/regex signature
# values match the spec table exactly. The auto-mode-denial-limits entry's
# relied_by is also pinned to the exact never-halt 07 text (spec sec 2.11),
# and each of the three new entries' relied_by names BpHook::DenialBreaker.
AC6c: {
    unless ($HAVE_DATA) {
        ok(0, 'AC6c: the shipped file has the eight expected ids, in order');
        ok(0, 'AC6c: the shipped literal and regex signature values match the spec table exactly');
        ok(0, 'AC6c: auto-mode-denial-limits relied_by names BpHook::DenialBreaker and the $MAX_CONSECUTIVE/$MAX_TOTAL constants');
        ok(0, 'AC6c: each of the three new never-halt 07 entries relied_by names BpHook::DenialBreaker');
        last AC6c;
    }
    my $data = read_json_file_raw($DATA);
    unless (ref $data eq 'HASH' && ref $data->{entries} eq 'ARRAY') {
        ok(0, 'AC6c: the shipped file has the eight expected ids, in order (blocked: file did not parse)');
        ok(0, 'AC6c: the shipped literal and regex signature values match the spec table exactly (blocked)');
        ok(0, 'AC6c: auto-mode-denial-limits relied_by names BpHook::DenialBreaker and the $MAX_CONSECUTIVE/$MAX_TOTAL constants (blocked)');
        ok(0, 'AC6c: each of the three new never-halt 07 entries relied_by names BpHook::DenialBreaker (blocked)');
        last AC6c;
    }
    my @entries      = @{ $data->{entries} };
    my @ids          = map { $_->{id} // '' } @entries;
    my @expected_ids = map { $_->{id} } @EXPECTED;
    is(scalar(@expected_ids), 8, 'AC6c precondition: this file\'s own fixture table has exactly eight expected ids');
    ok(arrays_equal(\@ids, \@expected_ids), 'AC6c: the shipped file has exactly the eight expected ids, in order')
        or diag('  got: ' . join(',', @ids));

    my $sig_ok = 1;
    for my $i (0 .. $#EXPECTED) {
        my $exp = $EXPECTED[$i];
        my $got = $entries[$i];
        unless ($got) { $sig_ok = 0; next; }
        my @exp_sigs = @{ $exp->{signatures} };
        my @got_sigs = ref $got->{signatures} eq 'ARRAY' ? @{ $got->{signatures} } : ();
        $sig_ok = 0 unless @exp_sigs == @got_sigs;
        for my $j (0 .. $#exp_sigs) {
            my $es = $exp_sigs[$j];
            my $gs = $got_sigs[$j] // {};
            $sig_ok = 0 unless ($gs->{type}  // '') eq $es->{type};
            $sig_ok = 0 unless ($gs->{value} // '') eq $es->{value};
            $sig_ok = 0 if $es->{type} eq 'regex' && ($gs->{example} // '') ne $es->{example};
        }
    }
    ok($sig_ok, 'AC6c: literal and regex signature values match the spec table exactly, entry by entry');

    my ($dl_got) = grep { ($_->{id} // '') eq 'auto-mode-denial-limits' } @entries;
    my ($dl_exp) = grep { $_->{id} eq 'auto-mode-denial-limits' } @EXPECTED;
    is(($dl_got->{relied_by} // ''), $dl_exp->{relied_by},
       'AC6c: auto-mode-denial-limits relied_by equals the never-halt 07 text exactly (spec sec 2.11)')
        if $dl_got && $dl_exp;
    ok(0, 'AC6c: auto-mode-denial-limits relied_by equals the never-halt 07 text exactly (spec sec 2.11; entry missing)')
        unless $dl_got && $dl_exp;

    my @new_ids = qw(auto-mode-safe-allowlist bash-rule-trailing-wildcard post-tool-use-failure-event);
    for my $id (@new_ids) {
        my ($got) = grep { ($_->{id} // '') eq $id } @entries;
        ok($got, "AC6c: the shipped file has the new never-halt 07 entry '$id'");
        next unless $got;
        like(($got->{relied_by} // ''), qr/BpHook::DenialBreaker/,
            "AC6c: '$id' relied_by names BpHook::DenialBreaker");
        is(ref $got->{signatures} eq 'ARRAY' ? scalar(@{ $got->{signatures} }) : 0, 1,
            "AC6c: '$id' has exactly one signature");
        if (ref $got->{signatures} eq 'ARRAY' && @{ $got->{signatures} }) {
            my $sig = $got->{signatures}[0];
            is(($sig->{type} // ''), 'literal', "AC6c: '$id' signature type is literal");
        }
    }
}

# ===========================================================================
# AC7 — SKILL.md gains a Step 9 between Step 8 and Maintenance.
AC7: {
    unless (-f $SKILL) {
        ok(0, 'AC7: update SKILL.md exists');
        ok(0, 'AC7: Step 9 sits after Step 8 and before Maintenance, and names claude-internals-check.pl');
        last AC7;
    }
    ok(1, 'AC7: update SKILL.md exists');
    my $text = slurp($SKILL);
    my $step9_idx = index($text, '## Step 9: Check the internals this setup relies on');
    my $step8_idx = index($text, '## Step 8:');
    my $maint_idx = index($text, '## Maintenance');
    ok($step9_idx >= 0, 'AC7: SKILL.md has the "## Step 9: Check the internals this setup relies on" heading');
    ok($step8_idx >= 0 && $maint_idx >= 0 && $step9_idx > $step8_idx && $step9_idx < $maint_idx,
       'AC7: Step 9 sits after Step 8 and before Maintenance')
        or diag("  step8=$step8_idx step9=$step9_idx maintenance=$maint_idx");
    my $between = ($step9_idx >= 0 && $maint_idx > $step9_idx) ? substr($text, $step9_idx, $maint_idx - $step9_idx) : '';
    ok(index($between, 'claude-internals-check.pl') >= 0, 'AC7: the Step 9 section names claude-internals-check.pl');
}

# update-research.t stays green through this package's own test_paths (tooling-fixes 06); no assertion runs it here.

# ===========================================================================
# AC9 — the chunked scan: correct at every straddle offset, correct at the
# lookahead edge case, and refuses an invalid seam.
AC9: {
    unless ($HAVE_SCRIPT) {
        ok(0, 'AC9: a full fixture at every leading-pad offset 0..63 exits 0 under a 64/64 seam');
        ok(0, 'AC9: the ticklish-whisper lookahead trap is correctly reported CHANGED, not falsely PRESENT');
        ok(0, 'AC9: CLAUDE_INTERNALS_CHUNK_BYTES=0 exits 2 (invalid scan seam)');
        last AC9;
    }
    my $data_path = "$ROOT/ac9-data.json";
    my $obj = write_self_data($data_path, \@EXPECTED);
    my @entries = @{ $obj->{entries} };
    my $full = build_fixture(\@entries);

    # --- straddle: every leading-pad offset 0..63 must still find everything.
    my @bad_offsets;
    for my $pad (0 .. 63) {
        my $bin = "$ROOT/ac9-pad-$pad.bin";
        write_bin($bin, ('Z' x $pad) . $full);
        my $r = run(args => [ '--binary', $bin, '--data', $data_path ], chunk => 64, overlap => 64);
        push @bad_offsets, $pad unless ($r->{exit} // -1) == 0;
    }
    ok(!@bad_offsets, 'AC9: a full fixture at every leading-pad offset 0..63 exits 0 under a 64/64 seam')
        or diag('  failing offsets: ' . join(',', @bad_offsets));

    # --- the lookahead trap: the ONLY occurrence of CLAUDE_CODE_TICKLISH_WHISPER
    # is inside ..._TIMEOUT_MS, with a chunk boundary right after "WHISPER".
    my ($tw) = grep { $_->{id} eq 'ticklish-whisper-timed-fallback' } @entries;
    my ($regex_sig)  = grep { $_->{type} eq 'regex' } @{ $tw->{signatures} };
    my ($timeout_sig) = grep { $_->{value} =~ /_TIMEOUT_MS\z/ } @{ $tw->{signatures} };
    my ($tengu_sig)    = grep { $_->{value} eq 'tengu_ticklish_whisper' } @{ $tw->{signatures} };
    my ($autodeny_sig) = grep { $_->{value} eq 'autoDenyAfterMs' } @{ $tw->{signatures} };
    my $tok = 'CLAUDE_CODE_TICKLISH_WHISPER';
    my $pad_len = (64 - (length($tok) % 64)) % 64;
    my $trap = ('P' x $pad_len) . $timeout_sig->{value}
             . "\0\xff\0" . $tengu_sig->{value}
             . "\0\xff\0" . $autodeny_sig->{value};
    my $bin2 = "$ROOT/ac9-trap.bin";
    write_bin($bin2, $trap);
    my $r2 = run(args => [ '--binary', $bin2, '--data', $data_path ], chunk => 64, overlap => 64);
    is($r2->{exit}, 1, 'AC9: the lookahead-trap fixture exits 1') or diag($r2->{raw} . $r2->{stderr});
    my ($e2) = grep { ($_->{id} // '') eq 'ticklish-whisper-timed-fallback' } @{ $r2->{json}{entries} // [] };
    ok($e2, 'AC9: ticklish-whisper-timed-fallback appears in entries[]');
    if ($e2) {
        is(($e2->{state} // ''), 'CHANGED',
           'AC9: it is CHANGED -- the negative lookahead correctly refuses the _TIMEOUT_MS-suffixed occurrence, straddle or not');
        ok((grep { $_ eq $regex_sig->{value} } @{ $e2->{missing} // [] }) ? 1 : 0,
           'AC9: missing[] names the regex signature, not a false PRESENT from a buffer-edge illusion');
    }

    # --- an invalid seam is refused outright.
    my $bin3 = "$ROOT/ac9-any.bin";
    write_bin($bin3, $full);
    my $r3 = run(args => [ '--binary', $bin3, '--data', $data_path ], chunk => 0, overlap => 64);
    is($r3->{exit}, 2, 'AC9: CLAUDE_INTERNALS_CHUNK_BYTES=0 exits 2') or diag($r3->{raw} . $r3->{stderr});
    like(($r3->{json}{error} // ''), qr/invalid scan seam/i, 'AC9: error names an invalid scan seam');
}

# ===========================================================================
# AC10 — PATH resolution, including a non-ASCII directory name.
AC10: {
    unless ($HAVE_SCRIPT) {
        ok(0, 'AC10: PATH resolves the fixture claude binary; binary_source is "path"; the é directory decodes cleanly');
        ok(0, 'AC10: PATH with no candidate exits 2, "claude not found on PATH"');
        last AC10;
    }
    my $data_path = "$ROOT/ac10-data.json";
    my $obj = write_self_data($data_path, \@EXPECTED);
    my $full = build_fixture($obj->{entries});

    my $is_win_family  = ($^O eq 'MSWin32' || $^O eq 'msys' || $^O eq 'cygwin');
    my $candidate_name = $is_win_family ? 'claude.exe' : 'claude';
    my $sep            = ($^O eq 'MSWin32') ? ';' : ':';

    # 'André' as raw UTF-8 bytes on disk -- never decoded before the filesystem call.
    my $accented_dir = "$ROOT/Andr\xc3\xa9-bin";
    make_path($accented_dir);
    write_bin("$accented_dir/$candidate_name", $full);

    # msys/cygwin present PATH in POSIX form (/c/...); convert a native
    # "C:\..." / "C:/..." tempdir path the same way, by hand -- never via
    # cygpath, which would itself be a spawn.
    my $path_dir = $accented_dir;
    if ($^O ne 'MSWin32' && $path_dir =~ m{^([A-Za-z]):[\\/](.*)\z}) {
        my ($drive, $rest) = (lc($1), $2);
        $rest =~ s{\\}{/}g;
        $path_dir = "/$drive/$rest";
    }
    my $path_value = $path_dir . $sep . "$ROOT/unrelated-other-dir";

    my $r = run(args => [ '--data', $data_path ], path => $path_value);
    is($r->{exit}, 0, 'AC10: PATH resolves the fixture claude binary') or diag($r->{raw} . $r->{stderr});
    is(($r->{json}{binary_source} // ''), 'path', 'AC10: binary_source is "path"');
    like(($r->{json}{binary} // ''), qr/\x{e9}/, 'AC10: the decoded binary field contains é, not mojibake')
        or diag('  got: ' . ($r->{json}{binary} // ''));
    unlike(($r->{json}{binary} // ''), qr/\x{c3}\x{83}/, 'AC10: counter-check: no double-encoded sequence in the field');

    my $empty_dir = "$ROOT/empty-path-dir";
    make_path($empty_dir);
    my $r2 = run(args => [ '--data', $data_path ], path => $empty_dir);
    is($r2->{exit}, 2, 'AC10: PATH with no candidate exits 2');
    like(($r2->{json}{error} // ''), qr/claude not found on PATH; pass --binary/,
         'AC10: error is exactly "claude not found on PATH; pass --binary <path>"');

    # --- the same é fixture, found via --binary rather than PATH.
    my $r_binary = run(args => [ '--binary', "$accented_dir/$candidate_name", '--data', $data_path ]);
    is($r_binary->{exit}, 0, 'AC10: --binary resolves the é-directory fixture')
        or diag($r_binary->{raw} . $r_binary->{stderr});
    for my $entry (@{ $r_binary->{json}{entries} // [] }) {
        is(($entry->{state} // ''), 'PRESENT',
           "AC10: --binary case -- entry '" . ($entry->{id} // '?') . "' is PRESENT");
    }
    like(($r_binary->{json}{binary} // ''), qr/\x{e9}/,
         'AC10: --binary case -- the decoded binary field contains é, not mojibake')
        or diag('  got: ' . ($r_binary->{json}{binary} // ''));
    unlike(($r_binary->{json}{binary} // ''), qr/\x{c3}\x{83}/,
           'AC10: --binary case -- counter-check: no double-encoded sequence in the field');
}

# ===========================================================================
# AC11 — the ccpraxis-helpers.pl dispatch mirrors the direct script exactly.
AC11: {
    unless ($HAVE_SCRIPT && -f $HELPER) {
        ok(0, 'AC11: helper dispatch matches direct script for exit 0');
        ok(0, 'AC11: helper dispatch matches direct script for exit 1');
        ok(0, 'AC11: helper dispatch matches direct script for exit 2');
        last AC11;
    }
    my $data_path = "$ROOT/ac11-data.json";
    my $obj = write_self_data($data_path, \@EXPECTED);
    my @entries = @{ $obj->{entries} };

    my $full_bin = "$ROOT/ac11-full.bin";
    write_bin($full_bin, build_fixture(\@entries));
    my $d0 = run(args => [ '--binary', $full_bin, '--data', $data_path ]);
    my $h0 = run_helper('--binary', $full_bin, '--data', $data_path);
    is($h0->{exit}, $d0->{exit}, 'AC11: exit 0 case -- helper exit matches direct script exit')
        or diag("direct: $d0->{raw}$d0->{stderr}\nhelper: $h0->{raw}");
    is(($h0->{json}{status} // ''), ($d0->{json}{status} // ''), 'AC11: exit 0 case -- helper JSON status matches direct');

    my $changed_bin = "$ROOT/ac11-changed.bin";
    write_bin($changed_bin, build_fixture(\@entries, exclude_id => 'subagent-classifier-abort'));
    my $d1 = run(args => [ '--binary', $changed_bin, '--data', $data_path ]);
    my $h1 = run_helper('--binary', $changed_bin, '--data', $data_path);
    is($h1->{exit}, $d1->{exit}, 'AC11: exit 1 case -- helper exit matches direct script exit');
    is(($h1->{json}{status} // ''), ($d1->{json}{status} // ''), 'AC11: exit 1 case -- helper JSON status matches direct');

    my $missing_bin = "$ROOT/ac11-missing.bin";
    my $d2 = run(args => [ '--binary', $missing_bin, '--data', $data_path ]);
    my $h2 = run_helper('--binary', $missing_bin, '--data', $data_path);
    is($h2->{exit}, $d2->{exit}, 'AC11: exit 2 case -- helper exit matches direct script exit');
    is(($h2->{json}{status} // ''), ($d2->{json}{status} // ''), 'AC11: exit 2 case -- helper JSON status matches direct');
}

# ===========================================================================
# Supplementary, spec-mandated but unnumbered: .about sidecars, the help-text
# addition, --help/usage errors, and the 0-byte-binary edge case.

ABOUT: {
    ok(-f $ABOUT_SCRIPT, 'the claude-internals-check.pl.about sidecar exists');
    if (-f $ABOUT_SCRIPT) {
        my $t = slurp($ABOUT_SCRIPT);
        $t =~ s/\s+\z//;
        is($t, "Read-only signature scan of the installed claude binary for the undocumented internals ccpraxis settings rely on -- run by /steward:update after an install",
           'the .pl.about content matches the spec verbatim');
    } else {
        ok(0, 'the .pl.about content matches the spec verbatim');
    }

    ok(-f $ABOUT_DATA, 'the claude-internals.json.about sidecar exists');
    if (-f $ABOUT_DATA) {
        my $t = slurp($ABOUT_DATA);
        $t =~ s/\s+\z//;
        is($t, "Data file for claude-internals-check.pl: each undocumented Claude Code internal ccpraxis relies on, the setting at risk, and the byte signatures that prove it is still there",
           'the .json.about content matches the spec verbatim');
    } else {
        ok(0, 'the .json.about content matches the spec verbatim');
    }
}

HELPTEXT: {
    unless (-f $HELPER) {
        ok(0, 'ccpraxis-helpers.pl help text mentions the new claude-internals subcommand');
        last HELPTEXT;
    }
    my $out = `"$^X" "$HELPER" help 2>&1`;
    like($out, qr/claude-internals/, 'ccpraxis-helpers.pl help text mentions the new claude-internals subcommand');
}

USAGE: {
    unless ($HAVE_SCRIPT) {
        ok(0, '--help exits 0 and prints usage on stdout');
        ok(0, 'an unrecognized argument is a usage error, exit 2');
        ok(0, '--binary with no value is a usage error, exit 2');
        last USAGE;
    }
    my $rh = run(args => [ '--help' ]);
    is($rh->{exit}, 0, '--help exits 0');
    ok(length($rh->{raw}) > 0, '--help prints usage text to stdout');

    my $ru = run(args => [ '--frobnicate-not-a-real-option' ]);
    is($ru->{exit}, 2, 'an unrecognized argument is a usage error, exit 2');

    my $rb = run(args => [ '--binary' ]);
    is($rb->{exit}, 2, '--binary with no value is a usage error, exit 2');
}

EDGE_EMPTY: {
    unless ($HAVE_SCRIPT) {
        ok(0, 'edge case: a 0-byte binary is readable and reports every entry CHANGED, exit 1 (not 2)');
        last EDGE_EMPTY;
    }
    my $data_path = "$ROOT/edge-empty-data.json";
    write_self_data($data_path, \@EXPECTED);
    my $empty_bin = "$ROOT/empty.bin";
    write_bin($empty_bin, '');
    my $r = run(args => [ '--binary', $empty_bin, '--data', $data_path ]);
    is($r->{exit}, 1, 'edge case: a 0-byte binary exits 1, not 2') or diag($r->{raw} . $r->{stderr});
    my $all_changed = $r->{json} && ref $r->{json}{entries} eq 'ARRAY' && @{ $r->{json}{entries} }
                     && !grep { ($_->{state} // '') ne 'CHANGED' } @{ $r->{json}{entries} };
    ok($all_changed, 'edge case: every entry is CHANGED against a 0-byte binary');
}

done_testing();
