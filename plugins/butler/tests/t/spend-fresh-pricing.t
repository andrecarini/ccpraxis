#!/usr/bin/env perl
# platform: any
# Oracle for blueprint spend-token-report, package
# 01-token-columns-fresh-pricing (DC2, DC5): BpPricing's acquisition
# precedence (PRICING_FILE, then offline/NO_FETCH, then the live fetch via
# the CCPRAXIS_SPEND_FETCH_CMD transport seam, Decisions 16/21), the parser
# (standard/long-context/fast-mode tables, Decision 3/10/22), per-request
# rate selection, unpriced reasons (Decision 4/10/18/22), and that nothing is
# ever cached on disk (Decision 1/12). Spec: specs/01-token-columns-fresh-
# pricing-spec.md §4.2/§4.3.
#
# NO test here ever touches the network. Every seam test writes its own
# stub.pl (spec §4) into a private tempdir, sets CCPRAXIS_SPEND_FETCH_CMD to
# it, and deletes CCPRAXIS_SPEND_NO_FETCH/CCPRAXIS_SPEND_PRICING_FILE for
# that child only (local). Every other test in this file sets
# CCPRAXIS_SPEND_NO_FETCH=1 at file scope (Decision 16).
#
# THIS FILE IS THE PACKAGE'S ORACLE for the pricing-acquisition/parser/
# rate-selection behaviour. It must not be weakened to make an
# implementation's life easier.
use strict;
use warnings;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Spec;
use File::Path qw(make_path);
use File::Basename qw(basename);
use Test::More;
use JSON::PP;

# spend-token-report Decision 16: never let this test reach a live fetch,
# except the seam subtests below, which delete this for their own child only.
$ENV{CCPRAXIS_SPEND_NO_FETCH} = 1;

my $SPEND_PL = "$Bin/../../scripts/bp-spend.pl";
ok(-f $SPEND_PL, 'bp-spend.pl exists') or BAIL_OUT('nothing to test');

my $PERL = $^X;
my $JSON = JSON::PP->new->canonical;

my $SPEND_LOADED = do { local $@; eval { require $SPEND_PL }; !$@ };
ok($SPEND_LOADED, 'HARNESS: bp-spend.pl requires cleanly as a module')
    or diag("require failed: $@");

# ---------------------------------------------------------------------------
# generic helpers
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

sub write_text_file {
    my ($path, $text) = @_;
    my ($vol, $dir, undef) = File::Spec->splitpath($path);
    make_path($dir) if $dir && !-d $dir;
    open(my $fh, '>:raw', $path) or die "open $path: $!";
    print $fh $text;
    close $fh;
    return $path;
}

sub slurp_raw {
    my ($p) = @_;
    return undef unless -f $p;
    open(my $fh, '<:raw', $p) or return undef;
    my $raw = do { local $/; <$fh> };
    close $fh;
    return $raw;
}

sub read_lines {
    my ($p) = @_;
    my $raw = slurp_raw($p);
    return () unless defined $raw;
    return split(/\n/, $raw);
}

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
    $message{model} = $o{model}      if exists $o{model};
    $message{id}    = $o{message_id} if exists $o{message_id};

    my %rec = (
        type       => 'assistant',
        message    => \%message,
        session_id => $o{session} // 'sess-1',
        uuid       => $o{uuid} // ('u-' . int(rand(1e9))),
    );
    $rec{requestId} = $o{request_id} if exists $o{request_id};
    $rec{effort}    = $o{effort}     if exists $o{effort};
    return \%rec;
}

sub session_paths {
    my ($dir, $uuid) = @_;
    my $main   = File::Spec->catfile($dir, "$uuid.jsonl");
    my $subdir = File::Spec->catdir($dir, $uuid, 'subagents');
    return ($main, $subdir);
}

sub snapshot_tree {
    my (@dirs) = @_;
    my %snap;
    for my $dir (@dirs) {
        next unless -d $dir;
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
    }
    return \%snap;
}

# ===========================================================================
# Canonical fixtures (spec §4.3), embedded as heredocs. No shared fixture
# file: every test that needs one of these reads it from this file's own
# lexical scalars.
# ===========================================================================

my $F_MD = <<'MD';
# Pricing

Learn about Anthropic's pricing structure for models and features.

## Model pricing

The following table shows pricing for all Claude models.

| Model | Base Input Tokens | 5m Cache Writes | 1h Cache Writes | Cache Hits & Refreshes | Output Tokens |
|---|---|---|---|---|---|
| Claude Opus 5.5 | $4 / MTok | $5 / MTok | $8 / MTok | $0.20 / MTok | $20 / MTok |
| Claude Sonnet 5 | $2 / MTok | $2.50 / MTok | $4 / MTok | $0.20 / MTok | $10 / MTok |
| Claude Fable 5.1 | $10 / MTok | $12.50 / MTok | $20 / MTok | $0.25 / MTok | $50 / MTok |
| Claude Haiku 4.5 (`claude-haiku-4-5-20251001`) | $1 / MTok | $1.25 / MTok | $2 / MTok | $0.10 / MTok | $5 / MTok |
| Claude Opus 5 ([deprecated](/docs/en/about-claude/model-deprecations)) | $5 / MTok | $6.25 / MTok | $10 / MTok | $0.50 / MTok | $25 / MTok |
| `claude-test-9` | $3 / MTok | $3.75 / MTok | Not available | $0.30 / MTok | $15 / MTok |

## Batch processing

| Model | Batch input | Batch output |
|---|---|---|
| Claude Opus 5.5 | $2 / MTok | $10 / MTok |
| Claude Sonnet 5 | $1 / MTok | $5 / MTok |

## Long context pricing

When using the 1M token context window, requests that exceed 200K input tokens are charged at long context rates. The 200K threshold is based on input tokens, including cache reads and writes.

| Model | Input (<= 200K) | Input (> 200K) | Output (<= 200K) | Output (> 200K) |
|---|---|---|---|---|
| Claude Opus 5.5 | $4 / MTok | $8 / MTok | $20 / MTok | $30 / MTok |

Prompt caching multipliers apply on top of long context rates.

## Fast mode pricing

| Model | Input | Output |
|---|---|---|
| Claude Opus 5.5 | $24 / MTok | $120 / MTok |
MD

my $F_HTML = <<'HTML';
<h1>Pricing</h1>
<p>Learn about Anthropic's pricing structure for models and features.</p>
<h2>Model pricing</h2>
<p>The following table shows pricing for all Claude models.</p>
<table><thead><tr><th>Model</th><th>Base Input Tokens</th><th>5m Cache Writes</th><th>1h Cache Writes</th><th>Cache Hits &amp; Refreshes</th><th>Output Tokens</th></tr></thead>
<tbody>
<tr><td>Claude Opus 5.5</td><td>$4 / MTok</td><td>$5 / MTok</td><td>$8 / MTok</td><td>$0.20 / MTok</td><td>$20 / MTok</td></tr>
<tr><td>Claude Sonnet 5</td><td>$2 / MTok</td><td>$2.50 / MTok</td><td>$4 / MTok</td><td>$0.20 / MTok</td><td>$10 / MTok</td></tr>
<tr><td>Claude Fable 5.1</td><td>$10 / MTok</td><td>$12.50 / MTok</td><td>$20 / MTok</td><td>$0.25 / MTok</td><td>$50 / MTok</td></tr>
<tr><td>Claude Haiku 4.5 (<code>claude-haiku-4-5-20251001</code>)</td><td>$1 / MTok</td><td>$1.25 / MTok</td><td>$2 / MTok</td><td>$0.10 / MTok</td><td>$5 / MTok</td></tr>
<tr><td>Claude Opus 5 (<a href="/docs/en/about-claude/model-deprecations">deprecated</a>)</td><td>$5 / MTok</td><td>$6.25 / MTok</td><td>$10 / MTok</td><td>$0.50 / MTok</td><td>$25 / MTok</td></tr>
<tr><td><code>claude-test-9</code></td><td>$3 / MTok</td><td>$3.75 / MTok</td><td>Not available</td><td>$0.30 / MTok</td><td>$15 / MTok</td></tr>
</tbody></table>
<h2>Batch processing</h2>
<table><thead><tr><th>Model</th><th>Batch input</th><th>Batch output</th></tr></thead>
<tbody>
<tr><td>Claude Opus 5.5</td><td>$2 / MTok</td><td>$10 / MTok</td></tr>
<tr><td>Claude Sonnet 5</td><td>$1 / MTok</td><td>$5 / MTok</td></tr>
</tbody></table>
<h2>Long context pricing</h2>
<p>When using the 1M token context window, requests that exceed 200K input tokens are charged at long context rates. The 200K threshold is based on input tokens, including cache reads and writes.</p>
<table><thead><tr><th>Model</th><th>Input (&le; 200K)</th><th>Input (&gt; 200K)</th><th>Output (&le; 200K)</th><th>Output (&gt; 200K)</th></tr></thead>
<tbody>
<tr><td>Claude Opus 5.5</td><td>$4 / MTok</td><td>$8 / MTok</td><td>$20 / MTok</td><td>$30 / MTok</td></tr>
</tbody></table>
<p>Prompt caching multipliers apply on top of long context rates.</p>
<h2>Fast mode pricing</h2>
<table><thead><tr><th>Model</th><th>Input</th><th>Output</th></tr></thead>
<tbody>
<tr><td>Claude Opus 5.5</td><td>$24 / MTok</td><td>$120 / MTok</td></tr>
</tbody></table>
HTML

my $F_MD_VARIANT = <<'MD';
# Pricing

Learn about Anthropic's pricing structure for models and features.

## Model pricing

The following table shows pricing for all Claude models.

| Model | Output Tokens | Cache Hits & Refreshes | 1h Cache Writes | 5m Cache Writes | Base Input Tokens | Notes |
|---|---|---|---|---|---|---|
| Claude Opus 5.5 | $20/MTok | $0.20/MTok | $8/MTok | $5/MTok | $4/MTok | |
| Claude Sonnet 5 | $10 / MTok | $0.20 / MTok | $4 / MTok | $2.50 / MTok | $2 / MTok | $99 / MTok |
| Claude Fable 5.1 | $50 / MTok | $0.25 / MTok | $20 / MTok | $12.50 / MTok | $10 / MTok | |
| Claude Haiku 4.5 (`claude-haiku-4-5-20251001`) | $5 / MTok | $0.10 / MTok | $2 / MTok | $1.25 / MTok | $1 / MTok | |
| Claude Opus 5 ([deprecated](/docs/en/about-claude/model-deprecations)) | $25 / MTok | $0.50 / MTok | $10 / MTok | $6.25 / MTok | $5 / MTok | |
| `claude-test-9` | $15 / MTok | $0.30 / MTok | Not available | $3.75 / MTok | $3 / MTok | |

## Batch processing

| Model | Batch input | Batch output |
|---|---|---|
| Claude Opus 5.5 | $2 / MTok | $10 / MTok |
| Claude Sonnet 5 | $1 / MTok | $5 / MTok |

## Long context pricing

When using the 1M token context window, requests that exceed 200K input tokens are charged at long context rates. The 200K threshold is based on input tokens, including cache reads and writes.

| Model | Input (<= 200K) | Input (> 200K) | Output (<= 200K) | Output (> 200K) |
|---|---|---|---|---|
| Claude Opus 5.5 | $4 / MTok | $8 / MTok | $20 / MTok | $30 / MTok |

Prompt caching multipliers apply on top of long context rates.

## Fast mode pricing

| Model | Input | Output |
|---|---|---|
| Claude Opus 5.5 | $24 / MTok | $120 / MTok |
MD

(my $F_NO_LC = $F_MD) =~ s{\n## Long context pricing\n.*?\n(?=## Fast mode pricing)}{}s;

(my $F_LC_NO_THRESHOLD = $F_MD) =~ s{
When\ using\ the\ 1M\ token\ context\ window,\ requests\ that\ exceed\ 200K\ input\ tokens\ are\ charged\ at\ long\ context\ rates\.\ The\ 200K\ threshold\ is\ based\ on\ input\ tokens,\ including\ cache\ reads\ and\ writes\.
}{When using the 1M token context window, long requests are charged at long context rates.}x;
$F_LC_NO_THRESHOLD =~ s{\| Model \| Input \(<= 200K\) \| Input \(> 200K\) \| Output \(<= 200K\) \| Output \(> 200K\) \|}
                       {| Model | Input (standard) | Input (long) | Output (standard) | Output (long) |};

(my $F_LC_UNRESOLVED = $F_MD) =~ s{
\|\ Model\ \|\ Input\ \(<=\ 200K\)\ \|\ Input\ \(>\ 200K\)\ \|\ Output\ \(<=\ 200K\)\ \|\ Output\ \(>\ 200K\)\ \|
\n\|---\|---\|---\|---\|---\|
\n\|\ Claude\ Opus\ 5\.5\ \|\ \$4\ /\ MTok\ \|\ \$8\ /\ MTok\ \|\ \$20\ /\ MTok\ \|\ \$30\ /\ MTok\ \|
}{| <= 200K input tokens | > 200K input tokens |
|---|---|
| Input: \$4 / MTok | Input: \$8 / MTok |
| Output: \$20 / MTok | Output: \$30 / MTok |}x;

# FP12: standard table duplicated -- append a second copy of the same table
# under a new heading so two qualifying standard tables exist.
my $F_MD_DUP_STANDARD = $F_MD . "\n## Model pricing (again)\n\n"
    . "| Model | Base Input Tokens | 5m Cache Writes | 1h Cache Writes | Cache Hits & Refreshes | Output Tokens |\n"
    . "|---|---|---|---|---|---|\n"
    . "| Claude Sonnet 5 | \$2 / MTok | \$2.50 / MTok | \$4 / MTok | \$0.20 / MTok | \$10 / MTok |\n";

# FP12: every rate cell replaced by TBD -- no model has a complete row.
(my $F_MD_ALL_TBD = $F_MD) =~ s{\$[\d.]+ / MTok}{TBD}g;

# FP17 (Decision 23): the CURRENT live-page shape. The long-context section
# states only that models get the full 1M context at standard pricing --
# no threshold sentence, no rate table. Two standard-table cells carry
# <sup>N</sup> footnote markers. The fast-mode row names two models
# separated by " / ".
my $F_LIVE_SHAPE = <<'MD';
# Pricing

Learn about Anthropic's pricing structure for models and features.

## Model pricing

The following table shows pricing for all Claude models.

| Model | Base Input Tokens | 5m Cache Writes | 1h Cache Writes | Cache Hits & Refreshes | Output Tokens |
|---|---|---|---|---|---|
| Claude Opus 5.5 | $4 / MTok | $5 / MTok | $8 / MTok | $0.20 / MTok | $20 / MTok |
| Claude Sonnet 5 | $2 / MTok<sup>1</sup> | $2.50 / MTok | $4 / MTok | $0.20 / MTok | $10 / MTok<sup>1</sup> |
| Claude Fable 5.1 | $10 / MTok | $12.50 / MTok | $20 / MTok | $0.25 / MTok | $50 / MTok |

## Batch processing

| Model | Batch input | Batch output |
|---|---|---|
| Claude Opus 5.5 | $2 / MTok | $10 / MTok |
| Claude Sonnet 5 | $1 / MTok | $5 / MTok |

## Long context pricing

Claude 4.6+ models include the full 1M token context window at standard pricing.

## Fast mode pricing

| Model | Input | Output |
|---|---|---|
| Claude Opus 5 / Claude Sonnet 5 | $24 / MTok | $120 / MTok |

<sup>1</sup> Effective pricing for this model reflects a limited-time promotion.
MD

# Decision 24 M2: two fast-mode rows for claude-opus-5-5 with DIFFERENT rates
# in the same fast-mode table (reviewer's probe: a second "Claude Opus 5.5"
# row reading $99 / $999 immediately below the real $24 / $120 row).
(my $F_MD_FAST_CONFLICT = $F_MD) =~
    s{(\| Claude Opus 5\.5 \| \$24 / MTok \| \$120 / MTok \|\n)}
     {$1| Claude Opus 5.5 | \$99 / MTok | \$999 / MTok |\n};

# Decision 24 M3: the long-context section states a premium in PROSE, with
# no threshold sentence the parser recognises and no rate table -- the exact
# shape from the reviewer's probe (M3).
(my $F_LC_PROSE_PREMIUM = $F_NO_LC) =~
    s{\n## Fast mode pricing\n}
     {\n## Long context pricing\n\nRequests with over 200,000 input tokens are billed at \$8 / MTok input and \$30 / MTok output.\n\n## Fast mode pricing\n};

# Decision 24 S2: a fenced code block containing a "# ..." line, placed
# right before the batch table -- the reviewer's exact probe shape ("a
# fenced `# enable fast mode` placed before the batch table made the batch
# table the fast table").
(my $F_MD_CODEFENCE = $F_MD) =~
    s{\n## Batch processing\n}
     {\n```\n# enable fast mode\n```\n\n## Batch processing\n};

sub iso_now { my @g = gmtime(time); return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $g[5]+1900, $g[4]+1, $g[3], $g[2], $g[1], $g[0]); }

# ---------------------------------------------------------------------------
# The seam stub (spec §4). Written once per test into its own tempdir; its
# behaviour is controlled at runtime by $ENV{SPEND_STUB_MODE}.
# ---------------------------------------------------------------------------
sub write_stub {
    my ($dir) = @_;
    write_text_file(File::Spec->catfile($dir, 'F-MD.md'), $F_MD);
    write_text_file(File::Spec->catfile($dir, 'F-HTML.html'), $F_HTML);
    my $stub = File::Spec->catfile($dir, 'stub.pl');
    write_text_file($stub, <<'STUB');
#!/usr/bin/env perl
use strict; use warnings;
use File::Basename qw(dirname);
my $here = dirname($0);
open(my $cfh, '>>', $ENV{SPEND_STUB_COUNTER}) or die "counter: $!";
print $cfh "$ARGV[0]\n";
close $cfh;
my $mode = $ENV{SPEND_STUB_MODE} // 'ok';
sub slurp { my ($p) = @_; open(my $fh, '<:raw', $p) or die $!; local $/; my $x = <$fh>; close $fh; return $x; }
if ($mode eq 'ok') {
    print slurp("$here/F-MD.md"); print "\n200";
} elsif ($mode eq 'html') {
    print slurp("$here/F-HTML.html"); print "\n200";
} elsif ($mode eq 'garbage') {
    print '<html><body>Service temporarily unavailable</body></html>'; print "\n200";
} elsif ($mode eq 'http404') {
    print slurp("$here/F-MD.md"); print "\n404";
} elsif ($mode eq 'fail') {
    exit 7;
} else {
    die "unknown SPEND_STUB_MODE: $mode";
}
STUB
    return $stub;
}

# Runs bp-spend.pl with the seam armed for that child only. %o: mode, stub,
# counter, plus any extra env overrides (pricing_file, offline_var etc).
sub run_seam {
    my ($mode, $stub, $counter, @args) = @_;
    local $ENV{CCPRAXIS_SPEND_FETCH_CMD} = $stub;
    local $ENV{SPEND_STUB_MODE}          = $mode;
    local $ENV{SPEND_STUB_COUNTER}       = $counter;
    delete local $ENV{CCPRAXIS_SPEND_NO_FETCH};
    delete local $ENV{CCPRAXIS_SPEND_PRICING_FILE};
    return run_spend(@args);
}

# ===========================================================================
# FP1 (DC2 2a) -- standard cost, hand-computable.
# ===========================================================================
subtest 'FP1: standard-rate cost is exact for a request at the fixture rates' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $stubdir = tempdir(CLEANUP => 1);
    my $stub = write_stub($stubdir);
    my $counter = File::Spec->catfile($stubdir, 'counter.txt');
    my ($main) = session_paths($dir, 'sess-fp1');
    write_jsonl($main, assistant_rec(request_id => 'req-fp1', model => 'claude-sonnet-5',
        input => 1_000_000, cache_creation => 2_000_000, cache_5m => 1_000_000, cache_1h => 1_000_000,
        cache_read => 1_000_000, output => 1_000_000));

    my ($rc, $out) = run_seam('ok', $stub, $counter, 'report-session', '--session', $main, '--json');
    is($rc, 0, 'FP1: exits 0') or diag($out);
    my $doc = eval { JSON::PP->new->decode($out) };
    ok($doc, 'FP1: stdout parses') or diag($out);
  SKIP: {
        skip 'FP1: doc unavailable', 3 unless $doc;
        my ($row) = @{ $doc->{rows} // [] };
        ok($row, 'FP1: exactly one row');
        if ($row) {
            ok(abs($row->{api_equivalent_cost_usd} - 18.7) < 1e-9, 'FP1: api_equivalent_cost_usd == 18.7')
                or diag($row->{api_equivalent_cost_usd});
            is($row->{unpriced_tokens}, 0, 'FP1: unpriced_tokens == 0');
            is_deeply($row->{unpriced_reasons}, [], 'FP1: unpriced_reasons == []');
        }
    }

    my ($rc2, $out2) = run_seam('ok', $stub, $counter, 'report-session', '--session', $main);
    is($rc2, 0, 'FP1 text: exits 0') or diag($out2);
    like($out2, qr/api_equivalent_cost=\$18\.700000/, 'FP1 text: row cost is $18.700000') or diag($out2);
};

# ===========================================================================
# FP2 (DC2 2a) -- long context, three requests: under/over/boundary.
# ===========================================================================
subtest 'FP2: long-context rates apply strictly-over the threshold; boundary is standard' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $stubdir = tempdir(CLEANUP => 1);
    my $stub = write_stub($stubdir);
    my $counter = File::Spec->catfile($stubdir, 'counter.txt');
    my ($main) = session_paths($dir, 'sess-fp2');
    write_jsonl($main,
        assistant_rec(request_id => 'r1', model => 'claude-opus-5-5', effort => 'e-under',
            input => 100_000, cache_read => 50_000, output => 10_000),
        assistant_rec(request_id => 'r2', model => 'claude-opus-5-5[1m]', effort => 'e-over',
            input => 150_000, cache_creation => 20_000, cache_5m => 20_000, cache_1h => 0,
            cache_read => 60_000, output => 10_000),
        assistant_rec(request_id => 'r3', model => 'claude-opus-5-5-20260101', effort => 'e-boundary',
            input => 200_000, output => 0),
    );
    my ($rc, $out) = run_seam('ok', $stub, $counter, 'report-session', '--session', $main, '--by', 'effort', '--json');
    is($rc, 0, 'FP2: exits 0') or diag($out);
    my $doc = eval { JSON::PP->new->decode($out) };
    ok($doc, 'FP2: stdout parses') or diag($out);
  SKIP: {
        skip 'FP2: doc unavailable', 3 unless $doc;
        my %by_effort = map { $_->{effort} => $_ } @{ $doc->{rows} // [] };
        ok(abs(($by_effort{'e-under'}{api_equivalent_cost_usd} // -1) - 0.61) < 1e-9,
            'FP2: e-under (<=200K) is standard-priced: 0.61') or diag($JSON->encode($by_effort{'e-under'} // {}));
        ok(abs(($by_effort{'e-over'}{api_equivalent_cost_usd} // -1) - 1.724) < 1e-9,
            'FP2: e-over (>200K) is LC-priced: 1.724') or diag($JSON->encode($by_effort{'e-over'} // {}));
        ok(abs(($by_effort{'e-boundary'}{api_equivalent_cost_usd} // -1) - 0.8) < 1e-9,
            'FP2: e-boundary (==200K, not strictly over) is standard-priced: 0.8') or diag($JSON->encode($by_effort{'e-boundary'} // {}));
    }
};

# ===========================================================================
# FP3 (DC2 2a) -- format/layout robustness: html and a reordered/variant md.
# ===========================================================================
subtest 'FP3: FP1/FP2 results are identical when served as html, or via a reordered PRICING_FILE' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $stubdir = tempdir(CLEANUP => 1);
    my $stub = write_stub($stubdir);
    my $counter = File::Spec->catfile($stubdir, 'counter.txt');
    my ($main1) = session_paths($dir, 'sess-fp3a');
    write_jsonl($main1, assistant_rec(request_id => 'req-fp3', model => 'claude-sonnet-5',
        input => 1_000_000, cache_creation => 2_000_000, cache_5m => 1_000_000, cache_1h => 1_000_000,
        cache_read => 1_000_000, output => 1_000_000));

    my ($rc_html, $out_html) = run_seam('html', $stub, $counter, 'report-session', '--session', $main1, '--json');
    is($rc_html, 0, 'FP3 html: exits 0') or diag($out_html);
    my $doc_html = eval { JSON::PP->new->decode($out_html) };
    ok($doc_html, 'FP3 html: stdout parses') or diag($out_html);
  SKIP: {
        skip 'FP3 html: unavailable', 1 unless $doc_html;
        ok(abs(($doc_html->{rows}[0]{api_equivalent_cost_usd} // -1) - 18.7) < 1e-9, 'FP3 html: same 18.7 result as FP1')
            or diag($JSON->encode($doc_html->{rows}[0] // {}));
    }

    my $varfile = File::Spec->catfile(tempdir(CLEANUP => 1), 'F-MD-VARIANT.md');
    write_text_file($varfile, $F_MD_VARIANT);
    local $ENV{CCPRAXIS_SPEND_PRICING_FILE} = $varfile;
    delete local $ENV{CCPRAXIS_SPEND_NO_FETCH};
    my ($rc_var, $out_var) = run_spend('report-session', '--session', $main1, '--json');
    is($rc_var, 0, 'FP3 variant-file: exits 0') or diag($out_var);
    my $doc_var = eval { JSON::PP->new->decode($out_var) };
    ok($doc_var, 'FP3 variant-file: stdout parses') or diag($out_var);
  SKIP: {
        skip 'FP3 variant-file: unavailable', 1 unless $doc_var;
        ok(abs(($doc_var->{rows}[0]{api_equivalent_cost_usd} // -1) - 18.7) < 1e-9,
            'FP3 variant-file: reordered columns, extra ignored Notes column, no-space rates -- still 18.7')
            or diag($JSON->encode($doc_var->{rows}[0] // {}));
    }
};

# ===========================================================================
# FP4 (DC2 2b) -- fetches again every run; nothing cached on disk.
# ===========================================================================
subtest 'FP4: a second run fetches again; the counter has two lines; nothing new appears on disk' => sub {
    my $home    = tempdir(CLEANUP => 1);
    my $tmp     = tempdir(CLEANUP => 1);
    my $dataroot = tempdir(CLEANUP => 1);
    make_path(File::Spec->catdir($dataroot, '.ccpraxis-local-data'));
    my $data_dir = File::Spec->catdir($dataroot, '.ccpraxis-local-data');

    my $dir = tempdir(CLEANUP => 1);
    my $stubdir = tempdir(CLEANUP => 1);
    my $stub = write_stub($stubdir);
    my $counter = File::Spec->catfile($stubdir, 'counter.txt');
    my ($main) = session_paths($dir, 'sess-fp4');
    write_jsonl($main, assistant_rec(request_id => 'req-fp4', model => 'claude-sonnet-5', input => 10, output => 1));

    local $ENV{HOME}        = $home;
    local $ENV{USERPROFILE} = $home;
    local $ENV{TEMP}        = $tmp;
    local $ENV{TMP}         = $tmp;
    local $ENV{TMPDIR}      = $tmp;

    my $before = snapshot_tree($home, $tmp, $data_dir);
    my ($rc1, $out1) = run_seam('ok', $stub, $counter, 'report-session', '--session', $main, '--data-root', $data_dir, '--json');
    is($rc1, 0, 'FP4: first run exits 0') or diag($out1);
    my ($rc2, $out2) = run_seam('ok', $stub, $counter, 'report-session', '--session', $main, '--data-root', $data_dir, '--json');
    is($rc2, 0, 'FP4: second run exits 0') or diag($out2);
    my $after = snapshot_tree($home, $tmp, $data_dir);

    my @counter_lines = read_lines($counter);
    is(scalar(@counter_lines), 2, 'FP4: the seam was called exactly twice across the two runs') or diag(join("\n", @counter_lines));
    my $doc1 = eval { JSON::PP->new->decode($out1) };
    if ($doc1) {
        is($counter_lines[0], $doc1->{price_source}, 'FP4: line 1 of the counter equals run 1\'s price_source');
    }
    is_deeply($after, $before, 'FP4: HOME/TEMP/.ccpraxis-local-data are byte- and mtime-identical after two report runs')
        or diag("before: " . $JSON->encode($before) . "\nafter: " . $JSON->encode($after));
};

# ===========================================================================
# FP5 (DC2 2c) -- failed fetch / garbage / http404.
# ===========================================================================
subtest 'FP5: a failed, garbage, or non-200 fetch still prints every token column, never a dollar figure' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $stubdir = tempdir(CLEANUP => 1);
    my $stub = write_stub($stubdir);
    my $counter = File::Spec->catfile($stubdir, 'counter.txt');
    my ($main) = session_paths($dir, 'sess-fp5');
    write_jsonl($main, assistant_rec(request_id => 'req-fp5', model => 'claude-sonnet-5',
        input => 100, cache_creation => 50, cache_5m => 30, cache_1h => 20, cache_read => 400, output => 7));

    my ($rc, $out) = run_seam('fail', $stub, $counter, 'report-session', '--session', $main, '--json');
    is($rc, 0, 'FP5 fail: exits 0') or diag($out);
    my $doc = eval { JSON::PP->new->decode($out) };
    ok($doc, 'FP5 fail: stdout parses') or diag($out);
  SKIP: {
        skip 'FP5 fail: unavailable', 5 unless $doc;
        is($doc->{pricing_status}, 'unavailable: fetch command exited 7', 'FP5 fail: exact pricing_status');
        my ($row) = @{ $doc->{rows} // [] };
        ok($row, 'FP5 fail: a row exists');
        if ($row) {
            is($row->{input_tokens}, 100, 'FP5 fail: input_tokens still printed');
            is($row->{output_tokens}, 7, 'FP5 fail: output_tokens still printed');
            ok(!defined($row->{api_equivalent_cost_usd}), 'FP5 fail: api_equivalent_cost_usd is null');
            is_deeply($row->{unpriced_reasons}, [ { reason => 'pricing-unavailable', tokens => $row->{tokens} } ],
                'FP5 fail: unpriced_reasons is exactly pricing-unavailable for the whole row') or diag($JSON->encode($row));
        }
        # report-session's JSON has no top-level "unpriced" key (that key
        # belongs to derive-session only; see FP10/spec 3.1). Check the same
        # fact -- everything is unpriced -- through totals instead.
        my $total_tokens   = 0;
        my $total_unpriced = 0;
        for my $t (values %{ $doc->{totals} }) {
            $total_tokens   += $t->{tokens};
            $total_unpriced += $t->{unpriced_tokens};
        }
        is($total_unpriced, $total_tokens,
            'FP5 fail: every totals.<type> is fully unpriced (its unpriced_tokens equals its tokens)');
    }

    my ($rct, $outt) = run_seam('fail', $stub, $counter, 'report-session', '--session', $main);
    is($rct, 0, 'FP5 fail text: exits 0') or diag($outt);
    my @lines = grep { /^(row|TOTAL):/ } split(/\n/, $outt);
    ok(@lines, 'FP5 fail text: has row/TOTAL lines');
    my @bad = grep { !/input=\d+ cache_write_5m=\d+ cache_write_1h=\d+ cache_write_unsplit=\d+ cache_read=\d+ output=\d+/
                   || !/api_equivalent_cost=unavailable: fetch command exited 7$/ } @lines;
    is_deeply(\@bad, [], 'FP5 fail text: every row/TOTAL line has the full TOK segment and ends unavailable: fetch command exited 7')
        or diag(join("\n", @bad));
    my @dollar_lines = grep { /\$\d/ } @lines;
    is_deeply(\@dollar_lines, [], 'FP5 fail text: no line matches /\$\d/');

    my ($rc2, $out2) = run_seam('garbage', $stub, $counter, 'report-session', '--session', $main, '--json');
    my $doc2 = eval { JSON::PP->new->decode($out2) };
    is(($doc2 // {})->{pricing_status}, 'unavailable: standard price table not found', 'FP5 garbage: exact reason') or diag($out2);

    my ($rc3, $out3) = run_seam('http404', $stub, $counter, 'report-session', '--session', $main, '--json');
    my $doc3 = eval { JSON::PP->new->decode($out3) };
    is(($doc3 // {})->{pricing_status}, 'unavailable: HTTP 404', 'FP5 http404: exact reason') or diag($out3);
};

# ===========================================================================
# FP6 (DC2 2d) -- unpriced reasons, exactly attributed.
# ===========================================================================
subtest 'FP6: unknown-model, cache-write-unsplit, non-standard-speed and rate-missing each tally exactly' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $stubdir = tempdir(CLEANUP => 1);
    my $stub = write_stub($stubdir);
    my $counter = File::Spec->catfile($stubdir, 'counter.txt');
    my ($main) = session_paths($dir, 'sess-fp6');
    write_jsonl($main,
        assistant_rec(request_id => 'a', model => 'claude-nonexistent-model', effort => 'e-a', input => 1000, output => 1),
        assistant_rec(request_id => 'b', model => 'claude-sonnet-5', effort => 'e-b', cache_creation => 500, input => 1, output => 1),
        assistant_rec(request_id => 'c', model => 'claude-sonnet-5', effort => 'e-c', speed => 'fast', input => 200, output => 300),
        assistant_rec(request_id => 'd', model => 'claude-test-9', effort => 'e-d', input => 1000, cache_creation => 1000, cache_5m => 0, cache_1h => 1000),
        assistant_rec(request_id => 'e', model => 'claude-opus-5-5', effort => 'e-e', speed => 'fast',
            input => 100_000, cache_read => 50_000, output => 10_000),
        assistant_rec(request_id => 'f', model => 'claude-opus-5-5', effort => 'e-f', speed => 'turbo', input => 10),
    );
    my ($rc, $out) = run_seam('ok', $stub, $counter, 'derive-session', '--session', $main, '--json');
    is($rc, 0, 'FP6: exits 0') or diag($out);
    my $doc = eval { JSON::PP->new->decode($out) };
    ok($doc, 'FP6: stdout parses') or diag($out);
  SKIP: {
        skip 'FP6: doc unavailable', 6 unless $doc;
        is($doc->{unpriced}{'unknown-model'},      1001, 'FP6: unknown-model == 1000+1');
        is($doc->{unpriced}{'cache-write-unsplit'}, 500, 'FP6: cache-write-unsplit == 500');
        is($doc->{unpriced}{'non-standard-speed'},  510, 'FP6: non-standard-speed == 200+300+10');
        is($doc->{unpriced}{'rate-missing'},       1000, 'FP6: rate-missing == the 1h cache-write on claude-test-9');
        my ($e_cell_input) = grep { $_->{effort} eq 'e-e' && $_->{token_type} eq 'input' } @{ $doc->{cells} };
        my ($e_cell_read)  = grep { $_->{effort} eq 'e-e' && $_->{token_type} eq 'cache_read' } @{ $doc->{cells} };
        my ($e_cell_out)   = grep { $_->{effort} eq 'e-e' && $_->{token_type} eq 'output' } @{ $doc->{cells} };
        my $e_total = ($e_cell_input->{api_equivalent_cost_usd} // 0) + ($e_cell_read->{api_equivalent_cost_usd} // 0)
                    + ($e_cell_out->{api_equivalent_cost_usd} // 0);
        ok(abs($e_total - 3.66) < 1e-9, 'FP6: (e), fast-priced, totals 3.66 across its three cells') or diag($e_total);
        my ($d_cell_input) = grep { $_->{effort} eq 'e-d' && $_->{token_type} eq 'input' } @{ $doc->{cells} };
        ok($d_cell_input && abs($d_cell_input->{api_equivalent_cost_usd} - 0.003) < 1e-9, 'FP6: (d) input priced at 0.003')
            or diag($JSON->encode($d_cell_input // {}));
    }
};

# ===========================================================================
# FP7 (DC2 2e) -- partial entry: some tokens priced, some not, same row.
# ===========================================================================
subtest 'FP7: a partial entry carries the priced sum plus unpriced_tokens/unpriced_reasons; a fully unpriced row has null' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $stubdir = tempdir(CLEANUP => 1);
    my $stub = write_stub($stubdir);
    my $counter = File::Spec->catfile($stubdir, 'counter.txt');
    my ($main) = session_paths($dir, 'sess-fp7');
    write_jsonl($main,
        assistant_rec(request_id => 'A', model => 'claude-sonnet-5', input => 1_000_000, output => 0),
        assistant_rec(request_id => 'B', model => 'claude-sonnet-5', cache_creation => 500, input => 0, output => 0),
        assistant_rec(request_id => 'C', model => 'claude-sonnet-5', speed => 'fast', output => 300, input => 0),
        assistant_rec(request_id => 'D', model => 'claude-nonexistent-model', input => 1000, output => 1),
    );
    my ($rc, $out) = run_seam('ok', $stub, $counter, 'report-session', '--session', $main, '--by', 'role,model', '--json');
    is($rc, 0, 'FP7: exits 0') or diag($out);
    my $doc = eval { JSON::PP->new->decode($out) };
    ok($doc, 'FP7: stdout parses') or diag($out);
  SKIP: {
        skip 'FP7: doc unavailable', 2 unless $doc;
        my ($sonnet_row) = grep { $_->{model} eq 'claude-sonnet-5' } @{ $doc->{rows} // [] };
        ok($sonnet_row, 'FP7: the sonnet row exists');
        if ($sonnet_row) {
            is($sonnet_row->{tokens}, 1_000_800, 'FP7: tokens == 1,000,000 + 500 + 300');
            ok(abs($sonnet_row->{api_equivalent_cost_usd} - 2) < 1e-9, 'FP7: api_equivalent_cost_usd == 2');
            is($sonnet_row->{unpriced_tokens}, 800, 'FP7: unpriced_tokens == 500 + 300');
            is_deeply($sonnet_row->{unpriced_reasons},
                [ { reason => 'cache-write-unsplit', tokens => 500 }, { reason => 'non-standard-speed', tokens => 300 } ],
                'FP7: unpriced_reasons in reason-ascending order') or diag($JSON->encode($sonnet_row));
        }
        my ($ghost_row) = grep { $_->{model} eq 'claude-nonexistent-model' } @{ $doc->{rows} // [] };
        ok($ghost_row, 'FP7: the fully-unpriced row exists');
        if ($ghost_row) {
            ok(!defined($ghost_row->{api_equivalent_cost_usd}), 'FP7: fully-unpriced row has api_equivalent_cost_usd null');
            is_deeply($ghost_row->{unpriced_reasons}, [ { reason => 'unknown-model', tokens => 1001 } ], 'FP7: unpriced_reasons for the ghost row');
        }
    }

    my ($rc2, $out2) = run_seam('ok', $stub, $counter, 'report-session', '--session', $main, '--by', 'role,model');
    is($rc2, 0, 'FP7 text: exits 0') or diag($out2);
    like($out2, qr/api_equivalent_cost=\$2\.000000 \+ unpriced 800 tokens \(cache-write-unsplit 500, non-standard-speed 300\)/,
        'FP7 text: the sonnet row\'s cost cell matches exactly') or diag($out2);
    like($out2, qr/api_equivalent_cost=unpriced 1001 tokens \(unknown-model 1001\)/,
        'FP7 text: the fully-unpriced row\'s cost cell matches exactly') or diag($out2);
};

# ===========================================================================
# FP8 (DC2 2f) -- TOTAL line, exact text, across FP7's two rows.
# ===========================================================================
subtest 'FP8: the TOTAL line is exactly the spec text for FP7\'s session' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $stubdir = tempdir(CLEANUP => 1);
    my $stub = write_stub($stubdir);
    my $counter = File::Spec->catfile($stubdir, 'counter.txt');
    my ($main) = session_paths($dir, 'sess-fp8');
    write_jsonl($main,
        assistant_rec(request_id => 'A', model => 'claude-sonnet-5', input => 1_000_000, output => 0),
        assistant_rec(request_id => 'B', model => 'claude-sonnet-5', cache_creation => 500, input => 0, output => 0),
        assistant_rec(request_id => 'C', model => 'claude-sonnet-5', speed => 'fast', output => 300, input => 0),
        assistant_rec(request_id => 'D', model => 'claude-nonexistent-model', input => 1000, output => 1),
    );
    my ($rc, $out) = run_seam('ok', $stub, $counter, 'report-session', '--session', $main, '--by', 'role,model');
    is($rc, 0, 'FP8: exits 0') or diag($out);
    like($out,
        qr{^TOTAL: 1001801 tokens, input=1001000 cache_write_5m=0 cache_write_1h=0 cache_write_unsplit=500 cache_read=0 output=301, api_equivalent_cost=\$2\.000000 \+ unpriced 1801 tokens \(cache-write-unsplit 500, non-standard-speed 300, unknown-model 1001\)$}m,
        'FP8: the TOTAL line matches exactly') or diag($out);
};

# ===========================================================================
# FP9 (DC2 2g) -- header names source and fetch time.
# ===========================================================================
subtest 'FP9: the text header names the source and fetch time; every dollar line says api_equivalent_cost=' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $stubdir = tempdir(CLEANUP => 1);
    my $stub = write_stub($stubdir);
    my $counter = File::Spec->catfile($stubdir, 'counter.txt');
    my ($main) = session_paths($dir, 'sess-fp9');
    write_jsonl($main, assistant_rec(request_id => 'req-fp9', model => 'claude-sonnet-5', input => 100, output => 1));

    my $t0 = time;
    my ($rc, $out) = run_seam('ok', $stub, $counter, 'report-session', '--session', $main);
    my $t1 = time;
    is($rc, 0, 'FP9: exits 0') or diag($out);
    my @lines = split(/\n/, $out);
    like($lines[0] // '', qr/API equivalent cost/, 'FP9: line 1 mentions "API equivalent cost"');
    my ($pline) = grep { /^pricing: ok, source/ } @lines;
    ok($pline, 'FP9: a "pricing: ok, source ..." line exists') or diag($out);
    if ($pline) {
        like($pline, qr{^pricing: ok, source (https://platform\.claude\.com/docs/en/about-claude/pricing(?:\.md)?), fetched-at (\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ), fetched via override command$},
            'FP9: pricing line matches the exact grammar, including the override-command suffix (Decision 24 S4, since run_seam always sets CCPRAXIS_SPEND_FETCH_CMD)') or diag($pline);
        my ($u, $iso) = ($pline =~ /source (\S+), fetched-at (\S+?)(?:, fetched via override command)?$/);
        if ($iso) {
            my ($y, $mo, $d, $h, $mi, $s) = ($iso =~ /^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)Z$/);
            # Time::Local::timegm takes a 0-based month; the ISO string's month is 1-based.
            my $epoch = eval { require Time::Local; Time::Local::timegm($s, $mi, $h, $d, $mo - 1, $y); };
            ok(!$@ && $epoch >= $t0 - 2 && $epoch <= $t1 + 2, 'FP9: fetched-at is within [start-2s, end+2s]') or diag("$iso vs [$t0,$t1] err=$@");
        }
        my @counter_lines = read_lines($counter);
        is($counter_lines[0] // '', $u // '<no-source>', 'FP9: the source matches the counter\'s logged argv');
    }
    my @dollar_missing = grep { /\$\d/ && !/api_equivalent_cost=/ } @lines;
    is_deeply(\@dollar_missing, [], 'FP9: every line with $<digit> also contains api_equivalent_cost=');
};

# ===========================================================================
# FP10 (DC2 2h) -- exact JSON key sets, ok and offline.
# ===========================================================================
subtest 'FP10: derive-session/report-session JSON key sets are exact; offline nulls every cost' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $stubdir = tempdir(CLEANUP => 1);
    my $stub = write_stub($stubdir);
    my $counter = File::Spec->catfile($stubdir, 'counter.txt');
    my ($main) = session_paths($dir, 'sess-fp10');
    write_jsonl($main, assistant_rec(request_id => 'req-fp10', model => 'claude-sonnet-5',
        input => 100, cache_creation => 50, cache_5m => 30, cache_1h => 20, cache_read => 400, output => 7));

    my ($rc, $out) = run_seam('ok', $stub, $counter, 'derive-session', '--session', $main, '--json');
    is($rc, 0, 'FP10 derive-session ok: exits 0') or diag($out);
    my $doc = eval { JSON::PP->new->decode($out) };
    ok($doc, 'FP10 derive-session ok: parses') or diag($out);
  SKIP: {
        skip 'FP10 derive-session ok: unavailable', 6 unless $doc;
        is_deeply([ sort keys %$doc ],
            [ sort qw(cost_basis price_source price_fetched_at pricing_status cells totals unpriced anomaly record_counts agents price_fetch_override) ],
            'FP10: derive-session top-level key set is exact, including price_fetch_override (Decision 24 S4, fetched via the seam)');
        is($doc->{cost_basis}, 'fetched', 'FP10: cost_basis is "fetched"');
        is($doc->{pricing_status}, 'ok', 'FP10: pricing_status ok');
        my ($u) = read_lines($counter);
        is($doc->{price_source}, $u, 'FP10: price_source equals the fetched URL');
        like($doc->{price_fetched_at}, qr/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/, 'FP10: price_fetched_at is ISO');
        ok($doc->{price_fetch_override}, 'FP10: price_fetch_override is true when fetched via CCPRAXIS_SPEND_FETCH_CMD (Decision 24 S4)');
        for my $c (@{ $doc->{cells} }) {
            is_deeply([ sort keys %$c ],
                [ sort qw(role model effort token_type tokens api_equivalent_cost_usd unpriced_tokens unpriced_reasons) ],
                'FP10: a cell has exactly the 8 keys of spec §3.1') or diag($JSON->encode($c));
            last;
        }
        for my $t (values %{ $doc->{totals} }) {
            is_deeply([ sort keys %$t ],
                [ sort qw(tokens api_equivalent_cost_usd unpriced_tokens unpriced_reasons) ],
                'FP10: a totals.<type> entry has exactly 4 keys') or diag($JSON->encode($t));
            last;
        }
        is_deeply([ sort keys %{ $doc->{unpriced} } ],
            [ sort qw(unknown-model cache-write-unsplit non-standard-speed rate-missing offline pricing-unavailable fast-long-context-unspecified) ],
            'FP10: unpriced has exactly the 7 keys of Decision 24 M1, zeros kept');
    }

    my ($rc2, $out2) = run_seam('ok', $stub, $counter, 'report-session', '--session', $main, '--by', 'token_type', '--json');
    is($rc2, 0, 'FP10 report-session ok: exits 0') or diag($out2);
    my $doc2 = eval { JSON::PP->new->decode($out2) };
    ok($doc2, 'FP10 report-session ok: parses') or diag($out2);
  SKIP: {
        skip 'FP10 report-session ok: unavailable', 3 unless $doc2;
        is_deeply([ sort keys %$doc2 ],
            [ sort qw(cost_basis price_source price_fetched_at pricing_status by data_root data_root_source rows totals attribution price_fetch_override) ],
            'FP10: report-session top-level key set is exact, including price_fetch_override (Decision 24 S4)');
        ok($doc2->{price_fetch_override}, 'FP10: report-session price_fetch_override is true when fetched via the seam');
        for my $r (@{ $doc2->{rows} }) {
            is_deeply([ sort keys %$r ],
                [ sort qw(token_type tokens api_equivalent_cost_usd unpriced_tokens unpriced_reasons) ],
                'FP10: with token_type in --by, a row has exactly those 5 keys, no *_tokens keys') or diag($JSON->encode($r));
            last;
        }
    }

    # Offline (this file's default NO_FETCH=1): every cost is null.
    my ($rc3, $out3) = run_spend('derive-session', '--session', $main, '--json');
    is($rc3, 0, 'FP10 offline: exits 0') or diag($out3);
    my $doc3 = eval { JSON::PP->new->decode($out3) };
    ok($doc3, 'FP10 offline: parses') or diag($out3);
  SKIP: {
        skip 'FP10 offline: unavailable', 4 unless $doc3;
        is($doc3->{pricing_status}, 'offline', 'FP10 offline: pricing_status offline');
        ok(!defined($doc3->{price_source}), 'FP10 offline: price_source null');
        ok(!defined($doc3->{price_fetched_at}), 'FP10 offline: price_fetched_at null');
        my $any_priced = grep { defined($_->{api_equivalent_cost_usd}) } @{ $doc3->{cells} };
        is($any_priced, 0, 'FP10 offline: every cell\'s api_equivalent_cost_usd is null');

        my ($lib_doc, $lib_err) = call_derive_session(session => $main);
        ok(!$lib_err, 'FP10: library derive_session(no pricing) does not die') or diag($lib_err);
        is_deeply($lib_doc, $doc3, 'FP10: library derive_session(no pricing) == CLI --json under NO_FETCH=1') if $lib_doc;
    }
};

# ===========================================================================
# FP11 (DC2 2i, Decision 16) -- acquisition precedence.
# ===========================================================================
subtest 'FP11: PRICING_FILE wins over offline/NO_FETCH, which win over the live fetch' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $stubdir = tempdir(CLEANUP => 1);
    my $stub = write_stub($stubdir);
    my $counter = File::Spec->catfile($stubdir, 'counter.txt');
    my ($main) = session_paths($dir, 'sess-fp11');
    write_jsonl($main, assistant_rec(request_id => 'req-fp11', model => 'claude-sonnet-5', input => 1, output => 1));
    my $mdfile = File::Spec->catfile(tempdir(CLEANUP => 1), 'F-MD.md');
    write_text_file($mdfile, $F_MD);

    # (a) PRICING_FILE + NO_FETCH=1 + seam set -> file wins.
    {
        local $ENV{CCPRAXIS_SPEND_PRICING_FILE} = $mdfile;
        local $ENV{CCPRAXIS_SPEND_FETCH_CMD}     = $stub;
        local $ENV{SPEND_STUB_MODE}               = 'ok';
        local $ENV{SPEND_STUB_COUNTER}             = $counter;
        local $ENV{CCPRAXIS_SPEND_NO_FETCH}         = 1;
        my ($rc, $out) = run_spend('derive-session', '--session', $main, '--json');
        is($rc, 0, 'FP11a: exits 0') or diag($out);
        my $doc = eval { JSON::PP->new->decode($out) };
        if ($doc) {
            is($doc->{pricing_status}, 'ok', 'FP11a: PRICING_FILE wins -> pricing_status ok');
            is($doc->{price_source}, "file:$mdfile", 'FP11a: price_source is file:<path>');
        }
        ok(!-e $counter, 'FP11a: the seam is never called');
    }

    # (b) NO_FETCH=1 + seam set, no file -> offline.
    {
        local $ENV{CCPRAXIS_SPEND_FETCH_CMD} = $stub;
        local $ENV{SPEND_STUB_MODE}           = 'ok';
        local $ENV{SPEND_STUB_COUNTER}         = $counter;
        local $ENV{CCPRAXIS_SPEND_NO_FETCH}     = 1;
        my ($rc, $out) = run_spend('derive-session', '--session', $main, '--json');
        my $doc = eval { JSON::PP->new->decode($out) };
        is(($doc // {})->{pricing_status}, 'offline', 'FP11b: NO_FETCH wins over the seam -> offline') or diag($out);
        ok(!-e $counter, 'FP11b: the seam is never called');
    }

    # (c) --offline + NO_FETCH deleted + seam set -> offline.
    {
        local $ENV{CCPRAXIS_SPEND_FETCH_CMD} = $stub;
        local $ENV{SPEND_STUB_MODE}           = 'ok';
        local $ENV{SPEND_STUB_COUNTER}         = $counter;
        delete local $ENV{CCPRAXIS_SPEND_NO_FETCH};
        my ($rc, $out) = run_spend('derive-session', '--session', $main, '--offline', '--json');
        my $doc = eval { JSON::PP->new->decode($out) };
        is(($doc // {})->{pricing_status}, 'offline', 'FP11c: --offline -> offline') or diag($out);
        ok(!-e $counter, 'FP11c: the seam is never called');
    }

    # (d) only the seam set -> a real fetch, counter has 1 line.
    {
        my ($rc, $out) = run_seam('ok', $stub, $counter, 'derive-session', '--session', $main, '--json');
        my $doc = eval { JSON::PP->new->decode($out) };
        is(($doc // {})->{pricing_status}, 'ok', 'FP11d: only the seam set -> ok') or diag($out);
        my @lines = read_lines($counter);
        is(scalar(@lines), 1, 'FP11d: the counter has exactly one line');
    }

    # (e) PRICING_FILE pointing at a nonexistent path -> unavailable. This
    # reuses (d)'s $counter, which (d) already left with one line, so the
    # right check is "unchanged by this run", not "absent" (that would
    # already be false because of (d), regardless of what (e) does).
    {
        my $ghost = File::Spec->catfile(tempdir(CLEANUP => 1), 'no-such-file.md');
        local $ENV{CCPRAXIS_SPEND_PRICING_FILE} = $ghost;
        delete local $ENV{CCPRAXIS_SPEND_NO_FETCH};
        my @before = read_lines($counter);
        my ($rc, $out) = run_spend('derive-session', '--session', $main, '--json');
        my $doc = eval { JSON::PP->new->decode($out) };
        like(($doc // {})->{pricing_status} // '', qr/^unavailable: pricing file unreadable: /, 'FP11e: unreadable file -> unavailable') or diag($out);
        my @after = read_lines($counter);
        is_deeply(\@after, \@before, 'FP11e: the seam is never called (counter unchanged by this run)');
    }
};

# ===========================================================================
# FP12 (DC2 2a/2d) -- parser failure modes, in-process, on BpPricing directly.
# ===========================================================================
subtest 'FP12: parse_document failure modes and the exact F-MD rate table' => sub {
    my $p_no_lc = eval { BpPricing::parse_document($F_NO_LC, source => 'file:F-NO-LC', fetched_at => '2026-09-26T00:00:00Z') };
    ok(!$@, 'FP12: parse_document(F-NO-LC) does not die') or diag($@);
  SKIP: {
        skip 'FP12 no-lc: unavailable', 2 unless $p_no_lc;
        is($p_no_lc->{status}, 'ok', 'FP12 no-lc: status ok') or diag($JSON->encode($p_no_lc));
        ok(!defined($p_no_lc->{long_context}{threshold_tokens}), 'FP12 no-lc: threshold_tokens is undef when there is no LC section');
    }

    my $p_no_threshold = eval { BpPricing::parse_document($F_LC_NO_THRESHOLD, source => 'file:x', fetched_at => '2026-09-26T00:00:00Z') };
    ok(!$@, 'FP12: parse_document(F-LC-NO-THRESHOLD) does not die') or diag($@);
    is(($p_no_threshold // {})->{status}, 'unavailable', 'FP12 no-threshold: status unavailable');
    is(($p_no_threshold // {})->{reason}, 'long-context threshold not found', 'FP12 no-threshold: exact reason') if $p_no_threshold;

    my $p_dup = eval { BpPricing::parse_document($F_MD_DUP_STANDARD, source => 'file:x', fetched_at => '2026-09-26T00:00:00Z') };
    ok(!$@, 'FP12: parse_document(dup standard table) does not die') or diag($@);
    is(($p_dup // {})->{status}, 'unavailable', 'FP12 dup: status unavailable');
    is(($p_dup // {})->{reason}, 'more than one standard price table', 'FP12 dup: exact reason') if $p_dup;

    my $p_tbd = eval { BpPricing::parse_document($F_MD_ALL_TBD, source => 'file:x', fetched_at => '2026-09-26T00:00:00Z') };
    ok(!$@, 'FP12: parse_document(all-TBD) does not die') or diag($@);
    is(($p_tbd // {})->{status}, 'unavailable', 'FP12 all-tbd: status unavailable');
    is(($p_tbd // {})->{reason}, 'no model has a complete rate row', 'FP12 all-tbd: exact reason') if $p_tbd;

    my $p_unresolved = eval { BpPricing::parse_document($F_LC_UNRESOLVED, source => 'file:x', fetched_at => '2026-09-26T00:00:00Z') };
    ok(!$@, 'FP12: parse_document(F-LC-UNRESOLVED) does not die') or diag($@);
  SKIP: {
        skip 'FP12 unresolved: unavailable', 2 unless $p_unresolved;
        is($p_unresolved->{status}, 'ok', 'FP12 unresolved: status ok') or diag($JSON->encode($p_unresolved));
        is($p_unresolved->{long_context}{unresolved}, 1, 'FP12 unresolved: unresolved == 1');
    }

    my $p_md = eval { BpPricing::parse_document($F_MD, source => 'file:F-MD', fetched_at => '2026-09-26T00:00:00Z') };
    ok(!$@, 'FP12: parse_document(F-MD) does not die') or diag($@);
  SKIP: {
        skip 'FP12 F-MD: unavailable', 4 unless $p_md;
        my %want = (
            'claude-opus-5-5'  => { input => 4,  output => 20, cache_write_5m => 5,     cache_write_1h => 8,  cache_read => 0.20 },
            'claude-sonnet-5'  => { input => 2,  output => 10, cache_write_5m => 2.50,  cache_write_1h => 4,  cache_read => 0.20 },
            'claude-fable-5-1' => { input => 10, output => 50, cache_write_5m => 12.50, cache_write_1h => 20, cache_read => 0.25 },
            'claude-haiku-4-5' => { input => 1,  output => 5,  cache_write_5m => 1.25,  cache_write_1h => 2,  cache_read => 0.10 },
            'claude-opus-5'    => { input => 5,  output => 25, cache_write_5m => 6.25,  cache_write_1h => 10, cache_read => 0.50 },
        );
        my @bad;
        for my $id (sort keys %want) {
            my $got = $p_md->{models}{$id};
            unless ($got) { push @bad, "$id: missing"; next; }
            for my $k (qw(input output cache_write_5m cache_write_1h cache_read)) {
                push @bad, "$id.$k" unless defined($got->{$k}) && $got->{$k} == $want{$id}{$k};
            }
        }
        my $t9 = $p_md->{models}{'claude-test-9'};
        ok($t9 && $t9->{input} == 3 && !defined($t9->{cache_write_1h}), "FP12 F-MD: claude-test-9 input==3, cache_write_1h undef")
            or diag($JSON->encode($t9 // {}));
        is_deeply(\@bad, [], 'FP12 F-MD: every listed id has the exact rates') or diag(join(', ', @bad));
        is($p_md->{long_context}{threshold_tokens}, 200000, 'FP12 F-MD: threshold_tokens == 200000');
        is_deeply([ sort keys %{ $p_md->{fast}{models} } ], [ 'claude-opus-5-5' ], 'FP12 F-MD: fast.models has only claude-opus-5-5');
    }
};

# ===========================================================================
# FP13 (DC5) -- library load and one derive_session call never fetch.
# ===========================================================================
subtest 'FP13: requiring bp-spend.pl and calling derive_session never invokes the fetch seam' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $stubdir = tempdir(CLEANUP => 1);
    my $stub = write_stub($stubdir);
    my $counter = File::Spec->catfile($stubdir, 'counter.txt');
    my ($main) = session_paths($dir, 'sess-fp13');
    write_jsonl($main, assistant_rec(request_id => 'req-fp13', model => 'claude-sonnet-5', input => 1, output => 1));

    local $ENV{CCPRAXIS_SPEND_FETCH_CMD} = $stub;
    local $ENV{SPEND_STUB_MODE}           = 'ok';
    local $ENV{SPEND_STUB_COUNTER}         = $counter;
    delete local $ENV{CCPRAXIS_SPEND_NO_FETCH};

    my $reloaded = do { local $@; eval { require $SPEND_PL }; !$@ };
    ok($reloaded, 'FP13: bp-spend.pl requires cleanly with the seam armed and NO_FETCH unset');
    my ($doc, $err) = call_derive_session(session => $main);
    ok(!$err, 'FP13: derive_session(no pricing arg) does not die') or diag($err);
    ok(!-e $counter, 'FP13: the fetch seam was never invoked by requiring the library or calling derive_session');
};

# ===========================================================================
# FP14 (DC5) -- HTTP::Tiny never loaded.
# ===========================================================================
subtest 'FP14: HTTP::Tiny never enters %INC, and neither source file mentions it' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $stubdir = tempdir(CLEANUP => 1);
    my $stub = write_stub($stubdir);
    my $counter = File::Spec->catfile($stubdir, 'counter.txt');
    my ($main) = session_paths($dir, 'sess-fp14');
    write_jsonl($main, assistant_rec(request_id => 'req-fp14', model => 'claude-sonnet-5', input => 1, output => 1));

    local $ENV{CCPRAXIS_SPEND_FETCH_CMD} = $stub;
    local $ENV{SPEND_STUB_MODE}           = 'ok';
    local $ENV{SPEND_STUB_COUNTER}         = $counter;
    delete local $ENV{CCPRAXIS_SPEND_NO_FETCH};

    my $p = eval { BpPricing::acquire() };
    ok(!$@, 'FP14: BpPricing::acquire() does not die') or diag($@);
    is(($p // {})->{status}, 'ok', 'FP14: acquire() with the seam armed gives status ok') if $p;
    ok(!exists $INC{'HTTP/Tiny.pm'}, 'FP14: HTTP::Tiny is not in %INC');

    my $bp_spend_src = slurp_raw($SPEND_PL) // '';
    my $pricing_pm   = "$Bin/../../scripts/BpPricing.pm";
    my $pricing_src  = -f $pricing_pm ? (slurp_raw($pricing_pm) // '') : '';
    unlike($bp_spend_src, qr/^\s*(?:use|require)\s+HTTP::Tiny\b/m, 'FP14: bp-spend.pl source never mentions HTTP::Tiny');
    unlike($pricing_src, qr/^\s*(?:use|require)\s+HTTP::Tiny\b/m, 'FP14: BpPricing.pm source never mentions HTTP::Tiny')
        if length $pricing_src;
};

# ===========================================================================
# FP15 (DC5) -- scripts/run-tests.pl exports the guard.
# ===========================================================================
subtest 'FP15: scripts/run-tests.pl sets CCPRAXIS_SPEND_NO_FETCH=1' => sub {
    my $runner_src = slurp_raw("$Bin/../../../../scripts/run-tests.pl");
    ok(defined $runner_src, 'FP15: scripts/run-tests.pl is readable') or return;
    like($runner_src, qr/\$ENV\{CCPRAXIS_SPEND_NO_FETCH\}\s*=\s*1\s*;/, 'FP15: run-tests.pl exports CCPRAXIS_SPEND_NO_FETCH=1');
};

# ===========================================================================
# FP16 (DC5) -- every package test_paths file that reaches a session verb
# guards itself with CCPRAXIS_SPEND_NO_FETCH=1.
# ===========================================================================
subtest 'FP16: every test_paths file reaching report-session/derive-session sets the NO_FETCH guard itself' => sub {
    my @files = qw(
        spend-token-columns.t spend-fresh-pricing.t spend-session-dispatch-hook.t
        spend-session-attribution.t spend-drive-solo-session.t spend-derived-from-transcripts.t
        spend-package-request-dedup.t spend-session-fast-reader.t spend-global-and-claude.t
    );
    for my $f (@files) {
        my $path = File::Spec->catfile($Bin, $f);
        my $src = slurp_raw($path);
        ok(defined $src, "FP16: $f is readable") or next;
        if ($src =~ /report-session|derive-session|report_session|derive_session/) {
            like($src, qr/\$ENV\{CCPRAXIS_SPEND_NO_FETCH\}\s*=\s*1/, "FP16: $f reaches a session verb and sets the guard");
        } else {
            pass("FP16: $f does not reach report-session/derive-session; no guard required");
        }
    }
};

# ===========================================================================
# FP17 (Decision 23) -- the current live-page shape: a long-context section
# that states only standard pricing (no threshold, no table); footnoted
# rate cells; a fast-mode row naming two models.
# ===========================================================================
subtest 'FP17: current live-page shape -- standard-pricing long context, footnoted cells, multi-model fast row (Decision 23)' => sub {
    my $p = eval { BpPricing::parse_document($F_LIVE_SHAPE, source => 'file:F-LIVE-SHAPE', fetched_at => '2026-09-26T00:00:00Z') };
    ok(!$@, 'FP17: parse_document(F-LIVE-SHAPE) does not die') or diag($@);
  SKIP: {
        skip 'FP17: doc unavailable', 10 unless $p;
        is($p->{status}, 'ok',
            'FP17: a long-context section stating only standard pricing, with no threshold and no table, parses ok (Decision 23)')
            or diag($JSON->encode($p));
        ok(!defined($p->{long_context}{threshold_tokens}), 'FP17: threshold_tokens is undef -- the page states no threshold');
        is($p->{long_context}{unresolved}, 0,
            'FP17: unresolved is 0 -- the page stated the rate (standard), it did not fail to state one');
        is_deeply($p->{long_context}{models}, {}, 'FP17: long_context.models is empty -- there is no long-context tier at all');

        my $sonnet = $p->{models}{'claude-sonnet-5'};
        ok($sonnet, 'FP17: claude-sonnet-5 is in the standard table');
        if ($sonnet) {
            is($sonnet->{input}, 2,
                'FP17: the footnoted input cell ($2 / MTok<sup>1</sup>) parses to 2, not a stray-digit value') or diag($JSON->encode($sonnet));
            is($sonnet->{output}, 10,
                'FP17: the footnoted output cell ($10 / MTok<sup>1</sup>) parses to 10, not a stray-digit value') or diag($JSON->encode($sonnet));
            is($sonnet->{cache_write_1h}, 4, 'FP17: an un-footnoted cell in the same row is unaffected');
        }

        my $fast_opus   = $p->{fast}{models}{'claude-opus-5'};
        my $fast_sonnet = $p->{fast}{models}{'claude-sonnet-5'};
        ok($fast_opus,   'FP17: the fast row "Claude Opus 5 / Claude Sonnet 5" maps claude-opus-5');
        ok($fast_sonnet, 'FP17: the fast row "Claude Opus 5 / Claude Sonnet 5" also maps claude-sonnet-5');
        if ($fast_opus && $fast_sonnet) {
            is($fast_opus->{input},   24,  'FP17: claude-opus-5 fast input is 24');
            is($fast_opus->{output},  120, 'FP17: claude-opus-5 fast output is 120');
            is($fast_sonnet->{input}, 24,  'FP17: claude-sonnet-5 fast input is 24');
            is($fast_sonnet->{output},120, 'FP17: claude-sonnet-5 fast output is 120');
        }
    }

    # End-to-end: a request whose input is far larger than the old 200K
    # threshold still prices at standard rates, because this page states no
    # long-context tier at all (Decision 23), and the header notes it.
    my $dir = tempdir(CLEANUP => 1);
    my ($main) = session_paths($dir, 'sess-fp17');
    write_jsonl($main, assistant_rec(request_id => 'req-fp17', model => 'claude-sonnet-5',
        input => 5_000_000, output => 1_000_000));

    my $livefile = File::Spec->catfile(tempdir(CLEANUP => 1), 'F-LIVE-SHAPE.md');
    write_text_file($livefile, $F_LIVE_SHAPE);
    local $ENV{CCPRAXIS_SPEND_PRICING_FILE} = $livefile;
    delete local $ENV{CCPRAXIS_SPEND_NO_FETCH};

    my ($rc, $out) = run_spend('report-session', '--session', $main, '--json');
    is($rc, 0, 'FP17: exits 0') or diag($out);
    my $doc = eval { JSON::PP->new->decode($out) };
    ok($doc, 'FP17: stdout parses') or diag($out);
  SKIP: {
        skip 'FP17: doc unavailable', 2 unless $doc;
        my ($row) = @{ $doc->{rows} // [] };
        ok($row, 'FP17: exactly one row');
        if ($row) {
            ok(abs($row->{api_equivalent_cost_usd} - 20) < 1e-9,
                'FP17: a 5M-input request still prices at standard rates (5*2 + 1*10 = 20), never long-context or rate-missing')
                or diag($JSON->encode($row));
            is($row->{unpriced_tokens}, 0, 'FP17: nothing is unpriced');
        }
    }

    my ($rc2, $out2) = run_spend('report-session', '--session', $main);
    is($rc2, 0, 'FP17 text: exits 0') or diag($out2);
    like($out2,
        qr/^pricing: ok, source \S+, fetched-at \d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ, long-context: standard pricing per source$/m,
        'FP17: the header notes long-context: standard pricing per source (Decision 23)') or diag($out2);
};

# ===========================================================================
# FP18 (Decision 24 M1) -- fast mode strictly over the long-context
# threshold is unpriced fast-long-context-unspecified, never priced flat at
# the fast rate; at or under the threshold, fast pricing still applies.
# ===========================================================================
subtest 'FP18: M1 -- fast mode strictly over the long-context threshold is unpriced fast-long-context-unspecified' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my ($main) = session_paths($dir, 'sess-fp18');
    write_jsonl($main,
        assistant_rec(request_id => 'r-over', model => 'claude-opus-5-5', effort => 'e-over-fast',
            speed => 'fast', input => 250_000, output => 10_000),
        assistant_rec(request_id => 'r-boundary', model => 'claude-opus-5-5', effort => 'e-boundary-fast',
            speed => 'fast', input => 200_000, output => 1_000),
    );
    my $mdfile = File::Spec->catfile(tempdir(CLEANUP => 1), 'F-MD.md');
    write_text_file($mdfile, $F_MD);
    local $ENV{CCPRAXIS_SPEND_PRICING_FILE} = $mdfile;

    my ($rc, $out) = run_spend('report-session', '--session', $main, '--by', 'effort', '--json');
    is($rc, 0, 'FP18: exits 0') or diag($out);
    my $doc = eval { JSON::PP->new->decode($out) };
    ok($doc, 'FP18: stdout parses') or diag($out);
  SKIP: {
        skip 'FP18: doc unavailable', 4 unless $doc;
        my %by_effort = map { $_->{effort} => $_ } @{ $doc->{rows} // [] };
        my $over = $by_effort{'e-over-fast'};
        ok($over, 'FP18: the over-threshold fast row exists');
        if ($over) {
            ok(!defined($over->{api_equivalent_cost_usd}),
                'FP18: fast + strictly-over-threshold is never priced flat at the fast rate -- api_equivalent_cost_usd is null')
                or diag($JSON->encode($over));
            is($over->{unpriced_tokens}, 260_000, 'FP18: unpriced_tokens == 250,000 + 10,000');
            is_deeply($over->{unpriced_reasons}, [ { reason => 'fast-long-context-unspecified', tokens => 260_000 } ],
                'FP18: unpriced_reasons is exactly fast-long-context-unspecified for the whole request (Decision 22/24 M1)')
                or diag($JSON->encode($over));
        }
        my $boundary = $by_effort{'e-boundary-fast'};
        ok($boundary, 'FP18: the boundary (==200K, not strictly over) fast row exists');
        if ($boundary) {
            ok(abs(($boundary->{api_equivalent_cost_usd} // -1) - 4.92) < 1e-9,
                'FP18: at the threshold (not strictly over), fast pricing still applies: 200000*24e-6 + 1000*120e-6 = 4.92')
                or diag($JSON->encode($boundary));
            is($boundary->{unpriced_tokens}, 0, 'FP18: the boundary row has nothing unpriced');
        }
    }
};

# ===========================================================================
# FP19 (Decision 24 M2) -- two fast-mode rows for one model with different
# rates give rate-missing for that model, never last-row-wins.
# ===========================================================================
subtest 'FP19: M2 -- conflicting fast-mode rows for one model mark it rate-missing, never last-row-wins' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my ($main) = session_paths($dir, 'sess-fp19');
    write_jsonl($main, assistant_rec(request_id => 'req-fp19', model => 'claude-opus-5-5',
        speed => 'fast', input => 1000, output => 1000));
    my $mdfile = File::Spec->catfile(tempdir(CLEANUP => 1), 'F-MD-FAST-CONFLICT.md');
    write_text_file($mdfile, $F_MD_FAST_CONFLICT);
    local $ENV{CCPRAXIS_SPEND_PRICING_FILE} = $mdfile;

    my ($rc, $out) = run_spend('report-session', '--session', $main, '--json');
    is($rc, 0, 'FP19: exits 0') or diag($out);
    my $doc = eval { JSON::PP->new->decode($out) };
    ok($doc, 'FP19: stdout parses') or diag($out);
  SKIP: {
        skip 'FP19: doc unavailable', 3 unless $doc;
        is($doc->{pricing_status}, 'ok', 'FP19: the document as a whole still parses ok -- one model\'s conflict does not fail the fetch');
        my ($row) = @{ $doc->{rows} // [] };
        ok($row, 'FP19: exactly one row');
        if ($row) {
            ok(!defined($row->{api_equivalent_cost_usd}),
                'FP19: never guesses either conflicting rate ($24/$120 nor $99/$999) -- api_equivalent_cost_usd is null')
                or diag($JSON->encode($row));
            is_deeply($row->{unpriced_reasons}, [ { reason => 'rate-missing', tokens => 2000 } ],
                'FP19: unpriced_reasons is exactly rate-missing for the whole request') or diag($JSON->encode($row));
        }
    }
};

# ===========================================================================
# FP20 (Decision 24 M3) -- a long-context section stating a premium in
# prose, with no parseable table, is NOT standard pricing.
# ===========================================================================
subtest 'FP20: M3 -- a stated long-context premium with no parseable table is never silently standard-priced' => sub {
    my $p = eval { BpPricing::parse_document($F_LC_PROSE_PREMIUM, source => 'file:x', fetched_at => '2026-09-26T00:00:00Z') };
    ok(!$@, 'FP20: parse_document(F-LC-PROSE-PREMIUM) does not die') or diag($@);
    ok($p, 'FP20: parse_document returns a defined result') or diag($@);
  SKIP: {
        skip 'FP20: no result to inspect', 1 unless $p;
        my $doc_unavailable = ($p->{status} eq 'unavailable');
        my $lc_unresolved   = ($p->{status} eq 'ok' && $p->{long_context} && $p->{long_context}{unresolved});
        ok($doc_unavailable || $lc_unresolved,
            'FP20: a stated premium the parser cannot turn into a rule is unavailable or long-context rate-missing, never silently standard (Decision 24 M3)')
            or diag($JSON->encode($p));
    }

    # End-to-end: a request whose input is far over the old 200K threshold
    # must never be priced at the plain standard rate on this page (the
    # reviewer's exact probe: a 500K-input request silently priced at
    # standard $4/$20 while the page states an $8/$30 premium in prose).
    my $dir = tempdir(CLEANUP => 1);
    my ($main) = session_paths($dir, 'sess-fp20');
    write_jsonl($main, assistant_rec(request_id => 'req-fp20', model => 'claude-sonnet-5',
        input => 500_000, output => 0));
    my $mdfile = File::Spec->catfile(tempdir(CLEANUP => 1), 'F-LC-PROSE-PREMIUM.md');
    write_text_file($mdfile, $F_LC_PROSE_PREMIUM);
    local $ENV{CCPRAXIS_SPEND_PRICING_FILE} = $mdfile;

    my ($rc, $out) = run_spend('report-session', '--session', $main, '--json');
    is($rc, 0, 'FP20: exits 0') or diag($out);
    my $doc = eval { JSON::PP->new->decode($out) };
    ok($doc, 'FP20: stdout parses') or diag($out);
  SKIP: {
        skip 'FP20: doc unavailable', 2 unless $doc;
        my ($row) = @{ $doc->{rows} // [] };
        ok($row, 'FP20: exactly one row');
        if ($row) {
            ok(!defined($row->{api_equivalent_cost_usd}),
                'FP20: a 500K-input request is never priced at the plain standard rate ($1.00) on a page stating an unparsed premium')
                or diag($JSON->encode($row));
        }
    }
};

# ===========================================================================
# FP21 (Decision 24 S2) -- a fenced code block containing a "# ..." line is
# not read as a heading.
# ===========================================================================
subtest 'FP21: S2 -- a fenced "# ..." comment line is never read as a heading' => sub {
    my $p = eval { BpPricing::parse_document($F_MD_CODEFENCE, source => 'file:x', fetched_at => '2026-09-26T00:00:00Z') };
    ok(!$@, 'FP21: parse_document(F-MD-CODEFENCE) does not die') or diag($@);
  SKIP: {
        skip 'FP21: doc unavailable', 4 unless $p;
        is($p->{status}, 'ok', 'FP21: status ok -- the fenced comment does not break the document') or diag($JSON->encode($p));
        is_deeply([ sort keys %{ $p->{fast}{models} } ], [ 'claude-opus-5-5' ],
            'FP21: fast.models still has only claude-opus-5-5 -- the batch table was never absorbed into it (reviewer\'s exact probe)')
            or diag($JSON->encode($p->{fast}));
        my $fo = $p->{fast}{models}{'claude-opus-5-5'};
        ok($fo && $fo->{input} == 24 && $fo->{output} == 120,
            'FP21: claude-opus-5-5 keeps its real fast rate 24/120, not the batch rate 2/10') or diag($JSON->encode($fo // {}));
        ok(!exists($p->{fast}{models}{'claude-sonnet-5'}),
            'FP21: claude-sonnet-5 never appears in fast.models -- its batch rate never became a fast rate');
    }
};

# ===========================================================================
# FP22 (Decision 24 S4) -- CCPRAXIS_SPEND_FETCH_CMD marks both the text
# header and the JSON with an override marker; neither appears without it.
# ===========================================================================
subtest 'FP22: S4 -- the override command is visible in the header and JSON, and only then' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $stubdir = tempdir(CLEANUP => 1);
    my $stub = write_stub($stubdir);
    my $counter = File::Spec->catfile($stubdir, 'counter.txt');
    my ($main) = session_paths($dir, 'sess-fp22');
    write_jsonl($main, assistant_rec(request_id => 'req-fp22', model => 'claude-sonnet-5', input => 100, output => 1));

    my ($rc, $out) = run_seam('ok', $stub, $counter, 'report-session', '--session', $main);
    is($rc, 0, 'FP22 seam text: exits 0') or diag($out);
    like($out, qr/fetched via override command/, 'FP22 seam text: the header says fetched via override command');

    my ($rc2, $out2) = run_seam('ok', $stub, $counter, 'report-session', '--session', $main, '--json');
    is($rc2, 0, 'FP22 seam json: exits 0') or diag($out2);
    my $doc2 = eval { JSON::PP->new->decode($out2) };
    ok($doc2, 'FP22 seam json: stdout parses') or diag($out2);
    ok($doc2 && $doc2->{price_fetch_override}, 'FP22 seam json: price_fetch_override is true') if $doc2;

    # Without the seam (PRICING_FILE instead): neither marker appears.
    my $mdfile = File::Spec->catfile(tempdir(CLEANUP => 1), 'F-MD.md');
    write_text_file($mdfile, $F_MD);
    local $ENV{CCPRAXIS_SPEND_PRICING_FILE} = $mdfile;
    my ($rc3, $out3) = run_spend('report-session', '--session', $main);
    is($rc3, 0, 'FP22 file text: exits 0') or diag($out3);
    unlike($out3, qr/fetched via override command/, 'FP22 file text: no override marker without CCPRAXIS_SPEND_FETCH_CMD');
    my ($rc4, $out4) = run_spend('report-session', '--session', $main, '--json');
    my $doc4 = eval { JSON::PP->new->decode($out4) };
    ok($doc4, 'FP22 file json: stdout parses') or diag($out4);
    ok($doc4 && !exists($doc4->{price_fetch_override}), 'FP22 file json: price_fetch_override key is absent without the override seam') if $doc4;

    # Offline: neither marker appears either.
    my ($rc5, $out5) = run_spend('report-session', '--session', $main, '--offline');
    is($rc5, 0, 'FP22 offline text: exits 0') or diag($out5);
    unlike($out5, qr/fetched via override command/, 'FP22 offline text: no override marker when offline');
};

# ===========================================================================
# FP23 (Decision 24 S1) -- offline or unavailable totals show null, not 0,
# for token types with no tokens.
# ===========================================================================
subtest 'FP23: S1 -- offline/unavailable totals are null, not 0, for token types with no tokens' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my ($main) = session_paths($dir, 'sess-fp23');
    write_jsonl($main, assistant_rec(request_id => 'req-fp23', model => 'claude-sonnet-5', input => 100, output => 7));

    # Offline (this file's default CCPRAXIS_SPEND_NO_FETCH=1).
    my ($rc, $out) = run_spend('derive-session', '--session', $main, '--json');
    is($rc, 0, 'FP23 offline: exits 0') or diag($out);
    my $doc = eval { JSON::PP->new->decode($out) };
    ok($doc, 'FP23 offline: stdout parses') or diag($out);
  SKIP: {
        skip 'FP23 offline: doc unavailable', 4 unless $doc;
        for my $type (qw(cache_write_5m cache_write_1h cache_write_unsplit cache_read)) {
            my $t = $doc->{totals}{$type};
            ok($t, "FP23 offline: totals.$type exists");
            next unless $t;
            is($t->{tokens}, 0, "FP23 offline: totals.$type has zero tokens (nothing of this type occurred)");
            ok(!defined($t->{api_equivalent_cost_usd}),
                "FP23 offline: totals.$type.api_equivalent_cost_usd is null, not 0, while pricing_status is offline (Decision 24 S1)")
                or diag($JSON->encode($t));
        }
    }

    # Unavailable (a failed fetch via the seam).
    my $stubdir = tempdir(CLEANUP => 1);
    my $stub = write_stub($stubdir);
    my $counter = File::Spec->catfile($stubdir, 'counter.txt');
    my ($rc2, $out2) = run_seam('fail', $stub, $counter, 'derive-session', '--session', $main, '--json');
    is($rc2, 0, 'FP23 unavailable: exits 0') or diag($out2);
    my $doc2 = eval { JSON::PP->new->decode($out2) };
    ok($doc2, 'FP23 unavailable: stdout parses') or diag($out2);
  SKIP: {
        skip 'FP23 unavailable: doc unavailable', 4 unless $doc2;
        for my $type (qw(cache_write_5m cache_write_1h cache_write_unsplit cache_read)) {
            my $t = $doc2->{totals}{$type};
            ok($t, "FP23 unavailable: totals.$type exists");
            next unless $t;
            is($t->{tokens}, 0, "FP23 unavailable: totals.$type has zero tokens");
            ok(!defined($t->{api_equivalent_cost_usd}),
                "FP23 unavailable: totals.$type.api_equivalent_cost_usd is null, not 0, while pricing_status is unavailable (Decision 24 S1)")
                or diag($JSON->encode($t));
        }
    }
};

done_testing();
