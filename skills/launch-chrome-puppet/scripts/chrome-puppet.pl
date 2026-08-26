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

my $JSON = JSON::PP->new->utf8->pretty->canonical;

# --- Option parsing ---

my $cmd = shift @ARGV // 'help';

my ($opt_port, $opt_tab);
GetOptions(
    'port=i' => \$opt_port,
    'tab=s'  => \$opt_tab,
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

sub http_get {
    my ($host, $port, $path) = @_;

    my $sock = IO::Socket::INET->new(
        PeerAddr => $host,
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 2,
    ) or return undef;

    binmode $sock;
    # HTTP/1.1, not 1.0: as of Chrome 151 the DevTools HTTP endpoint
    # closes HTTP/1.0 connections without sending a response at all.
    # `Connection: close` keeps this a single-shot request regardless.
    syswrite($sock, "GET $path HTTP/1.1\r\nHost: $host:$port\r\nConnection: close\r\n\r\n")
        or return undef;

    my $sel = IO::Select->new($sock);
    my $response = '';
    while ($sel->can_read(3)) {
        my $n = sysread($sock, my $chunk, 8192);
        last unless $n;
        $response .= $chunk;
    }
    close $sock;

    return $1 if $response =~ /\r\n\r\n(.*)/s;
    undef;
}

sub to_native_path {
    my ($path) = @_;
    # Convert msys /c/... to C:/... for Win32 programs like Chrome
    if ($^O eq 'msys' && $path =~ m{^/([a-zA-Z])(/.*)?$}) {
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

sub profile_dir {
    to_native_path(getcwd() . '/.chrome-puppet/profile');
}

sub resolve_port {
    return $opt_port if $opt_port;

    # Check DevToolsActivePort file first (fast path)
    my $prof = profile_dir();
    my $port_from_file = _read_active_port($prof);
    return $port_from_file if $port_from_file;

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

sub _read_active_port {
    my ($prof_dir) = @_;
    my $file = "$prof_dir/DevToolsActivePort";
    return undef unless -f $file;

    open my $fh, '<', $file or return undef;
    my $port = <$fh>;
    close $fh;
    chomp $port if defined $port;
    return undef unless $port && $port =~ /^\d+$/;

    # Verify CDP is actually responding on this port
    my $body = http_get('localhost', $port, '/json/version');
    $body ? int($port) : undef;
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
    my $cwd = to_native_path(getcwd());
    if (system("git rev-parse --git-dir >/dev/null 2>&1") == 0) {
        my $gitignore = "$cwd/.gitignore";
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
    my $existing_port = _read_active_port($prof);
    if ($existing_port) {
        my $ver = _get_version($existing_port);
        output({
            ok             => \1,
            status         => 'existing',
            port           => $existing_port,
            cdp_endpoint   => "http://localhost:$existing_port",
            profile_dir    => $prof,
            chrome_path    => $chrome,
            setup_actions  => \@setup_actions,
            chrome_version => $ver,
        });
        return;
    }

    # 5. Find a free port
    my $port;
    for my $p (9222..9232) {
        my $body = http_get('localhost', $p, '/json/version');
        unless ($body) {
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

    output({
        ok             => \1,
        status         => 'launched',
        port           => $port,
        cdp_endpoint   => "http://localhost:$port",
        profile_dir    => $prof,
        chrome_path    => $chrome,
        setup_actions  => \@setup_actions,
        chrome_version => _get_version($port),
    });
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
    my $path = $url ? "/json/new?$url" : '/json/new';
    my $body = http_get('localhost', $port, $path);

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
    my $ver  = eval { JSON::PP->new->utf8->decode($body) } // {};
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
            file => to_native_path(abs_path($file)),
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
            launch       => 'Detect Chrome, setup dirs, find port, launch, verify CDP',
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
