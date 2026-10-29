#!/usr/bin/env perl
# install.pl — ccpraxis top-level install orchestrator.
#
# Discovers every per-surface `ccpraxis-install.pl` in the repo, runs each
# in "plan" mode by default to print what would change, and asks the caller
# to re-run with --confirm to actually apply.
#
# Discovery roots:
#   - plugins/<name>/ccpraxis-install.pl         (each local plugin — including the sandbox launcher under plugins/sandbox/)
#   - skills/<name>/ccpraxis-install.pl          (each skill that needs install)
#
# Flags:
#   --confirm        Apply the plan (otherwise: print plan + guidance and exit)
#   -h, --help       Show this help
#
# Behavior detection:
#   When $ENV{CLAUDECODE} is set (Claude Code is running), the post-plan
#   guidance is tailored to Claude — it tells Claude to review the changes
#   WITH the user before re-running with --confirm.

use strict;
use warnings;
use FindBin qw($Bin);
# No `use utf8;` — literal bytes in the source (e.g. the em-dash) get
# written straight to a :raw stdout, which is what we want for a UTF-8
# console.

# Use raw byte mode — paths (UTF-8 bytes from Git Bash) flow through
# unchanged. A :utf8 layer would double-encode the bytes we'd print.
binmode STDOUT, ':raw';
binmode STDERR, ':raw';

my $confirm = 0;
my $help    = 0;
for my $arg (@ARGV) {
    if    ($arg eq '--confirm')          { $confirm = 1 }
    elsif ($arg eq '-h' || $arg eq '--help') { $help = 1 }
    else {
        print STDERR "install.pl: unknown argument: $arg\n";
        print STDERR "Try `perl install.pl --help`.\n";
        exit 1;
    }
}

if ($help) {
    print <<'EOH';
Usage: perl install.pl [--confirm]

First run prints the plan (what each install hook would do) and exits.
Re-run with --confirm to actually apply.

Each install hook is idempotent — re-runs are safe no-ops if everything
is already wired.
EOH
    exit 0;
}

my $CCPRAXIS_DIR = $Bin;
my $IS_CLAUDE    = $ENV{CLAUDECODE} ? 1 : 0;

# ── Discover hooks (deterministic order) ──────────────────────────
# The sandbox plugin (plugins/sandbox/ccpraxis-install.pl) is picked up by
# the plugins/* glob below — no explicit entry required. If you add a new
# standalone surface at the repo root, list it explicitly here.
my @scripts;

for my $dir (sort glob("$CCPRAXIS_DIR/plugins/*")) {
    next unless -d $dir;
    my $hook = "$dir/ccpraxis-install.pl";
    push @scripts, $hook if -f $hook;
}

for my $dir (sort glob("$CCPRAXIS_DIR/skills/*")) {
    next unless -d $dir;
    my $hook = "$dir/ccpraxis-install.pl";
    push @scripts, $hook if -f $hook;
}

# Standalone root surface (not a plugin/skill): the host-tools hook that puts
# `perl` on the user's PATH. Listed explicitly per the discovery note above.
{
    my $hook = "$CCPRAXIS_DIR/host-tools/ccpraxis-install.pl";
    push @scripts, $hook if -f $hook;
}

unless (@scripts) {
    print "No ccpraxis-install.pl hooks found under $CCPRAXIS_DIR.\n";
    exit 0;
}

# ── Run each hook (plan or apply) ─────────────────────────────────
my $mode = $confirm ? 'apply' : 'plan';

print "\n";
print $confirm
    ? "Applying ccpraxis install hooks:\n"
    : "ccpraxis install — PLAN (no changes will be made yet):\n";
print "\n";

my $i = 0;
for my $script (@scripts) {
    $i++;
    my $rel = $script;
    $rel =~ s|^\Q$CCPRAXIS_DIR\E/?||;

    my $desc = hook_description($script);
    printf "%d. %s\n", $i, $rel;
    print  "   $desc\n" if length $desc;

    my $rc = system($^X, $script, $mode);
    if ($rc != 0) {
        my $exit = $rc >> 8;
        warn "   (hook exited $exit)\n";
    }
    print "\n";
}

# ── Trailing guidance ─────────────────────────────────────────────
if ($confirm) {
    print "All install hooks complete. Open a new terminal for PATH changes to take effect.\n";
    exit 0;
}

if ($IS_CLAUDE) {
    print <<'EOC';
=== Guidance for Claude ===

The plan above lists every change this install would make to the user's
environment. NO changes have been made yet.

Before re-running with --confirm:
  1. Summarize the plan to the user in plain language (which directories
     would be added to PATH, whether PATHEXT would be touched on Windows).
  2. Call out anything the user might not recognize — especially install
     hooks from plugins they didn't author themselves.
  3. Ask for the user's explicit consent.

Only after the user clearly agrees, re-run:

    perl install.pl --confirm
EOC
} else {
    print <<'EOH';
The plan above lists every change this install would make to your
environment. NO changes have been made yet.

Before continuing:
  - Inspect each `ccpraxis-install.pl` path above if you don't recognize one
    (`cat <path>` is plenty — they're tiny shims that exec the shared helper).
  - On Windows, the changes touch only User-scope PATH and PATHEXT (no admin).
  - On Linux/macOS, the only file modified outside the repo is your shell rc.

To apply, re-run:

    perl install.pl --confirm
EOH
}

exit 0;

# ── Helpers ───────────────────────────────────────────────────────
# Pull a one-line description from each hook (second comment line — the
# first is conventionally "ccpraxis-install.pl — <surface> install hook").
sub hook_description {
    my $path = shift;
    open my $fh, '<', $path or return '';
    my $count = 0;
    while (my $line = <$fh>) {
        chomp $line;
        next if $line =~ /^#!/;
        if ($line =~ /^\s*#\s?(.*)$/) {
            $count++;
            if ($count == 2) {
                close $fh;
                return $1;
            }
        } elsif ($line =~ /\S/) {
            last;
        }
    }
    close $fh;
    return '';
}
