#!/usr/bin/env perl
# platform: any
# The node-pnpm recipe as the ONE way to get Node.js and pnpm in a sandbox,
# held by plugins/backpack/hooks/auto-declare.pl on three Bash hook events.
#
# The sandbox image ships no Node since 2026-10-30. An agent that decides it
# needs Node will not have read the backpack add skill, so prose cannot be what
# routes it to the recipe. Machinery does, at the three moments it matters:
#   A. registration: the container settings.json runs the hook on PreToolUse,
#      PostToolUse and PostToolUseFailure, and the hook's idea of where the
#      recipe's Node lives matches the recipe and the image PATH;
#   B-E. PreToolUse refuses every ad-hoc Node or pnpm install (apt, version
#      managers, installers, NodeSource, nodejs.org tarballs, corepack, global
#      pnpm, hand-written Node backpack items) and names the recipe, while
#      read-only and project-local commands, and quoted text that merely
#      mentions an install, pass untouched;
#   F. replays: items already in a backpack, klink's grandfathered
#      other/nvm+node22 among them, keep installing: the install pass is never
#      a Bash tool call the guard could see, and backpack.pl itself refuses
#      nothing;
#   G. PostToolUseFailure: a command that fails because node/npm/npx/pnpm/
#      corepack is missing gets the recipe named, with the right next step for
#      what the backpack already declares;
#   H. PostToolUse: an ad-hoc Node install that slipped through is never
#      proposed as a backpack item; the recipe is proposed instead. Plus the
#      proposal flow's own regressions fixed alongside (VAR=value prefixes,
#      pipes, newlines, a mojibake em dash);
#   I. the add skill's description, always in context, says recipes exist in
#      one clause, with no per-OS text.
# Every case feeds the real hook a payload fixture; no container, no network.
use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use File::Spec;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;
use Test::More;

binmode Test::More->builder->$_, ':encoding(UTF-8)' for qw(output failure_output todo_output);

my $ROOT     = File::Spec->rel2abs(File::Spec->catdir($Bin, '..', '..'));          # plugins/backpack
my $REPO     = File::Spec->rel2abs(File::Spec->catdir($ROOT, '..', '..'));
my $HOOK     = "$ROOT/hooks/auto-declare.pl";
my $BP       = "$ROOT/scripts/backpack.pl";
my $RECIPE_F = "$ROOT/recipes/node-pnpm.json";
my $SETTINGS = "$REPO/plugins/sandbox/container/settings.json";
my $CFILE    = "$REPO/plugins/sandbox/container/Containerfile";
for ($HOOK, $BP, $RECIPE_F, $SETTINGS, $CFILE) { -f $_ or BAIL_OUT("missing $_") }

my $tmp  = tempdir(CLEANUP => 1);
my $capn = 0;

sub slurp_raw {
    my ($p) = @_;
    open my $fh, '<:raw', $p or return '';
    local $/;
    my $c = <$fh>;
    close $fh;
    return defined $c ? $c : '';
}

sub spew_raw {
    my ($p, $c) = @_;
    open my $fh, '>:raw', $p or die "write $p: $!";
    print $fh $c;
    close $fh or die "close $p: $!";
}

# Capture through temp files, never an in-memory handle (Git-for-Windows perl).
sub run_with_stdin {
    my ($stdin, @cmd) = @_;
    my $n = ++$capn;
    my ($in, $out, $err) = map { File::Spec->catfile($tmp, "$_.$n") } qw(in out err);
    spew_raw($in, $stdin);
    open my $oi, '<&', \*STDIN  or die "dup STDIN: $!";
    open my $oo, '>&', \*STDOUT or die "dup STDOUT: $!";
    open my $oe, '>&', \*STDERR or die "dup STDERR: $!";
    open STDIN,  '<:raw', $in  or die "redirect STDIN: $!";
    open STDOUT, '>:raw', $out or die "redirect STDOUT: $!";
    open STDERR, '>:raw', $err or die "redirect STDERR: $!";
    my $rc = system(@cmd);
    open STDIN,  '<&', $oi or die "restore STDIN: $!";
    open STDOUT, '>&', $oo or die "restore STDOUT: $!";
    open STDERR, '>&', $oe or die "restore STDERR: $!";
    close $_ for $oi, $oo, $oe;
    return ($rc == -1 ? -1 : $rc >> 8, slurp_raw($out), slurp_raw($err));
}

# The recipe's bin directory as the hook sees it: a scratch directory per
# scenario, holding fake executables when a scenario needs the recipe's Node.
my $NO_NODE = File::Spec->catdir($tmp, 'recipe-absent', 'bin');
make_path($NO_NODE);
my $EMPTY_BP = File::Spec->catfile($tmp, 'no-backpack.json');    # never created

sub fake_bin {
    my ($name, @tools) = @_;
    my $dir = File::Spec->catdir($tmp, $name, 'bin');
    make_path($dir);
    for my $t (@tools) {
        my $p = File::Spec->catfile($dir, $t);
        spew_raw($p, "#!/bin/sh\nexit 0\n");
        chmod 0755, $p;
    }
    return $dir;
}

sub backpack_file {
    my ($name, @items) = @_;
    my $p = File::Spec->catfile($tmp, "$name.json");
    spew_raw($p, JSON::PP->new->utf8->canonical->pretty->encode({ version => 2, items => \@items }));
    return $p;
}

# hook(%o) -> { rc, out, err, json } for one payload.
#   event, command, error, is_interrupt  payload fields
#   bin       BACKPACK_RECIPE_NODE_BIN (default: a directory with no node)
#   backpack  BACKPACK_FILE (default: none)
sub hook {
    my (%o) = @_;
    my $payload = {
        session_id      => 'test',
        hook_event_name => $o{event} // 'PreToolUse',
        tool_name       => $o{tool} // 'Bash',
        tool_input      => { command => $o{command} // '' },
        tool_use_id     => 'toolu_test',
    };
    $payload->{error}        = $o{error}        if exists $o{error};
    $payload->{is_interrupt} = $o{is_interrupt} if exists $o{is_interrupt};
    $payload->{tool_response} = { stdout => '', stderr => '' } if ($o{event} // '') eq 'PostToolUse';
    local $ENV{BACKPACK_RECIPE_NODE_BIN} = $o{bin} // $NO_NODE;
    local $ENV{BACKPACK_FILE}            = $o{backpack} // $EMPTY_BP;
    my ($rc, $out, $err) = run_with_stdin(JSON::PP->new->utf8->encode($payload), $^X, $HOOK);
    my $json = length $out ? eval { JSON::PP->new->utf8->decode($out) } : undef;
    return { rc => $rc, out => $out, err => $err, json => $json };
}

sub decision { my ($r) = @_; return ($r->{json} // {})->{hookSpecificOutput} // {} }
sub context  { return decision($_[0])->{additionalContext} // '' }

my $RECIPE_LINE = qr{/backpack:add --recipe node-pnpm\b};

# ---------------------------------------------------------------------------
# A. Registration, and one recipe location everywhere.
# ---------------------------------------------------------------------------
{
    my $s = JSON::PP->new->utf8->decode(slurp_raw($SETTINGS));
    my $hooks = $s->{hooks} // {};
    my $want  = qr{auto-declare\.pl};
    my %cmd_for;
    for my $ev (qw(PreToolUse PostToolUse PostToolUseFailure)) {
        my @cmds = map  { $_->{command} // '' }
                   map  { @{ $_->{hooks} // [] } }
                   grep { ($_->{matcher} // '') eq 'Bash' } @{ $hooks->{$ev} // [] };
        my @ours = grep { $_ =~ $want } @cmds;
        is(scalar(@ours), 1, "A: the container settings.json runs auto-declare.pl once on $ev (matcher Bash)")
            or diag(explain($hooks->{$ev}));
        $cmd_for{$ev} = $ours[0] // '';
    }
    is($cmd_for{PreToolUse}, $cmd_for{PostToolUse},
       'A: PreToolUse uses the same command line as the existing PostToolUse registration');
    is($cmd_for{PostToolUseFailure}, $cmd_for{PostToolUse},
       'A: so does PostToolUseFailure (the hook dispatches on hook_event_name)');
    like($cmd_for{PreToolUse}, qr/^\[ -f "\$HOME\/\.claude\/auto-declare\.pl" \] && perl .* \|\| true$/,
         'A: the command no-ops when the mount is missing and never fails the call');

    my $recipe = JSON::PP->new->utf8->decode(slurp_raw($RECIPE_F))->{items}[0];
    my ($hook_bin) = slurp_raw($HOOK) =~ /\$ENV\{BACKPACK_RECIPE_NODE_BIN\}\s*\/\/\s*'([^']+)'/;
    ok(defined $hook_bin, 'A: the hook names a default recipe bin directory');
    is($hook_bin, ($recipe->{bin_dirs} // [])->[0],
       "A: the hook's recipe bin directory is the recipe's bin_dirs[0]");
    like(slurp_raw($CFILE), qr/^ENV PATH="\Q$hook_bin\E:/m,
         'A: and that directory is on the image PATH');
}

# ---------------------------------------------------------------------------
# B. PreToolUse refuses each ad-hoc Node or pnpm install, naming the recipe.
# ---------------------------------------------------------------------------
my @refused = (
    # [ command, what the reason must name ]
    [ 'apt-get install -y nodejs',                                         qr/apt-get install nodejs/ ],
    [ 'sudo apt install nodejs npm',                                       qr/apt install nodejs/ ],
    [ 'apt-get update && DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::=--force-confold install -y nodejs=18.19.0',
                                                                           qr/nodejs=18\.19\.0/ ],
    [ 'apt-get install -y -t bookworm-backports nodejs/bookworm-backports', qr/nodejs\/bookworm/ ],
    [ 'aptitude install npm',                                              qr/aptitude install npm/ ],
    [ 'curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash', qr/nvm installer/ ],
    [ 'git clone https://github.com/nvm-sh/nvm.git ~/.nvm',                qr/nvm installer/ ],
    [ '. ~/.nvm/nvm.sh && nvm install 22',                                 qr/nvm install/ ],
    [ 'nvm install --lts',                                                 qr/nvm install/ ],
    [ 'n lts',                                                             qr/\bn lts/ ],
    [ 'n 22.11.0',                                                         qr/\bn 22/ ],
    [ 'curl -L https://bit.ly/n-install | bash',                           qr/n installer/ ],
    [ 'fnm install 22',                                                    qr/fnm install/ ],
    [ 'fnm use --install-if-missing 22',                                   qr/fnm use/ ],
    [ 'curl -fsSL https://fnm.vercel.app/install | bash',                  qr/fnm installer/ ],
    [ 'volta install node@22',                                             qr/volta install/ ],
    [ 'curl https://get.volta.sh | bash',                                  qr/volta installer/ ],
    [ 'nodenv install 22.11.0',                                            qr/nodenv install/ ],
    [ 'asdf plugin add nodejs',                                            qr/asdf plugin nodejs/ ],
    [ 'mise use -g node@22',                                               qr/mise use node/ ],
    [ 'curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -', qr/NodeSource/ ],
    [ 'curl -fsSL https://nodejs.org/dist/v22.11.0/node-v22.11.0-linux-x64.tar.xz | tar -xJ -C /usr/local --strip-components=1',
                                                                           qr/nodejs\.org/ ],
    [ 'wget https://nodejs.org/dist/latest-v22.x/node-v22.11.0-linux-x64.tar.gz', qr/nodejs\.org/ ],
    [ 'curl -fsSLO https://unofficial-builds.nodejs.org/download/release/v22.11.0/node-v22.11.0-linux-x64-musl.tar.xz',
                                                                           qr/nodejs\.org/ ],
    # The recipe's own install, run by hand instead of through the backpack.
    [ 'T=node-v24.22.1-linux-x64.tar.xz && curl -fsSL "https://nodejs.org/dist/v24.22.1/$T" -o "/tmp/$T"',
                                                                           qr/nodejs\.org/ ],
    [ 'npm install -g pnpm@9.15.0',                                        qr/npm install -g pnpm\@9\.15\.0/ ],
    [ 'npm install --global pnpm',                                         qr/npm install -g pnpm/ ],
    [ 'npm i --location=global @pnpm/exe',                                 qr/\@pnpm\/exe/ ],
    [ 'npm i -g n',                                                        qr/npm i -g n\b/ ],
    [ 'npm install -g node@22',                                            qr/node\@22/ ],
    [ 'npm i -g corepack',                                                 qr/corepack/ ],
    [ 'pnpm add -g pnpm',                                                  qr/pnpm add -g pnpm/ ],
    [ 'pnpm self-update',                                                  qr/pnpm self-update/ ],
    [ 'pnpm env use --global 22',                                          qr/pnpm env use/ ],
    [ 'yarn global add pnpm',                                              qr/yarn global add pnpm/ ],
    [ 'npx pnpm install',                                                  qr/npx pnpm/ ],
    [ 'npx -y pnpm@9 install',                                             qr/npx pnpm\@9/ ],
    [ 'npm exec --package=pnpm -- pnpm install',                           qr/npx pnpm/ ],
    [ 'npx node@22 --version',                                             qr/npx node\@22/ ],
    [ 'curl -fsSL https://get.pnpm.io/install.sh | sh -',                  qr/pnpm standalone installer/ ],
    # Looked through: shells, eval, wrappers.
    [ q{bash -c 'apt-get install -y nodejs'},                              qr/apt-get install nodejs/ ],
    [ q{sudo sh -c "curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -"}, qr/NodeSource/ ],
    [ 'bash -lc "nvm install 22"',                                         qr/nvm install/ ],
    [ 'eval apt-get install -y nodejs',                                    qr/apt-get install nodejs/ ],
    [ 'env DEBIAN_FRONTEND=noninteractive timeout 600 nice -n 5 apt-get install -y nodejs', qr/apt-get install nodejs/ ],
    [ "cd /project\napt-get install -y nodejs",                            qr/apt-get install nodejs/ ],
    # A stray backpack.pl operand does not short-circuit the other rules.
    [ 'apt-get install -y nodejs backpack.pl',                             qr/apt-get install nodejs/ ],
    # What the refusal echoes is cleaned of control characters.
    [ "apt-get install -y 'nodejs=18\e[2J'",                               qr/nodejs=18 \[2J/ ],
    # Red-team round: shapes the first matrix missed.
    [ 'npm i -gf pnpm',                                                    qr/npm i -g pnpm/ ],
    [ 'n -a x64 lts',                                                      qr/\bn lts/ ],
    [ 'npx n lts',                                                         qr/npx n\b/ ],
    [ 'mise install pnpm',                                                 qr/mise install pnpm/ ],
    [ 'git clone https://github.com/nodenv/nodenv.git ~/.nodenv',          qr/nodenv installer/ ],
    [ 'git clone https://github.com/tj/n',                                 qr/n installer/ ],
    [ 'curl -fsSL https://raw.githubusercontent.com/tj/n/master/bin/n -o n', qr/n installer/ ],
    [ 'nodeenv -n lts env',                                                qr/nodeenv/ ],
    [ 'python3 -m nodeenv env',                                            qr/nodeenv/ ],
    [ 'pip install nodejs-bin',                                            qr/pip install nodejs-bin/ ],
    [ 'apt-get install -y ./nodejs_22.11.0-1nodesource1_amd64.deb',        qr/\.deb installed by hand/ ],
    [ 'dpkg -i nodejs_22.11.0-1_amd64.deb',                                qr/dpkg -i nodejs_/ ],
);
for my $case (@refused) {
    my ($cmd, $what) = @$case;
    (my $label = $cmd) =~ s/\n/\\n/g;
    $label =~ s/[\x00-\x1f\x7f]/?/g;
    my $r = hook(command => $cmd);
    my $d = decision($r);
    is($r->{rc}, 0, "B: exits 0: $label");
    is($d->{permissionDecision} // '', 'deny', "B: refused: $label")
        or diag("stdout: $r->{out}\nstderr: $r->{err}");
    is($d->{hookEventName} // '', 'PreToolUse', "B: answers as PreToolUse: $label");
    my $why = $d->{permissionDecisionReason} // '';
    like($why, $what, "B: the reason names what was refused: $label");
    like($why, $RECIPE_LINE, "B: the reason names the one way, the node-pnpm recipe: $label");
    like($why, qr{/backpack:install}, "B: and the install step after it: $label");
}

# ---------------------------------------------------------------------------
# C. Everything else passes untouched: no output at all.
# ---------------------------------------------------------------------------
my @allowed = (
    'node --version', 'npm --version', 'npm ls', 'npm ls -g --depth=0', 'npm ci', 'npm install',
    'npm install -D vite@5.4.0', 'npm run build', 'npx vite build', 'npx node --version',
    'pnpm install', 'pnpm install --frozen-lockfile', 'pnpm add -D vitest', 'pnpm run test',
    'npm i -g typescript@5.6.3', 'pnpm add -g serve', 'yarn install', 'npm install -g npm@11.6.2',
    'nvm use 22 && npm run build', 'nvm ls', 'source ~/.nvm/nvm.sh', 'corepack --version',
    'apt-get install -y jq', 'apt-get install -y node-gyp build-essential', 'apt-get remove -y nodejs npm',
    'apt-cache policy nodejs', 'dpkg -s nodejs',
    'curl -s https://nodejs.org/dist/index.json | head -c 400',
    'curl -sO https://nodejs.org/dist/v24.22.1/SHASUMS256.txt',
    'curl -s https://nodejs.org/dist/v24.22.1/',
    'git status', 'ls node_modules/.bin', 'cat package.json', 'echo -n done',
    # Quoted text, comments and here-document bodies are data, not commands.
    'echo "apt-get install nodejs"',
    q{git commit -m "guard: deny apt-get install nodejs; nvm install 22; npm i -g pnpm"},
    "git commit -F - <<'MSG'\napt-get install -y nodejs is refused\nnvm install 22 too\nMSG",
    "cat > notes.md <<EOF\napt-get install nodejs\ncurl https://deb.nodesource.com/setup_22.x | bash\nEOF\nls",
    "cat <<-EOF > x\n\tnvm install 22\n\tEOF",
    'ls # apt-get install nodejs',
    q{grep -rn 'nvm install' docs/},
    'cat /root/.claude/backpack.pl',
    # Red-team round: reading about a tool is not installing it.
    'curl https://raw.githubusercontent.com/nvm-sh/nvm/master/README.md',
    'curl -s https://api.github.com/repos/nvm-sh/nvm/releases/latest',
    'curl -s https://api.github.com/repos/volta-cli/volta/releases',
    'curl https://github.com/tj/n/issues',
    'curl -s https://fnm.vercel.app/',
    'git clone https://github.com/nvm-sh/nvm-docs',
    'curl -s https://nodejs.org/dist/v22.11.0/docs/api/fs.html',
    'curl -sI https://nodejs.org/dist/v22.11.0/node-v22.11.0-linux-x64.tar.xz',
    'wget --spider https://nodejs.org/dist/v22.11.0/node-v22.11.0-linux-x64.tar.xz',
    'curl -sO https://nodejs.org/dist/v22.11.0/node-v22.11.0-headers.tar.gz',
    'curl -sO https://nodejs.org/dist/v22.11.0/node-v22.11.0-linux-x64.tar.xz.asc',
    'curl -s https://nodesource.com/blog',
    'curl -s https://deb.nodesource.com/',
    'apt-get install -s nodejs',
    'apt-get download nodejs',
    'nodeenv --node=system env',
    'pip install nodeenv',
    'xargs -n 1 echo',
);
for my $cmd (@allowed) {
    (my $label = $cmd) =~ s/\n/\\n/g;
    $label =~ s/[\x00-\x1f\x7f]/?/g;
    my $r = hook(command => $cmd);
    is($r->{rc}, 0, "C: exits 0: $label");
    is($r->{out}, '', "C: passes untouched: $label")
        or diag("stdout: $r->{out}");
}

# ---------------------------------------------------------------------------
# D. corepack: refused without the recipe's Node; next to it, only for pnpm.
# ---------------------------------------------------------------------------
{
    my $with_node = fake_bin('recipe-present', qw(node npm npx corepack pnpm));
    for my $cmd ('corepack enable', 'corepack enable yarn', 'corepack prepare yarn@4.5.0 --activate') {
        my $d = decision(hook(command => $cmd));
        is($d->{permissionDecision} // '', 'deny', "D: without the recipe's Node: refused: $cmd");
        like($d->{permissionDecisionReason} // '', qr/does not have yet/, "D: and says the recipe's Node is missing: $cmd");
    }
    for my $cmd ('corepack enable', 'corepack enable pnpm', 'corepack prepare pnpm@9.15.0 --activate', 'corepack use pnpm@9') {
        my $d = decision(hook(command => $cmd, bin => $with_node));
        is($d->{permissionDecision} // '', 'deny', "D: next to the recipe's Node: refused (pnpm is the recipe's): $cmd");
        like($d->{permissionDecisionReason} // '', qr/pnpm already comes pinned from the recipe/, "D: with the pnpm reason: $cmd");
    }
    for my $cmd ('corepack enable yarn', 'corepack prepare yarn@4.5.0 --activate', 'corepack --version') {
        my $r = hook(command => $cmd, bin => $with_node);
        is($r->{out}, '', "D: next to the recipe's Node: allowed: $cmd");
    }
}

# ---------------------------------------------------------------------------
# E. backpack.pl add: Node and pnpm enter the backpack only through --recipe.
# ---------------------------------------------------------------------------
{
    my $skill_bp = q{perl "${CLAUDE_SKILL_DIR}/../../scripts/backpack.pl" add "$HOME/.claude/backpack.json"};
    my $mount_bp = q{perl /root/.claude/backpack.pl add /root/.claude/backpack.json};
    my $tarball  = q{curl -fsSL "https://nodejs.org/dist/v22.11.0/$T" -o "/tmp/$T" && echo "$S  /tmp/$T" | sha256sum -c -};
    my @deny = (
        [ "$mount_bp --category apt --name nodejs --install 'apt-get install -y nodejs' --verify 'dpkg -s nodejs'", qr/apt-get install nodejs/ ],
        [ "$mount_bp --category other --name nvm+node22 --install 'curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash' --verify 'node -v'",
                                                                                                        qr/nvm installer/ ],
        # The old "copy the recipe as a template" path, without --recipe.
        [ "$skill_bp --category other --name node22 --install '$tarball' --verify 'node -v'",            qr/nodejs\.org/ ],
        [ "$mount_bp --category other --name js-runtime --install='$tarball' --verify 'node -v'",        qr/nodejs\.org/ ],
        # A Node item by name, whatever its install does.
        [ "$mount_bp --category other --name node --install './scripts/get-node.sh' --verify 'node -v'", qr/named 'node'/ ],
        [ "$mount_bp --category npm-global --name pnpm --install './x.sh' --verify 'pnpm -v'",           qr/named 'pnpm'/ ],
        [ "$mount_bp --category other --name Node-22 --install './x.sh' --verify 'true'",                qr/named 'Node-22'/ ],
        # Under --recipe, an override may change the version, never the route.
        [ "$mount_bp --recipe node-pnpm --install 'apt-get install -y nodejs'",                          qr/apt-get install nodejs/ ],
        [ "$mount_bp --recipe node-pnpm --install 'nvm install 22'",                                     qr/nvm install/ ],
        [ "backpack.pl add bp.json --category apt --name npm --install 'apt-get install -y npm' --verify true", qr/apt-get install npm/ ],
    );
    for my $case (@deny) {
        my ($cmd, $what) = @$case;
        my $d = decision(hook(command => $cmd));
        is($d->{permissionDecision} // '', 'deny', "E: refused: $cmd");
        my $why = $d->{permissionDecisionReason} // '';
        like($why, qr/backpack item that brings Node or pnpm outside the node-pnpm recipe/, "E: as a backpack item: $cmd");
        like($why, $what, "E: naming what it does: $cmd");
        like($why, qr/keep --recipe node-pnpm and override --name, --install and --verify/,
             "E: and how to pin another major through the recipe: $cmd");
    }
    my @allow = (
        "$skill_bp --recipe node-pnpm --rationale 'Vite build'",
        "$mount_bp --rec node-pnpm",
        "$mount_bp -recipe=node-pnpm --rationale x",
        # Another major, through the recipe.
        "$mount_bp --recipe node-pnpm --name node22+pnpm --install '$tarball' --verify 'node -v'",
        "$mount_bp --category apt --name jq --install 'apt-get install -y jq' --verify 'dpkg -s jq >/dev/null 2>&1'",
        "$mount_bp --category npm-global --name typescript --install 'npm install -g typescript\@5.6.3' --verify 'command -v tsc'",
        "$mount_bp --category project-setup --name node-modules --install 'cd /project && npm ci' --verify 'test -d /project/node_modules'",
        # The item bp-fast-store.sh prints for a pnpm project.
        "$mount_bp --category project-setup --name pnpm-install-myapp --install 'cd \"/project\" && pnpm install --frozen-lockfile' --verify 'cd /project && test -d node_modules'",
        q{perl /root/.claude/backpack.pl remove /root/.claude/backpack.json --category other --name nvm+node22},
        q{perl /root/.claude/backpack.pl list /root/.claude/backpack.json},
    );
    for my $cmd (@allow) {
        is(hook(command => $cmd)->{out}, '', "E: allowed: $cmd");
    }
}

# ---------------------------------------------------------------------------
# F. Replays keep working, grandfathered items included.
# ---------------------------------------------------------------------------
# klink's item as recorded on 2026-06-03, before the recipe existed (copied
# here; the test never reads the operator's vault).
my $KLINK_NVM = {
    added     => '2026-06-03',
    category  => 'other',
    name      => 'nvm+node22',
    install   => 'curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash && export NVM_DIR="$HOME/.nvm" && . "$NVM_DIR/nvm.sh" && nvm install 22 --lts && mkdir -p ~/.local/bin && for b in node npm npx corepack; do ln -sf "$(nvm which 22 | xargs dirname)/$b" "$HOME/.local/bin/$b"; done',
    rationale => 'Klink is a Vite + Svelte 5 + TS + vitest project; Node 22 LTS is the runtime for dev/build/test.',
    verify    => 'command -v node && node -v | grep -E "^v22\."',
};
{
    # The two ways an install pass is started, exactly as their sources write
    # them: /backpack:install's skill (a Bash tool call) and the launcher (podman
    # exec, which never reaches a Claude Code hook; checked anyway).
    my ($skill_cmd) = slurp_raw("$ROOT/skills/install/SKILL.md") =~ /^(perl "\$\{CLAUDE_SKILL_DIR\}[^\n]*backpack\.pl" install [^\n]*)$/m;
    ok(defined $skill_cmd, 'F: found the install command in skills/install/SKILL.md') or diag('pattern drifted');
    my ($launcher_cmd) = slurp_raw("$REPO/plugins/sandbox/scripts/launcher.pl") =~ /^(perl \/root\/\.claude\/backpack\.pl install [^\n]*)$/m;
    ok(defined $launcher_cmd, "F: found the launcher's install-pass command") or diag('pattern drifted');
    my $bpf = backpack_file('klink-like', $KLINK_NVM);
    for my $cmd (grep { defined } $skill_cmd, $launcher_cmd) {
        is(hook(command => $cmd, backpack => $bpf)->{out}, '', "F: the guard lets the install pass start: $cmd");
        is(hook(command => $cmd, backpack => $bpf, event => 'PostToolUse')->{out}, '',
           "F: and the proposal flow has nothing to say about it: $cmd");
    }

    # backpack.pl itself refuses nothing: the grandfathered item validates and
    # replays. verify is swapped for `true` so the pass SKIPs instead of
    # running the real installer (no network); the install text is klink's own.
    my ($rc, $out) = run_with_stdin('', $^X, $BP, 'validate', $bpf);
    is($rc, 0, "F: backpack.pl validate accepts klink's other/nvm+node22 item") or diag($out);
    my $replay = backpack_file('klink-replay', { %$KLINK_NVM, verify => 'true' });
    my $profile = File::Spec->catfile($tmp, 'profile.sh');
    ($rc, $out) = run_with_stdin('', $^X, $BP, 'install', $replay, '--profile-path', $profile);
    is($rc, 0, 'F: backpack.pl install runs the grandfathered item without refusing it') or diag($out);
    like($out, qr/^SKIP: other:nvm\+node22/m, 'F: and reports it present (verify passed)') or diag($out);
    unlike($out, qr/recipe|refus/i, 'F: no recipe enforcement leaked into the install pass') or diag($out);

    # Running that same installer by hand is a different thing: refused.
    is(decision(hook(command => $KLINK_NVM->{install}))->{permissionDecision} // '', 'deny',
       "F: klink's install line typed as a Bash command is refused (it is not a replay)");
}

# ---------------------------------------------------------------------------
# G. PostToolUseFailure: a missing Node tool gets the recipe named.
# ---------------------------------------------------------------------------
{
    my %fail = (event => 'PostToolUseFailure', command => 'npm run build');
    my @shapes = (
        [ "Exit code 127\nbash: line 1: npm: command not found\n",               'npm' ],
        [ "Exit code 127\n/bin/bash: line 3: node: command not found",           'node' ],
        [ "Exit code 127\nsh: 1: pnpm: not found\n",                             'pnpm' ],
        [ "Exit code 127\nzsh: command not found: npx",                          'npx' ],
        [ "Exit code 127\n/usr/bin/env: \x{2018}node\x{2019}: No such file or directory", 'node' ],
        [ "Exit code 127\n/usr/bin/env: 'node': No such file or directory",      'node' ],
        [ "make: npm: No such file or directory\nmake: *** [Makefile:3: build] Error 127", 'npm' ],
        [ "Exit code 127\nbash: corepack: command not found",                    'corepack' ],
        [ "Exit code 127\nbash: nodejs: command not found",                      'node' ],
    );
    for my $s (@shapes) {
        my ($err, $tool) = @$s;
        (my $label = $err) =~ s/\n/\\n/g;
        my $r = hook(%fail, error => $err);
        my $d = decision($r);
        is($r->{rc}, 0, "G: exits 0: $label");
        is($d->{hookEventName} // '', 'PostToolUseFailure', "G: answers as PostToolUseFailure: $label");
        my $c = $d->{additionalContext} // '';
        like($c, qr/`\Q$tool\E` is missing/, "G: names the missing tool ($tool): $label");
        like($c, qr/ships no Node\.js/, "G: says the image has no Node: $label");
        like($c, $RECIPE_LINE, "G: names the recipe: $label");
        like($c, qr{then /backpack:install}, "G: and the install step: $label");
    }
    for my $err ("Exit code 127\nbash: line 1: jq: command not found",
                 "Exit code 1\ncat: node: No such file or directory",
                 "Exit code 1\nnpm error 404 Not Found - GET https://registry.npmjs.org/nope - Not found",
                 "Exit code 2\nmake: *** No rule to make target 'node'.  Stop.") {
        (my $label = $err) =~ s/\n/\\n/g;
        is(hook(%fail, error => $err)->{out}, '', "G: silent for an unrelated failure: $label");
    }
    is(hook(%fail, error => "Exit code 130\nbash: node: command not found", is_interrupt => JSON::PP::true)->{out}, '',
       'G: silent for an interrupted command');

    # What the backpack already declares changes the next step.
    my $recipe = JSON::PP->new->utf8->decode(slurp_raw($RECIPE_F))->{items}[0];
    my $declared = backpack_file('recipe-declared', { %$recipe, bin_dirs => [$NO_NODE] });
    my $c = context(hook(%fail, error => "bash: node: command not found", backpack => $declared));
    like($c, qr/declares Node through the node-pnpm recipe \('node\+pnpm'\).*not installed it yet: run \/backpack:install/s,
         'G: recipe declared but not installed here: run /backpack:install');
    unlike($c, $RECIPE_LINE, 'G: and does not ask to add it again');

    my $bin_with_pnpm = fake_bin('pnpm-off-path', qw(node npm npx corepack pnpm));
    $c = context(hook(%fail, error => "bash: pnpm: command not found", bin => $bin_with_pnpm));
    like($c, qr/installed at \Q$bin_with_pnpm\E\/pnpm, but \Q$bin_with_pnpm\E is not on this shell's PATH/,
         'G: the tool is in the recipe bin directory: a PATH problem, said as one');

    my $bin_npm_only = fake_bin('npm-only', qw(node npm npx corepack));
    $c = context(hook(%fail, error => "bash: pnpm: command not found", bin => $bin_npm_only, backpack => $declared));
    like($c, qr/declared without pnpm\. Add it again from the recipe/, "G: the recipe's Node without pnpm: re-add from the recipe");
    like($c, $RECIPE_LINE, 'G: with the recipe line');

    my $klink = backpack_file('klink-hint', $KLINK_NVM);
    $c = context(hook(%fail, error => "sh: 1: pnpm: not found", backpack => $klink));
    like($c, qr/Node item 'nvm\+node22' did not come from the node-pnpm recipe and brings no pnpm/,
         "G: a grandfathered Node item and no pnpm: names the item");
    like($c, qr{/backpack:remove --category 'other' --name 'nvm\+node22'}, 'G: says how to replace it');
    like($c, $RECIPE_LINE, 'G: with the recipe');
    $c = context(hook(%fail, error => "bash: node: command not found", backpack => $klink));
    like($c, qr/declares Node as 'nvm\+node22'.*\/backpack:install replays it/s,
         'G: a grandfathered Node item whose node is missing: replay it, do not replace it');
    unlike($c, $RECIPE_LINE, 'G: and no recipe push for a replayable item');

    # The recipe declared with its pnpm step, Node in place, pnpm not: the
    # step did not finish, so the answer is to install, not to re-add.
    my $bin_half = fake_bin('half-installed', qw(node npm npx corepack));
    my $declared_here = backpack_file('declared-here', { %$recipe, bin_dirs => [$bin_half] });
    $c = context(hook(%fail, error => "bash: pnpm: command not found", bin => $bin_half, backpack => $declared_here));
    like($c, qr/recipe item \('node\+pnpm'\) installs pnpm, but that step has not completed.*run \/backpack:install/s,
         'G: recipe declared with pnpm, pnpm absent: run /backpack:install');

    # Only a shell's own "not found" counts, and only for this machine.
    is(hook(%fail, error => "npm ERR! code E404 npm: not found")->{out}, '',
       'G: silent for a tool message that merely ends in "npm: not found"');
    is(hook(%fail, command => q{ssh build-host 'node -v'}, error => "bash: node: command not found")->{out}, '',
       'G: silent when the command ran on another machine (ssh)');
    like(context(hook(%fail, error => "./scripts/build.sh: line 3: npm: command not found")), qr/`npm` is missing/,
         "G: a script's own 'command not found' counts");
}

# ---------------------------------------------------------------------------
# H. PostToolUse: a Node install that slipped through is never proposed.
# ---------------------------------------------------------------------------
{
    my %post = (event => 'PostToolUse');
    my $r = hook(%post, command => 'apt-get install -y nodejs');
    my $c = context($r);
    is(decision($r)->{hookEventName} // '', 'PostToolUse', 'H: answers as PostToolUse');
    unlike($c, qr/--name 'nodejs'/, 'H: apt nodejs is not proposed as a backpack item');
    like($c, qr/outside the node-pnpm recipe \(apt-get install nodejs\)/, 'H: says what happened');
    like($c, $RECIPE_LINE, 'H: proposes the recipe instead');

    $c = context(hook(%post, command => 'apt-get install -y jq nodejs'));
    like($c, qr/--name 'jq' --install 'apt-get install -y jq'/, 'H: other packages of the same command are still proposed');
    unlike($c, qr/--name 'nodejs'/, 'H: but not nodejs');
    like($c, $RECIPE_LINE, 'H: and the recipe is proposed alongside');

    $c = context(hook(%post, command => 'npm i -g pnpm typescript@5.6.3'));
    like($c, qr/--name 'typescript'/, 'H: npm -g typescript is proposed');
    unlike($c, qr/--name 'pnpm'/, 'H: npm -g pnpm is not');
    like($c, $RECIPE_LINE, 'H: the recipe is');

    $c = context(hook(%post, command => 'curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash'));
    like($c, $RECIPE_LINE, 'H: a shape no parser proposes (the nvm installer) still gets the recipe proposed');

    $c = context(hook(%post, command => "perl /root/.claude/backpack.pl add /root/.claude/backpack.json --category apt --name nodejs --install 'apt-get install -y nodejs' --verify true"));
    like($c, qr/recorded Node or pnpm in the backpack without the node-pnpm recipe.*\/backpack:remove/s,
         'H: a hand-written Node item that got recorded: remove it, add the recipe');

    my $recipe = JSON::PP->new->utf8->decode(slurp_raw($RECIPE_F))->{items}[0];
    $c = context(hook(%post, command => 'apt-get install -y nodejs', backpack => backpack_file('post-declared', { %$recipe, bin_dirs => [$NO_NODE] })));
    like($c, qr/already declares the recipe \('node\+pnpm'\), so there is nothing to record/,
         'H: with the recipe already declared: nothing to record');
    unlike($c, $RECIPE_LINE, 'H: and no second recipe proposal');

    is(hook(%post, command => q{perl "${CLAUDE_SKILL_DIR}/../../scripts/backpack.pl" add "$HOME/.claude/backpack.json" --recipe node-pnpm})->{out}, '',
       'H: adding the recipe itself draws no proposal');

    # Proposal-flow regressions fixed alongside, and the existing shape kept.
    $c = context(hook(%post, command => 'apt-get install -y jq'));
    is($c, "[backpack] Detected 1 install-shape item in that Bash call that aren't tracked yet. "
         . "Decide whether each should persist to the next container rebuild. To track an item, run its pre-filled "
         . "/backpack:add with a real rationale; skip any that were one-offs (you'll be prompted again if you install them again later).\n\n"
         . "  /backpack:add --category 'apt' --name 'jq' --install 'apt-get install -y jq' --verify 'dpkg -s jq >/dev/null 2>&1' "
         . "--rationale '<WHY: one line \x{2014} what this is for, why this version>'\n",
       'H: an ordinary install is proposed exactly as before, its em dash one character (it was mojibake)');
    like(context(hook(%post, command => 'DEBIAN_FRONTEND=noninteractive apt-get install -y jq')), qr/--name 'jq'/,
         'H: a VAR=value prefix no longer hides an install');
    unlike(context(hook(%post, command => 'apt-get install -y jq | tee /tmp/log')), qr/--name 'tee'/,
           'H: a pipe no longer turns the next command into a package');
    like(context(hook(%post, command => "apt-get update\napt-get install -y jq")), qr/--name 'jq'/,
         'H: an install on a later line is seen');
    is(hook(%post, command => 'echo "apt-get install -y jq"')->{out}, '', 'H: quoted text is not an install');
    like(context(hook(%post, command => 'sudo -E apt install -y tree')), qr/--install 'apt-get install -y tree'/,
         'H: sudo still stripped from what gets recorded');
    is(hook(%post, command => 'apt-get install -s jq')->{out}, '', 'H: a simulated apt install is not proposed');
    $c = context(hook(%post, command => 'apt-get install -y ' . join(' ', map { "pkg$_" } 1 .. 30)));
    my @lines = $c =~ m{^  /backpack:add }mg;
    is(scalar(@lines), 25, 'H: at most 25 proposals are listed');
    like($c, qr/\.\.\. and 5 more/, 'H: and the rest are counted');
}

# ---------------------------------------------------------------------------
# B2. The refusal's next step follows what the container already has.
# ---------------------------------------------------------------------------
{
    my $installed = fake_bin('recipe-installed', qw(node npm npx corepack pnpm));
    my $why = decision(hook(command => 'nvm install 22', bin => $installed))->{permissionDecisionReason} // '';
    like($why, qr/already installed here, in \Q$installed\E \(on PATH\): use them/,
         "B2: the recipe's Node is installed: says so, and to use it");
    like($why, qr/another Node major, add the recipe again with --name, --install and --verify overridden/,
         'B2: and how another major goes through the recipe');
    unlike($why, qr/come from one place/, 'B2: rather than the first-time pitch');

    my $recipe = JSON::PP->new->utf8->decode(slurp_raw($RECIPE_F))->{items}[0];
    my $declared = backpack_file('b2-declared', { %$recipe, bin_dirs => [$NO_NODE] });
    $why = decision(hook(command => 'apt-get install -y nodejs', backpack => $declared))->{permissionDecisionReason} // '';
    like($why, qr/already declares Node through the node-pnpm recipe \('node\+pnpm'\).*run \/backpack:install/s,
         'B2: declared but not installed: run /backpack:install');
    unlike($why, $RECIPE_LINE, 'B2: without asking to add it again');
}

# ---------------------------------------------------------------------------
# I. The add skill's description: recipes exist, in one clause, no OS text.
# ---------------------------------------------------------------------------
{
    my ($desc) = slurp_raw("$ROOT/skills/add/SKILL.md") =~ /^description:\s*(.+)$/m;
    ok(defined $desc, 'I: the add skill has a description');
    $desc //= '';
    my @mentions = $desc =~ /recipe/gi;
    ok(@mentions >= 1 && @mentions <= 2, 'I: the description mentions recipes, briefly') or diag($desc);
    like($desc, qr/--recipe node-pnpm/, 'I: naming the Node recipe by its flag');
    unlike($desc, qr/\b(?:Windows|macOS|darwin|Linux|WSL|podman)\b/i, 'I: with no per-OS text');
}

done_testing();
