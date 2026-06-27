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
#   install <path>                                           Run verify; if it fails, run install. Reports status per item.
#   audit <path>                                             Audit each item: runs verify (no install) + checks rationale.
#   help                                                     Show usage.
#
# Schema (backpack v2):
#   { "version": 2, "items": [ {
#       "category": "apt|npm-global|pip|cargo|gem|go-install|curl-script|snap|project-setup|other",
#       "name":      "<non-empty string, no newline>",
#       "install":   "<shell command, no newline>",
#       "verify":    "<shell command, no newline>",
#       "rationale": "<optional, free-text 'why this is in the backpack'>",
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

my $cmd = shift @ARGV // "help";

if    ($cmd eq "validate") { cmd_validate() }
elsif ($cmd eq "list")     { cmd_list()     }
elsif ($cmd eq "add")      { cmd_add()      }
elsif ($cmd eq "remove")   { cmd_remove()   }
elsif ($cmd eq "install")  { cmd_install()  }
elsif ($cmd eq "audit")    { cmd_audit()    }
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

# Load the backpack file. Missing file → return a fresh empty backpack. Malformed
# JSON or wrong schema version → die. `add` against a missing file should create
# one, but a corrupted file should never be silently overwritten.
#
# Per-entry validation (via validate_backpack) runs by default — `add` / `remove`
# / `install` / `list` all need a fully valid file to operate safely. Pass
# skip_full_validate => 1 from cmd_validate, which does its own richer reporting.
sub load_backpack {
    my ($path, %opts) = @_;
    if (!-f $path) {
        return { version => $SCHEMA_VERSION, items => [] } if $opts{create_if_missing};
        die_user("backpack file not found: $path");
    }
    my $data = read_json($path);
    die_user("backpack file is not valid JSON: $path") unless defined $data;
    die_user("backpack file is not an object: $path") unless ref $data eq 'HASH';
    my $v = $data->{version} // 0;
    if ($v == 1) {
        die_user("backpack file is on legacy schema v1 (uses 'tools' key): $path. "
            . "Rename top-level 'tools' to 'items' and bump 'version' to 2, then re-run.");
    }
    die_user("backpack schema version mismatch: expected $SCHEMA_VERSION, got $v ($path)")
        unless $v == $SCHEMA_VERSION;
    die_user("backpack 'items' is not an array: $path")
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
        print STDERR "ERROR: backpack file is invalid: $path\n";
        for my $e (@errors) { print STDERR "  - $e->[1]\n"; }
        exit 1;
    }
    return $data;
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
            push @issues, ['error', "items[$i].$f: must be a string"]
                if ref $val;
            push @issues, ['error', "items[$i].$f: must not contain newlines"]
                if defined $val && !ref $val && $val =~ /[\r\n]/;
            # Null-byte check: bash -c may truncate at \0 on some libc
            # implementations, executing only the prefix while the user sees
            # the full string in the list display. Reject at validation time.
            push @issues, ['error', "items[$i].$f: must not contain null bytes"]
                if defined $val && !ref $val && $val =~ /\0/;
            # Control/escape chars (e.g. ESC 0x1b) are rejected so a hostile
            # backpack can't emit terminal cursor/clear sequences during the
            # launcher's per-item approval review to spoof a benign-looking
            # command (the AS-ROOT install gate, #21 red-team). Tab is allowed.
            push @issues, ['error', "items[$i].$f: must not contain control/escape characters"]
                if defined $val && !ref $val && $val =~ /[\x01-\x08\x0b\x0c\x0e-\x1f\x7f]/;
        }
        # Optional rationale: when present, must be a non-ref non-newline string.
        if (defined $t->{rationale}) {
            push @issues, ['error', "items[$i].rationale: must be a string"]
                if ref $t->{rationale};
            push @issues, ['error', "items[$i].rationale: must not contain newlines"]
                if !ref $t->{rationale} && $t->{rationale} =~ /[\r\n]/;
            push @issues, ['error', "items[$i].rationale: must not contain null bytes"]
                if !ref $t->{rationale} && $t->{rationale} =~ /\0/;
            push @issues, ['error', "items[$i].rationale: must not contain control/escape characters"]
                if !ref $t->{rationale} && $t->{rationale} =~ /[\x01-\x08\x0b\x0c\x0e-\x1f\x7f]/;
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
    my ($category, $name, $install, $verify, $rationale);
    GetOptionsFromArray(\@ARGV,
        'category=s'  => \$category,
        'name=s'      => \$name,
        'install=s'   => \$install,
        'verify=s'    => \$verify,
        'rationale=s' => \$rationale,
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

    if (defined $existing_idx) {
        # Update: preserve original added timestamp + preserve prior rationale
        # if the caller didn't supply one (don't blow away existing context).
        $entry->{added} = $items->[$existing_idx]{added} // today_iso();
        if (!defined $entry->{rationale} && defined $items->[$existing_idx]{rationale}) {
            $entry->{rationale} = $items->[$existing_idx]{rationale};
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
    my $path = shift @ARGV or die_user("usage: install <path>");
    my $bp = load_backpack($path);
    my $items = $bp->{items};

    emit("PATH", $path);
    emit("ITEMS", scalar @$items);

    my ($n_ok, $n_skipped, $n_installed, $n_failed) = (0, 0, 0, 0);

    for my $t (@$items) {
        my $label = "$t->{category}:$t->{name}";

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
            $n_failed++;
        }
    }

    emit("INSTALLED", $n_installed);
    emit("SKIPPED",   $n_skipped);
    emit("FAILED",    $n_failed);
    exit ($n_failed == 0 ? 0 : 1);
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
        open(STDERR, '>&', \*STDOUT);     # merge the xtrace (stderr) into the pipe
        exec('bash', '-xc', $cmd);        # $cmd as a literal arg — no shell-quoting
        CORE::exit(127);
    }
    my @lines = <$fh>;
    close $fh;
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
  install <path>                                           Run verify; install if missing.
  audit <path>                                             Per-item: verify status + rationale check.
  help                                                     This message.

Schema version: 2
Allowed categories: apt npm-global pip cargo gem go-install curl-script snap project-setup other
EOF
}
