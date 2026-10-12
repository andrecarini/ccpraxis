#!/usr/bin/env perl
# promote.pl -- the one promotion command: merge this clone's main into the
# live install, then sync the global-config/ payload into <home>/.claude.
#
# Spec: .ccpraxis-local-data/blueprints/hook-continuity-remake/specs/
# 33-promote-syncs-global-config-spec.md, Decision 109.
#
# Two syncs re-implement rules that live in
# plugins/steward/scripts/ccpraxis-helpers.pl (settings-export-merge,
# marketplace-diff). That script's subs are not importable (it is a
# dispatch-table script, not a module), so the unit model and preference
# table are re-implemented here, citing the source lines at each mirror
# point. Extracting a shared module is a logged follow-up, not this package.
use strict;
use warnings;
use FindBin qw($Bin);
use Cwd qw(abs_path);
use File::Basename qw(dirname basename);
use File::Path qw(make_path);
use File::Temp qw(tempfile);
use JSON::PP qw(decode_json);
use B ();

# ---------------------------------------------------------------------------
# Usage / argument parsing
# ---------------------------------------------------------------------------

sub usage_text {
    return <<'EOF';
promote.pl -- merge this clone's main into the live install, then sync the global-config/ payload into <home>/.claude.

Usage:
  perl scripts/promote.pl [--dry-run] [--clone DIR] [--live DIR] [--home DIR] [--help]

Options:
  --clone DIR   source repo whose main branch gets merged (default: this script's repo)
  --home DIR    user home; <home>/.claude is the target (default: $HOME or $USERPROFILE)
  --live DIR    the live install repo (default: <home>/.claude/ccpraxis)
  --dry-run     compute and print everything; write nothing anywhere
  --help        this text

Exit codes: 0 ok, 1 a payload file was refused, 2 precondition/hard failure, 3 usage error.
EOF
}

sub die_usage {
    my ($msg) = @_;
    print STDERR "promote: $msg\n" if defined $msg && length $msg;
    print STDERR usage_text();
    exit 3;
}

sub parse_args {
    my (@argv) = @_;
    my %opt = (dry_run => 0, help => 0, clone => undef, live => undef, home => undef);
    while (@argv) {
        my $a = shift @argv;
        if ($a eq '--help') {
            $opt{help} = 1;
        } elsif ($a eq '--dry-run') {
            $opt{dry_run} = 1;
        } elsif ($a eq '--clone' || $a eq '--live' || $a eq '--home') {
            my $key = substr($a, 2);
            die_usage("$a requires a value") unless @argv;
            $opt{$key} = shift @argv;
        } else {
            die_usage("unknown option: $a");
        }
    }
    return \%opt;
}

# ---------------------------------------------------------------------------
# path helpers
# ---------------------------------------------------------------------------

sub pjoin {
    my (@parts) = @_;
    my $out = shift @parts;
    $out =~ s{[\\/]+\z}{};
    for my $p (@parts) {
        (my $q = $p) =~ s{^[\\/]+}{};
        $q =~ s{[\\/]+\z}{};
        $out .= "/$q";
    }
    return $out;
}

# The house translation (project CLAUDE.md; mirrors vault-sync.pl:1481 and
# HostCaps::git_path): rewrite a POSIX-style /c/... path into the
# forward-slash Windows form C:/... that git.exe accepts whether or not
# MSYS later rewrites it. A no-op on Linux/macOS and on already-C:/ paths.
# MSYS2_ARG_CONV_EXCL is never set here -- this hand translation is used
# instead, per spec 2.5.
sub git_path {
    my $p = shift;
    return $p unless defined $p;
    (my $q = $p) =~ s{\\}{/}g;
    $q =~ s{^/([a-zA-Z])/}{uc($1) . ":/"}e;
    return $q;
}

sub norm_for_cmp {
    my $p = shift;
    return undef unless defined $p;
    my $a = -e $p ? (abs_path($p) // $p) : $p;
    $a =~ s{\\}{/}g;
    $a =~ s{/+\z}{};
    return ($^O =~ /^(MSWin32|cygwin|msys)$/) ? lc($a) : $a;
}

sub read_bytes {
    my ($path) = @_;
    return undef unless defined $path && -f $path;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

sub write_bytes_atomic {
    my ($path, $content) = @_;
    my $dir = dirname($path);
    make_path($dir) unless -d $dir;
    my $tmp = "$path.tmp.$$." . time();
    open my $fh, '>:raw', $tmp or return "cannot open $tmp for write: $!";
    unless (print {$fh} $content) {
        my $e = $!;
        close $fh;
        unlink $tmp;
        return "write $tmp failed: $e";
    }
    unless (close $fh) {
        my $e = $!;
        unlink $tmp;
        return "close $tmp failed: $e";
    }
    unless (rename($tmp, $path)) {
        my $e = $!;
        unlink $tmp;
        return "rename $tmp -> $path failed: $e";
    }
    return undef;
}

# ---------------------------------------------------------------------------
# git invocation. List-form only, never a shell string. Both stdout and
# stderr of the CHILD are captured via real File::Temp files (never an
# in-memory scalar reopen -- project CLAUDE.md's "Bad file descriptor" trap).
# Every path handed to git goes through git_path().
# ---------------------------------------------------------------------------

sub git_capture {
    my ($dir, @args) = @_;
    my @cmd = ('git', '-C', git_path($dir), @args);
    my ($ofh, $oname) = tempfile(UNLINK => 1);
    close $ofh;
    my ($efh, $ename) = tempfile(UNLINK => 1);
    close $efh;
    open(my $saved_out, '>&', \*STDOUT) or die "cannot dup STDOUT: $!";
    open(my $saved_err, '>&', \*STDERR) or die "cannot dup STDERR: $!";
    open(STDOUT, '>', $oname) or die "cannot redirect STDOUT: $!";
    open(STDERR, '>', $ename) or die "cannot redirect STDERR: $!";
    my $rc = system(@cmd);
    open(STDOUT, '>&', $saved_out) or warn "cannot restore STDOUT: $!";
    open(STDERR, '>&', $saved_err) or warn "cannot restore STDERR: $!";
    close $saved_out;
    close $saved_err;
    $rc = ($rc == -1) ? -1 : ($rc >> 8);
    my $out = read_bytes($oname) // '';
    my $err = read_bytes($ename) // '';
    unlink $oname;
    unlink $ename;
    return ($rc, $out, $err);
}

sub git_line {
    my ($dir, @args) = @_;
    my ($rc, $out) = git_capture($dir, @args);
    $out =~ s/\s+\z//;
    return ($rc, $out);
}

sub is_git_worktree {
    my ($dir) = @_;
    return 0 unless defined $dir && -d $dir;
    my ($rc, $out) = git_line($dir, 'rev-parse', '--is-inside-work-tree');
    return $rc == 0 && $out eq 'true';
}

sub head_sha {
    my ($dir) = @_;
    my ($rc, $out) = git_line($dir, 'rev-parse', 'HEAD');
    return $rc == 0 ? $out : undef;
}

sub is_ancestor {
    my ($dir, $anc, $desc) = @_;
    my ($rc) = git_capture($dir, 'merge-base', '--is-ancestor', $anc, $desc);
    return $rc == 0;
}

sub short_sha { my $s = shift; return defined $s ? substr($s, 0, 7) : '???????'; }

sub blob_exists {
    my ($dir, $ref, $relpath) = @_;
    my ($rc) = git_capture($dir, 'cat-file', '-e', "$ref:$relpath");
    return $rc == 0;
}

sub show_blob {
    my ($dir, $ref, $relpath) = @_;
    my ($rc, $out) = git_capture($dir, 'show', "$ref:$relpath");
    return $rc == 0 ? $out : undef;
}

# Every version of a path in <ref>'s history, oldest-doesn't-matter order.
sub payload_versions_bytes {
    my ($dir, $ref, $relpath) = @_;
    my ($rc, $out) = git_capture($dir, 'log', $ref, '--format=%H', '--', $relpath);
    return () if $rc != 0;
    my @shas = grep { length $_ } split /\n/, $out;
    my @blobs;
    for my $sha (@shas) {
        my $b = show_blob($dir, $sha, $relpath);
        push @blobs, $b if defined $b;
    }
    return @blobs;
}

# ---------------------------------------------------------------------------
# JSON helpers. Bytes in, bytes out -- no double encode/decode (spec 2.6).
# ---------------------------------------------------------------------------

sub decode_json_bytes {
    my ($bytes) = @_;
    my $obj = eval { decode_json($bytes) };
    return $@ ? (undef, "$@") : ($obj, undef);
}

sub encode_json_bytes {
    my ($data) = @_;
    return JSON::PP->new->utf8->canonical->pretty->encode($data);
}

sub canon_str {
    my ($data) = @_;
    return JSON::PP->new->canonical->allow_nonref->encode($data);
}

sub same_value { return canon_str($_[0]) eq canon_str($_[1]); }

sub deep_clone {
    my ($data) = @_;
    return JSON::PP->new->allow_nonref->decode(JSON::PP->new->allow_nonref->encode($data));
}

# ---------------------------------------------------------------------------
# Unit model, shared by settings.json (spec S3.4/S3.5). Mirrors
# plugins/steward/scripts/ccpraxis-helpers.pl's settings-export-merge:
#   VALID_ACTION table:      ccpraxis-helpers.pl:506-510
#   same_value / VALUE_CMP:  ccpraxis-helpers.pl:515-516
#   dotted_collision:        ccpraxis-helpers.pl:535-541
#   one-level dotted expand: ccpraxis-helpers.pl:562-589 (merge_export_level)
# left = live, right = payload (current repo config), matching that script's
# live-vs-repo vocabulary.
# ---------------------------------------------------------------------------

our %VALID_ACTION = (
    only_left  => 'left-only',
    only_right => 'right-only',
    diverged   => 'skip-always',
);

sub dotted_collision {
    my ($key, $left_val, $right_val, $all_keys) = @_;
    for my $sk (keys %$left_val, keys %$right_val) {
        return 1 if exists $all_keys->{"$key.$sk"};
    }
    return 0;
}

# Returns a list of unit hashrefs:
#   { name, path => [k] | [k, sk], relation, live_val, payload_val }
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

sub value_at_path {
    my ($data, $path) = @_;
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
    else              { delete $data->{$path->[0]}{$path->[1]}; }
    return;
}

# Historical values for a unit: canonical JSON of the value at that unit's
# path, across every payload-history version that parses as JSON and
# contains the path (spec S3.4 item 14).
sub historical_canon_set {
    my ($versions, $path) = @_;
    my %set;
    for my $ver (@$versions) {
        next unless ref($ver) eq 'HASH';
        my ($found, $val) = value_at_path($ver, $path);
        $set{ canon_str($val) } = 1 if $found;
    }
    return \%set;
}

# ---------------------------------------------------------------------------
# Array-unit merge (Decision 26 / spec 09-promote-array-merge). Only the
# three permission-rule arrays get element-wise treatment; everything else
# (including permissions.additionalDirectories) stays on the whole-value
# path above unchanged. See spec S2.1-2.3 for the exact rules mirrored here.
# ---------------------------------------------------------------------------

# True iff $e is a genuine JSON string -- NOT a JSON number. JSON::PP
# decodes both a string and a number into a bare, non-ref scalar, so a
# ref/defined check alone cannot tell them apart (review S1 / red-team S3).
# This mirrors JSON::PP's own string-vs-number test: a number carries the
# IOK/NOK flag without POK; a string carries POK.
sub is_json_string {
    my ($e) = @_;
    return 0 if ref($e);
    return 0 unless defined $e;
    my $flags = B::svref_2object(\$e)->FLAGS;
    return 0 if ($flags & (B::SVp_IOK() | B::SVp_NOK())) && !($flags & B::SVp_POK());
    return 1;
}

# True iff every element of $v is a genuine JSON string (not a number, not a
# ref). An empty array qualifies (spec S2.1 item 3).
sub is_string_array {
    my ($v) = @_;
    return 0 unless ref($v) eq 'ARRAY';
    for my $e (@$v) {
        return 0 unless is_json_string($e);
    }
    return 1;
}

# Returns the array-unit key ('allow' | 'deny' | 'ask') iff $u qualifies as
# an array unit under spec S2.1, else undef -- in which case the caller
# falls through to the pre-existing whole-value handling untouched.
sub array_unit_key {
    my ($u) = @_;
    return undef unless @{ $u->{path} } == 2 && $u->{path}[0] eq 'permissions';
    my $k = $u->{path}[1];
    return undef unless $k =~ /^(?:allow|deny|ask)\z/;
    return undef unless $u->{relation} =~ /^(?:diverged|only_left|only_right)\z/;

    # Only check the side(s) actually present for this relation -- an
    # only_left unit has no payload_val, an only_right unit has no live_val.
    my $live_present    = $u->{relation} ne 'only_right';
    my $payload_present = $u->{relation} ne 'only_left';
    return undef if $live_present    && !is_string_array($u->{live_val});
    return undef if $payload_present && !is_string_array($u->{payload_val});
    return $k;
}

# The union, across every payload-history version, of the string elements
# found in the array at $path (spec S2.2's H). A version where the path is
# missing or not an array contributes nothing; non-string elements in
# history are ignored (they can never appear in a qualifying L/P anyway).
sub historical_string_set {
    my ($versions, $path) = @_;
    my %set;
    for my $ver (@$versions) {
        next unless ref($ver) eq 'HASH';
        my ($found, $val) = value_at_path($ver, $path);
        next unless $found && ref($val) eq 'ARRAY';
        for my $e (@$val) {
            next unless is_json_string($e);
            $set{$e} = 1;
        }
    }
    return \%set;
}

# The string set at $path within a single object (or {} when $obj is
# missing/not a hash) -- used for the baseline (Decision 27's three-way
# widening merge), which is one payload version, not a history list.
sub string_set_at {
    my ($obj, $path) = @_;
    return {} unless ref($obj) eq 'HASH';
    return historical_string_set([$obj], $path);
}

# The element-wise merge itself (spec S2.3), amended by Decision 27: a
# change that NARROWS permissions is judged against the payload's whole
# history ($hist_versions, spec S2.2's H, unchanged); a change that WIDENS
# them is judged only against the payload at the live install's pre-merge
# HEAD ($baseline_obj, undef when there is none -- fresh install or no
# settings.json at that commit). Which action narrows/widens depends on the
# array: removing an allow entry or adding a deny/ask entry narrows;
# adding an allow entry or removing a deny/ask entry widens. Returns
# (\@result, \@removed, \@added, $changes).
sub merge_array_unit {
    my ($u, $key, $hist_versions, $baseline_obj) = @_;
    my $L = ($u->{relation} eq 'only_right') ? [] : $u->{live_val};
    my $P = ($u->{relation} eq 'only_left')  ? [] : $u->{payload_val};
    my %in_P = map { $_ => 1 } @$P;
    my %in_L = map { $_ => 1 } @$L;

    my $hist_set     = historical_string_set($hist_versions, $u->{path});
    my $baseline_set = string_set_at($baseline_obj, $u->{path});
    my $is_allow      = ($key eq 'allow');

    my (@removed, %removed_seen);
    # allow removal narrows -> whole history H. deny/ask removal widens ->
    # the baseline only; with no baseline payload, nothing is removed
    # (Decision 27's "deny/ask removals remove nothing").
    my $removal_set = $is_allow ? $hist_set : $baseline_set;
    for my $e (@$L) {
        next if $removed_seen{$e};
        next unless $removal_set->{$e};
        next if $in_P{$e};
        push @removed, $e;
        $removed_seen{$e} = 1;
    }

    my (@added, %added_seen);
    # allow addition widens -> added only if new since the baseline; with no
    # baseline payload the baseline is empty, so every payload entry not
    # already live counts as new (Decision 27's "allow additions treat the
    # baseline as empty"). deny/ask addition narrows -> unrestricted, as
    # spec S2.3 always was.
    for my $p (@$P) {
        next if $added_seen{$p} || $in_L{$p};
        next if $is_allow && $baseline_set->{$p};
        push @added, $p;
        $added_seen{$p} = 1;
    }

    my %remove_set = map { $_ => 1 } @removed;
    my @result = ((grep { !$remove_set{$_} } @$L), @added);
    return (\@result, \@removed, \@added, scalar(@removed) + scalar(@added));
}

# spec S2.6: JSON-string encoding of a report-line entry.
sub encode_entry_json {
    my ($e) = @_;
    return JSON::PP->new->utf8->allow_nonref->encode($e);
}

sub pref_honoured {
    my ($scope, $name, $category) = @_;
    my $p = $scope->{$name};
    return 0 unless ref($p) eq 'HASH';
    my $cat = $p->{category} // '';
    my $act = $p->{action}   // '';
    return ($cat eq $category && defined $VALID_ACTION{$category} && $act eq $VALID_ACTION{$category}) ? 1 : 0;
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

sub main {
    my $opt = parse_args(@ARGV);

    if ($opt->{help}) {
        print usage_text();
        exit 0;
    }

    $opt->{home}  //= $ENV{HOME} // $ENV{USERPROFILE};
    die_usage("cannot determine home directory (set --home, HOME or USERPROFILE)")
        unless defined $opt->{home} && length $opt->{home};

    $opt->{clone} //= abs_path("$Bin/..") // "$Bin/..";
    $opt->{live}  //= pjoin($opt->{home}, '.claude', 'ccpraxis');

    my $nc = norm_for_cmp($opt->{clone});
    my $nl = norm_for_cmp($opt->{live});
    if (defined $nc && defined $nl && $nc eq $nl) {
        die_usage("--clone and --live resolve to the same directory ($opt->{clone} == $opt->{live})");
    }

    my $mode      = $opt->{dry_run} ? 'dry-run' : 'apply';
    my $clone_dir = $opt->{clone};
    my $live_dir  = $opt->{live};
    my $home_dir  = $opt->{home};

    my @out;
    push @out, "promote: mode=$mode clone=$clone_dir live=$live_dir home=$home_dir";

    my $exit_code = 0;
    my $backup_dir; # undef until first overwrite, memoized for the whole run

    my $bump = sub { my $c = shift; $exit_code = $c if $c > $exit_code; };

    my $get_backup_dir = sub {
        return $backup_dir if defined $backup_dir;
        my $base = pjoin($home_dir, '.claude', '.promotion-backups');
        make_path($base) unless -d $base;
        my @t = gmtime(time());
        my $ts = sprintf('%04d%02d%02d-%02d%02d%02d', $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
        my $dir = pjoin($base, $ts);
        if (-d $dir) {
            my $n = 2;
            while (-d "$dir-$n") { $n++; }
            $dir = "$dir-$n";
        }
        make_path($dir) or die "cannot create backup dir $dir: $!\n";
        return $backup_dir = $dir;
    };

    my $backup_file = sub {
        my ($orig_bytes, $basename) = @_;
        my $dir = $get_backup_dir->();
        my $dest = pjoin($dir, $basename);
        my $err = write_bytes_atomic($dest, $orig_bytes);
        return $err if defined $err;
        my $verify = read_bytes($dest);
        return "backup verification mismatch for $dest" unless defined $verify && $verify eq $orig_bytes;
        return undef;
    };

    # -----------------------------------------------------------------
    # Preflight (spec 3.1)
    # -----------------------------------------------------------------
    my $preflight_error;
    if (!-d $clone_dir || !is_git_worktree($clone_dir)) {
        $preflight_error = "clone is missing or not a git work tree: $clone_dir";
    } elsif (!-d $live_dir || !is_git_worktree($live_dir)) {
        $preflight_error = "live is missing or not a git work tree: $live_dir";
    } else {
        my ($rc) = git_capture($clone_dir, 'rev-parse', '--verify', 'refs/heads/main');
        $preflight_error = "clone has no main branch: $clone_dir" if $rc != 0;
    }

    if (defined $preflight_error) {
        push @out, "merge: error $preflight_error";
        push @out, "claude-md: not-run";
        push @out, "settings: not-run";
        push @out, "marketplaces: not-run";
        push @out, "backup: none";
        push @out, "result: error";
        print STDERR "promote: $preflight_error\n";
        print join("\n", @out) . "\n";
        exit 2;
    }

    # .backup-preferences.json is promote.pl's own control input (spec S3.5
    # item 16), not repo content -- functionally the same as an ignored file
    # even where the live repo's own .gitignore does not yet cover it
    # (the real live install's .gitignore already lists it at the root,
    # matching any depth per gitignore's basename-pattern rule). Exclude it
    # from the dirty check via pathspec magic rather than depending on a
    # .gitignore entry existing in every fixture.
    my ($srtc, $status_text) = git_capture(
        $live_dir, 'status', '--porcelain', '--untracked-files=all',
        '--', '.', ':(exclude).backup-preferences.json',
    );
    if ($srtc == 0 && length $status_text) {
        push @out, "merge: refused-dirty";
        for my $line (split /\n/, $status_text) {
            next unless length $line;
            push @out, "  $line";
        }
        push @out, "claude-md: not-run";
        push @out, "settings: not-run";
        push @out, "marketplaces: not-run";
        push @out, "backup: none";
        push @out, "result: error";
        print STDERR "promote: live install has a dirty working tree\n";
        print join("\n", @out) . "\n";
        exit 2;
    }

    # -----------------------------------------------------------------
    # Merge (spec 3.2 / 3.8)
    # -----------------------------------------------------------------
    my ($crc, $clone_main) = git_line($clone_dir, 'rev-parse', 'main');
    if ($crc != 0 || !length $clone_main) {
        push @out, "merge: error cannot resolve clone main";
        push @out, "claude-md: not-run";
        push @out, "settings: not-run";
        push @out, "marketplaces: not-run";
        push @out, "backup: none";
        push @out, "result: error";
        print STDERR "promote: cannot resolve clone main\n";
        print join("\n", @out) . "\n";
        exit 2;
    }

    my $payload_dir; # repo to read global-config/* from
    my $payload_ref; # ref within that repo
    my $sync_stopped = 0;
    my $live_only_commits = 0; # dry-run only: live HEAD has commits clone main lacks

    # Decision 27's baseline for the settings.json array-unit widening merge:
    # the live install's HEAD *before* this run's merge changes it. Captured
    # here, before the pull below can move it. --dry-run never pulls, so
    # live's HEAD is unchanged throughout and IS the baseline (spec: "in
    # --dry-run the live HEAD is the baseline").
    my $baseline_sha;

    if ($mode eq 'apply') {
        my $pre_head = head_sha($live_dir);
        $baseline_sha = $pre_head;
        if (is_ancestor($live_dir, $clone_main, 'HEAD')) {
            push @out, "merge: up-to-date";
        } else {
            my ($prc, undef, $perr) = git_capture(
                $live_dir, 'pull', '--no-rebase', '--ff', '--no-edit', '-q', git_path($clone_dir), 'main',
            );
            if ($prc != 0) {
                if (-f pjoin($live_dir, '.git', 'MERGE_HEAD')) {
                    git_capture($live_dir, 'merge', '--abort');
                }
                push @out, "merge: failed";
                for my $line (split /\n/, $perr) {
                    next unless length $line;
                    push @out, "  $line";
                }
                push @out, "claude-md: not-run";
                push @out, "settings: not-run";
                push @out, "marketplaces: not-run";
                push @out, "backup: none";
                push @out, "result: error";
                print STDERR "promote: merge failed\n$perr";
                print join("\n", @out) . "\n";
                exit 2;
            }
            my $new_head = head_sha($live_dir);
            my ($pcrc, $parents) = git_line($live_dir, 'log', '-1', '--pretty=%P');
            my $parent_count = length($parents) ? scalar(split ' ', $parents) : 0;
            my (undef, $count) = git_line($live_dir, 'rev-list', '--count', "$pre_head..$new_head");
            my $kind = ($parent_count == 2) ? 'merged' : 'fast-forward';
            push @out, "merge: $kind " . short_sha($pre_head) . '..' . short_sha($new_head) . " ($count commits)";
        }
        $payload_dir = $live_dir;
        $payload_ref = 'HEAD';
    } else {
        my $live_head = head_sha($live_dir);
        $baseline_sha = $live_head;
        if (is_ancestor($live_dir, $clone_main, 'HEAD')) {
            push @out, "merge: up-to-date";
        } else {
            push @out, "merge: would-merge " . short_sha($live_head) . ' <- ' . short_sha($clone_main);
        }
        if (defined $live_head) {
            $live_only_commits = is_ancestor($clone_dir, $live_head, 'main') ? 0 : 1;
        }
        $payload_dir = $clone_dir;
        $payload_ref = 'main';
    }

    # -----------------------------------------------------------------
    # CLAUDE.md (spec 3.3)
    # -----------------------------------------------------------------
    my $relpath_claude = 'global-config/CLAUDE.md';
    my $home_claude = pjoin($home_dir, '.claude', 'CLAUDE.md');
    my @claude_lines;
    my $claude_status;

    if (!blob_exists($payload_dir, $payload_ref, $relpath_claude)) {
        $claude_status = 'skipped-no-payload';
    } else {
        my $payload_bytes = show_blob($payload_dir, $payload_ref, $relpath_claude);
        $payload_bytes = '' unless defined $payload_bytes;

        if (-l $home_claude) {
            my $target = readlink($home_claude) // '';
            my $target_abs = norm_for_cmp(rel2abs_ourselves($target, dirname($home_claude)));
            my $expected = norm_for_cmp(pjoin($live_dir, $relpath_claude));
            if (defined $target_abs && $target_abs eq $expected) {
                $claude_status = 'linked';
            } else {
                $bump->(1);
                $claude_status = "refused-symlink $target";
            }
        } elsif (!-e $home_claude) {
            if ($mode eq 'apply') {
                my $err = write_bytes_atomic($home_claude, $payload_bytes);
                if (defined $err) { $bump->(2); $claude_status = "error $err"; }
                else { $claude_status = 'installed'; }
            } else {
                $claude_status = 'would-install';
            }
        } else {
            my $home_bytes = read_bytes($home_claude) // '';
            my $norm = sub { my $s = shift; $s =~ s/\r\n/\n/g; return $s; };
            if ($norm->($home_bytes) eq $norm->($payload_bytes)) {
                $claude_status = 'unchanged';
            } else {
                my @hist = ($payload_bytes, payload_versions_bytes($payload_dir, $payload_ref, $relpath_claude));
                if ($mode eq 'dry-run') {
                    push @hist, payload_versions_bytes($live_dir, 'HEAD', $relpath_claude);
                }
                my %line_set;
                for my $ver (@hist) {
                    for my $l (split /\n/, $ver) {
                        (my $t = $l) =~ s/\r\z//;
                        $line_set{$t} = 1;
                    }
                }
                my @home_lines = split /\n/, $home_bytes;
                my @offending;
                for my $i (0 .. $#home_lines) {
                    (my $t = $home_lines[$i]) =~ s/\r\z//;
                    push @offending, { n => $i + 1, text => $t } unless $line_set{$t};
                }
                if (!@offending) {
                    if ($mode eq 'apply') {
                        my $err = $backup_file->($home_bytes, 'CLAUDE.md');
                        if (defined $err) { $bump->(2); $claude_status = "error $err"; }
                        else {
                            my $werr = write_bytes_atomic($home_claude, $payload_bytes);
                            if (defined $werr) { $bump->(2); $claude_status = "error $werr"; }
                            else { $claude_status = 'refreshed'; }
                        }
                    } else {
                        $claude_status = 'would-refresh';
                    }
                } else {
                    $bump->(1);
                    my $n = scalar(@offending);
                    $claude_status = "refused-local-edit $n line(s) the payload never had";
                    for my $o (@offending) {
                        push @claude_lines, "  L$o->{n}: $o->{text}";
                    }
                    push @claude_lines,
                        "  resolve: fold these lines into global-config/CLAUDE.md in the clone and promote again, or delete them from the live file.";
                }
            }
        }
    }
    push @out, "claude-md: $claude_status";
    push @out, @claude_lines;

    # -----------------------------------------------------------------
    # settings.json (spec 3.4 / 3.5)
    # -----------------------------------------------------------------
    my $relpath_settings = 'global-config/settings.json';
    my $home_settings = pjoin($home_dir, '.claude', 'settings.json');
    my @settings_lines;
    my $settings_status;

    if (!blob_exists($payload_dir, $payload_ref, $relpath_settings)) {
        $settings_status = 'skipped-no-payload';
    } elsif (!-e $home_settings) {
        $settings_status = 'skipped-missing-live';
    } else {
        my $payload_bytes = show_blob($payload_dir, $payload_ref, $relpath_settings) // '';
        my $home_bytes = read_bytes($home_settings) // '';
        my ($live_obj, $live_err)       = decode_json_bytes($home_bytes);
        my ($payload_obj, $payload_err) = decode_json_bytes($payload_bytes);

        my $prefs_path = pjoin($live_dir, '.backup-preferences.json');
        my $prefs_scope = {};
        my $prefs_err;
        if (-f $prefs_path) {
            my ($pobj, $perr) = decode_json_bytes(read_bytes($prefs_path) // '');
            if ($perr) { $prefs_err = $perr; }
            else { $prefs_scope = (ref($pobj) eq 'HASH' && ref($pobj->{live_vs_repo}) eq 'HASH') ? $pobj->{live_vs_repo} : {}; }
        }

        if ($live_err || $payload_err || $prefs_err) {
            my $reason = $live_err || $payload_err || $prefs_err;
            $bump->(2);
            $settings_status = "error $reason";
        } elsif (ref($live_obj) ne 'HASH') {
            # red-team N1: syntactically valid JSON (null, [], "x", ...) that
            # is not an object cannot be merged as a unit tree -- compute_units
            # would dereference it as a hashref and die. Report and refuse
            # instead of writing anything or crashing.
            $bump->(2);
            $settings_status = 'error live settings.json is not a JSON object';
        } elsif (ref($payload_obj) ne 'HASH') {
            $bump->(2);
            $settings_status = 'error payload settings.json is not a JSON object';
        } else {
            my @hist_versions = ($payload_obj);
            for my $b (payload_versions_bytes($payload_dir, $payload_ref, $relpath_settings)) {
                my ($v, $e) = decode_json_bytes($b);
                push @hist_versions, $v unless $e;
            }
            if ($mode eq 'dry-run') {
                for my $b (payload_versions_bytes($live_dir, 'HEAD', $relpath_settings)) {
                    my ($v, $e) = decode_json_bytes($b);
                    push @hist_versions, $v unless $e;
                }
            }

            # Decision 27's baseline object: the settings.json payload at the
            # live install's pre-merge HEAD ($baseline_sha, captured above,
            # before this run's merge could move it). undef when there is no
            # such blob (fresh install, or no settings.json at that commit) --
            # merge_array_unit treats a missing/non-hash baseline as empty.
            my $baseline_obj;
            if (defined $baseline_sha) {
                my $bbytes = show_blob($live_dir, $baseline_sha, $relpath_settings);
                if (defined $bbytes) {
                    my ($bobj, $berr) = decode_json_bytes($bbytes);
                    $baseline_obj = $bobj unless $berr;
                }
            }

            my $result = deep_clone($live_obj);
            my @units = compute_units($live_obj, $payload_obj);
            my $count = 0;
            for my $u (@units) {
                my $rel = $u->{relation};
                next if $rel eq 'identical';

                # Decision 26 / spec 09: the three permission-rule arrays
                # are merged element by element against payload history,
                # instead of being kept/replaced as one opaque value.
                my $array_key = array_unit_key($u);
                if (defined $array_key) {
                    # Decision 27 MUST (red-team M1, M2): any preference
                    # recorded for this array unit pins it fully untouched,
                    # WHATEVER its current relation -- not only the relation
                    # the preference's own category names. A skip-always pref
                    # set while diverged must still protect the array after
                    # the payload drops the key and it becomes only_left; a
                    # right-only pref set while only_right must still protect
                    # it once the operator's own array makes it diverged.
                    my $pinned_action;
                    for my $cat (qw(diverged only_left only_right)) {
                        if (pref_honoured($prefs_scope, $u->{name}, $cat)) {
                            $pinned_action = $VALID_ACTION{$cat};
                            last;
                        }
                    }
                    if (defined $pinned_action) {
                        push @settings_lines, "  kept-pref $u->{name} ($pinned_action)";
                        next;
                    }

                    my ($result_arr, $removed, $added, $changes) =
                        merge_array_unit($u, $array_key, \@hist_versions, $baseline_obj);

                    if ($changes == 0) {
                        # A pure reorder/duplicate difference or an
                        # only_left/only_right unit with nothing to report
                        # (spec S2.6): only the diverged case still names
                        # live entries the current payload does not carry.
                        if ($rel eq 'diverged') {
                            my %in_p = map { $_ => 1 } @{ $u->{payload_val} };
                            my $has_own = grep { !$in_p{$_} } @{ $u->{live_val} };
                            push @settings_lines, "  kept-local $u->{name}" if $has_own;
                        }
                        next;
                    }

                    for my $e (@$removed) {
                        push @settings_lines, "  removed $u->{name} entry " . encode_entry_json($e);
                    }
                    for my $e (@$added) {
                        push @settings_lines, "  added $u->{name} entry " . encode_entry_json($e);
                    }
                    if ($rel eq 'only_left' && !@$result_arr) {
                        # Mirrors Decision 125: emptying an only_left array
                        # by removing every retired entry retires the key
                        # itself, same as the whole-value path below.
                        delete_at_path($result, $u->{path});
                    } else {
                        set_at_path($result, $u->{path}, $result_arr);
                    }
                    $count += $changes;
                    next;
                }

                if ($rel eq 'only_left') {
                    # Decision 125: an only_left unit whose installed value
                    # canonically matches a value the payload once had (any
                    # historical version) is retired -- the payload dropped
                    # it, and the live install should catch up. Any other
                    # only_left unit is kept silently, as today.
                    my $hist_set = historical_canon_set(\@hist_versions, $u->{path});
                    if ($hist_set->{ canon_str($u->{live_val}) }) {
                        if (pref_honoured($prefs_scope, $u->{name}, 'only_left')) {
                            push @settings_lines, "  kept-pref $u->{name} (left-only)";
                        } else {
                            delete_at_path($result, $u->{path});
                            push @settings_lines, "  removed $u->{name}";
                            $count++;
                        }
                    }
                } elsif ($rel eq 'only_right') {
                    if (pref_honoured($prefs_scope, $u->{name}, 'only_right')) {
                        push @settings_lines, "  kept-pref $u->{name} (right-only)";
                    } else {
                        set_at_path($result, $u->{path}, $u->{payload_val});
                        push @settings_lines, "  added $u->{name}";
                        $count++;
                    }
                } elsif ($rel eq 'diverged') {
                    if (pref_honoured($prefs_scope, $u->{name}, 'diverged')) {
                        push @settings_lines, "  kept-pref $u->{name} (skip-always)";
                    } else {
                        my $hist_set = historical_canon_set(\@hist_versions, $u->{path});
                        if ($hist_set->{ canon_str($u->{live_val}) }) {
                            set_at_path($result, $u->{path}, $u->{payload_val});
                            push @settings_lines, "  updated $u->{name}";
                            $count++;
                        } else {
                            push @settings_lines, "  kept-local $u->{name}";
                        }
                    }
                }
            }

            if ($count == 0) {
                $settings_status = 'unchanged';
            } elsif ($mode eq 'apply') {
                my $err = $backup_file->($home_bytes, 'settings.json');
                if (defined $err) {
                    $bump->(2);
                    $settings_status = "error $err";
                } else {
                    # red-team N2, handled as the CLAUDE.md branch's symlink
                    # awareness: a plain rename(tmp, $home_settings) would
                    # replace the symlink node itself with a regular file.
                    # Resolve through it and write the real target instead,
                    # so the symlink survives the promotion.
                    my $write_path = (-l $home_settings) ? (abs_path($home_settings) // $home_settings) : $home_settings;
                    my $werr = write_bytes_atomic($write_path, encode_json_bytes($result));
                    if (defined $werr) { $bump->(2); $settings_status = "error $werr"; }
                    else { $settings_status = "updated ($count changes)"; }
                }
            } else {
                $settings_status = "would-update ($count changes)";
            }
        }
    }
    push @out, "settings: $settings_status";
    if ($mode eq 'dry-run' && $live_only_commits) {
        push @out,
            "  caveat: preview ignores live-only commits -- live HEAD " . short_sha($baseline_sha)
            . " has commits clone main " . short_sha($clone_main)
            . " lacks; a real promote merges first, so the result may differ either way --"
            . " apply may report or perform changes this preview doesn't show, or this"
            . " preview's 'removed'/'updated' lines may not happen";
    }
    push @out, @settings_lines;

    # -----------------------------------------------------------------
    # known_marketplaces.json (spec 3.6) -- report only, never written
    # -----------------------------------------------------------------
    my $relpath_mp = 'global-config/known_marketplaces.json';
    my $home_mp = pjoin($home_dir, '.claude', 'plugins', 'known_marketplaces.json');
    my @mp_lines;
    my $mp_status;

    if (!blob_exists($payload_dir, $payload_ref, $relpath_mp)) {
        $mp_status = 'skipped-no-payload';
    } elsif (!-e $home_mp) {
        $mp_status = 'skipped-missing-live';
    } else {
        my $payload_bytes = show_blob($payload_dir, $payload_ref, $relpath_mp) // '';
        my $home_bytes = read_bytes($home_mp) // '';
        my ($live_obj, $live_err)       = decode_json_bytes($home_bytes);
        my ($payload_obj, $payload_err) = decode_json_bytes($payload_bytes);
        if ($live_err || $payload_err) {
            $bump->(2);
            $mp_status = 'error ' . ($live_err || $payload_err);
        } else {
            # Strip volatile fields, mirroring ccpraxis-helpers.pl:389-399
            # (cmd_marketplace_diff): installLocation is machine-specific,
            # lastUpdated is a routine refresh timestamp -- neither
            # distinguishes what a marketplace IS.
            my @VOLATILE = qw(installLocation lastUpdated);
            my $strip = sub {
                my $obj = shift;
                my %out;
                for my $name (keys %$obj) {
                    my $entry = { %{ $obj->{$name} // {} } };
                    delete $entry->{$_} for @VOLATILE;
                    $out{$name} = $entry;
                }
                return \%out;
            };
            my $live_clean    = $strip->($live_obj);
            my $payload_clean = $strip->($payload_obj);

            my %all;
            $all{$_} = 1 for (keys %$live_clean, keys %$payload_clean);

            # Preferences, mirroring ccpraxis-helpers.pl:446-469: same
            # category/action table, "marketplaces" scope. A parse failure
            # is swallowed to {} there (cmd_marketplace_diff:451-456 never
            # checks read_json_file's error return), so mirrored exactly.
            my $prefs_scope = {};
            my $prefs_path = pjoin($live_dir, '.backup-preferences.json');
            if (-f $prefs_path) {
                my ($pobj) = decode_json_bytes(read_bytes($prefs_path) // '');
                $prefs_scope = (ref($pobj) eq 'HASH' && ref($pobj->{marketplaces}) eq 'HASH') ? $pobj->{marketplaces} : {};
            }

            for my $name (sort keys %all) {
                my $in_l = exists $live_clean->{$name};
                my $in_r = exists $payload_clean->{$name};
                if ($in_l && !$in_r) {
                    next; # live-only entries are never reported (spec 3.6.20)
                } elsif (!$in_l && $in_r) {
                    next if pref_honoured($prefs_scope, $name, 'only_right');
                    my $entry = $payload_clean->{$name};
                    my $src = (ref($entry) eq 'HASH' && ref($entry->{source}) eq 'HASH') ? $entry->{source} : {};
                    my $hint = (($src->{source} // '') eq 'github')
                        ? "/plugin marketplace add " . ($src->{repo} // '')
                        : 'add manually';
                    push @mp_lines, "  missing-live $name hint: $hint";
                } else {
                    next if same_value($live_clean->{$name}, $payload_clean->{$name});
                    next if pref_honoured($prefs_scope, $name, 'diverged');
                    push @mp_lines, "  diverged $name";
                }
            }
            $mp_status = @mp_lines ? 'action-needed' : 'in-sync';
        }
    }
    push @out, "marketplaces: $mp_status";
    push @out, @mp_lines;

    # -----------------------------------------------------------------
    # backup / result
    # -----------------------------------------------------------------
    push @out, 'backup: ' . (defined $backup_dir ? $backup_dir : 'none');
    my $result = $exit_code == 2 ? 'error' : $exit_code == 1 ? 'refused' : 'ok';
    push @out, "result: $result";

    print join("\n", @out) . "\n";
    exit $exit_code;
}

# rel2abs without pulling in File::Spec's own path-separator assumptions,
# which disagree with the forward-slash convention used everywhere else in
# this script on this host.
sub rel2abs_ourselves {
    my ($path, $base) = @_;
    $path =~ s{\\}{/}g;
    return $path if $path =~ m{^[a-zA-Z]:/} || $path =~ m{^/};
    return pjoin($base, $path);
}

main();
