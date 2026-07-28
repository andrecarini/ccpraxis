#!/usr/bin/env perl
# bp-deps-check.pl — deterministic dependency/version-policy classifier (Decisions #4, #11, #12, #14).
#
# Given a project dir, classifies violations of the version policy — latest
# LTS/stable, >=7 days old, mutually compatible, never EOL, and declared in the
# backpack — into BLOCK (unambiguous + mechanically fixable) and WARN (a
# judgment call needing a written justification).
#
# It ONLY classifies. It never pauses, never prompts, never fixes: BLOCKs are
# ingested by the b05 conformance verdict and auto-remediated by the b07 engine
# (Decisions #20/#22); WARNs go to the end-of-run review.
#
# INVARIANT — no BLOCK may ever originate from this script's own inability to
# determine something. Offline, timeout, unreachable registry, absent git and
# malformed registry JSON all degrade to WARN. A gate that manufactures a BLOCK
# out of a network outage would halt a fleet for no reason.
#
# Usage:
#   perl bp-deps-check.pl --project=<dir> [--backpack=<path>] [--out=<path>]
#                         [--now=<ISO8601|epoch>] [--offline] [--quiet]
# Exit: 0 = no BLOCK findings (WARNs permitted); 2 = at least one BLOCK
#       (Decision #14 — a classification RESULT, not a crash); 1 = usage or
#       internal error.
#
# require:  require "<path>/bp-deps-check.pl";
#           my ($report,$rc) = BpDepsCheck::run({ project=>$d, now=>$epoch, http=>$stub });

package BpDepsCheck;
use strict;
use warnings;
use FindBin qw($Bin);
use JSON::PP;
use File::Basename qw(dirname);
use File::Spec;
use Time::Local qw(timegm);

# ---- EOL table (Decision #11: bundled, deterministic, offline-safe) --------
# Verified live against endoflife.date on 2026-07-25. Refreshing this table is
# OPTIONAL and must NEVER be required at gate time.
#
# We store EOL *dates*, not an is_eol flag, on purpose: the injected clock then
# drives the EOL verdict, so the table cannot rot into a lie as time passes and
# criterion (a) stays deterministic under a fixed reference date.
our %EOL = (
    node => {
        '16' => { eol => '2023-09-11', lts => '2021-10-26' },
        '18' => { eol => '2025-04-30', lts => '2022-10-25' },
        '20' => { eol => '2026-04-30', lts => '2023-10-24' },
        '21' => { eol => '2024-06-01', lts => undef },
        '22' => { eol => '2027-04-30', lts => '2024-10-29' },
        '23' => { eol => '2025-06-01', lts => undef },
        '24' => { eol => '2028-04-30', lts => '2025-10-28' },
        '25' => { eol => '2026-06-01', lts => undef },
        '26' => { eol => '2029-04-30', lts => '2026-10-28' },
    },
    python => {
        '3.8'  => { eol => '2024-10-07', lts => undef },
        '3.9'  => { eol => '2025-10-31', lts => undef },
        '3.10' => { eol => '2026-10-31', lts => undef },
        '3.11' => { eol => '2027-10-31', lts => undef },
        '3.12' => { eol => '2028-10-31', lts => undef },
        '3.13' => { eol => '2029-10-31', lts => undef },
        '3.14' => { eol => '2030-10-31', lts => undef },
    },
);

our $FRESH_DAYS = 7;    # Decision #4: a selection younger than this needs justification

# Hard ceiling on registry round-trips per run. Each npm lookup pulls a FULL
# packument (megabytes for popular packages), so an uncapped manifest could pull
# gigabytes on a gate that runs for every package. Exceeding it is reported as a
# publish_age_truncated WARN -- never silently.
our $MAX_REGISTRY_LOOKUPS = 50;

# ---- pure helpers (unit-tested directly, no I/O) --------------------------

# parse_iso8601($str) -> epoch | undef. Tolerates a bare epoch, a date-only
# string, and FRACTIONAL seconds of any precision -- npm emits ".796Z" and PyPI
# ".443000Z", so a \d{2}:\d{2}:\d{2}Z$ parser breaks on both registries.
sub parse_iso8601 {
    my ($s) = @_;
    return undef unless defined $s;
    $s =~ s/^\s+|\s+$//g;
    return $s + 0 if $s =~ /^\d{9,}$/;
    if ($s =~ /^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2}):(\d{2})(?:\.\d+)?)?\s*(?:Z|UTC)?$/) {
        my ($Y,$M,$D,$h,$mi,$se) = ($1,$2,$3, $4 // 0, $5 // 0, $6 // 0);
        my $e = eval { timegm($se,$mi,$h,$D,$M-1,$Y) };
        return defined $e ? $e : undef;
    }
    return undef;
}

sub iso_of {
    my ($epoch) = @_;
    my @t = gmtime($epoch);
    sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ", $t[5]+1900,$t[4]+1,$t[3],$t[2],$t[1],$t[0];
}

# normalize_runtime($name) -> canonical runtime id.
# Strips a trailing version suffix so the backpack's "node22" (the DAME item,
# filed under category curl-script) still resolves to "node". Matching is by
# NAME, never by category -- backpack v2 has no runtime category at all.
sub normalize_runtime {
    my ($n) = @_;
    return undef unless defined $n && length $n;
    my $s = lc $n;
    $s =~ s/^\s+|\s+$//g;
    $s =~ s/[-_ ]?v?\d[\d.]*$//;
    $s =~ s/[-_ ]+$//;
    return 'node'   if $s =~ /^(?:node|nodejs)$/;
    return 'python' if $s =~ /^(?:python|py)$/;
    return length($s) ? $s : undef;
}

# major_of($runtime,$raw) -> table key | undef. "v20.11.1"/">=20"/"20.x" -> 20;
# "3.12.4"/">=3.11" -> 3.11 (python keys are major.minor).
sub major_of {
    my ($runtime, $raw) = @_;
    return undef unless defined $raw && !ref $raw;
    return undef unless $raw =~ /(\d+(?:\.\d+)?)/;
    my $v = $1;
    if (($runtime // '') eq 'python') {
        return undef unless $v =~ /^(\d+)\.(\d+)/;
        # strip leading zeros: the table is string-keyed, so "03.09" must find
        # the "3.9" row rather than silently missing it and reading as 'unknown'
        return sprintf('%d.%d', $1, $2);
    }
    return undef unless $v =~ /^(\d+)/;
    return sprintf('%d', $1);          # "020" -> "20", not a table miss
}

# Percent-encode one URL path segment (RFC 3986 unreserved set kept as-is).
sub _uri_escape_segment {
    my ($s) = @_;
    $s = '' unless defined $s && !ref $s;
    $s =~ s{([^A-Za-z0-9\-._~])}{sprintf('%%%02X', ord($1))}ge;
    return $s;
}

# is_open_lower_bound($raw) -> bool. True for ">=20", "> 3.8", ">=3.8,!=3.9" --
# an OPEN MINIMUM, with no upper bound.
#
# WHY THIS EXISTS: `engines.node: ">=20"` and `requires-python = ">=3.8"` declare
# the OLDEST version a project SUPPORTS -- they are not the version it RUNS. If
# the floor is read as the selection, the single most common line in Python
# packaging (`requires-python = ">=3.8"`) produces an eol_runtime BLOCK on a
# project actually running 3.13 -- and per Decision #22 b07 then auto-bumps a
# correct manifest with no human in the loop. So an open floor is NOT a version
# selection and must not be EOL-judged at all.
#
# A bounded range (">=3.9,<4", "^20", "~20.1") DOES pin a line and keeps normal
# handling, as do .nvmrc / .node-version / .python-version, which are true
# selections.
sub is_open_lower_bound {
    my ($raw) = @_;
    return 0 unless defined $raw && !ref $raw;
    my $s = $raw;
    $s =~ s/^\s+|\s+$//g;
    return 0 unless $s =~ /^>=?\s*\d/;   # must start with an open minimum
    return 0 if $s =~ /</;               # an upper bound makes it a bounded range
    return 1;
}

# _latest_lts($runtime,$now) -> the newest release line that IS already LTS and
# is NOT yet EOL at $now. This is the "clear LTS successor" b07 needs (SYN-6).
sub _latest_lts {
    my ($runtime, $now) = @_;
    my $tbl = $EOL{$runtime} or return undef;
    my ($best, $best_lts);
    for my $maj (sort keys %$tbl) {
        my $e = $tbl->{$maj};
        next unless defined $e->{lts};
        my $lts = parse_iso8601($e->{lts});
        my $eol = parse_iso8601($e->{eol});
        next unless defined $lts && defined $eol;
        next if $lts > $now;     # not LTS yet
        next if $eol <= $now;    # already EOL
        if (!defined $best_lts || $lts > $best_lts) { ($best, $best_lts) = ($maj, $lts); }
    }
    return $best;
}

# eol_status($runtime,$major,$now) -> ('eol'|'ok'|'unknown', $eol_date, $successor)
sub eol_status {
    my ($runtime, $major, $now) = @_;
    return ('unknown', undef, undef) unless defined $runtime && defined $major;
    my $tbl = $EOL{$runtime}    or return ('unknown', undef, undef);
    my $ent = $tbl->{$major}    or return ('unknown', undef, undef);
    my $eol = parse_iso8601($ent->{eol});
    my $successor = _latest_lts($runtime, $now);
    return ('unknown', $ent->{eol}, $successor) unless defined $eol;
    return ($eol <= $now ? 'eol' : 'ok'), $ent->{eol}, $successor;
}

# is_declared(\@items,$runtime) -> bool. NAME-based, never category-based.
sub is_declared {
    my ($items, $runtime) = @_;
    return 0 unless ref $items eq 'ARRAY' && defined $runtime;
    for my $it (@$items) {
        next unless ref $it eq 'HASH' && defined $it->{name};
        my $norm = normalize_runtime($it->{name});
        return 1 if defined $norm && $norm eq $runtime;
    }
    return 0;
}

sub age_days {
    my ($published, $now) = @_;
    return undef unless defined $published && defined $now;
    return ($now - $published) / 86400;
}

# ---- finding construction -------------------------------------------------

sub _finding {
    my (%f) = @_;
    my $warn = ($f{severity} // 'warn') eq 'warn';
    return {
        kind                => $f{kind},
        severity            => $f{severity},
        subject             => $f{subject},
        detail              => $f{detail},
        evidence            => $f{evidence} || {},
        remedy              => $f{remedy}   || { action => 'none' },
        needs_justification => $warn ? JSON::PP::true : JSON::PP::false,
    };
}

# ---- small I/O helpers ----------------------------------------------------

our $MAX_READ_BYTES = 8 * 1024 * 1024;    # generous for every file this script reads

# _slurp($path) -> raw bytes | undef.
#
# HARDENED: reads only a REGULAR file, and only up to $MAX_READ_BYTES. Every
# path reaching here is selected by -e, which is ALSO true for FIFOs, character
# devices, and symlinks to them. An unbounded slurp of a FIFO hangs the gate
# forever; one of /dev/zero exhausts container RAM and takes other fleet
# processes with it. Both then die by signal (124/137) or by perl's UNCATCHABLE
# "Out of memory!" -- i.e. nonzero-but-not-2 with no report written, which
# Decision #14 makes b05 misread as a BLOCK. The eval guards elsewhere cannot
# catch a hang or a signal, so this has to be prevented here, at the read.
# -f kills the FIFO/device class; the size cap kills the sparse-file class.
sub _slurp {
    my ($path) = @_;
    return undef unless defined $path && -f $path;
    return undef if -s _ > $MAX_READ_BYTES;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

# _read_json($path) -> ($data, $error)
#   ($data, undef)  parsed fine
#   (undef, undef)  absent / unreadable        -- "there is nothing here"
#   (undef, $msg)   PRESENT but unparseable    -- "I could not determine"
#
# Those last two MUST stay distinguishable. Collapsing them into a bare undef is
# what let an unparseable package.json silently delete BOTH the EOL criterion
# and the publish-age criterion: the runtime was still detected, but with no
# version, so EOL read as 'unknown' and emitted nothing, and the dependency list
# came back empty so zero registry calls were made. The report was then
# byte-identical to a compliant project -- silence where §3.5 demands a WARN.
sub _read_json {
    my ($path) = @_;
    my $raw = _slurp($path);
    unless (defined $raw) {
        # CAREFUL: _slurp returns undef for BOTH "absent" and "present but I
        # refused to read it" (over the size cap, a FIFO/device, permission
        # denied). Collapsing those back into "absent" silently re-creates the
        # very hole this function was rewritten to close: an oversized or
        # irregular package.json would emit no manifest_unparseable WARN, so a
        # project pinning an EOL runtime would report CLEAN. If the path exists
        # at all, it is "could not determine", not "nothing here".
        return (undef, 'present but unreadable (over the size cap, not a regular file, or permission denied)')
            if defined $path && -e $path;
        return (undef, undef);
    }
    $raw =~ s/^\xEF\xBB\xBF//;                       # tolerate a UTF-8 BOM
    my $d = eval { JSON::PP->new->utf8->relaxed->decode($raw) };
    if ($@ || !defined $d) {
        my $e = $@ || 'unknown parse error';
        $e =~ s/\s+at\s+\S+\s+line\s+\d+.*\z//s;     # drop perl's file/line tail
        $e =~ s/\s+/ /g; $e =~ s/^\s+|\s+$//g;
        return (undef, (length $e ? $e : 'unparseable JSON'));
    }
    return ($d, undef);
}

# Atomic write: temp + rename, with the Windows unlink-then-rename fallback
# (mirrors backpack.pl). Returns 1 on success, 0 on failure.
sub _write_json_atomic {
    my ($path, $data) = @_;
    my $dir = dirname($path);
    unless (-d $dir) {
        require File::Path;
        eval { File::Path::make_path($dir) };
        return 0 unless -d $dir;
    }
    my $tmp = "$path.tmp.$$";
    open my $fh, '>:encoding(UTF-8)', $tmp or return 0;
    print {$fh} JSON::PP->new->canonical->pretty->encode($data);
    close $fh or return 0;
    unless (rename $tmp, $path) {
        unlink $path;
        unless (rename $tmp, $path) { unlink $tmp; return 0; }
    }
    return 1;
}

# ---- runtime detection ----------------------------------------------------

sub _detect_runtimes {
    my ($project) = @_;
    my %found;

    my @node_evidence = grep { -e "$project/$_" } qw(package.json .nvmrc .node-version);
    if (@node_evidence) {
        my ($ver, $src);
        for my $f (qw(.nvmrc .node-version)) {
            next unless -e "$project/$f";
            my $c = _slurp("$project/$f");
            next unless defined $c;
            $c =~ s/^\s+|\s+$//g;
            if (length $c) { ($ver, $src) = ($c, $f); last }
        }
        if (!defined $ver && -e "$project/package.json") {
            my ($pj) = _read_json("$project/package.json");
            if (ref $pj eq 'HASH' && ref $pj->{engines} eq 'HASH'
                && defined $pj->{engines}{node} && !ref $pj->{engines}{node}) {
                ($ver, $src) = ($pj->{engines}{node}, 'package.json:engines.node');
            }
        }
        $found{node} = { version => $ver, source => $src // $node_evidence[0],
                         floor => is_open_lower_bound($ver) };
    }

    my @py_evidence = grep { -e "$project/$_" } qw(pyproject.toml requirements.txt setup.py .python-version);
    if (@py_evidence) {
        my ($ver, $src);
        if (-e "$project/.python-version") {
            my $c = _slurp("$project/.python-version");
            if (defined $c) { $c =~ s/^\s+|\s+$//g; if (length $c) { ($ver,$src) = ($c, '.python-version') } }
        }
        if (!defined $ver && -e "$project/pyproject.toml") {
            my $c = _slurp("$project/pyproject.toml");
            if (defined $c && $c =~ /^\s*requires-python\s*=\s*["']([^"']+)["']/m) {
                ($ver, $src) = ($1, 'pyproject.toml:requires-python');
            }
        }
        $found{python} = { version => $ver, source => $src // $py_evidence[0],
                           floor => is_open_lower_bound($ver) };
    }

    return \%found;
}

# ---- lockfiles ------------------------------------------------------------

my @ECOSYSTEMS = (
    { id        => 'npm',
      manifests => [qw(package.json)],
      # npm-shrinkwrap.json is an OFFICIAL npm lockfile and bun ships its own;
      # omitting them raised a false lockfile_missing BLOCK on correctly-locked
      # projects, which b07 would then "remediate" by generating a redundant
      # second lockfile into a repo that was already fine.
      locks     => [qw(package-lock.json npm-shrinkwrap.json pnpm-lock.yaml
                       yarn.lock bun.lockb bun.lock)] },

    { id        => 'pip',
      # requirements.txt / setup.py are manifests in their own right. Keying the
      # check on pyproject.toml alone meant a requirements.txt-only project --
      # even one with entirely floating deps -- was never lockfile-checked at
      # all, silently exempting a whole ecosystem from criterion (d).
      manifests => [qw(pyproject.toml requirements.txt setup.py)],
      locks     => [qw(poetry.lock uv.lock Pipfile.lock)],
      # ...and requirements.txt only COUNTS as a lock when it actually pins
      # everything. Accepting it unconditionally let an unpinned file satisfy
      # the very requirement it fails to meet.
      conditional_locks => { 'requirements.txt' => \&_requirements_fully_pinned } },
);

# _requirements_fully_pinned($path) -> bool. True only if every requirement line
# carries an exact "==" pin. An empty file pins nothing, so it is NOT a lock.
sub _requirements_fully_pinned {
    my ($path) = @_;
    my $c = _slurp($path);
    return 0 unless defined $c;
    my $saw = 0;
    for my $line (split /\n/, $c) {
        $line =~ s/#.*$//;
        $line =~ s/^\s+|\s+$//g;
        next unless length $line;
        next if $line =~ /^-/;              # -r / -e / --hash continuation lines
        return 0 unless $line =~ /==/;      # one floating requirement disqualifies the file
        $saw = 1;
    }
    return $saw;
}

sub _default_git {
    return sub {
        my ($dir, @args) = @_;
        my @cmd = ('git', '-C', $dir, @args);
        # fork-exec (not the list-form open) so the child's STDERR can be muted:
        # on a non-git dir git writes "fatal: not a git repository" to STDERR,
        # which is an EXPECTED, handled case here (-> git_unavailable WARN), not
        # something to spray over a caller's console or a test run's output.
        my $pid = open(my $fh, '-|');
        return (undef, -1) unless defined $pid;      # fork failed
        unless ($pid) {                              # child
            open(STDERR, '>', File::Spec->devnull()) or close(STDERR);
            exec(@cmd);
            exit 127;                                # git missing
        }
        local $/;
        my $out = <$fh>;
        close $fh;
        return (defined $out ? $out : '', $? >> 8);
    };
}

# ---- registry lookups -----------------------------------------------------

sub _registry_publish {
    my ($http, $eco, $pkg, $ver) = @_;   # -> ($epoch, $err)
    my ($url, $extract);
    # Percent-encode the path segment. Scoped npm names ("@scope/name") contain
    # a '/' that would otherwise split the path and silently 404, leaving the
    # publish-age policy unenforced for every scoped package.
    my $epkg = _uri_escape_segment($pkg);
    if ($eco eq 'npm') {
        $url = "https://registry.npmjs.org/$epkg";
        $extract = sub {
            my ($d) = @_;
            return undef unless ref $d eq 'HASH' && ref $d->{time} eq 'HASH';
            return $d->{time}{$ver};
        };
    } else {
        $url = "https://pypi.org/pypi/$epkg/json";
        $extract = sub {
            my ($d) = @_;
            return undef unless ref $d eq 'HASH' && ref $d->{releases} eq 'HASH';
            my $r = $d->{releases}{$ver};
            return undef unless ref $r eq 'ARRAY' && @$r && ref $r->[0] eq 'HASH';
            return $r->[0]{upload_time_iso_8601} // $r->[0]{upload_time};
        };
    }

    # ref alone is not enough: an ARRAY/CODE/SCALAR ref passes `ref` and then
    # dies "Not a HASH reference" on the ->{} deref, turning a bad response into
    # a crash instead of the WARN §3.5 requires.
    my $res = eval { $http->('GET', $url, {}) };
    return (undef, 'transport error', 'transport-unavailable')
        if $@ || ref($res) ne 'HASH';

    my $status = $res->{status};
    $status = 0 unless defined $status && !ref $status && $status =~ /^\d+$/;
    return (undef, "registry returned status $status", "http-$status") if $status != 200;

    my $body = $res->{content};
    $body = '' unless defined $body && !ref $body;
    my $doc = eval { JSON::PP->new->utf8->decode($body) };
    return (undef, 'unparseable registry response', 'unparseable-response')
        if $@ || ref($doc) ne 'HASH';

    my $iso = eval { $extract->($doc) };
    return (undef, 'malformed registry document', 'unparseable-response') if $@;
    return (undef, "no publish date for $pkg\@$ver", 'no-publish-date')
        unless defined $iso && !ref $iso;
    my $epoch = parse_iso8601($iso);
    return (undef, "unparseable publish date '$iso'", 'unparseable-date')
        unless defined $epoch;
    return ($epoch, undef, undef);
}

sub _direct_deps {
    my ($project) = @_;   # -> [ {eco,name,version} ] -- EXACT pins only
    my @out;
    if (-e "$project/package.json") {
        my ($pj) = _read_json("$project/package.json");
        if (ref $pj eq 'HASH') {
            for my $sect (qw(dependencies devDependencies)) {
                next unless ref $pj->{$sect} eq 'HASH';
                for my $name (sort keys %{ $pj->{$sect} }) {
                    my $spec = $pj->{$sect}{$name};
                    next unless defined $spec && !ref $spec;
                    # exact pin only: "1.2.3" or "=1.2.3"; ranges are not a selection
                    next unless $spec =~ /^=?\s*(\d+\.\d+\.\d+(?:[-+][\w.]+)?)$/;
                    push @out, { eco => 'npm', name => $name, version => $1 };
                }
            }
        }
    }
    if (-e "$project/requirements.txt") {
        my $c = _slurp("$project/requirements.txt");
        if (defined $c) {
            for my $line (split /\n/, $c) {
                $line =~ s/#.*$//;
                $line =~ s/^\s+|\s+$//g;
                next unless length $line;
                next unless $line =~ /^([A-Za-z0-9_.\-]+)\s*==\s*([\w.\-]+)$/;
                push @out, { eco => 'pip', name => $1, version => $2 };
            }
        }
    }
    return \@out;
}

# ---- main -----------------------------------------------------------------

sub run {
    my ($opts) = @_;
    $opts ||= {};

    my $project = $opts->{project};
    return ({ error => 'no --project' }, 1) unless defined $project && -d $project;

    my $now  = defined $opts->{now} ? $opts->{now} : time;

    # Loading the transport must not be able to kill the gate. An unguarded
    # `require` here dies with $! == ENOENT, and perl turns that into EXIT 2 --
    # byte-identical to "found BLOCKs", which b05 reads as a policy FAIL. A
    # missing transport would then masquerade as a violation while writing no
    # report at all. Degrade to a status-0 fetcher instead: that is the same
    # path a network outage takes, so it surfaces as a registry_unavailable
    # WARN (the degradation invariant), not a phantom BLOCK.
    my $http = $opts->{http};
    unless ($http) {
        my $loaded = eval { require "$Bin/bp-http.pl"; 1 };
        $http = $loaded
            ? sub { BpHttp::request(@_) }
            : sub { { status => 0, content => 'bp-http.pl transport unavailable' } };
    }

    my $git = $opts->{git} || _default_git();

    my (@blocks, @warns);
    my $add = sub {
        my ($f) = @_;
        push @{ $f->{severity} eq 'block' ? \@blocks : \@warns }, $f;
    };

    # -- backpack ----------------------------------------------------------
    my $bp_path = $opts->{backpack};
    unless (defined $bp_path) {
        $bp_path = -e "$project/.claude/backpack.json"
            ? "$project/.claude/backpack.json"
            : (($ENV{HOME} // '') . '/.claude/backpack.json');
    }
    my ($bp, $bp_err) = _read_json($bp_path);
    my ($items, $bp_problem);
    if (!defined $bp) {
        $bp_problem = "backpack unreadable or absent at $bp_path";
    } elsif (ref $bp eq 'HASH' && ref $bp->{items} eq 'ARRAY') {
        $items = $bp->{items};
    } elsif (ref $bp eq 'HASH' && exists $bp->{tools}) {
        $bp_problem = "backpack is schema v1 (top-level 'tools'); v2 renamed it to 'items'";
    } else {
        $bp_problem = "backpack at $bp_path has no items[] array";
    }

    # -- unparseable manifests: "could not determine" must be AUDIBLE ------
    # A present-but-unparseable package.json used to sink without trace: the
    # runtime stayed detected but version-less (EOL -> 'unknown', no finding)
    # and the dependency list came back empty (no registry calls, no WARNs), so
    # the report was byte-identical to a compliant project. That silently
    # disabled done-criteria (a) and (c). §3.5 says degrade to WARN, not silence.
    for my $mf (qw(package.json)) {
        next unless -e "$project/$mf";
        my (undef, $err) = _read_json("$project/$mf");
        next unless defined $err;
        $add->(_finding(
            kind     => 'manifest_unparseable',
            severity => 'warn',
            subject  => $mf,
            detail   => "$mf is present but could not be parsed ($err); the EOL and "
                      . "publish-age checks could NOT be applied to it. This is unverified, not clean.",
            evidence => { file => $mf, parse_error => $err },
            remedy   => { action => 'none' },
        ));
    }

    # -- runtimes: EOL + declared ------------------------------------------
    my $runtimes = eval { _detect_runtimes($project) } || {};
    for my $rt (sort keys %$runtimes) {
        my $info  = $runtimes->{$rt};
        my $major = major_of($rt, $info->{version});

        my ($status, $eol_date, $successor) = eol_status($rt, $major, $now);

        # An open lower bound (">=20", ">=3.8") is a MINIMUM SUPPORTED version,
        # not the version in use -- judging it would BLOCK correct projects and
        # have b07 auto-bump them. Emit nothing rather than a WARN: virtually
        # every Python package carries `requires-python = ">=3.x"`, so warning
        # would flood the end-of-run review with non-findings.
        $status = 'unknown' if $status eq 'eol' && $info->{floor};
        if ($status eq 'eol') {
            $add->(_finding(
                kind     => 'eol_runtime',
                severity => 'block',
                subject  => "$rt\@$major",
                detail   => ucfirst($rt) . " $major reached end-of-life $eol_date, before the reference date "
                          . substr(iso_of($now), 0, 10) . ".",
                evidence => { source => $info->{source}, value => $info->{version} },
                remedy   => defined $successor
                    ? { action => 'bump_runtime', runtime => $rt, from => $major, to => $successor }
                    : { action => 'bump_runtime', runtime => $rt, from => $major },
            ));
        }

        if (defined $bp_problem) {
            $add->(_finding(
                kind     => 'undeclared_runtime',
                severity => 'block',
                subject  => $rt,
                detail   => "Cannot prove $rt is declared in the backpack: $bp_problem.",
                evidence => { source => $info->{source}, backpack => $bp_path },
                remedy   => { action => 'declare_backpack', runtime => $rt },
            ));
        } elsif (!is_declared($items, $rt)) {
            $add->(_finding(
                kind     => 'undeclared_runtime',
                severity => 'block',
                subject  => $rt,
                detail   => "$rt is used by this project but is not declared in the backpack; "
                          . "it will be absent after a container rebuild.",
                evidence => { source => $info->{source}, backpack => $bp_path },
                remedy   => { action => 'declare_backpack', runtime => $rt },
            ));
        }
    }

    # -- lockfiles ---------------------------------------------------------
    my $git_ok = 1;
    for my $eco (@ECOSYSTEMS) {
        my ($manifest) = grep { -e "$project/$_" } @{ $eco->{manifests} };
        next unless defined $manifest;

        # -f and non-zero size: a DIRECTORY named package-lock.json, or an empty
        # file, satisfied a bare -e while locking exactly nothing.
        my ($lock) = grep { -f "$project/$_" && -s "$project/$_" } @{ $eco->{locks} };

        unless (defined $lock) {
            for my $cl (sort keys %{ $eco->{conditional_locks} || {} }) {
                next unless -f "$project/$cl" && -s "$project/$cl";
                next unless $eco->{conditional_locks}{$cl}->("$project/$cl");
                $lock = $cl;
                last;
            }
        }

        unless (defined $lock) {
            my @accepted = @{ $eco->{locks} };
            my @cond     = sort keys %{ $eco->{conditional_locks} || {} };
            $add->(_finding(
                kind     => 'lockfile_missing',
                severity => 'block',
                subject  => $eco->{id},
                detail   => "$manifest is present but no usable lockfile was found (accepted: "
                          . join(', ', @accepted)
                          . (@cond ? "; or a fully '=='-pinned " . join('/', @cond) : '')
                          . "). An empty file or a directory does not count.",
                evidence => { manifest => $manifest, accepted => \@accepted },
                remedy   => { action => 'create_lockfile', ecosystem => $eco->{id} },
            ));
            next;
        }

        next unless $git_ok;

        # Establish that we are in a usable git repo BEFORE interpreting any
        # per-file git result. Skipping this is a trap: outside a repo,
        # `ls-files --error-unmatch` exits non-zero exactly as it does for an
        # untracked file, so "git can't tell me" would be misread as "this file
        # is untracked" -- manufacturing a BLOCK out of the checker's own
        # blindness, which §3.5 forbids outright.
        my ($probe_out, $probe_rc) = eval { $git->($project, 'rev-parse', '--git-dir') };
        if ($@ || !defined $probe_out || $probe_rc != 0) {
            $git_ok = 0;
            $add->(_finding(
                kind     => 'git_unavailable',
                severity => 'warn',
                subject  => $project,
                detail   => "Could not determine whether lockfiles are committed "
                          . "(not a git repository, or git unavailable); committed-state unverified.",
                evidence => { lockfile => $lock },
                remedy   => { action => 'none' },
            ));
            next;
        }

        # Now tracked-ness is meaningful. `git status --porcelain` prints
        # NOTHING for a gitignored file, indistinguishable from "committed and
        # clean" -- so a gitignored lockfile used to read as committed.
        # ls-files --error-unmatch answers the real question.
        my ($tracked_out, $tracked_rc) =
            eval { $git->($project, 'ls-files', '--error-unmatch', '--', $lock) };
        if ($@ || !defined $tracked_out) {
            $git_ok = 0;
            $add->(_finding(
                kind     => 'git_unavailable',
                severity => 'warn',
                subject  => $project,
                detail   => "Could not determine whether lockfiles are committed "
                          . "(git call failed); committed-state unverified.",
                evidence => { lockfile => $lock },
                remedy   => { action => 'none' },
            ));
            next;
        }
        if ($tracked_rc != 0) {
            $add->(_finding(
                kind     => 'lockfile_uncommitted',
                severity => 'block',
                subject  => $lock,
                detail   => "$lock exists but is not tracked by git (untracked or ignored); "
                          . "a rebuild would not restore it.",
                evidence => { lockfile => $lock, tracked => JSON::PP::false },
                remedy   => { action => 'commit_lockfile', file => $lock },
            ));
            next;
        }

        my ($out, $rc) = eval { $git->($project, 'status', '--porcelain', '--', $lock) };
        if ($@ || !defined $out || $rc != 0) {
            $git_ok = 0;
            $add->(_finding(
                kind     => 'git_unavailable',
                severity => 'warn',
                subject  => $project,
                detail   => "Could not determine whether lockfiles are committed "
                          . "(not a git repository, or git unavailable); committed-state unverified.",
                evidence => { lockfile => $lock },
                remedy   => { action => 'none' },
            ));
            next;
        }
        if ($out =~ /\S/) {
            $add->(_finding(
                kind     => 'lockfile_uncommitted',
                severity => 'block',
                subject  => $lock,
                detail   => "$lock is tracked but has uncommitted modifications; a rebuild would not restore the committed state.",
                evidence => { lockfile => $lock, git_status => (split /\n/, $out)[0] },
                remedy   => { action => 'commit_lockfile', file => $lock },
            ));
        }
    }

    # -- publish age (direct deps only) ------------------------------------
    if ($opts->{offline}) {
        $add->(_finding(
            kind => 'registry_unavailable', severity => 'warn', subject => 'registry',
            detail => 'Registry lookups skipped (--offline); publish-age policy unverified.',
            remedy => { action => 'none' },
        ));
    } else {
        my $deps  = eval { _direct_deps($project) } || [];
        my $total = scalar @$deps;

        # Bound the work. One full npm packument per pinned dep, and packuments
        # run to megabytes (react ~6.8 MB) -- a 300-dep manifest was measured at
        # 300 sequential fetches with no cap, and a 5000-dep one would spawn
        # 5000 curls. "Direct deps only" was not sufficient on its own, because
        # direct deps are routinely in the hundreds.
        my $unchecked = 0;
        if ($total > $MAX_REGISTRY_LOOKUPS) {
            $unchecked = $total - $MAX_REGISTRY_LOOKUPS;
            @$deps = @{$deps}[0 .. $MAX_REGISTRY_LOOKUPS - 1];
        }

        # Collect failures by CAUSE CLASS, not by message. The previous dedupe
        # keyed on a string that interpolated the package name, so nothing ever
        # collapsed: 300 deps produced 299 near-identical WARNs. WARNs are read
        # by a human at end-of-run, and 299 duplicates bury the real signal.
        my %by_cause;
        for my $d (@$deps) {
            my ($pub, $err, $class) = _registry_publish($http, $d->{eco}, $d->{name}, $d->{version});
            if (defined $err) {
                $class ||= 'unknown';
                push @{ $by_cause{$class} ||= [] }, "$d->{name}\@$d->{version}";
                next;
            }
            my $age = age_days($pub, $now);
            next unless defined $age && $age < $FRESH_DAYS;
            $add->(_finding(
                kind     => 'fresh_version',
                severity => 'warn',
                subject  => "$d->{name}\@$d->{version}",
                detail   => sprintf("%s\@%s was published %.1f days before the reference date (policy: >= %d days); needs a written justification.",
                                    $d->{name}, $d->{version}, $age, $FRESH_DAYS),
                evidence => { ecosystem => $d->{eco}, published => iso_of($pub) },
                remedy   => { action => 'justify', subject => "$d->{name}\@$d->{version}" },
            ));
        }

        # One aggregated WARN per cause class, carrying a bounded sample.
        for my $class (sort keys %by_cause) {
            my $pkgs = $by_cause{$class};
            my $n    = scalar @$pkgs;
            my $last = $#$pkgs > 9 ? 9 : $#$pkgs;
            $add->(_finding(
                kind     => 'registry_unavailable',
                severity => 'warn',
                subject  => "registry:$class",
                detail   => sprintf("Could not verify publish age for %d %s (%s); publish-age policy unverified for %s.",
                                    $n, ($n == 1 ? 'dependency' : 'dependencies'), $class,
                                    ($n == 1 ? 'it' : 'them')),
                evidence => { cause => $class, count => $n, sample => [ @{$pkgs}[0 .. $last] ] },
                remedy   => { action => 'none' },
            ));
        }

        # NEVER truncate silently -- an unreported cap reads as "all clean",
        # which is precisely the wrong answer for a policy gate.
        if ($unchecked) {
            $add->(_finding(
                kind     => 'publish_age_truncated',
                severity => 'warn',
                subject  => 'publish-age',
                detail   => "Publish-age checked the first $MAX_REGISTRY_LOOKUPS of $total pinned direct "
                          . "dependencies; $unchecked were NOT checked (lookup cap). Those are unverified, not clean.",
                evidence => { checked => $MAX_REGISTRY_LOOKUPS, total => $total, unchecked => $unchecked },
                remedy   => { action => 'none' },
            ));
        }
    }

    my %report = (
        generated_at => iso_of($now),
        now          => iso_of($now),
        project      => $project,
        blocks       => \@blocks,
        warns        => \@warns,
    );

    my $rc = @blocks ? 2 : 0;

    if (exists $opts->{out} && !defined $opts->{out}) {
        return (\%report, $rc);
    }
    my $out = $opts->{out};
    unless (defined $out) {
        $out = defined $ENV{BP_DIR} ? "$ENV{BP_DIR}/runs/deps-check.json"
                                    : "$project/runs/deps-check.json";
    }
    return ({ %report, error => "could not write $out" }, 1)
        unless _write_json_atomic($out, \%report);

    return (\%report, $rc);
}

# ---- CLI ------------------------------------------------------------------

unless (caller) {
    my %opt;
    for (@ARGV) {
        if    (/^--project=(.+)$/)  { $opt{project}  = $1 }
        elsif (/^--backpack=(.+)$/) { $opt{backpack} = $1 }
        elsif (/^--out=(.+)$/)      { $opt{out}      = $1 }
        elsif (/^--now=(.+)$/)      { $opt{now}      = $1 }
        elsif ($_ eq '--offline')   { $opt{offline}  = 1 }
        elsif ($_ eq '--quiet')     { $opt{quiet}    = 1 }
        else {
            print STDERR "bp-deps-check.pl: unknown argument '$_'\n"
                       . "usage: bp-deps-check.pl --project=<dir> [--backpack=<path>] [--out=<path>]\n"
                       . "                        [--now=<ISO8601|epoch>] [--offline] [--quiet]\n";
            exit 1;
        }
    }
    unless (defined $opt{project}) {
        print STDERR "bp-deps-check.pl: --project=<dir> is required\n";
        exit 1;
    }
    $opt{now} = defined $opt{now} ? parse_iso8601($opt{now})
              : (defined $ENV{BP_NOW} ? parse_iso8601($ENV{BP_NOW}) : time);
    unless (defined $opt{now}) {
        print STDERR "bp-deps-check.pl: --now is not a parseable ISO-8601 date or epoch\n";
        exit 1;
    }

    # Belt-and-braces: an unexpected die must NEVER reach perl's default exit
    # status, because that can land on 2 ($! == ENOENT) and be misread by b05
    # as "BLOCKs found". Any crash is an internal error -> exit 1.
    my ($report, $rc) = eval { run(\%opt) };
    if ($@) {
        my $err = $@; $err =~ s/\s+$//;
        print STDERR "bp-deps-check.pl: internal error: $err\n";
        exit 1;
    }
    if ($rc == 1) {
        print STDERR "bp-deps-check.pl: " . ($report->{error} // 'internal error') . "\n";
        exit 1;
    }
    unless ($opt{quiet}) {
        printf "deps-check: %d block(s), %d warn(s) as of %s\n",
            scalar @{ $report->{blocks} }, scalar @{ $report->{warns} }, $report->{now};
        for my $f (@{ $report->{blocks} }) { print "  BLOCK  $f->{kind}: $f->{detail}\n" }
        for my $f (@{ $report->{warns} })  { print "  WARN   $f->{kind}: $f->{detail}\n" }
    }
    exit $rc;
}

1;
