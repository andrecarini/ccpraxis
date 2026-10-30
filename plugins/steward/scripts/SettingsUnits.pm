# SettingsUnits -- the one-level dotted unit model for settings.json.
#
# Every settings sync in ccpraxis decides, compares and remembers per UNIT, not
# per file: a top-level key is one unit, EXCEPT a key present on both sides
# whose values are both objects and differ, which expands one level into
# "parent.child" units. Expansion is skipped when an expanded name would
# collide with a real top-level key that already contains a dot. Units are
# named in that dotted form everywhere they are stored (.backup-preferences.json,
# --keep-key, decision records).
#
# THIS MODULE IS THE SHARED COPY. scripts/promote.pl carried it inline (its
# header logged the extraction as a follow-up); it now uses this module, and so
# do the two consumers added on 2026-10-30:
#   plugins/sandbox/scripts/SandboxSettings.pm  the per-key 3-way merge of a
#       sandbox's settings.json when its container is created (merge3 below)
#   scripts/backup/Export.pm                    the "sandbox preset vs each
#       sandbox's settings" pair of /steward:backup
# json-diff.pl and ccpraxis-helpers.pl's settings-export-merge still spell the
# same rules inline (both are dispatch scripts whose output formats other
# scripts parse); they agree with compute_units unit for unit, and moving them
# onto this module is a separate change.
#
# Vocabulary: compute_units($left, $right) names relations from the left side:
# only_left (the key is on the left only), only_right, identical, diverged.
#
# Core modules only; no state; never prints.
package SettingsUnits;
use strict;
use warnings;
use JSON::PP ();
use Exporter 'import';

our @EXPORT_OK = qw(
    canon_str same_value deep_clone dotted_collision compute_units
    value_at_path set_at_path delete_at_path take_at_path merge3
);

# Canonical JSON of any value (sorted keys), the comparison form for values.
sub canon_str {
    my ($data) = @_;
    return JSON::PP->new->canonical->allow_nonref->encode($data);
}

sub same_value { return canon_str($_[0]) eq canon_str($_[1]); }

sub deep_clone {
    my ($data) = @_;
    return JSON::PP->new->allow_nonref->decode(JSON::PP->new->allow_nonref->encode($data));
}

# True when expanding $key one level would produce a name that is already a
# real top-level key ("env.X" next to an expanded env.X).
sub dotted_collision {
    my ($key, $left_val, $right_val, $all_keys) = @_;
    for my $sk (keys %$left_val, keys %$right_val) {
        return 1 if exists $all_keys->{"$key.$sk"};
    }
    return 0;
}

# compute_units($left, $right) -> list of unit hashrefs, sorted by name:
#   { name, path => [k] | [k, sk], relation, live_val, payload_val }
# live_val / payload_val are the left / right values (the names promote.pl
# has always used: left = ~/.claude, right = the payload).
sub compute_units {
    my ($live, $payload) = @_;
    my %all_keys;
    $all_keys{$_} = 1 for (keys %$live, keys %$payload);

    my @units;
    for my $k (sort keys %all_keys) {
        my $in_l = exists $live->{$k};
        my $in_r = exists $payload->{$k};
        my $lv   = $live->{$k};
        my $rv   = $payload->{$k};

        my $rel = !$in_r ? 'only_left'
                : !$in_l ? 'only_right'
                : same_value($lv, $rv) ? 'identical'
                :                        'diverged';

        if ($rel eq 'diverged' && ref($lv) eq 'HASH' && ref($rv) eq 'HASH'
            && !dotted_collision($k, $lv, $rv, \%all_keys)) {
            my %sub_keys;
            $sub_keys{$_} = 1 for (keys %$lv, keys %$rv);
            for my $sk (sort keys %sub_keys) {
                my $sin_l = exists $lv->{$sk};
                my $sin_r = exists $rv->{$sk};
                my $slv   = $lv->{$sk};
                my $srv   = $rv->{$sk};
                my $srel = !$sin_r ? 'only_left'
                         : !$sin_l ? 'only_right'
                         : same_value($slv, $srv) ? 'identical'
                         :                          'diverged';
                push @units, {
                    name => "$k.$sk", path => [$k, $sk], relation => $srel,
                    live_val => $slv, payload_val => $srv,
                };
            }
            next;
        }

        push @units, {
            name => $k, path => [$k], relation => $rel,
            live_val => $lv, payload_val => $rv,
        };
    }
    return @units;
}

# value_at_path($data, $path) -> ($found, $value)
sub value_at_path {
    my ($data, $path) = @_;
    return (0, undef) unless ref($data) eq 'HASH';
    if (@$path == 1) {
        return exists $data->{$path->[0]} ? (1, $data->{$path->[0]}) : (0, undef);
    }
    my $top = $data->{$path->[0]};
    return (0, undef) unless ref($top) eq 'HASH' && exists $top->{$path->[1]};
    return (1, $top->{$path->[1]});
}

sub set_at_path {
    my ($data, $path, $val) = @_;
    if (@$path == 1) { $data->{$path->[0]} = $val; }
    else              { $data->{$path->[0]}{$path->[1]} = $val; }
    return;
}

sub delete_at_path {
    my ($data, $path) = @_;
    if (@$path == 1) { delete $data->{$path->[0]}; }
    elsif (ref($data->{$path->[0]}) eq 'HASH') { delete $data->{$path->[0]}{$path->[1]}; }
    return;
}

# take_at_path($target, $path, $from) -> void
# Makes $target hold at $path exactly what $from holds there: the value (a
# copy) when $from has it, nothing when it does not. A two-level path whose
# parent in $target is not an object cannot hold a sub-key, so the whole
# parent is taken instead.
sub take_at_path {
    my ($target, $path, $from) = @_;
    if (@$path == 2 && exists $target->{$path->[0]} && ref($target->{$path->[0]}) ne 'HASH') {
        $path = [ $path->[0] ];
    }
    my ($found, $val) = value_at_path($from, $path);
    if ($found) { set_at_path($target, $path, deep_clone($val)); }
    else         { delete_at_path($target, $path); }
    return;
}

sub _overlaps {
    my ($a, $b) = @_;
    return 0 unless $a->[0] eq $b->[0];
    return 1 if @$a == 1 || @$b == 1;
    return $a->[1] eq $b->[1] ? 1 : 0;
}

# merge3(base => H, local => H, remote => H, resolve => CODE) -> hashref
#
# A per-unit three-way merge. base is what both sides started from, local the
# side whose file is being updated, remote the side changes are taken from.
# A missing base (undef) is an empty object: then every unit present on either
# side counts as that side's own addition.
#
#   a unit only remote changed  -> taken (remote's value, or removed)
#   a unit only local changed   -> kept
#   a unit both changed to the same value (or both removed) -> agreed, kept
#   a unit both changed differently -> resolve->(\%conflict) decides:
#       'take' takes remote's value; anything else (the default) keeps local's
#
# Units come from compute_units against base on each side, so their
# granularity can differ: local may have changed env.A while remote replaced
# env wholesale. Overlapping units are settled together at the coarser path
# (env), as ONE conflict.
#
# The conflict record handed to resolve, and listed in the result:
#   { name, path, base_found, base_val, local_found, local_val,
#     remote_found, remote_val }        (+ choice => 'keep'|'take' in the result)
#
# Returns { result, taken => [names], kept => [names], agreed => [names],
#           conflicts => [records], changed => 0|1 }. changed is whether result
# differs from local at all. local is never modified.
sub merge3 {
    my (%o) = @_;
    my $base    = ref($o{base})   eq 'HASH' ? $o{base}   : {};
    my $local   = ref($o{local})  eq 'HASH' ? $o{local}  : {};
    my $remote  = ref($o{remote}) eq 'HASH' ? $o{remote} : {};
    my $resolve = ref($o{resolve}) eq 'CODE' ? $o{resolve} : sub { 'keep' };

    my @lc = grep { $_->{relation} ne 'identical' } compute_units($local,  $base);
    my @rc = grep { $_->{relation} ne 'identical' } compute_units($remote, $base);
    my %l_by_top;
    push @{ $l_by_top{ $_->{path}[0] } }, $_ for @lc;

    my $result = deep_clone($local);
    my (@taken, @agreed, @conflicts, %settled, %local_involved);

    for my $r (@rc) {
        my $top = $r->{path}[0];
        my @overlap = grep { _overlaps($_->{path}, $r->{path}) } @{ $l_by_top{$top} || [] };
        unless (@overlap) {
            take_at_path($result, $r->{path}, $remote);
            push @taken, $r->{name};
            next;
        }
        $local_involved{ $_->{name} } = 1 for @overlap;
        my $coarse = (grep { @{ $_->{path} } == 1 } ($r, @overlap)) ? [ $top ] : $r->{path};
        my $name   = join('.', @$coarse);
        next if $settled{$name}++;

        my ($lf, $lv) = value_at_path($local,  $coarse);
        my ($rf, $rv) = value_at_path($remote, $coarse);
        if ($lf == $rf && (!$lf || same_value($lv, $rv))) {
            push @agreed, $name;
            next;
        }
        my ($bf, $bv) = value_at_path($base, $coarse);
        my %conflict = (
            name => $name, path => [ @$coarse ],
            base_found => $bf ? 1 : 0,   base_val => $bv,
            local_found => $lf ? 1 : 0,  local_val => $lv,
            remote_found => $rf ? 1 : 0, remote_val => $rv,
        );
        my $choice = $resolve->({ %conflict });
        $choice = (defined $choice && $choice eq 'take') ? 'take' : 'keep';
        take_at_path($result, $coarse, $remote) if $choice eq 'take';
        push @conflicts, { %conflict, choice => $choice };
    }

    my @kept = map { $_->{name} } grep { !$local_involved{ $_->{name} } } @lc;
    return {
        result    => $result,
        taken     => \@taken,
        kept      => \@kept,
        agreed    => \@agreed,
        conflicts => \@conflicts,
        changed   => same_value($result, $local) ? 0 : 1,
    };
}

1;
