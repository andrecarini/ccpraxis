#!/usr/bin/env perl
# bp-turn-caps.pl -- the canonical turn-cap source, and the drift guard over it.
#
# WHY THIS EXISTS
#
# A turn cap lives in twelve places under three field names (`max_turns`,
# `maxTurns`, `steps`). The copies drifted three separate times, silently:
# b23 raised the authoring prose and missed both bp-scout.md AND the ledger
# template; b49 raised the agent caps and missed the OpenCode `steps:` twins.
#
# Frontmatter cannot reference a variable, so a literal must physically exist in
# each agent file -- true single-sourcing is impossible. What IS achievable is a
# canonical source plus a guard that turns drift into a red suite instead of a
# two-month divergence nobody notices. That is this file's whole job.
#
# DUAL SHAPE (repo convention): a requireable module with no top-level side
# effects, plus a CLI behind `unless (caller)`.
#
#   BpTurnCaps::load($config_path)        -> $cfg hashref (dies with a reason)
#   BpTurnCaps::cap_for_role($cfg,$role)  -> int or undef
#   BpTurnCaps::drift($cfg, $root)        -> arrayref of drift records
#   BpTurnCaps::sync($cfg, $root)         -> arrayref of the writes it performed
#
# CLI:
#   bp-turn-caps.pl check [--root R] [--config C]   exit 0 clean, 1 drift, 2 usage
#   bp-turn-caps.pl sync  [--root R] [--config C]   rewrites derived surfaces
#   bp-turn-caps.pl show  [--config C]
#
# SCOPE OF `sync`. It rewrites only DATA surfaces whose whole content is a
# frontmatter/JSON field: agent `maxTurns:`, OpenCode `steps:`, and the two
# templates' `max_turns:`. It deliberately does NOT rewrite executable source
# (bp-launch.sh, bp-orchestrator.pl, bp-judge.sh) -- a script that edits shell
# and Perl by regex is a worse hazard than the drift it prevents. Those are
# CHECKED and reported, and a human edits them. Reporting without fixing is the
# honest split; silently rewriting code is not.

use strict;
use warnings;

package BpTurnCaps;

use JSON::PP ();
use File::Spec ();
use File::Basename ();
use Cwd ();

# script_dir_for($path) -> the directory holding $path, absolute, separators
# normalised. Pure string/filesystem logic so it is TESTABLE ON LINUX with a
# synthetic Windows path -- which matters, because this exact resolution has now
# failed three times in this repo and every failure needed a Windows host to
# observe:
#
#   1. bp-baseline.pl  — a relative dirname made `require` search @INC.
#   2. install-skills.pl — FindBin fell back to the CWD on a backslash $0, and
#      `apply` DELETED the user's installed skills.
#   3. bp-turn-caps.pl — abs_path was handed a raw `C:\...` path, did not
#      recognise it as absolute, and pasted the CWD in front of it.
#
# The two rules that make all three go away:
#   - normalise separators BEFORE anything tries to split or absolutise;
#   - treat a drive-letter prefix as absolute, because File::Spec's Unix flavour
#     (which msys/Git-Bash perl uses) does not.
sub script_dir_for {
    my ($path) = @_;
    return undef unless defined $path && length $path;
    (my $p = $path) =~ s{\\}{/}g;
    my $dir = File::Basename::dirname($p);
    return $dir if $dir =~ m{^[A-Za-z]:/};
    return $dir if File::Spec->file_name_is_absolute($dir);
    return Cwd::abs_path($dir) // File::Spec->rel2abs($dir);
}

# ---------------------------------------------------------------- load ---

sub load {
    my ($path) = @_;
    die "bp-turn-caps: config path required\n" unless defined $path && length $path;
    open my $fh, '<', $path or die "bp-turn-caps: cannot read $path: $!\n";
    my $raw = do { local $/; <$fh> };
    close $fh;

    my $cfg = eval { JSON::PP->new->relaxed->decode($raw) };
    die "bp-turn-caps: $path is not valid JSON: $@\n" if $@;
    die "bp-turn-caps: $path must decode to an object\n" unless ref $cfg eq 'HASH';

    for my $k (qw(ceiling coordinator_default roles)) {
        die "bp-turn-caps: $path is missing required key '$k'\n" unless defined $cfg->{$k};
    }
    die "bp-turn-caps: 'roles' must be an object\n" unless ref $cfg->{roles} eq 'HASH';

    for my $r (sort keys %{ $cfg->{roles} }) {
        my $v = $cfg->{roles}{$r};
        die "bp-turn-caps: role '$r' cap must be a positive integer\n"
            unless defined $v && $v =~ /\A[1-9][0-9]*\z/;
        die "bp-turn-caps: role '$r' cap ($v) exceeds the ceiling ($cfg->{ceiling})\n"
            if $v > $cfg->{ceiling};
    }
    return $cfg;
}

sub cap_for_role {
    my ($cfg, $role) = @_;
    return undef unless ref $cfg eq 'HASH' && ref $cfg->{roles} eq 'HASH';
    return $cfg->{roles}{$role};
}

# --------------------------------------------------------------- helpers ---

sub _slurp {
    my ($p) = @_;
    open my $fh, '<', $p or return undef;
    my $t = do { local $/; <$fh> };
    close $fh;
    return $t;
}

sub _spew {
    my ($p, $t) = @_;
    open my $fh, '>', $p or die "bp-turn-caps: cannot write $p: $!\n";
    print $fh $t;
    close $fh or die "bp-turn-caps: cannot close $p: $!\n";
    return 1;
}

# Each derived surface: where it lives, which field carries the number, and how
# the wanted value is derived from the config. Keeping this as DATA is the point
# -- a new surface is one entry, not a new branch in three functions.
sub _surfaces {
    my ($cfg, $root) = @_;
    my @s;

    for my $p (sort glob("$root/plugins/*/agents/*.md")) {
        my ($role) = $p =~ m{([^/]+)\.md$};
        push @s, {
            surface => 'agent', file => $p, field => 'maxTurns',
            re => qr/^maxTurns:[ \t]*(\d+)[ \t]*$/m,
            want => cap_for_role($cfg, $role), role => $role, writable => 1,
        };
    }

    for my $p (sort glob("$root/plugins/butler/opencode/*.md")) {
        my ($role) = $p =~ m{([^/]+)\.md$};
        push @s, {
            surface => 'opencode', file => $p, field => 'steps',
            re => qr/^steps:[ \t]*(\d+)[ \t]*$/m,
            want => cap_for_role($cfg, $role), role => $role, writable => 1,
        };
    }

    push @s, {
        surface => 'template', file => "$root/plugins/blueprint/templates/package-ledger.md",
        field => 'max_turns', re => qr/^max_turns:[ \t]*(\d+)[ \t]*$/m,
        want => $cfg->{coordinator_default}, writable => 1,
    };
    push @s, {
        surface => 'template', file => "$root/plugins/blueprint/templates/blueprint.md",
        field => 'max_turns', re => qr/^- \*\*max_turns:\*\*[ \t]*(\d+)[ \t]*$/m,
        want => $cfg->{coordinator_default}, writable => 1,
    };

    # Executable source: CHECKED, never rewritten. See the header note.
    push @s, {
        surface => 'script', file => "$root/plugins/butler/scripts/bp-launch.sh",
        field => 'BP_DEFAULT_MAX_TURNS', re => qr/BP_DEFAULT_MAX_TURNS:-(\d+)/,
        want => $cfg->{coordinator_default}, writable => 0,
    };
    push @s, {
        surface => 'script', file => "$root/plugins/butler/scripts/bp-orchestrator.pl",
        field => 'default fallback', re => qr/\$ENV\{BP_DEFAULT_MAX_TURNS\}\s*\/\/\s*(\d+)/,
        want => $cfg->{coordinator_default}, writable => 0,
    };
    push @s, {
        surface => 'script', file => "$root/plugins/butler/scripts/bp-orchestrator.pl",
        field => 'MAX_TURNS_CEILING', re => qr/\$MAX_TURNS_CEILING\s*=\s*(\d+)/,
        want => $cfg->{ceiling}, writable => 0,
    };
    push @s, {
        surface => 'script', file => "$root/plugins/butler/scripts/bp-judge.sh",
        field => 'BP_CONFORMANCE_MAX_TURNS', re => qr/BP_CONFORMANCE_MAX_TURNS:-(\d+)/,
        want => cap_for_role($cfg, 'bp-conformance-judge'), writable => 0,
    };
    push @s, {
        surface => 'script', file => "$root/plugins/butler/scripts/bp-judge.sh",
        field => 'BP_RESOLVE_MAX_TURNS', re => qr/BP_RESOLVE_MAX_TURNS:-(\d+)/,
        want => cap_for_role($cfg, 'bp-resolve-judge'), writable => 0,
    };
    push @s, {
        surface => 'script', file => "$root/plugins/butler/scripts/bp-judge.sh",
        field => 'BP_ESCALATION_MAX_TURNS', re => qr/BP_ESCALATION_MAX_TURNS:-(\d+)/,
        want => cap_for_role($cfg, 'bp-escalation-resolver'), writable => 0,
    };

    return @s;
}

# ---------------------------------------------------------------- drift ---
#
# A surface drifts when the file exists and its value differs from `want`, or the
# field is absent entirely. A file that does not exist is NOT drift -- a partial
# checkout is not a cap defect. An unknown role IS drift: a new agent with no
# canonical entry must fail loudly rather than default silently.

sub drift {
    my ($cfg, $root) = @_;
    my @out;
    for my $s (_surfaces($cfg, $root)) {
        my $text = _slurp($s->{file});
        next unless defined $text;

        if (!defined $s->{want}) {
            push @out, { %$s, have => undef, reason => 'no canonical cap for this role' };
            next;
        }
        my ($have) = $text =~ $s->{re};
        if (!defined $have) {
            push @out, { %$s, have => undef, reason => 'field absent' };
            next;
        }
        push @out, { %$s, have => $have, reason => 'value differs' }
            if $have != $s->{want};
    }
    return \@out;
}

# ----------------------------------------------------------------- sync ---

sub sync {
    my ($cfg, $root) = @_;
    my @wrote;
    for my $s (_surfaces($cfg, $root)) {
        next unless $s->{writable};
        next unless defined $s->{want};
        my $text = _slurp($s->{file});
        next unless defined $text;

        my ($have) = $text =~ $s->{re};
        next if defined $have && $have == $s->{want};

        my $re = $s->{re};
        my $n  = ($text =~ s/$re/_replace_number($&, $s->{want})/e);
        next unless $n;

        _spew($s->{file}, $text);
        push @wrote, { %$s, have => $have, wrote => $s->{want} };
    }
    return \@wrote;
}

# Swap the digits inside whatever matched, preserving the surrounding syntax --
# so a template's `- **max_turns:** 80` keeps its markdown.
sub _replace_number {
    my ($matched, $want) = @_;
    $matched =~ s/\d+/$want/;
    return $matched;
}

package main;

unless (caller) {
    my $verb = shift(@ARGV) // '';
    my %opt;
    while (@ARGV) {
        my $a = shift @ARGV;
        if    ($a =~ /^--root=(.*)$/)   { $opt{root}   = $1 }
        elsif ($a =~ /^--config=(.*)$/) { $opt{config} = $1 }
        elsif ($a eq '--root')          { $opt{root}   = shift @ARGV }
        elsif ($a eq '--config')        { $opt{config} = shift @ARGV }
        else { print STDERR "bp-turn-caps: unrecognised argument '$a'\n"; exit 2 }
    }

    # See script_dir_for's header for why this is not inline dirname/abs_path.
    my $self_dir = BpTurnCaps::script_dir_for(__FILE__);

    # rel2abs would paste the CWD in front of a drive-letter path here too, for
    # exactly the reason script_dir_for documents -- so only absolutise when the
    # path is not already absolute in either flavour.
    my $root = $opt{root};
    unless (defined $root) {
        $root = "$self_dir/../../..";
        $root = File::Spec->rel2abs($root)
            unless $root =~ m{^[A-Za-z]:/} || File::Spec->file_name_is_absolute($root);
    }
    my $config = $opt{config} // "$self_dir/../turn-caps.json";

    if ($verb eq '' || $verb =~ /^(-h|--help|help)$/) {
        print "usage: bp-turn-caps.pl <check|sync|show> [--root R] [--config C]\n";
        exit 2;
    }

    my $cfg = eval { BpTurnCaps::load($config) };
    if ($@) { print STDERR $@; exit 2 }

    if ($verb eq 'show') {
        printf "ceiling             %d\n", $cfg->{ceiling};
        printf "coordinator_default %d\n", $cfg->{coordinator_default};
        printf "%-24s %s\n", $_, $cfg->{roles}{$_} for sort keys %{ $cfg->{roles} };
        exit 0;
    }
    elsif ($verb eq 'check') {
        my $d = BpTurnCaps::drift($cfg, $root);
        if (!@$d) { print "turn caps: no drift\n"; exit 0 }
        printf STDERR "turn caps: %d surface(s) drifted from %s\n", scalar(@$d), $config;
        for my $r (@$d) {
            printf STDERR "  %-9s %-56s %-24s want=%s have=%s (%s)\n",
                $r->{surface}, $r->{file}, $r->{field},
                $r->{want} // '?', defined $r->{have} ? $r->{have} : '(absent)', $r->{reason};
        }
        print STDERR "\nData surfaces: run `bp-turn-caps.pl sync`. Script surfaces: edit by hand (sync never rewrites code).\n";
        exit 1;
    }
    elsif ($verb eq 'sync') {
        my $w = BpTurnCaps::sync($cfg, $root);
        printf "turn caps: %d surface(s) rewritten\n", scalar(@$w);
        printf "  %-9s %-56s %s -> %s\n", $_->{surface}, $_->{file},
               defined $_->{have} ? $_->{have} : '(absent)', $_->{wrote} for @$w;
        my $left = BpTurnCaps::drift($cfg, $root);
        if (@$left) {
            printf STDERR "\n%d surface(s) still drifted (script surfaces are not rewritten):\n", scalar(@$left);
            printf STDERR "  %-9s %-56s %-24s want=%s have=%s\n",
                $_->{surface}, $_->{file}, $_->{field}, $_->{want} // '?',
                defined $_->{have} ? $_->{have} : '(absent)' for @$left;
            exit 1;
        }
        exit 0;
    }

    print STDERR "bp-turn-caps: unknown verb '$verb'\n";
    exit 2;
}

1;
