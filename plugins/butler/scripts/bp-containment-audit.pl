#!/usr/bin/env perl
# bp-containment-audit.pl — post-step subprocess write-containment audit (b20).
#
# A `write_set` bounds the AGENT (via guard-writes.sh, which intercepts Edit/Write tool calls).
# It does not bound the processes that agent spawns with Bash. This script closes that visibility
# gap by *reporting* — never blocking — what actually changed on disk around a step, diffed
# against the package's declared boundary.
#
# Derived from:
#   .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/specs/b20-subprocess-write-containment-spec.md
#
# Interface:
#   bp-containment-audit.pl snapshot --out <file> [--project-root P] [--data-dir D]
#   bp-containment-audit.pl diff --before <file> [--after <file>] [--write-set S] [--bp-dir B]
#                                [--report <file>] [--format text|json]
#                                [--project-root P] [--data-dir D]
#
# Scan roots (§1 of the spec — a correctness requirement, not an optimisation):
#   1. $BP_PROJECT_ROOT, excluding .git/ and excluding $CCPRAXIS_DATA_DIR.
#   2. $CCPRAXIS_DATA_DIR/blueprints/.
# Everything else under <data> -- chiefly claude-home/, which is rewritten every turn by the very
# coordinator running this audit -- is excluded. This is never derived from `git status`.
#
# Exit codes: 0 = ran successfully (report, regardless of findings -- this audit REPORTS, it does
# not kill). 4 = the audit's OWN failure (unreadable root, malformed snapshot). Never 127 -- that
# is reserved by the shell for "could not run the script at all", and a coordinator must be able
# to tell "nothing leaked" from "the audit could not tell you".
use strict;
use warnings;
use FindBin qw($Bin);
use JSON::PP ();
use File::Spec ();
use File::Path qw(make_path);
use Cwd qw(getcwd);

my $EXIT_AUDIT_FAILURE = 4;

sub fail {
    my ($msg) = @_;
    print STDERR "bp-containment-audit: $msg\n";
    exit $EXIT_AUDIT_FAILURE;
}

sub usage_die {
    print STDERR "usage: bp-containment-audit.pl snapshot --out <file> [--project-root P] [--data-dir D]\n";
    print STDERR "       bp-containment-audit.pl diff --before <file> [--after <file>] [--write-set S]\n";
    print STDERR "                                    [--bp-dir B] [--report <file>] [--format text|json]\n";
    print STDERR "                                    [--project-root P] [--data-dir D]\n";
    exit 2;
}

# ---------------------------------------------------------------------------------------------
# Generic --key value arg parsing.
# ---------------------------------------------------------------------------------------------
sub parse_opts {
    my (@argv) = @_;
    my %opts;
    while (@argv) {
        my $a = shift @argv;
        if ($a =~ /^--([A-Za-z0-9][A-Za-z0-9-]*)$/) {
            my $key = $1;
            usage_die() unless @argv;
            $opts{$key} = shift @argv;
        } else {
            print STDERR "bp-containment-audit: unrecognised argument '$a'\n";
            usage_die();
        }
    }
    return \%opts;
}

sub norm_dir {
    my ($d) = @_;
    return $d unless defined $d;
    $d =~ s{/+$}{};
    return $d;
}

sub is_under_or_eq {
    my ($path, $dir) = @_;
    return 0 unless defined $dir && length $dir;
    $dir = norm_dir($dir);
    return 1 if $path eq $dir;
    return 1 if index($path, "$dir/") == 0;
    return 0;
}

# match_any REL PATTERNS — mirrors plugins/butler/hooks/lib.sh's match_any exactly: colon-
# separated patterns; a trailing '/' means a directory prefix; otherwise an exact match.
sub match_any {
    my ($rel, $patterns) = @_;
    return 0 unless defined $patterns && length $patterns;
    for my $pat (split /:/, $patterns, -1) {
        next unless length $pat;
        if ($pat =~ m{/$}) {
            return 1 if index($rel, $pat) == 0;
            (my $bare = $pat) =~ s{/$}{};
            return 1 if $rel eq $bare;
        } else {
            return 1 if $rel eq $pat;
        }
    }
    return 0;
}

# ---------------------------------------------------------------------------------------------
# Filesystem walk. Never follows symlinks (avoids cycles); never descends into a dir named
# ".git"; the repo walk never descends into $data_dir (that subtree is scanned separately, and
# only its blueprints/ child is in-scope at all).
# ---------------------------------------------------------------------------------------------
sub walk_repo {
    my ($dir, $proj_root, $data_dir, $entries) = @_;
    opendir(my $dh, $dir) or die "cannot read directory $dir: $!\n";
    for my $name (sort readdir($dh)) {
        next if $name eq '.' || $name eq '..';
        next if $name eq '.git';
        my $full = "$dir/$name";
        next if is_under_or_eq($full, $data_dir);
        next if -l $full;
        if (-d $full) {
            walk_repo($full, $proj_root, $data_dir, $entries);
        } elsif (-f $full) {
            my @st = stat($full);
            my $rel = File::Spec->abs2rel($full, $proj_root);
            $entries->{$full} = { mtime => $st[9], size => $st[7], root => 'repo', rel => $rel };
        }
    }
    closedir $dh;
}

sub walk_data {
    my ($dir, $data_root, $entries) = @_;
    opendir(my $dh, $dir) or die "cannot read directory $dir: $!\n";
    for my $name (sort readdir($dh)) {
        next if $name eq '.' || $name eq '..';
        my $full = "$dir/$name";
        next if -l $full;
        if (-d $full) {
            walk_data($full, $data_root, $entries);
        } elsif (-f $full) {
            my @st = stat($full);
            my $rel = File::Spec->abs2rel($full, $data_root);
            $entries->{$full} = { mtime => $st[9], size => $st[7], root => 'data', rel => $rel };
        }
    }
    closedir $dh;
}

sub scan_tree {
    my (%args) = @_;
    my $proj = norm_dir($args{project_root});
    my $data = norm_dir($args{data_dir});
    die "project root is not a readable directory: $proj\n" unless -d $proj;
    my %entries;
    walk_repo($proj, $proj, $data, \%entries);
    my $bp_root = "$data/blueprints";
    walk_data($bp_root, $data, \%entries) if -d $bp_root;
    return \%entries;
}

# ---------------------------------------------------------------------------------------------
# Snapshot load / save.
# ---------------------------------------------------------------------------------------------
sub save_snapshot {
    my ($path, $entries) = @_;
    my $dir = $path;
    $dir =~ s{[/\\][^/\\]+$}{};
    make_path($dir) if length($dir) && !-d $dir;
    my $json = JSON::PP->new->canonical->encode({ entries => $entries });
    open(my $fh, '>', $path) or die "cannot write snapshot $path: $!\n";
    print $fh $json;
    close $fh;
}

sub load_snapshot {
    my ($path) = @_;
    die "snapshot file does not exist: $path\n" unless -f $path;
    open(my $fh, '<', $path) or die "cannot read snapshot $path: $!\n";
    local $/;
    my $text = <$fh>;
    close $fh;
    my $decoded = eval { JSON::PP::decode_json($text) };
    die "malformed snapshot JSON in $path: $@\n" if $@;
    die "malformed snapshot structure in $path (missing 'entries' object)\n"
        unless ref($decoded) eq 'HASH' && ref($decoded->{entries}) eq 'HASH';
    return $decoded->{entries};
}

# ---------------------------------------------------------------------------------------------
# In-set rule (§2.4). Mirrors guard-writes.sh's "$BP_DIR"/*|/tmp/* exemption, so the hook (agent
# tool calls) and this audit (subprocess writes) enforce ONE boundary.
# ---------------------------------------------------------------------------------------------
sub in_set {
    my ($abs, $rec, $write_set, $bp_dir) = @_;
    return 1 if $abs =~ m{^/tmp/};
    if ($rec->{root} eq 'repo') {
        return match_any($rec->{rel}, $write_set) ? 1 : 0;
    } elsif ($rec->{root} eq 'data') {
        return is_under_or_eq($abs, $bp_dir) ? 1 : 0;
    }
    return 0;
}

# ---------------------------------------------------------------------------------------------
# snapshot subcommand
# ---------------------------------------------------------------------------------------------
sub cmd_snapshot {
    my $o = parse_opts(@_);
    usage_die() unless defined $o->{out};
    my $project_root = defined $o->{'project-root'} ? $o->{'project-root'}
                      : ($ENV{BP_PROJECT_ROOT} || getcwd());
    my $data_dir = defined $o->{'data-dir'} ? $o->{'data-dir'}
                 : ($ENV{CCPRAXIS_DATA_DIR} || "$project_root/.ccpraxis-local-data");

    my $entries = eval { scan_tree(project_root => $project_root, data_dir => $data_dir) };
    fail($@) if $@;

    eval { save_snapshot($o->{out}, $entries) };
    fail($@) if $@;

    exit 0;
}

# ---------------------------------------------------------------------------------------------
# diff subcommand
# ---------------------------------------------------------------------------------------------
sub cmd_diff {
    my $o = parse_opts(@_);
    usage_die() unless defined $o->{before};

    my $write_set = defined $o->{'write-set'} ? $o->{'write-set'} : ($ENV{BP_WRITE_SET} // '');
    my $bp_dir    = defined $o->{'bp-dir'}    ? $o->{'bp-dir'}    : ($ENV{BP_DIR} // '');
    $bp_dir = norm_dir($bp_dir);
    my $format = $o->{format} // 'text';

    my $before_entries = eval { load_snapshot($o->{before}) };
    fail($@) if $@;

    my $after_entries;
    if (defined $o->{after}) {
        $after_entries = eval { load_snapshot($o->{after}) };
        fail($@) if $@;
    } else {
        my $project_root = defined $o->{'project-root'} ? $o->{'project-root'}
                          : ($ENV{BP_PROJECT_ROOT} || getcwd());
        my $data_dir = defined $o->{'data-dir'} ? $o->{'data-dir'}
                     : ($ENV{CCPRAXIS_DATA_DIR} || "$project_root/.ccpraxis-local-data");
        $after_entries = eval { scan_tree(project_root => $project_root, data_dir => $data_dir) };
        fail($@) if $@;
    }

    my %all_paths = map { $_ => 1 } (keys %$before_entries, keys %$after_entries);
    my @findings;
    for my $p (sort keys %all_paths) {
        my $b = $before_entries->{$p};
        my $a = $after_entries->{$p};
        my $kind;
        if (!$b && $a) {
            $kind = 'new';
        } elsif ($b && !$a) {
            $kind = 'deleted';
        } elsif ($b && $a) {
            next if $b->{mtime} == $a->{mtime} && $b->{size} == $a->{size};
            $kind = 'modified';
        } else {
            next;
        }
        my $rec = $a || $b;
        next if in_set($p, $rec, $write_set, $bp_dir);
        push @findings, {
            path => $rec->{rel},
            size => ($a ? $a->{size} : $b->{size}),
            kind => $kind,
        };
    }

    my $total_bytes = 0;
    $total_bytes += ($_->{size} // 0) for @findings;
    my $result = {
        summary  => { count => scalar(@findings), total_bytes => $total_bytes },
        findings => \@findings,
    };

    my $rendered;
    if ($format eq 'json') {
        $rendered = JSON::PP->new->canonical->pretty->encode($result);
    } else {
        my @lines;
        push @lines, sprintf("containment audit: %d out-of-set write(s), %d byte(s) total",
                              $result->{summary}{count}, $result->{summary}{total_bytes});
        for my $f (@findings) {
            push @lines, sprintf("  [%s] %s (%d bytes)", $f->{kind}, $f->{path}, $f->{size} // 0);
        }
        $rendered = join("\n", @lines) . "\n";
    }

    if (defined $o->{report}) {
        my $dir = $o->{report};
        $dir =~ s{[/\\][^/\\]+$}{};
        make_path($dir) if length($dir) && !-d $dir;
        open(my $fh, '>', $o->{report}) or fail("cannot write report $o->{report}: $!");
        print $fh $rendered;
        close $fh;
    }
    print $rendered;

    # Emit findings onto the same structured log stream the coordinator and s16 already read
    # (§2.5) -- a report file nobody opens is the silence this package exists to end. Non-fatal:
    # a logging failure must never turn a successful report into an audit failure.
    if (@findings && length $bp_dir) {
        eval {
            require "$Bin/bp-log.pl";
            my $logpath = "$bp_dir/runs/containment-audit.jsonl";
            BpLog::event($logpath, 'containment_finding', {
                count       => scalar(@findings),
                total_bytes => $total_bytes,
                findings    => \@findings,
            });
        };
    }

    exit 0;
}

# ---------------------------------------------------------------------------------------------
my $cmd = shift @ARGV;
usage_die() unless defined $cmd;
if ($cmd eq 'snapshot') {
    cmd_snapshot(@ARGV);
} elsif ($cmd eq 'diff') {
    cmd_diff(@ARGV);
} else {
    print STDERR "bp-containment-audit: unknown subcommand '$cmd'\n";
    usage_die();
}
