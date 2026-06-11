#!/usr/bin/env perl
# onboard.pl — deterministically prepare a project to use the ccpraxis blueprint
# system. Manual (run via /steward:setup-project); never auto-triggered.
#
# Usage: onboard.pl <project-root>
#
# Does, idempotently and locally (no vault network writes):
#   1. Create <root>/.ccpraxis-local-data/blueprints/ + self-gitignore (*).
#   2. Migrate any legacy .claude-plans/*.md into blueprints (delegates to the
#      blueprint plugin's bp-migrate-plans.pl --apply --delete).
#   3. If the project is already registered for vault backup, ensure
#      .ccpraxis-local-data/blueprints is in its tracked_paths (ensure-tracked).
#
# Emits a JSON summary. Vault REGISTRATION of a not-yet-registered project is
# intentionally NOT done here (it pushes to your private vault) — the summary
# reports registered:false so /steward:setup-project runs the registration
# flow with you present.
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use JSON::PP;
binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

my $root = shift @ARGV or die "usage: onboard.pl <project-root>\n";
$root =~ s{[/\\]+$}{};
die "onboard: not a directory: $root\n" unless -d $root;

my $script_dir = dirname(abs_path(__FILE__));        # plugins/steward/scripts
my $plugins    = abs_path("$script_dir/../..");        # plugins/
my $ccpraxis   = abs_path("$plugins/..");              # repo root
my $bp_migrate = "$plugins/blueprint/scripts/bp-migrate-plans.pl";
my $vault_sync = "$script_dir/vault-sync.pl";

my %summary = (root => $root);

# ---- 1. data dir + self-gitignore (inline; deterministic for THIS root) -----
my $data = "$root/.ccpraxis-local-data";
my $created_dir = !-d "$data/blueprints";
make_path("$data/blueprints");
my $gi = "$data/.gitignore";
unless (-f $gi) { if (open(my $g, '>', $gi)) { print $g "*\n"; close $g } }
$summary{data_dir} = $created_dir ? 'created' : 'exists';

# ---- 2. migrate legacy plans (delegate; list-form = space/unicode safe) ------
$summary{migration} = { ran => JSON::PP::false };
if (-d "$root/.claude-plans" && -f $bp_migrate) {
    my @cmd = ('perl', $bp_migrate, $root, '--apply', '--delete');
    my $out = run_capture(@cmd);
    my ($wrote) = ($out =~ /wrote (\d+) blueprint/);
    my ($del)   = ($out =~ /deleted (\d+) original/);
    $summary{migration} = {
        ran     => JSON::PP::true,
        wrote   => defined $wrote ? $wrote + 0 : 0,
        deleted => defined $del   ? $del + 0   : 0,
    };
}

# ---- 3. vault tracking ------------------------------------------------------
$summary{registered} = JSON::PP::false;
if (-f $vault_sync) {
    my $isreg = eval { decode_json(run_capture('perl', $vault_sync, 'is-registered', '--cwd', $root)) };
    if ($isreg && $isreg->{registered}) {
        $summary{registered} = JSON::PP::true;
        my $slug = $isreg->{slug};
        $summary{slug} = $slug;
        my $et = eval { decode_json(run_capture('perl', $vault_sync, 'ensure-tracked', '--slug', $slug, '--path', '.ccpraxis-local-data/blueprints')) };
        $summary{ensure_tracked} = $et ? $et->{status} : 'error';
    }
}

print JSON::PP->new->canonical(1)->pretty->encode(\%summary);

# Run a command (list form, no shell) and return combined-ish stdout.
sub run_capture {
    my @cmd = @_;
    my $pid = open(my $fh, '-|');
    die "fork failed: $!\n" unless defined $pid;
    if ($pid == 0) { open(STDERR, '>&', \*STDOUT); exec { $cmd[0] } @cmd or exit 127; }
    local $/; my $out = <$fh> // ''; close $fh;
    return $out;
}
