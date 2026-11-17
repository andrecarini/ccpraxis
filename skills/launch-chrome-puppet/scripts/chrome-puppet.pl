#!/usr/bin/perl
# Chrome Puppet — CDP browser automation via subcommands.
# All output is JSON to stdout for machine consumption.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use CDPClient;
use JSON::PP;
use IO::Socket::INET;
use IO::Select;
use Getopt::Long qw(:config pass_through);
use File::Path qw(make_path);
use Cwd qw(abs_path getcwd);
use MIME::Base64 qw(decode_base64);
use Time::HiRes qw(time);
use Encode ();

my $JSON = JSON::PP->new->utf8->pretty->canonical;

# --- Option parsing ---

my $cmd = shift @ARGV // 'help';

my ($opt_port, $opt_tab, $opt_headless);
GetOptions(
    'port=i'   => \$opt_port,
    'tab=s'    => \$opt_tab,
    'headless' => \$opt_headless,
);

# --- Dispatch ---

my %dispatch = (
    launch       => \&cmd_launch,
    tabs         => \&cmd_tabs,
    'tab-new'    => \&cmd_tab_new,
    'tab-close'  => \&cmd_tab_close,
    status       => \&cmd_status,
    navigate     => \&cmd_navigate,
    html         => \&cmd_html,
    text         => \&cmd_text,
    screenshot   => \&cmd_screenshot,
    click        => \&cmd_click,
    type         => \&cmd_type,
    eval         => \&cmd_eval,
    wait         => \&cmd_wait,
    help         => \&cmd_help,
);

if (my $handler = $dispatch{$cmd}) {
    $handler->();
} else {
    output({ ok => \0, command => $cmd, error => "Unknown subcommand: $cmd" });
    exit 1;
}

# =========================================================================
# Helpers
# =========================================================================

sub output {
    my ($data) = @_;
    $data->{command} //= $cmd;
    print $JSON->encode($data);
}

# Every caller talks to a DevTools endpoint on this machine, which accepts in
# about a millisecond. Windows takes a full 2 s to report a refused localhost
# connect (it retries the SYN), so a long connect timeout made every probe of
# an empty port cost 2 s and a scan of 9222-9232 cost 22 s.
use constant CONNECT_TIMEOUT => 0.5;
use constant READ_TIMEOUT    => 5;     # whole response, not per read

sub _connect {
    my ($host, $port) = @_;
    IO::Socket::INET->new(
        PeerAddr => $host,
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => CONNECT_TIMEOUT,
    );
}

sub port_in_use {
    my ($port) = @_;
    my $sock = _connect('localhost', $port) or return 0;
    close $sock;
    1;
}

# One HTTP/1.1 request; returns the body of a 2xx response, else undef.
#
# The response ends where its framing says it does: Content-Length, or the
# last chunk of a chunked body. Chrome ignores `Connection: close` and holds
# the socket open, so waiting for EOF -- what this did before -- returned the
# body only after the read timeout expired: 3 s on every call, for a body that
# had arrived in 6 ms (measured on Chrome 151). EOF still ends a response that
# carries neither header.
sub http_request {
    my ($method, $host, $port, $path) = @_;

    my $sock = _connect($host, $port) or return undef;
    binmode $sock;
    # HTTP/1.1, not 1.0: as of Chrome 151 the DevTools HTTP endpoint
    # closes HTTP/1.0 connections without sending a response at all.
    syswrite($sock, "$method $path HTTP/1.1\r\nHost: $host:$port\r\n"
                  . "Content-Length: 0\r\nConnection: close\r\n\r\n")
        or do { close $sock; return undef };

    my $sel      = IO::Select->new($sock);
    my $deadline = time() + READ_TIMEOUT;
    my $buf      = '';
    my ($status, %hdr, $hlen);
    my $eof = 0;

    my $complete = sub {
        return 0 unless defined $hlen;
        my $body_len = length($buf) - $hlen;
        if (defined $hdr{'content-length'}) {
            return $body_len >= $hdr{'content-length'};
        }
        if (($hdr{'transfer-encoding'} // '') =~ /\bchunked\b/i) {
            return defined _dechunk(substr($buf, $hlen));
        }
        return $eof;
    };

    until ($eof || $complete->()) {
        my $left = $deadline - time();
        last if $left <= 0 || !$sel->can_read($left);
        my $n = sysread($sock, my $chunk, 65536);
        if (!$n) { $eof = 1; last }
        $buf .= $chunk;
        if (!defined $hlen && $buf =~ /\r\n\r\n/) {
            $hlen = $+[0];
            my ($line, @lines) = split /\r\n/, substr($buf, 0, $hlen - 4);
            ($status) = ($line // '') =~ m{^HTTP/\d\.\d\s+(\d{3})};
            for (@lines) {
                $hdr{lc $1} = $2 if /^([^:]+):\s*(.*?)\s*$/;
            }
        }
    }
    close $sock;

    return undef unless defined $hlen && defined $status && $status =~ /^2/;
    return undef unless $eof || $complete->();
    my $body = substr($buf, $hlen);
    if (defined $hdr{'content-length'}) {
        return substr($body, 0, $hdr{'content-length'});
    }
    if (($hdr{'transfer-encoding'} // '') =~ /\bchunked\b/i) {
        return _dechunk($body);
    }
    $body;
}

sub http_get { http_request('GET', @_) }

# A complete chunked body -> its payload; undef while chunks are still due.
sub _dechunk {
    my ($raw) = @_;
    my ($out, $pos) = ('', 0);
    while (1) {
        my $eol = index($raw, "\r\n", $pos);
        return undef if $eol < 0;
        my ($size) = substr($raw, $pos, $eol - $pos) =~ /^([0-9a-fA-F]+)/;
        return undef unless defined $size;
        $size = hex $size;
        $pos = $eol + 2;
        return $out if $size == 0;
        return undef if length($raw) < $pos + $size + 2;
        $out .= substr($raw, $pos, $size);
        $pos += $size + 2;
    }
}

# A filesystem path is UTF-8 bytes; the JSON encoder takes characters, so a
# path printed as-is came out double-encoded (AndrÃ© for André).
sub disp {
    my ($path) = @_;
    my $copy = $path;
    my $chars = eval { Encode::decode('UTF-8', $copy, Encode::FB_CROAK()) };
    defined $chars ? $chars : $path;
}

sub to_native_path {
    my ($path) = @_;
    # Convert msys /c/... to C:/... for Win32 programs like Chrome. Git for
    # Windows' perl reports $^O as 'cygwin', not 'msys': testing for 'msys'
    # alone left every path unconverted, and Chrome got the right profile only
    # because MSYS happened to rewrite --user-data-dir=/c/... on exec.
    if (($^O eq 'msys' || $^O eq 'cygwin') && $path =~ m{^/([a-zA-Z])(/.*)?$}) {
        return uc($1) . ':' . ($2 // '/');
    }
    $path;
}

sub detect_chrome {
    if ($^O eq 'MSWin32' || $^O eq 'msys' || $^O eq 'cygwin') {
        for my $dir ('C:/Program Files', 'C:/Program Files (x86)') {
            my $p = "$dir/Google/Chrome/Application/chrome.exe";
            return $p if -e $p;
        }
    } elsif ($^O eq 'darwin') {
        my $p = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
        return $p if -x $p;
    } else {
        for my $name (qw(google-chrome google-chrome-stable chromium-browser chromium)) {
            chomp(my $p = `which $name 2>/dev/null`);
            return $p if $p && -x $p;
        }
    }
    undef;
}

# The directory holding .chrome-puppet/. Anchored on the project, not on the
# current directory: a shell that drifted into a subdirectory used to get a
# fresh profile there, and with it a second Chrome. The nearest .chrome-puppet/
# between the current directory and the git toplevel wins; failing that the
# toplevel; outside a git repo, the current directory.
my $puppet_root;
sub puppet_root {
    return $puppet_root if defined $puppet_root;
    my $cwd = to_native_path(getcwd());
    chomp(my $top = `git rev-parse --show-toplevel 2>/dev/null` // '');
    return $puppet_root = $cwd unless $? == 0 && length $top;
    $top = to_native_path($top);
    for (my $d = $cwd; length($d) >= length($top); ) {
        return $puppet_root = $d if -d "$d/.chrome-puppet";
        last if lc($d) eq lc($top);
        (my $up = $d) =~ s{/[^/]+/?\z}{};
        last if $up eq $d;
        $d = $up;
    }
    $puppet_root = $top;
}

sub state_dir   { puppet_root() . '/.chrome-puppet' }
sub profile_dir { state_dir() . '/profile' }
sub port_file   { state_dir() . '/port' }

# 1 if a Chrome is running on this profile, else 0.
# Windows: Chrome holds <profile>/lockfile open without write sharing while it
# runs, so an append-open fails ("Device or resource busy", measured); a
# lockfile left behind by a crash opens fine. Elsewhere SingletonLock is a
# symlink to "<host>-<pid>".
sub profile_in_use {
    my ($prof) = @_;
    if ($^O eq 'MSWin32' || $^O eq 'msys' || $^O eq 'cygwin') {
        my $lock = "$prof/lockfile";
        return 0 unless -e $lock;
        open(my $fh, '>>', $lock) or return 1;
        close $fh;
        return 0;
    }
    my $link = readlink("$prof/SingletonLock");
    return 0 unless defined $link;
    my ($pid) = $link =~ /-(\d+)\z/;
    return 1 unless $pid;
    (kill(0, $pid) || $!{EPERM}) ? 1 : 0;
}

# The CDP port of the Chrome running on this project's profile, or undef.
# `launch` records the port it chose in .chrome-puppet/port. Chrome writes
# DevToolsActivePort only when it picks the port itself
# (--remote-debugging-port=0); with the fixed port used here it writes nothing
# (measured, Chrome 151). Reading only that file, `launch` never found its own
# instance and ran Chrome again, which Chrome hands to the running instance as
# a new window. A recorded port counts only while the profile is in use, so a
# stale file never attaches to some other Chrome that later took the port.
sub running_port {
    my $prof = profile_dir();
    return undef unless profile_in_use($prof);
    for my $file (port_file(), "$prof/DevToolsActivePort") {
        my $port = _read_port_file($file) or next;
        return $port if http_get('localhost', $port, '/json/version');
    }
    undef;
}

sub resolve_port {
    return $opt_port if $opt_port;

    my $port = running_port();
    return $port if $port;

    # Fallback: scan port range for any CDP instance
    for my $p (9222..9232) {
        my $body = http_get('localhost', $p, '/json/version');
        if ($body) {
            eval { JSON::PP->new->utf8->decode($body) };
            return $p unless $@;
        }
    }
    undef;
}

sub resolve_tab {
    my ($port) = @_;
    return $opt_tab if $opt_tab;

    my $body = http_get('localhost', $port, '/json/list') or return undef;
    my $tabs = eval { JSON::PP->new->utf8->decode($body) };
    return undef if $@ || !$tabs || ref $tabs ne 'ARRAY' || !@$tabs;

    # Prefer first "page" type tab
    for my $t (@$tabs) {
        return $t->{id} if ($t->{type} // '') eq 'page';
    }
    $tabs->[0]{id};
}

# First line of a port file (ours or DevToolsActivePort), or undef.
sub _read_port_file {
    my ($file) = @_;
    open my $fh, '<', $file or return undef;
    my $port = <$fh>;
    close $fh;
    return undef unless defined $port && $port =~ /^\s*(\d+)\s*$/;
    int($1);
}

sub with_cdp {
    my ($cmd_name, $code) = @_;

    my $port = resolve_port();
    unless ($port) {
        output({ ok => \0, command => $cmd_name,
                 error => "No running Chrome puppet found. Run 'launch' first." });
        exit 1;
    }

    my $tab_id = resolve_tab($port);
    unless ($tab_id) {
        output({ ok => \0, command => $cmd_name,
                 error => "No open tabs found on port $port" });
        exit 1;
    }

    my $cdp = CDPClient->new(port => $port, target_id => $tab_id);
    eval { $cdp->connect() };
    if ($@) {
        chomp(my $err = $@);
        output({ ok => \0, command => $cmd_name, error => "CDP connect failed: $err" });
        exit 1;
    }

    eval { $code->($cdp, $port, $tab_id) };
    my $err = $@;
    $cdp->disconnect();

    if ($err) {
        chomp $err;
        output({ ok => \0, command => $cmd_name, error => $err });
        exit 1;
    }
}

# =========================================================================
# Launch & lifecycle subcommands
# =========================================================================

sub cmd_launch {
    my @setup_actions;

    # 1. Detect Chrome
    my $chrome = detect_chrome();
    unless ($chrome) {
        output({ ok => \0, error => "Chrome not found. Install Google Chrome." });
        exit 1;
    }

    # 2. Ensure profile dir exists
    my $prof = profile_dir();
    unless (-d $prof) {
        make_path($prof) or do {
            output({ ok => \0, error => "Failed to create profile dir: $!" });
            exit 1;
        };
        push @setup_actions, "created $prof";
    }

    # 3. Add to .gitignore if this is a git repo
    my $root = puppet_root();
    if (system("git rev-parse --git-dir >/dev/null 2>&1") == 0) {
        my $gitignore = "$root/.gitignore";
        my $has_entry = 0;
        if (-f $gitignore) {
            if (open my $fh, '<', $gitignore) {
                while (<$fh>) {
                    chomp;
                    if (/^\s*\.chrome-puppet\/?$/) { $has_entry = 1; last }
                }
                close $fh;
            }
        }
        unless ($has_entry) {
            if (open my $fh, '>>', $gitignore) {
                print $fh ".chrome-puppet/\n";
                close $fh;
                push @setup_actions, "added .chrome-puppet/ to .gitignore";
            }
        }
    }

    # 4. Check for already-running instance
    my $existing_port = running_port();
    if ($existing_port) {
        _write_port_file($existing_port);
        my $ver = _get_version($existing_port);
        output({
            ok             => \1,
            status         => 'existing',
            port           => $existing_port,
            cdp_endpoint   => "http://localhost:$existing_port",
            profile_dir    => disp($prof),
            chrome_path    => $chrome,
            setup_actions  => \@setup_actions,
            chrome_version => $ver,
        });
        return;
    }

    # Running on this profile but unreachable over CDP (started by hand, or
    # its port record is gone): launching again would only open another
    # window in that instance and then wait for a CDP port that never comes.
    if (profile_in_use($prof)) {
        output({ ok => \0, profile_dir => disp($prof),
                 error => "Chrome is already running on " . disp($prof) . " but its DevTools "
                        . "endpoint is unreachable. Close that Chrome, then run "
                        . "launch again (or pass --port if you know its port)." });
        exit 1;
    }

    # 5. Find a free port: nothing listening at all, not merely no CDP.
    my $port;
    for my $p (9222..9232) {
        unless (port_in_use($p)) {
            $port = $p;
            last;
        }
    }
    unless ($port) {
        output({ ok => \0, error => "No free port in 9222-9232" });
        exit 1;
    }

    # 6. Launch Chrome (backgrounded via fork+exec to avoid shell injection)
    my @args = (
        "--remote-debugging-port=$port",
        "--user-data-dir=$prof",
        '--no-first-run',
        '--no-default-browser-check',
        '--disable-extensions',
        '--disable-popup-blocking',
        '--window-size=1920,1080',
        '--disable-background-networking',
    );
    push @args, '--headless=new' if $opt_headless;

    my $pid = fork();
    if (!defined $pid) {
        output({ ok => \0, error => "Fork failed: $!" });
        exit 1;
    } elsif ($pid == 0) {
        # Child: suppress output, exec Chrome
        open STDOUT, '>', '/dev/null';
        open STDERR, '>', '/dev/null';
        exec($chrome, @args) or exit 1;
    }
    # Parent continues to wait for CDP

    # 7. Wait for CDP to become ready
    my $ready = 0;
    for (1..20) { # 20 × 500ms = 10s
        select(undef, undef, undef, 0.5);
        if (http_get('localhost', $port, '/json/version')) {
            $ready = 1;
            last;
        }
    }

    unless ($ready) {
        output({ ok => \0, error => "Chrome launched but CDP not responding on port $port after 10s" });
        exit 1;
    }
    _write_port_file($port);

    output({
        ok             => \1,
        status         => 'launched',
        port           => $port,
        cdp_endpoint   => "http://localhost:$port",
        profile_dir    => disp($prof),
        chrome_path    => $chrome,
        setup_actions  => \@setup_actions,
        chrome_version => _get_version($port),
    });
}

sub _write_port_file {
    my ($port) = @_;
    my $file = port_file();
    return if (_read_port_file($file) // 0) == $port;
    open(my $fh, '>', $file) or return;
    print $fh "$port\n";
    close $fh;
}

sub _get_version {
    my ($port) = @_;
    my $body = http_get('localhost', $port, '/json/version') or return 'unknown';
    my $info = eval { JSON::PP->new->utf8->decode($body) };
    $info->{'Browser'} // 'unknown';
}

sub cmd_tabs {
    my $port = resolve_port();
    unless ($port) {
        output({ ok => \0, error => "No running Chrome puppet found" });
        exit 1;
    }

    my $body = http_get('localhost', $port, '/json/list');
    unless ($body) {
        output({ ok => \0, error => "Failed to list tabs on port $port" });
        exit 1;
    }

    my $tabs = eval { JSON::PP->new->utf8->decode($body) };
    output({ ok => \1, result => $tabs });
}

sub cmd_tab_new {
    my $port = resolve_port();
    unless ($port) {
        output({ ok => \0, error => "No running Chrome puppet found" });
        exit 1;
    }

    my $url  = $ARGV[0] // '';
    $url =~ s/[\r\n]//g;  # Prevent HTTP request splitting
    $url =~ s/ /%20/g;    # A space would end the request target
    my $path = $url ? "/json/new?$url" : '/json/new';
    # PUT: Chrome answers GET /json/new with 405 "Using unsafe HTTP verb GET".
    my $body = http_request('PUT', 'localhost', $port, $path);

    unless ($body) {
        output({ ok => \0, error => "Failed to create new tab" });
        exit 1;
    }

    my $tab = eval { JSON::PP->new->utf8->decode($body) };
    output({ ok => \1, result => $tab });
}

sub cmd_tab_close {
    my $port = resolve_port();
    my $id   = $ARGV[0] // $opt_tab;

    unless ($port && $id) {
        output({ ok => \0, error => "Usage: tab-close [--port PORT] <tab-id>" });
        exit 1;
    }

    my $body = http_get('localhost', $port, "/json/close/$id");
    unless (defined $body) {
        output({ ok => \0, error => "Failed to close tab $id" });
        exit 1;
    }
    output({ ok => \1, result => { closed => $id } });
}

sub cmd_status {
    my $port = resolve_port();
    unless ($port) {
        output({ ok => \0, error => "No running Chrome puppet on ports 9222-9232" });
        exit 1;
    }

    my $body = http_get('localhost', $port, '/json/version');
    my $ver  = defined $body ? eval { JSON::PP->new->utf8->decode($body) } : undef;
    unless (ref $ver eq 'HASH') {
        output({ ok => \0, error => "No DevTools endpoint answering on port $port" });
        exit 1;
    }
    output({ ok => \1, result => { port => $port, version => $ver } });
}

# =========================================================================
# Page interaction subcommands (via WebSocket CDP)
# =========================================================================

sub cmd_navigate {
    my $url = $ARGV[0];
    unless ($url) {
        output({ ok => \0, error => "Usage: navigate <url>" });
        exit 1;
    }

    with_cdp('navigate', sub {
        my ($cdp) = @_;

        $cdp->send_command('Page.enable');
        my $result = $cdp->send_command('Page.navigate', { url => $url });
        die $result->{error} . "\n" unless $result->{ok};

        my $event = $cdp->wait_for_event('Page.loadEventFired', 30);

        output({ ok => \1, result => {
            url     => $url,
            frameId => $result->{result}{frameId},
            loaded  => defined $event ? \1 : \0,
        }});
    });
}

sub cmd_html {
    my $selector = $ARGV[0];

    with_cdp('html', sub {
        my ($cdp) = @_;

        my $js;
        if ($selector) {
            my $sel_js = JSON::PP->new->encode($selector);
            $js = "(() => { const el = document.querySelector($sel_js); return el ? el.outerHTML : null; })()";
        } else {
            $js = 'document.documentElement.outerHTML';
        }

        my $r = $cdp->send_command('Runtime.evaluate', {
            expression    => $js,
            returnByValue => \1,
        });
        die $r->{error} . "\n" unless $r->{ok};

        output({ ok => \1, result => {
            html     => $r->{result}{result}{value},
            selector => $selector,
        }});
    });
}

sub cmd_text {
    my $selector = $ARGV[0];

    with_cdp('text', sub {
        my ($cdp) = @_;

        my $js;
        if ($selector) {
            my $sel_js = JSON::PP->new->encode($selector);
            $js = "(() => { const el = document.querySelector($sel_js); return el ? el.innerText : null; })()";
        } else {
            $js = 'document.body.innerText';
        }

        my $r = $cdp->send_command('Runtime.evaluate', {
            expression    => $js,
            returnByValue => \1,
        });
        die $r->{error} . "\n" unless $r->{ok};

        output({ ok => \1, result => {
            text     => $r->{result}{result}{value},
            selector => $selector,
        }});
    });
}

sub cmd_screenshot {
    my $file = $ARGV[0] // 'screenshot.png';

    with_cdp('screenshot', sub {
        my ($cdp) = @_;

        my $r = $cdp->send_command('Page.captureScreenshot', { format => 'png' });
        die $r->{error} . "\n" unless $r->{ok};

        my $data = decode_base64($r->{result}{data});
        open my $fh, '>:raw', $file or die "Cannot write $file: $!\n";
        print $fh $data;
        close $fh;

        output({ ok => \1, result => {
            file => disp(to_native_path(abs_path($file))),
            size => length($data),
        }});
    });
}

sub cmd_click {
    my $selector = $ARGV[0];
    unless ($selector) {
        output({ ok => \0, error => "Usage: click <selector>" });
        exit 1;
    }

    with_cdp('click', sub {
        my ($cdp) = @_;

        my $sel_js = JSON::PP->new->encode($selector);
        my $js = "(() => { const el = document.querySelector($sel_js); if (!el) return false; el.click(); return true; })()";

        my $r = $cdp->send_command('Runtime.evaluate', {
            expression    => $js,
            returnByValue => \1,
        });
        die $r->{error} . "\n" unless $r->{ok};

        if ($r->{result}{result}{value}) {
            output({ ok => \1, result => { selector => $selector, clicked => \1 } });
        } else {
            output({ ok => \0, error => "Element not found: $selector" });
        }
    });
}

sub cmd_type {
    my $selector = $ARGV[0];
    my $text     = $ARGV[1];

    unless ($selector && defined $text) {
        output({ ok => \0, error => "Usage: type <selector> <text>" });
        exit 1;
    }

    with_cdp('type', sub {
        my ($cdp) = @_;

        # Focus the element
        my $sel_js = JSON::PP->new->encode($selector);
        my $focus_js = "(() => { const el = document.querySelector($sel_js); if (!el) return false; el.focus(); return true; })()";

        my $f = $cdp->send_command('Runtime.evaluate', {
            expression    => $focus_js,
            returnByValue => \1,
        });
        die $f->{error} . "\n" unless $f->{ok};

        unless ($f->{result}{result}{value}) {
            output({ ok => \0, error => "Element not found: $selector" });
            return;
        }

        # Insert text
        my $t = $cdp->send_command('Input.insertText', { text => $text });
        die $t->{error} . "\n" unless $t->{ok};

        output({ ok => \1, result => { selector => $selector, typed => $text } });
    });
}

sub cmd_eval {
    my $js = $ARGV[0];
    unless ($js) {
        output({ ok => \0, error => "Usage: eval <javascript>" });
        exit 1;
    }

    with_cdp('eval', sub {
        my ($cdp) = @_;

        my $r = $cdp->send_command('Runtime.evaluate', {
            expression    => $js,
            returnByValue => \1,
        });
        die $r->{error} . "\n" unless $r->{ok};

        my $res = $r->{result};
        if ($res->{exceptionDetails}) {
            output({ ok => \0, error => "JS error: " .
                ($res->{exceptionDetails}{text} // 'unknown') });
        } else {
            output({ ok => \1, result => {
                value => $res->{result}{value},
                type  => $res->{result}{type},
            }});
        }
    });
}

sub cmd_wait {
    my $target = $ARGV[0];
    unless ($target) {
        output({ ok => \0, error => "Usage: wait <selector|seconds>" });
        exit 1;
    }

    # Numeric → simple sleep (no CDP needed)
    if ($target =~ /^\d+(\.\d+)?$/) {
        select(undef, undef, undef, $target + 0);
        output({ ok => \1, result => { waited_seconds => $target + 0 } });
        return;
    }

    # CSS selector → poll until found
    with_cdp('wait', sub {
        my ($cdp) = @_;

        my $timeout = 30;
        my $sel_js = JSON::PP->new->encode($target);
        my $js = "document.querySelector($sel_js) !== null";
        my $start = time();

        while (time() - $start < $timeout) {
            my $r = $cdp->send_command('Runtime.evaluate', {
                expression    => $js,
                returnByValue => \1,
            });

            if ($r->{ok} && $r->{result}{result}{value}) {
                output({ ok => \1, result => {
                    selector => $target,
                    found    => \1,
                    elapsed  => sprintf('%.1f', time() - $start),
                }});
                return;
            }

            select(undef, undef, undef, 0.5);
        }

        output({ ok => \0, error => "Timeout (${timeout}s) waiting for: $target" });
    });
}

sub cmd_help {
    output({ ok => \1, result => {
        usage    => 'chrome-puppet.pl <command> [--port PORT] [--tab ID] [args...]',
        commands => {
            launch       => "Reuse this project's running Chrome, or set up, launch and verify CDP [--headless]",
            tabs         => 'List open tabs',
            'tab-new'    => 'Open a new tab [url]',
            'tab-close'  => 'Close a tab <id>',
            status       => 'Check if CDP is responding',
            navigate     => 'Navigate to <url> and wait for load',
            html         => 'Get outer HTML [selector]',
            text         => 'Get inner text [selector]',
            screenshot   => 'Capture viewport as PNG [filename]',
            click        => 'Click element <selector>',
            type         => 'Type into element <selector> <text>',
            eval         => 'Evaluate JavaScript <expression>',
            wait         => 'Wait for <selector> or <seconds>',
        },
    }});
}
