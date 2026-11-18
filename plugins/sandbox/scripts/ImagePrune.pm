package ImagePrune;
# ImagePrune -- remove the images a successful build has superseded, and
# recognise a build that failed because the podman machine's disk is full.
#
# WHY THIS EXISTS (bug report 20261118-004944-c84a). Nothing in the launcher
# ever removed an image. Every rebuild of the shared base (claude-sandbox:<v>
# plus :latest) or of a project layer (claude-<project>-<hash>-image:<content
# hash>) left the previous image and its whole layer chain behind, so the
# podman machine's disk only grew: 291 images, 16.5 GB of a 30 GB disk, until
# a project build died with "no space left on device" and the launcher said
# only "failed (exit 125) ... the output above is podman's own explanation",
# the explanation being the last line of a 4,500-line log.
#
# WHAT IS REMOVED, after a SUCCESSFUL build only:
#   - for each repository named by the caller (this project's image repository
#     and/or the shared base's), every OTHER tag of it, except
#       * the current tag, and for the base also :latest and every tag on the
#         image :latest points at;
#       * the newest previous tag (the fallback: kept even when nothing uses it);
#       * any tag whose image a container (running or stopped) was created from;
#       * for the base, tags that are not shaped like a version (someone's own
#         tag is not ours to delete).
#   - then dangling images (`image prune -f --filter until=1h`: untagged, childless and an hour old).
# Another project's images are never candidates: candidates come only from the
# named repositories. `rmi` is never forced, so an image some other image is
# built on, or a container uses after all, is refused by the runtime itself
# and simply stays.
#
# BEST EFFORT, ALWAYS. If the listing fails nothing is removed (an unknown
# in-use set is not an empty one). A removal that fails is reported in ONE
# line and never fails the launch. A timed-out call ends the cleanup, so a
# wedged runtime costs one bound, not one per tag.
#
# PURE ENOUGH TO TEST: every runtime call goes through the injected runner,
# which has BoundedRun::run's result contract ({ rc, out, err, timed_out }).
use strict;
use warnings;
use Time::Local ();

our $DISK_FULL_RE = qr/no space left on device/i;

# A refusal that means "this image is still needed", not "removal broke".
my $NEEDED_RE = qr/dependent child|has dependent|child images|in use by|is using its referenced image|used by container|image is in use/i;

# ---------------------------------------------------------------------------
# parsing
# ---------------------------------------------------------------------------

# norm_id($id) -> lowercase hex without a "sha256:" prefix, or ''.
sub norm_id {
    my ($id) = @_;
    return '' unless defined $id;
    $id =~ s/\A\s+|\s+\z//g;
    $id = lc $id;
    $id =~ s/\Asha256://;
    return $id =~ /\A[0-9a-f]+\z/ ? $id : '';
}

# same_id($a, $b) -> 1 when two ids name one image. Either side may be the
# truncated 12-character form, so the shorter must prefix the longer.
sub same_id {
    my ($a, $b) = map { norm_id($_) } @_;
    return 0 unless length($a) >= 12 && length($b) >= 12;
    my ($s, $l) = length($a) <= length($b) ? ($a, $b) : ($b, $a);
    return substr($l, 0, length $s) eq $s ? 1 : 0;
}

# norm_repo($repo) -> the repository without the registry prefix podman
# (localhost/) or docker (docker.io/library/) adds for a local name.
sub norm_repo {
    my ($r) = @_;
    return '' unless defined $r;
    $r =~ s/\A\s+|\s+\z//g;
    $r =~ s{\A(?:localhost/|docker\.io/library/|docker\.io/)}{};
    return lc $r;
}

# parse_created($text) -> epoch seconds | 0. Accepts the CreatedAt both
# runtimes print ("2026-11-18 00:49:44.123 +0000 UTC") and a bare epoch.
sub parse_created {
    my ($t) = @_;
    return 0 unless defined $t;
    return $1 + 0 if $t =~ /\A\s*(\d{9,})\s*\z/;
    return 0 unless $t =~ /(\d{4})-(\d\d)-(\d\d)[ T](\d\d):(\d\d):(\d\d)(?:\.\d+)?\s*(?:([+-])(\d\d):?(\d\d)|Z)?/;
    my $e = eval { Time::Local::timegm($6, $5, $4, $3, $2 - 1, $1) };
    return 0 unless defined $e;
    if (defined $7) {
        my $off = ($8 * 3600 + $9 * 60) * ($7 eq '-' ? -1 : 1);
        $e -= $off;
    }
    return $e;
}

# The format both runtimes accept for `images`: one tab-separated row per tag.
sub IMAGES_FORMAT { return "{{.ID}}\t{{.Repository}}\t{{.Tag}}\t{{.CreatedAt}}" }

# parse_images($text) -> [ { id, repo, tag, created, ref } ], tagged rows only.
sub parse_images {
    my ($text) = @_;
    my @rows;
    for my $line (split /\r?\n/, defined $text ? $text : '') {
        my ($id, $repo, $tag, $created) = split /\t/, $line, 4;
        next unless defined $tag;
        $id = norm_id($id);
        next unless length $id;
        next if !length($repo) || $repo eq '<none>' || !length($tag) || $tag eq '<none>';
        $repo =~ s/\A\s+|\s+\z//g;
        $tag  =~ s/\A\s+|\s+\z//g;
        push @rows, { id => $id, repo => $repo, tag => $tag,
                      created => parse_created($created), ref => "$repo:$tag" };
    }
    return \@rows;
}

# parse_ids($text) -> [ normalised ids ], one per non-empty line.
sub parse_ids {
    my ($text) = @_;
    return [ grep { length } map { norm_id($_) } split /\r?\n/, defined $text ? $text : '' ];
}

# split_ref("localhost/claude-x-image:abc") -> ("localhost/claude-x-image", "abc").
sub split_ref {
    my ($ref) = @_;
    return ('', '') unless defined $ref && $ref =~ m{\A(.+):([^:/]+)\z};
    return ($1, $2);
}

sub _version_key {
    my ($tag) = @_;
    my @n = $tag =~ /(\d+)/g;
    return @n;
}

sub _cmp_version {
    my ($a, $b) = @_;
    my @a = _version_key($a);
    my @b = _version_key($b);
    while (@a || @b) {
        my $x = @a ? shift @a : -1;
        my $y = @b ? shift @b : -1;
        return $x <=> $y if $x != $y;
    }
    return $a cmp $b;
}

# ---------------------------------------------------------------------------
# select_removals(%o) -> { remove => [refs], keep => [ { ref, why } ] }
#
#   images        parse_images rows
#   in_use        [ ids of images containers were created from ]
#   repo          the repository to clean (prefix-insensitive)
#   current_tag   the tag just built (never removed)
#   kind          'base' | 'project'. base: :latest and every tag sharing its
#                 image are current too; only version-shaped tags are
#                 candidates; ordering is by version. project: by creation.
#   keep_previous how many previous tags to keep as fallback (default 1)
# ---------------------------------------------------------------------------
sub select_removals {
    my (%o) = @_;
    my $want = norm_repo($o{repo});
    my $kind = defined $o{kind} ? $o{kind} : 'project';
    my $keep_n = defined $o{keep_previous} ? $o{keep_previous} : 1;
    my @in_use = @{ $o{in_use} || [] };
    my @rows = grep { norm_repo($_->{repo}) eq $want } @{ $o{images} || [] };
    return { remove => [], keep => [] } unless length $want && @rows;

    my %current = map { $_ => 1 } grep { defined } ($o{current_tag}, ($kind eq 'base' ? 'latest' : ()));
    my @current_ids = map { $_->{id} } grep { $current{ $_->{tag} } } @rows;

    my (@keep, @cand);
    for my $r (@rows) {
        if ($current{ $r->{tag} } || grep { same_id($_, $r->{id}) } @current_ids) {
            push @keep, { ref => $r->{ref}, why => 'current' };
        } elsif ($kind eq 'base' && $r->{tag} !~ /\A\d+\.\d+\.\d+/) {
            push @keep, { ref => $r->{ref}, why => 'not a version tag' };
        } else {
            push @cand, $r;
        }
    }
    @cand = $kind eq 'base'
        ? sort { _cmp_version($b->{tag}, $a->{tag}) || $b->{created} <=> $a->{created} } @cand
        : sort { $b->{created} <=> $a->{created} || $b->{tag} cmp $a->{tag} } @cand;

    my @remove;
    my $kept_prev = 0;
    for my $r (@cand) {
        if ($kept_prev < $keep_n) {
            $kept_prev++;
            push @keep, { ref => $r->{ref}, why => 'previous' };
        } elsif (grep { same_id($_, $r->{id}) } @in_use) {
            push @keep, { ref => $r->{ref}, why => 'in use by a container' };
        } else {
            push @remove, $r->{ref};
        }
    }
    return { remove => \@remove, keep => \@keep };
}

# ---------------------------------------------------------------------------
# cleanup(%o) -> { removed => [refs], kept => [ {ref, why} ], failed => [ {ref, error} ],
#                  pruned => 0|1, skipped => reason|undef, lines => [ for the operator ] }
#
#   run      coderef(\@argv) -> BoundedRun-shaped result. Required.
#   cli      the container CLI (podman / docker path).
#   targets  [ { repo, current_tag, kind } ]
#   prune    run `image prune -f` afterwards (default 1)
# ---------------------------------------------------------------------------
sub cleanup {
    my (%o) = @_;
    my $run = $o{run};
    my $cli = $o{cli};
    my $res = { removed => [], kept => [], failed => [], pruned => 0, skipped => undef, lines => [] };
    return { %$res, skipped => 'no runner' } unless ref $run eq 'CODE' && defined $cli;

    my $call = sub {
        my $r = eval { $run->([ $cli, @_ ]) };
        $r = { rc => -1, out => '', err => ($@ || 'runner failed'), timed_out => 0 } unless ref $r eq 'HASH';
        return $r;
    };
    my $ok = sub { my ($r) = @_; return !$r->{timed_out} && defined $r->{rc} && $r->{rc} == 0 };
    my $why = sub {
        my ($r) = @_;
        return 'timed out' if $r->{timed_out};
        my $t = join(' ', grep { defined && length } $r->{err}, $r->{out});
        $t =~ s/\s+/ /g;
        $t =~ s/\A\s+|\s+\z//g;
        $t = substr($t, 0, 160) . '...' if length $t > 160;
        return length $t ? $t : 'exit ' . (($r->{rc} // -1) >> 8);
    };

    my $im = $call->('images', '--no-trunc', '--format', IMAGES_FORMAT());
    my $ps = $ok->($im) ? $call->('ps', '-a', '-q', '--no-trunc') : undef;
    unless ($ok->($im) && $ps && $ok->($ps)) {
        my $r = $ok->($im) ? $ps : $im;
        $res->{skipped} = 'listing images/containers failed: ' . $why->($r);
        push @{ $res->{lines} }, "old images were not cleaned up (listing images/containers failed: " . $why->($r) . ')';
        return $res;
    }
    my $cids = parse_ids($ps->{out});
    my @in_use;
    if (@$cids) {
        my $ci = $call->('container', 'inspect', '--format', '{{.Image}}', @$cids);
        # A container can vanish between ps and inspect; whatever was printed
        # still counts, but nothing printed at all means the set is unknown.
        @in_use = @{ parse_ids($ci->{out}) };
        if ($ci->{timed_out} || !@in_use) {
            $res->{skipped} = 'inspecting containers failed: ' . $why->($ci);
            push @{ $res->{lines} }, 'old images were not cleaned up (inspecting containers failed: ' . $why->($ci) . ')';
            return $res;
        }
    }
    my $images = parse_images($im->{out});

    my $stop = 0;
    for my $t (@{ $o{targets} || [] }) {
        last if $stop;
        my $sel = select_removals(images => $images, in_use => \@in_use,
                                     repo => $t->{repo}, current_tag => $t->{current_tag},
                                     kind => $t->{kind}, keep_previous => $t->{keep_previous});
        push @{ $res->{kept} }, @{ $sel->{keep} };
        for my $ref (@{ $sel->{remove} }) {
            my $r = $call->('rmi', $ref);
            if ($ok->($r)) {
                push @{ $res->{removed} }, $ref;
            } elsif (!$r->{timed_out} && $why->($r) =~ $NEEDED_RE) {
                push @{ $res->{kept} }, { ref => $ref, why => 'still needed: ' . $why->($r) };
            } else {
                push @{ $res->{failed} }, { ref => $ref, error => $why->($r) };
                if ($r->{timed_out}) { $stop = 1; last }
            }
        }
    }
    if (!$stop && (defined $o{prune} ? $o{prune} : 1)) {
        # until=1h: no image build is serialised against another project's, and a
        # build's just-committed step is untagged and childless (dangling) until
        # its next step lands, so an unfiltered prune could pull a layer out from
        # under a concurrent build. Leftovers an hour old are nobody's work.
        my $r = $call->('image', 'prune', '-f', '--filter', 'until=1h');
        if ($ok->($r)) { $res->{pruned} = 1 }
        else           { push @{ $res->{failed} }, { ref => 'dangling images (image prune -f --filter until=1h)', error => $why->($r) } }
    }
    if (@{ $res->{failed} }) {
        push @{ $res->{lines} }, 'could not remove ' . join('; ', map { "$_->{ref} ($_->{error})" } @{ $res->{failed} })
            . '. The launch continues; `podman system df` shows what images hold.';
    }
    return $res;
}

# ---------------------------------------------------------------------------
# disk full
# ---------------------------------------------------------------------------

# disk_full($text) -> 1 when a build's output says the disk ran out.
sub disk_full {
    my ($text) = @_;
    return (defined $text && $text =~ $DISK_FULL_RE) ? 1 : 0;
}

# disk_full_lines(%o) -> the explanation to print under a failed build's
# ERROR line. %o: df (the text of `df -h /` in the machine, optional),
# cli_name ('podman' | 'docker').
sub disk_full_lines {
    my (%o) = @_;
    my $cli = defined $o{cli_name} && length $o{cli_name} ? $o{cli_name} : 'podman';
    my @l = ("  Cause: no space left on device -- the $cli machine's disk is full.");
    if (defined $o{df} && $o{df} =~ /\S/) {
        push @l, '  Free space in the machine (df -h /):';
        push @l, map { "    $_" } grep { /\S/ } split /\r?\n/, $o{df};
    }
    push @l,
        "  See what takes the space: $cli system df",
        "  Free it: $cli image prune -f removes dangling layers; $cli image prune -a removes every image no",
        "  container uses (the sandbox rebuilds its own on the next launch). Successful builds remove the",
        "  images they supersede by themselves, so this is needed once, not after every build.";
    return @l;
}

1;
