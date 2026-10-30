#!/usr/bin/env perl
# platform: any
# The one hook-payload reader, <plugin>/scripts/read-payload.sh.
#
# Every bash hook of almanac and butler that reads a JSON payload from stdin
# sources <plugin>/scripts/read-payload.sh and calls ccp_read_payload. This
# file pins:
#   P1  the two copies (almanac, butler) are byte-identical -- one
#       implementation, carried by each plugin so neither depends on its
#       sibling being installed next to it;
#   P2  no hook under plugins/*/hooks reads stdin with its own read -N /
#       read -d '' any more, and each known payload-reading hook sources the
#       library from its own plugin's scripts/ (never from the sibling);
#   P3  the library spawns nothing (no command substitution, no pipe, no
#       interpreter) and keeps the bash >= 4.1 "read -N" fast path;
#   P4  its behaviour, under EVERY distinct bash this host has (macOS: the
#       3.2 /bin/bash; Windows and the container: bash 5): complete input,
#       empty input, a stale value cleared, the 8 MiB cap, a stalled writer
#       (timeout: the variable comes back EMPTY on every bash -- bash 3.2
#       drops a timed-out read's partial input, so bash 5 must not keep it
#       either), the BP_PAYLOAD_READ_TIMEOUT default, a bad variable name.
#
# On this Mac only bash 3.2 exists, so P4 exercises the 3.2 branch here and
# the -N branch wherever bash >= 4.1 runs the suite. Every subprocess is
# bounded by a fork/waitpid deadline (no external "timeout" needed) and
# captures output to real files, never an in-memory STDOUT reopen.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Spec ();
use POSIX ();
use Time::HiRes ();

(my $REPO = "$Bin/../../../..") =~ s{\\}{/}g;
my $LIB_B = "$REPO/plugins/butler/scripts/read-payload.sh";
my $LIB_A = "$REPO/plugins/almanac/scripts/read-payload.sh";

sub slurp {
    my ($p) = @_;
    open my $fh, '<:raw', $p or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

sub spew {
    my ($p, $c) = @_;
    open my $fh, '>:raw', $p or die "write $p: $!";
    print {$fh} $c;
    close $fh;
}

# ---------------------------------------------------------------------------
# P1 -- parity.
# ---------------------------------------------------------------------------
my $lib = slurp($LIB_B);
ok(defined $lib, 'P1: plugins/butler/scripts/read-payload.sh exists') or BAIL_OUT('library missing');
my $lib_a = slurp($LIB_A);
ok(defined $lib_a, 'P1: plugins/almanac/scripts/read-payload.sh exists');
ok(defined $lib_a && $lib_a eq $lib,
   'P1: the almanac and butler copies are byte-identical (edit both, or neither)');

# ---------------------------------------------------------------------------
# P2 -- every payload-reading hook goes through the library.
# ---------------------------------------------------------------------------
{
    my %READERS = (
        'plugins/butler/hooks/run-hook.sh'                    => 'BP_PAYLOAD',
        'plugins/butler/hooks/arm-nudge-prompt.sh'            => 'P',
        'plugins/almanac/hooks/guard-almanac-write.sh'        => 'P',
        'plugins/almanac/hooks/guard-tasks-tool.sh'           => 'PAYLOAD',
        'plugins/almanac/hooks/reminder-chart-tasklist-gate.sh' => 'P',
    );
    for my $rel (sort keys %READERS) {
        my $src = slurp("$REPO/$rel");
        ok(defined $src, "P2: $rel exists") or next;
        (my $code = $src) =~ s/^\s*#.*$//mg;
        like($code, qr{\.\s+"\$\w+(?:/\.\./scripts)?/read-payload\.sh"}, "P2: $rel sources read-payload.sh from its own plugin");
        like($code, qr{\bccp_read_payload\s+\Q$READERS{$rel}\E\b}, "P2: $rel reads its payload with ccp_read_payload $READERS{$rel}");
    }

    # No hook keeps a private stdin reader. A read fed by a here-document or
    # a file redirect (guard-disarm-judge-readonly.sh's embedded program,
    # run-hook.sh's state-file reads) is not a payload read.
    my @hooks = (glob("$REPO/plugins/*/hooks/*.sh"), glob("$REPO/plugins/*/hooks/*/*.sh"));
    my @private;
    for my $f (@hooks) {
        my $src = slurp($f) // next;
        my $n = 0;
        for my $line (split /\n/, $src) {
            $n++;
            next if $line =~ /^\s*#/;
            next unless $line =~ /\bread\b[^\n]*\s-(?:N|d)\s/;
            next if $line =~ /<</ || $line =~ /<\s*"/;
            push @private, "$f:$n: $line";
        }
    }
    is_deeply(\@private, [], 'P2: no hook reads stdin with its own read -N / read -d')
        or diag(join("\n", @private));
}

# ---------------------------------------------------------------------------
# P3 -- the library itself.
# ---------------------------------------------------------------------------
{
    (my $code = $lib) =~ s/^\s*#.*$//mg;
    unlike($code, qr/\$\((?!\()/, 'P3: no command substitution $( in the library (arithmetic $(( is fine)');
    unlike($code, qr/\x60/, 'P3: no backtick in the library');
    unlike($lib, qr/(?<!\|)\|(?!\|)/, 'P3: no lone pipe character anywhere in the library (run-hook.sh rule)');
    unlike($lib, qr/perl/i, 'P3: the library never names an interpreter (the Tasks guard source scan forbids the word)');
    unlike(lc($lib), qr/\bjq\b/, 'P3: no jq');
    like($code, qr/IFS= read -r -N 8388608 -t "\$_ccp_t" "\$1"/, 'P3: bash >= 4.1 keeps the read -N 8388608 bulk read');
    like($code, qr/IFS= read -r -d '' -n 8388608 -t "\$_ccp_t" "\$1"/, "P3: older bash reads -d '' with the same 8 MiB cap");
    like($code, qr/BASH_VERSINFO\[0\]/, 'P3: the branch is chosen from BASH_VERSINFO, never by trying -N');
}

# ---------------------------------------------------------------------------
# P4 -- behaviour under every distinct bash on this host.
# ---------------------------------------------------------------------------
my %seen;
my @bashes;
for my $cand ('/bin/bash', '/usr/bin/bash', '/usr/local/bin/bash', '/opt/homebrew/bin/bash',
              do { my $p = `bash -c "command -v bash" 2>/dev/null`; chomp $p; $p }) {
    next unless defined $cand && length $cand && -x $cand;
    my $v = `"$cand" -c 'printf "%s" "\${BASH_VERSINFO[0]}.\${BASH_VERSINFO[1]}"' 2>/dev/null`;
    next unless defined $v && $v =~ /^\d+\.\d+$/;
    next if $seen{$v}++;
    push @bashes, [$cand, $v];
}
ok(scalar(@bashes) >= 1, 'P4 setup: at least one bash found') or BAIL_OUT('no bash');
diag('P4 runs under: ' . join(', ', map { "$_->[0] ($_->[1])" } @bashes));

my $TMP = tempdir(CLEANUP => 1);
my $PROBE = "$TMP/probe.sh";
spew($PROBE, <<'SH');
# $1 = library, $2 = variable name, $3 = optional seconds argument.
. "$1"
P=stale-value
ccp_read_payload "$2" ${3+"$3"}
rc=$?
printf 'rc=%s\nstate=%s\nlen=%s\n' "$rc" "$CCP_PAYLOAD_STATE" "${#P}"
printf '%s' "$P" > "$PROBE_OUT"
SH

my @KILL;
END { kill 'KILL', $_ for grep { $_ } @KILL; $? = 0 }

# run_probe($bash, $stdin_spec, \@args, %env) -> { rc, state, len, value, secs }
# $stdin_spec: { file => path } or { fifo => [payload, hold_seconds] }.
sub run_probe {
    my ($bash, $stdin, $args, %env) = @_;
    my $out = "$TMP/out.$$." . int(rand(1e9));
    my $res = "$TMP/res.$$." . int(rand(1e9));
    my $in;
    my $writer;
    if ($stdin->{file}) {
        $in = $stdin->{file};
    }
    else {
        $in = "$TMP/fifo." . int(rand(1e9));
        POSIX::mkfifo($in, 0600) or return undef;
        my ($payload, $hold) = @{ $stdin->{fifo} };
        $writer = fork();
        die "fork: $!" unless defined $writer;
        if ($writer == 0) {
            open(STDOUT, '>', File::Spec->devnull);
            open(STDERR, '>', File::Spec->devnull);
            open(my $w, '>', $in) or POSIX::_exit(1);
            syswrite($w, $payload) if length $payload;
            sleep $hold;
            POSIX::_exit(0);
        }
        push @KILL, $writer;
    }
    my $t0 = Time::HiRes::time();
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        open(STDIN, '<', $in) or POSIX::_exit(126);
        open(STDOUT, '>', $res) or POSIX::_exit(126);
        open(STDERR, '>', File::Spec->devnull);
        delete $ENV{BP_PAYLOAD_READ_TIMEOUT};
        $ENV{$_} = $env{$_} for keys %env;
        $ENV{PROBE_OUT} = $out;
        exec($bash, $PROBE, $LIB_B, @$args) or POSIX::_exit(127);
    }
    my $deadline = $t0 + 30;
    my $done = 0;
    while (Time::HiRes::time() < $deadline) {
        my $w = waitpid($pid, POSIX::WNOHANG());
        if ($w == $pid) { $done = 1; last }
        Time::HiRes::sleep(0.05);
    }
    unless ($done) { kill 'KILL', $pid; waitpid($pid, 0) }
    my $secs = Time::HiRes::time() - $t0;
    if ($writer) { kill 'KILL', $writer; waitpid($writer, 0) }
    my $r = slurp($res) // '';
    my %f = map { /^(\w+)=(.*)$/ ? ($1 => $2) : () } split /\n/, $r;
    return { %f, value => slurp($out), secs => $secs, finished => $done };
}

my $big = "$TMP/big.json";
spew($big, '{"a":"' . ('x' x 8388608) . '"}');
my $small = "$TMP/small.json";
my $SMALL = qq({"session_id":"s1","tool_name":"Write",\n"tool_input":{"file_path":"/x"}}\n);
spew($small, $SMALL);
my $empty = "$TMP/empty";
spew($empty, '');

my $have_fifo = do { my $f = "$TMP/fifo-probe"; my $ok = POSIX::mkfifo($f, 0600); unlink $f; $ok };

for my $b (@bashes) {
    my ($bash, $ver) = @$b;
    my $tag = "[bash $ver]";

    my $r = run_probe($bash, { file => $small }, ['P']);
    is($r->{state}, 'complete', "P4 $tag: a whole payload reads complete");
    is($r->{rc}, 0, "P4 $tag: ...returning 0");
    is($r->{value}, $SMALL, "P4 $tag: ...byte-exact, embedded and trailing newlines included");

    $r = run_probe($bash, { file => $empty }, ['P']);
    is($r->{state}, 'complete', "P4 $tag: empty stdin reads complete");
    is($r->{len}, 0, "P4 $tag: ...and clears the variable's stale value");

    $r = run_probe($bash, { file => $big }, ['P']);
    is($r->{state}, 'truncated', "P4 $tag: a payload over 8 MiB reads truncated");
    is($r->{rc}, 1, "P4 $tag: ...returning 1");
    is($r->{len}, 8388608, "P4 $tag: ...with exactly the first 8 MiB kept (both branches cap alike)");

    $r = run_probe($bash, { file => $small }, ['bad name']);
    is($r->{rc}, 2, "P4 $tag: an invalid variable name returns 2 without reading");

    SKIP: {
        skip "P4 $tag: no mkfifo on this host", 7 unless $have_fifo;
        # A writer that sends a COMPLETE payload and then holds the pipe open:
        # bash 5 would have the whole JSON in hand at the timeout, bash 3.2
        # nothing. Both must come back empty.
        $r = run_probe($bash, { fifo => [$SMALL, 20] }, ['P', '1']);
        ok($r->{finished}, "P4 $tag: a stalled writer does not hang the read");
        is($r->{state}, 'timeout', "P4 $tag: a stalled writer reads timeout");
        is($r->{rc}, 1, "P4 $tag: ...returning 1");
        is($r->{len}, 0, "P4 $tag: ...with the variable EMPTY, though the whole JSON had arrived");
        cmp_ok($r->{secs}, '<', 6, "P4 $tag: ...within the 1 s budget plus slack");

        $r = run_probe($bash, { fifo => [$SMALL, 20] }, ['P'], BP_PAYLOAD_READ_TIMEOUT => 1);
        is($r->{state}, 'timeout', "P4 $tag: with no SECONDS argument, BP_PAYLOAD_READ_TIMEOUT sets the budget");
        cmp_ok($r->{secs}, '<', 6, "P4 $tag: ...and is honoured (1 s, not the default 10)");
    }
}

done_testing();
