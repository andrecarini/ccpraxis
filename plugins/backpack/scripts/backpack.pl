#!/usr/bin/env perl
# backpack.pl — what you packed for the /sandbox container.
#
# Owns the per-project backpack.json file declaring what tools, runtimes, and
# project-setup commands the sandbox needs. Two consumers:
#   * Host-side: the /sandbox launcher runs `install` on container (re)creation
#     to bring the new container up to the declared state before handing off.
#   * Container-side: the inside-sandbox agent runs `add` / `remove` (via the
#     /backpack:add and /backpack:remove plugin commands) to record what got
#     installed during real work, OR the PostToolUse Bash hook auto-seeds
#     entries from apt/npm/pip/cargo install commands.
#
# Subcommands:
#   validate <path>                                          Schema-check the file. Exit 0 ok, 1 invalid.
#   list <path>                                              Pretty-print the contents.
#   add <path> --category C --name N --install I --verify V [--rationale R]
#                                                           Add or update entry (idempotent on category+name).
#   remove <path> --category C --name N                     Drop an entry (idempotent).
#   install <path> [--declared <declared-path>]              Run verify; if it fails, run install. Reports status per item.
#                                                           With --declared, also reconciles against the full declared
#                                                           backpack (DECLARED/ABSENT/EXTRA/RECONCILE lines) instead of
#                                                           only the handed (possibly pre-filtered) install-set. A missing
#                                                           or unparseable --declared file degrades to a loud WARNING and
#                                                           skips reconciliation rather than aborting the install pass.
#                                                           Exit codes: 0 clean (and fully reconciled, if --declared);
#                                                           1 an item's install/verify actually failed; 2 every item
#                                                           installed/skipped fine but --declared reconciliation MISMATCHed.
#                                                           A bin_dirs entry outside the backpack's install root is
#                                                           reported per item (REJECTED lines, BIN_DIRS_REJECTED count)
#                                                           and excluded from the PATH profile fragment, but does NOT
#                                                           change the exit code -- see the comment above install_root()
#                                                           for why that's a deliberate compatibility choice, not an
#                                                           oversight.
#   audit <path>                                             Audit each item: runs verify (no install) + checks rationale.
#   deps <path> --note TEXT                                  Print a depends_on dependency/ordering audit table (a cycle
#                                                           member is reported as load_bearing: CYCLE, not folded into
#                                                           yes/no). --note is echoed verbatim (e.g. a "this is a
#                                                           synthetic fixture" disclaimer) and validated like every other
#                                                           free-text field.
#   help                                                     Show usage.
#
# Schema (backpack v2):
#   { "version": 2, "items": [ {
#       "category": "apt|npm-global|pip|cargo|gem|go-install|curl-script|snap|project-setup|other",
#       "name":      "<non-empty string, no newline>",
#       "install":   "<shell command, no newline>",
#       "verify":    "<shell command, no newline>",
#       "rationale": "<optional, free-text 'why this is in the backpack'>",
#       "depends_on":"<optional array of 'category:name' refs to other items in the SAME file that must install first>",
#       "bin_dirs":  "<optional array of absolute directory paths this item's binaries land in;
#                     `install` aggregates these (plus the standing /opt/tools/bin floor) into a
#                     PATH profile fragment AND applies them to $ENV{PATH} in-process, so verify/
#                     install commands can use a bare command name instead of a hand-rolled
#                     `export PATH=...` preamble. `add` rejects any entry outside the backpack's
#                     own install root (the /opt/tools prefix the floor lives under) -- an
#                     unconstrained bin_dirs entry would otherwise ride into the PATH of every
#                     future login shell in the container>",
#       "added":     "<ISO date, auto-set on add>"
#     } ] }
#
# NOTE: a per-item "version" field was REMOVED from the schema (it duplicated the
# pin already baked into the install command / verify check and could silently
# drift out of sync — the command is the single source of truth). The top-level
# "version": 2 above is the SCHEMA version and is unrelated. Existing files that
# still carry a per-item "version" are tolerated: it is stripped on read (so it
# never displays) and dropped on the next write. `add --version` is rejected.
#
# The schema changed from v1 to v2: the top-level array was renamed `tools` → `items`,
# and `rationale` was added as an optional field. v1 files are rejected with a clear
# error pointing at this change.

use strict;
use warnings;
use utf8;                  # source-literal non-ASCII (e.g. em-dashes in FAIL/usage text) are real chars, encoded exactly once by the :encoding layers below — NOT raw bytes the layer would double-encode
use JSON::PP;
use Getopt::Long qw(GetOptionsFromArray);
use POSIX qw(strftime);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use Encode ();

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

# @ARGV arrives as UTF-8 octets (this script runs in the UTF-8 sandbox container,
# where /backpack:add records entries). Decode to Perl characters up front so any
# non-ASCII in --rationale / --install / --verify is stored as TEXT and JSON-
# encoded exactly once on write. Without this, the raw UTF-8 bytes are treated as
# Latin-1 and re-encoded by JSON::PP's ->utf8, double-mojibaking them (an em-dash
# 'E2 80 94' landed on disk as 'C3 A2 C2 80 C2 94'). FB_DEFAULT leaves a non-UTF-8
# arg (e.g. an ASCII path from a host-side `validate`) intact rather than dying.
@ARGV = map { Encode::decode('UTF-8', $_, Encode::FB_DEFAULT) } @ARGV;

our $SCHEMA_VERSION = 2;
our @ALLOWED_CATEGORIES = qw(apt npm-global pip cargo gem go-install curl-script snap project-setup other);
our %ALLOWED_CATEGORY = map { $_ => 1 } @ALLOWED_CATEGORIES;

# The standing floor: every install/audit pass puts this directory on PATH
# regardless of any item's own bin_dirs. Concrete directories named in
# individual items are NOT hardcoded here -- see aggregate_bin_dirs. Assigned
# here (before dispatch) rather than down among the other subs, because a
# top-level statement only runs when program flow actually reaches it --
# dispatch below calls straight into cmd_install/cmd_audit, which would see
# an empty @PATH_FLOOR_DIRS if this assignment sat textually later in the file.
our @PATH_FLOOR_DIRS = ('/opt/tools/bin');

# Snapshot the PROCESS's inherited PATH exactly once, before anything below
# has a chance to mutate $ENV{PATH}. apply_path_env (fix-batch step7,
# CRITICAL-2 fix) is now called PER ITEM inside cmd_install's/cmd_audit's
# loops -- if it prepended onto the CURRENT $ENV{PATH} each time (as a naive
# implementation would), every item's dirs would silently accumulate onto
# every SUBSEQUENT item's scope across the loop, reopening exactly the
# cross-item contamination CRITICAL-2 exists to close. Always rebuilding
# from this one fixed snapshot makes each call's result depend only on that
# item's own dirs, never on how many items were processed before it.
our $ORIGINAL_PATH = $ENV{PATH} // '';

# bin_dirs content-rule bounds (fix-batch step7, MEDIUM finding Part B): a
# single pathological entry (observed: 100KB on this dev host) broke every
# subsequent `bash -c` spawn by blowing an OS environment-block limit. These
# are generous but bounded -- 1024 bytes is far beyond any real directory
# path, 65536 aggregate covers a backpack with hundreds of entries.
our $BIN_DIRS_MAX_ENTRY_LEN = 1024;
our $BIN_DIRS_MAX_TOTAL_LEN = 65536;

my $cmd = shift @ARGV // "help";

if    ($cmd eq "validate") { cmd_validate() }
elsif ($cmd eq "list")     { cmd_list()     }
elsif ($cmd eq "add")      { cmd_add()      }
elsif ($cmd eq "remove")   { cmd_remove()   }
elsif ($cmd eq "install")  { cmd_install()  }
elsif ($cmd eq "audit")    { cmd_audit()    }
elsif ($cmd eq "deps")     { cmd_deps()     }
else                       { cmd_help(); exit ($cmd eq "help" ? 0 : 2) }

exit 0;

# ── Helpers ──────────────────────────────────────────────────────────

sub emit {
    my ($k, $v) = @_;
    $v = "" unless defined $v;
    print "$k: $v\n";
}

sub die_user {
    my ($msg) = @_;
    print STDERR "ERROR: $msg\n";
    exit 1;
}

sub read_json {
    my $file = shift;
    open my $fh, '<:raw', $file or return undef;
    local $/;
    my $content = <$fh>;
    close $fh;
    my $data = eval { decode_json($content) };
    return $@ ? undef : $data;
}

sub write_json_atomic {
    my ($file, $data) = @_;
    my $dir = dirname($file);
    make_path($dir) unless -d $dir;
    my $tmp = "$file.tmp.$$";
    open my $fh, '>:raw', $tmp or die "write $tmp: $!\n";
    print $fh JSON::PP->new->canonical(1)->pretty->utf8->encode($data);
    close $fh or die "close $tmp: $!\n";
    # Linux/macOS: rename(2) atomically replaces the destination.
    # Windows: rename() fails if the destination exists, so fall back to
    # unlink-then-rename. There is a microsecond window between unlink and
    # rename where the destination doesn't exist and the new content lives
    # only in the .tmp file. If a process kill or power loss interrupts
    # this window, recovery is MANUAL: rename
    #   $file.tmp.$PID → $file
    # by hand (find the orphan .tmp.* sibling). Re-running the add/remove
    # won't help because the desired content is in the .tmp, not lost.
    unless (rename $tmp, $file) {
        if (-e $file) {
            unlink $file or do {
                unlink $tmp;
                die "unlink $file failed: $!\n";
            };
            rename $tmp, $file or do {
                unlink $tmp;
                die "rename $tmp -> $file (after unlink): $!\n";
            };
        } else {
            unlink $tmp;
            die "rename $tmp -> $file: $!\n";
        }
    }
}

sub today_iso {
    return strftime('%Y-%m-%d', gmtime);
}

# write_text_atomic($file, $content) -- mirrors write_json_atomic (make_path
# the parent dir, write to a .tmp.$$ sibling, rename over the destination).
# Used only by cmd_install for the PATH profile fragment; failures are caught
# by the caller (non-fatal there), so this sub is allowed to die -- the
# caller wraps it in an eval.
sub write_text_atomic {
    my ($file, $content) = @_;
    my $dir = dirname($file);
    make_path($dir) unless -d $dir;
    my $tmp = "$file.tmp.$$";
    open my $fh, '>:raw', $tmp or die "write $tmp: $!\n";
    print $fh $content;
    close $fh or die "close $tmp: $!\n";
    unless (rename $tmp, $file) {
        if (-e $file) {
            unlink $file or do { unlink $tmp; die "unlink $file failed: $!\n"; };
            rename $tmp, $file or do { unlink $tmp; die "rename $tmp -> $file (after unlink): $!\n"; };
        } else {
            unlink $tmp;
            die "rename $tmp -> $file: $!\n";
        }
    }
    eval { chmod 0644, $file };
}

# @PATH_FLOOR_DIRS is declared near the top of the file (before dispatch) --
# see the comment there for why.

# apply_path_env(@dirs) -- sets $ENV{PATH} in-process (this same backpack.pl
# process, not a child shell) so every subsequent run_bash/run_bash_silent
# call -- a fresh `bash -c` child that inherits %ENV -- can find binaries in
# @dirs by bare command name. This is independent of whether the on-disk
# profile fragment was written or will ever be sourced by anything; it is
# what actually closes the reinstall loop (DC3).
sub apply_path_env {
    my (@dirs) = @_;
    # Always rebuild from the fixed $ORIGINAL_PATH snapshot, never from the
    # (possibly already-mutated-by-a-previous-call) current $ENV{PATH} -- see
    # the comment above $ORIGINAL_PATH's declaration for why that matters
    # now that this is called per item in a loop.
    $ENV{PATH} = join(':', @dirs) . ":$ORIGINAL_PATH";
}

# item_bin_dirs($item) -> floor + THAT item's own bin_dirs only, deduped
# (fix-batch step7, CRITICAL-2 fix). Scoping install/verify PATH to a single
# item's own declared directories -- never the union of every item in the
# file -- is what stops an unrelated item's bin_dirs binary from making a
# never-installed item falsely report itself present (redteam-step6
# CRITICAL-2 reproducer: two items independently checking for the same
# command name).
sub item_bin_dirs {
    my ($item) = @_;
    my (@dirs, %seen);
    for my $d (@PATH_FLOOR_DIRS, @{ $item->{bin_dirs} // [] }) {
        next if $seen{$d}++;
        push @dirs, $d;
    }
    return @dirs;
}

# apply_path_env_for_item($item) -- sets $ENV{PATH} to THAT item's own scope
# (see item_bin_dirs) immediately before running its verify/install. Called
# once per item, at the top of each iteration, so every other item's
# commands run under their OWN scope instead of a shared aggregate.
sub apply_path_env_for_item {
    my ($item) = @_;
    apply_path_env(item_bin_dirs($item));
}

# ── install-root containment (fix-batch step7, CRITICAL-1) ────────────
#
# bin_dirs was an unconstrained absolute directory, prepended ahead of
# root's PATH for the WHOLE container's remaining life via the persisted
# profile fragment -- invisible to both the approval-hash gate (bin_dirs is
# not an item_hash input) and the human review screen (BackpackReview.pm
# never prints it). Both of those live outside this package's write set
# (BackpackApproval.pm / BackpackReview.pm are explicitly off-limits here --
# see the fix-batch dispatch and z01 residual note in the fix-batch report).
# The fix INSIDE this write set: constrain what actually reaches the
# PERSISTENT fragment to directories inside the backpack's own install root
# -- collapsing "prepend an arbitrary attacker-chosen directory to root's
# PATH" down to "reorder within directories the backpack itself already owns
# and populates". install_root() derives the root from the SAME
# @PATH_FLOOR_DIRS constant the floor itself uses (its parent directory) so
# there is exactly one place that names "/opt/tools" -- not a second,
# independently-maintained copy that could drift.
#
# Deliberately NOT applied to item_bin_dirs/apply_path_env_for_item (an
# item's own scope, used to run ITS OWN install/verify): an item already
# runs arbitrary shell as root via its own install/verify text, so an
# out-of-root bin_dirs entry used only within that item's own scope grants
# it no capability it didn't already have. What matters is stopping it from
# (a) contaminating OTHER items' scope (closed by CRITICAL-2's per-item
# scoping) and (b) persisting into the on-disk fragment sourced by every
# future login shell for the rest of the container's life -- (b) is what
# install_root()/dir_within_root() below actually gates.
sub install_root {
    return dirname($PATH_FLOOR_DIRS[0]);
}

# normalize_path($p) -> a lexically-normalized absolute path: collapses
# duplicate/trailing slashes and resolves '..'/'.' segments WITHOUT touching
# the filesystem (no symlink resolution -- that would be a TOCTOU trap for a
# root-owned check). "/opt/tools/../../etc" normalizes to "/etc" and is
# correctly seen as escaping the root by dir_within_root below.
sub normalize_path {
    my ($p) = @_;
    my @parts = split m{/+}, $p;
    my @stack;
    for my $part (@parts) {
        next if $part eq '' || $part eq '.';
        if ($part eq '..') {
            pop @stack if @stack;
        } else {
            push @stack, $part;
        }
    }
    return '/' . join('/', @stack);
}

# dir_within_root($dir, $root) -> true iff $dir, after lexical normalization,
# IS $root or is nested under it. String comparison after normalization, not
# a filesystem check.
sub dir_within_root {
    my ($dir, $root) = @_;
    my $nd = normalize_path($dir);
    my $nr = normalize_path($root);
    return 1 if $nd eq $nr;
    return index($nd, "$nr/") == 0;
}

# aggregate_bin_dirs_filtered(\@items, $root) -> (\@dirs, \@rejected).
# @dirs: floor first, then each item's bin_dirs entries that pass
# dir_within_root, deduped, floor-then-file order -- exactly what
# cmd_install writes into the PERSISTENT profile fragment (the thing that
# outlives this process and is sourced by every future login shell).
# @rejected: [label, dir] pairs for entries that failed the root check --
# EXCLUDED from the fragment, but reported per-item (not silently dropped),
# and NOT treated as a whole-file abort (MEDIUM fix: the offending item
# still installs/verifies normally via its own scope, see item_bin_dirs).
sub aggregate_bin_dirs_filtered {
    my ($items_ref, $root) = @_;
    my (@dirs, %seen, @rejected);
    for my $d (@PATH_FLOOR_DIRS) {
        next if $seen{$d}++;
        push @dirs, $d;
    }
    for my $t (@$items_ref) {
        my $label = "$t->{category}:$t->{name}";
        for my $d (@{ $t->{bin_dirs} // [] }) {
            if (dir_within_root($d, $root)) {
                next if $seen{$d}++;
                push @dirs, $d;
            } else {
                push @rejected, [$label, $d];
            }
        }
    }
    return (\@dirs, \@rejected);
}

# cycle_line(\@labels, $prefix) -> a bounded "CYCLE: <prefix><labels>\n" line
# (NIT-1 fix). A pathological cycle graph could otherwise print every member
# on one unbounded line; truncate to the first N and say explicitly how many
# were omitted, rather than emitting an ever-growing line silently.
sub cycle_line {
    my ($labels, $prefix) = @_;
    $prefix //= '';
    my $max = 25;
    my @shown = @$labels;
    my $omitted = 0;
    if (@shown > $max) {
        $omitted = @shown - $max;
        @shown = @shown[0 .. $max - 1];
    }
    my $line = "CYCLE: $prefix" . join(', ', @shown);
    $line .= " (+$omitted more, truncated)" if $omitted;
    return "$line\n";
}

# Load the backpack file. Missing file → return a fresh empty backpack. Malformed
# JSON or wrong schema version → die. `add` against a missing file should create
# one, but a corrupted file should never be silently overwritten.
#
# Per-entry validation (via validate_backpack) runs by default — `add` / `remove`
# / `install` / `list` all need a fully valid file to operate safely. Pass
# skip_full_validate => 1 from cmd_validate, which does its own richer reporting.
#
# opts{soft} => 1: NEVER exit. Return undef on any problem (missing file,
# invalid JSON, wrong schema, invalid items) after printing a WARNING (not
# ERROR) to STDERR, instead of die_user's hard exit(1). Used by `install
# --declared` (MINOR-1 fix): a broken/missing declared-accounting file must
# degrade reconciliation to "unavailable", never abort the whole install pass
# -- that would make the accounting layer itself a new all-or-nothing gate of
# exactly the class this package exists to close.
sub load_backpack {
    my ($path, %opts) = @_;
    my $soft = $opts{soft};
    my $fail = sub {
        my ($msg) = @_;
        if ($soft) {
            print STDERR "WARNING: $msg\n";
            return undef;
        }
        die_user($msg);
    };
    if (!-f $path) {
        return { version => $SCHEMA_VERSION, items => [] } if $opts{create_if_missing};
        return $fail->("backpack file not found: $path");
    }
    my $data = read_json($path);
    return $fail->("backpack file is not valid JSON: $path") unless defined $data;
    return $fail->("backpack file is not an object: $path") unless ref $data eq 'HASH';
    my $v = $data->{version} // 0;
    if ($v == 1) {
        return $fail->("backpack file is on legacy schema v1 (uses 'tools' key): $path. "
            . "Rename top-level 'tools' to 'items' and bump 'version' to 2, then re-run.");
    }
    return $fail->("backpack schema version mismatch: expected $SCHEMA_VERSION, got $v ($path)")
        unless $v == $SCHEMA_VERSION;
    return $fail->("backpack 'items' is not an array: $path")
        unless ref $data->{items} eq 'ARRAY';

    # The per-item 'version' field was removed from the schema (it duplicated the
    # install command's pin and could drift). Tolerate it in existing files but
    # strip it on read so it never displays and the next write drops it. This is
    # NOT the top-level $data->{version} schema marker, which stays.
    delete $_->{version} for grep { ref $_ eq 'HASH' } @{ $data->{items} };

    return $data if $opts{skip_full_validate};

    my @issues = validate_backpack($data);
    my @errors = grep { $_->[0] eq 'error' } @issues;
    if (@errors) {
        if ($soft) {
            print STDERR "WARNING: backpack file is invalid: $path\n";
            for my $e (@errors) { print STDERR "  - $e->[1]\n"; }
            return undef;
        }
        print STDERR "ERROR: backpack file is invalid: $path\n";
        for my $e (@errors) { print STDERR "  - $e->[1]\n"; }
        exit 1;
    }
    return $data;
}

# Shared control/escape/newline/null-byte validation for any plain-text field
# (category/name/install/verify/rationale/depends_on entries). Centralized so
# a newly added field can't accidentally skip this defense the way depends_on
# originally did (MAJOR-2 fix) -- the check was duplicated by hand per-field
# instead of shared, so a new field is validated by construction from now on.
sub push_text_issues {
    my ($issues, $label, $val) = @_;
    return unless defined $val;
    if (ref $val) {
        push @$issues, ['error', "$label: must be a string"];
        return;
    }
    push @$issues, ['error', "$label: must not contain newlines"]
        if $val =~ /[\r\n]/;
    push @$issues, ['error', "$label: must not contain null bytes"]
        if $val =~ /\0/;
    # Control/escape chars (e.g. ESC 0x1b) are rejected so a hostile backpack
    # can't emit terminal cursor/clear sequences during the launcher's
    # per-item approval review to spoof a benign-looking command (the
    # AS-ROOT install gate, #21 red-team), or in the `deps` audit table / the
    # `install` DANGLING line (MAJOR-2 red-team, depends_on specifically).
    # Tab is allowed.
    push @$issues, ['error', "$label: must not contain control/escape characters"]
        if $val =~ /[\x01-\x08\x0b\x0c\x0e-\x1f\x7f]/;
}

# bin_dirs_entry_problem($d) -> undef if $d is a well-formed bin_dirs entry,
# else a short problem description (no "items[N].bin_dirs entry: " prefix --
# callers add that). Covers every CONTENT rule a bin_dirs entry must satisfy
# (null/type/newline/null-byte/control-char/whitespace-only/length/absolute/
# forbidden-char) in one place, shared between validate_backpack (the hard,
# authoring-time gate used by `validate`/`add`/the initial `install` load)
# and cmd_add's own inline check. Deliberately does NOT include the
# install-root containment rule (dir_within_root) -- that one is enforced
# separately (hard at `add`-time via install_root()/dir_within_root() below,
# soft/per-item at `install`-time via aggregate_bin_dirs_filtered) because a
# root violation must NOT abort the whole install pass the way every rule
# here does (MEDIUM fix, fix-batch step7) -- see the comment above
# install_root() for the full reasoning, including why t/10's oracle fixture
# is legitimately outside /opt/tools and must still install cleanly.
#
# LOW fix (fix-batch step7): the null check closes the one gap the red-team
# confirmed -- push_text_issues used to return silently on undef, and the
# caller's own `next unless defined $d` compounded it, letting a null
# element reach join(':', @dirs) as an empty PATH segment (a POSIX shell
# reads "" as the current directory -- in a file sourced by root).
sub bin_dirs_entry_problem {
    my ($d) = @_;
    return "must not be null" unless defined $d;
    return "must be a string" if ref $d;
    return "must not contain newlines" if $d =~ /[\r\n]/;
    return "must not contain null bytes" if $d =~ /\0/;
    return "must not contain control/escape characters"
        if $d =~ /[\x01-\x08\x0b\x0c\x0e-\x1f\x7f]/;
    return "must not be empty or whitespace-only" if $d =~ /^\s*$/;
    return "exceeds maximum length ($BIN_DIRS_MAX_ENTRY_LEN bytes)"
        if length($d) > $BIN_DIRS_MAX_ENTRY_LEN;
    return "must be an absolute path (starting with '/')" unless $d =~ m{^/};
    return "must not contain ':', '\"', '\$', backtick, or whitespace"
        if $d =~ /[:"\$`\s]/;
    return undef;
}

# Returns a list of (severity, message) tuples. severity is 'error' or 'warn'.
sub validate_backpack {
    my $bp = shift;
    my @issues;

    push @issues, ['error', "top-level must be a JSON object"] unless ref $bp eq 'HASH';
    return @issues unless ref $bp eq 'HASH';

    my $v = $bp->{version};
    push @issues, ['error', "missing 'version'"] unless defined $v;
    push @issues, ['error', "'version' must equal $SCHEMA_VERSION (got " . ($v // 'undef') . ")"]
        if defined $v && $v != $SCHEMA_VERSION;

    my $items = $bp->{items};
    push @issues, ['error', "missing 'items' array"] unless defined $items;
    return @issues unless ref $items eq 'ARRAY';

    my %seen;
    my $bin_dirs_total_len = 0;
    for my $i (0 .. $#$items) {
        my $t = $items->[$i];
        unless (ref $t eq 'HASH') {
            push @issues, ['error', "items[$i]: must be an object"];
            next;
        }
        for my $f (qw(category name install verify)) {
            my $val = $t->{$f};
            if (!defined $val || $val eq '') {
                push @issues, ['error', "items[$i]: missing required '$f'"];
                next;
            }
            # Null-byte check: bash -c may truncate at \0 on some libc
            # implementations, executing only the prefix while the user sees
            # the full string in the list display. Reject at validation time.
            push_text_issues(\@issues, "items[$i].$f", $val);
        }
        # Optional rationale: when present, must be a non-ref non-newline string.
        push_text_issues(\@issues, "items[$i].rationale", $t->{rationale})
            if defined $t->{rationale};
        # Optional depends_on: when present, an array of "category:name" strings
        # naming other items in the SAME file that must install first. Optional
        # and backward-compatible -- absence is unchanged behavior. Each entry
        # gets the SAME control/escape/newline/null-byte validation every other
        # field already receives (MAJOR-2 fix): unsanitized depends_on entries
        # reach the `deps` audit table and `install`'s DANGLING line raw.
        if (defined $t->{depends_on}) {
            if (ref $t->{depends_on} ne 'ARRAY') {
                push @issues, ['error', "items[$i].depends_on: must be an array"];
            } else {
                for my $d (@{ $t->{depends_on} }) {
                    push_text_issues(\@issues, "items[$i].depends_on entry", $d);
                }
            }
        }
        # Optional bin_dirs: when present, an array of absolute directory paths
        # this item's binaries land in. Every entry is validated by the
        # shared bin_dirs_entry_problem() (null/type/newline/null-byte/
        # control-char/whitespace-only/length/absolute/forbidden-char --
        # fix-batch step7 folded the null/whitespace/length rules into the
        # same shared check the pre-existing absolute/forbidden-char rules
        # already used). The install-root containment rule is DELIBERATELY
        # NOT here -- see the comment above install_root() for why.
        if (defined $t->{bin_dirs}) {
            if (ref $t->{bin_dirs} ne 'ARRAY') {
                push @issues, ['error', "items[$i].bin_dirs: must be an array"];
            } else {
                for my $d (@{ $t->{bin_dirs} }) {
                    my $problem = bin_dirs_entry_problem($d);
                    if (defined $problem) {
                        push @issues, ['error', "items[$i].bin_dirs entry: $problem"];
                    } else {
                        $bin_dirs_total_len += length($d);
                    }
                }
            }
        }
        if (defined $t->{category} && !$ALLOWED_CATEGORY{$t->{category}}) {
            push @issues, ['warn', "items[$i].category '$t->{category}' is not in the known set ("
                . join(",", @ALLOWED_CATEGORIES) . ")"];
        }
        if (defined $t->{name} && defined $t->{category}) {
            my $key = "$t->{category}\0$t->{name}";
            push @issues, ['error', "items[$i]: duplicate (category,name)=($t->{category},$t->{name})"]
                if $seen{$key}++;
        }
    }

    # MEDIUM Part B fix: an aggregate cap across every valid bin_dirs entry
    # in the whole file, in addition to the per-entry cap above -- guards
    # against many small-but-not-individually-huge entries collectively
    # producing a pathological PATH value.
    push @issues, ['error', "bin_dirs: aggregate length across all entries exceeds maximum ($BIN_DIRS_MAX_TOTAL_LEN bytes)"]
        if $bin_dirs_total_len > $BIN_DIRS_MAX_TOTAL_LEN;

    return @issues;
}

# ── Subcommands ──────────────────────────────────────────────────────

sub cmd_validate {
    my $path = shift @ARGV or die_user("usage: validate <path>");
    my $bp = load_backpack($path, skip_full_validate => 1);
    my @issues = validate_backpack($bp);
    my @errors = grep { $_->[0] eq 'error' } @issues;
    my @warns  = grep { $_->[0] eq 'warn'  } @issues;

    if (@errors) {
        emit("STATUS", "invalid");
        emit("ERRORS", scalar @errors);
        for my $e (@errors) { print STDERR "  - $e->[1]\n"; }
        for my $w (@warns)  { print STDERR "  ! $w->[1]\n"; }
        exit 1;
    }
    emit("STATUS", "ok");
    emit("ITEMS", scalar @{$bp->{items}});
    if (@warns) {
        emit("WARNINGS", scalar @warns);
        for my $w (@warns) { print STDERR "  ! $w->[1]\n"; }
    }
}

sub cmd_list {
    my $path = shift @ARGV or die_user("usage: list <path>");
    my $bp = load_backpack($path);

    my $items = $bp->{items};
    emit("PATH", $path);
    emit("ITEMS", scalar @$items);
    return if !@$items;

    # Group by category for readability, but preserve insertion order within group.
    my %by_cat;
    my @cat_order;
    for my $t (@$items) {
        my $c = $t->{category};
        push @cat_order, $c unless exists $by_cat{$c};
        push @{$by_cat{$c}}, $t;
    }

    for my $cat (@cat_order) {
        for my $t (@{$by_cat{$cat}}) {
            print "  $cat: $t->{name}\n";
            print "      install:   $t->{install}\n";
            print "      verify:    $t->{verify}\n";
            if (defined $t->{rationale} && $t->{rationale} ne '') {
                print "      rationale: $t->{rationale}\n";
            } else {
                print "      rationale: (none — agent should fill in)\n";
            }
        }
    }
}

sub cmd_add {
    my $path = shift @ARGV or die_user("usage: add <path> --category C --name N --install I --verify V [--rationale R]");
    # The per-item version field was removed from the schema. Reject it loudly
    # (rather than silently ignore) so callers update to pinning inside --install.
    die_user("the per-item --version field was removed from the backpack schema; "
        . "pin the version inside the --install command (e.g. 'apt-get install -y jq=1.6') instead")
        if grep { /^--version(?:=|$)/ } @ARGV;
    my ($category, $name, $install, $verify, $rationale, $bin_dirs_raw);
    GetOptionsFromArray(\@ARGV,
        'category=s'  => \$category,
        'name=s'      => \$name,
        'install=s'   => \$install,
        'verify=s'    => \$verify,
        'rationale=s' => \$rationale,
        'bin_dirs=s@' => \$bin_dirs_raw,
    ) or die_user("invalid options for add");

    for my $f (qw(category name install verify)) {
        my %vals = (category => $category, name => $name, install => $install, verify => $verify);
        die_user("--$f is required") unless defined $vals{$f} && $vals{$f} ne '';
        die_user("--$f must not contain newlines") if $vals{$f} =~ /[\r\n]/;
        die_user("--$f must not contain null bytes") if $vals{$f} =~ /\0/;
        die_user("--$f must not contain control/escape characters")
            if $vals{$f} =~ /[\x01-\x08\x0b\x0c\x0e-\x1f\x7f]/;
    }
    if (defined $rationale) {
        die_user("--rationale must not contain newlines") if $rationale =~ /[\r\n]/;
        die_user("--rationale must not contain null bytes") if $rationale =~ /\0/;
        die_user("--rationale must not contain control/escape characters")
            if $rationale =~ /[\x01-\x08\x0b\x0c\x0e-\x1f\x7f]/;
    }
    if (defined $bin_dirs_raw) {
        # Shares bin_dirs_entry_problem() with validate_backpack (see that
        # sub's comment) for the content rules, PLUS the install-root
        # containment check (CRITICAL-1 fix, fix-batch step7): `add` is the
        # sanctioned authoring path, so this is where a hostile or mistaken
        # out-of-root directory gets stopped BEFORE it can ever be written
        # to the file at all -- closing the attack at its source rather than
        # only downstream at `install` time.
        my $root = install_root();
        for my $d (@$bin_dirs_raw) {
            my $problem = bin_dirs_entry_problem($d);
            die_user("--bin_dirs entry ($d): $problem") if defined $problem;
            die_user("--bin_dirs entry ($d): must be inside the backpack's install root ($root)")
                unless dir_within_root($d, $root);
        }
    }
    # Normalize category to lowercase so `apt` and `APT` aren't treated as
    # distinct keys by the (category,name) deduplication. The allowed-set is
    # all-lowercase by convention.
    $category = lc $category;
    unless ($ALLOWED_CATEGORY{$category}) {
        print STDERR "WARNING: category '$category' is not in the known set ("
            . join(",", @ALLOWED_CATEGORIES) . "). Continuing anyway.\n";
    }

    my $bp = load_backpack($path, create_if_missing => 1);
    my $items = $bp->{items};

    my $existing_idx;
    for my $i (0 .. $#$items) {
        my $t = $items->[$i];
        if ($t->{category} eq $category && $t->{name} eq $name) {
            $existing_idx = $i;
            last;
        }
    }

    my $entry = {
        category => $category,
        name     => $name,
        install  => $install,
        verify   => $verify,
    };
    $entry->{rationale} = $rationale if defined $rationale && $rationale ne '';
    # bin_dirs: given (even a single occurrence) -> replaces the entry's whole
    # array wholesale; omitted -> preserved on update, absent entirely on a
    # new entry (mirrors rationale's preserve-if-omitted pattern below).
    $entry->{bin_dirs} = $bin_dirs_raw if defined $bin_dirs_raw;

    if (defined $existing_idx) {
        # Update: preserve original added timestamp + preserve prior rationale
        # if the caller didn't supply one (don't blow away existing context).
        $entry->{added} = $items->[$existing_idx]{added} // today_iso();
        if (!defined $entry->{rationale} && defined $items->[$existing_idx]{rationale}) {
            $entry->{rationale} = $items->[$existing_idx]{rationale};
        }
        if (!defined $bin_dirs_raw && defined $items->[$existing_idx]{bin_dirs}) {
            $entry->{bin_dirs} = $items->[$existing_idx]{bin_dirs};
        }
        $items->[$existing_idx] = $entry;
        emit("STATUS", "updated");
    } else {
        $entry->{added} = today_iso();
        push @$items, $entry;
        emit("STATUS", "added");
    }

    write_json_atomic($path, $bp);
    emit("CATEGORY", $category);
    emit("NAME",     $name);
    emit("RATIONALE_SET", defined $entry->{rationale} && $entry->{rationale} ne '' ? "yes" : "no");
    emit("TOTAL",    scalar @$items);
}

sub cmd_remove {
    my $path = shift @ARGV or die_user("usage: remove <path> --category C --name N");
    my ($category, $name);
    GetOptionsFromArray(\@ARGV,
        'category=s' => \$category,
        'name=s'     => \$name,
    ) or die_user("invalid options for remove");

    die_user("--category is required") unless defined $category && $category ne '';
    die_user("--name is required")     unless defined $name     && $name ne '';
    # Normalize so `remove --category APT` matches an entry stored as `apt`.
    $category = lc $category;

    my $bp = load_backpack($path);
    my $items = $bp->{items};
    my $before = scalar @$items;

    @$items = grep {
        !($_->{category} eq $category && $_->{name} eq $name)
    } @$items;

    my $removed = $before - scalar @$items;
    if ($removed == 0) {
        emit("STATUS", "noop");
        emit("REASON", "no entry matched (category=$category, name=$name)");
        return;
    }

    write_json_atomic($path, $bp);
    emit("STATUS", "removed");
    emit("CATEGORY", $category);
    emit("NAME",     $name);
    emit("TOTAL",    scalar @$items);
}

sub cmd_install {
    my $path = shift @ARGV or die_user("usage: install <path> [--declared <declared-backpack-path>]");
    # --declared: the caller (normally launcher.pl) hands in the FULL declared
    # backpack alongside the (possibly pre-filtered) install-set at $path, so
    # this pass can reconcile against the declared total instead of the
    # structural INSTALLED+SKIPPED+FAILED==ITEMS identity computed from the
    # handed subset alone (which can never fail -- see backpack.pl's own
    # header comment history / the b01 spec). Omitting --declared reproduces
    # today's output byte-for-byte: every new line below is gated on it.
    my $declared_path;
    my $profile_path = '/etc/profile.d/backpack-path.sh';
    GetOptionsFromArray(\@ARGV,
        'declared=s'     => \$declared_path,
        'profile-path=s' => \$profile_path,
    ) or die_user("invalid options for install");

    my $bp = load_backpack($path);
    my $items = $bp->{items};

    my %by_label;
    for my $t (@$items) {
        $by_label{"$t->{category}:$t->{name}"} = $t;
    }

    # MINOR-1 fix: a missing/unparseable --declared file must NEVER abort the
    # whole install pass -- that would make the accounting layer itself a new
    # all-or-nothing gate of exactly the class the spec's root-cause section
    # warns about (launcher.pl's own abort gates that emit no per-item output
    # at all). Load it "soft": on any problem, print a loud WARNING, drop
    # back to the pre---declared behavior for this run (no DECLARED/ABSENT/
    # RECONCILE lines), and keep installing the handed subset as usual.
    my (@declared_items, %declared_by_label);
    if (defined $declared_path) {
        my $declared_bp = load_backpack($declared_path, soft => 1);
        if (!$declared_bp) {
            print STDERR "WARNING: --declared file unusable ($declared_path) -"
                . " reconciliation skipped, installing the handed set as usual\n";
            $declared_path = undef;
        } else {
            @declared_items = @{ $declared_bp->{items} };
            %declared_by_label = map { ("$_->{category}:$_->{name}" => $_) } @declared_items;
        }
    }

    # ── depends_on: dangling-reference check + topological ordering ───────
    #
    # A depends_on target can be in one of three states:
    #   * present in THIS install-set   -> a real local ordering constraint.
    #   * absent here but present in the DECLARED backpack (only meaningful
    #     with --declared) -> the dependency was silently dropped upstream
    #     (exactly the incident this package exists for). Not a hard error:
    #     the item still attempts to install (reproducing the real exit-127
    #     symptom), but it is tracked so the FAIL path can name the real
    #     cause instead of leaving the reader to guess.
    #   * absent everywhere -> a genuinely dangling reference. Loud, named,
    #     non-zero exit, BEFORE any install runs -- never a silent drop, never
    #     a hang.
    my %missing_deps_of;
    my @dangling;
    my %indegree;
    my %dependents;

    for my $t (@$items) {
        $indegree{"$t->{category}:$t->{name}"} = 0;
    }
    for my $t (@$items) {
        my $label = "$t->{category}:$t->{name}";
        for my $dep (@{ $t->{depends_on} // [] }) {
            if (exists $by_label{$dep}) {
                $indegree{$label}++;
                push @{ $dependents{$dep} }, $label;
            } elsif (defined $declared_path && exists $declared_by_label{$dep}) {
                push @{ $missing_deps_of{$label} }, $dep;
            } else {
                push @dangling, [$label, $dep];
            }
        }
    }

    if (@dangling) {
        for my $d (@dangling) {
            print STDERR "DANGLING: $d->[0] depends on $d->[1], which is not declared anywhere\n";
        }
        exit 1;
    }

    # Kahn's algorithm, stable on original file order among ties, so files
    # with no depends_on at all (or none yet resolved) install in exactly
    # today's file order (backward compatibility, criterion 7).
    my @queue = grep { $indegree{$_} == 0 } map { "$_->{category}:$_->{name}" } @$items;
    my @order;
    while (@queue) {
        my $label = shift @queue;
        push @order, $label;
        for my $dep_label (@{ $dependents{$label} // [] }) {
            $indegree{$dep_label}--;
            push @queue, $dep_label if $indegree{$dep_label} == 0;
        }
    }

    if (@order != @$items) {
        my @cyclic = grep { $indegree{$_} > 0 } map { "$_->{category}:$_->{name}" } @$items;
        print STDERR cycle_line(\@cyclic, "dependency cycle detected among: ");
        exit 1;
    }

    my @ordered_items = map { $by_label{$_} } @order;

    emit("PATH", $path);
    emit("DECLARED", scalar @declared_items) if defined $declared_path;
    emit("ITEMS", scalar @$items);

    # ── PATH: profile fragment + in-process PATH (b02, DC1/DC3) ───────────
    #
    # Aggregation source: the FULL declared backpack when --declared was
    # given (a previously installed item outside this run's subset still
    # needs its dir on PATH), otherwise the handed file (the common case for
    # a direct/manual `install` call).
    my $bin_dirs_source = defined $declared_path ? \@declared_items : $items;
    my $bp_install_root = install_root();
    my ($path_dirs_ref, $bin_dirs_rejected_ref) = aggregate_bin_dirs_filtered($bin_dirs_source, $bp_install_root);
    my @path_dirs = @$path_dirs_ref;
    my @bin_dirs_rejected = @$bin_dirs_rejected_ref;

    my $fragment = "# Managed by backpack.pl -- regenerated on every `install` pass. Do not edit by\n"
        . "# hand; edits are lost on the next install. Source of truth: bin_dirs on backpack\n"
        . "# items, plus a standing floor directory for tools with no declared bin_dirs.\n"
        . "export PATH=\"" . join(':', @path_dirs) . ":\$PATH\"\n";
    eval { write_text_atomic($profile_path, $fragment) };
    if ($@) {
        my $reason = $@;
        $reason =~ s/\s+$//;
        print STDERR "WARNING: could not write profile fragment ($profile_path): $reason\n";
    }
    emit("PROFILE_PATH", $profile_path);
    emit("PATHDIRS", scalar @path_dirs);

    # CRITICAL-1 fix (fix-batch step7): any bin_dirs entry outside the
    # backpack's own install root is excluded from the PERSISTENT fragment
    # above -- named here, per item, rather than silently dropped. This does
    # NOT abort the pass (MEDIUM fix) and does NOT affect the offending
    # item's OWN in-process PATH scope below (see item_bin_dirs / the
    # comment above install_root() for why that distinction is safe).
    emit("BIN_DIRS_REJECTED", scalar @bin_dirs_rejected);
    for my $r (@bin_dirs_rejected) {
        my ($rlabel, $rdir) = @$r;
        print "REJECTED: $rlabel bin_dirs entry '$rdir' is outside the install root"
            . " ($bp_install_root) -- excluded from the PATH profile fragment\n";
    }

    # NOTE: no global apply_path_env() call here (unlike the pre-fix-batch
    # shape). CRITICAL-2 fix: PATH is now set PER ITEM, inside the loop
    # below, scoped to that item's own bin_dirs only -- never the union of
    # every item in the file. A single shared aggregate PATH applied to
    # every item's verify was what let one item's bin_dirs binary make an
    # unrelated, never-installed item falsely report itself present
    # (redteam-step6 CRITICAL-2).

    # Every declared item that never made it into this install-set gets its
    # own loud disposition line -- the exact thing that was silently invisible
    # before this package (criterion 2). And the converse (BLOCKER-1 fix): an
    # item present in the install-set that was never declared anywhere also
    # gets its own loud line, not a silent SKIP/INSTALL -- a count-preserving
    # substitution (one declared item dropped, one undeclared item filling
    # its slot) must be visible on BOTH sides, not just missed on one.
    my (@absent, @extra);
    if (defined $declared_path) {
        for my $d (@declared_items) {
            my $label = "$d->{category}:$d->{name}";
            push @absent, $label unless exists $by_label{$label};
        }
        for my $label (@absent) {
            print "ABSENT: $label (declared, not in install-set)\n";
        }
        for my $t (@$items) {
            my $label = "$t->{category}:$t->{name}";
            push @extra, $label unless exists $declared_by_label{$label};
        }
        for my $label (@extra) {
            print "EXTRA: $label (in install-set, not declared)\n";
        }
    }

    my ($n_ok, $n_skipped, $n_installed, $n_failed) = (0, 0, 0, 0);

    for my $t (@ordered_items) {
        my $label = "$t->{category}:$t->{name}";

        # CRITICAL-2 fix: scope PATH to THIS item's own bin_dirs (plus the
        # floor) before running any of its commands -- never the union of
        # every item's bin_dirs. Set once per iteration; both verify calls
        # and the install call for this item see the same scope.
        apply_path_env_for_item($t);

        # Verify first: if already installed, skip.
        my $verify_rc = run_bash($t->{verify});
        if ($verify_rc == 0) {
            print "SKIP: $label (already present)\n";
            $n_skipped++;
            $n_ok++;
            next;
        }

        # Not present → install.
        print "INSTALL: $label\n";
        my $install_rc = run_bash($t->{install});
        if ($install_rc != 0) {
            print STDERR "FAIL: $label — install " . fmt_rc($install_rc) . "\n";
            print STDERR "      install: $t->{install}\n";
            for my $dep (@{ $missing_deps_of{$label} // [] }) {
                print STDERR "      missing dependency: $dep (declared, but absent from install-set — likely cause)\n";
            }
            $n_failed++;
            next;
        }

        # Confirm via verify.
        my $confirm_rc = run_bash($t->{verify});
        if ($confirm_rc == 0) {
            print "OK: $label\n";
            $n_installed++;
            $n_ok++;
        } else {
            # The verify command is usually self-silencing (e.g. `… 2>/dev/null |
            # grep -q …`), so its failure prints nothing of its own — leaving the
            # user with "something failed" and no "what". Echo the exact check that
            # failed so they can see and re-run it.
            print STDERR "FAIL: $label — verify after install " . fmt_rc($confirm_rc) . "\n";
            print STDERR "      verify: $t->{verify}\n";
            my $diag = diagnose_verify($t->{verify});
            if (length $diag) {
                print STDERR "      why (bash -x, last lines):\n";
                print STDERR "$diag\n";
            }
            for my $dep (@{ $missing_deps_of{$label} // [] }) {
                print STDERR "      missing dependency: $dep (declared, but absent from install-set — likely cause)\n";
            }
            $n_failed++;
        }
    }

    emit("INSTALLED", $n_installed);
    emit("SKIPPED",   $n_skipped);
    emit("FAILED",    $n_failed);

    # BLOCKER-1 fix: RECONCILE is derived from SET membership (@absent /
    # @extra, already computed above from the real declared/install-set
    # difference), never from raw item counts. A count-preserving
    # substitution (declared item dropped, undeclared item filling its slot)
    # used to leave declared==processed in COUNT while differing in CONTENT,
    # printing "RECONCILE: OK" in the same breath as an ABSENT/NOTICE line --
    # a direct, machine-visible self-contradiction. Set equality can't be
    # fooled that way: any absent or extra label makes it MISMATCH.
    my $reconcile_mismatch = 0;
    if (defined $declared_path) {
        my $n_absent = scalar @absent;
        if ($n_absent > 0) {
            # A PEER fact, not a footnote under any FAIL line -- un-indented,
            # column 0, so it reads with the same weight as any symptom above
            # it (criterion 5).
            printf "NOTICE: %d declared item%s never reached install\n",
                $n_absent, ($n_absent == 1 ? '' : 's');
        }
        $reconcile_mismatch = (@absent || @extra) ? 1 : 0;
        emit("RECONCILE", $reconcile_mismatch ? 'MISMATCH' : 'OK');
    }

    # BLOCKER-2 fix: a reconciliation MISMATCH must make the process exit
    # non-zero, with a status distinguishable from "an item's install/verify
    # command failed" -- otherwise launcher.pl (which only ever inspects the
    # raw exit code) can never learn a declared item was silently dropped,
    # and the original incident reproduces byte-for-byte through the
    # operator-facing signal even with the accounting logic above wired up.
    #   0  everything installed/skipped cleanly, and (if --declared) fully
    #      reconciled.
    #   1  at least one item's install or verify actually failed (unchanged
    #      from pre-existing behavior -- preserves the oracle's only exit-
    #      code assertion, the no---declared backward-compat case, byte for
    #      byte, since $reconcile_mismatch is always 0 there).
    #   2  every handed item installed/skipped fine (no FAILED), but
    #      reconciliation against --declared found a MISMATCH. A distinct
    #      code so a caller can tell "items themselves are fine, but the set
    #      you handed me wasn't what was declared" apart from a real
    #      install/verify failure.
    if ($n_failed != 0) {
        exit 1;
    } elsif ($reconcile_mismatch) {
        exit 2;
    } else {
        exit 0;
    }
}

sub cmd_deps {
    my $path = shift @ARGV or die_user("usage: deps <path> --note TEXT");
    my $note;
    GetOptionsFromArray(\@ARGV,
        'note=s' => \$note,
    ) or die_user("invalid options for deps");

    # --note is operator-supplied free text echoed straight to a terminal, the
    # same trust boundary as every field already sanitized (MINOR-2 fix: the
    # old code comment called this "deliberate" because launcher.pl never
    # drives this flag today -- "unreachable today" isn't a property to
    # depend on).
    if (defined $note && $note ne '') {
        my @note_issues;
        push_text_issues(\@note_issues, "--note", $note);
        die_user($note_issues[0][1]) if @note_issues;
    }

    my $bp = load_backpack($path);
    my $items = $bp->{items};

    # --note is the caller's explicit hand-off of whatever provenance
    # disclaimer applies (e.g. "this is a synthetic fixture, not a real
    # audit") -- backpack.pl has no way to know that fact about a file at
    # runtime, so it is echoed verbatim (now sanitized above) rather than
    # guessed at.
    print "NOTE: $note\n" if defined $note && $note ne '';

    emit("PATH", $path);
    emit("ITEMS", scalar @$items);

    my %by_label;
    my %index;
    for my $i (0 .. $#$items) {
        my $label = "$items->[$i]{category}:$items->[$i]{name}";
        $by_label{$label} = $items->[$i];
        $index{$label}    = $i;
    }

    # Cycle detection (MAJOR-1 fix): this table must not report a cycle
    # member as ordinary "load_bearing: no" -- that would give a reader zero
    # indication that `install` refuses to run on this exact file. Kahn's
    # algorithm restricted to in-file edges only (a dangling reference to an
    # item outside this file is a different, already-flagged condition, not
    # a cycle) mirrors cmd_install's own cycle check.
    my %indegree;
    my %dependents;
    for my $i (0 .. $#$items) {
        $indegree{"$items->[$i]{category}:$items->[$i]{name}"} = 0;
    }
    for my $i (0 .. $#$items) {
        my $t = $items->[$i];
        my $label = "$t->{category}:$t->{name}";
        for my $dep (@{ $t->{depends_on} // [] }) {
            next unless exists $by_label{$dep};
            $indegree{$label}++;
            push @{ $dependents{$dep} }, $label;
        }
    }
    my @queue = grep { $indegree{$_} == 0 } keys %indegree;
    my %visited;
    while (@queue) {
        my $l = shift @queue;
        $visited{$l} = 1;
        for my $dep_label (@{ $dependents{$l} // [] }) {
            $indegree{$dep_label}--;
            push @queue, $dep_label if $indegree{$dep_label} == 0;
        }
    }
    my %in_cycle = map { $_ => 1 } grep { !$visited{$_} } keys %indegree;

    if (%in_cycle) {
        my @cyclic = sort keys %in_cycle;
        print cycle_line(\@cyclic, "dependency cycle detected among: ");
    }

    print "\nDependency table:\n";
    for my $i (0 .. $#$items) {
        my $t = $items->[$i];
        my $label = "$t->{category}:$t->{name}";
        my @deps = @{ $t->{depends_on} // [] };
        my $deps_str = @deps ? join(', ', @deps) : '(none)';

        # "Load-bearing" (criterion 4's required artifact): this entry's
        # CURRENT position in the file matters -- either a declared
        # dependency sits later in the file (naive file-order install would
        # get it backwards without depends_on-aware ordering), or a declared
        # dependency isn't in this file at all (position can never fix that;
        # flagged so it isn't mistaken for "fine as-is"). A cycle member is
        # reported as CYCLE, not folded into yes/no -- `install` refuses to
        # run at all on this file, which is a stronger fact than "position
        # matters" and must not be silently downgraded to "no".
        my $lb_word;
        if ($in_cycle{$label}) {
            $lb_word = 'CYCLE';
        } else {
            my $load_bearing = 0;
            for my $dep (@deps) {
                if (!exists $by_label{$dep}) {
                    $load_bearing = 1;
                } elsif ($index{$dep} > $i) {
                    $load_bearing = 1;
                }
            }
            $lb_word = $load_bearing ? 'yes' : 'no';
        }
        print "  $label - depends_on: $deps_str - load_bearing: $lb_word\n";
    }
}

sub cmd_audit {
    my $path = shift @ARGV or die_user("usage: audit <path>");
    my $bp = load_backpack($path);
    my $items = $bp->{items};

    emit("PATH", $path);
    emit("ITEMS", scalar @$items);

    my ($n_ok, $n_no_rationale, $n_gone) = (0, 0, 0);
    my @lines;

    for my $t (@$items) {
        my $label = "$t->{category}:$t->{name}";
        my $has_rationale = defined $t->{rationale} && $t->{rationale} ne '';
        # CRITICAL-2 fix (fix-batch step7): PATH augmentation is now PER
        # ITEM, scoped to that item's own bin_dirs only (see item_bin_dirs) --
        # not a single aggregate applied to every item's verify. The old
        # global aggregate let one item's bin_dirs binary make an unrelated,
        # never-installed item falsely report itself present here too
        # (redteam-step6 CRITICAL-2, confirmed against cmd_audit
        # specifically: it reproduced "[v] ... verify ok" for a tool that
        # was never installed).
        apply_path_env_for_item($t);
        # Silence the verify command's stdout/stderr for audit — we only care
        # about the exit code. Done at the Perl level (not via a `{ cmd; }
        # >/dev/null` shell wrapper) so a literal `}` or `)` inside the verify
        # string can't break the wrapping shell parse.
        my $verify_rc = run_bash_silent($t->{verify});
        my $present = ($verify_rc == 0);

        my ($symbol, $verify_word, $rat_word);
        if (!$present) {
            $symbol = "x";
            $n_gone++;
        } elsif (!$has_rationale) {
            $symbol = "?";
            $n_no_rationale++;
        } else {
            $symbol = "v";
            $n_ok++;
        }
        $verify_word = $present ? "verify ok" : "verify FAILED";
        $rat_word    = $has_rationale ? "rationale: \"$t->{rationale}\"" : "rationale: (none)";
        push @lines, "  [$symbol] $label - $verify_word - $rat_word";
    }

    emit("OK",            $n_ok);
    emit("NO_RATIONALE",  $n_no_rationale);
    emit("GONE",          $n_gone);
    print "\nDetails:\n" if @lines;
    print "$_\n" for @lines;

    # Exit 0 always (this is a report, not a failure mode). Callers read the
    # NO_RATIONALE / GONE counts and react.
}

# Run a command through bash -c so install/verify entries can use pipes,
# redirects, env vars. Returns the exit code (0 = success).
#
# Sentinel values for non-normal termination so callers don't mistake a
# signal-killed process for a clean exit (Perl's system() raw status puts
# the signal in the low 7 bits and leaves the high 8 bits zero, so a naive
# `$rc >> 8` returns 0 for SIGKILL/SIGTERM):
#   -1  fork failed
#   -2  killed by signal
sub run_bash {
    my $cmd = shift;
    my $rc = system('bash', '-c', $cmd);
    return -1 if $rc == -1;
    return -2 if ($rc & 127);
    return $rc >> 8;
}

# Same as run_bash, but redirects the child's stdout+stderr to /dev/null
# (NUL on Windows) at the Perl level. Used by `audit` so verify commands
# can't pollute the audit summary, and so a literal `}` or `)` in the
# verify string can't break a shell-level wrapper.
sub run_bash_silent {
    my $cmd = shift;
    my $null = ($^O eq 'MSWin32') ? 'NUL' : '/dev/null';
    open(my $orig_out, '>&', \*STDOUT) or die "dup STDOUT: $!\n";
    open(my $orig_err, '>&', \*STDERR) or die "dup STDERR: $!\n";
    open(STDOUT, '>', $null)           or die "redirect STDOUT to $null: $!\n";
    open(STDERR, '>', $null)           or die "redirect STDERR to $null: $!\n";
    my $rc = system('bash', '-c', $cmd);
    open(STDOUT, '>&', $orig_out)      or die "restore STDOUT: $!\n";
    open(STDERR, '>&', $orig_err)      or die "restore STDERR: $!\n";
    close $orig_out;
    close $orig_err;
    return -1 if $rc == -1;
    return -2 if ($rc & 127);
    return $rc >> 8;
}

sub fmt_rc {
    my $rc = shift;
    return "fork failed"      if $rc == -1;
    return "killed by signal" if $rc == -2;
    return "exited $rc";
}

# diagnose_verify($cmd) -> a short, indented multi-line string showing WHY a
# verify failed. A verify is usually self-silencing (`… 2>/dev/null | grep -q …`),
# so the failure prints nothing of its own and the user is left with the command
# but no clue. Re-run it under `bash -x` with stderr merged into stdout: the
# xtrace exposes the failing pipeline (e.g. a `head -1 | grep` that a tool's
# first-run banner defeats) and any tool output that slips past the suppression.
# Bounded to the last few lines. Read-only: verifies are existence/version checks,
# safe to run twice. Runs in-container (Linux), where fork-pipe + bash -x exist.
sub diagnose_verify {
    my ($cmd) = @_;
    my $max_lines = 12;
    my $max_cols  = 200;
    my $pid = open(my $fh, '-|');
    return '' unless defined $pid;
    if ($pid == 0) {
        open(STDIN,  '<', '/dev/null');   # a verify that reads stdin gets EOF, not a hang
        open(STDERR, '>&', \*STDOUT);     # merge the xtrace (stderr) into the pipe
        exec('bash', '-xc', $cmd);        # $cmd as a literal arg — no shell-quoting
        CORE::exit(127);
    }
    # Hard cap: a pathological verify must never wedge the install run. On timeout
    # kill the child and salvage nothing (the verify command itself is still shown).
    my @lines;
    eval {
        local $SIG{ALRM} = sub { die "diag-timeout\n" };
        alarm 15;
        @lines = <$fh>;
        alarm 0;
    };
    alarm 0;
    if ($@) { kill 'KILL', $pid; }
    close $fh;
    waitpid($pid, 0);
    @lines = @lines[-$max_lines .. -1] if @lines > $max_lines;
    my @out;
    for my $ln (@lines) {
        chomp $ln;
        $ln = substr($ln, 0, $max_cols) . '...' if length($ln) > $max_cols;
        push @out, "        $ln";
    }
    return @out ? join("\n", @out) : '';
}

sub cmd_help {
    print <<'EOF';
backpack.pl — what you packed for the /sandbox container

Subcommands:
  validate <path>                                          Schema-check the file.
  list <path>                                              Pretty-print the contents.
  add <path> --category C --name N --install I --verify V [--rationale R]
                                                           Add or update entry.
  remove <path> --category C --name N                     Drop an entry.
  install <path> [--declared <declared-path>]              Run verify; install if missing.
  audit <path>                                             Per-item: verify status + rationale check.
  deps <path> --note TEXT                                  Dependency/ordering audit table.
  help                                                     This message.

Schema version: 2
Allowed categories: apt npm-global pip cargo gem go-install curl-script snap project-setup other
EOF
}
