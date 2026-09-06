#!/usr/bin/env perl
# update-research.pl -- deterministic release research for /steward:update, with
# a persistence layer so the same facts are never re-derived.
#
# WHY THIS EXISTS
#
# /steward:update used to be a prose protocol: the agent hand-ran eight
# WebFetches, hand-joined two datasets, hand-computed ages and hand-classified
# risk, every single run. That cost tokens per invocation, drifted between runs,
# and -- measured on 2026-09-06 -- was wrong in three ways that a script cannot
# be:
#
#   1. It read GitHub Releases through a prose summarizer, which returned FIVE
#      releases. The API returns 100 on page one and paginates to three. The
#      protocol then computed release age from a dataset missing 95% of its
#      rows, and had no date at all for most candidate versions.
#   2. Its version-string issue search (`q=...2.1.263+OR+2.1.261+...`) matched
#      every issue filed that day. Zero signal, presented as evidence.
#   3. It re-derived everything on every run. Decline an update and the next
#      invocation pays the identical cost to reach the identical conclusion.
#
# The facts involved are mostly IMMUTABLE -- a published release's date and its
# changelog text never change -- so re-fetching them is pure waste. This script
# stores them once, refreshes only what can actually move (open issues, and the
# tail of the changelog), and recomputes only what is a function of NOW (age,
# and therefore risk).
#
# WHAT IS AND IS NOT CACHED, AND WHY
#
#   versions.json   IMMUTABLE. A version's published_at and changelog body are
#                   facts about a shipped artifact. Fetched once, kept forever.
#                   Refreshed via a conditional GET, so the steady-state cost of
#                   a run is one 304.
#   issues.json     MUTABLE, TTL'd. New crash reports appear and old ones close,
#                   so this expires (default 12h). It is the only thing a
#                   routine re-run actually pays for.
#   decisions.jsonl APPEND-ONLY. What the operator chose and why. This is what
#                   makes the NEXT run smarter rather than merely faster: a
#                   version declined for a named issue can be re-offered when
#                   that issue closes, instead of being re-litigated blind.
#
# Risk is deliberately NOT stored. It is a function of the current time, and a
# cached risk verdict silently rots into a lie the day after it is written.
#
# SUBCOMMANDS
#   status                 Offline. Where the store is, what it holds, how stale.
#   gather                 Refresh what is stale, merge, emit the full analysis.
#   record-decision        Append what the operator chose.
#   history                Past decisions, newest first.
#   sync                   Commit + push the store when it lives in the vault.
#   prune                  Remove legacy/oversized cache artifacts.
#
# All output is a single JSON object on stdout. Errors are JSON too ({ok:0}),
# never a bare die, so the caller always has something to parse.

use strict;
use warnings;
use JSON::PP ();
use File::Path qw(make_path);
use File::Basename qw(dirname);
use FindBin ();
use lib $FindBin::Bin;
use Getopt::Long qw(GetOptionsFromArray);
use VaultNamespace ();

# MSYS2 mangles ':'-separated args handed to native Windows binaries (curl,
# git), rewriting them into ';'-joined Windows paths. Every URL we pass contains
# "https:", so without this a curl fallback receives a corrupted argument. See
# the project CLAUDE.md; this is the opt-out half of the technique, and the
# paths we hand out are already Windows-shaped (git_path below) so it is safe.
$ENV{MSYS2_ARG_CONV_EXCL} = '*' if $^O =~ /^(MSWin32|cygwin|msys)$/;

my $SCHEMA          = 1;
my $ISSUE_TTL       = 12 * 3600;   # seconds; see "MUTABLE, TTL'd" above

# How long an issue's state may go unverified before it is re-checked.
#
# THE BUG THIS FIXES. The symptom searches filter `state:open`, so when an issue
# is CLOSED it simply stops appearing in results -- and a record that stops
# appearing was never updated. It kept `state: open` forever and went on
# penalising its version indefinitely. Measured on the real store: 87 issues
# held, 72 of which had never had their state re-checked since first sight.
#
# Absence from a result page is NOT sufficient evidence of closure either --
# with per_page=30 an issue can fall out of the window because newer ones
# pushed it out. So state is re-verified positively, against the issue's own
# endpoint, on a rolling basis.
my $ISSUE_VERIFY_AGE = 7 * 86400;
my $CHANGELOG_URL   = 'https://raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md';
# Anthropic's own published changelog. It states that it is generated from the
# GitHub CHANGELOG.md, and measured on 2026-09-06 the two agreed exactly: 387
# versions each, none present in one and missing from the other. It is fetched
# anyway, for two things GitHub's copy cannot give:
#
#   DATES. Every one of those 387 entries carries description="September 6,
#   2026". GitHub's markdown has bare `## 2.1.263` headers with no date at all,
#   so without this the only date source is the Releases API -- 100 per page,
#   rate limited to 60 requests/hour unauthenticated, and the thing the old
#   protocol got truncated by. One fetch here dates the entire history.
#
#   A CROSS-CHECK. Two independent renderings of the same claim. If they ever
#   diverge, the run says so rather than silently trusting whichever it read
#   first.
my $DOCS_CHANGELOG_URL = 'https://code.claude.com/docs/en/changelog.md';
my $RELEASES_URL    = 'https://api.github.com/repos/anthropics/claude-code/releases';
my $SEARCH_URL      = 'https://api.github.com/search/issues';
my $UA              = 'ccpraxis-steward-update-research';

# The symptom queries. Version-string searching is deliberately absent: it was
# tried, and GitHub's search treats `2.1.263 OR 2.1.261` as loose terms that
# match essentially every recent issue. Versions are extracted from the BODIES
# of symptom hits instead, which is where they are actually stated.
my @SYMPTOM_QUERIES = (
    '"stack overflow"',
    '"illegal instruction"',
    'segfault',
    '"crashes on startup"',
    'panic Bun',
);

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

# BYTES, NOT CHARS -- everywhere in this file, deliberately.
#
# $ENV{HOME} on this machine is `/c/Users/André/...`, which perl hands us as
# raw UTF-8 BYTES. Calling ->utf8->encode on a structure containing it encodes
# those bytes a second time and the store path comes back as `AndrÃ©`. That is
# the same double-encode that corrupted vault-sync's ops journal.
#
# So the policy is uniform: never ->utf8 on encode, never ->utf8 on decode, and
# raw handles at both ends. Every string stays a byte string from the socket to
# the file and back, and round-trips byte-for-byte. The one thing that must not
# happen is mixing the two conventions in one process.
binmode(STDOUT, ':raw');

sub json_out {
    my ($obj) = @_;
    print JSON::PP->new->canonical(1)->pretty->encode($obj);
    return;
}

sub bail {
    my ($msg, %extra) = @_;
    json_out({ ok => JSON::PP::false, error => "$msg", %extra });
    exit 1;
}

sub now_iso { my @t = gmtime(time); return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5]+1900, $t[4]+1, @t[3,2,1,0]) }

sub home_dir {
    my $h = $ENV{HOME} // $ENV{USERPROFILE};
    return undef unless defined $h && length $h;
    $h =~ s{\\}{/}g;
    $h =~ s{/+$}{};
    return $h;
}

# iso_to_epoch -- parse the ISO-8601 GitHub hands back. Written out rather than
# pulled from Time::Piece because strptime's %z handling differs across the
# perls this has to run on, and every timestamp here is already UTC 'Z'.
sub iso_to_epoch {
    my ($s) = @_;
    return undef unless defined $s && $s =~ /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})/;
    my ($Y,$M,$D,$h,$m,$sec) = ($1,$2,$3,$4,$5,$6);
    require Time::Local;
    my $e = eval { Time::Local::timegm($sec, $m, $h, $D, $M - 1, $Y) };
    return defined $e ? $e : undef;
}

# vcmp -- numeric, component-wise. `2.1.90` must sort BELOW `2.1.219`; a string
# compare puts it above, which would silently mis-order every candidate list.
sub vcmp {
    my ($a, $b) = @_;
    my @a = split /\./, ($a // '');
    my @b = split /\./, ($b // '');
    for my $i (0 .. 2) {
        my $x = ($a[$i] // 0) + 0;
        my $y = ($b[$i] // 0) + 0;
        return $x <=> $y if $x != $y;
    }
    return 0;
}

sub read_file_raw {
    my ($p) = @_;
    open my $fh, '<:raw', $p or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

# Atomic: a run interrupted mid-write must not leave a half-JSON store that the
# next run cannot parse. Write beside, then rename over.
sub write_file_atomic {
    my ($p, $bytes) = @_;
    make_path(dirname($p)) unless -d dirname($p);
    my $tmp = "$p.tmp.$$";
    open my $fh, '>:raw', $tmp or return 0;
    print {$fh} $bytes or do { close $fh; unlink $tmp; return 0 };
    close $fh or do { unlink $tmp; return 0 };
    unlink $p if -e $p && $^O =~ /^MSWin32$/;   # rename onto an existing file fails on Win32
    rename($tmp, $p) or do { unlink $tmp; return 0 };
    return 1;
}

sub read_json_file {
    my ($p) = @_;
    my $raw = read_file_raw($p);
    return undef unless defined $raw && length $raw;
    my $d = eval { JSON::PP->new->decode($raw) };
    return ref $d eq 'HASH' ? $d : undef;
}

sub write_json_file {
    my ($p, $obj) = @_;
    return write_file_atomic($p, JSON::PP->new->canonical(1)->pretty->encode($obj));
}

# ---------------------------------------------------------------------------
# Store location
#
# The vault when there is one, so a second machine inherits the whole history
# instead of re-deriving it -- which is the point of persisting at all. A plain
# local dir otherwise, because research must not require a configured vault.
# ---------------------------------------------------------------------------

sub store_paths {
    my $home = home_dir() or return undef;
    my $vault = "$home/.claude/claude-code-vault";
    my $in_vault = (-d "$vault/.git") ? 1 : 0;
    my $root = $in_vault ? "$vault/research/claude-code"
                         : "$home/.claude/cache/update-research";
    return {
        home      => $home,
        vault     => $vault,
        in_vault  => $in_vault,
        root      => $root,
        versions  => "$root/versions.json",
        issues    => "$root/issues.json",
        decisions => "$root/decisions.jsonl",
    };
}

# ---------------------------------------------------------------------------
# HTTP
#
# HTTP::Tiny when TLS is wired up, curl otherwise. Neither is an install: HTTP
# ::Tiny is core, IO::Socket::SSL ships with Git for Windows and with most
# system perls, and curl is present on macOS, Linux and Git for Windows alike.
# The repo's no-external-dependencies rule is why there is a fallback at all
# rather than a hard requirement on the SSL module.
# ---------------------------------------------------------------------------

my $HTTP_MODE;
sub http_mode {
    return $HTTP_MODE if defined $HTTP_MODE;
    my $tiny = eval { require HTTP::Tiny; HTTP::Tiny->can_ssl ? 1 : 0 } || 0;
    $HTTP_MODE = $tiny ? 'http-tiny' : 'curl';
    return $HTTP_MODE;
}

# http_get($url, %opt) -> { status, content, headers, from_cache }
#   opt: etag => conditional GET (a 304 means "nothing to parse", the cheap path)
sub http_get {
    my ($url, %opt) = @_;
    my %hdr = ('User-Agent' => $UA, 'Accept' => 'application/vnd.github+json');
    $hdr{'If-None-Match'} = $opt{etag} if defined $opt{etag} && length $opt{etag};

    if (http_mode() eq 'http-tiny') {
        my $r = HTTP::Tiny->new(agent => $UA, timeout => 30)
                  ->get($url, { headers => \%hdr });
        my $et = $r->{headers}{etag};
        $et = $et->[0] if ref $et eq 'ARRAY';
        my $link = $r->{headers}{link};
        $link = $link->[0] if ref $link eq 'ARRAY';
        return { status => ($r->{status} // 0), content => ($r->{content} // ''),
                 etag => $et, link => $link };
    }

    # curl fallback. -sS keeps it quiet but still reports real errors; the
    # status is appended on its own line so a body containing digits cannot be
    # mistaken for it.
    my @cmd = ('curl', '-sS', '-L', '--max-time', '30',
               '-H', "User-Agent: $UA", '-H', 'Accept: application/vnd.github+json');
    push @cmd, '-H', "If-None-Match: $opt{etag}" if defined $opt{etag} && length $opt{etag};
    push @cmd, '-D', '-', '-w', "\n__CCPX_STATUS__%{http_code}\n", $url;

    my $out = '';
    if (open my $ph, '-|', @cmd) { local $/; $out = <$ph> // ''; close $ph }
    my $status = ($out =~ /__CCPX_STATUS__(\d+)/) ? $1 + 0 : 0;
    $out =~ s/\n?__CCPX_STATUS__\d+\n?//;
    # Split the (possibly multiple, due to -L) header blocks from the body.
    my ($etag, $link);
    while ($out =~ /^(HTTP\/[\d.]+ \d+.*?)(?:\r?\n\r?\n)/s) {
        my $block = $1;
        $etag = $1 if $block =~ /^etag:\s*(\S+)/mi;
        $link = $1 if $block =~ /^link:\s*(.+?)\s*$/mi;
        $out =~ s/^HTTP\/[\d.]+ \d+.*?(?:\r?\n\r?\n)//s;
    }
    return { status => $status, content => $out, etag => $etag, link => $link };
}

# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------

# parse_changelog($markdown) -> { version => \@bullets }
#
# The docs SITE renders this same content through a JS framework with
# randomised element ids, which is why an earlier attempt cached 3.6 MB of HTML
# per run and still could not parse it. The repo ships the markdown; parse that.
sub parse_changelog {
    my ($md) = @_;
    my %out;
    return \%out unless defined $md && length $md;
    my $cur;
    for my $line (split /\r?\n/, $md) {
        if ($line =~ /^#{1,3}\s*v?(\d+\.\d+\.\d+)\s*$/) { $cur = $1; $out{$cur} ||= []; next }
        next unless defined $cur;
        # Stop a version's bullets at the next header of any kind.
        if ($line =~ /^#{1,3}\s/) { $cur = undef; next }
        push @{ $out{$cur} }, $1 if $line =~ /^\s*[-*]\s+(.*\S)\s*$/;
    }
    return \%out;
}

# parse_docs_changelog($markdown) -> { version => { bullets => [...], date => 'YYYY-MM-DD' } }
#
# The docs page ships MDX, so entries are <Update label="2.1.263"
# description="September 6, 2026"> blocks rather than markdown headers. Parsed
# with an explicit month table rather than a strptime %B, because %B is
# locale-dependent and would stop matching on a machine whose locale is not
# English -- a failure that would show up as "no dates found" and be blamed on
# the network.
{
    my %MONTH = do { my $i = 0; map { $_ => ++$i } qw(January February March April May June
                                                      July August September October November December) };
    sub parse_docs_changelog {
        my ($md) = @_;
        my %out;
        return \%out unless defined $md && length $md;
        while ($md =~ m{<Update\s+label="(\d+\.\d+\.\d+)"\s+description="([^"]*)"\s*>(.*?)</Update>}sg) {
            my ($v, $desc, $body) = ($1, $2, $3);
            my @b = $body =~ /^\s*[-*]\s+(.*\S)\s*$/mg;
            my $date;
            if ($desc =~ /^\s*([A-Z][a-z]+)\s+(\d{1,2}),\s*(\d{4})\s*$/ && $MONTH{$1}) {
                $date = sprintf('%04d-%02d-%02d', $3, $MONTH{$1}, $2);
            }
            $out{$v} = { bullets => \@b, date => $date };
        }
        return \%out;
    }
}

# platforms_named($text) -> sorted list. Used so a Linux-only crash cluster is
# not presented to a Windows operator as though it applied to them -- the single
# most misleading thing the old prose flow did.
sub platforms_named {
    my ($t) = @_;
    $t = lc($t // '');
    my %p;
    $p{windows} = 1 if $t =~ /\bwindows\b|\bwin32\b|\bwin64\b|\bmsix\b|\bpowershell\b/;
    $p{macos}   = 1 if $t =~ /\bmacos\b|\bmac os\b|\bdarwin\b|\bapple silicon\b|\bmonterey\b|\bsonoma\b/;
    $p{linux}   = 1 if $t =~ /\blinux\b|\bglibc\b|\bubuntu\b|\barch\b|\bdebian\b|\bfedora\b|\bcachyos\b|\bwsl\b/;
    return [ sort keys %p ];
}

# Two different questions, deliberately kept apart.
#
# versions_mentioned  every 2.x string anywhere in the report
# versions_affected   the ones the report actually blames
#
# Conflating them over-links badly. Issue #89437 is titled "Startup SIGILL in
# 2.1.241; 2.1.243 clean in 17/17 launches" -- 2.1.243 is named there as the
# version that WORKS. Counting every mention as an accusation gave 2.1.243
# twenty-two "open issues naming this version" and would have talked the
# operator out of a version that several reports were recommending.
#
# The affected set comes from the title plus the labelled fields bug templates
# use ("Claude Code version: 2.1.246"), and drops any version the text marks as
# working. It is a heuristic and is reported as one -- both sets are emitted, so
# a reader can always see what was discarded.
sub versions_mentioned {
    my ($t) = @_;
    my %v;
    while (($t // '') =~ /\b(\d+\.\d+\.\d+)\b/g) {
        # COPY $1 FIRST. The filter below is itself a match, and a SUCCESSFUL
        # match with no capture groups sets $1 to undef -- so testing $1 with a
        # pattern destroys the value being tested. Silent: it stores undef keys
        # rather than erroring, and only `use warnings` reveals it.
        my $c = $1;
        # Bun/glibc/kernel versions share the shape. Claude Code is 2.x.
        $v{$c} = 1 if $c =~ /^2\./;
    }
    return [ sort { vcmp($a, $b) } keys %v ];
}

sub versions_affected {
    my ($title, $body) = @_;
    $title //= ''; $body //= '';
    my %v;

    # 1. Versions in the title.
    $v{$1} = 1 while $title =~ /\b(2\.\d+\.\d+)\b/g;

    # 2. Labelled fields in the body, which is where issue templates put it.
    while ($body =~ /(?:claude[ -]?code|cc|version|installed)\s*(?:version)?\s*[:=]?\s*v?(2\.\d+\.\d+)/gi) {
        $v{$1} = 1;
    }

    # 3. Drop anything the text explicitly exonerates. Narrow on purpose: it
    #    only fires on a version immediately followed by a working-word, so
    #    "2.1.243 clean in 17/17" is dropped and "2.1.243 crashes" is not.
    for my $blob ($title, $body) {
        while ($blob =~ /\b(2\.\d+\.\d+)\s+(?:is\s+|was\s+|looks\s+|runs\s+)?
                          (clean|fine|ok|okay|good|works?|working|stable|unaffected)\b/gix) {
            delete $v{$1};
        }
    }
    return [ sort { vcmp($a, $b) } keys %v ];
}

sub runtime_named {
    my ($t) = @_;
    return $1 if ($t // '') =~ /\bBun\s+v?(\d+\.\d+\.\d+)/i;
    return undef;
}

# ---------------------------------------------------------------------------
# gather
# ---------------------------------------------------------------------------

sub cmd_gather {
    my (@argv) = @_;
    my ($current, $ttl, $offline, $force, $no_sync) = (undef, $ISSUE_TTL, 0, 0, 0);
    GetOptionsFromArray(\@argv,
        'current=s'    => \$current,
        'issues-ttl=i' => \$ttl,
        'offline'      => \$offline,
        'force'        => \$force,
        'no-sync'      => \$no_sync,
    ) or bail('bad arguments to gather');

    my $S = store_paths() or bail('cannot determine home directory');
    make_path($S->{root}) unless -d $S->{root};

    my @warnings;
    my %net;

    # Current version: ask the binary unless told. A wrong "current" silently
    # changes which versions are even candidates, so it is reported back.
    if (!defined $current || !length $current) {
        my $v = `claude --version 2>&1` // '';
        $current = ($v =~ /(\d+\.\d+\.\d+)/) ? $1 : undef;
        push @warnings, 'could not determine the installed version; pass --current'
            unless defined $current;
    }

    my $vstore = read_json_file($S->{versions})
              || { schema => $SCHEMA, versions => {}, etag => undef, updated_at => undef };
    $vstore->{versions} ||= {};

    # --- changelog (conditional; a 304 is the steady state) -----------------
    if (!$offline) {
        my $r = http_get($CHANGELOG_URL, ($force ? () : (etag => $vstore->{etag})));
        if ($r->{status} == 304) {
            $net{changelog} = 'not-modified';
        }
        elsif ($r->{status} == 200) {
            my $parsed = parse_changelog($r->{content});
            my $added = 0;
            for my $v (keys %$parsed) {
                my $rec = $vstore->{versions}{$v} ||= { version => $v, first_seen => now_iso() };
                $added++ unless $rec->{changelog_bullets};
                $rec->{changelog_bullets} = $parsed->{$v};
            }
            $vstore->{etag} = $r->{etag};
            $net{changelog} = "fetched (" . scalar(keys %$parsed) . " versions, $added new)";
        }
        else {
            $net{changelog} = "failed (status $r->{status})";
            push @warnings, "changelog fetch failed with status $r->{status}; using cache";
        }
    }
    else { $net{changelog} = 'skipped (offline)' }

    # --- Anthropic's published changelog (dates + cross-check) --------------
    my @disagreements;
    if (!$offline) {
        my $r = http_get($DOCS_CHANGELOG_URL, ($force ? () : (etag => $vstore->{docs_etag})));
        if ($r->{status} == 304) { $net{docs_changelog} = 'not-modified' }
        elsif ($r->{status} == 200) {
            my $parsed = parse_docs_changelog($r->{content});
            my $dated = 0;
            for my $v (keys %$parsed) {
                my $rec = $vstore->{versions}{$v} ||= { version => $v, first_seen => now_iso() };
                if (defined $parsed->{$v}{date}) {
                    # Day granularity. Kept in its own field so the Releases
                    # API's precise timestamp always wins where both exist, and
                    # this fills the gap where only this source reaches.
                    $rec->{docs_date} = $parsed->{$v}{date};
                    $dated++;
                }
                $rec->{docs_bullets} = $parsed->{$v}{bullets};
                # Cross-check: same version, materially different bullet counts.
                my $g = $rec->{changelog_bullets};
                if ($g && @$g && @{ $parsed->{$v}{bullets} }
                       && scalar(@$g) != scalar(@{ $parsed->{$v}{bullets} })) {
                    push @disagreements, { version => $v, github_bullets => scalar @$g,
                                           docs_bullets => scalar @{ $parsed->{$v}{bullets} } };
                }
            }
            # Present in one source only, in either direction.
            for my $v (keys %{ $vstore->{versions} }) {
                my $rec = $vstore->{versions}{$v};
                next unless $rec->{changelog_bullets} || $rec->{docs_bullets};
                push @disagreements, { version => $v, only_in => 'github-changelog' }
                    if $rec->{changelog_bullets} && !$rec->{docs_bullets};
                push @disagreements, { version => $v, only_in => 'docs-changelog' }
                    if $rec->{docs_bullets} && !$rec->{changelog_bullets};
            }
            $vstore->{docs_etag} = $r->{etag};
            $net{docs_changelog} = 'fetched (' . scalar(keys %$parsed) . " versions, $dated dated)";
            push @warnings, scalar(@disagreements) . ' version(s) differ between the GitHub and '
                          . 'published changelogs; see source_disagreements' if @disagreements;
        }
        else {
            $net{docs_changelog} = "failed (status $r->{status})";
            push @warnings, "published changelog fetch failed with status $r->{status}; "
                          . 'release dates may be missing for older versions';
        }
    }
    else { $net{docs_changelog} = 'skipped (offline)' }

    # --- releases (paginate until the current version is covered) ----------
    #
    # THE BUG THIS REPLACES: the old flow read one summarised page and believed
    # it had every release. Pagination is followed until the installed version
    # is inside the window, and if it never is, coverage_ok says so out loud
    # rather than letting a truncated dataset look complete.
    my $coverage_ok = 1;
    if (!$offline) {
        my ($page, $pages, $seen, $oldest) = (1, 0, 0, undef);
        my $url = "$RELEASES_URL?per_page=100";
        while ($url && $page <= 5) {
            # Conditional on page 1 only. A 304 there means no release has been
            # published since we last looked, so no later page can have changed
            # either -- releases are append-at-the-front. Without this the
            # steady-state run re-downloads and re-parses ~700 KB of JSON whose
            # every field we already hold.
            my $r = http_get($url, (($page == 1 && !$force && $vstore->{releases_etag})
                                        ? (etag => $vstore->{releases_etag}) : ()));
            if ($page == 1 && $r->{status} == 304) { $net{releases} = 'not-modified'; last }
            $vstore->{releases_etag} = $r->{etag} if $page == 1 && $r->{status} == 200 && $r->{etag};
            last unless $r->{status} == 200;
            my $j = eval { JSON::PP->new->decode($r->{content}) };
            last unless ref $j eq 'ARRAY' && @$j;
            for my $rel (@$j) {
                my $tag = $rel->{tag_name} // '';
                my ($v) = $tag =~ /(\d+\.\d+\.\d+)/ or next;
                $seen++;
                my $rec = $vstore->{versions}{$v} ||= { version => $v, first_seen => now_iso() };
                $rec->{tag}          = $tag;
                $rec->{published_at} = $rel->{published_at};
                $oldest = $v if !defined $oldest || vcmp($v, $oldest) < 0;
            }
            $pages++;
            # Stop as soon as the window reaches the installed version.
            last if defined $current && defined $oldest && vcmp($oldest, $current) <= 0;
            ($url) = ($r->{link} // '') =~ /<([^>]+)>;\s*rel="next"/;
            $page++;
        }
        $net{releases} = "fetched ($seen releases over $pages page(s))"
            unless ($net{releases} // '') eq 'not-modified';
        if (defined $current && defined $oldest && vcmp($oldest, $current) > 0) {
            $coverage_ok = 0;
            push @warnings, "release pagination stopped at $oldest, which is still newer than "
                          . "the installed $current -- versions between them have no publish date";
        }
    }
    else { $net{releases} = 'skipped (offline)' }

    $vstore->{schema}     = $SCHEMA;
    $vstore->{updated_at} = now_iso();
    write_json_file($S->{versions}, $vstore)
        or push @warnings, 'could not write versions.json';

    # --- issues (TTL'd) ----------------------------------------------------
    my $istore = read_json_file($S->{issues}) || { schema => $SCHEMA, issues => {}, fetched_at => undef };
    $istore->{issues} ||= {};
    my $iage = defined $istore->{fetched_at} ? (time - (iso_to_epoch($istore->{fetched_at}) // 0)) : undef;

    if ($offline) { $net{issues} = 'skipped (offline)' }
    elsif (!$force && defined $iage && $iage < $ttl) {
        $net{issues} = sprintf('cached (%dh old, ttl %dh)', int($iage / 3600), int($ttl / 3600));
    }
    else {
        my ($got, $failed) = (0, 0);
        for my $q (@SYMPTOM_QUERIES) {
            my $eq = $q;
            $eq =~ s/([^A-Za-z0-9_.~-])/sprintf('%%%02X', ord $1)/ge;
            my $u = "$SEARCH_URL?q=repo:anthropics/claude-code+$eq+state:open"
                  . "&sort=created&order=desc&per_page=30";
            my $r = http_get($u);
            if ($r->{status} != 200) { $failed++; next }
            my $j = eval { JSON::PP->new->decode($r->{content}) };
            next unless ref $j eq 'HASH' && ref $j->{items} eq 'ARRAY';
            for my $it (@{ $j->{items} }) {
                my $n = $it->{number} // next;
                my $blob = join(' ', ($it->{title} // ''), ($it->{body} // ''));
                $istore->{issues}{$n} = {
                    number     => $n,
                    title      => $it->{title},
                    created_at => $it->{created_at},
                    updated_at => $it->{updated_at},
                    reactions  => (ref $it->{reactions} eq 'HASH' ? ($it->{reactions}{total_count} // 0) : 0),
                    state      => $it->{state},
                    platforms  => platforms_named($blob),
                    versions   => versions_affected($it->{title}, $it->{body}),
                    mentioned  => versions_mentioned($blob),
                    runtime    => runtime_named($blob),
                    matched    => $q,
                };
                $got++;
            }
        }
        # REACTIONS ARE NOT IN THE SEARCH RESPONSE. Verified 2026-09-06: the
        # search endpoint returns reactions.total_count = 0 for issues whose
        # own endpoint reports 12 and 13. Trusting search would have made the
        # "how many people hit this" signal permanently zero, and any rule
        # keyed on it dead code that looks live.
        #
        # So they are hydrated one issue at a time -- but only for issues that
        # actually bear on a decision (they blame a version newer than the
        # installed one), and capped, because the unauthenticated core API
        # allows 60 requests an hour and this must not eat the budget for a
        # number that only sharpens an ordering.
        my ($hydrated, $newly_closed) = (0, 0);
        if (defined $current) {
            # Two reasons to visit an issue's own endpoint, and both matter:
            # it is the only place reactions are populated, and it is the only
            # way to learn an issue has CLOSED (search, filtered to open, can
            # only ever answer by omission). Never-checked first, then
            # longest-unverified, so the rolling re-check cannot starve.
            my @want = sort {
                my $A = $istore->{issues}{$a}{reactions_at};
                my $B = $istore->{issues}{$b}{reactions_at};
                return -1 if !$A && $B;
                return  1 if $A && !$B;
                return ($A // '') cmp ($B // '') || $b <=> $a;
            } grep {
                my $i = $istore->{issues}{$_};
                my $due = !$i->{reactions_at}
                       || (time - (iso_to_epoch($i->{reactions_at}) // 0)) > $ISSUE_VERIFY_AGE;
                # Only issues that bear on a decision. Verifying one that blames
                # a version older than the installed one spends a request from a
                # 60/hour budget to refine a number nobody will read.
                $due && grep { vcmp($_, $current) > 0 } @{ $i->{versions} || [] };
            } keys %{ $istore->{issues} };

            for my $n (@want[0 .. ($#want > 14 ? 14 : $#want)]) {
                last unless defined $n;
                my $r = http_get("https://api.github.com/repos/anthropics/claude-code/issues/$n");
                next unless $r->{status} == 200;
                my $j = eval { JSON::PP->new->decode($r->{content}) } or next;
                my $was = $istore->{issues}{$n}{state} // 'open';
                $istore->{issues}{$n}{reactions} =
                    (ref $j->{reactions} eq 'HASH' ? ($j->{reactions}{total_count} // 0) : 0);
                $istore->{issues}{$n}{comments}     = $j->{comments};
                $istore->{issues}{$n}{state}        = $j->{state};
                $istore->{issues}{$n}{reactions_at} = now_iso();
                $hydrated++;
                $newly_closed++ if $was eq 'open' && ($j->{state} // '') ne 'open';
            }
        }

        $istore->{fetched_at} = now_iso();
        $istore->{schema}     = $SCHEMA;
        write_json_file($S->{issues}, $istore) or push @warnings, 'could not write issues.json';
        $net{issues} = "fetched ($got records, $hydrated verified"
                     . ($newly_closed ? ", $newly_closed newly closed" : '')
                     . ($failed ? ", $failed queries failed" : '') . ')';
        # Worth saying out loud: a closed issue stops penalising its version,
        # which can change the recommendation between two otherwise identical
        # runs. Silent, that looks like the tool being inconsistent.
        push @warnings, "$newly_closed issue(s) have been closed upstream since last checked; "
                      . 'they no longer count against their versions' if $newly_closed;
        push @warnings, "$failed issue queries failed (GitHub search is rate limited to ~10/min "
                      . 'unauthenticated); results may be partial' if $failed;
    }

    # --- analysis (always recomputed; never cached) ------------------------
    my $analysis = analyse($vstore, $istore, $current, \@warnings);
    $analysis->{ok}            = JSON::PP::true;
    $analysis->{store}         = $S->{root};
    $analysis->{store_in_vault}= $S->{in_vault} ? JSON::PP::true : JSON::PP::false;
    $analysis->{network}       = \%net;
    $analysis->{http_mode}     = http_mode();
    $analysis->{coverage_ok}   = $coverage_ok ? JSON::PP::true : JSON::PP::false;
    $analysis->{source_disagreements} = \@disagreements;
    $analysis->{decisions}     = read_decisions($S->{decisions}, 10);

    # AUTOMATIC. Research that stays on one machine is research the next
    # machine pays for again, which is the whole thing this store exists to
    # stop. Skipped when offline (nothing new to push) and suppressible with
    # --no-sync. A sync failure is reported, never fatal: the analysis is
    # already computed and the operator should still get it.
    unless ($offline || $no_sync) {
        my $s = do_sync('steward: update research');
        $analysis->{sync} = {
            synced => ($s->{synced} ? JSON::PP::true : JSON::PP::false),
            pushed => ($s->{pushed} ? JSON::PP::true : JSON::PP::false),
            reason => $s->{reason},
            error  => $s->{error},
        };
        push @{ $analysis->{warnings} }, "research store sync failed: $s->{error}"
            if !$s->{ok} && $s->{error};
    }

    json_out($analysis);
    return 0;
}

# raise_risk($current, $floor) -> the worse of the two.
#
# Ordered so a band can only ever be made WORSE by additional evidence. NO_
# CHANGELOG and UNKNOWN sit above MEDIUM but below HIGH: not knowing what
# changed is a real reason for caution, and not as bad as a pile of open crash
# reports.
{
    my %RANK = (LOW => 0, MEDIUM => 1, UNKNOWN => 2, NO_CHANGELOG => 2, HIGH => 3, RUNTIME_RISK => 4);
    sub raise_risk {
        my ($cur, $floor) = @_;
        return $floor unless defined $cur && exists $RANK{$cur};
        return $cur   unless defined $floor && exists $RANK{$floor};
        return $RANK{$floor} > $RANK{$cur} ? $floor : $cur;
    }
}

# analyse -- risk is computed here, from the current clock, every time.
sub analyse {
    my ($vstore, $istore, $current, $warnings) = @_;

    my @all = sort { vcmp($b, $a) } keys %{ $vstore->{versions} };
    my $latest = $all[0];

    # A version is a candidate if it is strictly newer than what is installed.
    my @cand = defined $current ? (grep { vcmp($_, $current) > 0 } @all) : @all;

    # Runtime cluster: a bundled-runtime version named in two or more OPEN
    # issues filed within the last 7 days. Two, not one, because a single
    # report is a report; a pattern is what justifies refusing every version
    # from that point on.
    my (%rt_count, %rt_min_version);
    my $week = time - 7 * 86400;
    for my $i (values %{ $istore->{issues} || {} }) {
        next unless ($i->{state} // 'open') eq 'open';
        my $rt = $i->{runtime} or next;
        my $at = iso_to_epoch($i->{created_at}) // 0;
        next unless $at >= $week;
        $rt_count{$rt}++;
        for my $v (@{ $i->{versions} || [] }) {
            $rt_min_version{$rt} = $v
                if !defined $rt_min_version{$rt} || vcmp($v, $rt_min_version{$rt}) < 0;
        }
    }
    my @clusters;
    for my $rt (sort keys %rt_count) {
        next unless $rt_count{$rt} >= 2 && defined $rt_min_version{$rt};
        push @clusters, { runtime => $rt, reports => $rt_count{$rt},
                          from_version => $rt_min_version{$rt} };
    }

    # Index issues by the versions they name, so a candidate can carry its own.
    my %by_version;
    for my $i (values %{ $istore->{issues} || {} }) {
        next unless ($i->{state} // 'open') eq 'open';
        push @{ $by_version{$_} }, $i for @{ $i->{versions} || [] };
    }

    my @rows;
    for my $v (@cand) {
        my $rec  = $vstore->{versions}{$v};

        # Date precedence: the Releases API's exact timestamp, then the
        # published changelog's day. Midday UTC for the day-only form, so a
        # version dated "today" cannot read as 0.0 or 1.0 days old depending on
        # which side of midnight the run happens to fall.
        my ($pub, $dsrc) = ($rec->{published_at}, 'releases-api');
        if (!defined $pub && defined $rec->{docs_date}) {
            $pub  = "$rec->{docs_date}T12:00:00Z";
            $dsrc = 'docs-changelog';
        }
        $dsrc = undef unless defined $pub;

        my $age  = defined $pub ? (time - (iso_to_epoch($pub) // time)) : undef;
        my $days = defined $age ? sprintf('%.1f', $age / 86400) + 0 : undef;
        # Either changelog will do for the bullets; they agree, and the
        # cross-check above is what says so rather than an assumption here.
        my $bul  = ($rec->{changelog_bullets} && @{ $rec->{changelog_bullets} })
                   ? $rec->{changelog_bullets} : $rec->{docs_bullets};

        my (@why, $risk);
        if (!$bul || !@$bul)              { $risk = 'NO_CHANGELOG'; push @why, 'no published changelog entry' }
        elsif (!defined $age)             { $risk = 'UNKNOWN';      push @why, 'no publish date available' }
        elsif ($age < 48 * 3600)          { $risk = 'HIGH';         push @why, 'less than 48h old, no track record yet' }
        elsif ($age < 7 * 86400)          { $risk = 'MEDIUM';       push @why, 'less than 7 days old' }
        else                              { $risk = 'LOW';          push @why, 'more than 7 days old' }

        my @iss = map { { number => $_->{number}, title => $_->{title},
                          created_at => $_->{created_at}, reactions => $_->{reactions},
                          platforms => $_->{platforms} } }
                  sort { ($b->{reactions} // 0) <=> ($a->{reactions} // 0) }
                  @{ $by_version{$v} || [] };

        # OPEN REPORTS MUST MOVE THE BAND, not merely annotate it. The first cut
        # of this left the band on age alone, so 2.1.243 -- blamed by a dozen
        # open segfault reports -- displayed 'LOW' next to a version with none.
        # It was excluded from the recommendation, but the operator reads the
        # table, and a table that calls that LOW is lying to them.
        my $worst = 0;
        $worst = $_->{reactions} // 0 for grep { ($_->{reactions} // 0) > $worst } @iss;
        if (@iss) {
            my $floor = (@iss >= 5 || $worst >= 5) ? 'HIGH' : 'MEDIUM';
            $risk = raise_risk($risk, $floor);
            push @why, scalar(@iss) . ' open issue(s) blame this version'
                     . ($worst ? " (top report has $worst reaction(s))" : '');
        }

        # The cluster override sits last: it outranks everything above it.
        for my $c (@clusters) {
            next unless vcmp($v, $c->{from_version}) >= 0;
            $risk = 'RUNTIME_RISK';
            push @why, "at or above $c->{from_version}, the lowest version in an active "
                     . "$c->{reports}-report Bun $c->{runtime} crash cluster";
        }

        push @rows, {
            version        => $v,
            published_at   => $pub,
            date_source    => $dsrc,
            age_days       => $days,
            risk           => $risk,
            risk_reasons   => \@why,
            bullet_count   => ($bul ? scalar @$bul : 0),
            bullets        => $bul || [],
            issues         => \@iss,
        };
    }

    # Recommendation: newest that is LOW, names no open issue, and sits below
    # every runtime cluster. Deliberately conservative -- this picks what to
    # SUGGEST; the operator still sees every row and can take any of them.
    my ($rec_v, $rec_why);
    for my $r (@rows) {
        next unless $r->{risk} eq 'LOW';
        next if @{ $r->{issues} };
        $rec_v   = $r->{version};
        $rec_why = "newest version over 7 days old with no open issue naming it"
                 . (@clusters ? ', and below every active runtime crash cluster' : '');
        last;
    }
    unless (defined $rec_v) {
        $rec_why = 'nothing qualifies: every candidate is either too new, names an open '
                 . 'issue, or falls inside a runtime crash cluster. Staying put is defensible.';
    }

    return {
        current_version => $current,
        latest_version  => $latest,
        versions_behind => scalar @rows,
        candidates      => \@rows,
        runtime_clusters=> \@clusters,
        recommendation  => { version => $rec_v, why => $rec_why },
        warnings        => $warnings,
        generated_at    => now_iso(),
    };
}

# ---------------------------------------------------------------------------
# decisions
# ---------------------------------------------------------------------------

sub read_decisions {
    my ($p, $limit) = @_;
    my $raw = read_file_raw($p);
    return [] unless defined $raw && length $raw;
    my @out;
    for my $line (reverse split /\r?\n/, $raw) {
        next unless $line =~ /\S/;
        my $d = eval { JSON::PP->new->decode($line) } or next;
        push @out, $d;
        last if defined $limit && @out >= $limit;
    }
    return \@out;
}

sub cmd_record_decision {
    my (@argv) = @_;
    my ($to, $from, $action, $reason) = (undef, undef, undef, undef);
    GetOptionsFromArray(\@argv,
        'to=s' => \$to, 'from=s' => \$from, 'action=s' => \$action, 'reason=s' => \$reason,
    ) or bail('bad arguments to record-decision');
    bail('--action is required (installed|declined|deferred)')
        unless defined $action && $action =~ /^(installed|declined|deferred)$/;

    my $S = store_paths() or bail('cannot determine home directory');
    make_path($S->{root}) unless -d $S->{root};

    my $rec = { at => now_iso(), action => $action, to => $to, from => $from, reason => $reason };
    my $line = JSON::PP->new->canonical(1)->encode($rec);
    open my $fh, '>>:raw', $S->{decisions} or bail("cannot append to $S->{decisions}");
    print {$fh} "$line\n";
    close $fh;

    # A decision is the most valuable thing in the store and the cheapest to
    # lose, so it is pushed as soon as it is made rather than waiting for the
    # next gather.
    my $s = do_sync("steward: record update decision ($action)");
    json_out({ ok => JSON::PP::true, recorded => $rec, store => $S->{root},
               sync => { synced => ($s->{synced} ? JSON::PP::true : JSON::PP::false),
                         pushed => ($s->{pushed} ? JSON::PP::true : JSON::PP::false),
                         reason => $s->{reason}, error => $s->{error} } });
    return 0;
}

sub cmd_history {
    my (@argv) = @_;
    my $limit = 20;
    GetOptionsFromArray(\@argv, 'limit=i' => \$limit) or bail('bad arguments to history');
    my $S = store_paths() or bail('cannot determine home directory');
    json_out({ ok => JSON::PP::true, store => $S->{root},
               decisions => read_decisions($S->{decisions}, $limit) });
    return 0;
}

# ---------------------------------------------------------------------------
# status / prune / sync
# ---------------------------------------------------------------------------

sub cmd_status {
    my $S = store_paths() or bail('cannot determine home directory');
    my $v = read_json_file($S->{versions});
    my $i = read_json_file($S->{issues});
    my $iage = ($i && $i->{fetched_at}) ? (time - (iso_to_epoch($i->{fetched_at}) // 0)) : undef;
    json_out({
        ok             => JSON::PP::true,
        store          => $S->{root},
        store_in_vault => $S->{in_vault} ? JSON::PP::true : JSON::PP::false,
        exists         => (-d $S->{root} ? JSON::PP::true : JSON::PP::false),
        versions_known => ($v ? scalar keys %{ $v->{versions} || {} } : 0),
        versions_updated_at => ($v ? $v->{updated_at} : undef),
        issues_known   => ($i ? scalar keys %{ $i->{issues} || {} } : 0),
        issues_age_hours => (defined $iage ? int($iage / 3600) : undef),
        issues_stale   => ((!defined $iage || $iage >= $ISSUE_TTL) ? JSON::PP::true : JSON::PP::false),
        decisions      => scalar @{ read_decisions($S->{decisions}, undef) },
        http_mode      => http_mode(),
    });
    return 0;
}

# prune -- the earlier attempt wrote a timestamped copy of the 3.6 MB rendered
# changelog on EVERY run and never removed one; 48 MB of it was still on this
# machine months later. Nothing reads those files now.
sub cmd_prune {
    my (@argv) = @_;
    my $apply = 0;
    GetOptionsFromArray(\@argv, 'apply' => \$apply) or bail('bad arguments to prune');
    my $S = store_paths() or bail('cannot determine home directory');
    my $home = $S->{home};

    my @stale;
    for my $dir ("$home/.claude/cache/update-research",
                 "$home/.claude/cache/update-tmp",
                 "$home/.claude/cache/update-bootstrap-tmp") {
        next unless -d $dir;
        opendir(my $dh, $dir) or next;
        for my $f (readdir $dh) {
            next if $f eq '.' || $f eq '..';
            next if $dir eq $S->{root} && $f =~ /^(versions|issues)\.json$|^decisions\.jsonl$/;
            my $p = "$dir/$f";
            next unless -f $p;
            next unless $f =~ /^(changelog-|gather-)/;
            push @stale, { path => $p, bytes => (-s $p) // 0 };
        }
        closedir $dh;
    }
    my $bytes = 0; $bytes += $_->{bytes} for @stale;
    my $removed = 0;
    if ($apply) { for my $s (@stale) { $removed++ if unlink $s->{path} } }

    json_out({ ok => JSON::PP::true, applied => ($apply ? JSON::PP::true : JSON::PP::false),
               candidates => scalar @stale, bytes => $bytes, removed => $removed,
               files => [ map { $_->{path} } @stale[0 .. ($#stale > 19 ? 19 : $#stale)] ] });
    return 0;
}

# git_path -- POSIX path to something native git.exe can actually open.
#
# This file sets MSYS2_ARG_CONV_EXCL=* (see the top), which switches OFF the
# implicit MSYS translation. That is required so URLs containing "https:" reach
# curl intact -- but it means every path we hand a native binary must be
# translated by US. The CLAUDE.md rule is explicit that the opt-out and the
# translation are one technique and splitting them is the bug.
#
# The `/c/... -> C:/...` rule alone is NOT enough, and the gap is not
# theoretical: a File::Temp dir is `/tmp/xxx`, which that rule leaves untouched.
# Windows then resolves the leading slash against the current drive, and git
# either fails or -- worse -- creates `C:\tmp\...`. That is the documented
# drive-root stray bug that once left 576 entries at this machine's root.
#
# cygpath knows the real mount table (/tmp, /c, and anything else), so ask it
# when it exists and keep the drive-letter rule only as a fallback.
my $CYGPATH;
sub git_path {
    my ($p) = @_;
    return $p unless $^O =~ /^(MSWin32|cygwin|msys)$/;
    return $p unless $p =~ m{^/};

    unless (defined $CYGPATH) {
        my $probe = `cygpath -w / 2>/dev/null`;
        $CYGPATH = ($? == 0 && defined $probe && $probe =~ /\S/) ? 1 : 0;
    }
    if ($CYGPATH) {
        my $w = `cygpath -m -- "$p" 2>/dev/null`;
        if ($? == 0 && defined $w) {
            chomp $w;
            return $w if $w =~ /\S/;
        }
    }
    $p =~ s{^/([a-zA-Z])/}{\u$1:/};
    return $p;
}

# sync -- commit and push ONLY the research dir. Scoped deliberately: the vault
# also holds projects/ and todos/, each owned by a different script, and a broad
# `git add -A` here would sweep another owner's half-finished work into this
# commit.
# do_sync -- the shared implementation, used by both the `sync` verb and the
# automatic sync that follows gather/record-decision. One code path, so the
# automatic and manual routes cannot drift apart.
sub do_sync {
    my ($msg) = @_;
    my $S = store_paths() or return { ok => 0, error => 'cannot determine home directory' };
    return { ok => 1, synced => 0, reason => 'store is not in a vault; nothing to sync' }
        unless $S->{in_vault};
    return VaultNamespace::sync(
        vault   => $S->{vault},
        path    => 'research/claude-code',
        message => (defined $msg && length $msg ? $msg : 'steward: update research'),
    );
}

sub cmd_sync {
    my (@argv) = @_;
    my $r = do_sync(shift @argv);
    my $S = store_paths();
    for my $k (qw(ok synced pushed)) {
        $r->{$k} = $r->{$k} ? JSON::PP::true : JSON::PP::false if exists $r->{$k};
    }
    $r->{store} = $S->{root} if $S;
    json_out($r);
    return $r->{ok} ? 0 : 1;
}

# ---------------------------------------------------------------------------

sub usage {
    json_out({ ok => JSON::PP::false, error => 'unknown subcommand',
               subcommands => [qw(status gather record-decision history sync prune)] });
    return 1;
}

my $cmd = shift @ARGV // 'status';
my %d = (
    'status'          => \&cmd_status,
    'gather'          => \&cmd_gather,
    'record-decision' => \&cmd_record_decision,
    'history'         => \&cmd_history,
    'sync'            => \&cmd_sync,
    'prune'           => \&cmd_prune,
);
exit(exists $d{$cmd} ? $d{$cmd}->(@ARGV) : usage());
