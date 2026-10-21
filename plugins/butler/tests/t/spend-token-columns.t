#!/usr/bin/env perl
# platform: any
# Oracle for blueprint spend-token-report, package
# 01-token-columns-fresh-pricing (DC1, DC3): the per-type token columns
# (input, cache_write_5m, cache_write_1h, cache_write_unsplit, cache_read,
# output) on report-session/derive-session, thinking counted in output, the
# derive-package/derive-blueprint cache-write split additions, and that
# snapshot stays byte-identical. Spec: specs/01-token-columns-fresh-pricing-
# spec.md §4.1.
#
# EVERY fixture here is synthetic, built fresh in a tempdir. This file never
# fetches: CCPRAXIS_SPEND_NO_FETCH=1 is set below (Decision 16), except TC10
# which deliberately unsets it for a child that also sets the seam, to prove
# the fleet path (derive-package/derive-blueprint) now fetches through the
# seam too, but exactly once per CLI run rather than once per package
# (Decisions 25/27, package 02).
#
# THIS FILE IS THE PACKAGE'S ORACLE for the token-columns behaviour. It must
# not be weakened to make an implementation's life easier.
use strict;
use warnings;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Spec;
use File::Path qw(make_path);
use Test::More;
use JSON::PP;
use POSIX qw(strftime);

# spend-token-report Decision 16: never let this test reach a live fetch.
$ENV{CCPRAXIS_SPEND_NO_FETCH} = 1;

my $SPEND_PL = "$Bin/../../scripts/bp-spend.pl";
ok(-f $SPEND_PL, 'bp-spend.pl exists') or BAIL_OUT('nothing to test');

my $PERL = $^X;
my $JSON = JSON::PP->new->canonical;

my $SPEND_LOADED = do { local $@; eval { require $SPEND_PL }; !$@ };
ok($SPEND_LOADED, 'HARNESS: bp-spend.pl requires cleanly as a module')
    or diag("require failed: $@");

# ---------------------------------------------------------------------------
# helpers (mirror spend-drive-solo-session.t's style)
# ---------------------------------------------------------------------------

sub run_spend {
    my (@args) = @_;
    my $cmd = join(' ', map { qq("$_") } ($PERL, $SPEND_PL, @args));
    my $out = `$cmd 2>&1`;
    return ($? >> 8, $out);
}

sub call_derive_session {
    my (%opts) = @_;
    my $doc = eval { BpSpend::Derive::derive_session(%opts) };
    return ($doc, $@);
}
sub call_report_session {
    my (%opts) = @_;
    my $doc = eval { BpSpend::Derive::report_session(%opts) };
    return ($doc, $@);
}

sub write_jsonl {
    my ($path, @lines) = @_;
    my ($vol, $dir, undef) = File::Spec->splitpath($path);
    make_path($dir) if $dir && !-d $dir;
    open(my $fh, '>:raw', $path) or die "open $path: $!";
    for my $l (@lines) {
        print $fh (ref($l) ? $JSON->encode($l) : $l), "\n";
    }
    close $fh;
    return $path;
}

sub write_json_file {
    my ($path, $data) = @_;
    my ($vol, $dir, undef) = File::Spec->splitpath($path);
    make_path($dir) if $dir && !-d $dir;
    open(my $fh, '>:raw', $path) or die "open $path: $!";
    print $fh $JSON->encode($data);
    close $fh;
    return $path;
}

sub slurp_json {
    my ($p) = @_;
    return undef unless -f $p;
    open(my $fh, '<:raw', $p) or return undef;
    my $raw = do { local $/; <$fh> };
    close $fh;
    return eval { JSON::PP->new->decode($raw) };
}

sub slurp_raw {
    my ($p) = @_;
    return undef unless -f $p;
    open(my $fh, '<:raw', $p) or return undef;
    my $raw = do { local $/; <$fh> };
    close $fh;
    return $raw;
}

# Session-path assistant record (drive-solo shape). %o keys as in
# spend-drive-solo-session.t's assistant_rec: session, uuid, timestamp,
# request_id, message_id, model, effort, role marker via subdir placement,
# input, output, cache_read, cache_creation (unsplit), cache_5m, cache_1h,
# speed.
sub assistant_rec {
    my (%o) = @_;
    my %usage;
    $usage{input_tokens}                = $o{input}          if exists $o{input};
    $usage{output_tokens}               = $o{output}         if exists $o{output};
    $usage{cache_read_input_tokens}     = $o{cache_read}      if exists $o{cache_read};
    $usage{cache_creation_input_tokens} = $o{cache_creation}  if exists $o{cache_creation};
    if (exists $o{cache_5m} || exists $o{cache_1h}) {
        $usage{cache_creation} = {
            ephemeral_5m_input_tokens => $o{cache_5m} // 0,
            ephemeral_1h_input_tokens => $o{cache_1h} // 0,
        };
    }
    $usage{speed} = $o{speed} if exists $o{speed};

    my %message = (usage => \%usage);
    $message{model}   = $o{model}      if exists $o{model};
    $message{id}      = $o{message_id} if exists $o{message_id};
    $message{content} = $o{content}    if exists $o{content};

    my %rec = (
        type       => 'assistant',
        message    => \%message,
        session_id => $o{session} // 'sess-1',
        uuid       => $o{uuid} // ('u-' . int(rand(1e9))),
    );
    $rec{requestId} = $o{request_id} if exists $o{request_id};
    $rec{effort}    = $o{effort}     if exists $o{effort};
    $rec{timestamp} = $o{timestamp}  if exists $o{timestamp};
    return \%rec;
}

sub session_paths {
    my ($dir, $uuid) = @_;
    my $main   = File::Spec->catfile($dir, "$uuid.jsonl");
    my $subdir = File::Spec->catdir($dir, $uuid, 'subagents');
    return ($main, $subdir);
}
sub agent_jsonl_path { my ($subdir, $name) = @_; return File::Spec->catfile($subdir, "$name.jsonl"); }
sub agent_meta_path  { my ($subdir, $name) = @_; return File::Spec->catfile($subdir, "$name.meta.json"); }

# Fleet-path (derive-package) record builders, mirroring
# spend-derived-from-transcripts.t's shapes, extended with the 5m/1h split.
sub sys_init {
    my (%o) = @_;
    return { type => 'system', subtype => 'init', cwd => '/project',
             session_id => $o{session} // 'sess-1', model => $o{model} // 'claude-sonnet-5' };
}
sub fleet_assistant_rec {
    my (%o) = @_;
    my %usage = (
        input_tokens                => $o{input} // 0,
        output_tokens               => $o{output} // 0,
        cache_creation_input_tokens => $o{cache_creation} // 0,
        cache_read_input_tokens     => $o{cache_read} // 0,
    );
    if (exists $o{cache_5m} || exists $o{cache_1h}) {
        $usage{cache_creation} = {
            ephemeral_5m_input_tokens => $o{cache_5m} // 0,
            ephemeral_1h_input_tokens => $o{cache_1h} // 0,
        };
    }
    return {
        type    => 'assistant',
        message => { model => $o{model} // 'claude-sonnet-5', id => $o{id} // ('msg_' . int(rand(1e9))),
                     type => 'message', role => 'assistant',
                     content => [ { type => 'text', text => 'x' } ], usage => \%usage },
        parent_tool_use_id => $o{parent},
        session_id         => $o{session} // 'sess-1',
        uuid               => $o{uuid} // ('u-' . int(rand(1e9))),
        timestamp          => $o{timestamp} // '2026-09-26T00:00:00.000Z',
    };
}
sub result_rec {
    my (%o) = @_;
    return { type => 'result', is_error => JSON::PP::false, session_id => $o{session} // 'sess-1',
             total_cost_usd => $o{total_cost_usd} // 0,
             usage => { input_tokens => 0, output_tokens => 0, cache_read_input_tokens => 0,
                        cache_creation_input_tokens => 0, modelUsage => {} },
             uuid => 'u-result-' . int(rand(1e9)) };
}
sub runs_path    { my ($dir, $pkg) = @_; return File::Spec->catfile($dir, 'runs', "$pkg.jsonl"); }
sub derived_path { my ($dir) = @_; return File::Spec->catfile($dir, 'runs', 'spend-derived.json'); }

sub snapshot_tree {
    my ($dir) = @_;
    my %snap;
    return \%snap unless -d $dir;
    my @stack = ($dir);
    while (my $d = pop @stack) {
        opendir(my $dh, $d) or next;
        for my $e (readdir $dh) {
            next if $e eq '.' || $e eq '..';
            my $p = File::Spec->catfile($d, $e);
            if (-d $p) { push @stack, $p; next; }
            my @st = stat($p);
            $snap{$p} = "$st[9]:$st[7]";
        }
        closedir $dh;
    }
    return \%snap;
}

sub iso_from_epoch {
    my ($epoch) = @_;
    my @g = gmtime($epoch);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $g[5] + 1900, $g[4] + 1, $g[3], $g[2], $g[1], $g[0]);
}

# ===========================================================================
# TC1 (DC1) -- per-type columns from one request.
# ===========================================================================
subtest 'TC1: report-session --json --by role,model gives exact per-type token columns' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my ($main) = session_paths($dir, 'sess-tc1');
    write_jsonl($main, assistant_rec(request_id => 'req-tc1', model => 'claude-sonnet-5',
        input => 100, cache_creation => 50, cache_5m => 30, cache_1h => 20, cache_read => 400, output => 7));

    my ($rc, $out) = run_spend('report-session', '--session', $main, '--by', 'role,model', '--json');
    is($rc, 0, 'TC1: exits 0') or diag($out);
    my $doc = eval { JSON::PP->new->decode($out) };
    ok($doc, 'TC1: stdout parses as JSON') or diag($out);
  SKIP: {
        skip 'TC1: doc unavailable', 1 unless $doc;
        my ($row) = @{ $doc->{rows} // [] };
        ok($row, 'TC1: exactly one row') or diag($JSON->encode($doc));
        if ($row) {
            is($row->{input_tokens},               100, 'TC1: input_tokens');
            is($row->{cache_write_5m_tokens},        30, 'TC1: cache_write_5m_tokens');
            is($row->{cache_write_1h_tokens},        20, 'TC1: cache_write_1h_tokens');
            is($row->{cache_write_unsplit_tokens},    0, 'TC1: cache_write_unsplit_tokens');
            is($row->{cache_read_tokens},           400, 'TC1: cache_read_tokens');
            is($row->{output_tokens},                 7, 'TC1: output_tokens');
            is($row->{tokens},                      557, 'TC1: tokens == the sum of all six');
        }
    }
};

# ===========================================================================
# TC2 (DC1) -- unsplit cache-write typing, with and without the hash present.
# ===========================================================================
subtest 'TC2: cache_creation without the split hash, and with the hash zeroed, both count as cache_write_unsplit' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my ($main) = session_paths($dir, 'sess-tc2');
    write_jsonl($main,
        assistant_rec(request_id => 'req-tc2a', model => 'claude-sonnet-5', cache_creation => 60, input => 1, output => 1),
        assistant_rec(request_id => 'req-tc2b', model => 'claude-sonnet-5', cache_creation => 40,
            cache_5m => 0, cache_1h => 0, input => 1, output => 1),
    );
    my ($doc, $err) = call_derive_session(session => $main);
    ok(!$err, 'TC2: derive_session does not die') or diag($err);
  SKIP: {
        skip 'TC2: derive_session unavailable', 3 unless $doc;
        is($doc->{totals}{cache_write_unsplit}{tokens}, 100, 'TC2: both requests count as cache_write_unsplit (60+40)');
        is($doc->{totals}{cache_write_5m}{tokens}, 0, 'TC2: cache_write_5m stays 0');
        is($doc->{totals}{cache_write_1h}{tokens}, 0, 'TC2: cache_write_1h stays 0');
    }
};

# ===========================================================================
# TC3 (DC1) -- thinking is counted in output, never a separate column.
# ===========================================================================
subtest 'TC3: two records of one request (thinking then text) give output_tokens == 12, never 17' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my ($main) = session_paths($dir, 'sess-tc3');
    write_jsonl($main,
        assistant_rec(request_id => 'req-tc3', model => 'claude-sonnet-5',
            content => [ { type => 'thinking', thinking => 'reasoning about it...' } ],
            input => 1, output => 5),
        assistant_rec(request_id => 'req-tc3', model => 'claude-sonnet-5',
            content => [ { type => 'text', text => 'the answer' } ],
            input => 1, output => 12),
    );
    my ($doc, $err) = call_derive_session(session => $main);
    ok(!$err, 'TC3: derive_session does not die') or diag($err);
  SKIP: {
        skip 'TC3: derive_session unavailable', 3 unless $doc;
        is($doc->{totals}{output}{tokens}, 12, 'TC3: output_tokens is 12 (deduped by request), never 17 (5+12)');
        my @thinking_keys = grep { /thinking/i } (keys %{ $doc->{totals} }), (map { $_->{token_type} } @{ $doc->{cells} });
        is_deeply(\@thinking_keys, [], 'TC3: no row or totals key matches /thinking/');
        ok($doc->{totals}{output}{tokens} != 17, 'TC3: thinking is never additionally summed into output');
    }
};

# ===========================================================================
# TC4 (DC1, spec §3.2) -- exact text row layout.
# ===========================================================================
subtest 'TC4: the text row line matches the exact §3.2 layout' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my ($main) = session_paths($dir, 'sess-tc4');
    write_jsonl($main, assistant_rec(request_id => 'req-tc4', model => 'claude-sonnet-5',
        input => 100, cache_creation => 50, cache_5m => 30, cache_1h => 20, cache_read => 400, output => 7));

    my ($rc, $out) = run_spend('report-session', '--session', $main);
    is($rc, 0, 'TC4: exits 0') or diag($out);
    like($out,
        qr{^row: role=driver model=claude-sonnet-5 \| 557 tokens, input=100 cache_write_5m=30 cache_write_1h=20 cache_write_unsplit=0 cache_read=400 output=7, api_equivalent_cost=unavailable: offline$}m,
        'TC4: the row line matches exactly (offline, since this file sets CCPRAXIS_SPEND_NO_FETCH=1)'
    ) or diag($out);
};

# ===========================================================================
# TC5 (DC1) -- TOTAL sums across every row: text and JSON.
# ===========================================================================
subtest 'TC5: TOTAL is the sum of all row/cell figures, text and JSON alike' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my ($main, $subdir) = session_paths($dir, 'sess-tc5');
    write_jsonl($main,
        assistant_rec(request_id => 'r1', model => 'claude-sonnet-5',
            input => 100, cache_creation => 50, cache_5m => 30, cache_1h => 20, cache_read => 400, output => 7),
        assistant_rec(request_id => 'r2', model => 'claude-sonnet-5', cache_creation => 60, input => 1, output => 1),
        assistant_rec(request_id => 'r3', model => 'claude-sonnet-5', cache_creation => 40,
            cache_5m => 0, cache_1h => 0, input => 1, output => 1),
        assistant_rec(request_id => 'r4', model => 'claude-sonnet-5',
            content => [ { type => 'thinking', thinking => 'x' } ], input => 1, output => 5),
        assistant_rec(request_id => 'r4', model => 'claude-sonnet-5',
            content => [ { type => 'text', text => 'y' } ], input => 1, output => 12),
    );
    write_jsonl(agent_jsonl_path($subdir, 'agent-1'),
        assistant_rec(request_id => 'sub1', model => 'claude-sonnet-5', input => 9, output => 9));
    write_json_file(agent_meta_path($subdir, 'agent-1'), { agentType => 'butler:bp-worker' });

    my ($rc, $out) = run_spend('report-session', '--session', $main);
    is($rc, 0, 'TC5: text exits 0') or diag($out);
    my (@row_lines) = ($out =~ /^row: .*$/mg);
    my ($total_line) = ($out =~ /^(TOTAL: .*)$/m);
    ok(@row_lines && $total_line, 'TC5: at least one row line and a TOTAL line exist') or diag($out);

    my %sum;
    my $tok_total = 0;
    for my $line (@row_lines) {
        while ($line =~ /\b(input|cache_write_5m|cache_write_1h|cache_write_unsplit|cache_read|output)=(\d+)/g) {
            $sum{$1} += $2;
        }
        $tok_total += $1 if $line =~ /\|\s*(\d+)\s*tokens,/;
    }
    my %total_sum;
    my $total_tok;
    if ($total_line) {
        while ($total_line =~ /\b(input|cache_write_5m|cache_write_1h|cache_write_unsplit|cache_read|output)=(\d+)/g) {
            $total_sum{$1} = $2;
        }
        $total_tok = $1 if $total_line =~ /TOTAL:\s*(\d+)\s*tokens,/;
    }
    is_deeply(\%total_sum, \%sum, 'TC5: TOTAL text line six values equal the per-type sums of every row line') or diag("$total_line\n" . join("\n", @row_lines));
    is($total_tok, $tok_total, 'TC5: TOTAL token count equals the sum of every row\'s token count');

    my ($rc2, $out2) = run_spend('report-session', '--session', $main, '--json');
    is($rc2, 0, 'TC5: json exits 0') or diag($out2);
    my $doc = eval { JSON::PP->new->decode($out2) };
    ok($doc, 'TC5: json stdout parses') or diag($out2);
  SKIP: {
        skip 'TC5: doc unavailable', 6 unless $doc;
        for my $type (qw(input cache_write_5m cache_write_1h cache_write_unsplit cache_read output)) {
            is($doc->{totals}{$type}{tokens}, $sum{$type} // 0, "TC5: json totals.$type.tokens matches the text sum");
        }
    }
};

# ===========================================================================
# TC6 (DC1, spec §3.2) -- derive-session's six "total <type>:" lines plus TOTAL.
# ===========================================================================
subtest 'TC6: derive-session prints six total-by-type lines and a TOTAL line' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my ($main) = session_paths($dir, 'sess-tc6');
    write_jsonl($main, assistant_rec(request_id => 'req-tc6', model => 'claude-sonnet-5',
        input => 100, cache_creation => 50, cache_5m => 30, cache_1h => 20, cache_read => 400, output => 7));

    my ($rc, $out) = run_spend('derive-session', '--session', $main);
    is($rc, 0, 'TC6: exits 0') or diag($out);
    my %want = (input => 100, cache_write_5m => 30, cache_write_1h => 20, cache_write_unsplit => 0, cache_read => 400, output => 7);
    for my $type (qw(input cache_write_5m cache_write_1h cache_write_unsplit cache_read output)) {
        like($out, qr{^total \Q$type\E: \Q$want{$type}\E tokens, api_equivalent_cost=unavailable: offline$}m,
            "TC6: total $type: line present with the right count") or diag($out);
    }
    like($out, qr{^TOTAL: 557 tokens, input=100 cache_write_5m=30 cache_write_1h=20 cache_write_unsplit=0 cache_read=400 output=7, api_equivalent_cost=unavailable: offline$}m,
        'TC6: TOTAL line carries the full TOK segment') or diag($out);
};

# ===========================================================================
# TC7 (Decision 18) -- --by token_type rows carry no per-type *_tokens keys.
# ===========================================================================
subtest 'TC7: --by token_type rows have exactly the aggregate keys, no *_tokens keys; text still prints the full TOK' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my ($main) = session_paths($dir, 'sess-tc7');
    write_jsonl($main, assistant_rec(request_id => 'req-tc7', model => 'claude-sonnet-5',
        input => 100, cache_creation => 50, cache_5m => 30, cache_1h => 20, cache_read => 400, output => 7));

    my ($rc, $out) = run_spend('report-session', '--session', $main, '--by', 'token_type', '--json');
    is($rc, 0, 'TC7: json exits 0') or diag($out);
    my $doc = eval { JSON::PP->new->decode($out) };
    ok($doc, 'TC7: stdout parses') or diag($out);
  SKIP: {
        skip 'TC7: doc unavailable', 2 unless $doc;
        my $bad = 0;
        for my $r (@{ $doc->{rows} }) {
            my @keys = sort keys %$r;
            $bad++ unless "@keys" eq join(' ', sort qw(token_type tokens api_equivalent_cost_usd unpriced_tokens unpriced_reasons));
        }
        is($bad, 0, 'TC7: every row has EXACTLY token_type/tokens/api_equivalent_cost_usd/unpriced_tokens/unpriced_reasons, no *_tokens keys');
        my $has_type_key = grep { grep { /_tokens$/ && $_ ne 'unpriced_tokens' } keys %$_ } @{ $doc->{rows} };
        is($has_type_key, 0, 'TC7: no row carries any of the six *_tokens keys when token_type is in --by');
    }

    my ($rc2, $out2) = run_spend('report-session', '--session', $main, '--by', 'token_type');
    is($rc2, 0, 'TC7 text: exits 0') or diag($out2);
    like($out2, qr/input=\d+ cache_write_5m=\d+ cache_write_1h=\d+ cache_write_unsplit=\d+ cache_read=\d+ output=\d+/,
        'TC7 text: rows still print the full TOK segment even though --by is token_type') or diag($out2);
};

# ===========================================================================
# TC8 (DC3, Decision 20) -- derive-package adds the 5m/1h/unsplit split.
# ===========================================================================
subtest 'TC8: derive-package adds cache_write_5m/1h/unsplit_tokens to tokens.{coordinator,subagent} and by_model' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $a = fleet_assistant_rec(session => 'sess-1', parent => undef, model => 'claude-sonnet-5',
        input => 1, output => 1, cache_creation => 50, cache_5m => 30, cache_1h => 20);
    my $b = fleet_assistant_rec(session => 'sess-1', parent => undef, model => 'claude-sonnet-5',
        input => 1, output => 1, cache_creation => 60);
    my $c = fleet_assistant_rec(session => 'sess-1', parent => 'toolu_1', model => 'claude-sonnet-5',
        input => 1, output => 1, cache_creation => 7, cache_5m => 7, cache_1h => 0);
    write_jsonl(runs_path($dir, 'p1'),
        sys_init(session => 'sess-1'), $a, $b, $c,
        result_rec(session => 'sess-1', total_cost_usd => 1.23));

    my ($rc, $out) = run_spend('derive-package', '--run-dir', $dir, '--pkg', 'p1');
    is($rc, 0, 'TC8: exits 0') or diag($out);
    my $doc = slurp_json(derived_path($dir));
    ok($doc, 'TC8: spend-derived.json parses') or diag(slurp_raw(derived_path($dir)) // '<missing>');
  SKIP: {
        skip 'TC8: no doc to inspect', 10 unless $doc;
        is($doc->{tokens}{coordinator}{cache_creation},        110, 'TC8: coordinator cache_creation == 50+60');
        is($doc->{tokens}{coordinator}{cache_write_5m_tokens},   30, 'TC8: coordinator cache_write_5m_tokens');
        is($doc->{tokens}{coordinator}{cache_write_1h_tokens},   20, 'TC8: coordinator cache_write_1h_tokens');
        is($doc->{tokens}{coordinator}{cache_write_unsplit_tokens}, 60, 'TC8: coordinator cache_write_unsplit_tokens');
        is($doc->{tokens}{subagent}{cache_creation},              7, 'TC8: subagent cache_creation');
        is($doc->{tokens}{subagent}{cache_write_5m_tokens},       7, 'TC8: subagent cache_write_5m_tokens');
        is($doc->{tokens}{subagent}{cache_write_1h_tokens},       0, 'TC8: subagent cache_write_1h_tokens');
        is($doc->{tokens}{subagent}{cache_write_unsplit_tokens},  0, 'TC8: subagent cache_write_unsplit_tokens');
        my $bm = $doc->{by_model}{'claude-sonnet-5'};
        ok($bm, 'TC8: by_model.claude-sonnet-5 exists');
        if ($bm) {
            is($bm->{cache_write_5m_tokens},       30 + 7, 'TC8: by_model cache_write_5m_tokens == coordinator+subagent');
            is($bm->{cache_write_1h_tokens},       20 + 0, 'TC8: by_model cache_write_1h_tokens == coordinator+subagent');
            is($bm->{cache_write_unsplit_tokens},  60 + 0, 'TC8: by_model cache_write_unsplit_tokens == coordinator+subagent');
        }
        my $pkg = $doc->{packages}[0];
        ok($pkg, 'TC8: packages[0] exists');
        if ($pkg) {
            is($pkg->{cross_check}{total_cost_usd}, 1.23, 'TC8: packages[0].cross_check.total_cost_usd == result.total_cost_usd');
            is($pkg->{cross_check}{cost_source}, 'claude-code-self-reported-headless',
                'TC8: packages[0].cross_check.cost_source is the exact literal');
        }
    }
};

# ===========================================================================
# TC9 (DC3, Decision 20; rewritten per spend-token-report package 02 spec
# SS4.3 for Decision 27 -- derive-package/derive-blueprint now fetch and
# stamp a price, so price-shaped keys are EXPECTED, but only at the
# documented paths, and only when pricing was actually fetched).
# ===========================================================================
subtest 'TC9: derive-blueprint sums the split keys; price keys appear only at the stamped paths' => sub {
    my $dir = tempdir(CLEANUP => 1);
    write_jsonl(runs_path($dir, 'p1'),
        sys_init(session => 's1'),
        fleet_assistant_rec(session => 's1', parent => undef, model => 'claude-sonnet-5',
            input => 1, output => 1, cache_creation => 30, cache_5m => 30, cache_1h => 0));
    write_jsonl(runs_path($dir, 'p2'),
        sys_init(session => 's2'),
        fleet_assistant_rec(session => 's2', parent => undef, model => 'claude-sonnet-5',
            input => 1, output => 1, cache_creation => 20, cache_5m => 0, cache_1h => 20));

    my ($rc, $out) = run_spend('derive-blueprint', '--run-dir', $dir);
    is($rc, 0, 'TC9: exits 0') or diag($out);
    my $doc = slurp_json(derived_path($dir));
    ok($doc, 'TC9: doc parses') or diag(slurp_raw(derived_path($dir)) // '<missing>');
  SKIP: {
        skip 'TC9: no doc to inspect', 4 unless $doc;
        is($doc->{tokens}{coordinator}{cache_write_5m_tokens}, 30, 'TC9: top-level cache_write_5m_tokens sums across packages');
        is($doc->{tokens}{coordinator}{cache_write_1h_tokens}, 20, 'TC9: top-level cache_write_1h_tokens sums across packages');
        is($doc->{by_model}{'claude-sonnet-5'}{cache_write_5m_tokens}, 30, 'TC9: by_model cache_write_5m_tokens sums across packages');

        my @paths;
        my $scan;
        $scan = sub {
            my ($node, $path) = @_;
            if (ref($node) eq 'HASH') {
                for my $k (sort keys %$node) {
                    push @paths, "$path.$k" if $k =~ /api_equivalent|price_|pricing/;
                    $scan->($node->{$k}, "$path.$k");
                }
            } elsif (ref($node) eq 'ARRAY') {
                $scan->($_, "$path\[\]") for @$node;
            }
        };
        $scan->($doc, '$');
        is_deeply([ sort @paths ],
            [ '$.api_equivalent_cost_usd', '$.packages[].api_equivalent_cost_usd', '$.packages[].api_equivalent_cost_usd',
              '$.price_fetched_at', '$.price_source', '$.pricing_status' ],
            'TC9: price-shaped keys appear only at the stamped paths (two packages)') or diag(join(', ', @paths));
    }

    # Under this file's NO_FETCH=1, the run above was offline: no cost.
    is($doc->{pricing_status}, 'offline', 'TC9: pricing_status is offline (this file sets NO_FETCH=1)') if $doc;
  SKIP: {
        skip 'TC9 offline: no doc to inspect', 4 unless $doc;
        ok(!defined($doc->{api_equivalent_cost_usd}), 'TC9: top-level cost undef under NO_FETCH=1');
        ok(!defined($doc->{packages}[0]{api_equivalent_cost_usd}), 'TC9: packages[0] cost undef under NO_FETCH=1');
        ok(!defined($doc->{packages}[1]{api_equivalent_cost_usd}), 'TC9: packages[1] cost undef under NO_FETCH=1');
        is_deeply($doc->{unpriced_reasons}, [ { reason => 'offline', tokens => 54 } ],
            'TC9: top-level unpriced_reasons is exactly [{offline,54}] (p1 1+1+30, p2 1+1+20)') or diag($JSON->encode($doc->{unpriced_reasons} // []));
    }
};

# ===========================================================================
# TC10 (Decision 7/25/27, DC3, DC5; rewritten per spend-token-report package
# 02 spec SS4.3 -- the fleet path now DOES fetch, but exactly once per CLI
# run, never once per package).
# ===========================================================================
subtest 'TC10: derive-package and derive-blueprint fetch exactly once per run through the seam' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $stubdir = tempdir(CLEANUP => 1);
    my $stub = File::Spec->catfile($stubdir, 'stub.pl');
    open(my $sfh, '>', $stub) or die $!;
    print $sfh <<'STUB';
#!/usr/bin/env perl
open(my $fh, '>>', "$ENV{SPEND_STUB_COUNTER}") or die $!;
print $fh "$ARGV[0]\n";
close $fh;
print "ok\n200";
STUB
    close $sfh;
    my $counter = File::Spec->catfile($stubdir, 'counter.txt');

    write_jsonl(runs_path($dir, 'p1'),
        sys_init(session => 's1'),
        fleet_assistant_rec(session => 's1', parent => undef, model => 'claude-sonnet-5', input => 1, output => 1));
    write_jsonl(runs_path($dir, 'p2'),
        sys_init(session => 's2'),
        fleet_assistant_rec(session => 's2', parent => undef, model => 'claude-sonnet-5', input => 1, output => 1));

    local $ENV{CCPRAXIS_SPEND_FETCH_CMD} = $stub;
    local $ENV{SPEND_STUB_COUNTER}       = $counter;
    delete local $ENV{CCPRAXIS_SPEND_NO_FETCH};

    my ($rc, $out) = run_spend('derive-package', '--run-dir', $dir, '--pkg', 'p1');
    is($rc, 0, 'TC10: derive-package exits 0') or diag($out);
    my @lines1 = -e $counter ? do { open(my $fh, '<', $counter) or die $!; my @l = <$fh>; close $fh; @l } : ();
    is(scalar(@lines1), 1, 'TC10: derive-package fetches exactly once (1 counter line)') or diag(join('', @lines1));

    my ($rc2, $out2) = run_spend('derive-blueprint', '--run-dir', $dir);
    is($rc2, 0, 'TC10: derive-blueprint exits 0') or diag($out2);
    my @lines2 = -e $counter ? do { open(my $fh, '<', $counter) or die $!; my @l = <$fh>; close $fh; @l } : ();
    is(scalar(@lines2), 2, 'TC10: derive-blueprint over two packages adds exactly one more line (one fetch per run, not per package)')
        or diag(join('', @lines2));

    my $doc = slurp_json(derived_path($dir));
    ok($doc, 'TC10: last doc parses') or diag(slurp_raw(derived_path($dir)) // '<missing>');
  SKIP: {
        skip 'TC10: no doc to inspect', 3 unless $doc;
        is($doc->{pricing_status}, 'unavailable: standard price table not found',
            'TC10: the stub\'s bare "ok\\n200" body has no price table, so pricing_status names that');
        chomp(my $last_line = $lines2[-1] // '');
        is($doc->{price_source}, $last_line, 'TC10: price_source equals the counter\'s last logged line');
        ok(!defined($doc->{api_equivalent_cost_usd}), 'TC10: top-level cost is undef (no price table to price from)');
    }
};

# ===========================================================================
# TC11 (Decision 5, out of scope) -- snapshot is byte-identical (claude only since
# the OpenCode go/zen providers were removed).
# ===========================================================================
subtest 'TC11: snapshot --offline writes the exact pre-change bytes, with or without NO_FETCH set' => sub {
    my $iso = iso_from_epoch(1790000000);
    my $want = qq({"generated_at":"$iso","results":[{"provider":"claude","status":"absent"}]});

    for my $case (['NO_FETCH set (this file\'s default)', 1], ['NO_FETCH unset', undef]) {
        my ($label, $nofetch) = @$case;
        my $dir = tempdir(CLEANUP => 1);
        local $ENV{CCPRAXIS_SPEND_NO_FETCH} = $nofetch if defined $nofetch;
        delete local $ENV{CCPRAXIS_SPEND_NO_FETCH} unless defined $nofetch;
        my ($rc, $out) = run_spend('snapshot', '--offline', '--run-dir', $dir, '--now', 1790000000);
        is($rc, 0, "TC11 ($label): exits 0") or diag($out);
        my $expect_path = File::Spec->catfile($dir, 'spend.json');
        chomp(my $stdout_path = $out);
        is($stdout_path, $expect_path, "TC11 ($label): stdout is exactly the path") or diag($out);
        my $bytes = slurp_raw($expect_path);
        is($bytes, $want, "TC11 ($label): spend.json bytes are byte-identical to the pre-change shape") or diag($bytes // '<missing>');
    }
};

done_testing();
