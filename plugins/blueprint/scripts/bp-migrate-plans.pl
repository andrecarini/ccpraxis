#!/usr/bin/env perl
# bp-migrate-plans.pl — deterministically migrate legacy .claude-plans/*.md
# living-document plans into the blueprint system as archive-style blueprints.
#
# Usage:
#   bp-migrate-plans.pl <project-root> [--apply] [--delete]
#     default      dry run: print the plan, write nothing
#     --apply      write the blueprint files
#     --delete     after a successful --apply, remove the migrated originals
#                  and prune the emptied .claude-plans dirs
#
# Design (deterministic — no per-invocation guesswork):
#   - Discovers EVERY *.md under <root>/.claude-plans at any depth, so it
#     handles `archive/`, `archived/`, loose files, and arbitrary nesting
#     uniformly (this is the robustness an ad-hoc script keeps missing).
#   - A plan is ACTIVE iff it sits directly in .claude-plans/ AND its body
#     still carries an incomplete-deliverable marker (U+2B1C white square or
#     U+1F527 wrench). Active  -> blueprints/<slug>/        (status: running)
#     Everything else          -> blueprints/_archive/<slug>/ (status: archived)
#   - Archive-style: the full original content is preserved verbatim beneath a
#     blueprint metadata header. No package re-decomposition.
#   - Encoding-safe: UTF-8 in/out; markers matched by codepoint, never by a
#     literal emoji in this source (which would mojibake under non-utf8 perl).
#   - Idempotent: a dest already migrated from the same source is skipped; a
#     different source colliding on a slug is disambiguated (<slug>-2, -3, ...).
#   - Ensures <root>/.ccpraxis-local-data self-gitignores (inner .gitignore=*).
use strict;
use warnings;
use utf8;                       # this source carries non-ASCII (em-dash) in output strings
use File::Path qw(make_path);
use File::Basename qw(basename);
use File::Find qw(find);
use POSIX qw(strftime);
binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

my ($root, $apply, $delete);
for (@ARGV) {
    if    ($_ eq '--apply')  { $apply  = 1 }
    elsif ($_ eq '--delete') { $delete = 1 }
    elsif (!defined $root)   { $root   = $_ }
    else { die "bp-migrate-plans: unexpected argument: $_\n" }
}
die "usage: bp-migrate-plans.pl <project-root> [--apply] [--delete]\n" unless defined $root;
$root =~ s{[/\\]+$}{};

my $pdir   = "$root/.claude-plans";
my $bproot = "$root/.ccpraxis-local-data/blueprints";
unless (-d $pdir) { print "no .claude-plans/ under $root — nothing to migrate.\n"; exit 0; }

sub src_label { my $f = shift; (my $r = $f) =~ s{^\Q$pdir\E/}{}; return ".claude-plans/$r"; }
sub rel_to    { my ($base, $p) = @_; (my $r = $p) =~ s{^\Q$base\E/}{}; return $r; }
sub migrated_from {
    my $bm = shift;
    open(my $fh, '<:encoding(UTF-8)', $bm) or return undef;
    while (my $l = <$fh>) { if ($l =~ /^migrated_from:\s*(.+?)\s*$/) { close $fh; return $1 } }
    close $fh; return undef;
}

# 1. Discover every *.md under .claude-plans (recursive, symlink-safe).
my @plans;
find({ no_chdir => 1, wanted => sub {
    return if -l $_ || -d $_;
    push @plans, $_ if /\.md$/;
} }, $pdir);
@plans = sort @plans;
unless (@plans) { print "no *.md plans under $pdir — nothing to migrate.\n"; exit 0; }

my $today = strftime('%Y-%m-%d', localtime);

# 2. Classify + resolve destinations (idempotent, collision-safe).
my @todo;
my %claimed;
for my $f (@plans) {
    my $rel  = rel_to($pdir, $f);
    my $top  = ($rel !~ m{/});                 # directly in .claude-plans/
    my $slug = basename($f); $slug =~ s/\.md$//;
    open(my $in, '<:encoding(UTF-8)', $f) or do { warn "read $f: $!\n"; next };
    local $/; my $content = <$in>; close $in;
    my $active = $top && ($content =~ /\x{2B1C}|\x{1F527}/);
    my $t = { f => $f, rel => $rel, slug => $slug, active => $active, content => $content };

    my $base = $active ? "$bproot/$slug" : "$bproot/_archive/$slug";
    my $dir = $base; my $n = 1;
    while (1) {
        my $bm = "$dir/blueprint.md";
        if (-f $bm) {
            my $ex = migrated_from($bm);
            if (defined $ex && $ex eq src_label($f)) { $t->{skip} = 'already-migrated'; last }
            $n++; $dir = "$base-$n"; next;            # occupied by a different plan
        }
        if ($claimed{$dir}) { $n++; $dir = "$base-$n"; next }
        $claimed{$dir} = $f; $t->{dest} = $dir; last;
    }
    push @todo, $t;
}

# 3. Report.
my ($act, $arc, $skip) = (0, 0, 0);
for my $t (@todo) {
    if ($t->{skip}) { $skip++; printf "  SKIP      %-50s (%s)\n", $t->{rel}, $t->{skip}; next }
    $t->{active} ? $act++ : $arc++;
    printf "  %-9s %-50s -> %s\n", ($t->{active} ? 'ACTIVE' : 'ARCHIVED'), $t->{rel}, rel_to($root, $t->{dest});
}
printf "\nplan: %d active, %d archived, %d skipped (of %d) under %s\n", $act, $arc, $skip, scalar(@todo), $root;
unless ($apply) { print "\n(dry run — pass --apply to write" . ($delete ? ", --delete to remove originals" : "") . ")\n"; exit 0 }

# 4. Apply: ensure data dir self-gitignores, then write.
make_path($bproot);
my $gi = "$root/.ccpraxis-local-data/.gitignore";
if (!-f $gi) { if (open(my $g, '>', $gi)) { print $g "*\n"; close $g } }

my $written = 0;
for my $t (@todo) {
    next if $t->{skip};
    make_path($t->{dest});
    my $title   = ($t->{content} =~ /^\#\s+(.+)$/m) ? $1 : $t->{slug};
    my $created = strftime('%Y-%m-%d', localtime((stat($t->{f}))[9]));
    my $status  = $t->{active} ? 'running' : 'archived';
    my $name    = basename($t->{dest});
    (my $body = $t->{content}) =~ s/^\#\s+.+\n//m;
    my $hdr = "# $title\n\n```\nblueprint: $name\nstatus: $status\ncreated: $created\nlast_updated: $today\nmigrated_from: " . src_label($t->{f}) . "\n```\n\n> **Migrated** from the legacy .claude-plans plan system on $today. Archive-style: full content preserved below, no package re-decomposition.\n\n---\n";
    open(my $out, '>:encoding(UTF-8)', "$t->{dest}/blueprint.md") or do { warn "write $t->{dest}: $!\n"; next };
    print $out $hdr . $body; close $out;
    $t->{written} = 1; $written++;
}
print "wrote $written blueprint file(s).\n";

# 5. Optionally delete originals (only those verified on disk), then prune dirs.
if ($delete) {
    my $del = 0;
    for my $t (@todo) {
        next if $t->{skip};
        next unless $t->{written} && -s "$t->{dest}/blueprint.md";
        if (unlink $t->{f}) { $del++ } else { warn "unlink $t->{f}: $!\n" }
    }
    my @dirs;
    find({ no_chdir => 1, wanted => sub { push @dirs, $_ if -d $_ } }, $pdir);
    rmdir $_ for sort { length($b) <=> length($a) } @dirs;   # deepest first
    print "deleted $del original(s); pruned empty dirs.\n";
    print(-d $pdir ? "note: $pdir still has non-plan contents.\n" : "$pdir fully removed.\n");
}
