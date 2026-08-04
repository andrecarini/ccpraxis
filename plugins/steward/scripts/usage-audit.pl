#!/usr/bin/env perl
# usage-audit.pl — Reproducible token-usage and provider-cost analysis for
# Claude Code, across every transcript on this machine.
#
# Scans host + per-project sandbox transcript roots, deduplicates by API
# request, classifies interactive vs headless-fleet spend, and prices the
# result against Anthropic list rates, Z.ai GLM credit plans, and DeepSeek
# pay-per-token. Emits a dated Markdown report into the vault.
#
# Two things make a naive scan undercount by ~7x, so both are handled here:
#   1. Sandbox sessions write to <project>/.ccpraxis-local-data/claude-home/
#      not ~/.claude, so per-project roots must be discovered.
#   2. Subagent transcripts nest at <project>/<session>/subagents/agent-*.jsonl
#      so the walk must recurse, not glob one level.
use strict;
use warnings;
use JSON::PP;
use File::Find;
use File::Path  qw(make_path);
use File::Basename qw(dirname);
use Cwd ();
use Time::Local qw(timegm);
use Getopt::Long;

binmode STDOUT, ':raw';
binmode STDERR, ':raw';

my $HOME = $ENV{HOME} // $ENV{USERPROFILE} // '.';
$HOME =~ s{\\}{/}g;

my (@scan_roots, @explicit_roots, $weeks, $out_path, $no_vault, $rates_path, $help, $list_roots);
GetOptions(
    'scan-root=s' => \@scan_roots,
    'root=s'      => \@explicit_roots,
    'weeks=i'     => \$weeks,
    'out=s'       => \$out_path,
    'no-vault'    => \$no_vault,
    'rates=s'     => \$rates_path,
    'list-roots'  => \$list_roots,
    'help|h'      => \$help,
) or die "bad options; try --help\n";

if ($help) {
    print <<'USAGE';
usage-audit.pl [options]

  --root DIR         Explicit transcript projects-root (repeatable). Skips discovery.
  --scan-root DIR    Extra directory to scan for sandbox homes (repeatable).
  --weeks N          Limit output to the last N complete weeks.
  --out PATH         Write the report here instead of the vault default.
  --no-vault         Print to stdout only; write no report file.
  --rates PATH       Override the rate-card JSON.
  --help             This text.

Default report path: ~/.claude/claude-code-vault/reports/usage/<ISO-date>.md
USAGE
    exit 0;
}

$rates_path //= dirname(do { (my $f = __FILE__) =~ s{\\}{/}g; Cwd::abs_path($f) // $f }) . '/usage-audit-rates.json';
my $RATES = do {
    open(my $fh, '<', $rates_path) or die "cannot read rate card $rates_path: $!\n";
    local $/;
    decode_json(scalar <$fh>);
};

# ---------------------------------------------------------------- discovery --

# Transcript roots come from three places, in order of reliability:
#   1. --root (explicit, skips everything else)
#   2. the host root, plus every vault-registered project
#   3. a bounded scan of each registry path's PARENT, which catches sibling
#      projects that were never registered for vault backup
sub discover_roots {
    return @explicit_roots if @explicit_roots;

    my %roots;
    my $host = "$HOME/.claude/projects";
    $roots{$host} = 1 if -d $host;

    my %scan;
    $scan{$_} = 1 for @scan_roots;
    $scan{$HOME} = 1;

    my $reg = "$HOME/.claude/claude-code-vault/.registry-local.json";
    if (open(my $fh, '<', $reg)) {
        binmode $fh, ':raw';
        local $/;
        my $raw = scalar <$fh>;
        close $fh;
        # utf8(0) keeps strings as raw UTF-8 BYTES rather than decoding them to
        # characters. Paths here contain non-ASCII ("André"); decoded characters
        # do not round-trip through Windows filesystem calls and produce a
        # mojibake duplicate of every root.
        my $j = eval { JSON::PP->new->utf8(0)->decode($raw) };
        if (ref($j) eq 'HASH' && ref($j->{projects}) eq 'HASH') {
            for my $slug (keys %{ $j->{projects} }) {
                my $p = $j->{projects}{$slug}{path} or next;
                $p =~ s{\\}{/}g;
                my $pr = "$p/.ccpraxis-local-data/claude-home/projects";
                $roots{$pr} = 1 if -d $pr;
                # Sibling projects under the same parent are often unregistered.
                my $parent = dirname($p);
                $scan{$parent} = 1 if $parent && $parent ne '/' && -d $parent;
            }
        }
    }

    # Bounded breadth-first walk with opendir, not File::Find and not glob:
    #   - File::Find over $HOME descends into AppData and never returns.
    #   - glob() skips dot-directories, so it misses ~/.claude/ccpraxis.
    #   - readdir returns names in the filesystem's own encoding, which is what
    #     -d needs on Windows; UTF-8 bytes from the registry JSON fail -d on a
    #     path containing non-ASCII (this host's home is "André").
    my $tail   = '.ccpraxis-local-data/claude-home/projects';
    my %skip   = map { $_ => 1 } qw(
        AppData .git node_modules .cache venv target build dist
        .ccpraxis-local-data .venv __pycache__ Windows
    );
    for my $sr (sort keys %scan) {
        next unless -d $sr;
        my @frontier = ([$sr, 0]);
        while (my $node = shift @frontier) {
            my ($dir, $depth) = @$node;
            $roots{"$dir/$tail"} = 1 if -d "$dir/$tail";
            next if $depth >= 3;
            opendir(my $dh, $dir) or next;
            my @kids = readdir($dh);
            closedir $dh;
            for my $k (@kids) {
                next if $k eq '.' || $k eq '..' || $skip{$k};
                my $p = "$dir/$k";
                push @frontier, [$p, $depth + 1] if -d $p && !-l $p;
            }
        }
    }
    return sort keys %roots;
}

my @ROOTS = discover_roots();
die "no transcript roots found; pass --root explicitly\n" unless @ROOTS;

if ($list_roots) { print "$_\n" for @ROOTS; exit 0 }

# ------------------------------------------------------------------- ingest --

my (%seen, %agg, @events);
my ($files, $records) = (0, 0);

my @paths;
for my $r (@ROOTS) {
    find(sub { push @paths, $File::Find::name if -f $_ && /\.jsonl$/ }, $r);
}

for my $path (@paths) {
    $files++;
    open(my $fh, '<', $path) or next;
    while (my $line = <$fh>) {
        next unless index($line, '"usage"') >= 0;
        my $j = eval { decode_json($line) } or next;
        my $m = $j->{message};
        next unless ref($m) eq 'HASH' && ref($m->{usage}) eq 'HASH';
        my $u = $m->{usage};

        # One usage record per API request. Resumed/copied transcripts repeat
        # records, and a backup-cache copy of a project duplicates whole files.
        my $key = $j->{requestId} // $m->{id} // $j->{uuid} // next;
        next if $seen{$key}++;
        $records++;

        my ($Y, $Mo, $D, $H, $Mi, $S) =
            ($j->{timestamp} // '') =~ /^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)/ or next;
        my $epoch = timegm($S, $Mi, $H, $D, $Mo - 1, $Y);
        my $dow   = (gmtime($epoch))[6];                 # 0 = Sunday
        my @mt    = gmtime($epoch - ((($dow + 6) % 7) * 86400));
        my $week  = sprintf('%04d-%02d-%02d', $mt[5] + 1900, $mt[4] + 1, $mt[3]);

        # entrypoint sdk-cli == spawned by an orchestrator/SDK (headless fleet);
        # cli == a real terminal session the user is sitting at.
        my $class = (($j->{entrypoint} // '') eq 'sdk-cli') ? 'HEADLESS' : 'INTERACTIVE';
        my $tier  = $path =~ m{/subagents/} ? 'sub' : 'main';

        my %t = (
            input    => $u->{input_tokens}                // 0,
            cwrite   => $u->{cache_creation_input_tokens} // 0,
            cread    => $u->{cache_read_input_tokens}     // 0,
            output   => $u->{output_tokens}               // 0,
            requests => 1,
        );

        my $peak = zai_is_peak($dow, $H);
        for my $f (keys %t) {
            $agg{$week}{$class}{$f}            += $t{$f};
            $agg{ALL}{$class}{$f}              += $t{$f};
            $agg{ALL}{"$class/$tier"}{$f}      += $t{$f};
            $agg{$week}{ $peak ? 'PEAK' : 'OFF' }{$f} += $t{$f};
            $agg{ALL}{ $peak ? 'PEAK' : 'OFF' }{$f}   += $t{$f};
        }
        push @events, { at => $epoch, peak => $peak, %t };
    }
    close $fh;
}
die "no usage records found under: @ROOTS\n" unless $records;

@events = sort { $a->{at} <=> $b->{at} } @events;

# ------------------------------------------------------------------ pricing --

sub zai_is_peak {
    my ($dow, $hour) = @_;
    my $z = $RATES->{zai};
    return 0 if $z->{peak_weekdays_only} && ($dow == 0 || $dow == 6);
    return scalar grep { $_ == $hour } @{ $z->{peak_utc_hours} };
}

sub tokens { my $t = shift // {};
    ($t->{input} // 0) + ($t->{cwrite} // 0) + ($t->{cread} // 0) + ($t->{output} // 0) }

sub anthropic_usd {
    my ($t, $model) = @_;
    $t //= {};
    my $r = $RATES->{anthropic}{models}{ $model // $RATES->{anthropic}{default_model} };
    return ( ($t->{input}  // 0) * $r->{input}
           + ($t->{cwrite} // 0) * $r->{cache_write}
           + ($t->{cread}  // 0) * $r->{cache_read}
           + ($t->{output} // 0) * $r->{output} ) / 1e6;
}

# Z.ai has no cache-write tier, so cache_creation is billed as full input.
sub zai_credits {
    my ($t, $model) = @_;
    $t //= {};
    my $r = $RATES->{zai}{models}{ $model // $RATES->{zai}{default_model} };
    return ( (($t->{input} // 0) + ($t->{cwrite} // 0)) * $r->{input}
           + ($t->{cread}  // 0) * $r->{cached}
           + ($t->{output} // 0) * $r->{output} ) / $RATES->{zai}{credit_divisor};
}

sub deepseek_usd {
    my ($t, $model) = @_;
    $t //= {};
    my $r = $RATES->{deepseek}{models}{ $model // $RATES->{deepseek}{default_model} };
    return ( (($t->{input} // 0) + ($t->{cwrite} // 0)) * $r->{cache_miss}
           + ($t->{cread}  // 0) * $r->{cache_hit}
           + ($t->{output} // 0) * $r->{output} ) / 1e6;
}

# Peak share billed at full rate, off-peak at the discounted multiplier.
sub zai_discounted {
    my ($week, $model) = @_;
    my $src = $agg{$week} // {};
    return zai_credits($src->{PEAK}, $model)
         + zai_credits($src->{OFF},  $model) * $RATES->{zai}{offpeak_multiplier};
}

# Max value of a rolling 5-hour window over $fn applied to each event.
sub peak_5h {
    my $fn = shift;
    my ($i, $sum, $best, $when) = (0, 0, 0, 0);
    for my $j (0 .. $#events) {
        $sum += $fn->($events[$j]);
        while ($events[$i]{at} <= $events[$j]{at} - 5 * 3600) {
            $sum -= $fn->($events[$i]);
            $i++;
        }
        if ($sum > $best) { $best = $sum; $when = $events[$j]{at} }
    }
    return ($best, $when);
}

sub comma { my $n = reverse(shift // 0); $n =~ s/(\d{3})(?=\d)/$1,/g; scalar reverse $n }
sub iso   { my @t = gmtime(shift); sprintf('%04d-%02d-%02d %02d:%02dZ',
                $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1]) }

# ------------------------------------------------------------------- report --

my @weeks = sort grep { $_ ne 'ALL' } keys %agg;
if ($weeks && @weeks > $weeks) { @weeks = @weeks[-$weeks .. -1] }

# The week in progress is always partial; label it so nobody averages it in.
my $cur_week = do {
    my $now = time;
    my $dow = (gmtime($now))[6];
    my @mt  = gmtime($now - ((($dow + 6) % 7) * 86400));
    sprintf('%04d-%02d-%02d', $mt[5] + 1900, $mt[4] + 1, $mt[3]);
};

my $zmodel = $RATES->{zai}{default_model};
my $amodel = $RATES->{anthropic}{default_model};
my $dmodel = $RATES->{deepseek}{default_model};

my @md;
push @md, "# Claude Code usage audit\n";
push @md, "**Generated:** " . iso(time) . " · **Rate card verified:** $RATES->{rates_verified}\n";
push @md, "**Window:** $weeks[0] → $weeks[-1] · **Files:** " . comma($files)
        . " · **Unique API requests:** " . comma($records) . "\n";
push @md, "\n## Transcript roots scanned\n";
push @md, "- `$_`" for @ROOTS;

my $all_i = $agg{ALL}{INTERACTIVE} // {};
my $all_h = $agg{ALL}{HEADLESS}    // {};
my $grand = tokens($all_i) + tokens($all_h);

push @md, "\n## Totals\n";
push @md, "| Field | Tokens |", "|---|---:|";
push @md, "| fresh input | " . comma(($all_i->{input}//0)+($all_h->{input}//0)) . " |";
push @md, "| cache write | " . comma(($all_i->{cwrite}//0)+($all_h->{cwrite}//0)) . " |";
push @md, "| cache read | "  . comma(($all_i->{cread}//0)+($all_h->{cread}//0))  . " |";
push @md, "| output (incl. thinking) | " . comma(($all_i->{output}//0)+($all_h->{output}//0)) . " |";
my $all_in = ($all_i->{input}//0)+($all_h->{input}//0)
           + ($all_i->{cwrite}//0)+($all_h->{cwrite}//0)
           + ($all_i->{cread}//0)+($all_h->{cread}//0);
push @md, sprintf("\nCache hit rate **%.1f%%** · output is **%.2f%%** of token volume.\n",
    $all_in ? 100*(($all_i->{cread}//0)+($all_h->{cread}//0))/$all_in : 0,
    $grand  ? 100*(($all_i->{output}//0)+($all_h->{output}//0))/$grand : 0);

push @md, "\n## Interactive vs headless fleet\n";
push @md, "| Class | Requests | Tokens | Share | Tokens/req |", "|---|---:|---:|---:|---:|";
for my $c (qw(INTERACTIVE INTERACTIVE/main INTERACTIVE/sub HEADLESS HEADLESS/main HEADLESS/sub)) {
    my $t = $agg{ALL}{$c} or next;
    push @md, sprintf('| %s | %s | %s | %.2f%% | %s |', $c, comma($t->{requests}),
        comma(tokens($t)), $grand ? 100*tokens($t)/$grand : 0,
        comma($t->{requests} ? int(tokens($t)/$t->{requests}) : 0));
}

push @md, "\n## Per week\n";
push @md, "| Week (Mon) | Reqs | Tokens | Fleet share | $amodel \$ | $zmodel credits | disc. | $dmodel \$ |";
push @md, "|---|---:|---:|---:|---:|---:|---:|---:|";
for my $w (@weeks) {
    my $i = $agg{$w}{INTERACTIVE} // {};
    my $h = $agg{$w}{HEADLESS}    // {};
    my %s = map { my $f = $_; ($f => ($i->{$f}//0) + ($h->{$f}//0)) }
            qw(input cwrite cread output requests);
    my $tt = tokens(\%s) || 1;
    push @md, sprintf('| %s | %s | %s | %.1f%% | %.2f | %.0f | %.0f | %.2f |',
        $w . ($w eq $cur_week ? ' *(partial)*' : ''),
        comma($s{requests}), comma(tokens(\%s)), 100*tokens($h)/$tt,
        anthropic_usd(\%s), zai_credits(\%s), zai_discounted($w), deepseek_usd(\%s));
}

push @md, "\n## Cost composition at $amodel list rates\n";
push @md, "| Component | Interactive | Headless |", "|---|---:|---:|";
for my $row (['fresh input','input'], ['cache write','cwrite'],
             ['cache read','cread'], ['output (incl. thinking)','output']) {
    my ($label, $f) = @$row;
    my @cells;
    for my $t ($all_i, $all_h) {
        my $part = anthropic_usd({ $f => $t->{$f} // 0 });
        my $tot  = anthropic_usd($t) || 1;
        push @cells, sprintf('%.1f%%', 100 * $part / $tot);
    }
    push @md, "| $label | $cells[0] | $cells[1] |";
}
push @md, sprintf('| **total** | **$%.2f** | **$%.2f** |',
    anthropic_usd($all_i), anthropic_usd($all_h));

push @md, "\n## Peak rolling 5-hour windows\n";
my ($pk_req, $t_req) = peak_5h(sub { 1 });
push @md, "| Metric | Peak | Ending (UTC) |", "|---|---:|---|";
push @md, "| requests | " . comma($pk_req) . " | " . iso($t_req) . " |";
for my $zm (sort keys %{ $RATES->{zai}{models} }) {
    my ($c, $t) = peak_5h(sub { zai_credits($_[0], $zm) });
    my ($d)     = peak_5h(sub { my $e = shift;
        zai_credits($e, $zm) * ($e->{peak} ? 1 : $RATES->{zai}{offpeak_multiplier}) });
    push @md, sprintf('| %s credits (full / off-peak disc.) | %.0f / %.0f | %s |', $zm, $c, $d, iso($t));
}
push @md, "\n### Against Z.ai plan caps\n";
push @md, "| Plan | 5h cap | Peak 5h ($zmodel, disc.) | Weekly cap | Worst week (disc.) |";
push @md, "|---|---:|---:|---:|---:|";
my ($pk_disc) = peak_5h(sub { my $e = shift;
    zai_credits($e, $zmodel) * ($e->{peak} ? 1 : $RATES->{zai}{offpeak_multiplier}) });
my $worst = 0;
for my $w (@weeks) {
    next if $w eq $cur_week;    # in-progress week would understate the worst case
    my $d = zai_discounted($w);
    $worst = $d if $d > $worst;
}
my $plans = $RATES->{zai}{plans};
for my $p (sort { $plans->{$a}{per_week} <=> $plans->{$b}{per_week} } keys %$plans) {
    my $pl = $plans->{$p};
    push @md, sprintf('| %s | %s | %.0f (%.1fx) | %s | %.0f (%.1fx) |',
        $p, comma($pl->{per_5h}), $pk_disc, $pk_disc/$pl->{per_5h},
        comma($pl->{per_week}), $worst, $worst/$pl->{per_week});
}

push @md, "\n### Against Kimi request metering\n";
my $kr = $RATES->{kimi}{requests_per_5h_range};
push @md, sprintf("Kimi Code meters in requests per rolling 5h (documented range %d–%d). "
    . "Peak here is **%s requests** — %.1fx the top of that range.\n",
    $kr->[0], $kr->[1], comma($pk_req), $pk_req / $kr->[1]);

push @md, "\n## Offload cost (headless fleet → DeepSeek)\n";
push @md, "| Model | Whole run | Per week |", "|---|---:|---:|";
my $n_complete = grep { $_ ne $cur_week } @weeks;
$n_complete ||= 1;
for my $dm (sort keys %{ $RATES->{deepseek}{models} }) {
    push @md, sprintf('| %s | $%.2f | $%.2f |', $dm,
        deepseek_usd($all_h, $dm), deepseek_usd($all_h, $dm) / $n_complete);
}
push @md, "\n> Assumes the measured cache hit rate carries to DeepSeek. Their cache-miss "
        . "price is 50–120x their cache-hit price, so validate against a real run before "
        . "relying on these figures.\n";

push @md, "\n## Caveats\n";
push @md, "- Claude Code's retention cleanup (`cleanupPeriodDays`, default 30) deletes old "
        . "transcripts. Weeks older than that window are partial and understate.";
push @md, "- Anthropic's Admin API usage/cost endpoints are unavailable to individual accounts "
        . "and cover only organization API-key usage, so transcripts are the only complete source.";
push @md, "- Rate card verified $RATES->{rates_verified}; re-verify before acting on the numbers.";

my $doc = join("\n", @md) . "\n";

# --------------------------------------------------------------------- emit --

unless ($no_vault) {
    my @t = gmtime(time);
    my $date = sprintf('%04d-%02d-%02d', $t[5]+1900, $t[4]+1, $t[3]);
    $out_path //= "$HOME/.claude/claude-code-vault/reports/usage/$date.md";
    make_path(dirname($out_path));
    open(my $fh, '>', $out_path) or die "cannot write $out_path: $!\n";
    print $fh $doc;
    close $fh;
    print "REPORT: $out_path\n";
}

printf "ROOTS: %d   FILES: %s   REQUESTS: %s   TOKENS: %s\n",
    scalar(@ROOTS), comma($files), comma($records), comma($grand);
printf "SPLIT: interactive %.1f%%  headless %.1f%%\n",
    $grand ? 100*tokens($all_i)/$grand : 0, $grand ? 100*tokens($all_h)/$grand : 0;
printf "PEAK5H: %s requests | %.0f %s credits (off-peak disc.)\n",
    comma($pk_req), $pk_disc, $zmodel;
print $doc if $no_vault;
