#!/usr/bin/env perl
# auto-declare.pl — the backpack's Bash hook inside the sandbox container.
# Proposes /backpack:add after installs, and keeps Node.js and pnpm on their one
# sanctioned path, the node-pnpm recipe.
#
# Registered only in plugins/sandbox/container/settings.json, so the host never
# runs it. It is registered on three events, each with matcher "Bash" and the
# same command line; the payload's hook_event_name picks the handler:
#
#   PostToolUse         after a command succeeded: propose a pre-filled
#                       /backpack:add for each install it recognises.
#   PreToolUse          before a command runs: refuse an ad-hoc install of
#                       Node.js or pnpm, and name the recipe.
#   PostToolUseFailure  after a command failed because node, npm, npx, pnpm or
#                       corepack is missing: name the recipe, at the moment the
#                       agent finds out it needs Node.
#
# One file for all three because they share one rule. Whether a command puts a
# Node or pnpm in place outside the recipe is decided by node_violation() alone:
# the guard refuses what it flags, the proposal flow never proposes it (and
# proposes the recipe instead), and the failure hint names the same recipe.
# The launcher bind-mounts this file on its own at /root/.claude/auto-declare.pl
# (launcher.pl, "Backpack plugin mounts"), so it cannot load a sibling module;
# its name predates the guard. A container that still has an older
# settings.json, registering PostToolUse only, runs this file safely: the other
# two handlers simply never fire there.
#
# Cost. PreToolUse and PostToolUse run on every Bash call. Before JSON::PP is
# loaded, each looks in the raw payload's command for a word it could act on
# and exits at once when there is none, so an ordinary command costs one bare
# perl start. PostToolUseFailure runs only when a command failed.
#
# Always exits 0. A refusal is a PreToolUse JSON decision on stdout, never an
# exit code: the registration ends in `|| true`, which would swallow one.
#
# ── The Node rule (node_violation) ──────────────────────────────────────
#
# The recipe (plugins/backpack/recipes/node-pnpm.json) installs an exact Node
# LTS and pnpm, each tarball checked against a pinned sha256, under
# /opt/tools/node, whose bin directory is on the image PATH; the backpack
# replays it on every rebuild. Refused, each because it puts a Node or a pnpm
# into the container that is not that one:
#
#   apt / apt-get / aptitude install nodejs | npm | node (not -s, a simulation)
#       Debian bookworm's Node is 18, end of life, and nothing records it.
#   apt install ./nodejs_*.deb, dpkg -i nodejs_*.deb
#       a hand-fetched package: no pins, no checksum, no rebuild restores it.
#   nvm install; n lts|latest|<version>|auto; fnm install; volta install|fetch|pin;
#   nodenv install; asdf install|plugin add ... nodejs; mise|rtx install|use
#   node (or pnpm); nodeenv without --node=system; pip install nodejs-bin
#       version managers and Node-bundling packages: an unpinned, unverified
#       Node that no rebuild restores.
#   curl | wget | git clone of the nvm, n, nodenv, fnm or volta installer itself
#   (nvm-sh/nvm/<ref>/install.sh, a clone of the nvm, n or nodenv repository,
#   fnm.vercel.app/install, get.volta.sh, ...)
#       the same thing, one step earlier. A README, a release API or an
#       issue page of those projects stays readable.
#   curl | wget of deb.nodesource.com/setup_* (or rpm.)
#       a third-party apt repository, set up by a root curl|bash.
#   curl | wget of a Node archive in nodejs.org/dist/<version>/ (also
#   /download/…): node-v<version>-<platform>.tar.xz and kin, or `$T`
#       a Node unpacked by hand. The rest stays readable: index.json and
#       SHASUMS256.txt (pinning a recipe needs them), signatures, the headers
#       tarball node-gyp fetches, the docs, and any curl -I / wget --spider.
#   corepack enable|prepare|install|use|up|pnpm|… while the recipe's Node is
#   absent
#       corepack is part of the recipe's Node; one from elsewhere is not.
#   corepack enable (bare, or naming pnpm); corepack prepare|use|… pnpm
#       swaps the recipe's pinned pnpm for a shim that downloads its own.
#   npm|pnpm global install (-g, also inside a cluster such as -gf), yarn
#   global add, of pnpm, @pnpm/exe, n, node, corepack; pnpm self-update; pnpm
#   env use|add; npx|npm exec|pnpm dlx|yarn dlx pnpm; npx n; npx
#   node@<version>; curl|wget get.pnpm.io/install.sh
#       an unpinned pnpm, or a second Node.
#   backpack.pl add without --recipe, when its --install does any of the above
#   or its --name names node or pnpm (node22, node+pnpm, nvm+node22, ...);
#   backpack.pl add --recipe with an --install override that does any of the
#   above except the nodejs.org download, which is the recipe's own shape
#       Node enters the backpack only through the recipe. A project that pins
#       another major keeps --recipe node-pnpm and overrides the version.
#
# Allowed: everything else, including node --version, npm ls, npm ci, pnpm
# install, a project-local npm install, npm install -g of any other tool (the
# proposal flow offers to record it), nvm use, corepack enable yarn next to the
# recipe's Node. Items already in a backpack keep replaying, klink's grandfathered
# other/nvm+node22 included: the install pass runs each item inside backpack.pl
# (`bash -c`), never as a Bash tool call, so no hook sees them, and the
# launcher's own pass runs through `podman exec`, outside Claude Code entirely.
#
# Commands are read the way the shell reads them (shell_lex): quoted text,
# comments and here-document bodies are data, so a commit message or an `echo`
# that mentions `apt-get install nodejs` is not refused, while `sudo`, `env`,
# VAR=value prefixes and `sh -c '…'` / `eval` are looked through.
#
# ── Proposals (PostToolUse) ─────────────────────────────────────────────
#
# Design choice C, "ask, don't auto-add": the hook never writes to
# backpack.json. It identifies items that look like installs and aren't in the
# backpack yet, and emits an `additionalContext` payload with pre-filled
# /backpack:add invocations. The agent decides whether to record each (filling
# in the rationale) or skip it as a one-off. Some installs are throwaway (`jq`
# once, to inspect a JSON); auto-adding would pollute the backpack. With the
# ask flow, the worst case is a second prompt after the next install.
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
# Each simple command of a compound one is matched on its own, after its
# `sudo`, `env` and VAR=value prefixes; the recorded command never has them
# (the install pass replays as root). Already-tracked (category, name) pairs
# are filtered out, so re-installing a declared item is silent. A Node or pnpm
# install is never proposed: the recipe is proposed instead.
#
# Path resolution:
#   BACKPACK_FILE (env)             defaults to $HOME/.claude/backpack.json
#   BACKPACK_RECIPE_NODE_BIN (env)  defaults to /opt/tools/node/bin (tests only)

use strict;
use warnings;
use utf8;    # the literals below (em dashes) are characters, encoded once by encode_json

my $RECIPE = 'node-pnpm';
# The recipe's bin directory: node-pnpm.json's bin_dirs[0], and on the image
# PATH (Containerfile). plugins/backpack/tests/t/node-recipe-hooks.t holds the
# three equal.
my $RECIPE_BIN    = $ENV{BACKPACK_RECIPE_NODE_BIN} // '/opt/tools/node/bin';
my $BACKPACK_FILE = $ENV{BACKPACK_FILE} // "$ENV{HOME}/.claude/backpack.json";
my $MAX_COMMAND   = 200_000;    # longer than any real command; past it, fail open
my $ADD_RECIPE    = "/backpack:add --recipe $RECIPE --rationale '<WHY: what this project builds with Node>'";

# Why each kind of refusal is one (deny_reason).
my %WHY = (
    apt          => "Debian's nodejs and npm packages are Node 18, which is end of life, and no rebuild would restore them.",
    deb          => "A Node .deb installed by hand skips the recipe's pins and checksums, and no rebuild restores it.",
    manager      => "A Node version manager downloads an unpinned, unverified Node that the next container rebuild does not restore.",
    nodesource   => "NodeSource's setup script adds a third-party apt repository, as root.",
    dist         => "A Node unpacked by hand is gone at the next rebuild. Reading nodejs.org/dist/index.json or a SHASUMS256.txt is still fine.",
    'corepack-no-node' => "corepack comes with the recipe's Node, which this container does not have yet.",
    'corepack-pnpm'    => "pnpm already comes pinned from the recipe; corepack would swap it for a shim that downloads a pnpm of its own choosing.",
    pnpm         => "pnpm comes pinned from the recipe; this would bring in an unpinned pnpm that the next rebuild does not restore.",
    'node-pkg'   => "That installs a second Node outside the recipe.",
);

# Packages that are pnpm, or a Node, when installed globally or run through npx.
my $PNPM_PKG = qr{^(?:pnpm|\@pnpm/exe)(?:@.*)?$};
my $NODE_PKG = qr{^(?:pnpm|\@pnpm/exe|n|node|corepack)(?:@.*)?$};

# Wrappers that run the rest of their line, and which of their options take a
# value (command_start).
my %WRAPPER_ARG_OPTS = map { my $k = $_->[0]; ($k => { map { $_ => 1 } @{ $_->[1] } }) } (
    [ sudo    => [qw(-u -g -C -D -h -p -R -r -T -t --user --group --chdir --prompt --role --type
                     --close-from --host --command-timeout --other-user)] ],
    [ doas    => [qw(-u -C)] ],
    [ env     => [qw(-u -C -S --unset --chdir --split-string)] ],
    [ nice    => [qw(-n --adjustment)] ],
    [ timeout => [qw(-s -k --signal --kill-after)] ],
    [ nohup   => [] ],
    [ command => [] ],
    [ builtin => [] ],
    [ exec    => [qw(-a)] ],
    [ time    => [qw(-f -o --format --output)] ],
    [ stdbuf  => [qw(-i -o -e)] ],
    [ xargs   => [qw(-a -d -E -I -L -n -P -s --arg-file --delimiter --eof --replace --max-lines
                     --max-args --max-procs --max-chars)] ],
);

# Words the guard or the Node half of the proposal flow could act on. Only a
# prefilter: a match costs the full parse, never a decision.
my $NODE_WORDS = qr/node|npm|npx|pnpm|corepack|nvm|fnm|volta|asdf|mise|rtx|yarn|backpack|n-install|tj\/n\b|(?<![\w.\/-])n\s/;

my $raw = do { local $/; <STDIN> };
exit 0 unless defined $raw && length $raw;

# ── Fast path: decide from the raw payload whether there is anything to do ──
{
    # A command of many thousand escapes exceeds the regex engine's recursion
    # limit: the match then fails, the full parse runs, and the warning is noise.
    no warnings 'regexp';
    my $ev = $raw =~ /"hook_event_name"\s*:\s*"(PreToolUse|PostToolUseFailure)"/ ? $1 : 'PostToolUse';
    if ($ev eq 'PostToolUseFailure') {
        exit 0 unless $raw =~ /not found|No such file/;
    } elsif (my ($raw_cmd) = $raw =~ /"command"\s*:\s*"([^"\\]*(?:\\.[^"\\]*)*)"/s) {
        exit 0 unless $raw_cmd =~ $NODE_WORDS
            || ($ev eq 'PostToolUse' && $raw_cmd =~ /install|\badd\b|\bi\b/);
    }
}

require JSON::PP;

my $data = eval { JSON::PP::decode_json($raw) };
exit 0 unless ref $data eq 'HASH';
exit 0 unless ($data->{tool_name} // '') eq 'Bash';
# Guard against schema-valid-but-shape-wrong payloads: if tool_input isn't a
# hash ref, the next `->{}` dereference would throw under `use strict`, and the
# hook would exit non-zero, exactly the disruption the contract forbids.
exit 0 unless ref($data->{tool_input}) eq 'HASH';
my $command = $data->{tool_input}{command};
exit 0 unless defined $command && !ref $command && length $command;
exit 0 if length $command > $MAX_COMMAND;

my $event = $data->{hook_event_name};
$event = 'PostToolUse' unless defined $event && !ref $event && length $event;

eval {
    if    ($event eq 'PreToolUse')         { on_pre_tool_use($command) }
    elsif ($event eq 'PostToolUseFailure') { on_failure($data) }
    elsif ($event eq 'PostToolUse')        { on_post_tool_use($command) }
    1;
} or warn "auto-declare: $@";

exit 0;

# ── Handlers ────────────────────────────────────────────────────────

sub emit {
    my ($event, %fields) = @_;
    print JSON::PP::encode_json({ hookSpecificOutput => { hookEventName => $event, %fields } });
}

sub on_pre_tool_use {
    my ($command) = @_;
    my $v = node_violation($command, {}) or return;
    emit('PreToolUse', permissionDecision => 'deny', permissionDecisionReason => deny_reason($v));
}

sub on_failure {
    my ($data) = @_;
    return if $data->{is_interrupt};
    my $err = $data->{error};
    return unless defined $err && !ref $err;
    my $tool = missing_node_tool($err) // return;
    # A tool missing on another machine (ssh, a container) is not this sandbox's.
    for my $words (simple_commands($data->{tool_input}{command})) {
        my @t = map { $_->[0] } @$words;
        my $k = command_start(\@t);
        next if $k > $#t;
        (my $head = $t[$k]) =~ s{.*/}{};
        return if $head =~ /^(?:ssh|docker|podman|kubectl|lxc|vagrant)$/;
    }
    emit('PostToolUseFailure', additionalContext => failure_hint($tool));
}

sub on_post_tool_use {
    my ($command) = @_;
    # Static: the command already ran, so the rule judges its shape only.
    my $node = node_violation($command, { static => 1 });

    my @declarations;
    push @declarations, parse_apt($command);
    push @declarations, parse_npm_global($command);
    push @declarations, parse_pnpm_global($command);
    push @declarations, parse_yarn_global($command);
    push @declarations, parse_pip($command);
    push @declarations, parse_cargo($command);

    # A declaration whose own install command is an ad-hoc Node or pnpm
    # (apt nodejs, npm -g pnpm, ...) is never proposed; the recipe is.
    @declarations = grep {
        my $v = node_violation($_->{install}, { static => 1 });
        $node //= $v;
        !$v;
    } @declarations;

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

    # Filter out items already in the backpack — re-installing a tracked item
    # shouldn't re-prompt. If reading the backpack fails (missing, malformed),
    # treat all proposals as new; better noisy than silent.
    my @items = load_items();
    my %tracked = map { ("$_->{category}\0$_->{name}" => 1) } @items;
    @declarations = grep { !$tracked{"$_->{category}\0$_->{name}"} } @declarations;

    my @parts;
    push @parts, build_proposal(\@declarations) if @declarations;
    push @parts, recipe_proposal($node, \@items) if $node;
    return unless @parts;
    emit('PostToolUse', additionalContext => join("\n", @parts));
}

# ── Messages ────────────────────────────────────────────────────────

sub recipe_prefix { (my $p = $RECIPE_BIN) =~ s{/bin/*$}{}; return $p }

sub deny_reason {
    my ($v) = @_;
    my $prefix = recipe_prefix();
    if ($v->{rule} eq 'backpack-add') {
        return "[backpack] Refused: a backpack item that brings Node or pnpm outside the $RECIPE recipe ($v->{what}). "
             . "Node and pnpm enter the backpack only through the recipe:\n"
             . "  $ADD_RECIPE\n"
             . "then /backpack:install. If the project pins another Node major, keep --recipe $RECIPE and override "
             . "--name, --install and --verify (change the version literals and both sha256 values). "
             . "Items already in the backpack keep replaying.";
    }
    my $lead = "[backpack] Refused: $v->{what}. " . ($WHY{$v->{rule}} // '') . " ";
    # The next step depends on what this container and its backpack already have.
    if (-x "$RECIPE_BIN/node") {
        return $lead . "Node.js and pnpm from the $RECIPE recipe are already installed here, in $RECIPE_BIN "
             . "(on PATH): use them. If the project needs another Node major, add the recipe again with "
             . "--name, --install and --verify overridden (the version literals and both sha256 values):\n"
             . "  $ADD_RECIPE\nthen /backpack:install.";
    }
    my ($recipe_item) = grep { is_recipe_item($_) } load_items();
    if ($recipe_item) {
        return $lead . "The backpack already declares Node through the $RECIPE recipe ('$recipe_item->{name}'), "
             . "and this container has not installed it yet: run /backpack:install.";
    }
    return $lead
         . "Node.js, npm, npx, corepack and pnpm come from one place in this sandbox, the $RECIPE recipe:\n"
         . "  $ADD_RECIPE\n"
         . "then /backpack:install. It installs an exact Node LTS and pnpm, checksum-verified, under $prefix "
         . "(already on PATH), and every rebuild restores it.";
}

sub recipe_proposal {
    my ($v, $items) = @_;
    my ($recipe_item) = grep { is_recipe_item($_) } @$items;
    if ($recipe_item) {
        return "[backpack] That command put Node.js or pnpm in place outside the $RECIPE recipe ($v->{what}). "
             . "The backpack already declares the recipe ('$recipe_item->{name}'), so there is nothing to record; "
             . "its $RECIPE_BIN comes first on PATH.";
    }
    my $lead = $v->{rule} eq 'backpack-add'
        ? "[backpack] That command recorded Node or pnpm in the backpack without the $RECIPE recipe ($v->{what}). "
          . "Remove that item with /backpack:remove and declare Node the one sanctioned way:"
        : "[backpack] That command put Node.js or pnpm in place outside the $RECIPE recipe ($v->{what}), "
          . "so it is not proposed for the backpack. Declare Node the one sanctioned way:";
    return "$lead\n  $ADD_RECIPE\nthen /backpack:install (an exact Node LTS and pnpm, checksum-verified, restored on every rebuild).";
}

# missing_node_tool($error) -> the Node tool a failed command could not find,
# or undef. Only a shell's own message counts, at the start of a line: bash
# `bash: line 1: node: command not found` (or a script's path in place of
# `bash`), dash `sh: 1: node: not found`, zsh `zsh: command not found: node`, a
# `#!/usr/bin/env node` shebang (`/usr/bin/env: 'node': No such file or
# directory`, typographic quotes in a UTF-8 locale), and GNU make's recipe line.
# A tool's own output that happens to end in "npm: not found" is not one.
sub missing_node_tool {
    my ($t) = @_;
    my $tool = qr/node|nodejs|npm|npx|pnpm|pnpx|corepack/;
    my $hit;
    if    ($t =~ m{^(?:\S*/\S*|\S*sh): (?:line \d+: )?($tool): command not found\s*$}m)         { $hit = $1 }
    elsif ($t =~ m{^\S*sh: (?:\d+: )?($tool): not found\s*$}m)                                 { $hit = $1 }
    elsif ($t =~ m{^\S*zsh: command not found: ($tool)\s*$}m)                                  { $hit = $1 }
    elsif ($t =~ /\benv: ['"\x{2018}]?($tool)['"\x{2019}]?: No such file or directory/)          { $hit = $1 }
    elsif ($t =~ /^make(?:\[\d+\])?: ($tool): (?:Command not found|No such file or directory)/m) { $hit = $1 }
    return undef unless defined $hit;
    return $hit eq 'nodejs' ? 'node' : $hit eq 'pnpx' ? 'pnpm' : $hit;
}

sub failure_hint {
    my ($tool) = @_;
    my @items = load_items();
    my ($recipe_item) = grep { is_recipe_item($_) } @items;
    my ($other_node)  = grep { !is_recipe_item($_) && names_runtime($_->{name}, 'node') } @items;
    my $bin  = $RECIPE_BIN;
    my $lead = "[backpack] `$tool` is missing.";

    if (-x "$bin/$tool") {
        return "$lead It is installed at $bin/$tool, but $bin is not on this shell's PATH: "
             . "call it by that path, or put $bin first on PATH.";
    }
    if (-x "$bin/node") {
        if ($tool eq 'pnpm') {
            return "$lead The backpack's recipe item ('$recipe_item->{name}') installs pnpm, but that step has "
                 . "not completed in this container: run /backpack:install."
                if $recipe_item && ($recipe_item->{install} // '') =~ /\bpnpm\b/;
            return "$lead The backpack's Node was declared without pnpm. Add it again from the recipe, "
                 . "whose install step brings pnpm:\n  $ADD_RECIPE\nthen /backpack:install.";
        }
        return "$lead The recipe's Node in " . recipe_prefix() . " is incomplete: run /backpack:install, "
             . "and if it reports the item as already present, remove " . recipe_prefix() . " and run it again.";
    }
    if ($recipe_item) {
        return "$lead The backpack declares Node through the $RECIPE recipe ('$recipe_item->{name}'), "
             . "but this container has not installed it yet: run /backpack:install.";
    }
    if ($other_node) {
        my $n = $other_node->{name};
        return "$lead The backpack declares Node as '$n', from before the recipe existed; "
             . "/backpack:install replays it."
            unless $tool eq 'pnpm';
        return "$lead The backpack's Node item '$n' did not come from the $RECIPE recipe and brings no pnpm; "
             . "the recipe is the one way to get it. Replace the item: /backpack:remove --category "
             . "'$other_node->{category}' --name '$n', then\n  $ADD_RECIPE\n"
             . "(if the project pins another Node major, keep --recipe $RECIPE and override --name, --install "
             . "and --verify), then /backpack:install.";
    }
    return "$lead This sandbox image ships no Node.js. Node, npm, npx, corepack and pnpm come from one place, "
         . "the $RECIPE recipe (an exact Node LTS and pnpm, checksum-verified, restored on every rebuild):\n"
         . "  $ADD_RECIPE\nthen /backpack:install. Installing Node any other way is refused by a hook.";
}

# ── The Node rule ───────────────────────────────────────────────────

# viol($rule, $what) -> a verdict. $what echoes text from the command (a URL,
# a package spec) back to the agent and the transcript, so control characters
# become spaces and it is cut to a readable length.
sub viol {
    my ($rule, $what) = @_;
    $what =~ s/[\x00-\x1f\x7f]/ /g;
    $what = substr($what, 0, 197) . '...' if length $what > 200;
    return { rule => $rule, what => $what };
}

# node_violation($command, \%ctx) -> { rule, what } for the first simple command
# that puts a Node or pnpm in place outside the recipe, else undef.
#   ctx.static  judge the shape only: no look at what this container has
#               (PostToolUse, and a backpack item's install, which runs later)
#   ctx.recipe  the text is an --install override under backpack.pl add
#               --recipe, so a nodejs.org tarball download is the recipe's own
#               shape, not a violation
sub node_violation {
    my ($cmd, $ctx, $depth) = @_;
    $depth //= 0;
    return undef if $depth > 3 || !defined $cmd || length $cmd > $MAX_COMMAND;
    for my $words (simple_commands($cmd)) {
        my @t = map { $_->[0] } @$words;
        my $k = command_start(\@t);
        next if $k > $#t;
        my $v = words_violation([ @t[$k .. $#t] ], $ctx, $depth);
        return $v if $v;
    }
    return undef;
}

sub pkg_violation {
    my ($pkg, $what) = @_;
    return viol('pnpm', $what) if $pkg =~ $PNPM_PKG;
    return viol('node-pkg', $what);
}

sub words_violation {
    my ($w, $ctx, $depth) = @_;
    my @w = @$w;
    (my $head = $w[0]) =~ s{.*/}{};
    my @rest = @w[1 .. $#w];

    # backpack.pl add: its --install text is data, judged here. Any other
    # backpack.pl verb (install, list, remove, audit, validate) is fine. The
    # script is the command itself, or perl's first operand.
    my $bp_at;
    if ($head eq 'backpack.pl') {
        $bp_at = 0;
    } elsif ($head =~ /^perl[\d.]*$/) {
        for (my $j = 1; $j <= $#w; $j++) {
            if ($w[$j] =~ /^-[IMmx]$/) { $j++; next }    # a switch whose value is the next word
            next if $w[$j] =~ /^-/;
            $bp_at = $j if $w[$j] =~ m{(?:^|/)backpack\.pl$};
            last;
        }
    }
    if (defined $bp_at) {
        return (($w[$bp_at + 1] // '') eq 'add')
            ? backpack_add_violation([ @w[$bp_at + 2 .. $#w] ], $depth)
            : undef;
    }

    if ($head =~ /^(?:apt|apt-get|aptitude)$/) {
        my ($sub, @pkgs) = apt_operands(@rest);
        return undef unless defined $sub && $sub =~ /^(?:install|reinstall)$/;
        return undef if grep { /^(?:-s|--simulate|--dry-run|--just-print|--no-act|--recon)$/ } @rest;
        for my $p (@pkgs) {
            return viol('deb', "$head install $p") if node_deb($p);
            (my $base = $p) =~ s{[=/:].*$}{};
            return viol('apt', "$head install $p") if $base =~ /^(?:nodejs|npm|node)$/;
        }
        return undef;
    }
    if ($head eq 'dpkg' && grep { /^(?:-i|--install)$/ } @rest) {
        for (@rest) { return viol('deb', "dpkg -i $_") if node_deb($_) }
        return undef;
    }

    my $sub = $rest[0] // '';
    return viol('manager', "nvm $sub") if $head eq 'nvm' && $sub =~ /^install/;
    if ($head eq 'n') {
        my @pos;
        for (my $i = 0; $i < @rest; $i++) {
            if ($rest[$i] =~ /^(?:-a|--arch)$/) { $i++; next }
            push @pos, $rest[$i] unless $rest[$i] =~ /^-/;
        }
        my $nsub = $pos[0] // return undef;
        return $nsub =~ /^(?:lts|latest|current|stable|auto|engine|install|i|download|v?\d[\d.x]*)$/
            ? viol('manager', "n $nsub") : undef;
    }
    return viol('manager', "fnm $sub")
        if $head eq 'fnm' && ($sub =~ /^(?:install|i)$/ || grep { $_ eq '--install-if-missing' } @rest);
    return viol('manager', "volta $sub")    if $head eq 'volta'  && $sub =~ /^(?:install|fetch|pin|setup)$/;
    return viol('manager', "nodenv $sub")   if $head eq 'nodenv' && $sub eq 'install';
    return viol('manager', "asdf $sub nodejs")
        if $head eq 'asdf' && $sub =~ /^(?:install|plugin|plugin-add|global|local|set|shell)$/
           && grep { /^nodejs$/ } @rest;
    if ($head =~ /^(?:mise|rtx)$/ && $sub =~ /^(?:install|i|use|u|global|local)$/) {
        for (@rest[1 .. $#rest]) {
            return viol('manager', "$head $sub $_") if /^node(?:js)?(?:@.*)?$/;
            return viol('pnpm', "$head $sub $_")    if /^pnpm(?:@.*)?$/;
        }
    }
    # nodeenv downloads a Node into a virtualenv unless told to use the system's.
    return viol('manager', 'nodeenv') if $head eq 'nodeenv' && !nodeenv_system(@rest);
    if (my @pip = pip_args($head, @rest)) {
        return viol('manager', 'python -m nodeenv') if $pip[0] eq 'nodeenv' && !nodeenv_system(@pip[1 .. $#pip]);
        if ($pip[0] eq 'install') {
            for (@pip) { return viol('node-pkg', "pip install $_") if /^nodejs-bin(?:[=<>!~\[].*)?$/ }
        }
    }

    if ($head =~ /^(?:curl|wget|aria2c)$/ || ($head eq 'git' && grep { $_ eq 'clone' } @rest)) {
        # The installers themselves, never a README, a release API or an issue page.
        my $clone     = $head eq 'git';
        my $head_only = grep { /^(?:--head|--spider)$/ || /^-[A-Za-z]*I[A-Za-z]*$/ } @rest;    # curl -I, wget --spider
        for my $u (@rest) {
            return viol('manager', 'fetching the nvm installer')
                if $u =~ m{nvm-sh/nvm/[^/\s]+/install\.sh}i || ($clone && $u =~ m{nvm-sh/nvm(?:\.git)?/?$}i);
            return viol('manager', 'fetching the fnm installer')   if $u =~ m{fnm\.vercel\.app/install\b}i;
            return viol('manager', 'fetching the volta installer')
                if $u =~ m{get\.volta\.sh|volta-cli/volta/\S*install\S*\.sh}i;
            return viol('manager', 'fetching the n installer')
                if $u =~ m{(?:bit\.ly|git\.io)/n-install|mklement0/n-install|(?:^|/)tj/n/[^/\s]+/bin/n$}i
                   || ($clone && $u =~ m{(?:^|/)tj/n(?:\.git)?/?$}i);
            return viol('manager', 'fetching the nodenv installer')
                if $u =~ m{nodenv/nodenv-installer}i || ($clone && $u =~ m{nodenv/(?:nodenv|node-build)(?:\.git)?/?$}i);
            return viol('nodesource', 'fetching a NodeSource setup script') if $u =~ m{(?:deb|rpm)\.nodesource\.com/setup}i;
            return viol('pnpm', 'fetching the pnpm standalone installer')   if $u =~ m{get\.pnpm\.io/install}i;
            return viol('dist', "downloading Node from nodejs.org ($u)")
                if !$clone && !$head_only && !$ctx->{recipe} && node_dist_file($u);
        }
        return undef;
    }

    if ($head eq 'corepack') {
        my @pos = grep { !/^-/ } @rest;
        my $csub = $pos[0] // return undef;
        return undef unless $csub =~ /^(?:enable|prepare|install|use|up|pnpm|pnpx|yarn|yarnpkg|npm|npx)$/;
        return viol('corepack-no-node', join(' ', 'corepack', @pos)) if !$ctx->{static} && !-x "$RECIPE_BIN/node";
        return viol('corepack-pnpm', join(' ', 'corepack', @pos))
            if ($csub eq 'enable' && @pos == 1) || grep { /^(?:pnpm|pnpx)(?:@.*)?$/ } @pos;
        return undef;
    }

    if ($head eq 'npm') {
        my ($s, $global, @pos) = pm_operands(@rest);
        return undef unless defined $s;
        if ($global && $s =~ /^(?:install|i|in|ins|inst|insta|instal|isnt|isnta|isntal|isntall|add|update|up|upgrade|udpate)$/) {
            for (@pos) { return pkg_violation($_, "npm $s -g $_") if $_ =~ $NODE_PKG }
        }
        return npx_violation(@rest[1 .. $#rest]) if $s =~ /^(?:exec|x)$/;
        return undef;
    }
    return npx_violation(@rest) if $head eq 'npx';

    if ($head eq 'pnpm') {
        my ($s, $global, @pos) = pm_operands(@rest);
        return undef unless defined $s;
        return viol('pnpm', 'pnpm self-update') if $s eq 'self-update';
        return viol('node-pkg', "pnpm env $pos[0]") if $s eq 'env' && ($pos[0] // '') =~ /^(?:use|add|install)$/;
        if ($global && $s =~ /^(?:add|install|i|update|up|upgrade)$/) {
            for (@pos) { return pkg_violation($_, "pnpm $s -g $_") if $_ =~ $NODE_PKG }
        }
        return viol('pnpm', "pnpm dlx $pos[0]") if $s eq 'dlx' && ($pos[0] // '') =~ $PNPM_PKG;
        return undef;
    }

    if ($head eq 'yarn') {
        my ($s, undef, @pos) = pm_operands(@rest);
        return undef unless defined $s;
        if ($s eq 'global' && ($pos[0] // '') eq 'add') {
            for (@pos[1 .. $#pos]) { return pkg_violation($_, "yarn global add $_") if $_ =~ $NODE_PKG }
        }
        return viol('pnpm', "yarn dlx $pos[0]") if $s eq 'dlx' && ($pos[0] // '') =~ $PNPM_PKG;
        return undef;
    }

    return undef;
}

# node_dist_file($url) -> true for a Node archive in a version directory of
# nodejs.org's dist tree (node-v<version>-<platform>.tar.xz and kin, or a bare
# `$T` as in the recipe's own install), false for everything else there: the
# index and checksum lists a pin is computed from, signatures, the headers
# tarball node-gyp fetches, the docs.
sub node_dist_file {
    my ($u) = @_;
    return 0 unless $u =~ m{(?:^|[/.@])nodejs\.org/(?:dist|download/[^/\s]+)/(?:v\d|latest|node-v)[^/\s]*/([^?#\s]*)}i;
    my $file = $1;
    return $file =~ /^node-v[^\/]*?(?<!-headers)\.(?:tar\.(?:xz|gz)|tgz|zip|7z|pkg|msi)$/i
        || $file =~ /^\$\{?\w+\}?$/;
}

sub npx_violation {
    my @a = @_;
    my @pkgs;    # every -p/--package value, plus the command to run
    for (my $i = 0; $i < @a; $i++) {
        my $x = $a[$i];
        if ($x =~ /^--package=(.*)$/s)          { push @pkgs, $1; next }
        if ($x eq '-p' || $x eq '--package')   { push @pkgs, $a[++$i] // ''; next }
        if ($x eq '-c' || $x eq '--call')      { $i++; next }
        if ($x eq '--')                        { push @pkgs, $a[$i + 1] // ''; last }
        next if $x =~ /^-/;
        push @pkgs, $x;
        last;
    }
    for (@pkgs) {
        return viol('pnpm', "npx $_")     if $_ =~ $PNPM_PKG;
        return viol('node-pkg', "npx $_") if /^node@/ || /^n(?:@.*)?$/;
    }
    return undef;
}

# backpack_add_violation(\@args_after_add) -> the add's verdict. Options are
# read the way backpack.pl's GetOptions reads them (one or two dashes, `=` or
# a separate value, a unique prefix such as --rec).
sub backpack_add_violation {
    my ($args, $depth) = @_;
    my %o = getopt_values($args, qw(category name install verify rationale bin_dirs recipe));
    my $from_recipe = defined $o{recipe} && length $o{recipe};
    if (defined $o{install}) {
        my $v = node_violation($o{install}, { static => 1, recipe => $from_recipe }, $depth + 1);
        return viol('backpack-add', "its --install: $v->{what}") if $v;
    }
    if (!$from_recipe && defined $o{name}
        && (names_runtime($o{name}, 'node') || names_runtime($o{name}, 'pnpm'))) {
        return viol('backpack-add', "an item named '$o{name}'");
    }
    return undef;
}

sub getopt_values {
    my ($args, @names) = @_;
    my %v;
    for (my $i = 0; $i < @$args; $i++) {
        next unless $args->[$i] =~ /^--?([A-Za-z_][\w-]*)(?:=(.*))?$/s;
        my ($key, $val) = ($1, $2);
        my @hit = grep { $_ eq $key } @names;
        @hit = grep { index($_, $key) == 0 } @names unless @hit;
        next unless @hit == 1;
        $val = $args->[++$i] unless defined $val;
        $v{ $hit[0] } = $val if defined $val;
    }
    return %v;
}

sub apt_operands {
    my @a = @_;
    my %with_arg = map { $_ => 1 } qw(-o -t -c --option --target-release --default-release --config-file);
    my ($sub, @pkgs);
    for (my $i = 0; $i < @a; $i++) {
        my $x = $a[$i];
        if ($x =~ /^-/) { $i++ if $with_arg{$x}; next }
        if (defined $sub) { push @pkgs, $x } else { $sub = $x }
    }
    return ($sub, @pkgs);
}

# node_deb($arg) -> true for a local Debian package of Node (nodejs_22.11.0-1_amd64.deb).
sub node_deb { return $_[0] =~ m{(?:^|/)(?:nodejs|node|npm)_[^/]*\.deb$}i }

# nodeenv_system(@args) -> true when nodeenv is told to use the system's Node
# (--node=system, -n system) and so downloads none.
sub nodeenv_system {
    my @a = @_;
    for my $i (0 .. $#a) {
        return 1 if $a[$i] =~ /^--node=system$/;
        return 1 if $a[$i] =~ /^(?:-n|--node)$/ && ($a[$i + 1] // '') eq 'system';
    }
    return 0;
}

# pip_args($head, @rest) -> pip's own arguments for `pip|pip3 ...` and
# `python[3] -m pip|nodeenv ...` (with the module name first for nodeenv),
# else ().
sub pip_args {
    my ($head, @rest) = @_;
    return @rest if $head =~ /^pip[\d.]*$/ && @rest;
    if ($head =~ /^python[\d.]*$/ && ($rest[0] // '') eq '-m') {
        my $mod = $rest[1] // return ();
        return @rest[2 .. $#rest] if $mod eq 'pip' && @rest > 2;
        return @rest[1 .. $#rest] if $mod eq 'nodeenv';
    }
    return ();
}

# pm_operands(@args) -> ($subcommand, $is_global, @positionals) for npm, pnpm
# and yarn.
sub pm_operands {
    my @a = @_;
    my %with_arg = map { $_ => 1 }
        qw(--prefix --registry --cache --userconfig --tag -w --workspace -C --dir --filter -F --reporter --loglevel);
    my ($sub, $global, @pos) = (undef, 0);
    for (my $i = 0; $i < @a; $i++) {
        my $x = $a[$i];
        if ($x eq '--') {
            my @tail = @a[$i + 1 .. $#a];
            $sub = shift @tail unless defined $sub;
            push @pos, @tail;
            last;
        }
        if ($x =~ /^-/) {
            $global = 1 if $x =~ /^(?:--global|--global=true|--location=global)$/
                || $x =~ /^-[A-Za-z]*g[A-Za-z]*$/;    # -g, or a cluster such as -gf
            if ($x eq '--location') { $global = 1 if ($a[$i + 1] // '') eq 'global'; $i++; next }
            $i++ if $with_arg{$x};
            next;
        }
        if (defined $sub) { push @pos, $x } else { $sub = $x }
    }
    return ($sub, $global, @pos);
}

# names_runtime($item_name, $runtime) -> true when a '+'-joined part of the
# name, its version suffix dropped, is that runtime ('node22', 'node+pnpm',
# 'nvm+node22' all name node). The same reading as butler's bp-deps-check.pl
# (normalize_runtime + is_declared), which decides whether a backpack declares
# a runtime; this file is mounted on its own and cannot load that script.
sub names_runtime {
    my ($name, $rt) = @_;
    return 0 unless defined $name && !ref $name;
    for my $part (split /\+/, $name) {
        my $s = lc $part;
        $s =~ s/^\s+|\s+$//g;
        $s =~ s/[-_ ]?v?\d[\d.]*$//;
        $s =~ s/[-_ ]+$//;
        $s = 'node' if $s eq 'nodejs';
        return 1 if $s eq $rt;
    }
    return 0;
}

sub is_recipe_item {
    my ($it) = @_;
    return 0 unless ref $it->{bin_dirs} eq 'ARRAY';
    (my $want = $RECIPE_BIN) =~ s{/+$}{};
    for my $d (@{ $it->{bin_dirs} }) {
        next unless defined $d && !ref $d;
        (my $have = $d) =~ s{/+$}{};
        return 1 if $have eq $want;
    }
    return 0;
}

# load_items() -> the backpack's items (hashrefs with a scalar category and
# name), or () when the file is missing or unreadable: the proposal flow
# continues even if the backpack is in an odd state.
sub load_items {
    my $path = $BACKPACK_FILE;
    return () unless -f $path;
    open my $fh, '<:raw', $path or return ();
    local $/;
    my $content = <$fh>;
    close $fh;
    my $data = eval { JSON::PP::decode_json($content) };
    return () unless $data && ref $data eq 'HASH' && ref $data->{items} eq 'ARRAY';
    return grep {
        ref $_ eq 'HASH' && defined $_->{category} && defined $_->{name}
            && !ref $_->{category} && !ref $_->{name}
    } @{ $data->{items} };
}

# ── Reading a command the way the shell does ────────────────────────

# shell_lex($command) -> list of simple commands, each an arrayref of words,
# each word [ $text_with_quotes_removed, $raw_text ]. Splits at unquoted ; & |
# ( ) ` $( and newlines; drops comments, redirections (with their targets) and
# here-document bodies. Approximate where the shell is dynamic (expansions are
# left as written), which is all a classifier of command shapes needs.
sub shell_lex {
    my ($s) = @_;
    my (@cmds, @cur, @heredocs);
    my ($w, $r, $in, $skip) = ('', '', 0, 0);
    my $n = length $s;
    my $i = 0;
    my $end_word = sub {
        if ($in) {
            if ($skip) { $skip = 0 } else { push @cur, [ $w, $r ] }
        }
        ($w, $r, $in) = ('', '', 0);
    };
    my $end_cmd = sub {
        $end_word->();
        push @cmds, [@cur] if @cur;
        @cur  = ();
        $skip = 0;
    };
    while ($i < $n) {
        my $c = substr($s, $i, 1);
        if ($c eq '\\') {
            my $nx = $i + 1 < $n ? substr($s, $i + 1, 1) : '';
            $i += 2;
            next if $nx eq "\n";    # line continuation
            $w .= $nx; $r .= "\\$nx"; $in = 1;
            next;
        }
        if ($c eq "'") {
            my $j = index($s, "'", $i + 1);
            $j = $n if $j < 0;
            $w .= substr($s, $i + 1, $j - $i - 1);
            $r .= substr($s, $i, $j - $i + 1);
            $in = 1; $i = $j + 1;
            next;
        }
        if ($c eq '"') {
            my $j = $i + 1;
            while ($j < $n) {
                my $d = substr($s, $j, 1);
                last if $d eq '"';
                if ($d eq '\\' && $j + 1 < $n) {
                    my $e = substr($s, $j + 1, 1);
                    $w .= $e eq "\n" ? '' : $e =~ /[\$`"\\]/ ? $e : "\\$e";
                    $j += 2;
                    next;
                }
                $w .= $d; $j++;
            }
            $r .= substr($s, $i, $j - $i + 1);
            $in = 1; $i = $j + 1;
            next;
        }
        if ($c eq '#' && !$in) {
            my $j = index($s, "\n", $i);
            $i = $j < 0 ? $n : $j;
            next;
        }
        if ($c eq "\n") {
            $end_cmd->();
            $i++;
            while (my $hd = shift @heredocs) {    # here-document bodies are data
                my ($delim, $tabs) = @$hd;
                while ($i < $n) {
                    my $j = index($s, "\n", $i);
                    my $line = substr($s, $i, ($j < 0 ? $n : $j) - $i);
                    $i = $j < 0 ? $n : $j + 1;
                    $line =~ s/^\t+// if $tabs;
                    last if $line eq $delim;
                }
            }
            next;
        }
        if ($c eq ' ' || $c eq "\t" || $c eq "\r") { $end_word->(); $i++; next }
        if ($c eq '$' && substr($s, $i + 1, 1) eq '(') { $end_cmd->(); $i += 2; next }
        if ($c =~ /[;&|()`]/) { $end_cmd->(); $i++; next }
        if ($c eq '<' || $c eq '>') {
            if ($in && $w =~ /^\d+$/ && $r eq $w) { ($w, $r, $in) = ('', '', 0) }    # an fd number
            else                                  { $end_word->() }
            if ($c eq '<' && substr($s, $i + 1, 1) eq '<' && substr($s, $i + 2, 1) ne '<') {
                $i += 2;
                my $tabs = 0;
                if (substr($s, $i, 1) eq '-') { $tabs = 1; $i++ }
                $i++ while $i < $n && substr($s, $i, 1) =~ /[ \t]/;
                my $delim = '';
                while ($i < $n) {
                    my $d = substr($s, $i, 1);
                    last if $d =~ /[\s;&|()<>]/;
                    $delim .= $d unless $d eq "'" || $d eq '"' || $d eq '\\';
                    $i++;
                }
                push @heredocs, [ $delim, $tabs ] if length $delim;
                next;
            }
            $i++;
            $i++ while $i < $n && substr($s, $i, 1) =~ /[<>|]/;
            if ($i < $n && substr($s, $i, 1) eq '&') {
                $i++;
                if ($i < $n && substr($s, $i, 1) =~ /[\d-]/) {    # >&2, 2>&1, <&-
                    $i++ while $i < $n && substr($s, $i, 1) =~ /[\d-]/;
                    next;
                }
            }
            $skip = 1;    # the next word is the redirection's target
            next;
        }
        $w .= $c; $r .= $c; $in = 1; $i++;
    }
    $end_cmd->();
    return @cmds;
}

# simple_commands($command) -> shell_lex's commands plus, recursively, those
# inside `sh|bash|dash|zsh|ksh -c '<string>'` and `eval <words>`.
sub simple_commands {
    my ($cmd, $depth) = @_;
    $depth //= 0;
    my @out;
    for my $words (shell_lex($cmd)) {
        push @out, $words;
        next if $depth >= 3;
        my @t = map { $_->[0] } @$words;
        my $k = command_start(\@t);
        next if $k > $#t;
        (my $head = $t[$k]) =~ s{.*/}{};
        if ($head =~ /^(?:sh|bash|dash|zsh|ksh)$/) {
            for my $j ($k + 1 .. $#t - 1) {
                next unless $t[$j] =~ /^-[A-Za-z]*c[A-Za-z]*$/;
                push @out, simple_commands($t[$j + 1], $depth + 1);
                last;
            }
        } elsif ($head eq 'eval') {
            push @out, simple_commands(join(' ', @t[$k + 1 .. $#t]), $depth + 1);
        }
    }
    return @out;
}

# command_start(\@texts) -> index of the word that names the command: past
# VAR=value assignments, `{ ! if then else elif do while until`, and wrappers
# that run the rest of the line (sudo, env, nice, timeout, nohup, command,
# exec, time, xargs, ...) with their options.
sub command_start {
    my ($t) = @_;
    my $i = 0;
    while ($i < @$t) {
        my $h = $t->[$i];
        if ($h =~ /^[A-Za-z_][A-Za-z0-9_]*\+?=/s)                  { $i++; next }
        if ($h =~ /^(?:\{|!|if|then|else|elif|do|while|until)$/)  { $i++; next }
        (my $b = $h) =~ s{.*/}{};
        my $opts = $WRAPPER_ARG_OPTS{$b} or last;
        $i++;
        while ($i < @$t) {
            my $o = $t->[$i];
            if ($b eq 'env' && $o =~ /^[A-Za-z_][A-Za-z0-9_]*=/s) { $i++; next }
            last unless $o =~ /^-/;
            $i++;
            last if $o eq '--';
            $i++ if $opts->{$o};
        }
        $i++ if $b eq 'timeout' && $i < @$t;    # its DURATION operand
    }
    return $i;
}

# ── Proposal helpers ────────────────────────────────────────────────

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
    # A generated command can install hundreds of packages; the context stays readable.
    my $max = 25;
    my @shown = $n > $max ? @$decls[0 .. $max - 1] : @$decls;
    for my $d (@shown) {
        my $line = "  /backpack:add --category " . shesc($d->{category})
                 . " --name "    . shesc($d->{name})
                 . " --install " . shesc($d->{install})
                 . " --verify "  . shesc($d->{verify});
        $line .= " --rationale '<WHY: one line — what this is for, why this version>'";
        $msg .= "$line\n";
    }
    $msg .= "  ... and " . ($n - $max) . " more; record them with /backpack:add the same way if they should persist.\n"
        if $n > $max;
    return $msg;
}

# Single-quote a value for safe shell embedding: wrap in '…' and escape
# internal single quotes as '\''.
sub shesc {
    my $s = shift;
    $s =~ s/'/'\\''/g;
    return "'$s'";
}

# install_segments($command, $head_pattern) -> the simple commands of
# $command (sh -c and eval looked through) that start with $head_pattern once
# their sudo/env/VAR=value prefixes are dropped, each as its words' raw text
# (quotes kept, so the recorded install replays exactly as typed).
sub install_segments {
    my ($cmd, $head_pattern) = @_;
    my @hits;
    for my $words (simple_commands($cmd)) {
        my @t = map { $_->[0] } @$words;
        my $k = command_start(\@t);
        next if $k > $#t;
        my $seg = join ' ', map { $_->[1] } @{$words}[$k .. $#$words];
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
        # A simulated install installed nothing.
        next if $seg =~ /\s(?:-s|--simulate|--dry-run|--just-print|--no-act|--recon)(?:\s|$)/;
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
            # The version pin (if any) stays baked into $tok / the install
            # command — the schema no longer stores a separate version field.
            push @results, {
                category => 'apt',
                name     => $name,
                install  => "apt-get install -y $tok",
                verify   => "dpkg -s $name >/dev/null 2>&1",
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
            my ($name) = npm_split($tok);
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
            my ($name) = npm_split($tok);
            next unless defined $name;
            push @results, {
                category => 'npm-global',
                name     => $name,
                install  => "pnpm add -g $tok",
                # CLI-shim test plus package-dir fallback (same rationale as
                # the npm verify above).
                verify   => "command -v $name >/dev/null 2>&1 || test -d \"\$(pnpm root -g 2>/dev/null)/$name\"",
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
            my ($name) = npm_split($tok);
            next unless defined $name;
            push @results, {
                category => 'npm-global',
                name     => $name,
                install  => "yarn global add $tok",
                # CLI-shim test plus package-dir fallback. yarn global stores
                # packages under `yarn global dir`/node_modules/.
                verify   => "command -v $name >/dev/null 2>&1 || test -d \"\$(yarn global dir 2>/dev/null)/node_modules/$name\"",
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
            # Any version operator stays inside $tok / the install command.
            push @results, {
                category => 'pip',
                name     => $name,
                install  => "$tool install $tok",
                verify   => "$tool show $name >/dev/null 2>&1",
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
            my $install = "cargo install $pkg";
            $install .= " --version $explicit_version" if defined $explicit_version && !defined $name_version;
            push @results, {
                category => 'cargo',
                name     => $name,
                install  => $install,
                verify   => "cargo install --list 2>/dev/null | grep -q '^$name '",
            };
        }
    }
    return @results;
}
