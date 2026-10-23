# BpHook::Guards::GuardContinuityState -- steers an agent away from
# hand-editing the continuity state directory (BpHook::state_dir()) and its
# own session transcript, toward the CLI that owns them (butler-continuity,
# butler-hold). Architecture: plugins/butler/docs/hook-architecture.md
# ("guard-continuity-state.sh" rows).
#
# GUIDANCE, NOT A SECURITY BOUNDARY (operator ruling 2026-10-23). This guard
# exists for a cooperating but fallible agent: it turns an easy slip (an
# `rm` of its own armed record, an `echo >>` into its transcript that would
# make `butler-continuity off` read as operator-typed) into a visible,
# explicit refusal. A malicious agent purposefully defeating the system is
# out of scope, so the matching below is deliberately simple and
# best-effort: substring tests for the two locations plus a short list of
# mutation shapes. Indirection (variables, eval, scripts, other tools)
# passes, and that is accepted.
#
# Rules, for every session and caller (main, coordinator, subagent):
#   1. Write/Edit/MultiEdit/NotebookEdit whose target resolves under
#      state_dir() -- except state_dir()/break-glass/, which the Stop gate
#      asks the agent to write with the Write tool -- or equals the
#      payload's own transcript_path: deny.
#   2. Bash whose command names one of those locations (the state dir, the
#      literal butler-state/continuity, the transcript path or its basename)
#      AND has a mutation shape (an output redirection, or rm/mv/cp/tee/
#      touch/truncate/ln/dd/install/chmod/unlink/rmdir in command position,
#      sed -i, perl -i): deny. Pure reads pass.
#
# run($p, @args) never calls exit, never dies on purpose, never spawns a
# process and never re-parses the payload. Prints only through
# BpHook::deny(@lines), at most 2 lines of at most 160 characters.
package BpHook::Guards::GuardContinuityState;
use strict;
use warnings;
use File::Basename qw(dirname);
use Cwd ();

my $SELF_DIR;
{
    my $f = __FILE__;
    $f = Cwd::abs_path($f) // $f;
    $SELF_DIR = dirname($f);
}
require "$SELF_DIR/../../BpHook.pm"
    unless grep { m{(?:^|/)BpHook\.pm$} } keys %INC;
require "$SELF_DIR/Common.pm"
    unless grep { m{(?:^|/)Guards/Common\.pm$} } keys %INC;
require "$SELF_DIR/Shell.pm"
    unless grep { m{(?:^|/)Guards/Shell\.pm$} } keys %INC;

my $L2 = 'Continuity state and the session transcript change only through butler-continuity and butler-hold; a hand edit skips the checks that keep them true.';

# Same auto rule as GuardBlueprintWrite: undef means case-insensitive on
# msys, MSWin32, cygwin and darwin. Tests may pin it.
our $CASE_INSENSITIVE;

sub _is_ci {
    return $CASE_INSENSITIVE ? 1 : 0 if defined $CASE_INSENSITIVE;
    return ($^O =~ /\A(?:msys|MSWin32|cygwin|darwin)\z/) ? 1 : 0;
}

# _norm($s) -> comparison form of a path or a command: UTF-8 bytes,
# backslashes as slashes, runs of slashes collapsed, ASCII case folded on a
# case-insensitive host.
sub _norm {
    my ($s) = @_;
    return undef unless defined $s && !ref($s) && length $s;
    my $v = BpHook::_to_bytes($s);
    $v =~ tr{\\}{/};
    $v =~ s{/{2,}}{/}g;
    $v =~ tr/A-Z/a-z/ if _is_ci();
    return $v;
}

# _path_forms($abs) -> the comparison forms a command may spell $abs in:
# C:/x and /c/x for a drive path, else the path itself.
sub _path_forms {
    my ($abs) = @_;
    my $c = BpHook::Guards::Common::canon($abs);
    return () unless defined $c && length $c;
    my @forms = ($c);
    push @forms, "/$1/$2" if $c =~ m{\A([a-z]):/(.*)\z}s;
    return map { _norm($_) } @forms;
}

sub _under {
    my ($path, $dir) = @_;
    return 0 unless defined $path && defined $dir && length $dir;
    return ($path eq $dir || index($path, "$dir/") == 0) ? 1 : 0;
}

# _locations($p, $cwd) -> (\@state_forms, \@transcript_forms, $basename).
sub _locations {
    my ($p, $cwd) = @_;
    my (@state, @tp, $base);
    my $sd = BpHook::state_dir();
    if (defined $sd && length $sd) {
        my $abs = BpHook::Guards::Common::resolve_path($sd, $cwd);
        @state = _path_forms($abs) if defined $abs;
    }
    my $tp = $p->{transcript_path};
    if (defined $tp && !ref($tp) && length $tp) {
        my $abs = BpHook::Guards::Common::resolve_path($tp, $cwd);
        if (defined $abs) {
            @tp = _path_forms($abs);
            ($base) = _norm($abs) =~ m{([^/]+)\z};
        }
    }
    return (\@state, \@tp, $base);
}

sub _deny {
    my ($what) = @_;
    return BpHook::deny(
        BpHook::Guards::Common::fit("CONTINUITY-STATE-GUARD: BLOCKED -- $what"),
        BpHook::Guards::Common::fit($L2),
    );
}

# ---------------------------------------------------------------------------
# Rule 1: an edit tool aimed at the state dir or the own transcript.
# ---------------------------------------------------------------------------
sub _edit_rule {
    my ($p, $tool, $cwd) = @_;
    my $ti = $p->{tool_input};
    return 0 unless ref $ti eq 'HASH';
    my $fp = $ti->{file_path};
    $fp = $ti->{notebook_path} if !defined $fp || ref($fp) || !length $fp;
    return 0 unless defined $fp && !ref($fp) && length $fp;

    my $abs = BpHook::Guards::Common::resolve_path($fp, $cwd);
    return 0 unless defined $abs && length $abs;
    my ($target) = _path_forms($abs);
    return 0 unless defined $target;

    my ($state, $tp) = _locations($p, $cwd);
    for my $dir (@$state) {
        next unless _under($target, $dir);
        return 0 if _under($target, "$dir/break-glass");
        return _deny("direct $tool refused: " . BpHook::Guards::Common::path_echo($abs));
    }
    for my $t (@$tp) {
        return _deny("direct $tool of the session transcript refused: " . BpHook::Guards::Common::path_echo($abs))
            if $target eq $t;
    }
    return 0;
}

# ---------------------------------------------------------------------------
# Rule 2: a Bash command that names a location and has a mutation shape.
# ---------------------------------------------------------------------------
my $VERB_RE = qr{(?:\A|[;&|(`\x7b\n]|\$\()\s*(?:(?:sudo|exec|command|nohup|xargs(?:\s+-\S+)*)\s+)*(?:/\S*/)?(?:rm|mv|cp|tee|touch|truncate|ln|dd|install|chmod|unlink|rmdir)(?=\s|\z)};
my $INPLACE_RE = qr{(?:\A|[\s;&|(`])(?:sed\s+(?:[^\s;&|]+\s+)*?-(?:-in-place|[a-zA-Z]*i)|perl\s+(?:[^\s;&|]+\s+)*?-(?![IMmeE])[a-zA-Z]*i)};

sub _mutates {
    my ($cmd) = @_;
    my $text = BpHook::Guards::Common::is_shell_or_eval_invocation($cmd)
        ? $cmd
        : BpHook::Guards::Shell::strip_noise($cmd);
    # Redirections that write nothing the guard cares about.
    $text =~ s{[0-9]*>&[0-9-]+}{ }g;
    $text =~ s{(?:&|[0-9]*)>>?\s*/dev/null\b}{ }g;
    return 1 if index($text, '>') >= 0;
    return 1 if $text =~ $VERB_RE;
    return 1 if $text =~ $INPLACE_RE;
    return 0;
}

sub _bash_rule {
    my ($p, $cwd) = @_;
    my $ti = $p->{tool_input};
    return 0 unless ref $ti eq 'HASH';
    my $cmd = $ti->{command};
    return 0 unless defined $cmd && !ref($cmd) && length $cmd;

    my $n = _norm($cmd);
    # The Stop gate's break-glass file sits under the state dir; naming it
    # is not naming continuity state.
    $n =~ s{/continuity/break-glass/}{/break-glass/}g;

    my ($state, $tp, $base) = _locations($p, $cwd);
    my $names = 0;
    for my $needle (@$state, 'butler-state/continuity', @$tp, (defined $base ? $base : ())) {
        next unless defined $needle && length $needle;
        if (index($n, $needle) >= 0) { $names = 1; last }
    }
    return 0 unless $names;
    return 0 unless _mutates($cmd);
    return _deny('Bash refused: ' . BpHook::Guards::Common::echo_cmd($cmd));
}

# ---------------------------------------------------------------------------
# run($p, @args) -> 0 | 2.
# ---------------------------------------------------------------------------
sub run {
    my ($p, @args) = @_;
    return 0 unless ref $p eq 'HASH';
    return 0 unless BpHook::payload_ok();

    my $tool = $p->{tool_name};
    return 0 unless defined $tool && !ref($tool) && length $tool;
    my $cwd = (defined $p->{cwd} && !ref($p->{cwd}) && length $p->{cwd}) ? $p->{cwd} : undef;

    my $rc = eval {
        return _edit_rule($p, $tool, $cwd) if $tool =~ /\A(?:Write|Edit|MultiEdit|NotebookEdit)\z/;
        return _bash_rule($p, $cwd) if $tool eq 'Bash';
        0;
    };
    return (defined $rc && $rc == 2) ? 2 : 0;
}

1;
