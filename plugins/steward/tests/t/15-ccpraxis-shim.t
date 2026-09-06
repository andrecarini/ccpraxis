#!/usr/bin/env perl
# 15-ccpraxis-shim.t — the `ccpraxis` dispatcher shim and its install hook.
#
# WHY THIS EXISTS. The skills that drive steward's scripts spelled out a
# 70-character absolute path on every invocation. That works — the skill file
# carries it, so nothing is being remembered — but it is brittle prose: moving
# the tree edits every skill that names it, and a typo surfaces as "file not
# found" rather than anything diagnosable.
#
# The shim removes that, and in doing so walks straight into two of this
# repo's documented landmines, which is what most of these assertions are for.
#
# AC1  the shim exists on both surfaces, and the install hook that wires it
# AC2  the .ps1 is ASCII-ONLY (PowerShell 5.1 reads BOM-less UTF-8 as CP1252)
# AC3  every subcommand maps to a script that actually exists
# AC4  an unknown subcommand fails loudly rather than silently doing nothing
# AC5  arguments pass through untouched
# AC6  the install hook is discoverable by install.pl's plugins/* glob
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use StewardTest qw(ok is like unlike done_testing diag);

my $PLUGIN  = "$Bin/../..";
my $SH      = "$PLUGIN/bin/ccpraxis.sh";
my $PS1     = "$PLUGIN/bin/ccpraxis.ps1";
my $HOOK    = "$PLUGIN/ccpraxis-install.pl";
my $SCRIPTS = "$PLUGIN/scripts";

sub slurp {
    my ($p) = @_;
    open my $fh, '<:raw', $p or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

# --- AC1 -------------------------------------------------------------------
ok(-f $SH,   'AC1 the bash shim exists');
ok(-f $PS1,  'AC1 the PowerShell shim exists');
ok(-f $HOOK, 'AC1 the install hook exists');

# --- AC2: ASCII ONLY in the .ps1 -------------------------------------------
#
# Not a style rule. The Write tool saves UTF-8 without a BOM, and PowerShell
# 5.1 reads a BOM-less script as CP1252 — so an em dash decodes into stray
# bytes, one of which (0x94) is a smart quote that PowerShell treats as a
# STRING DELIMITER. That opens a phantom string, swallows the following
# braces, and reports a missing brace at a line far from the real one. The
# failure looks like a syntax error somewhere innocent.
{
    my $ps = slurp($PS1);
    ok(defined $ps, 'AC2 the .ps1 is readable') or do { done_testing(); exit };

    my @bad;
    my $line = 1;
    for my $ch (split //, $ps) {
        $line++ if $ch eq "\n";
        push @bad, "$line:" . sprintf('0x%02X', ord $ch) if ord($ch) > 0x7F;
    }
    is(scalar @bad, 0, 'AC2 the .ps1 contains no byte above 0x7F')
        or diag('  offending: ' . join(', ', @bad[0 .. ($#bad > 9 ? 9 : $#bad)])
              . "\n  PowerShell 5.1 reads this file as CP1252; 0x94 becomes a string delimiter");

    # The typographic forms specifically, since they are what a writer reaches
    # for and what the ASCII scan above exists to catch.
    unlike($ps, qr/\x{2014}|\x{2013}|\x{2192}|\x{201C}|\x{201D}/,
           'AC2 no em/en dash, arrow or smart quote in the .ps1');
}

# --- AC3: every subcommand resolves to a real script ------------------------
{
    my $sh = slurp($SH);
    ok(defined $sh, 'AC3 the bash shim is readable') or do { done_testing(); exit };

    my @pairs = $sh =~ /^\s*(\w[\w-]*)\)\s*shift;\s*SCRIPT="\$STEWARD\/([\w.-]+)"/mg;
    my %map;
    while (@pairs) { my $k = shift @pairs; my $v = shift @pairs; $map{$k} = $v }

    # Non-vacuity: a regex that matched nothing would make the loop below pass
    # by never running, which is exactly how a broken shim ships green.
    cmp_ok_ge(scalar keys %map, 4,
        'AC3 liveness: the shim declares the subcommands this test reasons about');

    for my $sub (sort keys %map) {
        ok(-f "$SCRIPTS/$map{$sub}",
           "AC3 subcommand '$sub' points at a script that exists ($map{$sub})");
    }

    # And the PowerShell side maps the SAME set. Two shims that drift are worse
    # than one, because the difference only shows on the other platform.
    my $ps = slurp($PS1);
    for my $sub (sort keys %map) {
        like($ps, qr/'\Q$sub\E'\s*\{/,
             "AC3 the .ps1 declares '$sub' too (the shims must not drift)");
    }
}

sub cmp_ok_ge { my ($got, $want, $name) = @_; ok(($got // 0) >= $want, $name)
                    or diag("  got " . ($got // 'undef') . ", wanted >= $want") }

# --- AC4 / AC5: behaviour, via the real shim --------------------------------
if (have_bash()) {
    my $out = `bash "$SH" no-such-subcommand 2>&1`;
    my $rc  = $? >> 8;
    isnt_zero($rc, 'AC4 an unknown subcommand exits non-zero');
    like($out, qr/unknown subcommand/, 'AC4 and says so');

    my $help = `bash "$SH" 2>&1`;
    like($help, qr/ccpraxis research/, 'AC4 bare invocation prints usage');

    # Passthrough: `research status` must reach update-research.pl and come
    # back as its JSON, not as the shim's own output.
    my $json = `bash "$SH" research status 2>/dev/null`;
    like($json, qr/"store"\s*:/, 'AC5 arguments pass through to the target script')
        or diag("  got: " . substr($json, 0, 200));
}

sub isnt_zero { my ($v, $n) = @_; ok(($v // 0) != 0, $n) }

my $HAVE_BASH;
sub have_bash {
    unless (defined $HAVE_BASH) {
        my $v = `bash -c "echo ok" 2>&1`;
        $HAVE_BASH = (($v // '') =~ /ok/) ? 1 : 0;
        diag('bash unavailable — shim behaviour assertions are not running') unless $HAVE_BASH;
    }
    return $HAVE_BASH;
}

# --- AC6: install.pl finds the hook without being told ----------------------
#
# install.pl globs plugins/*/ccpraxis-install.pl, so a new plugin hook needs no
# registration. Pinned because the alternative — an explicit list somewhere —
# is the thing that silently omits a surface.
{
    my $hook = slurp($HOOK);
    ok(defined $hook, 'AC6 the hook is readable');
    like(($hook // ''), qr/_install-bin-helper\.pl/,
         'AC6 the hook delegates to the shared PATH helper rather than editing PATH itself')
        or diag('  hand-rolled PATH edits corrupt non-ASCII entries; see the global CLAUDE.md');
    like(($hook // ''), qr/\$Bin\/bin/,
         'AC6 and points the helper at this plugin bin dir');

    my $install = slurp("$Bin/../../../../install.pl");
    like(($install // ''), qr{glob\("\$CCPRAXIS_DIR/plugins/\*"\)},
         'AC6 install.pl discovers plugin hooks by glob, so this one needs no registration');
}

done_testing();
