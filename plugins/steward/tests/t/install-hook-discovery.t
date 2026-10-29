#!/usr/bin/env perl
# platform: any
# install.pl discovers every surface's ccpraxis-install.pl even when the live
# install sits under a path with a space in it.
#
# WHY. Discovery used the builtin glob(), which splits its PATTERN on
# whitespace: under '/Users/Jane Doe/.claude/ccpraxis' (or 'C:/Users/John
# Smith/...') it found nothing, printed "No ccpraxis-install.pl hooks found",
# and exited 0 -- an install that silently did nothing. Same defect, same fix
# (bsd_glob) as _install-bin-helper.pl's B3.
#
# HERMETIC: a copy of install.pl and two stub hooks in a tempdir; plan mode
# only, and the stubs only print.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

my $INSTALL = "$Bin/../../../../install.pl";
ok(-f $INSTALL, 'install.pl exists') or BAIL_OUT('install.pl missing');

my $root = tempdir(CLEANUP => 1) . '/live install with spaces';
make_path("$root/plugins/alpha", "$root/plugins/beta", "$root/skills/gamma");
sub write_file { my ($p, $c) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $c; close $fh; }
{
    open my $in, '<:raw', $INSTALL or die $!;
    local $/;
    write_file("$root/install.pl", <$in>);
}
for my $s (qw(plugins/alpha plugins/beta skills/gamma)) {
    (my $name = $s) =~ s{.*/}{};
    write_file("$root/$s/ccpraxis-install.pl",
        "#!/usr/bin/env perl\n# ccpraxis-install.pl -- stub\n# stub hook $name\nprint \"  STUB $name \$ARGV[0]\\n\";\n");
}

delete local $ENV{CLAUDECODE};
my $out = `"$^X" "$root/install.pl" 2>&1`;
is($? >> 8, 0, 'plan mode exits 0');
unlike($out, qr/No ccpraxis-install\.pl hooks found/, 'hooks ARE found under a path containing spaces');
like($out, qr/STUB alpha plan/, 'plugins/alpha hook ran in plan mode');
like($out, qr/STUB beta plan/,  'plugins/beta hook ran in plan mode');
like($out, qr/STUB gamma plan/, 'skills/gamma hook ran in plan mode');
like($out, qr/alpha.*beta.*gamma/s, 'hooks run in the documented order (plugins sorted, then skills)');

done_testing();
