package SandboxIdentity;
# Who this sandbox launcher is, and where its own tooling lives.
#
# Two kinds of fact, kept in one place so a downstream fork that ships its own
# launcher (a second command next to claude-sandbox, run from its own checkout)
# changes this file and nothing else:
#
#   * identity -- the names this launcher stamps on machine-wide things: the
#     container image, container names, the in-container hostname, the
#     Windows Terminal profile, and the id it presents to refusal markers
#     (RefusalMarker.pm). Two launchers with different identities never build
#     over each other's image or adopt each other's containers.
#
#   * install_root -- the checkout this launcher runs FROM, derived from this
#     file's own location (<root>/plugins/sandbox/scripts/SandboxIdentity.pm).
#     Everything the launcher mounts or copies out of its own tooling (the
#     container template, statusline, backpack scripts, the custom-skills dir,
#     the ccpraxis-local plugin tree) comes from here, never from a hard-coded
#     ~/.claude/ccpraxis. For the live install the two are the same directory,
#     so nothing changes there; a fork's launcher serves the fork.

use strict;
use warnings;
use Exporter qw(import);
use File::Basename qw(dirname);
use Cwd ();

our @EXPORT_OK = qw(
    install_root
    image_ref
    container_name
    is_sandbox_container_name
    directory_marketplace_source
);

# ---- identity (a fork edits these lines) --------------------------------

# Launcher id: image repository, hostname, refusal-marker id, WT profile name.
our $ID = 'claude-sandbox';

# Prefix of every container this launcher creates: <prefix>-<project>-<8 hex>.
our $CONTAINER_PREFIX = 'claude';

# Host names this launcher's containers must not reach. Each is pinned to
# 0.0.0.0 in the container's /etc/hosts at create time (--add-host), so any
# lookup inside the container lands nowhere. A guardrail, not a wall: root in
# the container can edit /etc/hosts. Empty for ccpraxis; a fork fills it in.
our @BLOCKED_HOSTS = ();

# Claude Code version baked into this launcher's image. undef (ccpraxis) means
# follow the host: the image is built with whatever `claude --version` reports,
# and a host update forces a rebuild. A fork that sets a version gets that
# version, always, independent of the host.
our $CLAUDE_VERSION;

# ---- derived ----------------------------------------------------------------

# claude_version($host_version) -> the version to build and record: the pinned
# $CLAUDE_VERSION when set (and shaped like a version), else $host_version.
sub claude_version {
    my ($host) = @_;
    return $CLAUDE_VERSION
        if defined $CLAUDE_VERSION && $CLAUDE_VERSION =~ /\A\d+\.\d+\.\d+(?:[-.][0-9A-Za-z.]+)?\z/;
    return $host;
}

# blocked_hosts() -> the valid entries of @BLOCKED_HOSTS, lowercased, in order,
# without duplicates. Anything that is not a plain DNS name is dropped, so an
# entry can never smuggle an extra argument into the container-create call.
sub blocked_hosts {
    my (%seen, @out);
    for my $h (@BLOCKED_HOSTS) {
        next unless defined $h;
        my $l = lc $h;
        next unless $l =~ /\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*\z/;
        push @out, $l unless $seen{$l}++;
    }
    return @out;
}

# blocked_host_args() -> the container-create arguments for blocked_hosts().
sub blocked_host_args {
    return map { ('--add-host', "$_:0.0.0.0") } blocked_hosts();
}

sub hostname             { return $ID }
sub wt_profile_name      { return $ID }
sub wt_fragment_filename { return "$ID.json" }

# image_ref($tag) -> "<id>:<tag>", default tag 'latest'.
sub image_ref {
    my ($tag) = @_;
    $tag = 'latest' unless defined $tag && length $tag;
    return "$ID:$tag";
}

# container_name($project_name, $path_hash8) -> "<prefix>-<project>-<hash>"
sub container_name {
    my ($project, $hash) = @_;
    return "$CONTAINER_PREFIX-$project-$hash";
}

# True for a name shaped like ANY sandbox launcher's container, this one's or
# another identity's. Used where launchers must see each other -- the port
# allocator, so two families never hand out the same port block. Matching
# too broadly only wastes a block; matching too narrowly causes a collision.
sub is_sandbox_container_name {
    my ($name) = @_;
    return 0 unless defined $name;
    return $name =~ /\A[a-z0-9][a-z0-9_.]*-.+-[0-9a-f]{8}\z/ ? 1 : 0;
}

my $ROOT;

# install_root() -> the checkout this module was loaded from, forward slashes,
# no trailing slash. Resolved once.
sub install_root {
    return $ROOT if defined $ROOT;
    (my $self = __FILE__) =~ s|\\|/|g;
    my $abs = Cwd::abs_path($self);
    die "ERROR: cannot resolve SandboxIdentity.pm's own path -- refusing to guess the install root\n"
        unless defined $abs;
    $abs =~ s|\\|/|g;
    my $root = dirname(dirname(dirname(dirname($abs))));
    # Same spelling winify_path gives $HOME-derived paths (drive-letter case
    # preserved), so the live install's mount strings are byte-identical to the
    # ~/.claude/ccpraxis literals this replaced.
    $root =~ s{^/([a-zA-Z])/}{$1:/} if $^O =~ /^(MSWin32|cygwin|msys)$/;
    return $ROOT = $root;
}

# directory_marketplace_source($name, $registry_path) -> the host directory
# that should back a directory-source marketplace inside the sandbox.
#
# The ccpraxis-local marketplace is this launcher's own plugin tree, so it is
# served from install_root()/plugins whenever that tree is a marketplace. For
# the live install that is the path the registry already holds; a fork's
# launcher serves the fork's plugins instead of the live install's. Every
# other marketplace keeps the registry's path.
sub directory_marketplace_source {
    my ($name, $registry_path) = @_;
    if (defined $name && $name eq 'ccpraxis-local') {
        my $own = install_root() . '/plugins';
        return $own if -f "$own/.claude-plugin/marketplace.json";
    }
    return $registry_path;
}

1;
