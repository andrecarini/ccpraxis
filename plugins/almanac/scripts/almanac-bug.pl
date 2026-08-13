#!/usr/bin/env perl
# almanac-bug.pl — ccpraxis bug reports filed BY agents working in other projects.
#
# THE PROBLEM. An agent hits a ccpraxis tooling defect while working in some
# unrelated project. Today that observation dies with the session: it is prose
# in a transcript nobody re-reads. There is no path from "the tooling failed me
# here" to "ccpraxis knows about it".
#
# THE SHAPE. One file per report, written ONLY through this script, in a small
# state machine that freezes a report once ccpraxis has picked it up:
#
#   open  ->  reviewing  ->  taken  ->  resolved | declined
#
# `open` is the reporter's: they may keep editing while nobody has looked. From
# `reviewing` onward the content is FROZEN — the filer cannot rewrite history
# under a reviewer who is mid-read, and a `taken` report cannot be quietly
# reworded after the fact.
#
# THREE LAYERS OF IMMUTABILITY, because two are bypassable:
#   1. this script refuses a content change once frozen;
#   2. a PreToolUse hook denies Edit/Write against the reports directory, so the
#      script is the only sanctioned writer (same pattern as
#      guard-blueprint-write.sh);
#   3. a sha256 recorded at freeze time DETECTS an out-of-band edit anyway —
#      `verify` reports it. Layers 1 and 2 can be routed around by a determined
#      Bash call; layer 3 cannot, because it does not rely on preventing the
#      write.
#
# WHERE THINGS LIVE. Reports sit in the project they were filed from, so they
# travel with the context that produced them:
#   <project>/.ccpraxis-local-data/bug-reports/<id>.md
# and every state change appends to a machine-level index:
#   ~/.claude/ccpraxis/bug-index.jsonl
# The index exists so `collect` never has to guess project paths from Claude
# Code's slugs, which are lossy (separators and hyphens are ambiguous — that
# ambiguity already produced a wrong conclusion during this system's design).

package AlmanacBug;
use strict;
use warnings;
use JSON::PP ();
use Digest::SHA qw(sha256_hex);
use File::Basename qw(dirname);
use Cwd ();

our @STATES = qw(open reviewing taken resolved declined);
our %NEXT = (
    open      => [qw(reviewing declined)],
    reviewing => [qw(taken open declined)],   # back to open = "not ready, keep editing"
    taken     => [qw(resolved declined)],
    resolved  => [],
    declined  => [],
);
# Content is editable ONLY in these states.
our %MUTABLE = (open => 1);

sub _now { time }
sub _iso { my @t = gmtime($_[0] // time);
           sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5]+1900,$t[4]+1,$t[3],$t[2],$t[1],$t[0]) }

# NOT under ~/.claude/ccpraxis — that path is the LIVE INSTALL, a git working
# tree, and an index file written there shows up as an untracked change that
# blocks `git pull` during promotion. Caught within an hour of shipping: the
# first two real reports left the live install dirty. State belongs beside the
# repo, never inside it.
sub index_path {
    my $home = $ENV{ALMANAC_HOME} // $ENV{HOME} // $ENV{USERPROFILE} // '.';
    return "$home/.claude/almanac/bug-index.jsonl";
}
sub reports_dir { my ($root) = @_; return "$root/.ccpraxis-local-data/bug-reports" }

sub _mkpath {
    my ($d) = @_;
    return 1 if -d $d;
    my $cur = ($d =~ m{^/}) ? '/' : '';
    for my $p (grep { length } split m{/}, $d) {
        $cur = ($cur eq '' || $cur eq '/') ? "$cur$p" : "$cur/$p";
        next if $cur =~ /^[A-Za-z]:$/;
        unless (-d $cur) { mkdir $cur or return 0 }
    }
    return -d $d ? 1 : 0;
}

# --- report file format: frontmatter + body -------------------------------
sub _parse {
    my ($text) = @_;
    return undef unless defined $text && $text =~ /\A---\r?\n(.*?)\r?\n---\r?\n(.*)\z/s;
    my ($fm, $body) = ($1, $2);
    my %f;
    for my $line (split /\r?\n/, $fm) {
        next unless $line =~ /^([A-Za-z0-9_]+):\s*(.*)$/;
        my ($k, $v) = ($1, $2);
        $v =~ s/\s+$//;
        $f{$k} = $v;
    }
    return { fields => \%f, body => $body };
}
sub _render {
    my ($f, $body) = @_;
    my @order = qw(id title status severity area project created_at updated_at
                   frozen_at content_sha256 taken_at resolution);
    my %seen;
    my @lines;
    for my $k (@order) { next unless defined $f->{$k}; push @lines, "$k: $f->{$k}"; $seen{$k}=1 }
    for my $k (sort keys %$f) { next if $seen{$k}; next unless defined $f->{$k}; push @lines, "$k: $f->{$k}" }
    return "---\n" . join("\n", @lines) . "\n---\n" . $body;
}
sub _read_file { my ($p)=@_; open my $fh,'<:raw',$p or return undef; local $/; my $c=<$fh>; close $fh; return $c }
sub _write_atomic {
    my ($p, $bytes) = @_;
    _mkpath(dirname($p)) or return 0;
    my $tmp = "$p.tmp.$$";
    open my $fh, '>:raw', $tmp or return 0;
    print {$fh} $bytes or do { close $fh; unlink $tmp; return 0 };
    close $fh or do { unlink $tmp; return 0 };
    rename($tmp, $p) or do { unlink $tmp; return 0 };
    return 1;
}

sub load {
    my ($path) = @_;
    my $raw = _read_file($path) or return undef;
    my $p = _parse($raw) or return undef;
    $p->{path} = $path;
    $p->{raw}  = $raw;
    return $p;
}

# The frozen digest covers the BODY only. Status/updated_at legitimately change
# after freezing; the reported content must not.
sub body_digest { return sha256_hex($_[0] // '') }

sub verify {
    my ($rep) = @_;
    my $f = $rep->{fields};
    return (1, 'not frozen') unless defined $f->{content_sha256} && length $f->{content_sha256};
    my $now = body_digest($rep->{body});
    return (1, 'intact') if $now eq $f->{content_sha256};
    return (0, "TAMPERED: body digest $now != recorded $f->{content_sha256}");
}

sub append_index {
    my ($rec) = @_;
    my $p = index_path();
    _mkpath(dirname($p)) or return 0;
    open my $fh, '>>:raw', $p or return 0;
    print {$fh} JSON::PP->new->canonical->encode($rec), "\n";
    close $fh;
    return 1;
}

# The index is append-only, so the LAST line for an id is its current state.
sub read_index {
    my $p = index_path();
    open my $fh, '<:raw', $p or return {};
    my %by_id;
    while (my $l = <$fh>) {
        my $j = eval { JSON::PP->new->decode($l) } or next;
        next unless ref $j eq 'HASH' && defined $j->{id};
        $by_id{ $j->{id} } = { %{ $by_id{$j->{id}} // {} }, %$j };
    }
    close $fh;
    return \%by_id;
}

sub new_id {
    my ($now) = @_;
    my @t = gmtime($now // time);
    return sprintf('%04d%02d%02d-%02d%02d%02d-%04x',
                   $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0], ($$ & 0xffff));
}

sub can_transition {
    my ($from, $to) = @_;
    return (0, "unknown target state '$to'") unless grep { $_ eq $to } @STATES;
    return (0, "unknown current state '$from'") unless exists $NEXT{$from};
    return (0, "$from -> $to is not a legal transition (from $from you may go to: "
             . (join(', ', @{$NEXT{$from}}) || 'nowhere — it is terminal') . ')')
        unless grep { $_ eq $to } @{ $NEXT{$from} };
    return (1, '');
}

package main;
use strict;
use warnings;
use JSON::PP;

sub _slurp_arg {
    my (%o) = @_;
    return $o{body} eq '-' ? do { local $/; <STDIN> } : $o{body} if defined $o{body};
    if (defined $o{'body-file'}) {
        open my $fh, '<:raw', $o{'body-file'} or die "cannot read $o{'body-file'}: $!\n";
        local $/; my $c = <$fh>; close $fh; return $c;
    }
    return undef;
}

unless (caller) {
    my $cmd = shift @ARGV // '';
    my %o;
    while (@ARGV) {
        my $a = shift @ARGV;
        if ($a =~ /^--([a-z0-9-]+)$/) { $o{$1} = (@ARGV && $ARGV[0] !~ /^--/) ? shift @ARGV : 1 }
        else { $o{_pos} ||= []; push @{$o{_pos}}, $a }
    }
    my @pos  = @{ $o{_pos} // [] };
    my $root = $o{project} // $ENV{CLAUDE_PROJECT_DIR} // Cwd::abs_path('.') // '.';
    $root =~ s{\\}{/}g; $root =~ s{/+$}{};

    if ($cmd eq 'file') {
        my $title = $o{title} or die "almanac-bug file: --title is required\n";
        die "almanac-bug file: --title must be one line\n" if $title =~ /[\r\n]/;
        my $body = _slurp_arg(%o);
        die "almanac-bug file: --body or --body-file is required (a report with no body is noise)\n"
            unless defined $body && $body =~ /\S/;
        my $now = time;
        my $id  = AlmanacBug::new_id($now);
        my $dir = AlmanacBug::reports_dir($root);
        my $path = "$dir/$id.md";
        my %f = (
            id => $id, title => $title, status => 'open',
            severity => ($o{severity} // 'unknown'),
            area     => ($o{area} // 'unknown'),
            project  => $root,
            created_at => AlmanacBug::_iso($now), updated_at => AlmanacBug::_iso($now),
        );
        AlmanacBug::_write_atomic($path, AlmanacBug::_render(\%f, $body))
            or die "almanac-bug file: could not write $path\n";
        AlmanacBug::append_index({ id=>$id, path=>$path, project=>$root, title=>$title,
                                   status=>'open', at=>AlmanacBug::_iso($now) });
        print "$path\n";
        exit 0;
    }

    # Locate a report by id, in this project or (for ccpraxis-side verbs) anywhere.
    my $find = sub {
        my ($id) = @_;
        my $local = AlmanacBug::reports_dir($root) . "/$id.md";
        return $local if -f $local;
        my $idx = AlmanacBug::read_index();
        my $rec = $idx->{$id} or return undef;
        return (defined $rec->{path} && -f $rec->{path}) ? $rec->{path} : undef;
    };

    if ($cmd eq 'update') {
        my $id = $pos[0] or die "almanac-bug update: <id> required\n";
        my $path = $find->($id) or die "almanac-bug update: no report '$id'\n";
        my $rep  = AlmanacBug::load($path) or die "almanac-bug update: $path is unreadable or malformed\n";
        my $st   = $rep->{fields}{status} // 'open';
        unless ($AlmanacBug::MUTABLE{$st}) {
            print STDERR "almanac-bug update: refused — '$id' is $st, and content is frozen from "
                       . "'reviewing' onward so a reviewer cannot have the report rewritten "
                       . "underneath them. Add a follow-up report instead.\n";
            exit 2;
        }
        my $body = _slurp_arg(%o);
        die "almanac-bug update: --body or --body-file is required\n" unless defined $body && $body =~ /\S/;
        my %f = %{ $rep->{fields} };
        $f{title} = $o{title} if defined $o{title} && !ref $o{title};
        $f{severity} = $o{severity} if defined $o{severity} && !ref $o{severity};
        $f{updated_at} = AlmanacBug::_iso(time);
        AlmanacBug::_write_atomic($path, AlmanacBug::_render(\%f, $body))
            or die "almanac-bug update: could not write $path\n";
        AlmanacBug::append_index({ id=>$id, path=>$path, project=>$f{project}//$root,
                                   title=>$f{title}, status=>$st, at=>$f{updated_at} });
        print "$path\n";
        exit 0;
    }

    if ($cmd eq 'set-status') {
        my $id = $pos[0] or die "almanac-bug set-status: <id> required\n";
        my $to = $o{to} or die "almanac-bug set-status: --to <state> required\n";
        my $path = $find->($id) or die "almanac-bug set-status: no report '$id'\n";
        my $rep  = AlmanacBug::load($path) or die "almanac-bug set-status: $path unreadable\n";
        my $from = $rep->{fields}{status} // 'open';
        my ($ok, $why) = AlmanacBug::can_transition($from, $to);
        unless ($ok) { print STDERR "almanac-bug set-status: $why\n"; exit 2 }

        my %f = %{ $rep->{fields} };
        my $now = AlmanacBug::_iso(time);
        $f{status} = $to;
        $f{updated_at} = $now;
        # Freeze on the way OUT of open; unfreeze if deliberately sent back.
        if ($to eq 'open') { delete $f{content_sha256}; delete $f{frozen_at} }
        else {
            $f{content_sha256} //= AlmanacBug::body_digest($rep->{body});
            $f{frozen_at}      //= $now;
        }
        $f{taken_at}   = $now       if $to eq 'taken' && !defined $f{taken_at};
        $f{resolution} = $o{note}   if defined $o{note} && !ref $o{note};
        AlmanacBug::_write_atomic($path, AlmanacBug::_render(\%f, $rep->{body}))
            or die "almanac-bug set-status: could not write $path\n";
        AlmanacBug::append_index({ id=>$id, path=>$path, project=>$f{project}//$root,
                                   title=>$f{title}, status=>$to, at=>$now });
        print "$id: $from -> $to\n";
        exit 0;
    }

    if ($cmd eq 'list' || $cmd eq 'collect') {
        # list   = this project only (from disk, authoritative)
        # collect = every project (from the index, then re-read each file)
        my @paths;
        if ($cmd eq 'list') {
            my $dir = AlmanacBug::reports_dir($root);
            @paths = sort glob("$dir/*.md");
        } else {
            my $idx = AlmanacBug::read_index();
            @paths = sort map { $_->{path} } grep { defined $_->{path} } values %$idx;
        }
        my @out;
        for my $p (@paths) {
            next unless -f $p;
            my $rep = AlmanacBug::load($p) or next;
            my $f = $rep->{fields};
            next if defined $o{status} && !ref $o{status} && ($f->{status}//'') ne $o{status};
            my ($intact, $note) = AlmanacBug::verify($rep);
            push @out, { id=>$f->{id}, title=>$f->{title}, status=>$f->{status},
                         severity=>$f->{severity}, area=>$f->{area}, project=>$f->{project},
                         created_at=>$f->{created_at}, path=>$p,
                         ($intact ? () : (integrity=>$note)) };
        }
        if ($o{json}) { print JSON::PP->new->canonical->pretty->encode(\@out) }
        else {
            printf "%-22s %-10s %-9s %s\n", 'ID', 'STATUS', 'SEVERITY', 'TITLE';
            for my $r (@out) {
                printf "%-22s %-10s %-9s %s\n", $r->{id}, $r->{status}//'?',
                       $r->{severity}//'?', $r->{title}//'';
                print  "  !! $r->{integrity}\n" if $r->{integrity};
                print  "  $r->{project}\n" if $cmd eq 'collect';
            }
            print "\n" . scalar(@out) . " report(s)\n";
        }
        exit 0;
    }

    if ($cmd eq 'verify') {
        my $idx = AlmanacBug::read_index();
        my @bad;
        my $n = 0;
        for my $rec (sort { ($a->{id}//'') cmp ($b->{id}//'') } values %$idx) {
            my $p = $rec->{path} or next;
            unless (-f $p) { push @bad, "$rec->{id}: MISSING from disk ($p)"; next }
            my $rep = AlmanacBug::load($p) or do { push @bad, "$rec->{id}: unreadable/malformed"; next };
            $n++;
            my ($ok, $note) = AlmanacBug::verify($rep);
            push @bad, "$rec->{id}: $note" unless $ok;
        }
        print "checked $n report(s)\n";
        print "  $_\n" for @bad;
        exit(@bad ? 2 : 0);
    }

    print STDERR <<'USAGE';
almanac-bug.pl — ccpraxis bug reports, one file per report.

  file --title T (--body - | --body-file F) [--severity S] [--area A] [--project ROOT]
        Create a report in the current project. Prints its path.
  update <id> (--body - | --body-file F) [--title T] [--severity S]
        Revise a report. Allowed ONLY while status is `open`.
  set-status <id> --to <state> [--note N]
        open -> reviewing -> taken -> resolved|declined  (reviewing -> open to hand back)
        Leaving `open` FREEZES the body and records its sha256.
  list [--status S] [--json]        reports in this project
  collect [--status S] [--json]     reports across every project (via the index)
  verify                            re-check every frozen body against its digest

One report per file. Write only through this script — a PreToolUse hook denies
direct edits to the reports directory.
USAGE
    exit 3;
}
1;
