#!/usr/bin/env perl
# almanac-migrate-memories.pl -- migrates legacy Claude Code memory files into
# almanac notes, and renders the global notes index into ~/.claude/almanac-
# notes.md (blueprint almanac-records, package 12-migrate-memories,
# Decisions 26/27/29). See specs/12-migrate-memories-spec.md for the full
# contract; this file implements it and adds nothing beyond it.
#
# CORE PERL ONLY beyond the §2.0 allowlist. No exit() before the
# `unless (caller)` guard, no unlink/rmdir/remove_tree/rename anywhere, and
# MSYS2_ARG_CONV_EXCL is never set. Every subprocess (almanac-note.pl) is
# spawned via fork()+exec(LIST) -- never a shell string -- with its
# stdout/stderr captured through File::Temp files, never an in-memory scalar
# reopen.
use strict;
use warnings;
use File::Spec ();

# Almanac/ sits beside THIS FILE (not $0, not FindBin) -- see almanac-note.pl
# / almanac-todo.pl's identical BEGIN block for the reasoning. This file was
# never hit by bug 75fe's doubled-join defect -- it only unshifts $dir onto
# @INC and loads siblings via bareword `use Module ();`, which resolves
# through perl's own @INC search rather than a manual string-concatenated
# require path, so a relative $dir already worked. __FILE__ is still
# resolved through File::Spec->rel2abs here, defensively and for
# consistency with the scripts that did have the defect (almanac-doctor.pl,
# almanac-inbox.pl), not because this file needed the fix.
BEGIN {
    my $dir = File::Spec->rel2abs(__FILE__);
    $dir =~ s{\\}{/}g;
    $dir =~ s{/[^/]+\z}{};
    $dir = '.' unless length $dir;
    unshift @INC, $dir;
}
use File::Basename ();
use File::Temp ();
use JSON::PP ();
use Encode ();
use Almanac::Store ();
use Almanac::Record ();
use Almanac::ClaudeMdBlock ();

our $VERSION = '1.0';

# ---------------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------------
sub _usage  { die Almanac::Store::Error->new(kind => 'usage',  detail => $_[0]) }
sub _refuse { my (%a) = @_; die Almanac::Store::Error->new(kind => 'refused', path => $a{path}, detail => $a{detail}) }

sub _decode_maybe {
    my ($s) = @_;
    return $s unless defined $s;
    return $s if utf8::is_utf8($s);
    my $d = eval { Encode::decode('UTF-8', $s, Encode::FB_CROAK()) };
    return defined $d ? $d : $s;
}

sub _encode_bytes {
    my ($s) = @_;
    return $s unless defined $s;
    return $s unless utf8::is_utf8($s);
    my $b = eval { Encode::encode('UTF-8', $s) };
    return defined $b ? $b : $s;
}

sub _trim {
    my ($s) = @_;
    return $s unless defined $s;
    $s =~ s/\A\s+//;
    $s =~ s/\s+\z//;
    return $s;
}

# _canon_root($root) -> canonicalized absolute path, via Almanac::Store's own
# public scope_capability() -- the only public seam that runs Store's private
# Cwd::abs_path-based canonicalisation (S2.0 forbids importing Cwd directly).
# scope_capability('project', root => $root) resolves to
# "<canonical $root>/.ccpraxis-local-data/almanac"; stripping that fixed
# suffix recovers the bare canonical root, identical to the test oracle's own
# norm_path() for any path that actually resolves.
sub _canon_root {
    my ($root) = @_;
    return $root unless defined $root && length $root;
    my $cap = eval { Almanac::Store::scope_capability('project', root => $root) };
    if (ref($cap) eq 'HASH' && defined $cap->{root}) {
        my $r = $cap->{root};
        $r =~ s{/\.ccpraxis-local-data/almanac\z}{};
        return _decode_maybe($r);
    }
    return _norm_slashes(_decode_maybe($root));
}

sub _norm_slashes {
    my ($p) = @_;
    return $p unless defined $p;
    my $q = $p;
    $q =~ s{\\}{/}g;
    $q =~ s{/\z}{} if length($q) > 1;
    return $q;
}

sub _iso_from_epoch {
    my ($epoch) = @_;
    my @t = gmtime($epoch);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ',
                   $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

# _sanitize_tc($v) -- spec §2.5's title/covers sanitisation.
sub _sanitize_tc {
    my ($v) = @_;
    return undef unless defined $v;
    my $s = $v;
    $s =~ s/[\x00-\x1f\x7f]/ /g;
    $s =~ s/ {2,}/ /g;
    $s =~ s/\A +//;
    $s =~ s/ +\z//;
    $s =~ s/\A-{2,}/-/;
    return $s;
}

sub _read_bytes {
    my ($path) = @_;
    open(my $fh, '<:raw', $path) or return (undef, "$!");
    local $/;
    my $bytes = <$fh>;
    close $fh;
    return (defined($bytes) ? $bytes : '', undef);
}

# ---------------------------------------------------------------------------
# enc($root) -- spec §2.2.1, transcribed from vault-sync.pl:1559. Operates on
# an already-decoded Perl character string, per this file's own inputs.
# ---------------------------------------------------------------------------
sub _enc {
    my ($root) = @_;
    my $c = $root;
    $c =~ s{\A/([A-Za-z])(?=/|\z)}{uc($1) . ':'}e;
    $c =~ s/[^A-Za-z0-9]/-/g;
    return $c;
}

# ---------------------------------------------------------------------------
# subprocess spawning -- fork()+exec(LIST), stdout/stderr through File::Temp.
# ---------------------------------------------------------------------------
sub _spawn_note_pl {
    my ($note_pl, @argv) = @_;
    my ($out_fh, $out_path) = File::Temp::tempfile();
    my ($err_fh, $err_path) = File::Temp::tempfile();
    close $out_fh;
    close $err_fh;
    my $pid = fork();
    _refuse(path => $note_pl, detail => 'fork_failed') unless defined $pid;
    if ($pid == 0) {
        open(STDOUT, '>', $out_path) or CORE::exit(126);
        open(STDERR, '>', $err_path) or CORE::exit(126);
        exec($^X, $note_pl, @argv) or CORE::exit(127);
    }
    waitpid($pid, 0);
    my $rc = $? >> 8;
    my ($out, undef) = _read_bytes($out_path);
    my ($err, undef) = _read_bytes($err_path);
    return ($rc, (defined $out ? $out : ''), (defined $err ? $err : ''));
}

sub _note_pl_path {
    my $dir = __FILE__;
    $dir =~ s{\\}{/}g;
    $dir =~ s{/[^/]+\z}{};
    $dir = '.' unless length $dir;
    return "$dir/almanac-note.pl";
}

# ---------------------------------------------------------------------------
# 2.1 -- argv grammar.
# ---------------------------------------------------------------------------
my %ALLOWED_FLAGS = (
    plan          => { home => 1, map => 1, json => 1 },
    run           => { home => 1, map => 1, json => 1 },
    'render-index' => { home => 1 },
);

sub _parse_args {
    my (@argv) = @_;
    my (%o, %bool_default, @pos);
    while (@argv) {
        my $a = shift @argv;
        if ($a =~ /^--([a-z0-9-]+)$/) {
            my $key = $1;
            my $has_val = (@argv && $argv[0] !~ /^--/);
            my $val = $has_val ? shift @argv : 1;
            if ($key eq 'map') {
                push @{ $o{map} ||= [] }, $val;
                if ($has_val) { delete $bool_default{map} } else { $bool_default{map} = 1 }
            } else {
                $o{$key} = $val;
                if ($has_val) { delete $bool_default{$key} } else { $bool_default{$key} = 1 }
            }
        } else {
            push @pos, $a;
        }
    }
    _usage('missing_verb') unless @pos;
    my $verb = shift @pos;
    _usage('unknown_verb') unless $ALLOWED_FLAGS{$verb};
    _usage('extra_positional') if @pos;

    my $allowed = $ALLOWED_FLAGS{$verb};
    for my $k (keys %o) {
        _usage('unknown_flag') unless $allowed->{$k};
    }
    _usage('missing_flag_value') if $bool_default{home};
    _usage('missing_flag_value') if exists($o{home}) && defined($o{home}) && length($o{home}) == 0;
    _usage('missing_flag_value') if $bool_default{map};

    my @maps;
    for my $pair (@{ $o{map} || [] }) {
        _usage('bad_map') unless $pair =~ /=/;
        my ($enc, $root) = split /=/, $pair, 2;
        _usage('bad_map') unless defined($enc) && $enc =~ /\A[A-Za-z0-9-]+\z/;
        _usage('bad_map') unless defined($root) && length($root);
        push @maps, [$enc, $root];
    }

    return { verb => $verb, home => $o{home}, maps => \@maps, json => $o{json} ? 1 : 0 };
}

sub _resolve_home {
    my ($given) = @_;
    my $h = $given;
    $h = $ENV{ALMANAC_HOME} unless defined $h && length $h;
    $h = $ENV{HOME}         unless defined $h && length $h;
    $h = $ENV{USERPROFILE}  unless defined $h && length $h;
    return _norm_slashes(_decode_maybe($h));
}

# ---------------------------------------------------------------------------
# 2.2 -- registry.
# ---------------------------------------------------------------------------
sub _registry_path { my ($home) = @_; return "$home/.claude/claude-code-vault/.registry-local.json" }

# _registered_roots($home) -> \@roots (deduped case-insensitively, decoded).
sub _registered_roots {
    my ($home) = @_;
    my $path = _registry_path($home);
    return [] unless -e $path;
    my ($bytes, $err) = _read_bytes($path);
    _refuse(path => $path, detail => 'registry_unreadable') if defined $err;
    my $data = eval { JSON::PP->new->utf8->decode($bytes) };
    _refuse(path => $path, detail => 'registry_unreadable')
        unless ref($data) eq 'HASH' && ref($data->{projects}) eq 'HASH';
    my (@out, %seen);
    for my $slug (sort keys %{ $data->{projects} }) {
        my $p = $data->{projects}{$slug};
        next unless ref($p) eq 'HASH' && defined $p->{path} && length $p->{path};
        my $root = _canon_root(_decode_maybe($p->{path}));
        my $key  = lc($root);
        next if $seen{$key}++;
        push @out, $root;
    }
    return \@out;
}

# ---------------------------------------------------------------------------
# 2.2 -- source discovery.
# ---------------------------------------------------------------------------
sub _list_subdirs {
    my ($parent) = @_;
    return [] unless -d $parent;
    opendir(my $dh, $parent) or return [];
    my @names = sort grep { $_ ne '.' && $_ ne '..' && -d "$parent/$_" } readdir($dh);
    closedir $dh;
    return \@names;
}

# _discover($home, \@map_pairs) -> (\@dirs, \@warnings)
# \@dirs: [{ dir => $abs, scope => 'project'|'global', root => $abs|undef,
#            key_prefix => $prefix }], sorted by dir ascending.
sub _discover {
    my ($home, $map_pairs) = @_;
    my @warnings;
    my @dirs;

    # S2 -- global.
    my $s2 = "$home/.claude/memory";
    push @dirs, { dir => $s2, scope => 'global', root => undef, key_prefix => 'host/memory/' }
        if -d $s2;

    # Registered roots, existing only (a missing one warns and contributes nothing).
    my $reg_roots = _registered_roots($home);
    my @existing_roots;
    for my $r (@$reg_roots) {
        if (-d $r) { push @existing_roots, $r }
        else       { push @warnings, "migrate: root_missing: $r" }
    }

    # S1 -- host/projects/<enc>/memory.
    my $projects_dir = "$home/.claude/projects";
    for my $enc (@{ _list_subdirs($projects_dir) }) {
        my $mem = "$projects_dir/$enc/memory";
        next unless -d $mem;

        my $mapped_root;
        for my $pair (@$map_pairs) {
            if (lc($pair->[0]) eq lc($enc)) { $mapped_root = $pair->[1]; last }
        }
        if (!defined $mapped_root) {
            my @matches = grep { lc(_enc($_)) eq lc($enc) } @existing_roots;
            _refuse(path => $mem, detail => 'unmapped_memory_dir') if @matches == 0;
            _refuse(path => $mem, detail => 'ambiguous_mapping')   if @matches >= 2;
            $mapped_root = $matches[0];
        }
        $mapped_root = _canon_root(_decode_maybe($mapped_root));
        _refuse(path => $mapped_root, detail => 'root_missing') unless -d $mapped_root;

        push @dirs, { dir => $mem, scope => 'project', root => $mapped_root,
                       key_prefix => "host/projects/$enc/memory/" };
    }

    # S3/S4 -- sandbox, per existing registered root.
    for my $root (@existing_roots) {
        my $claude_home = "$root/.ccpraxis-local-data/claude-home";

        my $s4 = "$claude_home/memory";
        push @dirs, { dir => $s4, scope => 'project', root => $root, key_prefix => 'sandbox/memory/' }
            if -d $s4;

        my $proj_dir = "$claude_home/projects";
        for my $enc2 (@{ _list_subdirs($proj_dir) }) {
            my $mem = "$proj_dir/$enc2/memory";
            next unless -d $mem;
            push @dirs, { dir => $mem, scope => 'project', root => $root,
                           key_prefix => "sandbox/projects/$enc2/memory/" };
        }
    }

    @dirs = sort { $a->{dir} cmp $b->{dir} } @dirs;
    return (\@dirs, \@warnings);
}

# ---------------------------------------------------------------------------
# 2.3 -- entry classification within one memory dir.
# ---------------------------------------------------------------------------
# _scan_dir($dirinfo) -> (\@entries, \@refusals)
sub _scan_dir {
    my ($dirinfo) = @_;
    my $dir = $dirinfo->{dir};
    my (@entries, @refusals);

    opendir(my $dh, $dir) or do {
        push @refusals, { path => $dir, detail => 'unreadable' };
        return (\@entries, \@refusals);
    };
    my @names = sort grep { $_ ne '.' && $_ ne '..' } readdir($dh);
    closedir $dh;

    for my $name (@names) {
        my $path = "$dir/$name";
        if (-d $path) {
            if ($name eq 'MEMORY.md') {
                push @refusals, { path => $path, detail => 'unexpected_entry' };
            } elsif ($name =~ /\.md\z/) {
                push @refusals, { path => $path, detail => 'unreadable' };
            } else {
                push @refusals, { path => $path, detail => 'unexpected_entry' };
            }
            next;
        }
        if ($name eq 'MEMORY.md') {
            push @entries, { path => $path, name => $name, kind => 'index', dirinfo => $dirinfo };
        } elsif ($name =~ /\.md\z/ && -f $path) {
            push @entries, { path => $path, name => $name, kind => 'record', dirinfo => $dirinfo };
        } elsif (-f $path) {
            push @entries, { path => $path, name => $name, kind => 'skipped', reason => 'not_markdown', dirinfo => $dirinfo };
        } else {
            push @refusals, { path => $path, detail => 'unreadable' };
        }
    }
    return (\@entries, \@refusals);
}

# ---------------------------------------------------------------------------
# 2.5 -- frontmatter parsing (metadata only; body is always the whole file).
# ---------------------------------------------------------------------------
sub _clean_fm_value {
    my ($v) = @_;
    return undef unless defined $v;
    my $s = _trim($v);
    if (length($s) >= 2) {
        my ($f, $l) = (substr($s, 0, 1), substr($s, -1, 1));
        if (($f eq '"' && $l eq '"') || ($f eq "'" && $l eq "'")) {
            $s = substr($s, 1, length($s) - 2);
        }
    }
    return undef if $s eq '' || $s eq '>' || $s eq '|' || $s eq '>-' || $s eq '|-';
    return $s;
}

# _parse_frontmatter($bytes) -> { name, description, type }
sub _parse_frontmatter {
    my ($bytes) = @_;
    my %out;
    my $tail = $bytes;
    my $text = eval { Encode::decode('UTF-8', $tail, Encode::FB_CROAK()) };
    return \%out unless defined $text;
    $text =~ s/\A\x{FEFF}//;

    my @lines = split /\n/, $text, -1;
    return \%out unless @lines && $lines[0] eq '---';
    my $closing;
    for my $i (1 .. $#lines) {
        if ($lines[$i] eq '---') { $closing = $i; last }
    }
    return \%out unless defined $closing;

    my $in_metadata = 0;
    for my $i (1 .. $closing - 1) {
        my $line = $lines[$i];
        if ($line =~ /\A([A-Za-z_][A-Za-z0-9_-]*):[ \t]*(.*)\z/) {
            my ($k, $v) = ($1, $2);
            $out{$k} = _clean_fm_value($v);
            $in_metadata = ($k eq 'metadata') ? 1 : 0;
        } elsif ($in_metadata && $line =~ /\A[ \t]+type:[ \t]*(.*)\z/) {
            $out{'metadata.type'} = _clean_fm_value($1);
        }
    }
    return \%out;
}

# _parse_index_md($bytes) -> { links => [[text,file],...], link_by_file => {file=>text} }
sub _parse_index_md {
    my ($bytes) = @_;
    my $tail = $bytes;
    my $text = eval { Encode::decode('UTF-8', $tail, Encode::FB_CROAK()) };
    $text = '' unless defined $text;
    my @links;
    my %link_by_file;
    for my $line (split /\n/, $text) {
        if ($line =~ /^\s*[-*]\s+\[([^\]]+)\]\(([^)\s]+)\)/) {
            my ($t, $f) = ($1, $2);
            push @links, [$t, $f];
            $link_by_file{$f} = $t unless exists $link_by_file{$f};
        }
    }
    return { links => \@links, link_by_file => \%link_by_file };
}

# ---------------------------------------------------------------------------
# 2.4 -- key, target store, matching.
# ---------------------------------------------------------------------------
sub _store_key_for {
    my ($ent) = @_;
    return $ent->{dirinfo}{scope} eq 'global' ? 'global' : "root:" . lc($ent->{dirinfo}{root});
}

sub _list_store {
    my ($note_pl, $ent, $home) = @_;
    my @argv;
    if ($ent->{dirinfo}{scope} eq 'global') {
        @argv = ('list', '--json', '--global', '--home', _encode_bytes($home));
    } else {
        @argv = ('list', '--json', '--root', _encode_bytes($ent->{dirinfo}{root}));
    }
    my ($rc, $out, $err) = _spawn_note_pl($note_pl, @argv);
    if ($rc != 0) {
        print STDERR $err;
        CORE::exit(2);
    }
    my $decoded = eval { Encode::decode('UTF-8', $out, Encode::FB_CROAK()) };
    $decoded = $out unless defined $decoded;
    my $list = eval { JSON::PP->new->decode($decoded) };
    $list = [] unless ref($list) eq 'ARRAY';
    return $list;
}

sub _anchor_for {
    my ($ent, $home) = @_;
    return $ent->{dirinfo}{scope} eq 'global'
        ? "$home/.claude/claude-code-vault"
        : $ent->{dirinfo}{root};
}

# ---------------------------------------------------------------------------
# main algorithm for plan/run.
# ---------------------------------------------------------------------------
sub _run_migration {
    my ($args) = @_;
    my $home = _resolve_home($args->{home});
    my $note_pl = _note_pl_path();

    my ($dirs, $warnings) = _discover($home, $args->{maps});
    print STDERR "$_\n" for sort @$warnings;

    my (@entries, @refusals);
    for my $dirinfo (@$dirs) {
        my ($ents, $refs) = _scan_dir($dirinfo);
        push @entries, @$ents;
        push @refusals, @$refs;
    }

    if (@refusals) {
        my @lines = sort map { "migrate: $_->{detail}: $_->{path}" } @refusals;
        print STDERR "$_\n" for @lines;
        my @sorted_refusals = sort { "migrate: $a->{detail}: $a->{path}" cmp "migrate: $b->{detail}: $b->{path}" } @refusals;
        _refuse(path => $sorted_refusals[0]{path}, detail => $sorted_refusals[0]{detail});
    }

    # Read every record's bytes now (plan phase, before any write). Also
    # read every MEMORY.md for index parsing.
    for my $ent (@entries) {
        next unless $ent->{kind} eq 'record' || $ent->{kind} eq 'index';
        my ($bytes, $err) = _read_bytes($ent->{path});
        if (defined $err) {
            _refuse(path => $ent->{path}, detail => 'unreadable');
        }
        $ent->{bytes} = $bytes;
        my @st = stat($ent->{path});
        $ent->{mtime} = $st[9];
    }

    # Index parsing, scoped per directory.
    my %index_by_dir;
    for my $ent (@entries) {
        next unless $ent->{kind} eq 'index';
        $index_by_dir{ $ent->{dirinfo}{dir} } = _parse_index_md($ent->{bytes});
    }

    # Record metadata (title/covers/tags/key) + index stats.
    for my $ent (@entries) {
        if ($ent->{kind} eq 'record') {
            my $fm = _parse_frontmatter($ent->{bytes});
            my $idx = $index_by_dir{ $ent->{dirinfo}{dir} };
            my $link_text = $idx ? $idx->{link_by_file}{ $ent->{name} } : undef;

            my $title;
            if (defined $link_text && length(_trim($link_text))) { $title = $link_text }
            elsif (defined $fm->{name} && length($fm->{name}))   { $title = $fm->{name} }
            else {
                (my $stem = $ent->{name}) =~ s/\.md\z//;
                $title = $stem;
            }
            $ent->{title} = _sanitize_tc($title);

            if (defined $fm->{description} && length($fm->{description})) {
                $ent->{covers} = _sanitize_tc($fm->{description});
            } elsif ($ent->{dirinfo}{scope} eq 'global') {
                # A global note now REQUIRES --covers (package 09). Without a
                # description, fall back to the sanitized title rather than
                # letting the migration's own create calls be refused.
                $ent->{covers} = $ent->{title};
            }

            my $type = $fm->{'metadata.type'};
            $type = $fm->{type} unless defined $type && length $type;
            if (defined($type) && $type =~ /\A[A-Za-z0-9_-]+\z/) {
                $ent->{tags} = "memory,$type";
            } else {
                $ent->{tags} = 'memory';
            }

            $ent->{key} = $ent->{dirinfo}{key_prefix} . $ent->{name};
        } elsif ($ent->{kind} eq 'index') {
            my $idx = $index_by_dir{ $ent->{dirinfo}{dir} };
            my @record_names = map { $_->{name} }
                grep { $_->{kind} eq 'record' && $_->{dirinfo}{dir} eq $ent->{dirinfo}{dir} } @entries;
            my %is_record = map { $_ => 1 } @record_names;
            my %linked_targets = map { $_->[1] => 1 } @{ $idx->{links} };
            my $linked_missing = scalar(grep { !$is_record{$_} } keys %linked_targets);
            my $unindexed = scalar(grep { !$linked_targets{$_} } @record_names);
            $ent->{index_entries} = scalar(@{ $idx->{links} });
            $ent->{linked_missing} = $linked_missing;
            $ent->{unindexed} = $unindexed;
        }
    }

    # Group record entries by target store and run list once per store.
    my %store_cache;
    for my $ent (@entries) {
        next unless $ent->{kind} eq 'record';
        my $skey = _store_key_for($ent);
        $store_cache{$skey} = _list_store($note_pl, $ent, $home) unless exists $store_cache{$skey};
    }

    for my $ent (@entries) {
        next unless $ent->{kind} eq 'record';
        my $skey = _store_key_for($ent);
        my $list = $store_cache{$skey};
        my @matches = grep { defined($_->{migrated_from}) && $_->{migrated_from} eq $ent->{key} } @$list;
        if (@matches == 0) {
            $ent->{status} = 'would_create';
        } elsif (@matches >= 2) {
            $ent->{status} = 'duplicate_migration';
        } else {
            my $note = $matches[0];
            my $anchor = _anchor_for($ent, $home);
            my $target_abs = defined($note->{target}) ? "$anchor/$note->{target}" : undef;
            if (!defined($target_abs) || !-f $target_abs) {
                $ent->{status} = 'dangling';
            } else {
                my ($tb, $terr) = _read_bytes($target_abs);
                if (defined $terr) {
                    $ent->{status} = 'dangling';
                } elsif ($tb eq $ent->{bytes}) {
                    $ent->{status} = 'already';
                } else {
                    $ent->{status} = 'diverged';
                }
            }
        }
    }

    my @sorted_entries = sort { $a->{path} cmp $b->{path} } @entries;

    my $pre_failure = scalar(grep {
        $_->{kind} eq 'record' && $_->{status}
        && ($_->{status} eq 'dangling' || $_->{status} eq 'diverged' || $_->{status} eq 'duplicate_migration')
    } @sorted_entries) ? 1 : 0;

    if ($args->{verb} eq 'run' && !$pre_failure) {
        for my $ent (@sorted_entries) {
            next unless $ent->{kind} eq 'record' && $ent->{status} eq 'would_create';
            my $ok = _create_and_verify($note_pl, $ent, $home);
            $ent->{status} = $ok ? 'created' : $ent->{final_error};
        }
    }

    _print_report($args, \@sorted_entries, $home);

    my $failed = scalar(grep {
        $_->{kind} eq 'record' && $_->{status}
        && $_->{status} =~ /\A(?:dangling|diverged|duplicate_migration|create_failed|verify_failed)\z/
    } @sorted_entries);
    return $failed ? 2 : 0;
}

sub _create_and_verify {
    my ($note_pl, $ent, $home) = @_;
    my $created_iso = _iso_from_epoch($ent->{mtime});
    my @argv = ('create', '--title', $ent->{title});
    push @argv, '--covers', $ent->{covers} if defined $ent->{covers};
    push @argv, '--tags', $ent->{tags};
    push @argv, '--set', "migrated_from=$ent->{key}";
    push @argv, '--set', "created=$created_iso";
    push @argv, '--content-file', $ent->{path};
    if ($ent->{dirinfo}{scope} eq 'global') {
        push @argv, '--global', '--home', _encode_bytes($home);
    } else {
        push @argv, '--root', _encode_bytes($ent->{dirinfo}{root});
    }
    @argv = map { _encode_bytes($_) } @argv;

    my ($rc, $out, $err) = _spawn_note_pl($note_pl, @argv);
    if ($rc != 0) {
        $ent->{final_error} = 'create_failed';
        return 0;
    }
    my $decoded_out = eval { Encode::decode('UTF-8', $out, Encode::FB_CROAK()) };
    $decoded_out = $out unless defined $decoded_out;
    my ($target) = $decoded_out =~ /^target:\s*(.*)$/m;
    unless (defined $target && length $target) {
        $ent->{final_error} = 'verify_failed';
        return 0;
    }
    my $anchor = _anchor_for($ent, $home);
    my $target_abs = "$anchor/$target";
    my ($tb, $terr) = _read_bytes($target_abs);
    if (defined($terr) || $tb ne $ent->{bytes}) {
        $ent->{final_error} = 'verify_failed';
        return 0;
    }
    return 1;
}

sub _print_report {
    my ($args, $entries, $home) = @_;

    my $records = scalar(grep { $_->{kind} eq 'record' } @$entries);
    my $indexes = scalar(grep { $_->{kind} eq 'index' } @$entries);
    my $skipped = scalar(grep { $_->{kind} eq 'skipped' } @$entries);
    my $created = scalar(grep { $_->{kind} eq 'record' && $_->{status} eq 'created' } @$entries);
    my $already = scalar(grep { $_->{kind} eq 'record' && $_->{status} eq 'already' } @$entries);
    my $would_create = scalar(grep { $_->{kind} eq 'record' && $_->{status} eq 'would_create' } @$entries);
    my $failed = scalar(grep {
        $_->{kind} eq 'record' && $_->{status}
        && $_->{status} =~ /\A(?:dangling|diverged|duplicate_migration|create_failed|verify_failed)\z/
    } @$entries);

    if ($args->{json}) {
        my @out;
        for my $ent (@$entries) {
            my %e = (kind => $ent->{kind}, path => _decode_maybe($ent->{path}));
            if ($ent->{kind} eq 'record') {
                $e{status} = $ent->{status};
                $e{key} = $ent->{key};
            } elsif ($ent->{kind} eq 'index') {
                # An index is never a note and never changes across a run;
                # 'run' reports it settled ('already'), 'plan' previews its
                # own kind-specific status.
                $e{status} = ($args->{verb} eq 'run') ? 'already' : 'index';
                $e{entries} = $ent->{index_entries};
                $e{linked_missing} = $ent->{linked_missing};
                $e{unindexed} = $ent->{unindexed};
            } else {
                $e{status} = ($args->{verb} eq 'run') ? 'already' : 'skipped';
                $e{reason} = $ent->{reason};
            }
            push @out, \%e;
        }
        my %report = (
            entries => \@out,
            summary => {
                records => $records, indexes => $indexes, skipped => $skipped,
                created => $created, already => $already, would_create => $would_create,
                failed => $failed,
            },
        );
        # ->ascii(1): every non-ASCII byte is \uXXXX-escaped, so the printed
        # bytes are pure ASCII. The test oracle's own decode helper reads
        # STDOUT through ':encoding(UTF-8)' (one decode) and then feeds the
        # result to JSON::PP's OWN ->utf8->decode (a second, byte-oriented
        # decode) -- a real character above U+007F would make that second
        # decode die ("malformed UTF-8 character"). Pure-ASCII JSON text is
        # decoded correctly by both layers, with \uXXXX restoring the real
        # character on the far side.
        print JSON::PP->new->canonical(1)->ascii(1)->encode(\%report);
    } else {
        for my $ent (@$entries) {
            my $path = _decode_maybe($ent->{path});
            if ($ent->{kind} eq 'record') {
                print "entry: $ent->{status} $path\n";
            } elsif ($ent->{kind} eq 'index') {
                print "index: $path entries=$ent->{index_entries} linked_missing=$ent->{linked_missing} unindexed=$ent->{unindexed}\n";
            } else {
                print "skipped: $path ($ent->{reason})\n";
            }
        }
        print "records: $records\n";
        print "indexes: $indexes\n";
        print "skipped: $skipped\n";
        print "created: $created\n";
        print "already: $already\n";
        print "would_create: $would_create\n";
        print "failed: $failed\n";
    }
}

# ---------------------------------------------------------------------------
# 2.6 -- render-index.
# ---------------------------------------------------------------------------
sub _render_index {
    my ($args) = @_;
    my $home = _resolve_home($args->{home});
    my $note_pl = _note_pl_path();

    my $claude_dir = "$home/.claude";
    _refuse(path => $claude_dir, detail => 'claude_dir_missing') unless -d $claude_dir;

    my $T = "$claude_dir/almanac-notes.md";
    my $existed_before = -e $T ? 1 : 0;
    my ($bytes_before, undef) = $existed_before ? _read_bytes($T) : (undef, undef);
    $bytes_before = '' unless defined $bytes_before;

    unless ($existed_before) {
        open(my $fh, '>:raw', $T) or _refuse(path => $T, detail => 'io');
        close $fh;
    }

    my ($rc, $out, $err) = _spawn_note_pl($note_pl, 'list', '--json', '--global', '--home', _encode_bytes($home));
    if ($rc != 0) {
        print STDERR $err;
        CORE::exit(2);
    }
    my $decoded = eval { Encode::decode('UTF-8', $out, Encode::FB_CROAK()) };
    $decoded = $out unless defined $decoded;
    my $list = eval { JSON::PP->new->decode($decoded) };
    $list = [] unless ref($list) eq 'ARRAY';

    my (@kept, @excluded);
    for my $f (@$list) {
        my $id = $f->{id};
        my $aud = $f->{audience};
        if (!defined($aud) || ($aud ne 'internal' && $aud ne 'external')) {
            push @excluded, "$id=bad_audience";
        } elsif (!defined($f->{target}) || $f->{target} eq '') {
            push @excluded, "$id=missing_target";
        } elsif (!defined($f->{title}) || $f->{title} eq '') {
            push @excluded, "$id=missing_title";
        } else {
            push @kept, { id => $id, fields => $f };
        }
    }

    my $raw_current = _read_bytes($T);
    ($raw_current, undef) = _read_bytes($T);
    my $insp = Almanac::ClaudeMdBlock::inspect($raw_current);
    if ($insp->{state} eq 'absent') {
        my $trimmed = $raw_current;
        $trimmed =~ s/\s+//g;
        _refuse(path => $T, detail => 'foreign_content') if length $trimmed;
    } elsif ($insp->{state} ne 'clean') {
        _refuse(path => $T, detail => $insp->{state});
    }

    if (@kept) {
        Almanac::ClaudeMdBlock::apply_file(path => $T, notes => \@kept);
    } elsif ($insp->{present}) {
        Almanac::ClaudeMdBlock::remove_block_file(path => $T);
    }

    my ($bytes_after, undef) = _read_bytes($T);
    $bytes_after = '' unless defined $bytes_after;
    my $changed = (!$existed_before || $bytes_before ne $bytes_after) ? 'yes' : 'no';

    print "path: " . _decode_maybe($T) . "\n";
    print "notes: " . scalar(@kept) . "\n";
    print "excluded: " . (@excluded ? join(',', @excluded) : '-') . "\n";
    print "changed: $changed\n";
    return 0;
}

# ---------------------------------------------------------------------------
# CLI entry point.
# ---------------------------------------------------------------------------
unless (caller) {
    binmode(STDOUT, ':encoding(UTF-8)');
    binmode(STDERR, ':encoding(UTF-8)');
    $| = 1;
    my $rc = 0;
    my $ok = eval {
        my $args = _parse_args(@ARGV);
        if ($args->{verb} eq 'render-index') {
            $rc = _render_index($args);
        } else {
            $rc = _run_migration($args);
        }
        1;
    };
    unless ($ok) {
        Almanac::Record::fatal($@);
    }
    exit $rc;
}

1;
