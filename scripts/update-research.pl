#!/usr/bin/env perl
# update-research.pl — Research script for /update skill
#
# Fetches public changelog (only to check which versions are listed there),
# GitHub releases (which carry the actual changelog content per version in `body`),
# and runs symptom + per-version issue searches against GitHub.
#
# Subcommands:
#   gather --current <V>          GitHub releases + public-changelog presence flag + ages
#   symptoms                       Six fixed symptom searches against GitHub issues
#   issues --versions V1,V2,...    Per-version issue search (paced for rate limit)

use strict;
use warnings;
use HTTP::Tiny;
use JSON::PP;
use File::Path qw(make_path);
use POSIX qw(strftime);

my $home = $ENV{HOME} // $ENV{USERPROFILE};
$home =~ s/\\/\//g;
my $CACHE_DIR = "$home/.claude/cache/update-research";

my $CHANGELOG_URL  = "https://code.claude.com/docs/en/changelog";
my $RELEASES_URL   = "https://api.github.com/repos/anthropics/claude-code/releases";
my $RELEASES_PER_PAGE = 100;
my $RELEASES_MAX_PAGES = 10;  # 10 * 100 = 1000 releases is a generous cap
my $ISSUES_API     = "https://api.github.com/search/issues";

my @SYMPTOM_QUERIES = (
    "stack overflow",
    "panic Bun",
    "illegal instruction",
    "segfault",
    "crashes on startup",
    "crash",
);

my $cmd = shift @ARGV // "help";

if    ($cmd eq "gather")   { cmd_gather()   }
elsif ($cmd eq "symptoms") { cmd_symptoms() }
elsif ($cmd eq "issues")   { cmd_issues()   }
else                       { cmd_help()     }

exit 0;

# ── Subcommands ──────────────────────────────────────────────────────

sub cmd_gather {
    my %args = parse_args(qw(--current));
    my $current = $args{"--current"} or emit_error("Usage: gather --current <V>");

    make_path($CACHE_DIR) unless -d $CACHE_DIR;
    my $ts = strftime("%Y%m%dT%H%M%SZ", gmtime);

    my (@warnings, @flags);

    # 1. Public changelog (HTML)
    my $changelog_path = "$CACHE_DIR/changelog-$ts.html";
    my ($cl_status, $cl_body) = http_get($CHANGELOG_URL);
    if ($cl_status != 200) {
        emit_error("Changelog fetch failed: HTTP $cl_status from $CHANGELOG_URL");
    }
    write_file($changelog_path, $cl_body);

    my %public_versions;
    while ($cl_body =~ /id="(\d+)-(\d+)-(\d+)"/g) {
        $public_versions{"$1.$2.$3"} = 1;
    }
    my $changelog_parsed = scalar keys %public_versions;
    push @warnings, "changelog_parsed_zero_versions" if $changelog_parsed == 0;

    # 2. GitHub releases (paginated until we've covered every release newer than --current)
    my $rel_result = fetch_releases_paginated($current);
    my $releases   = $rel_result->{releases};

    # Page-1 hard failure with no data — abort.
    if ($rel_result->{error} && @$releases == 0) {
        emit_error("Releases fetch failed: $rel_result->{error}");
    }
    # Page-2+ failure — keep partial data, warn loudly.
    if ($rel_result->{error}) {
        push @warnings, "releases_partial_fetch:" . $rel_result->{error};
    }

    my $releases_path = "$CACHE_DIR/releases-$ts.json";
    write_file($releases_path,
        JSON::PP->new->utf8->canonical->pretty->encode($releases));

    my $releases_parsed = scalar @$releases;
    push @warnings, "releases_parsed_zero" if $releases_parsed == 0;

    my $coverage_ok    = $rel_result->{coverage_ok};
    my $pages_fetched  = $rel_result->{pages_fetched};
    my $oldest_fetched = $rel_result->{oldest_fetched} // "";
    my $rel_status     = $rel_result->{status};

    if (!$coverage_ok && $releases_parsed > 0) {
        push @warnings,
            "coverage_incomplete:oldest_fetched=$oldest_fetched,current=$current,pages=$pages_fetched";
    }

    my $now_utc   = strftime("%Y-%m-%dT%H:%M:%SZ", gmtime);
    my $now_epoch = time;

    # 3. Build per-version entries newer than $current (from releases)
    my @newer;
    my %seen_release_versions;
    for my $rel (@$releases) {
        my $tag = $rel->{tag_name} // "";
        unless ($tag =~ /^v(\d+\.\d+\.\d+)$/) {
            push @warnings, "unparseable_tag:$tag";
            next;
        }
        my $version = $1;
        next unless version_newer($version, $current);

        my $published  = $rel->{published_at} // "";
        my $epoch      = parse_iso8601($published);
        my $age_secs   = defined($epoch) ? ($now_epoch - $epoch) : undef;
        my $risk       = "unknown";
        if (defined $age_secs) {
            if    ($age_secs < 48 * 3600)     { $risk = "HIGH"   }
            elsif ($age_secs < 7 * 86400)     { $risk = "MEDIUM" }
            else                              { $risk = "LOW"    }
        }

        my $has_pub = $public_versions{$version} ? 1 : 0;
        push @flags, "releases_only:$version" unless $has_pub;

        push @newer, {
            version              => $version,
            tag                  => $tag,
            published_at         => $published,
            age_seconds          => $age_secs,
            age_days             => defined($age_secs) ? int($age_secs / 86400) : undef,
            initial_risk         => $risk,
            has_release          => JSON::PP::true,
            has_public_changelog => $has_pub ? JSON::PP::true : JSON::PP::false,
            release_body         => $rel->{body} // "",
        };
        $seen_release_versions{$version} = 1;

        push @warnings, "unparseable_date:$version"
            if !defined($epoch) && length $published;
        push @warnings, "future_date:$version"
            if defined($age_secs) && $age_secs < -3600;
    }

    # 4. Versions in public changelog but not in releases (changelog-only)
    for my $v (sort keys %public_versions) {
        next unless version_newer($v, $current);
        next if $seen_release_versions{$v};
        push @flags, "changelog_only:$v";
        push @newer, {
            version              => $v,
            tag                  => "(no release)",
            published_at         => "",
            age_seconds          => undef,
            age_days             => undef,
            initial_risk         => "unknown",
            has_release          => JSON::PP::false,
            has_public_changelog => JSON::PP::true,
            release_body         => "",
        };
    }

    # 5. Sort descending by version
    @newer = sort { version_cmp($b->{version}, $a->{version}) } @newer;

    # 6. Sanity checks
    my $latest_observed = @newer ? $newer[0]->{version} : $current;
    push @warnings, "latest_older_than_current"
        if @newer && !version_newer($latest_observed, $current);

    # 7. Write JSON payload
    my $payload = {
        generated_at           => $now_utc,
        current_version        => $current,
        latest_observed        => $latest_observed,
        newer_versions         => \@newer,
        flags                  => \@flags,
        warnings               => \@warnings,
        coverage_ok            => $coverage_ok ? JSON::PP::true : JSON::PP::false,
        releases_pages_fetched => $pages_fetched,
        oldest_fetched_release => $oldest_fetched,
    };
    my $json_path = "$CACHE_DIR/gather-$ts.json";
    write_file($json_path, JSON::PP->new->utf8->canonical->pretty->encode($payload));

    # 8. Emit structured output
    emit("STATUS",                    "ok");
    emit("CHANGELOG_HTTP",            $cl_status);
    emit("CHANGELOG_PARSED_VERSIONS", $changelog_parsed);
    emit("RELEASES_HTTP",             $rel_status);
    emit("RELEASES_PARSED",           $releases_parsed);
    emit("RELEASES_PAGES_FETCHED",    $pages_fetched);
    emit("OLDEST_FETCHED_RELEASE",    $oldest_fetched);
    emit("COVERAGE_OK",               $coverage_ok ? "true" : "false");
    emit("DATE_NOW_UTC",              $now_utc);
    emit("CURRENT_VERSION",           $current);
    emit("LATEST_OBSERVED",           $latest_observed);
    emit("NEWER_VERSION_COUNT",       scalar @newer);
    emit("DATA_JSON_PATH",            $json_path);
    emit("RAW_CHANGELOG_PATH",        $changelog_path);
    emit("RAW_RELEASES_PATH",         $releases_path);
    emit("FLAGS",                     scalar(@flags)   ? join(", ", @flags)    : "(none)");
    emit("WARNINGS",                  scalar(@warnings) ? join(", ", @warnings) : "(none)");
}

sub cmd_symptoms {
    make_path($CACHE_DIR) unless -d $CACHE_DIR;
    my $ts = strftime("%Y%m%dT%H%M%SZ", gmtime);

    my %results;
    my $partial = 0;
    my $rate_limited = 0;

    for my $q (@SYMPTOM_QUERIES) {
        my $query = "repo:anthropics/claude-code $q state:open";
        my $url   = "$ISSUES_API?q=" . url_encode($query)
                  . "&sort=created&order=desc&per_page=10";
        my ($status, $body, $headers) = http_get_with_headers($url);

        rate_limit_wait($headers);

        if ($status == 403) {
            $rate_limited++;
            $partial = 1;
            $results{$q} = { error => "rate_limited" };
            next;
        }
        if ($status != 200) {
            $partial = 1;
            $results{$q} = { error => "HTTP $status" };
            next;
        }
        my $j = eval { decode_json($body) };
        if ($@) {
            $partial = 1;
            $results{$q} = { error => "JSON parse: $@" };
            next;
        }

        my @hits;
        for my $i (@{ $j->{items} // [] }) {
            push @hits, {
                number     => $i->{number},
                title      => $i->{title},
                created_at => $i->{created_at},
                reactions  => $i->{reactions}{total_count} // 0,
                url        => $i->{html_url},
            };
        }
        $results{$q} = { total => $j->{total_count}, hits => \@hits };
    }

    my $json_path = "$CACHE_DIR/symptoms-$ts.json";
    write_file($json_path, JSON::PP->new->utf8->canonical->pretty->encode(\%results));

    emit("STATUS",         $partial ? "partial" : "ok");
    emit("QUERIES_RUN",    scalar @SYMPTOM_QUERIES);
    emit("RATE_LIMITED",   $rate_limited);
    emit("DATA_JSON_PATH", $json_path);
}

sub cmd_issues {
    my %args = parse_args(qw(--versions));
    my $versions_str = $args{"--versions"}
        or emit_error("Usage: issues --versions V1,V2,...");
    my @versions = grep { length } split /\s*,\s*/, $versions_str;
    emit_error("No versions provided") unless @versions;

    make_path($CACHE_DIR) unless -d $CACHE_DIR;
    my $ts = strftime("%Y%m%dT%H%M%SZ", gmtime);

    my %results;
    my $partial      = 0;
    my $rate_limited = 0;
    my $searched     = 0;

    for my $v (@versions) {
        $searched++;
        my $query = qq{repo:anthropics/claude-code "$v" state:open};
        my $url   = "$ISSUES_API?q=" . url_encode($query)
                  . "&sort=reactions&order=desc&per_page=10";
        my ($status, $body, $headers) = http_get_with_headers($url);

        rate_limit_wait($headers);

        if ($status == 403) {
            $rate_limited++;
            $partial = 1;
            $results{$v} = { error => "rate_limited" };
            next;
        }
        if ($status != 200) {
            $partial = 1;
            $results{$v} = { error => "HTTP $status" };
            next;
        }
        my $j = eval { decode_json($body) };
        if ($@) {
            $partial = 1;
            $results{$v} = { error => "JSON parse: $@" };
            next;
        }

        my @hits;
        for my $i (@{ $j->{items} // [] }) {
            push @hits, {
                number     => $i->{number},
                title      => $i->{title},
                created_at => $i->{created_at},
                reactions  => $i->{reactions}{total_count} // 0,
                url        => $i->{html_url},
            };
        }
        $results{$v} = { total => $j->{total_count}, hits => \@hits };
    }

    my $json_path = "$CACHE_DIR/issues-$ts.json";
    write_file($json_path, JSON::PP->new->utf8->canonical->pretty->encode(\%results));

    emit("STATUS",         $partial ? "partial" : "ok");
    emit("SEARCHED",       $searched);
    emit("RATE_LIMITED",   $rate_limited);
    emit("DATA_JSON_PATH", $json_path);
}

sub cmd_help {
    print "Usage: update-research.pl <command> [args]\n\n";
    print "Commands:\n";
    print "  gather --current <V>          Fetch changelog + releases + ages\n";
    print "  symptoms                      Six fixed symptom searches\n";
    print "  issues --versions V1,V2,...   Per-version issue search (rate-limit paced)\n";
}

# ── Helpers ──────────────────────────────────────────────────────────

sub emit {
    my ($k, $v) = @_;
    $v //= "";
    print "$k: $v\n";
}

sub emit_error {
    my $msg = shift;
    emit("STATUS", "error");
    emit("ERROR",  $msg);
    exit 1;
}

sub parse_args {
    my %valid = map { $_ => 1 } @_;
    my (%got, @rest);
    while (defined(my $arg = shift @ARGV)) {
        if ($valid{$arg}) {
            $got{$arg} = shift @ARGV;
        } else {
            push @rest, $arg;
        }
    }
    @ARGV = @rest;
    return %got;
}

sub http_get {
    my $url = shift;
    my $ua  = HTTP::Tiny->new(timeout => 30, agent => "ccpraxis-update/1.0");
    my $res = $ua->get($url);
    return ($res->{status}, $res->{content} // "");
}

# Paginates GitHub releases endpoint until we've fetched a release older than
# (or equal to) $current, or we hit a hard stop (empty page, short page, error,
# or the page cap). Returns a hashref:
#   status         => HTTP status of the last fetched page
#   releases       => arrayref of parsed release records (flattened across pages)
#   pages_fetched  => integer count of pages actually fetched
#   coverage_ok    => 1 if we know we covered every release newer than $current
#   oldest_fetched => oldest parseable version we saw (across all pages), or undef
#   error          => string describing first error encountered, or undef
sub fetch_releases_paginated {
    my ($current) = @_;
    my @all;
    my $coverage_ok   = 0;
    my $pages_fetched = 0;
    my $last_status   = 0;
    my $error;

    for my $page (1 .. $RELEASES_MAX_PAGES) {
        my $url = "$RELEASES_URL?per_page=$RELEASES_PER_PAGE&page=$page";
        my ($status, $body) = http_get($url);
        $last_status = $status;
        if ($status != 200) {
            $error = "HTTP $status on page $page";
            last;
        }
        my $page_releases = eval { decode_json($body) };
        if ($@ || ref($page_releases) ne "ARRAY") {
            $error = "JSON parse failed on page $page: $@";
            last;
        }
        push @all, @$page_releases;
        $pages_fetched++;

        # Empty page => we've reached the end of all releases.
        if (@$page_releases == 0) {
            $coverage_ok = 1;
            last;
        }

        # If this page already contains a release at or below $current, we've
        # covered everything newer — stop early.
        my $oldest_on_page;
        for my $r (@$page_releases) {
            my $tag = $r->{tag_name} // "";
            next unless $tag =~ /^v(\d+\.\d+\.\d+)$/;
            $oldest_on_page = $1
                if !defined($oldest_on_page) || version_cmp($1, $oldest_on_page) < 0;
        }
        if (defined $oldest_on_page && version_cmp($oldest_on_page, $current) <= 0) {
            $coverage_ok = 1;
            last;
        }

        # Less than a full page => no more releases to fetch.
        if (@$page_releases < $RELEASES_PER_PAGE) {
            $coverage_ok = 1;
            last;
        }
    }

    # Compute oldest fetched across all pages (for coverage diagnostics + the
    # belt-and-suspenders coverage check below).
    my $overall_oldest;
    for my $r (@all) {
        my $tag = $r->{tag_name} // "";
        next unless $tag =~ /^v(\d+\.\d+\.\d+)$/;
        $overall_oldest = $1
            if !defined($overall_oldest) || version_cmp($1, $overall_oldest) < 0;
    }
    if (defined $overall_oldest && version_cmp($overall_oldest, $current) <= 0) {
        $coverage_ok = 1;
    }

    return {
        status         => $last_status,
        releases       => \@all,
        pages_fetched  => $pages_fetched,
        coverage_ok    => $coverage_ok,
        oldest_fetched => $overall_oldest,
        error          => $error,
    };
}

sub http_get_with_headers {
    my $url = shift;
    my $ua  = HTTP::Tiny->new(timeout => 30, agent => "ccpraxis-update/1.0");
    my $res = $ua->get($url);
    # HTTP::Tiny lowercases header names
    return ($res->{status}, $res->{content} // "", $res->{headers} // {});
}

sub rate_limit_wait {
    my $headers = shift // {};
    my $remaining = $headers->{"x-ratelimit-remaining"};
    my $reset     = $headers->{"x-ratelimit-reset"};
    return unless defined $remaining;
    return if $remaining > 1;
    return unless $reset && $reset =~ /^\d+$/;
    my $wait = $reset - time + 2;
    if ($wait > 0 && $wait <= 75) {
        sleep $wait;
    }
}

sub write_file {
    my ($path, $content) = @_;
    open my $fh, ">:raw", $path or die "Cannot write $path: $!\n";
    print $fh $content;
    close $fh;
}

sub url_encode {
    my $s = shift;
    $s =~ s/([^A-Za-z0-9\-._~])/sprintf("%%%02X", ord($1))/ge;
    return $s;
}

sub parse_iso8601 {
    my $ts = shift // "";
    return undef unless $ts =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:Z|[+\-]\d{2}:?\d{2})?$/;
    my ($y, $mo, $d, $h, $mi, $s) = ($1, $2, $3, $4, $5, $6);
    require Time::Local;
    my $epoch = eval { Time::Local::timegm($s, $mi, $h, $d, $mo - 1, $y - 1900) };
    return $@ ? undef : $epoch;
}

# Returns ( [major, minor, patch] ) tuple from "X.Y.Z"
sub _parts {
    my $v = shift;
    return [ $v =~ /^(\d+)\.(\d+)\.(\d+)$/ ];
}

sub version_cmp {
    my ($a, $b) = @_;
    my @ap = @{ _parts($a) };
    my @bp = @{ _parts($b) };
    for my $i (0 .. 2) {
        my $diff = ($ap[$i] // 0) <=> ($bp[$i] // 0);
        return $diff if $diff != 0;
    }
    return 0;
}

sub version_newer {
    my ($a, $b) = @_;
    return version_cmp($a, $b) > 0;
}
