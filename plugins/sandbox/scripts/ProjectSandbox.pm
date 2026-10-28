package ProjectSandbox;
# A project's own sandbox settings: `claude-sandbox.json` at the project root.
#
# Lets a project (1) build its own image layer on top of the shared claude-sandbox image, and
# (2) ask for a short, fixed allowlist of extra container settings -- the ones running podman
# inside the sandbox needs (`/dev/fuse`, `label=disable`) and named volumes for state that must
# survive a container rebuild (inner container storage, caches, a dev service's data).
#
# WHY AN ALLOWLIST AND NOT PASS-THROUGH FLAGS. The manifest is a file in the project, and the
# agents in the sandbox can edit it. Whatever it asks for takes effect at the operator's next
# launch, so it must never be able to ask for more than this list: no --privileged, no extra
# capabilities, no host binds, no host network. Everything outside the list fails the launch
# (closed, with the reason), and the launcher prints what a manifest grants on every launch.
#
# Pure functions only (no podman calls), so t/project-sandbox.t can hold every rule to account.
#
# Manifest shape:
#   {
#     "image": { "context": "container/dev", "containerfile": "Containerfile",
#                "build_args": { "PIN_MODE": "strict" } },
#     "run":   { "devices": ["/dev/fuse"], "security_opt": ["label=disable"],
#                "volumes": [ { "name": "cells", "target": "/var/lib/containers" } ] }
#   }
# The project's Containerfile receives the shared image as `--build-arg BASE_IMAGE=<ref>` and
# should start with `ARG BASE_IMAGE` / `FROM ${BASE_IMAGE}`.

use strict;
use warnings;
use Exporter qw(import);
use JSON::PP ();
use Digest::MD5 ();
use File::Find ();

our @EXPORT_OK = qw(load validate create_args resource_args memory_limit spec_signature image_hash image_tag describe);

our $MANIFEST_NAME = 'claude-sandbox.json';

our %ALLOWED_DEVICES      = map { $_ => 1 } ('/dev/fuse');
our %ALLOWED_SECURITY_OPT = map { $_ => 1 } ('label=disable');

# Volume targets the manifest may not cover: the project bind, the Claude home, and system trees.
our @FORBIDDEN_TARGET_PREFIXES = qw(/project /root/.claude /proc /sys /dev /etc/ssh /usr /bin /sbin /lib /lib64 /boot);

my $REL_PATH_RE  = qr{\A(?!/)(?!.*(?:\A|/)\.\.(?:/|\z))[A-Za-z0-9._/-]{1,200}\z};
my $VOL_NAME_RE  = qr{\A[a-z0-9][a-z0-9-]{0,39}\z};
my $ARG_KEY_RE   = qr{\A[A-Z][A-Z0-9_]{0,63}\z};
my $ARG_VALUE_RE = qr{\A[A-Za-z0-9._:/+-]{0,200}\z};

# load($project_path) -> ($spec_or_undef, \@errors)
# No manifest: (undef, []). A manifest that does not parse or validate: (undef, [reasons]).
sub load {
    my ($project_path) = @_;
    my $path = "$project_path/$MANIFEST_NAME";
    return (undef, []) unless -e $path;
    open my $fh, '<:raw', $path or return (undef, ["$MANIFEST_NAME: cannot read: $!"]);
    my $text = do { local $/; <$fh> };
    close $fh;
    my $data = eval { JSON::PP->new->relaxed(0)->decode($text) };
    return (undef, ["$MANIFEST_NAME: not valid JSON: " . ($@ =~ s/\s+\z//r)]) unless defined $data;
    my @errors = validate($data, $project_path);
    return @errors ? (undef, \@errors) : ($data, []);
}

# validate($data, $project_path) -> list of human-readable errors (empty when valid).
sub validate {
    my ($data, $project_path) = @_;
    my @e;
    return ("$MANIFEST_NAME: the top level must be an object") unless ref $data eq 'HASH';
    for my $k (sort keys %$data) {
        push @e, "$MANIFEST_NAME: unknown key '$k' (allowed: image, run)" unless $k eq 'image' || $k eq 'run';
    }
    if (exists $data->{image}) {
        my $img = $data->{image};
        if (ref $img ne 'HASH') { push @e, "image: must be an object" }
        else {
            for my $k (sort keys %$img) {
                push @e, "image: unknown key '$k' (allowed: context, containerfile, build_args)"
                    unless $k =~ /\A(?:context|containerfile|build_args)\z/;
            }
            my $ctx = $img->{context};
            if (!defined $ctx || ref $ctx || $ctx !~ $REL_PATH_RE) {
                push @e, "image.context: must be a relative path inside the project, without '..'";
            }
            elsif (defined $project_path && !-d "$project_path/$ctx") {
                push @e, "image.context: '$ctx' is not a directory in the project";
            }
            my $cf = $img->{containerfile} // 'Containerfile';
            if (ref $cf || $cf !~ $REL_PATH_RE) {
                push @e, "image.containerfile: must be a relative path inside image.context, without '..'";
            }
            elsif (defined $project_path && defined $ctx && !ref $ctx && -d "$project_path/$ctx"
                   && !-f "$project_path/$ctx/$cf") {
                push @e, "image.containerfile: '$ctx/$cf' does not exist";
            }
            if (exists $img->{build_args}) {
                my $ba = $img->{build_args};
                if (ref $ba ne 'HASH') { push @e, "image.build_args: must be an object of NAME: value" }
                else {
                    for my $k (sort keys %$ba) {
                        push @e, "image.build_args: '$k' is not an UPPER_CASE name" unless $k =~ $ARG_KEY_RE;
                        push @e, "image.build_args: 'BASE_IMAGE' is set by the launcher" if $k eq 'BASE_IMAGE';
                        push @e, "image.build_args.$k: value must be plain text (letters, digits, . _ : / + -)"
                            if ref $ba->{$k} || !defined $ba->{$k} || $ba->{$k} !~ $ARG_VALUE_RE;
                    }
                }
            }
        }
    }
    if (exists $data->{run}) {
        my $run = $data->{run};
        if (ref $run ne 'HASH') { push @e, "run: must be an object" }
        else {
            for my $k (sort keys %$run) {
                push @e, "run: unknown key '$k' (allowed: devices, security_opt, volumes, memory, cpus)"
                    unless $k =~ /\A(?:devices|security_opt|volumes|memory|cpus)\z/;
            }
            if (exists $run->{memory}) {
                my $m = $run->{memory};
                push @e, "run.memory: must look like 6g or 4096m (at least 512m)"
                    unless defined $m && !ref $m && $m =~ /\A(\d{1,6})([mg])\z/ && ($2 eq 'g' ? $1 * 1024 : $1) >= 512;
            }
            if (exists $run->{cpus}) {
                my $c = $run->{cpus};
                push @e, "run.cpus: must be a number from 0.5 to 64"
                    unless defined $c && !ref $c && $c =~ /\A\d{1,2}(?:\.\d{1,2})?\z/ && $c >= 0.5 && $c <= 64;
            }
            for my $d (@{ _list($run, 'devices', \@e) }) {
                push @e, "run.devices: '" . _show($d) . "' is not allowed (allowed: "
                    . join(', ', sort keys %ALLOWED_DEVICES) . ")" unless !ref $d && $ALLOWED_DEVICES{$d};
            }
            for my $s (@{ _list($run, 'security_opt', \@e) }) {
                push @e, "run.security_opt: '" . _show($s) . "' is not allowed (allowed: "
                    . join(', ', sort keys %ALLOWED_SECURITY_OPT) . ")" unless !ref $s && $ALLOWED_SECURITY_OPT{$s};
            }
            my (%names, %targets);
            for my $v (@{ _list($run, 'volumes', \@e) }) {
                if (ref $v ne 'HASH') { push @e, "run.volumes: each entry must be {name, target}"; next }
                for my $k (sort keys %$v) {
                    push @e, "run.volumes: unknown key '$k' (allowed: name, target)" unless $k =~ /\A(?:name|target)\z/;
                }
                my ($n, $t) = @{$v}{qw(name target)};
                if (!defined $n || ref $n || $n !~ $VOL_NAME_RE) {
                    push @e, "run.volumes: name '" . _show($n) . "' must be 1-40 of a-z, 0-9, '-'";
                }
                elsif ($names{$n}++) { push @e, "run.volumes: name '$n' is used twice" }
                if (!defined $t || ref $t || $t !~ m{\A/[A-Za-z0-9._/-]{1,200}\z} || $t =~ m{(?:\A|/)\.\.(?:/|\z)}) {
                    push @e, "run.volumes: target '" . _show($t) . "' must be an absolute path without '..'";
                }
                else {
                    (my $tn = $t) =~ s{/+\z}{};
                    if ($tn eq '') { push @e, "run.volumes: target '/' is not allowed" }
                    for my $p (@FORBIDDEN_TARGET_PREFIXES) {
                        push @e, "run.volumes: target '$t' is inside '$p', which is not allowed"
                            if $tn eq $p || index($tn, "$p/") == 0;
                    }
                    push @e, "run.volumes: target '$t' is used twice" if $targets{$tn}++;
                }
            }
        }
    }
    return @e;
}

sub _list {
    my ($h, $k, $e) = @_;
    return [] unless exists $h->{$k};
    return $h->{$k} if ref $h->{$k} eq 'ARRAY';
    push @$e, "run.$k: must be a list";
    return [];
}

sub _show { my ($x) = @_; return defined $x ? (ref $x ? '(not text)' : $x) : '(missing)' }

# Volume names are scoped to the container, so two projects never share one by accident.
sub volume_name { my ($container_name, $name) = @_; return "$container_name-$name" }

# create_args($spec, $container_name) -> extra `podman create` args, in `-v NAME:TARGET` form for
# volumes (the launcher's convert_v_to_mount turns a bare name into `--mount type=volume`).
sub create_args {
    my ($spec, $container_name) = @_;
    return () unless $spec && $spec->{run};
    my $run = $spec->{run};
    my @a;
    push @a, '--device', $_ for @{ $run->{devices} || [] };
    push @a, '--security-opt', $_ for @{ $run->{security_opt} || [] };
    push @a, '-v', volume_name($container_name, $_->{name}) . ":$_->{target}" for @{ $run->{volumes} || [] };
    return @a;
}

# memory_limit($spec, $host_mem_bytes) -> the memory limit for the sandbox container AND for image
# builds, as a podman size ("6144m"), or undef when nothing is known.
#
# WHY EVERY SANDBOX GETS ONE. On Windows the containers share one podman VM. A container (or a
# build) with no limit can use the whole VM, and when the VM runs out of memory it can go down
# with every container in it. With a limit, only the offender is killed. Default: three quarters
# of what the podman host has, so the VM always keeps headroom for itself and other containers;
# a project may set its own value with run.memory.
our $DEFAULT_MEMORY_FRACTION = 0.75;
sub memory_limit {
    my ($spec, $host_mem_bytes) = @_;
    my $m = $spec && $spec->{run} ? $spec->{run}{memory} : undef;
    return $m if defined $m;
    return undef unless $host_mem_bytes && $host_mem_bytes =~ /\A\d+\z/ && $host_mem_bytes > 0;
    my $mib = int($host_mem_bytes * $DEFAULT_MEMORY_FRACTION / 1048576);
    return $mib >= 512 ? "${mib}m" : undef;
}

# resource_args($spec, $host_mem_bytes) -> `--memory`/`--cpus` args for `podman create`.
# --memory-swap equals --memory, so a container cannot push the VM into heavy swapping either.
sub resource_args {
    my ($spec, $host_mem_bytes) = @_;
    my @a;
    my $m = memory_limit($spec, $host_mem_bytes);
    push @a, '--memory', $m, '--memory-swap', $m if defined $m;
    push @a, '--cpus', $spec->{run}{cpus} if $spec && $spec->{run} && defined $spec->{run}{cpus};
    return @a;
}

# spec_signature($spec) -> a stable string of everything in the manifest; recorded at container
# create, compared on the next launch (a change means the container must be recreated).
sub spec_signature {
    my ($spec) = @_;
    return 'none' unless $spec;
    return Digest::MD5::md5_hex(JSON::PP->new->canonical(1)->encode($spec));
}

# image_hash($project_path, $spec, $base_image_id) -> hex digest of everything the project image
# is built from: the base image id, the build args, and every file under the context.
sub image_hash {
    my ($project_path, $spec, $base_id) = @_;
    my $img = $spec->{image};
    my $ctx = "$project_path/$img->{context}";
    my @files;
    File::Find::find({ no_chdir => 1, wanted => sub { push @files, $File::Find::name if -f $File::Find::name } }, $ctx);
    my $md5 = Digest::MD5->new;
    $md5->add("base:$base_id\n");
    $md5->add("containerfile:" . ($img->{containerfile} // 'Containerfile') . "\n");
    my $ba = $img->{build_args} || {};
    $md5->add("arg:$_=$ba->{$_}\n") for sort keys %$ba;
    for my $f (sort @files) {
        (my $rel = $f) =~ s{\A\Q$ctx\E/?}{};
        open my $fh, '<:raw', $f or die "cannot read $f: $!\n";
        my $fm = Digest::MD5->new->addfile($fh)->hexdigest;
        close $fh;
        $md5->add("file:$rel:$fm\n");
    }
    return $md5->hexdigest;
}

# image_tag($container_name, $hash) -> the local image reference for a project layer.
sub image_tag {
    my ($container_name, $hash) = @_;
    return 'localhost/' . lc($container_name) . '-image:' . substr($hash, 0, 12);
}

# describe($spec) -> lines for the launch screen: what this manifest grants.
sub describe {
    my ($spec) = @_;
    return () unless $spec;
    my @l;
    push @l, "image layer from $spec->{image}{context}/" . ($spec->{image}{containerfile} // 'Containerfile') if $spec->{image};
    my $run = $spec->{run} || {};
    push @l, 'device ' . join(', ', @{ $run->{devices} }) if @{ $run->{devices} || [] };
    push @l, 'security option ' . join(', ', @{ $run->{security_opt} }) if @{ $run->{security_opt} || [] };
    push @l, 'volume ' . join(', ', map { "$_->{name} at $_->{target}" } @{ $run->{volumes} }) if @{ $run->{volumes} || [] };
    push @l, "memory $run->{memory}" if defined $run->{memory};
    push @l, "cpus $run->{cpus}" if defined $run->{cpus};
    return @l;
}

1;
