#!/usr/bin/env perl
# platform: any
# chrome-puppet.pl's DevTools HTTP client, against a mock endpoint that never
# closes a connection -- which is what Chrome does, `Connection: close` or not.
# The client used to read until EOF, so every call returned only when its 3 s
# read timeout expired (measured 3.2 s per `tabs` on Chrome 151). It must stop
# where the response's own framing says the body ends: Content-Length, or the
# last chunk of a chunked body.
#
# Also checked: `tab-new` uses PUT (Chrome answers GET /json/new with 405), a
# non-2xx response is a failure rather than a body, and `status` fails when no
# DevTools endpoint answers instead of reporting ok with an empty version.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use IO::Socket::INET;
use IO::Select;
use JSON::PP;
use Time::HiRes qw(time);

(my $SCRIPT = "$Bin/../../scripts/chrome-puppet.pl") =~ s{\\}{/}g;

my $listen = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 16, ReuseAddr => 1, Proto => 'tcp',
) or plan skip_all => "cannot listen: $!";
my $PORT = $listen->sockport;

my $version = '{"Browser":"MockChrome/1.0","Protocol-Version":"1.3"}';
my $list    = '[{"id":"T1","type":"page","url":"about:blank"}]';
my $newtab  = '{"id":"T2","type":"page","url":"about:blank"}';

sub fixed   { my ($code, $body) = @_;
              "HTTP/1.1 $code\r\nContent-Type:application/json\r\nContent-Length:" . length($body) . "\r\n\r\n$body" }
sub chunked { my ($body) = @_;
              my ($a, $b) = (substr($body, 0, 10), substr($body, 10));
              "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
              . sprintf("%x\r\n%s\r\n%x\r\n%s\r\n0\r\n\r\n", length $a, $a, length $b, $b) }

my $pid = fork();
die "fork: $!" unless defined $pid;
if ($pid == 0) {
    my @held;   # never closed: the client must not need EOF
    my $deadline = time() + 60;
    while (time() < $deadline) {
        my $c = $listen->accept or next;
        my $req = '';
        my $sel = IO::Select->new($c);
        while ($req !~ /\r\n\r\n/ && $sel->can_read(2)) {
            sysread($c, my $buf, 4096) or last;
            $req .= $buf;
        }
        my ($method, $path) = $req =~ m{^(\S+)\s+(\S+)};
        $method //= ''; $path //= '';
        my $resp =
              $path eq '/json/version'        ? fixed('200 OK', $version)
            : $path eq '/json/list'           ? chunked($list)
            : $path =~ m{^/json/new}          ? ($method eq 'PUT'
                                                 ? fixed('200 OK', $newtab)
                                                 : fixed('405 Method Not Allowed',
                                                         'Using unsafe HTTP verb GET to invoke /json/new. This action supports only PUT verb.'))
            :                                   fixed('404 Not Found', 'nope');
        syswrite($c, $resp);
        push @held, $c;
    }
    exit 0;
}
close $listen;

sub run {
    my (@args) = @_;
    my $t0  = time();
    my $out = `perl "$SCRIPT" @args 2>&1`;
    my $rc  = $? >> 8;
    my $json = eval { JSON::PP->new->utf8->decode($out) };
    return ($rc, $json, time() - $t0, $out);
}

{
    my ($rc, $j, $dt, $out) = run('status', '--port', $PORT);
    is($rc, 0, 'status exits 0 against a keep-alive endpoint') or diag($out);
    is($j && $j->{result}{version}{Browser}, 'MockChrome/1.0', 'status reads the Content-Length body');
    cmp_ok($dt, '<', 2, sprintf('status returns without waiting for EOF (%.2fs)', $dt));
}
{
    my ($rc, $j, $dt, $out) = run('tabs', '--port', $PORT);
    is($rc, 0, 'tabs exits 0') or diag($out);
    is($j && ref $j->{result} eq 'ARRAY' ? $j->{result}[0]{id} : undef, 'T1', 'tabs dechunks a chunked body');
    cmp_ok($dt, '<', 2, sprintf('tabs stops at the last chunk (%.2fs)', $dt));
}
{
    my ($rc, $j, $dt, $out) = run('tab-new', '--port', $PORT, 'about:blank');
    is($rc, 0, 'tab-new exits 0') or diag($out);
    is($j && $j->{result}{id}, 'T2', 'tab-new sends PUT, the only verb Chrome accepts for /json/new');
}
{
    # Nothing listens on the port the mock was given back? Use a port nobody
    # holds: bind one, read its number, close it.
    my $s = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 1, Proto => 'tcp');
    my $dead = $s->sockport; close $s;
    my ($rc, $j, $dt) = run('status', '--port', $dead);
    is($rc, 1, 'status exits 1 when no endpoint answers');
    ok($j && !$j->{ok}, 'and reports ok: false instead of an empty version');
    cmp_ok($dt, '<', 1.5, sprintf('a refused connect is bounded (%.2fs)', $dt));
}

kill 'KILL', $pid;
waitpid($pid, 0);
done_testing();
