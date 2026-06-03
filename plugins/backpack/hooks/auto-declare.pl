#!/usr/bin/env perl
# auto-declare.pl — PostToolUse hook on Bash that nudges the agent to record
# install-shape commands in the backpack.
#
# Wired up in plugins/sandbox/container/settings.json under hooks.PostToolUse with
# matcher "Bash", so it fires after every successful Bash tool invocation
# inside the sandbox. PostToolUse fires only on success — failed installs
# go to PostToolUseFailure and aren't proposed.
#
# Behavior (design choice C — "ask, don't auto-add"):
#   The hook never writes to backpack.json. It parses the executed Bash
#   command, identifies items that look like installs and aren't already in
#   the backpack, and emits an `additionalContext` payload that prompts the
#   agent on its next turn with pre-filled /backpack:add invocations. The
#   agent decides whether to actually record each item (filling in the
#   rationale) or skip it as a one-off.
#
# Why "ask, don't auto-add": some installs are throwaway (agent runs `jq`
# once to inspect a JSON, no intent to persist). Auto-adding would pollute
# the backpack with one-offs that the user has to clean up later. With the
# ask flow, the worst case is the agent installs it again on the next
# rebuild and gets prompted again — cheap, deterministic, no pollution.
#
# Reads JSON from stdin (per Claude Code hook contract):
#   { "tool_name": "Bash", "tool_input": { "command": "<cmd>" }, ... }
#
# Recognized install shapes (other commands fall through silently):
#   apt-get install [-y] [-q] [--no-install-recommends] [--] pkg1 pkg2 ...
#   apt install [-y] ...
#   npm install -g pkg[@ver] [pkg2 ...]
#   npm i -g pkg ...
#   pnpm add -g pkg
#   yarn global add pkg
#   pip install pkg[==ver] ...    (skipped when -r/-e/-c/--requirement points at a file)
#   pip3 install ...
#   python -m pip install ...
#   cargo install pkg[@ver]       (also handles --version ver pkg)
#
# Leading `sudo` is stripped — installs inside the sandbox don't need it,
# and we want the recorded command to match what'll replay (always as root).
#
# Already-tracked (category, name) pairs are filtered out before prompting,
# so re-installing something the agent already declared is silent.
#
# Path resolution:
#   BACKPACK_FILE (env)  defaults to $HOME/.claude/backpack.json
#
# Always exits 0 — hook failures must not disrupt Claude's flow.

use strict;
use warnings;
use JSON::PP;

my $BACKPACK_FILE = $ENV{BACKPACK_FILE} // "$ENV{HOME}/.claude/backpack.json";

# Slurp the hook payload from stdin. Empty / malformed → exit 0 silently.
my $payload = do { local $/; <STDIN> };
exit 0 unless defined $payload && length $payload;

my $data = eval { decode_json($payload) };
exit 0 unless $data && ref $data eq 'HASH';
exit 0 unless ($data->{tool_name} // '') eq 'Bash';
# Guard against schema-valid-but-shape-wrong payloads: if tool_input isn't a
# hash ref, the next `->{}` dereference would throw a fatal "Can't use string
# as a HASH ref" under `use strict`, and the hook would exit non-zero — exactly
# the disruption to Claude the contract forbids.
exit 0 unless ref($data->{tool_input}) eq 'HASH';

my $command = $data->{tool_input}{command} // '';
exit 0 unless length $command;
# `sudo` is stripped per-segment inside install_segments — not at the top
# level. The top-level strip would miss `cmd1 && sudo cmd2` shapes where
# sudo only precedes a later segment.

my @declarations;
push @declarations, parse_apt($command);
push @declarations, parse_npm_global($command);
push @declarations, parse_pnpm_global($command);
push @declarations, parse_yarn_global($command);
push @declarations, parse_pip($command);
push @declarations, parse_cargo($command);

exit 0 unless @declarations;

# Defense in depth: drop tokens that don't look like real package names
# (apt/npm/pip/cargo names never contain shell metacharacters). If a parser
# misfired or someone tried to sneak metachars in, refuse to surface it.
@declarations = grep {
    if ($_->{name} =~ m{^[\@a-zA-Z0-9][a-zA-Z0-9._/+\-]*$}) {
        1;
    } else {
        warn "auto-declare: skipping suspicious name '$_->{name}' (not a valid package name)\n";
        0;
    }
} @declarations;
exit 0 unless @declarations;

# Filter out items already in the backpack — re-installing a tracked item
# shouldn't re-prompt. If reading the backpack fails (missing, malformed),
# treat all proposals as new; better noisy than silent.
my %tracked = load_tracked_keys($BACKPACK_FILE);
@declarations = grep {
    !$tracked{"$_->{category}\0$_->{name}"}
} @declarations;
exit 0 unless @declarations;

# Emit the proposal as additionalContext. The agent sees this on its next
# turn and decides whether to fire each /backpack:add or skip.
print encode_json({
    hookSpecificOutput => {
        hookEventName     => "PostToolUse",
        additionalContext => build_proposal(\@declarations),
    },
});

exit 0;

# ── Helpers ─────────────────────────────────────────────────────────

# Returns a set (hash) of "<category>\0<name>" keys for everything in the
# backpack file. Returns an empty set on any read/parse failure — that
# guarantees the proposal flow continues even if the backpack is in an odd
# state.
sub load_tracked_keys {
    my $path = shift;
    return () unless -f $path;
    open my $fh, '<:raw', $path or return ();
    local $/;
    my $content = <$fh>;
    close $fh;
    my $data = eval { decode_json($content) };
    return () unless $data && ref $data eq 'HASH' && ref $data->{items} eq 'ARRAY';
    my %keys;
    for my $it (@{$data->{items}}) {
        next unless ref $it eq 'HASH';
        next unless defined $it->{category} && defined $it->{name};
        $keys{"$it->{category}\0$it->{name}"} = 1;
    }
    return %keys;
}

# Build the additionalContext string. One pre-filled /backpack:add invocation
# per proposed item, with a <WHY> placeholder for the rationale. Strings
# embedded in the invocation are single-quoted; internal single quotes are
# escaped via the standard '\'' trick so the agent can copy-paste safely.
sub build_proposal {
    my $decls = shift;
    my $n = scalar @$decls;
    my $plural = $n == 1 ? "item" : "items";
    my $msg = "[backpack] Detected $n install-shape $plural in that Bash call that aren't tracked yet. "
            . "Decide whether each should persist to the next container rebuild. To track an item, run its pre-filled "
            . "/backpack:add with a real rationale; skip any that were one-offs (you'll be prompted again if you install them again later).\n\n";
    for my $d (@$decls) {
        my $line = "  /backpack:add --category " . shesc($d->{category})
                 . " --name "    . shesc($d->{name})
                 . " --install " . shesc($d->{install})
                 . " --verify "  . shesc($d->{verify});
        $line .= " --version " . shesc($d->{version}) if defined $d->{version};
        $line .= " --rationale '<WHY: one line — what this is for, why this version>'";
        $msg .= "$line\n";
    }
    return $msg;
}

# Single-quote a value for safe shell embedding: wrap in '…' and escape
# internal single quotes as '\''.
sub shesc {
    my $s = shift;
    $s =~ s/'/'\\''/g;
    return "'$s'";
}

# Split a compound command (`A && B; C`) into segments, then run a regex
# anchored at segment start. Returns a list of matched install-command substrings.
# Per-segment sudo strip handles `cmd1 && sudo cmd2` shapes — the top-level
# strip in the caller doesn't see the inner `sudo`.
sub install_segments {
    my ($cmd, $head_pattern) = @_;
    my @segments = split /\s*(?:&&|\|\||;)\s*/, $cmd;
    my @hits;
    for my $seg (@segments) {
        $seg =~ s/^\s+//; $seg =~ s/\s+$//;
        $seg =~ s/^sudo(?:\s+-[a-zA-Z]+)*\s+//;
        push @hits, $seg if $seg =~ /^$head_pattern\b/;
    }
    return @hits;
}

# ── Parsers ─────────────────────────────────────────────────────────

sub parse_apt {
    my $cmd = shift;
    my @results;
    # Both `apt-get install` and `apt install`.
    for my $seg (install_segments($cmd, qr/(?:apt(?:-get)?\s+install)/)) {
        my @tokens = split /\s+/, $seg;
        # Drop the leading `apt-get install` or `apt install`.
        shift @tokens;  # apt or apt-get
        shift @tokens;  # install
        for my $tok (@tokens) {
            next if $tok =~ /^-/;       # flags
            next if $tok eq '--';
            # apt accepts `pkg=version`. Strip for the name; keep the raw form
            # for the install command so a re-run pins the same version.
            (my $name = $tok) =~ s/=.*//;
            next unless length $name;
            my $version;
            $version = $1 if $tok =~ /=(.+)$/;
            push @results, {
                category => 'apt',
                name     => $name,
                install  => "apt-get install -y $tok",
                verify   => "dpkg -s $name >/dev/null 2>&1",
                (defined $version ? (version => $version) : ()),
            };
        }
    }
    return @results;
}

sub parse_npm_global {
    my $cmd = shift;
    my @results;
    # `npm install -g …` or `npm i -g …` or `npm install --global …`.
    for my $seg (install_segments($cmd, qr/npm\s+(?:install|i)/)) {
        next unless $seg =~ /\s(?:-g|--global)(?:\s|$)/;
        my @tokens = split /\s+/, $seg;
        shift @tokens;  # npm
        shift @tokens;  # install or i
        for my $tok (@tokens) {
            next if $tok =~ /^-/;
            next if $tok eq '--';
            my ($name, $version) = npm_split($tok);
            next unless defined $name;
            push @results, {
                category => 'npm-global',
                name     => $name,
                install  => "npm install -g $tok",
                # Two-stage verify: prefer the CLI shim test (works for tools
                # like firebase-tools, prettier) and fall back to a package-
                # directory check (works for libraries with no shim).
                # `npm list -g --depth=0 X` is unreliable: it exits 1 on peer-
                # dep warnings even when X is installed.
                verify   => "command -v $name >/dev/null 2>&1 || test -d \"\$(npm root -g 2>/dev/null)/$name\"",
                (defined $version ? (version => $version) : ()),
            };
        }
    }
    return @results;
}

sub parse_pnpm_global {
    my $cmd = shift;
    my @results;
    # `pnpm add -g pkg` (or `--global`).
    for my $seg (install_segments($cmd, qr/pnpm\s+(?:add|install|i)/)) {
        next unless $seg =~ /\s(?:-g|--global)(?:\s|$)/;
        my @tokens = split /\s+/, $seg;
        shift @tokens;  # pnpm
        shift @tokens;  # add/install/i
        for my $tok (@tokens) {
            next if $tok =~ /^-/;
            next if $tok eq '--';
            my ($name, $version) = npm_split($tok);
            next unless defined $name;
            push @results, {
                category => 'npm-global',
                name     => $name,
                install  => "pnpm add -g $tok",
                # CLI-shim test plus package-dir fallback (same rationale as
                # the npm verify above).
                verify   => "command -v $name >/dev/null 2>&1 || test -d \"\$(pnpm root -g 2>/dev/null)/$name\"",
                (defined $version ? (version => $version) : ()),
            };
        }
    }
    return @results;
}

sub parse_yarn_global {
    my $cmd = shift;
    my @results;
    # `yarn global add pkg`.
    for my $seg (install_segments($cmd, qr/yarn\s+global\s+add/)) {
        my @tokens = split /\s+/, $seg;
        shift @tokens;  # yarn
        shift @tokens;  # global
        shift @tokens;  # add
        for my $tok (@tokens) {
            next if $tok =~ /^-/;
            next if $tok eq '--';
            my ($name, $version) = npm_split($tok);
            next unless defined $name;
            push @results, {
                category => 'npm-global',
                name     => $name,
                install  => "yarn global add $tok",
                # CLI-shim test plus package-dir fallback. yarn global stores
                # packages under `yarn global dir`/node_modules/.
                verify   => "command -v $name >/dev/null 2>&1 || test -d \"\$(yarn global dir 2>/dev/null)/node_modules/$name\"",
                (defined $version ? (version => $version) : ()),
            };
        }
    }
    return @results;
}

# Split an npm package specifier into (name, optional version).
# Handles scoped packages: `@scope/pkg`, `@scope/pkg@1.0`, `pkg`, `pkg@1.0`.
# Returns (undef, undef) if the token is malformed.
sub npm_split {
    my $tok = shift;
    if ($tok =~ m{^(@[^/]+/[^@]+)(?:@(.+))?$}) {
        return ($1, $2);
    }
    if ($tok =~ /^([^@]+)(?:@(.+))?$/) {
        return ($1, $2);
    }
    return (undef, undef);
}

sub parse_pip {
    my $cmd = shift;
    my @results;
    # pip3 / pip / `python[3] -m pip` followed by `install`.
    for my $seg (install_segments($cmd, qr/(?:pip3?|python3?\s+-m\s+pip)\s+install/)) {
        # Skip file-driven installs (requirements files, editable, constraint files).
        next if $seg =~ /(?:^|\s)(?:-r|--requirement|-e|--editable|-c|--constraint)(?:\s|=)/;
        # Capture the actual invocation prefix so the install/verify recorded
        # in the backpack reproduces the same shape the agent used. Falling
        # back to `pip install ...` when the agent used `python3 -m pip install`
        # would silently break replay on containers that only have python3.
        my ($tool) = $seg =~ /^(pip3?|python3?\s+-m\s+pip)/;
        $tool //= 'pip';  # head pattern matched, so this branch shouldn't fire
        my @tokens = split /\s+/, $seg;
        my $i = 0;
        $i++ until $i >= @tokens || $tokens[$i] eq 'install';
        $i++;  # skip 'install'
        for my $j ($i .. $#tokens) {
            my $tok = $tokens[$j];
            next if $tok =~ /^-/;
            next if $tok eq '--';
            # Strip version operators: ==, >=, <=, !=, ~=, <, >.
            (my $name = $tok) =~ s/[=<>!~].*//;
            next unless length $name;
            my $version;
            $version = $1 if $tok =~ /==(.+)$/;
            push @results, {
                category => 'pip',
                name     => $name,
                install  => "$tool install $tok",
                verify   => "$tool show $name >/dev/null 2>&1",
                (defined $version ? (version => $version) : ()),
            };
        }
    }
    return @results;
}

sub parse_cargo {
    my $cmd = shift;
    my @results;
    for my $seg (install_segments($cmd, qr/cargo\s+install/)) {
        my @tokens = split /\s+/, $seg;
        shift @tokens;  # cargo
        shift @tokens;  # install
        my $explicit_version;
        my @pkgs;
        my $next_is_version = 0;
        for my $tok (@tokens) {
            if ($next_is_version) { $explicit_version = $tok; $next_is_version = 0; next; }
            if ($tok eq '--version') { $next_is_version = 1; next; }
            next if $tok =~ /^-/;
            next if $tok eq '--';
            push @pkgs, $tok;
        }
        for my $pkg (@pkgs) {
            my ($name, $name_version);
            if ($pkg =~ /^([^@]+)@(.+)$/) {
                $name = $1;
                $name_version = $2;
            } else {
                $name = $pkg;
            }
            my $version = $name_version // $explicit_version;
            my $install = "cargo install $pkg";
            $install .= " --version $explicit_version" if defined $explicit_version && !defined $name_version;
            push @results, {
                category => 'cargo',
                name     => $name,
                install  => $install,
                verify   => "cargo install --list 2>/dev/null | grep -q '^$name '",
                (defined $version ? (version => $version) : ()),
            };
        }
    }
    return @results;
}
